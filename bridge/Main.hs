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
import Data.Aeson.Types (Pair)

import Hledger.Read (parseAndFinaliseJournal, definputopts, InputOpts, balancingopts_)
import Hledger.Data.Balancing (BalancingOpts(..))
import Hledger.Read.JournalReader (journalp)
import Hledger.Data.Types (Journal, jpricedirectives, AccountType(..), MixedAmount)
import Hledger.Data.Journal
  ( journalAccountNames
  , journalPayeesDeclaredOrUsed
  , journalCommoditiesUsed
  , journalTagsDeclaredOrUsed
  )
import Hledger.Reports.BalanceReport (balanceReport)
import Hledger.Reports.PostingsReport (postingsReport)
import Hledger.Reports.EntriesReport (entriesReport)
import Hledger.Reports.ReportOptions
  (defreportopts, ReportSpec, ReportOpts(..), reportOptsToSpec)
import Data.Time.Clock (getCurrentTime, utctDay)
import Hledger.Data.JournalChecks (journalCheckBalanceAssertions)

import Hledger.Query (Query(..))
import Hledger.Data.Types (Journal, jpricedirectives, AccountType(..))
import Hledger.Reports.MultiBalanceReport (compoundBalanceReport)
import Hledger.Reports.ReportTypes (CBCSubreportSpec(..), DisplayName, CompoundPeriodicReport)

{-# NOINLINE journalTable #-}
journalTable :: IORef (Map.Map Int Journal, Int)
journalTable = unsafePerformIO (newIORef (Map.empty, 0))

foreign export javascript "parseJournal" hs_parseJournal :: JSString -> IO JSString
foreign export javascript "runReport" hs_runReport :: Int -> JSString -> JSString -> IO JSString
foreign export javascript "freeJournal" hs_freeJournal :: Int -> IO ()



mkSubreport :: T.Text -> [AccountType] -> Bool -> CBCSubreportSpec DisplayName
mkSubreport title types increasesTotal = CBCSubreportSpec
  { cbcsubreporttitle          = title
  , cbcsubreportquery          = Type types
  , cbcsubreportoptions        = id
  , cbcsubreporttransform      = id
  , cbcsubreportincreasestotal = increasesTotal
  }

balanceSheetReport :: ReportSpec -> Journal -> CompoundPeriodicReport DisplayName MixedAmount
balanceSheetReport rspec j = compoundBalanceReport rspec j
  [ mkSubreport "Assets" [Asset] True
  , mkSubreport "Liabilities" [Liability] False
  ]

incomeStatementReport :: ReportSpec -> Journal -> CompoundPeriodicReport DisplayName MixedAmount
incomeStatementReport rspec j = compoundBalanceReport rspec j
  [ mkSubreport "Revenues" [Revenue] True
  , mkSubreport "Expenses" [Expense] False
  ]

cashflowReport :: ReportSpec -> Journal -> CompoundPeriodicReport DisplayName MixedAmount
cashflowReport rspec j = compoundBalanceReport rspec j
  [ mkSubreport "Cash flows" [Cash] True ]



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


jsonResponse :: [Pair] -> IO JSString
jsonResponse = pure . toJSString . BLC.unpack . encode . object
hs_runReport :: Int -> JSString -> JSString -> IO JSString
hs_runReport handle jsReportName jsQuery = do
  (tbl, _) <- readIORef journalTable
  case Map.lookup handle tbl of
    Nothing -> jsonResponse ["ok" .= False, "error" .= ("invalid handle" :: String)]
    Just journal -> do
      today <- utctDay <$> getCurrentTime
      let queryWords = T.words (T.pack (fromJSString jsQuery))
      let ropts = defreportopts { querystring_ = queryWords }
      case reportOptsToSpec today ropts of
        Left err -> jsonResponse ["ok" .= False, "error" .= ("bad query: " ++ err)]
        Right rspec -> case fromJSString jsReportName of
          "accounts" -> jsonResponse
            ["ok" .= True, "data" .= journalAccountNames journal]
          "balance" -> jsonResponse
            ["ok" .= True, "data" .= toJSON (balanceReport rspec journal)]
          "check" -> case journalCheckBalanceAssertions journal of
            Left err -> jsonResponse
              ["ok" .= True, "data" .= object ["valid" .= False, "error" .= err]]
            Right () -> jsonResponse
              ["ok" .= True, "data" .= object ["valid" .= True]]
          "register" -> jsonResponse
            ["ok" .= True, "data" .= toJSON (postingsReport rspec journal)]
          "print" -> jsonResponse
            ["ok" .= True, "data" .= toJSON (entriesReport rspec journal)]
          "prices" -> jsonResponse
            ["ok" .= True, "data" .= toJSON (jpricedirectives journal)]
          "payees" -> jsonResponse
            ["ok" .= True, "data" .= journalPayeesDeclaredOrUsed journal]
          "commodities" -> jsonResponse
            ["ok" .= True, "data" .= journalCommoditiesUsed journal]
          "tags" -> jsonResponse
            ["ok" .= True, "data" .= journalTagsDeclaredOrUsed journal]
          "balancesheet" -> jsonResponse
            ["ok" .= True, "data" .= toJSON (balanceSheetReport rspec journal)]
          "incomestatement" -> jsonResponse
            ["ok" .= True, "data" .= toJSON (incomeStatementReport rspec journal)]
          "cashflow" -> jsonResponse
            ["ok" .= True, "data" .= toJSON (cashflowReport rspec journal)]
          other -> jsonResponse
            ["ok" .= False, "error" .= ("unknown report: " ++ other)]

hs_freeJournal :: Int -> IO ()
hs_freeJournal handle =
  atomicModifyIORef' journalTable $ \(tbl, nextId) -> ((Map.delete handle tbl, nextId), ())

main :: IO ()
main = pure ()