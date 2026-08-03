{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import GHC.Wasm.Prim
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Control.Monad.Except (runExceptT)
import Data.Aeson (encode, object, (.=), toJSON, Value)
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Aeson.Types (Pair)
import Data.Time.Clock (getCurrentTime, utctDay)

import Hledger.Read (parseAndFinaliseJournal, forecast_, _ioDay, definputopts, InputOpts, balancingopts_)
import Hledger.Data.Balancing (BalancingOpts(..))
import Hledger.Read.JournalReader (journalp)
import Hledger.Read.RulesReader (readRules, readJournalFromCsv)
import Hledger.Data.Types (Journal, jpricedirectives, AccountType(..), MixedAmount, DateSpan(..))
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
import Hledger.Data.JournalChecks
  ( journalCheckBalanceAssertions
  , journalCheckOrdereddates
  , journalCheckAccounts
  , journalCheckCommodities
  , journalCheckPayees
  , journalCheckTags
  , journalCheckPairedConversionPostings
  , journalCheckRecentAssertions
  , journalCheckUniqueleafnames
  )

import Hledger.Query (Query(..))
import Hledger.Data.Types (Journal, jpricedirectives, AccountType(..))
import Hledger.Reports.MultiBalanceReport (compoundBalanceReport)
import Hledger.Reports.ReportTypes (CBCSubreportSpec(..), DisplayName, CompoundPeriodicReport)

{-# NOINLINE journalTable #-}
journalTable :: IORef (Map.Map Int Journal, Int)
journalTable = unsafePerformIO (newIORef (Map.empty, 0))

foreign export javascript "parseJournal" hs_parseJournal :: JSString -> JSString -> IO JSString
foreign export javascript "parseCsv" hs_parseCsv :: JSString -> JSString -> IO JSString
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



defaultChecks :: [(T.Text, Journal -> Either String ())]
defaultChecks =
  [ ("ordereddates", journalCheckOrdereddates)
  , ("balanceassertions", journalCheckBalanceAssertions)
  ]

strictChecks :: [(T.Text, Journal -> Either String ())]
strictChecks = defaultChecks ++
  [ ("commodities", journalCheckCommodities)
  , ("accounts", journalCheckAccounts)
  , ("tags", journalCheckTags)
  , ("recentassertions", journalCheckRecentAssertions)
  , ("pairedconversion", journalCheckPairedConversionPostings)
  , ("uniqueleafnames", journalCheckUniqueleafnames)
  ]

runChecks :: [(T.Text, Journal -> Either String ())] -> Journal -> Value
runChecks checks journal = toJSON
  [ case fn journal of
      Left err -> object ["name" .= name, "valid" .= False, "error" .= err]
      Right () -> object ["name" .= name, "valid" .= True]
  | (name, fn) <- checks
  ]


hs_parseJournal :: JSString -> JSString -> IO JSString
hs_parseJournal jstext jsForecast = do
  today <- utctDay <$> getCurrentTime
  let journalText = T.pack (fromJSString jstext)
  let forecastEnabled = not (null (fromJSString jsForecast))
  let parseOpts = definputopts
        { balancingopts_ = (balancingopts_ definputopts) { ignore_assertions_ = True }
        , forecast_ = if forecastEnabled then Just (DateSpan Nothing Nothing) else Nothing
        , _ioDay = today
        }
  result <- runExceptT $
    parseAndFinaliseJournal (journalp parseOpts) parseOpts "input" journalText
  case result of
    Left err -> jsonResponse ["ok" .= False, "error" .= err]
    Right j -> do
      handle <- atomicModifyIORef' journalTable $ \(tbl, nextId) ->
        ((Map.insert nextId j tbl, nextId + 1), nextId)
      jsonResponse ["ok" .= True, "handle" .= handle]


hs_parseCsv :: JSString -> JSString -> IO JSString
hs_parseCsv jsCsvText jsRulesPath = do
  let csvText = T.pack (fromJSString jsCsvText)
  let rulesPath = fromJSString jsRulesPath
  result <- runExceptT $ do
    rules <- readRules rulesPath
    readJournalFromCsv rules rulesPath csvText Nothing
  case result of
    Left err -> jsonResponse ["ok" .= False, "error" .= err]
    Right j -> do
      handle <- atomicModifyIORef' journalTable $ \(tbl, nextId) ->
        ((Map.insert nextId j tbl, nextId + 1), nextId)
      jsonResponse ["ok" .= True, "handle" .= handle]


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
          "check" -> jsonResponse
            ["ok" .= True, "data" .= runChecks defaultChecks journal]
          "checkstrict" -> jsonResponse
            ["ok" .= True, "data" .= runChecks strictChecks journal]
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