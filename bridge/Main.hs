{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad.Except (runExceptT)
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as BLC
import Hledger
  ( Journal,
    balanceReport,
    definputopts,
    defreportspec,
    journalAccountNames,
  )
import Hledger.Read (readJournalFile)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hFlush, hPutStrLn, stderr, stdout)

main :: IO ()
main = do
  args <- getArgs
  case args of
    (cmd : file : rest) -> do
      result <- runExceptT $ readJournalFile definputopts file
      case result of
        Left err -> failWith ("Parse error: " <> err)
        Right journal -> runCommand cmd journal rest
    _ -> failWith "Usage: hledger-wasm <command> <file> [args...]"

runCommand :: String -> Journal -> [String] -> IO ()
runCommand "accounts" journal _ =
  writeJson (journalAccountNames journal)
runCommand "balance" journal _ =
  writeJson (balanceReport defreportspec journal)
runCommand "check" _ _ =
  writeJson (Aeson.object ["ok" .= True])
runCommand command _ _ =
  failWith ("Unknown command: " <> command)

writeJson :: Aeson.ToJSON a => a -> IO ()
writeJson value = do
  BLC.putStrLn (Aeson.encode value)
  hFlush stdout

failWith :: String -> IO ()
failWith message = do
  hPutStrLn stderr message
  exitFailure
