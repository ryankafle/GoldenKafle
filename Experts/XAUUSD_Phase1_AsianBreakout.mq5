//+------------------------------------------------------------------+
//|                                   XAUUSD_Phase1_AsianBreakout.mq5 |
//|                                              GoldenKafle Project  |
//|                                                                  |
//|  PHASE 1 STRATEGY SKELETON  -  XAUUSD Asian-Range Breakout       |
//|                                                                  |
//|  WHAT THIS EA DOES                                               |
//|  ----------------------------------------------------------------|
//|  1. ASIAN RANGE                                                  |
//|     Records the highest high and lowest low of all M15 candles   |
//|     during the Asian session (default 00:00-06:00 server time).  |
//|     The range is locked in once at the session end.             |
//|                                                                  |
//|  2. TREND FILTER (H4 EMA)                                        |
//|     A 50-period EMA on the H4 chart. Price above EMA => only     |
//|     LONG trades allowed. Price below EMA => only SHORT trades.   |
//|                                                                  |
//|  3. ENTRY (LONDON SESSION, default 06:00-12:00 server time)      |
//|     LONG : an M15 candle closes ABOVE AsianHigh + bullish trend. |
//|     SHORT: an M15 candle closes BELOW AsianLow  + bearish trend. |
//|     Only the FIRST valid signal of the day is taken.            |
//|                                                                  |
//|  4. STOP LOSS / TAKE PROFIT (ATR 14, M15)                        |
//|     SL = entry -/+ 1.5 x ATR  (configurable multiplier)         |
//|     TP = entry +/- 2.0 x ATR  (configurable, >=1:2 RR)          |
//|                                                                  |
//|  5. FORCED EXIT                                                  |
//|     Any open trade is closed at 21:00 server time (end of day). |
//|                                                                  |
//|  Fixed lot 0.01 (dynamic sizing comes in a later phase).        |
//|  One trade open at a time. One trade per day maximum.           |
//|                                                                  |
//|  Version : 1.0                                                  |
//|  Date    : 2026-06-29                                           |
//+------------------------------------------------------------------+
#property copyright "GoldenKafle Project"
#property link      "https://github.com/ryankafle/goldenkafle"
#property version   "1.00"
#property description "Phase 1 skeleton: XAUUSD Asian-range breakout with H4 EMA trend filter and ATR-based SL/TP."
#property strict

#include <Trade\Trade.mqh>

//--- trade object used for all order handling
CTrade trade;

//+------------------------------------------------------------------+
//| Input parameters (all adjustable in the MT5 Inputs tab)          |
//+------------------------------------------------------------------+
input double          LotSize            = 0.01;       // Fixed lot size
input int             AsianSessionStart  = 0;          // Asian session start hour (server time)
input int             AsianSessionEnd    = 6;          // Asian session end hour (server time)
input int             LondonSessionStart = 6;          // London entry window start hour
input int             LondonSessionEnd   = 12;         // London entry window end hour
input int             ForceCloseHour     = 21;         // End-of-day forced close hour
input int             ATR_Period         = 14;         // ATR period (M15)
input double          ATR_SL_Multiplier  = 1.5;        // Stop loss = X * ATR
input double          ATR_TP_Multiplier  = 2.0;        // Take profit = X * ATR
input int             EMA_Period         = 50;         // Trend EMA period
input ENUM_TIMEFRAMES EMA_Timeframe      = PERIOD_H4;  // Trend EMA timeframe
input int             MaxSpread          = 30;         // Max allowed spread (points); skip trade if wider
input ulong           MagicNumber        = 20260629;   // Unique EA identifier

//+------------------------------------------------------------------+
//| Global state                                                     |
//+------------------------------------------------------------------+
int      g_atrHandle    = INVALID_HANDLE;  // ATR indicator handle (M15)
int      g_emaHandle    = INVALID_HANDLE;  // EMA indicator handle (H4)

double   g_asianHigh    = 0.0;             // recorded Asian session high
double   g_asianLow     = 0.0;             // recorded Asian session low
bool     g_asianRangeSet= false;           // has the range been locked for today?
bool     g_tradeToday   = false;           // has a trade already been taken today?
datetime g_currentDay   = 0;               // start-of-day stamp for daily reset
datetime g_lastBarTime  = 0;               // open time of the last processed M15 bar

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- basic sanity checks on the inputs
   if(LotSize <= 0.0)
     {
      Print("ERROR: LotSize must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(AsianSessionEnd <= AsianSessionStart)
     {
      Print("ERROR: AsianSessionEnd must be greater than AsianSessionStart.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(LondonSessionEnd <= LondonSessionStart)
     {
      Print("ERROR: LondonSessionEnd must be greater than LondonSessionStart.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- create indicator handles
   g_atrHandle = iATR(_Symbol, PERIOD_M15, ATR_Period);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("ERROR: failed to create ATR handle. Code=", GetLastError());
      return(INIT_FAILED);
     }

   g_emaHandle = iMA(_Symbol, EMA_Timeframe, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaHandle == INVALID_HANDLE)
     {
      Print("ERROR: failed to create EMA handle. Code=", GetLastError());
      return(INIT_FAILED);
     }

   //--- configure the trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- friendly heads-up if not running on a gold chart
   if(StringFind(_Symbol, "XAU") < 0)
      Print("NOTE: this EA is tuned for XAUUSD but is running on ", _Symbol, ".");

   Print("XAUUSD Phase 1 Asian-Breakout EA v1.0 initialized on ", _Symbol,
         " | Lot=", DoubleToString(LotSize, 2),
         " | Asian ", AsianSessionStart, ":00-", AsianSessionEnd, ":00",
         " | London ", LondonSessionStart, ":00-", LondonSessionEnd, ":00",
         " | ForceClose ", ForceCloseHour, ":00");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
     }
   if(g_emaHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_emaHandle);
      g_emaHandle = INVALID_HANDLE;
     }
   Print("XAUUSD Phase 1 Asian-Breakout EA deinitialized. Reason=", reason);
  }

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int hour = dt.hour;

   //--- 1) daily reset: detect a new trading day
   datetime dayStamp = StartOfDay(now);
   if(dayStamp != g_currentDay)
     {
      g_currentDay    = dayStamp;
      g_asianRangeSet = false;
      g_tradeToday    = false;
      g_asianHigh     = 0.0;
      g_asianLow      = 0.0;
      Print("New trading day: ", TimeToString(dayStamp, TIME_DATE));
     }

   //--- 2) end-of-day forced close (checked on every tick)
   if(hour >= ForceCloseHour)
     {
      if(HasOpenPosition())
         CloseOpenPosition("End-of-day forced close at " + IntegerToString(ForceCloseHour) + ":00");
      return; // nothing else to do once the trading day is over
     }

   //--- 3) lock the Asian range once the session has ended
   if(!g_asianRangeSet && hour >= AsianSessionEnd)
     {
      if(CalculateAsianRange())
        {
         g_asianRangeSet = true;
         Print("Asian range set for ", TimeToString(g_currentDay, TIME_DATE),
               " -> High=", DoubleToString(g_asianHigh, _Digits),
               " Low=", DoubleToString(g_asianLow, _Digits));
        }
     }

   //--- 4) entry logic runs only once per completed M15 bar
   if(!IsNewM15Bar())
      return;

   ProcessEntry();
  }

//+------------------------------------------------------------------+
//| Evaluate and (if valid) place the first trade of the day         |
//+------------------------------------------------------------------+
void ProcessEntry()
  {
   //--- gates: need a range, no trade yet today, nothing already open
   if(!g_asianRangeSet)        return;
   if(g_tradeToday)            return;
   if(HasOpenPosition())       return;

   //--- the candle that just closed = bar at shift 1; new bar opened at shift 0
   double   closedClose = iClose(_Symbol, PERIOD_M15, 1);
   datetime closeTime   = iTime(_Symbol, PERIOD_M15, 0); // open of new bar == close of prev bar
   if(closedClose <= 0.0 || closeTime == 0)
      return;

   MqlDateTime ct;
   TimeToStruct(closeTime, ct);
   int closeHour = ct.hour;

   //--- only look for entries inside the London window
   if(closeHour < LondonSessionStart || closeHour >= LondonSessionEnd)
      return;

   //--- spread guard
   long spread = (long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
     {
      Print("Spread too wide (", spread, " > ", MaxSpread, " points). Skipping signal check.");
      return;
     }

   //--- trend filter (H4 EMA)
   int trend = GetTrendDirection();
   if(trend == 0)
      return; // EMA data not ready or price exactly on the EMA

   //--- volatility for SL/TP
   double atr = GetATR();
   if(atr <= 0.0)
     {
      Print("ATR not available yet. Skipping signal check.");
      return;
     }

   //--- LONG signal: close above Asian high in a bullish trend
   if(closedClose > g_asianHigh && trend > 0)
     {
      Print("LONG signal fired: M15 close ", DoubleToString(closedClose, _Digits),
            " > AsianHigh ", DoubleToString(g_asianHigh, _Digits), " (trend bullish)");
      OpenTrade(ORDER_TYPE_BUY, atr);
     }
   //--- SHORT signal: close below Asian low in a bearish trend
   else if(closedClose < g_asianLow && trend < 0)
     {
      Print("SHORT signal fired: M15 close ", DoubleToString(closedClose, _Digits),
            " < AsianLow ", DoubleToString(g_asianLow, _Digits), " (trend bearish)");
      OpenTrade(ORDER_TYPE_SELL, atr);
     }
  }

//+------------------------------------------------------------------+
//| Open a trade with ATR-based SL/TP                                |
//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const double atr)
  {
   double sl = 0.0, tp = 0.0, price = 0.0;

   if(type == ORDER_TYPE_BUY)
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl    = NormalizeDouble(price - ATR_SL_Multiplier * atr, _Digits);
      tp    = NormalizeDouble(price + ATR_TP_Multiplier * atr, _Digits);

      if(trade.Buy(LotSize, _Symbol, price, sl, tp, "AsianBreakout Long"))
        {
         g_tradeToday = true;
         Print("TRADE OPENED: BUY ", DoubleToString(LotSize, 2), " ", _Symbol,
               " @ ", DoubleToString(price, _Digits),
               " SL=", DoubleToString(sl, _Digits),
               " TP=", DoubleToString(tp, _Digits),
               " ATR=", DoubleToString(atr, _Digits),
               " Ticket=", (long)trade.ResultOrder());
        }
      else
        {
         Print("ORDER FAILED (BUY): retcode=", trade.ResultRetcode(),
               " (", trade.ResultRetcodeDescription(), ")");
        }
     }
   else if(type == ORDER_TYPE_SELL)
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl    = NormalizeDouble(price + ATR_SL_Multiplier * atr, _Digits);
      tp    = NormalizeDouble(price - ATR_TP_Multiplier * atr, _Digits);

      if(trade.Sell(LotSize, _Symbol, price, sl, tp, "AsianBreakout Short"))
        {
         g_tradeToday = true;
         Print("TRADE OPENED: SELL ", DoubleToString(LotSize, 2), " ", _Symbol,
               " @ ", DoubleToString(price, _Digits),
               " SL=", DoubleToString(sl, _Digits),
               " TP=", DoubleToString(tp, _Digits),
               " ATR=", DoubleToString(atr, _Digits),
               " Ticket=", (long)trade.ResultOrder());
        }
      else
        {
         Print("ORDER FAILED (SELL): retcode=", trade.ResultRetcode(),
               " (", trade.ResultRetcodeDescription(), ")");
        }
     }
  }

//+------------------------------------------------------------------+
//| Compute the Asian-session high/low from M15 candles              |
//+------------------------------------------------------------------+
bool CalculateAsianRange()
  {
   //--- build today's session start/stop timestamps
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   dt.hour = AsianSessionStart;
   dt.min  = 0;
   dt.sec  = 0;
   datetime startTime = StructToTime(dt);

   dt.hour = AsianSessionEnd;
   dt.min  = 0;
   dt.sec  = 0;
   datetime endTime = StructToTime(dt);

   //--- pull all M15 bars whose open time falls inside the session
   //--- (subtract one second so the candle opening exactly at the session
   //---  end -- the first London candle -- is excluded)
   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_M15, startTime, endTime - 1, rates);
   if(copied <= 0)
     {
      Print("WARN: could not copy Asian-session M15 rates yet (copied=", copied,
            ", err=", GetLastError(), "). Will retry on next tick.");
      return(false);
     }

   double hi = -DBL_MAX;
   double lo =  DBL_MAX;
   for(int i = 0; i < copied; i++)
     {
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
     }

   if(hi <= 0.0 || lo >= DBL_MAX || hi < lo)
     {
      Print("WARN: invalid Asian range computed. Will retry on next tick.");
      return(false);
     }

   g_asianHigh = hi;
   g_asianLow  = lo;
   return(true);
  }

//+------------------------------------------------------------------+
//| Trend direction from the H4 EMA. +1 bull, -1 bear, 0 neutral     |
//+------------------------------------------------------------------+
int GetTrendDirection()
  {
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(g_emaHandle, 0, 0, 2, ema) < 2)
     {
      Print("WARN: EMA buffer not ready (err=", GetLastError(), ").");
      return(0);
     }

   double emaValue   = ema[0];
   double priceNow   = iClose(_Symbol, EMA_Timeframe, 0); // current H4 price
   if(priceNow <= 0.0 || emaValue <= 0.0)
      return(0);

   if(priceNow > emaValue) return(1);
   if(priceNow < emaValue) return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Latest completed ATR value (M15)                                 |
//+------------------------------------------------------------------+
double GetATR()
  {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 2, atr) < 2)
     {
      Print("WARN: ATR buffer not ready (err=", GetLastError(), ").");
      return(0.0);
     }
   return(atr[1]); // last fully-formed bar's ATR
  }

//+------------------------------------------------------------------+
//| True if this EA already has a position on this symbol            |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Close any open position belonging to this EA on this symbol      |
//+------------------------------------------------------------------+
void CloseOpenPosition(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(trade.PositionClose(ticket))
        {
         Print("TRADE CLOSED: ticket=", (long)ticket,
               " reason=", reason,
               " floating P/L=", DoubleToString(profit, 2));
        }
      else
        {
         Print("CLOSE FAILED: ticket=", (long)ticket,
               " retcode=", trade.ResultRetcode(),
               " (", trade.ResultRetcodeDescription(), ")");
        }
     }
  }

//+------------------------------------------------------------------+
//| Detect the start of a new M15 bar                                |
//+------------------------------------------------------------------+
bool IsNewM15Bar()
  {
   datetime t = iTime(_Symbol, PERIOD_M15, 0);
   if(t == 0)
      return(false);
   if(t != g_lastBarTime)
     {
      g_lastBarTime = t;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Midnight (00:00) of the day containing 'ts'                      |
//+------------------------------------------------------------------+
datetime StartOfDay(const datetime ts)
  {
   MqlDateTime dt;
   TimeToStruct(ts, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return(StructToTime(dt));
  }
//+------------------------------------------------------------------+
