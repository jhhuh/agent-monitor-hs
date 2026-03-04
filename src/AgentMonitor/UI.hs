{-# LANGUAGE OverloadedStrings #-}
module AgentMonitor.UI
  ( runApp
  ) where

import Brick
import Brick.BChan (newBChan)
import Brick.Widgets.Border
import Brick.Widgets.Border.Style (unicode)
import Brick.Widgets.Center (centerLayer, hCenter)
import Control.Monad.IO.Class (liftIO)
import Data.Function ((&))
import Control.Monad (when)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, NominalDiffTime, diffUTCTime)
import Data.Time.Clock (getCurrentTime)
import Graphics.Vty qualified as Vty
import Graphics.Vty.CrossPlatform (mkVty)
import System.FilePath (takeBaseName, takeDirectory)

import AgentMonitor.ProcChecker (ProcChecker, checkOpenFiles)
import AgentMonitor.Types
import AgentMonitor.Parser (parseJsonlLines, processEvent, processSubagentContent,
                            buildInitialState, loadSubagentFiles, flattenTreeFiltered)
import AgentMonitor.Watcher (startWatcher, readNewLines, readNewSubagentLines, discoverProjects, discoverSessions)

-- | Run the brick application
runApp :: AppState -> IO AppState
runApp initialState = do
  chan <- newBChan 10
  (posRef, subPosRef, checker) <- startWatcher chan (asFilePath initialState) (asFilePos initialState)
  let buildVty = mkVty Vty.defaultConfig
  initialVty <- buildVty
  customMain initialVty buildVty (Just chan) (app posRef subPosRef checker) initialState

-- | The brick App definition
app :: IORef Int -> IORef (Map FilePath Int) -> ProcChecker -> App AppState CustomEvent ResourceName
app posRef subPosRef checker = App
  { appDraw         = drawUI
  , appChooseCursor = neverShowCursor
  , appHandleEvent  = handleEvent posRef subPosRef checker
  , appStartEvent   = pure ()
  , appAttrMap      = const theAttrMap
  }

-- | Draw the UI
drawUI :: AppState -> [Widget ResourceName]
drawUI st =
  let focusedTree = asFocusedPanel st == AgentTree
      treeBorderLabel = if focusedTree
                        then withAttr focusedLabelAttr (str " Agent Tree ")
                        else str " Agent Tree "
      detailBorderLabel = if not focusedTree
                          then withAttr focusedLabelAttr (str " Detail Panel ")
                          else str " Detail Panel "
      base = withBorderStyle unicode $
        vBox
          [ hBox
              [ borderWithLabel treeBorderLabel $
                  hLimitPercent 40 $
                  padRight Max $
                  viewport AgentTree Vertical $
                  drawTree st
              , borderWithLabel detailBorderLabel $
                  padRight Max $
                  padBottom Max $
                  viewport DetailViewport Vertical $
                  drawDetail st
              ]
          , hBorder
          , drawStatusBar st
          ]
      overlays
        | asHelpVisible st    = [centerLayer helpWidget, base]
        | asPickerVisible st  = [centerLayer (drawPicker st), base]
        | otherwise           = [base]
  in overlays

-- | Help overlay widget listing all keybindings
helpWidget :: Widget ResourceName
helpWidget =
  withBorderStyle unicode $
    borderWithLabel (str " Help ") $
      padLeftRight 2 $ padTopBottom 1 $
        hCenter $ vBox
          [ str "h           Focus tree panel"
          , str "l           Focus detail panel"
          , str "j / Down    Move down / Scroll down"
          , str "k / Up      Move up / Scroll up"
          , str "g           Scroll detail to top"
          , str "G           Scroll detail to bottom"
          , str "c           Toggle completed agents"
          , str "r           Manual refresh"
          , str "p           Project picker"
          , str "s           Session picker"
          , str "?           Toggle this help"
          , str "q / Esc     Quit"
          ]

-- | Draw project/session picker overlay
drawPicker :: AppState -> Widget ResourceName
drawPicker st =
  let title = case asPickerMode st of
        PickerProjects -> " Projects "
        PickerSessions -> " Sessions (h: back) "
      items = asPickerItems st
      body = if null items
             then [withAttr dimAttr (str "(none found)")]
             else zipWith drawPickerItem [0..] items
  in withBorderStyle unicode $
    borderWithLabel (str title) $
      padLeftRight 2 $ padTopBottom 1 $
        vBox body
  where
    drawPickerItem idx (label, _path) =
      let isSelected = idx == asPickerIndex st
          w = str label
      in if isSelected
         then visible $ withAttr selectedAttr w
         else w

-- | Draw the agent tree
drawTree :: AppState -> Widget ResourceName
drawTree st = case Map.lookup "main" (asAgents st) of
  Nothing -> str "(empty)"
  Just mainAi ->
    let mainWidget = drawNodeLine st "main" mainAi ""
        children = filterChildren st (aiChildren mainAi)
        childWidgets = drawChildren st children "  "
    in vBox (mainWidget : childWidgets)

-- | Filter children based on asShowCompleted setting.
filterChildren :: AppState -> [AgentId] -> [AgentId]
filterChildren st
  | asShowCompleted st = id
  | otherwise = filter $ \aid -> case Map.lookup aid (asAgents st) of
      Just ai -> aiStatus ai /= Completed || hasRunningDescendant aid
      Nothing -> True
  where
    hasRunningDescendant aid = case Map.lookup aid (asAgents st) of
      Nothing -> False
      Just ai -> any isRunningOrHasRunning (aiChildren ai)
    isRunningOrHasRunning cid = case Map.lookup cid (asAgents st) of
      Nothing -> False
      Just ci -> aiStatus ci == Running || hasRunningDescendant cid

-- | Draw a list of sibling children with proper tree connectors
drawChildren :: AppState -> [AgentId] -> String -> [Widget ResourceName]
drawChildren _ [] _ = []
drawChildren st [aid] pfx =
  case Map.lookup aid (asAgents st) of
    Nothing -> []
    Just ai ->
      let line = drawNodeLine st aid ai (pfx ++ "└─")
          grandChildren = drawChildren st (filterChildren st (aiChildren ai)) (pfx ++ "  ")
      in line : grandChildren
drawChildren st (aid:rest) pfx =
  case Map.lookup aid (asAgents st) of
    Nothing -> drawChildren st rest pfx
    Just ai ->
      let line = drawNodeLine st aid ai (pfx ++ "├─")
          grandChildren = drawChildren st (filterChildren st (aiChildren ai)) (pfx ++ "│ ")
      in line : grandChildren ++ drawChildren st rest pfx

-- | Draw a single tree node line with inline duration
drawNodeLine :: AppState -> AgentId -> AgentInfo -> String -> Widget ResourceName
drawNodeLine st aid ai pfx =
  let icon = statusIcon (aiStatus ai)
      statusAttr' = statusColorAttr (aiStatus ai)
      label = withAttr statusAttr' $ txt (truncateText 45 (aiDescription ai))
      dur = durationText (aiStartTime ai) (aiLastTime ai)
      durWidget = if dur == "-" then emptyWidget
                  else withAttr dimAttr (txt (" [" <> dur <> "]"))
      isSelected = asSelectedId st == aid
      baseWidget = str pfx <+> icon <+> str " " <+> label <+> durWidget
  in if isSelected
     then visible $ withAttr selectedAttr baseWidget
     else baseWidget

-- | Map agent status to its color attribute
statusColorAttr :: AgentStatus -> AttrName
statusColorAttr Running   = runningAttr
statusColorAttr Completed = completedAttr
statusColorAttr Failed    = failedAttr

-- | Draw the detail panel for the selected agent
drawDetail :: AppState -> Widget ResourceName
drawDetail st = case Map.lookup (asSelectedId st) (asAgents st) of
  Nothing -> str "No agent selected"
  Just ai ->
    let icon = statusIcon (aiStatus ai)
        dur = durationText (aiStartTime ai) (aiLastTime ai)
        toks = T.pack $ formatTokens (aiInputTokens ai + aiOutputTokens ai)
        tools = T.pack $ show (aiToolCalls ai)
        headerLine = icon <+> str " " <+> txt (aiDescription ai)
                     <+> withAttr dimAttr (txt ("  [" <> dur <> "]  " <> toks <> " tokens  " <> tools <> " tools"))
        separator = withAttr dimAttr (str (replicate 50 '─'))
    in vBox $ [headerLine, separator] ++ outputWidgets (aiOutputParts ai)

-- | Render all output parts
outputWidgets :: [Text] -> [Widget ResourceName]
outputWidgets [] = [str "(no output)"]
outputWidgets parts = map txtWrap parts

-- | Draw the status bar (Python-style format)
drawStatusBar :: AppState -> Widget ResourceName
drawStatusBar st =
  let agents = Map.elems (asAgents st)
      total     = length agents
      running   = length $ filter (\a -> aiStatus a == Running) agents
      completed = length $ filter (\a -> aiStatus a == Completed) agents
      totalIn   = sum $ map aiInputTokens agents
      totalOut  = sum $ map aiOutputTokens agents
      totalTok  = totalIn + totalOut
      sessionName = T.pack $ take 12 $ takeBaseName (asFilePath st)
      elapsed = case asSessionStart st of
        Nothing -> ""
        Just start -> case aiLastTime =<< Map.lookup "main" (asAgents st) of
          Nothing -> ""
          Just end -> "  Elapsed: " <> T.unpack (formatDuration (diffUTCTime end start))
      hiddenIndicator = if not (asShowCompleted st) && completed > 0
                        then "  " ++ "Hidden: " ++ show completed
                        else ""
  in padLeftRight 1 $ hBox
    [ withAttr dimAttr (str "[")
    , withAttr labelAttr (txt sessionName)
    , withAttr dimAttr (str "]")
    , str "  "
    , str $ "Agents: " ++ show total
    , str "  "
    , withAttr runningAttr (str $ "Running: " ++ show running)
    , str "  "
    , withAttr completedAttr (str $ "Done: " ++ show completed)
    , str "  "
    , str $ "Tokens: " ++ formatTokens totalTok
    , str elapsed
    , str hiddenIndicator
    , padLeft Max $ str (T.unpack (asFilePath st & T.pack & abbreviatePath))
    ]

-- | Handle events
handleEvent :: IORef Int -> IORef (Map FilePath Int) -> ProcChecker -> BrickEvent ResourceName CustomEvent -> EventM ResourceName AppState ()
handleEvent posRef subPosRef checker ev = do
  st <- get
  if asPickerVisible st
    then handlePickerEvent posRef subPosRef ev
    else if asHelpVisible st
    then case ev of
      VtyEvent (Vty.EvKey _ _) -> modify $ \s -> s { asHelpVisible = False }
      AppEvent FileUpdated     -> handleFileUpdate posRef subPosRef
      AppEvent Tick            -> handleLivenessCheck checker
      _                        -> pure ()
    else case ev of
      VtyEvent (Vty.EvKey Vty.KEsc [])        -> halt
      VtyEvent (Vty.EvKey (Vty.KChar 'q') []) -> halt
      VtyEvent (Vty.EvKey (Vty.KChar '?') []) -> modify $ \s -> s { asHelpVisible = True }
      VtyEvent (Vty.EvKey (Vty.KChar 'c') []) -> modify toggleShowCompleted
      VtyEvent (Vty.EvKey (Vty.KChar 'h') []) -> modify $ \s -> s { asFocusedPanel = AgentTree }
      VtyEvent (Vty.EvKey (Vty.KChar 'l') []) -> modify $ \s -> s { asFocusedPanel = DetailPanel }
      VtyEvent (Vty.EvKey (Vty.KChar 'r') []) -> handleFileUpdate posRef subPosRef
      VtyEvent (Vty.EvKey (Vty.KChar 'p') []) -> openProjectPicker
      VtyEvent (Vty.EvKey (Vty.KChar 's') []) -> openSessionPicker
      VtyEvent (Vty.EvKey Vty.KUp [])         -> handleUpDown MoveUp
      VtyEvent (Vty.EvKey (Vty.KChar 'k') []) -> handleUpDown MoveUp
      VtyEvent (Vty.EvKey Vty.KDown [])       -> handleUpDown MoveDown
      VtyEvent (Vty.EvKey (Vty.KChar 'j') []) -> handleUpDown MoveDown
      VtyEvent (Vty.EvKey (Vty.KChar 'g') []) -> handleScrollTop
      VtyEvent (Vty.EvKey (Vty.KChar 'G') []) -> handleScrollBottom
      AppEvent FileUpdated                     -> handleFileUpdate posRef subPosRef
      AppEvent Tick                            -> handleLivenessCheck checker
      _                                        -> pure ()

data MoveDir = MoveUp | MoveDown

-- | Route up/down based on focused panel
handleUpDown :: MoveDir -> EventM ResourceName AppState ()
handleUpDown dir = do
  st <- get
  case asFocusedPanel st of
    AgentTree -> case dir of
      MoveUp   -> modify moveUp
      MoveDown -> modify moveDown
    _ -> do
      let vp = viewportScroll DetailViewport
      case dir of
        MoveUp   -> vScrollBy vp (-1)
        MoveDown -> vScrollBy vp 1

-- | Scroll detail to top
handleScrollTop :: EventM ResourceName AppState ()
handleScrollTop = do
  st <- get
  case asFocusedPanel st of
    DetailPanel -> vScrollToBeginning (viewportScroll DetailViewport)
    _ -> pure ()

-- | Scroll detail to bottom
handleScrollBottom :: EventM ResourceName AppState ()
handleScrollBottom = do
  st <- get
  case asFocusedPanel st of
    DetailPanel -> vScrollToEnd (viewportScroll DetailViewport)
    _ -> pure ()

-- | Open the project picker
openProjectPicker :: EventM ResourceName AppState ()
openProjectPicker = do
  projects <- liftIO discoverProjects
  modify $ \s -> s { asPickerVisible = True
                   , asPickerMode = PickerProjects
                   , asPickerItems = projects
                   , asPickerIndex = 0 }

-- | Open session picker for current project
openSessionPicker :: EventM ResourceName AppState ()
openSessionPicker = do
  st <- get
  let sessionDir = takeDirectory (asFilePath st)
  sessions <- liftIO $ discoverSessions sessionDir
  modify $ \s -> s { asPickerVisible = True
                   , asPickerMode = PickerSessions
                   , asPickerItems = sessions
                   , asPickerIndex = 0 }

-- | Handle picker events
handlePickerEvent :: IORef Int -> IORef (Map FilePath Int) -> BrickEvent ResourceName CustomEvent -> EventM ResourceName AppState ()
handlePickerEvent posRef subPosRef ev = case ev of
  VtyEvent (Vty.EvKey Vty.KEsc [])        -> pickerBack
  VtyEvent (Vty.EvKey (Vty.KChar 'q') []) -> modify $ \s -> s { asPickerVisible = False }
  VtyEvent (Vty.EvKey (Vty.KChar 'h') []) -> pickerBack
  VtyEvent (Vty.EvKey Vty.KUp [])         -> modify pickerUp
  VtyEvent (Vty.EvKey (Vty.KChar 'k') []) -> modify pickerUp
  VtyEvent (Vty.EvKey Vty.KDown [])       -> modify pickerDown
  VtyEvent (Vty.EvKey (Vty.KChar 'j') []) -> modify pickerDown
  VtyEvent (Vty.EvKey Vty.KEnter [])      -> handlePickerSelect posRef subPosRef
  VtyEvent (Vty.EvKey (Vty.KChar 'l') []) -> handlePickerSelect posRef subPosRef
  AppEvent FileUpdated                     -> handleFileUpdate posRef subPosRef
  _                                        -> pure ()

-- | Go back one level or close picker
pickerBack :: EventM ResourceName AppState ()
pickerBack = do
  st <- get
  case asPickerMode st of
    PickerSessions -> openProjectPicker  -- back to projects
    PickerProjects -> modify $ \s -> s { asPickerVisible = False }

pickerUp :: AppState -> AppState
pickerUp st = st { asPickerIndex = max 0 (asPickerIndex st - 1) }

pickerDown :: AppState -> AppState
pickerDown st =
  let maxIdx = max 0 (length (asPickerItems st) - 1)
  in st { asPickerIndex = min maxIdx (asPickerIndex st + 1) }

-- | Handle picker selection based on current mode
handlePickerSelect :: IORef Int -> IORef (Map FilePath Int) -> EventM ResourceName AppState ()
handlePickerSelect posRef subPosRef = do
  st <- get
  let items = asPickerItems st
      idx = asPickerIndex st
  case drop idx items of
    [] -> pure ()
    ((_label, path):_) -> case asPickerMode st of
      PickerProjects -> do
        -- Drill into sessions for this project
        sessions <- liftIO $ discoverSessions path
        modify $ \s -> s { asPickerMode = PickerSessions
                         , asPickerItems = sessions
                         , asPickerIndex = 0 }
      PickerSessions -> do
        -- Load the selected session
        content <- liftIO $ BL.readFile path
        subContents <- liftIO $ loadSubagentFiles path
        let newState = buildInitialState path content subContents
        liftIO $ writeIORef posRef (asFilePos newState)
        liftIO $ writeIORef subPosRef Map.empty
        put newState

-- | Handle file update: read new lines from main and subagent files
handleFileUpdate :: IORef Int -> IORef (Map FilePath Int) -> EventM ResourceName AppState ()
handleFileUpdate posRef subPosRef = do
  st <- get
  -- Read main file
  newContent <- liftIO $ readNewLines (asFilePath st) posRef
  let events = parseJsonlLines newContent
      st1 = foldl processEvent st events
  -- Read subagent files (pass filepath for agent→file mapping)
  subUpdates <- liftIO $ readNewSubagentLines (asFilePath st) subPosRef
  let st2 = foldl (\s (fp, content) -> processSubagentContent s fp content) st1 subUpdates
  let st3 = st2 { asFlatOrder = flattenTreeFiltered st2 }
  put st3
  -- Auto-scroll detail viewport to bottom on new content
  when (not (null events) || not (null subUpdates)) $
    vScrollToEnd (viewportScroll DetailViewport)

-- | Check liveness of running agents via /proc filesystem.
-- Agents whose .jsonl files are no longer held open by Claude processes
-- are marked as Completed.
handleLivenessCheck :: ProcChecker -> EventM ResourceName AppState ()
handleLivenessCheck checker = do
  st <- get
  let agentFiles = asAgentFiles st
      -- Only check files for Running agents (skip "main")
      runningFiles = Map.fromList
        [ (aid, fp)
        | (aid, fp) <- Map.toList agentFiles
        , aid /= "main"
        , Just ai <- [Map.lookup aid (asAgents st)]
        , aiStatus ai == Running
        ]
  if Map.null runningFiles then pure ()
  else do
    let targetSet = Set.fromList (Map.elems runningFiles)
    openFiles <- liftIO $ checkOpenFiles checker targetSet
    now <- liftIO getCurrentTime
    -- Mark agents whose files are closed as Completed
    let deadAgents = [ aid | (aid, fp) <- Map.toList runningFiles
                           , not (fp `Set.member` openFiles) ]
    if null deadAgents then pure ()
    else do
      let updateDead s aid = case Map.lookup aid (asAgents s) of
            Just ai -> s { asAgents = Map.insert aid
                             (ai { aiStatus = Completed, aiLastTime = Just now })
                             (asAgents s) }
            Nothing -> s
          st' = foldl updateDead st deadAgents
          st'' = st' { asFlatOrder = flattenTreeFiltered st' }
      put st''

-- | Move selection up in the tree
moveUp :: AppState -> AppState
moveUp st =
  let order = asFlatOrder st
      cur   = asSelectedId st
  in case break (== cur) order of
    ([], _)    -> st
    (prev, _)  -> st { asSelectedId = last prev }

-- | Move selection down in the tree
moveDown :: AppState -> AppState
moveDown st =
  let order = asFlatOrder st
      cur   = asSelectedId st
  in case dropWhile (/= cur) order of
    []     -> st
    [_]    -> st
    (_:n:_) -> st { asSelectedId = n }

-- | Toggle showing completed agents, adjusting selection if needed
toggleShowCompleted :: AppState -> AppState
toggleShowCompleted st =
  let st' = st { asShowCompleted = not (asShowCompleted st) }
      newOrder = flattenTreeFiltered st'
      selected = if asSelectedId st' `elem` newOrder
                 then asSelectedId st'
                 else "main"
  in st' { asFlatOrder = newOrder, asSelectedId = selected }

-- | Attribute map
theAttrMap :: AttrMap
theAttrMap = attrMap Vty.defAttr
  [ (selectedAttr,    Vty.black `on` Vty.cyan)
  , (runningAttr,     fg Vty.yellow)
  , (completedAttr,   fg Vty.green)
  , (failedAttr,      fg Vty.red)
  , (dimAttr,         fg (Vty.rgbColor (128 :: Int) 128 128))
  , (labelAttr,       fg Vty.cyan)
  , (focusedLabelAttr, fg Vty.white `Vty.withStyle` Vty.bold)
  ]

selectedAttr, runningAttr, completedAttr, failedAttr, dimAttr, labelAttr, focusedLabelAttr :: AttrName
selectedAttr    = attrName "selected"
runningAttr     = attrName "running"
completedAttr   = attrName "completed"
failedAttr      = attrName "failed"
dimAttr         = attrName "dim"
labelAttr       = attrName "label"
focusedLabelAttr = attrName "focusedLabel"

-- | Status icon widget
statusIcon :: AgentStatus -> Widget n
statusIcon Running   = withAttr runningAttr (str "⟳")
statusIcon Completed = withAttr completedAttr (str "✓")
statusIcon Failed    = withAttr failedAttr (str "✗")

-- | Duration text
durationText :: Maybe UTCTime -> Maybe UTCTime -> Text
durationText (Just start) (Just end) = formatDuration (diffUTCTime end start)
durationText _ _ = "-"

-- | Format a duration
formatDuration :: NominalDiffTime -> Text
formatDuration dt =
  let totalSecs = floor dt :: Int
      (totalMins, secs) = totalSecs `divMod` 60
      (hours, mins) = totalMins `divMod` 60
  in T.pack $ if hours > 0
     then show hours ++ "h " ++ show mins ++ "m " ++ show secs ++ "s"
     else if mins > 0
     then show mins ++ "m " ++ show secs ++ "s"
     else show secs ++ "s"

-- | Format token count with K suffix
formatTokens :: Int -> String
formatTokens n
  | n >= 1000000 = let tenths = n `div` 100000
                       whole = tenths `div` 10
                       frac = tenths `mod` 10
                   in show whole ++ "." ++ show frac ++ "M"
  | n >= 1000    = show (n `div` 1000) ++ "k"
  | otherwise    = show n

-- | Truncate text to a maximum length
truncateText :: Int -> Text -> Text
truncateText maxLen t
  | T.length t <= maxLen = t
  | otherwise = T.take (maxLen - 1) t <> "…"

-- | Abbreviate a file path for display
abbreviatePath :: Text -> Text
abbreviatePath p =
  let parts = T.splitOn "/" p
  in if length parts > 3
     then ".../" <> T.intercalate "/" (drop (length parts - 3) parts)
     else p

