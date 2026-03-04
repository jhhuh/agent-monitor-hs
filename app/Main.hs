module Main where

import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import AgentMonitor.Parser (buildInitialState, loadSubagentFiles)
import AgentMonitor.Types
import AgentMonitor.UI (runApp)
import AgentMonitor.Watcher (findNewestJsonl)

main :: IO ()
main = do
  args <- getArgs
  let dumpMode = "--dump-state" `elem` args
      paths = filter (/= "--dump-state") args
  fp <- case paths of
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
      hPutStrLn stderr "Usage: agent-monitor-hs [--dump-state] [path-to-jsonl]"
      exitFailure

  content <- BL.readFile fp
  subagentContents <- loadSubagentFiles fp
  let initialState = buildInitialState fp content subagentContents
  if dumpMode
    then dumpState initialState
    else do
      _ <- runApp initialState
      pure ()

dumpState :: AppState -> IO ()
dumpState st = do
  putStrLn $ "File: " ++ asFilePath st
  putStrLn $ "Total agents: " ++ show (Map.size (asAgents st))
  putStrLn $ "Flat order: " ++ show (asFlatOrder st)
  mapM_ printAgent (Map.toList (asAgents st))
  where
    printAgent (k, v) = putStrLn $ "  " ++ show k
      ++ " -> " ++ show (aiDescription v)
      ++ " parent=" ++ show (aiParentId v)
      ++ " children=" ++ show (aiChildren v)
