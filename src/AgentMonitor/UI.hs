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
import Data.IORef (IORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, NominalDiffTime, diffUTCTime)
import Graphics.Vty qualified as Vty
import Graphics.Vty.CrossPlatform (mkVty)

import AgentMonitor.Types
import AgentMonitor.Parser (parseJsonlLines, processEvent)
import AgentMonitor.Watcher (startWatcher, readNewLines)

-- | Run the brick application
runApp :: AppState -> IO AppState
runApp initialState = do
  chan <- newBChan 10
  posRef <- startWatcher chan (asFilePath initialState) (asFilePos initialState)
  let buildVty = mkVty Vty.defaultConfig
  initialVty <- buildVty
  customMain initialVty buildVty (Just chan) (app posRef) initialState

-- | The brick App definition
app :: IORef Int -> App AppState CustomEvent ResourceName
app posRef = App
  { appDraw         = drawUI
  , appChooseCursor = neverShowCursor
  , appHandleEvent  = handleEvent posRef
  , appStartEvent   = pure ()
  , appAttrMap      = const theAttrMap
  }

-- | Draw the UI
drawUI :: AppState -> [Widget ResourceName]
drawUI st =
  let base = withBorderStyle unicode $
        vBox
          [ hBox
              [ borderWithLabel (str " Agent Tree ") $
                  hLimitPercent 40 $
                  padRight Max $
                  viewport AgentTree Vertical $
                  drawTree st
              , borderWithLabel (str " Detail Panel ") $
                  padRight Max $
                  padBottom Max $
                  drawDetail st
              ]
          , hBorder
          , drawStatusBar st
          ]
  in if asHelpVisible st
     then [centerLayer helpWidget, base]
     else [base]

-- | Help overlay widget listing all keybindings
helpWidget :: Widget ResourceName
helpWidget =
  withBorderStyle unicode $
    borderWithLabel (str " Help ") $
      padLeftRight 2 $ padTopBottom 1 $
        hCenter $ vBox
          [ str "j / Down    Move selection down"
          , str "k / Up      Move selection up"
          , str "?           Toggle this help"
          , str "q / Esc     Quit"
          ]

-- | Draw the agent tree
drawTree :: AppState -> Widget ResourceName
drawTree st = case Map.lookup "main" (asAgents st) of
  Nothing -> str "(empty)"
  Just mainAi ->
    let mainWidget = drawNodeLine st "main" mainAi ""
        children = aiChildren mainAi
        childWidgets = drawChildren st children "  "
    in vBox (mainWidget : childWidgets)

-- | Draw a list of sibling children with proper tree connectors
drawChildren :: AppState -> [AgentId] -> String -> [Widget ResourceName]
drawChildren _ [] _ = []
drawChildren st [aid] pfx =
  -- Last child uses └── connector
  case Map.lookup aid (asAgents st) of
    Nothing -> []
    Just ai ->
      let line = drawNodeLine st aid ai (pfx ++ "└─")
          grandChildren = drawChildren st (aiChildren ai) (pfx ++ "  ")
      in line : grandChildren
drawChildren st (aid:rest) pfx =
  -- Non-last child uses ├── connector
  case Map.lookup aid (asAgents st) of
    Nothing -> drawChildren st rest pfx
    Just ai ->
      let line = drawNodeLine st aid ai (pfx ++ "├─")
          grandChildren = drawChildren st (aiChildren ai) (pfx ++ "│ ")
      in line : grandChildren ++ drawChildren st rest pfx

-- | Draw a single tree node line
drawNodeLine :: AppState -> AgentId -> AgentInfo -> String -> Widget ResourceName
drawNodeLine st aid ai pfx =
  let icon = statusIcon (aiStatus ai)
      label = txt (truncateText 30 (aiDescription ai))
      isSelected = asSelectedId st == aid
      baseWidget = str pfx <+> icon <+> str " " <+> label
  in if isSelected
     then visible $ withAttr selectedAttr baseWidget
     else baseWidget

-- | Draw the detail panel for the selected agent
drawDetail :: AppState -> Widget ResourceName
drawDetail st = case Map.lookup (asSelectedId st) (asAgents st) of
  Nothing -> str "No agent selected"
  Just ai -> vBox
    [ labeledField "Agent" (aiDescription ai)
    , labeledField "Status" (statusText (aiStatus ai))
    , labeledField "Duration" (durationText (aiStartTime ai) (aiLastTime ai))
    , labeledField "Tokens" (tokenText (aiInputTokens ai) (aiOutputTokens ai))
    , labeledField "Tool calls" (T.pack $ show (aiToolCalls ai))
    , str " "
    , withAttr dimAttr (str "Last output:")
    , padLeft (Pad 1) $ txtWrap (truncateText 500 (aiLastOutput ai))
    ]

-- | Draw the status bar
drawStatusBar :: AppState -> Widget ResourceName
drawStatusBar st =
  let agents = Map.elems (asAgents st)
      running   = length $ filter (\a -> aiStatus a == Running) agents
      completed = length $ filter (\a -> aiStatus a == Completed) agents
      failed    = length $ filter (\a -> aiStatus a == Failed) agents
      totalIn   = sum $ map aiInputTokens agents
      totalOut  = sum $ map aiOutputTokens agents
      totalTok  = totalIn + totalOut
  in padLeftRight 1 $ hBox
    [ withAttr runningAttr (str $ "Running: " ++ show running)
    , str "  "
    , withAttr completedAttr (str $ "Completed: " ++ show completed)
    , str "  "
    , withAttr failedAttr (str $ "Failed: " ++ show failed)
    , str "  "
    , str $ "Tokens: " ++ formatTokens totalTok
    , padLeft Max $ str (T.unpack (asFilePath st & T.pack & abbreviatePath))
    ]

-- | Handle events
handleEvent :: IORef Int -> BrickEvent ResourceName CustomEvent -> EventM ResourceName AppState ()
handleEvent posRef ev = do
  st <- get
  if asHelpVisible st
    then case ev of
      VtyEvent (Vty.EvKey _ _) -> modify $ \s -> s { asHelpVisible = False }
      AppEvent FileUpdated     -> handleFileUpdate posRef
      _                        -> pure ()
    else case ev of
      VtyEvent (Vty.EvKey Vty.KEsc [])        -> halt
      VtyEvent (Vty.EvKey (Vty.KChar 'q') []) -> halt
      VtyEvent (Vty.EvKey (Vty.KChar '?') []) -> modify $ \s -> s { asHelpVisible = True }
      VtyEvent (Vty.EvKey Vty.KUp [])         -> modify moveUp
      VtyEvent (Vty.EvKey (Vty.KChar 'k') []) -> modify moveUp
      VtyEvent (Vty.EvKey Vty.KDown [])       -> modify moveDown
      VtyEvent (Vty.EvKey (Vty.KChar 'j') []) -> modify moveDown
      AppEvent FileUpdated                     -> handleFileUpdate posRef
      _                                        -> pure ()

-- | Handle file update: read new lines and process them
handleFileUpdate :: IORef Int -> EventM ResourceName AppState ()
handleFileUpdate posRef = do
  st <- get
  newContent <- liftIO $ readNewLines (asFilePath st) posRef
  let events = parseJsonlLines newContent
      st' = foldl processEvent st events
      st'' = st' { asFlatOrder = flattenTreeFromState st' }
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
    [_]    -> st  -- at the end
    (_:n:_) -> st { asSelectedId = n }

-- | Flatten tree from state (re-export helper)
flattenTreeFromState :: AppState -> [AgentId]
flattenTreeFromState st =
  let go aid = case Map.lookup aid (asAgents st) of
        Nothing -> [aid]
        Just ai -> aid : concatMap go (aiChildren ai)
  in go "main"

-- | Attribute map
theAttrMap :: AttrMap
theAttrMap = attrMap Vty.defAttr
  [ (selectedAttr,  Vty.black `on` Vty.cyan)
  , (runningAttr,   fg Vty.yellow)
  , (completedAttr, fg Vty.green)
  , (failedAttr,    fg Vty.red)
  , (dimAttr,       fg (Vty.rgbColor (128 :: Int) 128 128))
  , (labelAttr,     fg Vty.cyan)
  ]

selectedAttr, runningAttr, completedAttr, failedAttr, dimAttr, labelAttr :: AttrName
selectedAttr  = attrName "selected"
runningAttr   = attrName "running"
completedAttr = attrName "completed"
failedAttr    = attrName "failed"
dimAttr       = attrName "dim"
labelAttr     = attrName "label"

-- | Status icon widget
statusIcon :: AgentStatus -> Widget n
statusIcon Running   = withAttr runningAttr (str "⟳")
statusIcon Completed = withAttr completedAttr (str "✓")
statusIcon Failed    = withAttr failedAttr (str "✗")

-- | Status text
statusText :: AgentStatus -> Text
statusText Running   = "running"
statusText Completed = "completed"
statusText Failed    = "failed"

-- | Duration text
durationText :: Maybe UTCTime -> Maybe UTCTime -> Text
durationText (Just start) (Just end) = formatDuration (diffUTCTime end start)
durationText _ _ = "-"

-- | Format a duration
formatDuration :: NominalDiffTime -> Text
formatDuration dt =
  let totalSecs = floor dt :: Int
      mins = totalSecs `div` 60
      secs = totalSecs `mod` 60
  in if mins > 0
     then T.pack $ show mins ++ "m " ++ show secs ++ "s"
     else T.pack $ show secs ++ "s"

-- | Token text
tokenText :: Int -> Int -> Text
tokenText inp out = T.pack $
  formatTokens (inp + out) ++ " total (" ++ formatTokens inp ++ " in, " ++ formatTokens out ++ " out)"

-- | Format token count with K suffix
formatTokens :: Int -> String
formatTokens n
  | n >= 1000000 = show (n `div` 1000) ++ "k"
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

-- | Helper for labeled fields in the detail panel
labeledField :: Text -> Text -> Widget n
labeledField label value =
  withAttr labelAttr (txt (label <> ": ")) <+> txt value

