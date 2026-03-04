module AgentMonitor.Parser
  ( parseJsonlLines
  , processEvent
  , buildInitialState
  ) where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Vector qualified as V

import AgentMonitor.Types

-- | Parse multiple JSONL lines into JSON values
parseJsonlLines :: BL.ByteString -> [Value]
parseJsonlLines = mapMaybe decode . BL.split 0x0a

-- | Build initial state from all lines in the file
buildInitialState :: FilePath -> BL.ByteString -> AppState
buildInitialState fp content =
  let events = parseJsonlLines content
      emptyState = AppState
        { asAgents       = Map.singleton "main" mkMainAgent
        , asRootId       = "main"
        , asSelectedId   = "main"
        , asFlatOrder    = ["main"]
        , asFilePath     = fp
        , asFilePos      = fromIntegral (BL.length content)
        , asSessionStart = Nothing
        }
      st = foldl processEvent emptyState events
  in st { asFlatOrder = flattenTree (asAgents st) "main" }

-- | Process a single JSONL event and update the state
processEvent :: AppState -> Value -> AppState
processEvent st val = case val of
  Object obj -> processObject st obj
  _          -> st

processObject :: AppState -> Object -> AppState
processObject st obj =
  let evType    = lookupText "type" obj
      timestamp = lookupText "timestamp" obj >>= iso8601ParseM . T.unpack
  in case evType of
    Just "assistant" -> processAssistant st obj timestamp
    Just "user"      -> processUser st obj timestamp
    Just "progress"  -> processProgress st obj timestamp
    _                -> maybeUpdateSessionStart st timestamp

-- | Process an assistant message. Looks for Task tool_use calls and
-- accumulates tokens/output.
processAssistant :: AppState -> Object -> Maybe UTCTime -> AppState
processAssistant st obj timestamp =
  let parentToolUseID = lookupText "parentToolUseID" obj
      agentId = resolveAgentId parentToolUseID
      -- Extract message fields
      msg = lookupObject "message" obj
      content = msg >>= lookupArray "content"
      stopReason = msg >>= lookupText "stop_reason"
      usage = msg >>= lookupObject "usage"
      inputTok = maybe 0 (lookupInt "input_tokens") usage
            + maybe 0 (lookupInt "cache_read_input_tokens") usage
      outputTok = maybe 0 (lookupInt "output_tokens") usage
      -- Find Task tool_use calls in content
      taskCalls = maybe [] extractTaskCalls content
      -- Find text content for last output
      textContent = maybe "" extractTextContent content
      -- Count tool_use calls
      toolUseCount = maybe 0 countToolUses content
      -- Is this the final message for a subagent?
      isEndTurn = stopReason == Just "end_turn"
      -- Update the agent that owns this message
      st1 = updateAgent agentId st $ \ai -> ai
        { aiInputTokens  = aiInputTokens ai + inputTok
        , aiOutputTokens = aiOutputTokens ai + outputTok
        , aiToolCalls    = aiToolCalls ai + toolUseCount
        , aiLastTime     = timestamp
        , aiStartTime    = aiStartTime ai <|> timestamp
        , aiLastOutput   = if T.null textContent then aiLastOutput ai else textContent
        }
      -- If end_turn and this is a subagent, mark completed
      st2 = if isEndTurn && agentId /= "main"
                && null taskCalls  -- no pending tool calls
             then updateAgent agentId st1 $ \ai -> ai { aiStatus = Completed }
             else st1
      -- Spawn subagents for each Task call
      st3 = foldl (spawnSubAgent agentId timestamp) st2 taskCalls
      st4 = maybeUpdateSessionStart st3 timestamp
  in st4 { asFlatOrder = flattenTree (asAgents st4) "main" }

-- | Process a user message. Looks for tool_result to detect subagent completion.
processUser :: AppState -> Object -> Maybe UTCTime -> AppState
processUser st obj timestamp =
  let msg = lookupObject "message" obj
      content = msg >>= lookupArray "content"
      -- Find tool_results that complete Task calls
      completedIds = maybe [] extractToolResults content
      -- Mark completed subagents
      st1 = foldl markCompleted st completedIds
      -- Also update main agent timestamp
      st2 = updateAgent "main" st1 $ \ai -> ai
        { aiLastTime = timestamp
        , aiStartTime = aiStartTime ai <|> timestamp
        }
      st3 = maybeUpdateSessionStart st2 timestamp
  in st3 { asFlatOrder = flattenTree (asAgents st3) "main" }
  where
    markCompleted s tid =
      if Map.member tid (asAgents s)
      then updateAgent tid s $ \ai -> ai
        { aiStatus   = Completed
        , aiLastTime = timestamp
        }
      else s

-- | Process a progress event. These track subagent activity.
processProgress :: AppState -> Object -> Maybe UTCTime -> AppState
processProgress st obj timestamp =
  let parentToolUseID = lookupText "parentToolUseID" obj
      agentId = resolveAgentId parentToolUseID
      dataObj = lookupObject "data" obj
      dataType = dataObj >>= lookupText "type"
  in case dataType of
    Just "agent_progress" -> processAgentProgress st obj dataObj timestamp agentId
    _ -> maybeUpdateSessionStart st timestamp

-- | Process agent_progress data which contains the subagent's conversation
processAgentProgress :: AppState -> Object -> Maybe Object -> Maybe UTCTime -> AgentId -> AppState
processAgentProgress st _obj dataObj timestamp agentId =
  let innerMsg = dataObj >>= lookupObject "message"
      innerMsgType = innerMsg >>= lookupText "type"
      innerMessage = innerMsg >>= lookupObject "message"
      -- Extract agentId from data
      dataAgentId = dataObj >>= lookupText "agentId"
      -- For assistant messages in agent_progress, extract tokens and content
      st1 = case innerMsgType of
        Just "assistant" ->
          let usage = innerMessage >>= lookupObject "usage"
              inputTok = maybe 0 (lookupInt "input_tokens") usage
                    + maybe 0 (lookupInt "cache_read_input_tokens") usage
              outputTok = maybe 0 (lookupInt "output_tokens") usage
              content = innerMessage >>= lookupArray "content"
              textContent = maybe "" extractTextContent content
              toolUseCount = maybe 0 countToolUses content
              stopReason = innerMessage >>= lookupText "stop_reason"
              taskCalls = maybe [] extractTaskCalls content
              isEndTurn = stopReason == Just "end_turn"
              s = updateAgent agentId st $ \ai -> ai
                { aiInputTokens  = aiInputTokens ai + inputTok
                , aiOutputTokens = aiOutputTokens ai + outputTok
                , aiToolCalls    = aiToolCalls ai + toolUseCount
                , aiLastTime     = timestamp
                , aiStartTime    = aiStartTime ai <|> timestamp
                , aiLastOutput   = if T.null textContent then aiLastOutput ai else textContent
                , aiAgentId      = aiAgentId ai <|> dataAgentId
                }
              s2 = if isEndTurn && null taskCalls
                   then updateAgent agentId s $ \ai -> ai { aiStatus = Completed }
                   else s
              -- Spawn sub-subagents
              s3 = foldl (spawnSubAgent agentId timestamp) s2 taskCalls
          in s3
        _ -> updateAgent agentId st $ \ai -> ai
          { aiLastTime = timestamp
          , aiStartTime = aiStartTime ai <|> timestamp
          , aiAgentId   = aiAgentId ai <|> dataAgentId
          }
      st2 = maybeUpdateSessionStart st1 timestamp
  in st2 { asFlatOrder = flattenTree (asAgents st2) "main" }

-- | Resolve which agent an event belongs to based on parentToolUseID
resolveAgentId :: Maybe Text -> AgentId
resolveAgentId Nothing    = "main"
resolveAgentId (Just pid) = pid

-- | Spawn a subagent from a Task tool_use call
spawnSubAgent :: AgentId -> Maybe UTCTime -> AppState -> (Text, Text) -> AppState
spawnSubAgent parentId timestamp st (taskId, desc) =
  let newAgent = mkSubAgent taskId parentId desc timestamp
  in if Map.member taskId (asAgents st)
     then st  -- Already exists
     else let agents' = Map.insert taskId newAgent (asAgents st)
              -- Add to parent's children list
              agents'' = Map.adjust (\ai -> ai { aiChildren = aiChildren ai ++ [taskId] })
                                    parentId agents'
          in st { asAgents = agents'' }

-- | Extract Task tool_use calls from message content
extractTaskCalls :: Array -> [(Text, Text)]
extractTaskCalls arr = mapMaybe extractTask (V.toList arr)
  where
    extractTask (Object o) =
      case (lookupText "type" o, lookupText "name" o, lookupText "id" o) of
        (Just "tool_use", Just name, Just tid)
          | name == "Task" || name == "Skill" ->
              let input = lookupObject "input" o
                  desc = fromMaybe name (input >>= lookupText "description")
              in Just (tid, desc)
        _ -> Nothing
    extractTask _ = Nothing

-- | Extract tool_result ids from user message content
extractToolResults :: Array -> [Text]
extractToolResults arr = mapMaybe extractResult (V.toList arr)
  where
    extractResult (Object o) =
      case lookupText "type" o of
        Just "tool_result" -> lookupText "tool_use_id" o
        _ -> Nothing
    extractResult _ = Nothing

-- | Extract text content from message content array
extractTextContent :: Array -> Text
extractTextContent arr =
  let texts = mapMaybe extractText (V.toList arr)
  in case texts of
    [] -> ""
    _  -> last texts  -- Take the last text block
  where
    extractText (Object o) =
      case lookupText "type" o of
        Just "text" -> lookupText "text" o
        _ -> Nothing
    extractText _ = Nothing

-- | Count tool_use items in content
countToolUses :: Array -> Int
countToolUses arr = length $ filter isToolUse (V.toList arr)
  where
    isToolUse (Object o) = lookupText "type" o == Just "tool_use"
    isToolUse _          = False

-- | Update an agent in the state, creating it if needed
updateAgent :: AgentId -> AppState -> (AgentInfo -> AgentInfo) -> AppState
updateAgent aid st f =
  let agents = asAgents st
  in case Map.lookup aid agents of
    Just ai -> st { asAgents = Map.insert aid (f ai) agents }
    Nothing ->
      -- Agent not yet known (progress event arrived before Task call was parsed)
      let newAgent = mkSubAgent aid "main" ("Agent " <> aid) Nothing
          agents' = Map.insert aid (f newAgent) agents
          -- Also add to main's children if not already there
          agents'' = Map.adjust (\ai ->
            if aid `elem` aiChildren ai
            then ai
            else ai { aiChildren = aiChildren ai ++ [aid] })
            "main" agents'
      in st { asAgents = agents'' }

-- | Flatten the agent tree into a list for navigation (DFS order)
flattenTree :: Map AgentId AgentInfo -> AgentId -> [AgentId]
flattenTree agents root = case Map.lookup root agents of
  Nothing -> [root]
  Just ai -> root : concatMap (flattenTree agents) (aiChildren ai)

-- | Update session start time if not yet set
maybeUpdateSessionStart :: AppState -> Maybe UTCTime -> AppState
maybeUpdateSessionStart st Nothing  = st
maybeUpdateSessionStart st (Just t) = st { asSessionStart = asSessionStart st <|> Just t }

-- Helper: lookup a text field from a JSON object
lookupText :: Text -> Object -> Maybe Text
lookupText key obj = case KM.lookup (Key.fromText key) obj of
  Just (String t) -> Just t
  _               -> Nothing

-- Helper: lookup an object field
lookupObject :: Text -> Object -> Maybe Object
lookupObject key obj = case KM.lookup (Key.fromText key) obj of
  Just (Object o) -> Just o
  _               -> Nothing

-- Helper: lookup an array field
lookupArray :: Text -> Object -> Maybe Array
lookupArray key obj = case KM.lookup (Key.fromText key) obj of
  Just (Array a) -> Just a
  _              -> Nothing

-- Helper: lookup an int field
lookupInt :: Text -> Object -> Int
lookupInt key obj = case KM.lookup (Key.fromText key) obj of
  Just (Number n) -> round n
  _               -> 0

-- Applicative alternative for Maybe
(<|>) :: Maybe a -> Maybe a -> Maybe a
(<|>) (Just x) _ = Just x
(<|>) Nothing  y = y
