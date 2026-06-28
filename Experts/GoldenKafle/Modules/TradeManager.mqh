//+------------------------------------------------------------------+
//|  Modules/TradeManager.mqh — M4: Trade Lifecycle Manager          |
//|  FTMO-Compliant EA — SRS Part 4 / Section 6.9 Step 6            |
//+------------------------------------------------------------------+
#ifndef TRADEMANAGER_MQH
#define TRADEMANAGER_MQH

#include <Trade/Trade.mqh>
#include "../Config/Inputs.mqh"
#include "Execution.mqh"

//--- Per-position state record ------------------------------------
struct STradeRecord {
    ulong  ticket;
    double atrAtEntry;      // ATR value at trade open (used for BE/trail calc)
    bool   beApplied;       // true after break-even SL has been set once
    bool   partialClosed;   // true after 50% partial close executed
};

//+------------------------------------------------------------------+
//|  CTradeManager — M4 Trade Lifecycle Module                       |
//|                                                                  |
//|  Runs on every new M15 bar (never per-tick). Manages:           |
//|    Break-even  — SL moved to entry + 0.1*ATR once +1R reached  |
//|    Trailing    — ATR-based trail after BE is applied            |
//|    Duration    — closes positions open > InpMaxHoldingBars bars  |
//|    Partial     — optional 50% close at +1R (InpEnablePartialClose)|
//|    Friday      — closes all positions at Friday 20:00 UTC       |
//|                                                                  |
//|  Requires a pointer to CExecution (M3) for ModifyPosition and   |
//|  ClosePosition. Call RegisterTrade() immediately after a new    |
//|  position is opened so ATR at entry is recorded precisely.      |
//+------------------------------------------------------------------+
class CTradeManager {
private:
    CExecution  *m_exec;        // pointer to M3 — provided in Init()
    CTrade       m_trade;       // used only for PositionClosePartial

    STradeRecord m_records[];
    int          m_count;

    // ---- Record management helpers -------------------------------
    int    FindRecord(ulong ticket)                                  const;
    void   AddRecord(ulong ticket, double atr,
                     bool beApplied = false, bool partClosed = false);
    void   RemoveRecord(int idx);
    void   SyncRecords();
    double EstimateATRFromPosition(ulong ticket, bool &beDetected)   const;

    // ---- Per-position processing --------------------------------
    void   ProcessPosition(int recIdx);
    bool   TryBreakEven(int recIdx);
    bool   TryTrailing(int recIdx);
    bool   TryPartialClose(int recIdx);
    void   CheckDuration(int recIdx);

    // ---- Account-level checks -----------------------------------
    void   CheckFridayClose();

    // ---- Price helpers ------------------------------------------
    double GetM15Close1(string symbol) const;
    double GetCurrentPrice(string symbol, ENUM_POSITION_TYPE type) const;

public:
    CTradeManager();
    bool Init(CExecution *exec);

    // Called once per new M15 bar — full lifecycle management pass
    void OnNewBar();

    // Called by main EA immediately after a successful PlaceOrder()
    void RegisterTrade(ulong ticket, double atrAtEntry);
};

//+------------------------------------------------------------------+
//  Constructor
//+------------------------------------------------------------------+
CTradeManager::CTradeManager() : m_exec(NULL), m_count(0) {}

//+------------------------------------------------------------------+
//  Init — stores M3 reference and configures the internal CTrade
//  instance used exclusively for partial close operations.
//+------------------------------------------------------------------+
bool CTradeManager::Init(CExecution *exec) {
    if (exec == NULL) {
        Print("CTradeManager::Init: CExecution pointer is NULL — aborting.");
        return false;
    }
    m_exec = exec;

    m_trade.SetExpertMagicNumber(InpMagicNumber);
    m_trade.SetDeviationInPoints(InpMaxSlippagePoints);
    m_trade.SetTypeFilling(ORDER_FILLING_FOK);

    Print("CTradeManager::Init: ready.");
    return true;
}

//+------------------------------------------------------------------+
//  RegisterTrade — records the ATR at entry for a newly opened
//  position. Call immediately after PlaceOrder() returns a ticket.
//+------------------------------------------------------------------+
void CTradeManager::RegisterTrade(ulong ticket, double atrAtEntry) {
    if (FindRecord(ticket) >= 0) return;  // already registered
    AddRecord(ticket, atrAtEntry, false, false);
    PrintFormat("CTradeManager::RegisterTrade: #%d registered  ATR=%.5f",
                ticket, atrAtEntry);
}

//+------------------------------------------------------------------+
//  OnNewBar — orchestrates the full management pass.
//  Called once per new M15 bar from the main EA OnTick handler.
//+------------------------------------------------------------------+
void CTradeManager::OnNewBar() {
    // 1. Friday close gate (account-wide; runs first)
    CheckFridayClose();

    // 2. Synchronise position records (detect new / remove closed)
    SyncRecords();

    // 3. Process each tracked position
    for (int i = 0; i < m_count; i++) {
        if (!PositionSelectByTicket(m_records[i].ticket)) continue;
        ProcessPosition(i);
    }
}

//+=================================================================+
//  Private — Record management
//+=================================================================+

int CTradeManager::FindRecord(ulong ticket) const {
    for (int i = 0; i < m_count; i++)
        if (m_records[i].ticket == ticket) return i;
    return -1;
}

void CTradeManager::AddRecord(ulong ticket, double atr, bool beApplied, bool partClosed) {
    ArrayResize(m_records, m_count + 1);
    m_records[m_count].ticket        = ticket;
    m_records[m_count].atrAtEntry    = atr;
    m_records[m_count].beApplied     = beApplied;
    m_records[m_count].partialClosed = partClosed;
    m_count++;
}

void CTradeManager::RemoveRecord(int idx) {
    if (idx < 0 || idx >= m_count) return;
    for (int i = idx; i < m_count - 1; i++)
        m_records[i] = m_records[i + 1];
    m_count--;
    ArrayResize(m_records, m_count);
}

//+------------------------------------------------------------------+
//  EstimateATRFromPosition — derives ATR at entry from position data.
//  Used when a position is found that was not registered (EA restart).
//
//  Detection logic:
//   If SL is on the profitable side of entry (BUY: SL >= OpenPrice /
//   SELL: SL <= OpenPrice), break-even was already applied.
//     → ATR = |SL - OpenPrice| / 0.1   (SL = entry ± 0.1*ATR)
//   Otherwise the original SL is still in place:
//     → ATR = |SL - OpenPrice| / InpSLMultiplier
//+------------------------------------------------------------------+
double CTradeManager::EstimateATRFromPosition(ulong ticket, bool &beDetected) const {
    beDetected = false;
    if (!PositionSelectByTicket(ticket)) return 0.0;

    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl        = PositionGetDouble(POSITION_SL);
    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    if (sl <= 0.0 || openPrice <= 0.0) return 0.0;

    double slDist = MathAbs(openPrice - sl);

    // Detect BE applied: SL has crossed to the profitable side of entry
    beDetected = (type == POSITION_TYPE_BUY  && sl >= openPrice) ||
                 (type == POSITION_TYPE_SELL && sl <= openPrice);

    double atrEst = beDetected
        ? slDist / 0.1              // SL ≈ entry ± 0.1*ATR
        : slDist / InpSLMultiplier; // SL ≈ entry ± 1.8*ATR

    PrintFormat("CTradeManager::EstimateATR #%d: slDist=%.5f  BE=%s  ATR_est=%.5f",
                ticket, slDist, beDetected ? "yes" : "no", atrEst);
    return atrEst;
}

//+------------------------------------------------------------------+
//  SyncRecords — aligns m_records[] with currently open positions.
//  New positions (e.g., after EA restart) are added with estimated ATR.
//  Records for closed positions are removed.
//+------------------------------------------------------------------+
void CTradeManager::SyncRecords() {
    // Collect open EA tickets
    ulong openTickets[];
    int   openCount = 0;

    for (int i = 0; i < PositionsTotal(); i++) {
        ulong t = PositionGetTicket(i);
        if (t == 0) continue;
        if ((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
        ArrayResize(openTickets, openCount + 1);
        openTickets[openCount++] = t;
    }

    // Add records for positions not yet registered (EA restart recovery)
    for (int i = 0; i < openCount; i++) {
        if (FindRecord(openTickets[i]) < 0) {
            bool beDetected = false;
            double atrEst = EstimateATRFromPosition(openTickets[i], beDetected);
            AddRecord(openTickets[i], atrEst, beDetected, false);
            PrintFormat("CTradeManager::SyncRecords: recovered position #%d  "
                        "ATR_est=%.5f  BE=%s",
                        openTickets[i], atrEst, beDetected ? "yes" : "no");
        }
    }

    // Remove records whose position is no longer open
    for (int i = m_count - 1; i >= 0; i--) {
        bool stillOpen = false;
        for (int j = 0; j < openCount; j++) {
            if (openTickets[j] == m_records[i].ticket) { stillOpen = true; break; }
        }
        if (!stillOpen) {
            PrintFormat("CTradeManager::SyncRecords: position #%d closed — removing record.",
                        m_records[i].ticket);
            RemoveRecord(i);
        }
    }
}

//+=================================================================+
//  Private — Per-position lifecycle
//+=================================================================+

//+------------------------------------------------------------------+
//  ProcessPosition — dispatches all lifecycle checks for one position.
//  Order matters: partial close → break-even → trailing → duration.
//+------------------------------------------------------------------+
void CTradeManager::ProcessPosition(int recIdx) {
    ulong  ticket   = m_records[recIdx].ticket;
    string symbol   = PositionGetString(POSITION_SYMBOL);
    double openTime = (double)PositionGetInteger(POSITION_TIME);
    double nowTime  = (double)TimeCurrent();

    // Enforce minimum trade duration before ANY SL modification (SRS 2.6.5 / 4.2)
    if ((nowTime - openTime) < InpMinTradeDurationSec) {
        PrintFormat("CTradeManager #%d: skipping — trade < %d s old.",
                    ticket, InpMinTradeDurationSec);
        return;
    }

    // Partial close first (only triggers once, before break-even)
    if (InpEnablePartialClose && !m_records[recIdx].partialClosed)
        TryPartialClose(recIdx);

    // Break-even (once per trade lifetime)
    if (!m_records[recIdx].beApplied)
        TryBreakEven(recIdx);

    // Trailing stop (only after BE is in place)
    if (m_records[recIdx].beApplied)
        TryTrailing(recIdx);

    // Maximum holding duration check
    CheckDuration(recIdx);
}

//+------------------------------------------------------------------+
//  TryBreakEven — moves SL to entry + 0.1*ATR once +1R is reached.
//  (SRS Section 4.2)
//
//  Trigger: current unrealised profit in price terms >= original SL
//  distance (= 1R = InpSLMultiplier * ATR_at_entry).
//
//  New SL = OpenPrice ± 0.1 * ATR_at_entry  (buffer keeps it off-spread)
//  Only applied if new SL is strictly better than the current SL.
//  Applied once and only once (beApplied flag).
//+------------------------------------------------------------------+
bool CTradeManager::TryBreakEven(int recIdx) {
    ulong  ticket      = m_records[recIdx].ticket;
    double atr         = m_records[recIdx].atrAtEntry;
    if (atr <= 0.0) return false;

    if (!PositionSelectByTicket(ticket)) return false;

    string sym         = PositionGetString(POSITION_SYMBOL);
    double openPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
    double currentSL   = PositionGetDouble(POSITION_SL);
    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    double oneR        = InpSLMultiplier * atr;       // original SL distance
    double currentPx   = GetCurrentPrice(sym, type);  // Bid for long, Ask for short
    double profitPts   = (type == POSITION_TYPE_BUY)
                         ? (currentPx - openPrice)
                         : (openPrice - currentPx);

    if (profitPts < oneR) return false;   // +1R not yet reached

    // Calculate BE price with small buffer
    double bePrice = (type == POSITION_TYPE_BUY)
                     ? openPrice + 0.1 * atr
                     : openPrice - 0.1 * atr;

    // Only update if improvement (avoid worsening SL)
    bool isBetter = (type == POSITION_TYPE_BUY)
                    ? (bePrice > currentSL)
                    : (currentSL <= 0.0 || bePrice < currentSL);

    if (!isBetter) return false;

    bool ok = m_exec.ModifyPosition(ticket, bePrice, 0.0);
    if (ok) {
        m_records[recIdx].beApplied = true;
        PrintFormat("CTradeManager #%d: BREAK-EVEN applied — SL %.5f → %.5f  (profit=%.5f  1R=%.5f)",
                    ticket, currentSL, bePrice, profitPts, oneR);
    }
    return ok;
}

//+------------------------------------------------------------------+
//  TryTrailing — advances the ATR-based trailing stop after BE.
//  (SRS Section 4.3)
//
//  Trail distance = InpTrailATRMultiplier * ATR_at_entry
//  Reference price = Close[1] M15 (bar close, not tick — SRS explicit)
//  Stop never moves backward (only tightens in trade direction).
//+------------------------------------------------------------------+
bool CTradeManager::TryTrailing(int recIdx) {
    ulong  ticket  = m_records[recIdx].ticket;
    double atr     = m_records[recIdx].atrAtEntry;
    if (atr <= 0.0) return false;

    if (!PositionSelectByTicket(ticket)) return false;

    string sym     = PositionGetString(POSITION_SYMBOL);
    double currentSL = PositionGetDouble(POSITION_SL);
    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    double trailDist = InpTrailATRMultiplier * atr;
    double close1    = GetM15Close1(sym);
    if (close1 <= 0.0) return false;

    double newSL = (type == POSITION_TYPE_BUY)
                   ? close1 - trailDist
                   : close1 + trailDist;

    // Only advance the stop — never move it backward
    bool shouldUpdate = (type == POSITION_TYPE_BUY)
                        ? (newSL > currentSL)
                        : (currentSL <= 0.0 || newSL < currentSL);

    if (!shouldUpdate) return false;

    bool ok = m_exec.ModifyPosition(ticket, newSL, 0.0);
    if (ok)
        PrintFormat("CTradeManager #%d: TRAIL advanced — SL %.5f → %.5f  (close1=%.5f  dist=%.5f)",
                    ticket, currentSL, newSL, close1, trailDist);
    return ok;
}

//+------------------------------------------------------------------+
//  TryPartialClose — closes 50% of position when +1R is reached,
//  then applies break-even to the remaining half. (SRS Section 4.6)
//  Only executes when InpEnablePartialClose = true.
//+------------------------------------------------------------------+
bool CTradeManager::TryPartialClose(int recIdx) {
    ulong  ticket    = m_records[recIdx].ticket;
    double atr       = m_records[recIdx].atrAtEntry;
    if (atr <= 0.0) return false;

    if (!PositionSelectByTicket(ticket)) return false;

    string sym        = PositionGetString(POSITION_SYMBOL);
    double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
    double totalLots  = PositionGetDouble(POSITION_VOLUME);
    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    double oneR      = InpSLMultiplier * atr;
    double currentPx = GetCurrentPrice(sym, type);
    double profitPts = (type == POSITION_TYPE_BUY)
                       ? (currentPx - openPrice)
                       : (openPrice - currentPx);

    if (profitPts < oneR) return false;   // +1R not yet reached

    // Calculate half-lots, normalised to broker's lot step
    double lotStep  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
    double minLot   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
    double halfLots = MathFloor((totalLots / 2.0) / lotStep) * lotStep;
    if (halfLots < minLot) {
        Print("CTradeManager::TryPartialClose #", ticket,
              ": half lot (", halfLots, ") below minLot (", minLot, ") — skipping.");
        return false;
    }

    bool ok = m_trade.PositionClosePartial(ticket, halfLots, InpMaxSlippagePoints);
    if (!ok) {
        PrintFormat("CTradeManager::TryPartialClose #%d: FAILED retcode=%d (%s)",
                    ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
        return false;
    }

    m_records[recIdx].partialClosed = true;
    PrintFormat("CTradeManager #%d: PARTIAL CLOSE — closed %.2f of %.2f lots at +1R",
                ticket, halfLots, totalLots);

    // Immediately apply break-even on the remaining half
    if (!m_records[recIdx].beApplied)
        TryBreakEven(recIdx);

    return true;
}

//+------------------------------------------------------------------+
//  CheckDuration — force-closes positions open longer than
//  InpMaxHoldingBars M15 bars (default 96 = 24 hours). (SRS 4.5)
//+------------------------------------------------------------------+
void CTradeManager::CheckDuration(int recIdx) {
    ulong ticket = m_records[recIdx].ticket;
    if (!PositionSelectByTicket(ticket)) return;

    datetime openTime  = (datetime)PositionGetInteger(POSITION_TIME);
    string   sym       = PositionGetString(POSITION_SYMBOL);
    long     elapsedSec = (long)(TimeCurrent() - openTime);
    long     maxSec     = (long)InpMaxHoldingBars * 15 * 60;  // bars → seconds

    if (elapsedSec < maxSec) return;

    PrintFormat("CTradeManager #%d [%s]: MAX DURATION exceeded (%d bars) — closing.",
                ticket, sym, InpMaxHoldingBars);
    m_exec.ClosePosition(ticket);
}

//+------------------------------------------------------------------+
//  CheckFridayClose — closes all EA positions when InpCloseOnFriday
//  is enabled and it is Friday at or after 20:00 UTC. (SRS 4.4)
//+------------------------------------------------------------------+
void CTradeManager::CheckFridayClose() {
    if (!InpCloseOnFriday) return;

    MqlDateTime utc;
    TimeToStruct(TimeGMT(), utc);
    if (utc.day_of_week != 5 || utc.hour < 20) return;  // not Friday 20:00+

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong t = PositionGetTicket(i);
        if (t == 0) continue;
        if ((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        string sym = PositionGetString(POSITION_SYMBOL);
        PrintFormat("CTradeManager #%d [%s]: Friday 20:00 UTC — closing (weekend gap prevention).",
                    t, sym);
        m_exec.ClosePosition(t);
    }
}

//+=================================================================+
//  Private — Price helpers
//+=================================================================+

double CTradeManager::GetM15Close1(string symbol) const {
    double buf[];
    ArraySetAsSeries(buf, true);
    if (CopyClose(symbol, PERIOD_M15, 1, 1, buf) < 1) return 0.0;
    return buf[0];
}

// Returns the relevant current price for P&L evaluation:
//   BUY  → Bid  (what you receive when selling the long)
//   SELL → Ask  (what you pay when covering the short)
double CTradeManager::GetCurrentPrice(string symbol, ENUM_POSITION_TYPE type) const {
    return (type == POSITION_TYPE_BUY)
           ? SymbolInfoDouble(symbol, SYMBOL_BID)
           : SymbolInfoDouble(symbol, SYMBOL_ASK);
}

#endif // TRADEMANAGER_MQH
