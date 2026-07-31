{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import GHC.Wasm.Prim
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Control.Monad.Except (runExceptT)
import Data.Aeson (encode, object, (.=), toJSON)
import qualified Data.ByteString.Lazy.Char8 as BLC

import Hledger.Read (parseAndFinaliseJournal, definputopts, InputOpts, balancingopts_)
import Hledger.Data.Balancing (BalancingOpts(..))
import Hledger.Read.JournalReader (journalp)
import Hledger.Data.Types (Journal)
import Hledger.Data.Journal (journalAccountNames)
import Hledger.Reports.BalanceReport (balanceReport)
import Hledger.Reports.ReportOptions (defreportspec)
import Hledger.Data.JournalChecks (journalCheckBalanceAssertions)

{-# NOINLINE journalTable #-}
journalTable :: IORef (Map.Map Int Journal, Int)
journalTable = unsafePerformIO (newIORef (Map.empty, 0))

foreign export javascript "parseJournal" hs_parseJournal :: JSString -> IO JSString
foreign export javascript "runReport" hs_runReport :: Int -> JSString -> IO JSString
foreign export javascript "freeJournal" hs_freeJournal :: Int -> IO ()

parseOpts :: InputOpts
parseOpts = definputopts
  { balancingopts_ = (balancingopts_ definputopts) { ignore_assertions_ = True } }
hs_parseJournal :: JSString -> IO JSString
hs_parseJournal jstext = do
  let journalText = T.pack (fromJSString jstext)
  result <- runExceptT $
    parseAndFinaliseJournal (journalp parseOpts) parseOpts "input" journalText
  case result of
    Left err -> pure . toJSString . BLC.unpack . encode $
      object ["ok" .= False, "error" .= err]
    Right j -> do
      handle <- atomicModifyIORef' journalTable $ \(tbl, nextId) ->
        ((Map.insert nextId j tbl, nextId + 1), nextId)
      pure . toJSString . BLC.unpack . encode $
        object ["ok" .= True, "handle" .= handle]

hs_runReport :: Int -> JSString -> IO JSString
hs_runReport handle jsReportName = do
  (tbl, _) <- readIORef journalTable
  case Map.lookup handle tbl of
    Nothing -> pure . toJSString . BLC.unpack . encode $
      object ["ok" .= False, "error" .= ("invalid handle" :: String)]
    Just journal -> case fromJSString jsReportName of
      "accounts" -> pure . toJSString . BLC.unpack . encode $
        object ["ok" .= True, "data" .= journalAccountNames journal]
      "balance" -> pure . toJSString . BLC.unpack . encode $
        object ["ok" .= True, "data" .= toJSON (balanceReport defreportspec journal)]
      "check" -> case journalCheckBalanceAssertions journal of
        Left err -> pure . toJSString . BLC.unpack . encode $
          object ["ok" .= True, "data" .= object ["valid" .= False, "error" .= err]]
        Right () -> pure . toJSString . BLC.unpack . encode $
          object ["ok" .= True, "data" .= object ["valid" .= True]]
      other -> pure . toJSString . BLC.unpack . encode $
        object ["ok" .= False, "error" .= ("unknown report: " ++ other)]

hs_freeJournal :: Int -> IO ()
hs_freeJournal handle =
  atomicModifyIORef' journalTable $ \(tbl, nextId) -> ((Map.delete handle tbl, nextId), ())

main :: IO ()
main = pure ()