module AgentMonitor.Watcher
  ( startWatcher
  , findNewestJsonl
  , readNewLines
  ) where

import Brick.BChan (BChan, writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (try, SomeException)
import Control.Monad (forever, when, void)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (sortOn)
import Data.Ord (Down(..))
import System.Directory
import System.FilePath
import System.IO

import AgentMonitor.Types (CustomEvent(..))

-- | Start a background thread that polls the file for new data.
-- Sends FileUpdated events when the file grows.
-- Returns an IORef tracking the current byte offset.
startWatcher :: BChan CustomEvent -> FilePath -> Int -> IO (IORef Int)
startWatcher chan fp initialPos = do
  posRef <- newIORef initialPos
  void $ forkIO $ forever $ do
    threadDelay 500000  -- 500ms
    result <- try @SomeException $ do
      size <- getFileSize fp
      pos <- readIORef posRef
      when (size > fromIntegral pos) $
        writeBChan chan FileUpdated
    case result of
      Left _   -> pure ()
      Right () -> pure ()
  pure posRef

-- | Read new lines from the file starting at the given offset.
-- Returns the new content and the updated offset.
readNewLines :: FilePath -> IORef Int -> IO BL.ByteString
readNewLines fp posRef = do
  pos <- readIORef posRef
  h <- openBinaryFile fp ReadMode
  hSeek h AbsoluteSeek (fromIntegral pos)
  content <- BS.hGetContents h  -- strict read, closes handle
  let newPos = pos + BS.length content
  writeIORef posRef newPos
  pure (BL.fromStrict content)

-- | Find the newest .jsonl file across all Claude project directories
findNewestJsonl :: IO (Maybe FilePath)
findNewestJsonl = do
  home <- getHomeDirectory
  let claudeDir = home </> ".claude" </> "projects"
  exists <- doesDirectoryExist claudeDir
  if not exists
    then pure Nothing
    else do
      projectDirs <- listDirectoryAbs claudeDir
      dirs <- myFilterM doesDirectoryExist projectDirs
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

-- | Monadic filter (to avoid importing Control.Monad.Extra)
myFilterM :: Monad m => (a -> m Bool) -> [a] -> m [a]
myFilterM _ []     = pure []
myFilterM p (x:xs) = do
  keep <- p x
  rest <- myFilterM p xs
  pure $ if keep then x : rest else rest
