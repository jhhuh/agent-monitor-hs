module AgentMonitor.Watcher
  ( startWatcher
  , findNewestJsonl
  , readNewLines
  , readNewSubagentLines
  , discoverProjects
  , discoverSessions
  ) where

import Brick.BChan (BChan, writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (try, SomeException)
import Control.Monad (forever, when, void, forM, filterM)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (sortOn, nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down(..))
import System.Directory
import System.FilePath
import System.IO
import System.Posix.User (getEffectiveUserID)

import AgentMonitor.ProcChecker (ProcChecker, newProcChecker)
import AgentMonitor.Types (CustomEvent(..))

-- | Start background threads: file polling (500ms) and liveness tick (2s).
-- Returns IORefs for file offsets and a ProcChecker for liveness detection.
startWatcher :: BChan CustomEvent -> FilePath -> Int -> IO (IORef Int, IORef (Map FilePath Int), ProcChecker)
startWatcher chan fp initialPos = do
  posRef <- newIORef initialPos
  subPosRef <- newIORef Map.empty
  checker <- newProcChecker
  let sessionDir = dropExtension fp
      subagentDir = sessionDir </> "subagents"
  -- File polling thread (500ms)
  void $ forkIO $ forever $ do
    threadDelay 500000
    result <- try @SomeException $ do
      mainGrew <- do
        size <- getFileSize fp
        pos <- readIORef posRef
        pure (size > fromIntegral pos)
      subGrew <- do
        exists <- doesDirectoryExist subagentDir
        if not exists then pure False
        else do
          entries <- listDirectory subagentDir
          let jsonlFiles = map (subagentDir </>)
                         $ filter (\f -> takeExtension f == ".jsonl") entries
          subPos <- readIORef subPosRef
          anyGrew <- forM jsonlFiles $ \sf -> do
            size <- getFileSize sf
            let curPos = Map.findWithDefault 0 sf subPos
            pure (size > fromIntegral curPos)
          pure (or anyGrew)
      when (mainGrew || subGrew) $
        writeBChan chan FileUpdated
    case result of
      Left _   -> pure ()
      Right () -> pure ()
  -- Liveness tick thread (2s)
  void $ forkIO $ forever $ do
    threadDelay 2000000
    writeBChan chan Tick
  pure (posRef, subPosRef, checker)

-- | Read new lines from the file starting at the given offset.
-- Returns the new content and updates the offset.
readNewLines :: FilePath -> IORef Int -> IO BL.ByteString
readNewLines fp posRef = do
  pos <- readIORef posRef
  h <- openBinaryFile fp ReadMode
  hSeek h AbsoluteSeek (fromIntegral pos)
  content <- BS.hGetContents h  -- strict read, closes handle
  let newPos = pos + BS.length content
  writeIORef posRef newPos
  pure (BL.fromStrict content)

-- | Read new lines from all subagent files.
-- Returns list of (filepath, new content) pairs.
readNewSubagentLines :: FilePath -> IORef (Map FilePath Int) -> IO [(FilePath, BL.ByteString)]
readNewSubagentLines fp subPosRef = do
  let sessionDir = dropExtension fp
      subagentDir = sessionDir </> "subagents"
  exists <- doesDirectoryExist subagentDir
  if not exists then pure []
  else do
    entries <- listDirectory subagentDir
    let jsonlFiles = map (subagentDir </>)
                   $ filter (\f -> takeExtension f == ".jsonl") entries
    subPos <- readIORef subPosRef
    results <- forM jsonlFiles $ \sf -> do
      let curPos = Map.findWithDefault 0 sf subPos
      result <- try @SomeException $ do
        h <- openBinaryFile sf ReadMode
        hSeek h AbsoluteSeek (fromIntegral curPos)
        content <- BS.hGetContents h
        let newPos = curPos + BS.length content
        modifyIORef' subPosRef (Map.insert sf newPos)
        pure content
      case result of
        Left _  -> pure Nothing
        Right c -> if BS.null c then pure Nothing
                   else pure (Just (sf, BL.fromStrict c))
    pure (mapMaybe id results)

-- | Discover projects for the picker.
-- Returns (display_label, project_dir_path) pairs sorted by mtime (newest first).
discoverProjects :: IO [(String, FilePath)]
discoverProjects = do
  home <- getHomeDirectory
  cwd <- getCurrentDirectory
  let claudeDir = home </> ".claude" </> "projects"
      currentProjectDirName = pathToProjectDir cwd
  exists <- doesDirectoryExist claudeDir
  if not exists then pure []
  else do
    entries <- listDirectory claudeDir
    dirs <- filterM (doesDirectoryExist . (claudeDir </>)) entries
    results <- forM dirs $ \dirName -> do
      let dirPath = claudeDir </> dirName
      jsonls <- findJsonlInDir dirPath
      case jsonls of
        [] -> pure Nothing
        _  -> do
          -- Get newest mtime for sorting
          mtimes <- mapM getModificationTime jsonls
          let newestMtime = maximum mtimes
              displayPath = dirToPath dirName
              marker = if dirName == currentProjectDirName then " *" else ""
              label = displayPath ++ marker ++ "  (" ++ show (length jsonls) ++ " sessions)"
          pure (Just (label, dirPath, newestMtime))
    let validResults = mapMaybe id results
        sorted = sortOn (\(_,_,t) -> Down t) validResults
    pure [(l, p) | (l, p, _) <- sorted]

-- | Discover sessions within a project directory.
-- Returns (display_label, jsonl_path) pairs sorted by mtime (newest first).
-- Sessions with running agents (detected via /proc) are marked.
discoverSessions :: FilePath -> IO [(String, FilePath)]
discoverSessions projectDir = do
  jsonls <- findJsonlInDir projectDir
  results <- forM jsonls $ \fp -> do
    mtime <- getModificationTime fp
    let uuid = take 8 $ takeBaseName fp
        label = uuid ++ "..."
    pure (label, fp, mtime)
  let sorted = sortOn (\(_,_,t) -> Down t) results
  pure [(l, p) | (l, p, _) <- sorted]

-- | Encode a filesystem path as a Claude project directory name.
-- "/home/user/project" → "-home-user-project"
pathToProjectDir :: FilePath -> String
pathToProjectDir = map (\c -> if c == '/' then '-' else c)

-- | Convert a project directory name back to a filesystem path.
-- "-home-user-project" → "/home/user/project"
dirToPath :: String -> String
dirToPath [] = "/"
dirToPath ('-':rest) = '/' : go rest
  where
    go [] = []
    go ('-':cs) = '/' : go cs
    go (c:cs) = c : go cs
dirToPath s = s

-- | Find the newest .jsonl file, preferring running sessions in the current project.
findNewestJsonl :: IO (Maybe FilePath)
findNewestJsonl = do
  home <- getHomeDirectory
  cwd <- getCurrentDirectory
  let claudeDir = home </> ".claude" </> "projects"
      projectDirName = pathToProjectDir cwd
      currentProjectDir = claudeDir </> projectDirName
  exists <- doesDirectoryExist claudeDir
  if not exists
    then pure Nothing
    else do
      dirExists <- doesDirectoryExist currentProjectDir
      if not dirExists
        then do
          projectDirs <- listDirectoryAbs claudeDir
          dirs <- filterM doesDirectoryExist projectDirs
          newestJsonlIn dirs
        else do
          -- Check for running session via /tmp symlinks
          running <- findRunningSession currentProjectDir
          case running of
            Just path -> pure (Just path)
            Nothing -> do
              result <- newestJsonlIn [currentProjectDir]
              case result of
                Just _  -> pure result
                Nothing -> do
                  projectDirs <- listDirectoryAbs claudeDir
                  dirs <- filterM doesDirectoryExist projectDirs
                  newestJsonlIn dirs

-- | Check /tmp/claude-$UID/<project>/tasks/ for active subagent symlinks.
findRunningSession :: FilePath -> IO (Maybe FilePath)
findRunningSession projectDir = do
  result <- try @SomeException $ do
    uid <- getEffectiveUserID
    cwd <- getCurrentDirectory
    let projectDirName = pathToProjectDir cwd
        tasksDir = "/tmp" </> ("claude-" ++ show uid) </> projectDirName </> "tasks"
    tasksExists <- doesDirectoryExist tasksDir
    if not tasksExists
      then pure Nothing
      else do
        entries <- listDirectory tasksDir
        let outputFiles = filter (\f -> takeExtension f == ".output") entries
        sessionIds <- fmap (nub . mapMaybe id) $ mapM (extractSessionId tasksDir) outputFiles
        case sessionIds of
          []    -> pure Nothing
          (sid:_) -> do
            let jsonlPath = projectDir </> sid <.> "jsonl"
            jsonlExists <- doesFileExist jsonlPath
            pure $ if jsonlExists then Just jsonlPath else Nothing
  case result of
    Left _  -> pure Nothing
    Right v -> pure v

-- | Extract session UUID from a symlink target in the tasks directory.
extractSessionId :: FilePath -> FilePath -> IO (Maybe String)
extractSessionId tasksDir entry = do
  result <- try @SomeException $ do
    target <- getSymbolicLinkTarget (tasksDir </> entry)
    let parts = splitDirectories target
        pairs = zip parts (drop 1 parts)
    pure $ case [p | (p, next) <- pairs, next == "subagents"] of
      (sid:_) -> Just sid
      []      -> Nothing
  case result of
    Left _  -> pure Nothing
    Right v -> pure v

-- | Find the newest .jsonl file across the given directories
newestJsonlIn :: [FilePath] -> IO (Maybe FilePath)
newestJsonlIn dirs = do
  jsonlFiles <- concat <$> mapM findJsonlInDir dirs
  if null jsonlFiles
    then pure Nothing
    else do
      withTimes <- mapM (\f -> do
        t <- getModificationTime f
        pure (f, t)) jsonlFiles
      let sorted = sortOn (Down . snd) withTimes
      case sorted of
        []        -> pure Nothing
        ((f,_):_) -> pure (Just f)

-- | List directory contents with absolute paths
listDirectoryAbs :: FilePath -> IO [FilePath]
listDirectoryAbs dir = do
  entries <- listDirectory dir
  pure $ map (dir </>) entries

-- | Find .jsonl files in a directory
findJsonlInDir :: FilePath -> IO [FilePath]
findJsonlInDir dir = do
  entries <- listDirectory dir
  pure $ map (dir </>) $ filter (\f -> takeExtension f == ".jsonl") entries
