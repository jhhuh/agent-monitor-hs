module Main where

import Data.ByteString.Lazy qualified as BL
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import AgentMonitor.Parser (buildInitialState)
import AgentMonitor.UI (runApp)
import AgentMonitor.Watcher (findNewestJsonl)

main :: IO ()
main = do
  args <- getArgs
  fp <- case args of
    [path] -> pure path
    []     -> do
      result <- findNewestJsonl
      case result of
        Just path -> do
          hPutStrLn stderr $ "Auto-detected: " ++ path
          pure path
        Nothing -> do
          hPutStrLn stderr "No .jsonl files found in ~/.claude/projects/"
          hPutStrLn stderr "Usage: agent-monitor-hs [path-to-jsonl]"
          exitFailure
    _ -> do
      hPutStrLn stderr "Usage: agent-monitor-hs [path-to-jsonl]"
      exitFailure

  content <- BL.readFile fp
  let initialState = buildInitialState fp content
  _ <- runApp initialState
  pure ()
