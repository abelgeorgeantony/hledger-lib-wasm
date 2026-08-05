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
import Data.Time.Calendar (toGregorian, fromGregorian, Day)
import Data.List (nub, minimumBy)
import Data.Ord (comparing)

import Hledger.Read (parseAndFinaliseJournal, forecast_, _ioDay, definputopts, InputOpts, balancingopts_)
import Hledger.Data.Balancing (BalancingOpts(..), defbalancingopts, journalBalanceTransactions)
import Hledger.Read.JournalReader (journalp)
import Hledger.Read.RulesReader (readRules, readJournalFromCsv)
import Hledger.Data.Types 
  ( Journal, jpricedirectives, AccountType(..)
  , MixedAmount, DateSpan(..), EFDay(..), Interval(..)
  , jperiodictxns, ptinterval
  , jtxns
  )
import Hledger.Data.Journal
  ( journalAccountNames
  , journalPayeesDeclaredOrUsed
  , journalCommoditiesUsed
  , journalTagsDeclaredOrUsed
  , journalDateSpan
  )
import Hledger.Data.Transaction (showTransaction)
import Hledger.Reports.BalanceReport (balanceReport)
import Hledger.Reports.PostingsReport (postingsReport)
import Hledger.Reports.EntriesReport (entriesReport)
import Hledger.Reports.BudgetReport (BudgetReport)
import qualified Hledger.Reports.BudgetReport as Lib
import Hledger.Reports.ReportOptions
  (defreportopts, ReportSpec(..), ReportOpts(..), reportOptsToSpec)
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

import Hledger.Query (Query(..), queryDateSpan')
import Hledger.Reports.MultiBalanceReport (compoundBalanceReport)
import Hledger.Reports.ReportTypes (CBCSubreportSpec(..), DisplayName, CompoundPeriodicReport)


{-# NOINLINE journalTable #-}
journalTable :: IORef (Map.Map Int Journal, Int)
journalTable = unsafePerformIO (newIORef (Map.empty, 0))


efDayToDay :: EFDay -> Day
efDayToDay (Exact d) = d
efDayToDay (Flex d)  = d

widenToYears :: DateSpan -> DateSpan
widenToYears (DateSpan (Just s) (Just e)) =
  let (sy, _, _) = toGregorian (efDayToDay s)
      (ey, _, _) = toGregorian (efDayToDay e)
  in DateSpan (Just (Exact (fromGregorian sy 1 1))) (Just (Exact (fromGregorian (ey + 1) 1 1)))
widenToYears _ = DateSpan Nothing Nothing  -- no real transactions at all; nothing to bracket

intervalRank :: Interval -> Int
intervalRank NoInterval              = maxBound
intervalRank (Days n)                = n
intervalRank (Weeks n)               = n * 7
intervalRank (Months n)              = n * 30
intervalRank (Quarters n)            = n * 91
intervalRank (Years n)               = n * 365
intervalRank (NthWeekdayOfMonth _ _) = 30
intervalRank (MonthDay _)            = 30
intervalRank (MonthAndDay _ _)       = 365
intervalRank (DaysOfWeek _)          = 7

inferBudgetInterval :: Journal -> Interval
inferBudgetInterval journal =
  case nub [ ptinterval pt | pt <- jperiodictxns journal, ptinterval pt /= NoInterval ] of
    []  -> NoInterval
    is  -> minimumBy (comparing intervalRank) is


foreign export javascript "parseJournal" hs_parseJournal :: JSString -> JSString -> IO JSString
foreign export javascript "parseCsv" hs_parseCsv :: JSString -> JSString -> IO JSString
foreign export javascript "runReport" hs_runReport :: Int -> JSString -> JSString -> IO JSString
foreign export javascript "balanceTransaction" hs_balanceTransaction :: Int -> JSString -> IO JSString
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
          "printtext" -> jsonResponse
            ["ok" .= True, "data" .= T.intercalate "\n" (map showTransaction (entriesReport rspec journal))]
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
          "budget" -> do
            let ropts' = (_rsReportOpts rspec) { interval_ = inferBudgetInterval journal }
            case reportOptsToSpec today ropts' of
              Left err -> jsonResponse ["ok" .= False, "error" .= ("bad query: " ++ err)]
              Right budgetRspec -> do
                let qspan = queryDateSpan' (_rsQuery budgetRspec)
                let reportspan = if qspan == DateSpan Nothing Nothing
                                  then widenToYears (journalDateSpan False journal)
                                  else qspan
                jsonResponse
                  ["ok" .= True, "data" .= toJSON (Lib.budgetReport budgetRspec defbalancingopts reportspan journal)]
          other -> jsonResponse
            ["ok" .= False, "error" .= ("unknown report: " ++ other)]


hs_balanceTransaction :: Int -> JSString -> IO JSString
hs_balanceTransaction handle jsTxnText = do
  (tbl, nextId) <- readIORef journalTable
  case Map.lookup handle tbl of
    Nothing -> jsonResponse ["ok" .= False, "error" .= ("invalid handle" :: String)]
    Just journal -> do
      today <- utctDay <$> getCurrentTime
      let parseOpts = definputopts { _ioDay = today }
      let txnText = T.pack (fromJSString jsTxnText)
      
      result <- runExceptT $ parseAndFinaliseJournal (journalp parseOpts) parseOpts "input" txnText
      case result of
        Left err -> jsonResponse ["ok" .= False, "error" .= err]
        Right miniJournal -> case jtxns miniJournal of
          [t] -> do
            let j' = journal { jtxns = jtxns journal ++ [t] }
            case journalBalanceTransactions defbalancingopts j' of
              Right balancedJ -> do
                -- KEY ADDITION: Save the updated journal back to WASM memory
                writeIORef journalTable (Map.insert handle balancedJ tbl, nextId)
                
                case reverse (jtxns balancedJ) of
                  (balancedT:_) -> jsonResponse ["ok" .= True, "data" .= showTransaction balancedT]
                  [] -> jsonResponse ["ok" .= False, "error" .= ("unexpected empty journal" :: String)]
              Left err -> jsonResponse ["ok" .= False, "error" .= err]
          _ -> jsonResponse ["ok" .= False, "error" .= ("expected exactly one transaction" :: String)]


hs_freeJournal :: Int -> IO ()
hs_freeJournal handle =
  atomicModifyIORef' journalTable $ \(tbl, nextId) -> ((Map.delete handle tbl, nextId), ())

main :: IO ()
main = pure ()