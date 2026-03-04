-- | Checks if agent files are held open by Claude Code processes.
--
-- Finds 'claude' processes via /proc/*/cmdline, walks the process tree
-- to include children, then checks those PIDs' file descriptors.
-- Caches the PID set; rescans the process tree every 10 seconds.
module AgentMonitor.ProcChecker
  ( ProcChecker
  , newProcChecker
  , checkOpenFiles
  ) where

import Control.Exception (try, SomeException)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO (hClose, hSetBinaryMode, openFile, IOMode(ReadMode))
import System.Posix.Files (readSymbolicLink)

-- | Opaque handle to the process checker with cached PID state.
newtype ProcChecker = ProcChecker (IORef ProcState)

data ProcState = ProcState
  { psClaudePids :: Set String   -- cached PIDs as strings (for /proc path construction)
  , psLastScanNs :: Word64       -- monotonic nanoseconds of last tree scan
  }

-- | Create a new ProcChecker with empty cache.
newProcChecker :: IO ProcChecker
newProcChecker = ProcChecker <$> newIORef (ProcState Set.empty 0)

-- | Return the subset of target file paths currently held open by Claude processes.
-- Rescans the process tree if the cache is older than 10 seconds.
checkOpenFiles :: ProcChecker -> Set FilePath -> IO (Set FilePath)
checkOpenFiles (ProcChecker ref) targets
  | Set.null targets = pure Set.empty
  | otherwise = do
      nowNs <- getMonotonicTimeNSec
      st <- readIORef ref
      -- Rescan process tree every 10 seconds or if no cached PIDs
      pids <- if Set.null (psClaudePids st) || (nowNs - psLastScanNs st) > 10_000_000_000
        then do
          newPids <- findClaudeTree
          writeIORef ref (ProcState newPids nowNs)
          pure newPids
        else pure (psClaudePids st)
      -- Check file descriptors of Claude processes
      (found, dead) <- checkFds pids targets
      -- Remove dead PIDs from cache
      if Set.null dead then pure ()
      else modifyIORef' ref (\s -> s { psClaudePids = psClaudePids s `Set.difference` dead })
      pure found

-- | Check /proc/<pid>/fd/ symlinks for each PID, returning
-- (files that are open, PIDs that are dead).
checkFds :: Set String -> Set FilePath -> IO (Set FilePath, Set String)
checkFds pids targets = go (Set.toList pids) Set.empty Set.empty
  where
    go [] found dead = pure (found, dead)
    go (pid:rest) found dead = do
      let fdDir = "/proc" </> pid </> "fd"
      result <- try @SomeException $ listDirectory fdDir
      case result of
        Left _ -> go rest found (Set.insert pid dead)  -- process died
        Right entries -> do
          found' <- checkEntries fdDir entries found
          go rest found' dead

    checkEntries _ [] found = pure found
    checkEntries fdDir (entry:rest) found = do
      result <- try @SomeException $ readSymbolicLink (fdDir </> entry)
      case result of
        Left _     -> checkEntries fdDir rest found
        Right link ->
          let found' = if link `Set.member` targets
                       then Set.insert link found
                       else found
          in checkEntries fdDir rest found'

-- | Find all PIDs in the Claude Code process tree.
-- 1. Scan /proc/*/cmdline for "claude"
-- 2. Build parent→children map from /proc/*/stat
-- 3. Walk descendants of Claude root PIDs
findClaudeTree :: IO (Set String)
findClaudeTree = do
  result <- try @SomeException $ listDirectory "/proc"
  case result of
    Left _ -> pure Set.empty
    Right entries -> do
      let pidEntries = filter isNumeric entries
      -- Build children map and find Claude roots in one pass
      (claudeRoots, childrenMap) <- scanProcs pidEntries
      -- Walk descendants
      pure (walkDescendants claudeRoots childrenMap)

-- | Scan all /proc entries to find Claude roots and build parent→children map.
scanProcs :: [String] -> IO (Set String, Map String [String])
scanProcs pids = go pids Set.empty Map.empty
  where
    go [] roots children = pure (roots, children)
    go (pid:rest) roots children = do
      -- Check cmdline for "claude"
      isClaude <- checkCmdline pid
      -- Read PPID from stat
      mppid <- readPPID pid
      let roots' = if isClaude then Set.insert pid roots else roots
          children' = case mppid of
            Nothing   -> children
            Just ppid -> Map.insertWith (++) ppid [pid] children
      go rest roots' children'

-- | Check if /proc/<pid>/cmdline contains "claude".
checkCmdline :: String -> IO Bool
checkCmdline pid = do
  result <- try @SomeException $ do
    h <- openFile ("/proc" </> pid </> "cmdline") ReadMode
    hSetBinaryMode h True
    content <- BS.hGet h 512
    hClose h
    pure content
  case result of
    Left _  -> pure False
    Right c -> pure (claudeBytes `BS.isInfixOf` c)
  where
    -- "claude" as raw bytes: [99,108,97,117,100,101]
    claudeBytes = BS.pack [99,108,97,117,100,101]

-- | Read PPID from /proc/<pid>/stat.
-- Format: "pid (comm) state ppid ..."
-- comm can contain spaces/parens, so find last ')' then parse.
readPPID :: String -> IO (Maybe String)
readPPID pid = do
  result <- try @SomeException $ do
    h <- openFile ("/proc" </> pid </> "stat") ReadMode
    content <- BS.hGet h 256
    hClose h
    pure content
  case result of
    Left _  -> pure Nothing
    Right c ->
      -- Find last ')' in the stat line, then skip " state " to get ppid
      let bs = c
          -- Find index of last ')'
          rparenIdx = BS.elemIndexEnd 0x29 bs  -- ')' = 0x29
      in case rparenIdx of
        Nothing -> pure Nothing
        Just idx ->
          -- After ") " comes "state ppid ..."
          let rest = BS.drop (idx + 2) bs
              -- Split on spaces, take fields: state(0) ppid(1)
              fields = BS.split 0x20 rest  -- space = 0x20
          in case fields of
            (_state:ppidBs:_) -> pure (Just (map (toEnum . fromEnum) (BS.unpack ppidBs)))
            _ -> pure Nothing

-- | Walk all descendants of root PIDs using the children map.
walkDescendants :: Set String -> Map String [String] -> Set String
walkDescendants roots childrenMap = go (Set.toList roots) Set.empty
  where
    go [] visited = visited
    go (pid:stack) visited
      | pid `Set.member` visited = go stack visited
      | otherwise =
          let kids = Map.findWithDefault [] pid childrenMap
          in go (kids ++ stack) (Set.insert pid visited)

-- | Check if a string is all digits (a PID entry in /proc).
isNumeric :: String -> Bool
isNumeric [] = False
isNumeric s  = all (\c -> c >= '0' && c <= '9') s
