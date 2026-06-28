//+------------------------------------------------------------------+
//|  Config/Inputs.mqh                                               |
//|  FTMO-Compliant EA — Centralised Input Parameters                |
//|  SRS Version 1.0  |  Section 5.7                                 |
//+------------------------------------------------------------------+
#ifndef INPUTS_MQH
#define INPUTS_MQH

//--- Risk Engine Inputs (M1) ----------------------------------------
input group "=== Risk Engine ==="

input double InpRiskPerTrade    = 0.35;     // Risk per trade (% of equity)
input double InpDailyDDLimit    = 3.5;      // Daily equity drawdown halt threshold (%)
input double InpMaxBalanceDD    = 9.5;      // Max balance drawdown — hard disable (%)
input int    InpMaxOpenTrades   = 3;        // Maximum simultaneous open positions
input int    InpMaxConsecLoss   = 5;        // Consecutive losses before system pause
input long   InpMagicNumber     = 20260628; // EA magic number (unique per instance)

//--- Signal Engine Inputs (M2) --------------------------------------
input group "=== Signal Engine ==="

// Trend indicators — H1 timeframe
input int    InpEMAFast         = 50;       // Fast EMA period (H1)
input int    InpEMASlow         = 200;      // Slow EMA period (H1)
input int    InpADXPeriod       = 14;       // ADX period (H1)
input double InpADXThreshold    = 22.0;     // Minimum ADX for trend confirmation

// Volatility indicator — M15 timeframe
input int    InpATRPeriod       = 14;       // ATR period (M15)
input double InpATRMinMultiplier = 0.8;     // Minimum ATR as fraction of 20-bar ATR average

// Momentum indicator — M15 timeframe
input int    InpRSIPeriod       = 14;       // RSI period (M15)
input int    InpRSIBuyMin       = 52;       // RSI lower bound for BUY signals
input int    InpRSIBuyMax       = 70;       // RSI upper bound for BUY signals
input int    InpRSISellMin      = 30;       // RSI lower bound for SELL signals
input int    InpRSISellMax      = 48;       // RSI upper bound for SELL signals

// Swing high/low detection
input int    InpSwingLookback   = 5;        // Bars to look back for swing high/low (M15)

// Pullback confirmation
input double InpPullbackMinATR  = 0.3;      // Minimum pullback as fraction of ATR

//--- Execution & Trade Management Inputs (M3 / M4) ------------------
input group "=== Execution & Trade Management ==="

input double InpSLMultiplier         = 1.8;  // ATR multiplier for stop loss
input double InpTPMultiplier         = 2.7;  // ATR multiplier for take profit
input double InpTrailATRMultiplier   = 1.2;  // ATR multiplier for trailing stop distance
input int    InpMaxSlippagePoints    = 5;    // Max slippage in points
input int    InpMaxSpreadGold        = 30;   // Max spread in points for XAUUSD
input int    InpMaxSpreadForex       = 15;   // Max spread in points for EURUSD
input int    InpMinTradeDurationSec  = 180;  // Minimum seconds before trade management modifies SL
input int    InpMaxHoldingBars       = 96;   // Maximum M15 bars a trade may stay open (96 = 24h)
input bool   InpCloseOnFriday        = true; // Close all positions at Friday 20:00 UTC
input bool   InpEnablePartialClose   = false;// Enable 50% partial close at +1R

//--- Utility / Filter Inputs (M5) -----------------------------------
input group "=== Session & Filter Settings ==="

input int    InpLondonStart          = 7;    // London session start (UTC hour)
input int    InpLondonEnd            = 12;   // London session end (UTC hour)
input int    InpNYStart              = 13;   // New York session start (UTC hour)
input int    InpNYEnd                = 18;   // New York session end (UTC hour)
input int    InpNewsFilterMinutes    = 30;   // Minutes before/after high-impact news to block trading
input bool   InpEnableNewsFilter     = true; // Enable news filter (requires news CSV in MQL5/Files)
input bool   InpEnableLogging        = true; // Write trade log to MQL5/Files/GoldenKafle_Log.csv
input bool   InpEnableDashboard      = true; // Show live performance overlay on chart

#endif // INPUTS_MQH
