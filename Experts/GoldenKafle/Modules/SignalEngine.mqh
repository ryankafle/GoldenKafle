//+------------------------------------------------------------------+
//|  Modules/SignalEngine.mqh — M2: Signal Generation Engine         |
//|  FTMO-Compliant EA — SRS Part 2 / Section 6.9 Step 4            |
//+------------------------------------------------------------------+
#ifndef SIGNALENGINE_MQH
#define SIGNALENGINE_MQH

#include "../Config/Inputs.mqh"

//--- Signal values returned by GetSignal() -------------------------
enum ENUM_SIGNAL {
    SIGNAL_NONE =  0,
    SIGNAL_BUY  =  1,
    SIGNAL_SELL = -1
};

//+------------------------------------------------------------------+
//|  CSignalEngine — M2 Signal Generation Engine                     |
//|                                                                  |
//|  One instance per trading symbol. Each instance manages its own  |
//|  indicator handles and caches bar values on every new M15 bar.   |
//|                                                                  |
//|  Signal requires ALL of (SRS Section 2.5):                       |
//|    H1  EMA alignment (50 vs 200)                                 |
//|    H1  ADX >= InpADXThreshold (trend strength gate)             |
//|    M15 Breakout above/below N-bar swing high/low                 |
//|    M15 ATR >= InpATRMinMultiplier x 20-bar ATR average           |
//|    M15 RSI in valid momentum range (BUY 52-70 / SELL 30-48)      |
//|    M15 Pullback >= InpPullbackMinATR x ATR from breakout extreme  |
//|    No existing open position on this symbol (no hedging/doubling) |
//+------------------------------------------------------------------+
class CSignalEngine {
private:
    string      m_symbol;

    // ---- Indicator handles (created in Init, released in Deinit) ---
    int         m_hEMAFast;   // InpEMAFast-period EMA on H1
    int         m_hEMASlow;   // InpEMASlow-period EMA on H1
    int         m_hADX;       // ADX on H1
    int         m_hATR;       // ATR on M15
    int         m_hRSI;       // RSI on M15

    // ---- Values cached by OnNewBar() -----------------------------
    double      m_emaFast;    // 50-EMA  value — last completed H1 bar
    double      m_emaSlow;    // 200-EMA value — last completed H1 bar
    double      m_adx;        // ADX main line — last completed H1 bar
    double      m_atr;        // ATR — last completed M15 bar
    double      m_atrAvg20;   // 20-bar ATR average on M15
    double      m_rsi;        // RSI — last completed M15 bar
    double      m_swingHigh;  // max High of bars [2 … 2+N-1] on M15
    double      m_swingLow;   // min Low  of bars [2 … 2+N-1] on M15
    double      m_close1;     // Close[1] M15
    double      m_high1;      // High[1]  M15
    double      m_low1;       // Low[1]   M15

    ENUM_SIGNAL m_signal;     // last computed signal
    bool        m_calcOk;     // false if indicator data was unavailable

    // ---- Private helpers -----------------------------------------
    bool   RefreshIndicators();
    bool   RefreshPriceData();
    bool   CheckBuyConditions()  const;
    bool   CheckSellConditions() const;
    bool   HasOpenPosition()     const;

public:
    CSignalEngine();
    bool        Init(string symbol);
    void        Deinit();

    // Call once per new M15 bar — refreshes all indicators and evaluates signal
    void        OnNewBar();

    // ---- Accessors -----------------------------------------------
    ENUM_SIGNAL GetSignal()                                const { return m_signal;  }
    double      GetSLPrice(ENUM_SIGNAL sig, double entry)  const;
    double      GetTPPrice(ENUM_SIGNAL sig, double entry)  const;
    double      GetATR()    const { return m_atr;    }
    double      GetADX()    const { return m_adx;    }
    string      GetSymbol() const { return m_symbol; }
    bool        IsCalcOk()  const { return m_calcOk; }
};

//+------------------------------------------------------------------+
//  Constructor
//+------------------------------------------------------------------+
CSignalEngine::CSignalEngine()
    : m_symbol(""),
      m_hEMAFast(INVALID_HANDLE),
      m_hEMASlow(INVALID_HANDLE),
      m_hADX(INVALID_HANDLE),
      m_hATR(INVALID_HANDLE),
      m_hRSI(INVALID_HANDLE),
      m_emaFast(0.0), m_emaSlow(0.0),
      m_adx(0.0), m_atr(0.0), m_atrAvg20(0.0), m_rsi(0.0),
      m_swingHigh(0.0), m_swingLow(0.0),
      m_close1(0.0), m_high1(0.0), m_low1(0.0),
      m_signal(SIGNAL_NONE),
      m_calcOk(false)
{}

//+------------------------------------------------------------------+
//  Init — creates all indicator handles for the given symbol.
//  Returns false (triggering INIT_FAILED) if any handle is invalid.
//+------------------------------------------------------------------+
bool CSignalEngine::Init(string symbol) {
    m_symbol = symbol;

    // Verify the symbol exists and is selectable before creating handles.
    if (!SymbolSelect(symbol, true)) {
        PrintFormat("CSignalEngine::Init [%s]: unknown / unselectable symbol (err %d). "
                    "Check the broker's exact symbol name.",
                    symbol, GetLastError());
        return false;
    }

    m_hEMAFast = iMA(symbol, PERIOD_H1, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
    m_hEMASlow = iMA(symbol, PERIOD_H1, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
    m_hADX     = iADX(symbol, PERIOD_H1, InpADXPeriod);
    m_hATR     = iATR(symbol, PERIOD_M15, InpATRPeriod);
    m_hRSI     = iRSI(symbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);

    if (m_hEMAFast == INVALID_HANDLE || m_hEMASlow == INVALID_HANDLE ||
        m_hADX    == INVALID_HANDLE || m_hATR   == INVALID_HANDLE ||
        m_hRSI    == INVALID_HANDLE) {
        PrintFormat("CSignalEngine::Init [%s]: indicator handle creation failed "
                    "(EMAFast=%d EMASlow=%d ADX=%d ATR=%d RSI=%d)",
                    symbol, m_hEMAFast, m_hEMASlow, m_hADX, m_hATR, m_hRSI);
        return false;
    }

    PrintFormat("CSignalEngine::Init [%s]: all handles created OK.", symbol);
    return true;
}

//+------------------------------------------------------------------+
//  Deinit — releases indicator handles
//+------------------------------------------------------------------+
void CSignalEngine::Deinit() {
    if (m_hEMAFast != INVALID_HANDLE) { IndicatorRelease(m_hEMAFast); m_hEMAFast = INVALID_HANDLE; }
    if (m_hEMASlow != INVALID_HANDLE) { IndicatorRelease(m_hEMASlow); m_hEMASlow = INVALID_HANDLE; }
    if (m_hADX     != INVALID_HANDLE) { IndicatorRelease(m_hADX);     m_hADX     = INVALID_HANDLE; }
    if (m_hATR     != INVALID_HANDLE) { IndicatorRelease(m_hATR);     m_hATR     = INVALID_HANDLE; }
    if (m_hRSI     != INVALID_HANDLE) { IndicatorRelease(m_hRSI);     m_hRSI     = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
//  RefreshIndicators — copies latest H1 and M15 values into cache.
//  All reads use index [1] (last COMPLETED bar) to prevent
//  look-ahead bias. Returns false if any CopyBuffer fails.
//+------------------------------------------------------------------+
bool CSignalEngine::RefreshIndicators() {
    double buf[];
    ArraySetAsSeries(buf, true);

    // ---- H1: 50-EMA --------------------------------------------------
    if (CopyBuffer(m_hEMAFast, 0, 1, 2, buf) < 2) {
        Print("CSignalEngine [", m_symbol, "]: CopyBuffer EMAFast failed. error=", GetLastError());
        return false;
    }
    m_emaFast = buf[0]; // [1] = last completed H1 bar

    // ---- H1: 200-EMA -------------------------------------------------
    if (CopyBuffer(m_hEMASlow, 0, 1, 2, buf) < 2) {
        Print("CSignalEngine [", m_symbol, "]: CopyBuffer EMASlow failed. error=", GetLastError());
        return false;
    }
    m_emaSlow = buf[0];

    // ---- H1: ADX (buffer 0 = main ADX line) --------------------------
    if (CopyBuffer(m_hADX, 0, 1, 2, buf) < 2) {
        Print("CSignalEngine [", m_symbol, "]: CopyBuffer ADX failed. error=", GetLastError());
        return false;
    }
    m_adx = buf[0];

    // ---- M15: ATR — need 21 bars: [1]..[21] for current ATR and
    //  the 20-bar average (bars [1] to [20])
    double atrBuf[];
    ArraySetAsSeries(atrBuf, true);
    if (CopyBuffer(m_hATR, 0, 1, 21, atrBuf) < 21) {
        Print("CSignalEngine [", m_symbol, "]: CopyBuffer ATR failed. error=", GetLastError());
        return false;
    }
    m_atr = atrBuf[0]; // last completed M15 bar ATR
    double atrSum = 0.0;
    for (int i = 0; i < 20; i++) atrSum += atrBuf[i];
    m_atrAvg20 = atrSum / 20.0;

    // ---- M15: RSI ---------------------------------------------------
    if (CopyBuffer(m_hRSI, 0, 1, 2, buf) < 2) {
        Print("CSignalEngine [", m_symbol, "]: CopyBuffer RSI failed. error=", GetLastError());
        return false;
    }
    m_rsi = buf[0];

    return true;
}

//+------------------------------------------------------------------+
//  RefreshPriceData — reads Close/High/Low[1] on M15 and computes
//  the swing high/low from bars [2 … 2+InpSwingLookback-1].
//+------------------------------------------------------------------+
bool CSignalEngine::RefreshPriceData() {
    // ---- Last completed M15 candle (index [1]) --------------------
    double closes[], highs[], lows[];
    ArraySetAsSeries(closes, true);
    ArraySetAsSeries(highs,  true);
    ArraySetAsSeries(lows,   true);

    if (CopyClose(m_symbol, PERIOD_M15, 1, 1, closes) < 1 ||
        CopyHigh( m_symbol, PERIOD_M15, 1, 1, highs)  < 1 ||
        CopyLow(  m_symbol, PERIOD_M15, 1, 1, lows)   < 1) {
        Print("CSignalEngine [", m_symbol, "]: CopyClose/High/Low [1] failed. error=", GetLastError());
        return false;
    }
    m_close1 = closes[0];
    m_high1  = highs[0];
    m_low1   = lows[0];

    // ---- Swing high/low: bars [2 … 2+N-1] on M15 -----------------
    // These are the N bars BEFORE the last completed bar, forming
    // the prior structure that the breakout must exceed.
    int N = InpSwingLookback;
    double swHigh[], swLow[];
    ArraySetAsSeries(swHigh, true);
    ArraySetAsSeries(swLow,  true);

    if (CopyHigh(m_symbol, PERIOD_M15, 2, N, swHigh) < N ||
        CopyLow( m_symbol, PERIOD_M15, 2, N, swLow)  < N) {
        Print("CSignalEngine [", m_symbol, "]: CopyHigh/Low swing range failed. error=", GetLastError());
        return false;
    }

    m_swingHigh = swHigh[ArrayMaximum(swHigh, 0, N)];
    m_swingLow  = swLow[ ArrayMinimum(swLow,  0, N)];

    return true;
}

//+------------------------------------------------------------------+
//  HasOpenPosition — returns true if this EA has any open position
//  on m_symbol (filtered by magic number). Prevents doubling into
//  an existing trade and enforces the no-hedging rule (SRS 2.5.3).
//+------------------------------------------------------------------+
bool CSignalEngine::HasOpenPosition() const {
    for (int i = 0; i < PositionsTotal(); i++) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL)  != m_symbol)       continue;
        if (PositionGetInteger(POSITION_MAGIC)  != InpMagicNumber)  continue;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//  CheckBuyConditions — evaluates all BUY entry filters (SRS 2.5.1)
//
//  Conditions (ALL must be true):
//   1. H1 50-EMA > H1 200-EMA            (bullish trend)
//   2. H1 ADX >= InpADXThreshold         (trend is strong)
//   3. M15 Close[1] > N-bar swing high   (breakout above structure)
//   4. M15 ATR[1] >= InpATRMinMultiplier x ATR_20avg  (volatility gate)
//   5. M15 RSI[1] in [InpRSIBuyMin, InpRSIBuyMax]     (52–70)
//   6. M15 High[1] - Close[1] >= InpPullbackMinATR x ATR  (pullback)
//   7. No open EA position on this symbol
//
//  Conditions 7-10 (session, news, spread, max-trades) are checked
//  by M5 and M1 respectively — this method tests only signal logic.
//+------------------------------------------------------------------+
bool CSignalEngine::CheckBuyConditions() const {
    // 1. Trend
    if (m_emaFast <= m_emaSlow) {
        PrintFormat("CSignalEngine [%s] BUY: EMA %s — 50EMA(%.5f) not above 200EMA(%.5f)",
                    m_symbol, "FAIL", m_emaFast, m_emaSlow);
        return false;
    }

    // 2. ADX trend strength
    if (m_adx < InpADXThreshold) {
        PrintFormat("CSignalEngine [%s] BUY: ADX %s — %.1f < %.1f",
                    m_symbol, "FAIL", m_adx, InpADXThreshold);
        return false;
    }

    // 3. Breakout above N-bar swing high
    if (m_close1 <= m_swingHigh) {
        PrintFormat("CSignalEngine [%s] BUY: Breakout %s — Close(%.5f) not above SwingHigh(%.5f)",
                    m_symbol, "FAIL", m_close1, m_swingHigh);
        return false;
    }

    // 4. ATR volatility gate
    double atrMin = InpATRMinMultiplier * m_atrAvg20;
    if (m_atr < atrMin) {
        PrintFormat("CSignalEngine [%s] BUY: ATR %s — %.5f < min %.5f (%.1fx avg)",
                    m_symbol, "FAIL", m_atr, atrMin, InpATRMinMultiplier);
        return false;
    }

    // 5. RSI momentum range
    if (m_rsi < InpRSIBuyMin || m_rsi > InpRSIBuyMax) {
        PrintFormat("CSignalEngine [%s] BUY: RSI %s — %.1f not in [%d, %d]",
                    m_symbol, "FAIL", m_rsi, InpRSIBuyMin, InpRSIBuyMax);
        return false;
    }

    // 6. Pullback from breakout candle's high (avoids chasing)
    double pullback = m_high1 - m_close1;
    double pullbackMin = InpPullbackMinATR * m_atr;
    if (pullback < pullbackMin) {
        PrintFormat("CSignalEngine [%s] BUY: Pullback %s — High-Close(%.5f) < min(%.5f)",
                    m_symbol, "FAIL", pullback, pullbackMin);
        return false;
    }

    // 7. No existing position on this symbol
    if (HasOpenPosition()) {
        Print("CSignalEngine [", m_symbol, "] BUY: BLOCKED — position already open.");
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//  CheckSellConditions — evaluates all SELL entry filters (SRS 2.5.2)
//
//  Conditions (ALL must be true):
//   1. H1 50-EMA < H1 200-EMA            (bearish trend)
//   2. H1 ADX >= InpADXThreshold         (trend is strong)
//   3. M15 Close[1] < N-bar swing low    (breakdown below structure)
//   4. M15 ATR[1] >= InpATRMinMultiplier x ATR_20avg
//   5. M15 RSI[1] in [InpRSISellMin, InpRSISellMax]   (30–48)
//   6. M15 Close[1] - Low[1] >= InpPullbackMinATR x ATR (bounce from low)
//   7. No open EA position on this symbol
//+------------------------------------------------------------------+
bool CSignalEngine::CheckSellConditions() const {
    // 1. Trend
    if (m_emaFast >= m_emaSlow) {
        PrintFormat("CSignalEngine [%s] SELL: EMA %s — 50EMA(%.5f) not below 200EMA(%.5f)",
                    m_symbol, "FAIL", m_emaFast, m_emaSlow);
        return false;
    }

    // 2. ADX trend strength
    if (m_adx < InpADXThreshold) {
        PrintFormat("CSignalEngine [%s] SELL: ADX %s — %.1f < %.1f",
                    m_symbol, "FAIL", m_adx, InpADXThreshold);
        return false;
    }

    // 3. Breakdown below N-bar swing low
    if (m_close1 >= m_swingLow) {
        PrintFormat("CSignalEngine [%s] SELL: Breakdown %s — Close(%.5f) not below SwingLow(%.5f)",
                    m_symbol, "FAIL", m_close1, m_swingLow);
        return false;
    }

    // 4. ATR volatility gate
    double atrMin = InpATRMinMultiplier * m_atrAvg20;
    if (m_atr < atrMin) {
        PrintFormat("CSignalEngine [%s] SELL: ATR %s — %.5f < min %.5f",
                    m_symbol, "FAIL", m_atr, atrMin);
        return false;
    }

    // 5. RSI momentum range
    if (m_rsi < InpRSISellMin || m_rsi > InpRSISellMax) {
        PrintFormat("CSignalEngine [%s] SELL: RSI %s — %.1f not in [%d, %d]",
                    m_symbol, "FAIL", m_rsi, InpRSISellMin, InpRSISellMax);
        return false;
    }

    // 6. Bounce from breakdown candle's low
    double bounce = m_close1 - m_low1;
    double bounceMin = InpPullbackMinATR * m_atr;
    if (bounce < bounceMin) {
        PrintFormat("CSignalEngine [%s] SELL: Bounce %s — Close-Low(%.5f) < min(%.5f)",
                    m_symbol, "FAIL", bounce, bounceMin);
        return false;
    }

    // 7. No existing position on this symbol
    if (HasOpenPosition()) {
        Print("CSignalEngine [", m_symbol, "] SELL: BLOCKED — position already open.");
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//  OnNewBar — called once per new M15 bar from the main EA.
//  Refreshes all indicator values, then evaluates BUY / SELL / NONE.
//  Results are stored in m_signal for retrieval via GetSignal().
//+------------------------------------------------------------------+
void CSignalEngine::OnNewBar() {
    m_signal  = SIGNAL_NONE;
    m_calcOk  = false;

    if (!RefreshIndicators() || !RefreshPriceData()) {
        Print("CSignalEngine [", m_symbol, "]: indicator refresh failed — signal skipped.");
        return;
    }
    m_calcOk = true;

    // Log indicator snapshot for every bar (aids backtesting diagnosis)
    PrintFormat("CSignalEngine [%s] | EMA50=%.5f EMA200=%.5f ADX=%.1f | "
                "ATR=%.5f ATRavg=%.5f RSI=%.1f | "
                "Close[1]=%.5f High[1]=%.5f Low[1]=%.5f | "
                "SwHigh=%.5f SwLow=%.5f",
                m_symbol,
                m_emaFast, m_emaSlow, m_adx,
                m_atr, m_atrAvg20, m_rsi,
                m_close1, m_high1, m_low1,
                m_swingHigh, m_swingLow);

    // Evaluate BUY first; if not valid, try SELL
    if (CheckBuyConditions()) {
        m_signal = SIGNAL_BUY;
        PrintFormat("CSignalEngine [%s]: >>> BUY signal <<<  ATR=%.5f  "
                    "SwHigh=%.5f  RSI=%.1f  ADX=%.1f",
                    m_symbol, m_atr, m_swingHigh, m_rsi, m_adx);
    } else if (CheckSellConditions()) {
        m_signal = SIGNAL_SELL;
        PrintFormat("CSignalEngine [%s]: >>> SELL signal <<<  ATR=%.5f  "
                    "SwLow=%.5f  RSI=%.1f  ADX=%.1f",
                    m_symbol, m_atr, m_swingLow, m_rsi, m_adx);
    }
}

//+------------------------------------------------------------------+
//  GetSLPrice — SL = entry +/- (ATR x InpSLMultiplier)  (SRS 2.6.1)
//+------------------------------------------------------------------+
double CSignalEngine::GetSLPrice(ENUM_SIGNAL sig, double entry) const {
    if (sig == SIGNAL_BUY)  return entry - (m_atr * InpSLMultiplier);
    if (sig == SIGNAL_SELL) return entry + (m_atr * InpSLMultiplier);
    return 0.0;
}

//+------------------------------------------------------------------+
//  GetTPPrice — TP = entry +/- (ATR x InpTPMultiplier)  (SRS 2.6.2)
//+------------------------------------------------------------------+
double CSignalEngine::GetTPPrice(ENUM_SIGNAL sig, double entry) const {
    if (sig == SIGNAL_BUY)  return entry + (m_atr * InpTPMultiplier);
    if (sig == SIGNAL_SELL) return entry - (m_atr * InpTPMultiplier);
    return 0.0;
}

#endif // SIGNALENGINE_MQH
