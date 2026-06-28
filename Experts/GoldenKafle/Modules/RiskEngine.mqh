//+------------------------------------------------------------------+
//|  Modules/RiskEngine.mqh — M1: Risk Management Engine            |
//|  FTMO-Compliant EA — SRS Part 3 / Section 6.9 Step 3            |
//+------------------------------------------------------------------+
#ifndef RISKENGINE_MQH
#define RISKENGINE_MQH

#include <Trade/Trade.mqh>
#include "../Config/Inputs.mqh"
#include "Utilities.mqh"   // ENUM_EA_STATE

//+------------------------------------------------------------------+
//|  CRiskEngine — M1 Risk Management Engine                         |
//|                                                                  |
//|  Responsibilities (runs BEFORE any signal or order logic):       |
//|    Init()              — record starting balance, restore state   |
//|    CheckDaily()        — daily DD gate; resets ref equity at dawn |
//|    CheckBalance()      — max balance DD gate; permanently disables|
//|    CalcLotSize()       — risk-based lot calculation (SRS 3.5)    |
//|    IsAllowedToTrade()  — combined gate checked before every entry |
//|    OnTradeClosed()     — updates consecutive-loss counter         |
//|    ResetPause()        — manual reset of pause state             |
//+------------------------------------------------------------------+
class CRiskEngine {
private:
    bool   m_haltedToday;       // set when daily DD >= InpDailyDDLimit
    bool   m_eaDisabled;        // set when balance DD >= InpMaxBalanceDD; never auto-clears
    bool   m_pausedForReview;   // set when consecutive losses >= InpMaxConsecLoss
    int    m_consecLosses;      // consecutive losing trades counter
    double m_startingBalance;   // AccountBalance() captured at OnInit()
    double m_dailyRefEquity;    // AccountEquity() at start of current broker day
    int    m_lastBrokerDay;     // day-of-month of last processed broker day

    CTrade m_trade;             // used only for emergency close-all operations

    // GlobalVariable key names — include magic number to avoid inter-EA collisions
    string m_gvStartBal;        // persists starting balance across EA restarts
    string m_gvDisabled;        // persists disabled flag across EA restarts

    void   CloseAllPositions(string reason);
    double ComputeDailyDD()   const;
    double ComputeBalanceDD() const;
    string GVKey(string tag)  const;

public:
    CRiskEngine();
    bool   Init();

    // Called every tick from OnTick() — must run before any other module
    void   CheckDaily();
    void   CheckBalance();

    // Pre-trade gate — returns true only when all conditions allow a new entry
    bool   IsAllowedToTrade() const;

    // Lot sizing per SRS Section 3.5
    double CalcLotSize(string symbol, double entryPrice, double slPrice) const;

    // Called by M4 / main EA after each position closes
    void   OnTradeClosed(bool win);

    // Manual reset of PAUSED_REVIEW state (via chart button or EA re-attach)
    void   ResetPause();

    // ---- State accessors (read by main EA and M5 dashboard) --------
    bool          IsHaltedToday()     const { return m_haltedToday;     }
    bool          IsDisabled()        const { return m_eaDisabled;      }
    bool          IsPausedForReview() const { return m_pausedForReview; }
    int           ConsecLosses()      const { return m_consecLosses;    }
    double        DailyDDPct()        const { return ComputeDailyDD();  }
    double        BalanceDDPct()      const { return ComputeBalanceDD();}
    double        StartingBalance()   const { return m_startingBalance; }
    double        DailyRefEquity()    const { return m_dailyRefEquity;  }
    ENUM_EA_STATE GetState()          const;
};

//+------------------------------------------------------------------+
//  Constructor
//+------------------------------------------------------------------+
CRiskEngine::CRiskEngine()
    : m_haltedToday(false),
      m_eaDisabled(false),
      m_pausedForReview(false),
      m_consecLosses(0),
      m_startingBalance(0.0),
      m_dailyRefEquity(0.0),
      m_lastBrokerDay(-1)
{}

//+------------------------------------------------------------------+
//  Private helpers
//+------------------------------------------------------------------+
string CRiskEngine::GVKey(string tag) const {
    return "GoldenKafle_" + tag + "_" + IntegerToString(InpMagicNumber);
}

double CRiskEngine::ComputeDailyDD() const {
    if (m_dailyRefEquity <= 0.0) return 0.0;
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    return (m_dailyRefEquity - equity) / m_dailyRefEquity * 100.0;
}

double CRiskEngine::ComputeBalanceDD() const {
    if (m_startingBalance <= 0.0) return 0.0;
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    return (m_startingBalance - balance) / m_startingBalance * 100.0;
}

//+------------------------------------------------------------------+
//  CloseAllPositions — emergency market-close of every position
//  managed by this EA (filtered by magic number and symbol).
//  Used when daily DD or balance DD limits are breached.
//+------------------------------------------------------------------+
void CRiskEngine::CloseAllPositions(string reason) {
    m_trade.SetExpertMagicNumber(InpMagicNumber);
    m_trade.SetDeviationInPoints(InpMaxSlippagePoints);
    m_trade.SetTypeFilling(ORDER_FILLING_FOK);

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        string sym = PositionGetString(POSITION_SYMBOL);
        bool ok = m_trade.PositionClose(ticket, InpMaxSlippagePoints);
        if (ok)
            PrintFormat("CRiskEngine: Closed position #%d (%s) — %s", ticket, sym, reason);
        else
            PrintFormat("CRiskEngine: Failed to close #%d — retcode %d", ticket, m_trade.ResultRetcode());
    }
}

//+------------------------------------------------------------------+
//  Init — called from OnInit()
//
//  1. Restores m_eaDisabled from GlobalVariable (survives EA restarts).
//  2. Records / restores m_startingBalance from GlobalVariable.
//     If the GV doesn't exist (first ever attach), uses current
//     AccountBalance() as the baseline.
//  3. Seeds m_dailyRefEquity with current AccountEquity().
//  4. Configures CTrade for emergency closes.
//+------------------------------------------------------------------+
bool CRiskEngine::Init() {
    m_gvStartBal  = GVKey("StartBal");
    m_gvDisabled  = GVKey("Disabled");

    // ---- Restore disabled flag -----------------------------------
    if (GlobalVariableCheck(m_gvDisabled)) {
        m_eaDisabled = (GlobalVariableGet(m_gvDisabled) != 0.0);
        if (m_eaDisabled) {
            Print("CRiskEngine::Init: EA is DISABLED (balance DD limit was previously hit). "
                  "Remove and re-attach to reset.");
            return true; // Init succeeds but EA is in read-only mode
        }
    }

    // ---- Starting balance ----------------------------------------
    if (GlobalVariableCheck(m_gvStartBal)) {
        double stored = GlobalVariableGet(m_gvStartBal);
        if (stored > 0.0) {
            m_startingBalance = stored;
            PrintFormat("CRiskEngine::Init: Restored starting balance = %.2f from GlobalVariable.",
                        m_startingBalance);
        }
    }
    if (m_startingBalance <= 0.0) {
        m_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        GlobalVariableSet(m_gvStartBal, m_startingBalance);
        PrintFormat("CRiskEngine::Init: Starting balance set to %.2f and persisted.",
                    m_startingBalance);
    }

    // ---- Seed daily reference -----------------------------------
    m_dailyRefEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    m_lastBrokerDay = dt.day;

    // ---- Configure CTrade for emergency closes ------------------
    m_trade.SetExpertMagicNumber(InpMagicNumber);
    m_trade.SetDeviationInPoints(InpMaxSlippagePoints);
    m_trade.SetTypeFilling(ORDER_FILLING_FOK);

    PrintFormat("CRiskEngine::Init: Ready. StartBal=%.2f  DailyRef=%.2f",
                m_startingBalance, m_dailyRefEquity);
    return true;
}

//+------------------------------------------------------------------+
//  CheckDaily — called EVERY TICK from OnTick()
//
//  1. Detects a new broker day; resets m_haltedToday and updates
//     m_dailyRefEquity at the first tick of each new day.
//  2. Computes current daily equity drawdown.
//  3. If drawdown >= InpDailyDDLimit: halts trading for remainder
//     of broker day and closes all open positions.
//+------------------------------------------------------------------+
void CRiskEngine::CheckDaily() {
    if (m_eaDisabled) return;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // ---- New broker day detected --------------------------------
    if (dt.day != m_lastBrokerDay) {
        m_lastBrokerDay  = dt.day;
        m_haltedToday    = false;
        m_dailyRefEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        PrintFormat("CRiskEngine: New broker day — daily halt cleared, "
                    "ref equity reset to %.2f.", m_dailyRefEquity);
    }

    if (m_haltedToday) return; // already halted today; nothing more to do

    // ---- Daily DD check ----------------------------------------
    double dd = ComputeDailyDD();
    if (dd >= InpDailyDDLimit) {
        m_haltedToday = true;
        PrintFormat("CRiskEngine: DAILY HALT — equity drawdown %.2f%% >= limit %.1f%%. "
                    "Equity=%.2f  Ref=%.2f  Time=%s",
                    dd, InpDailyDDLimit,
                    AccountInfoDouble(ACCOUNT_EQUITY), m_dailyRefEquity,
                    TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
        CloseAllPositions("Daily DD limit hit");
    }
}

//+------------------------------------------------------------------+
//  CheckBalance — called EVERY TICK from OnTick()
//
//  Computes balance drawdown from the recorded starting balance.
//  If drawdown >= InpMaxBalanceDD: permanently disables the EA,
//  persists the disabled flag to GlobalVariables, closes all
//  positions, and fires a visible alert.
//
//  Once disabled the EA cannot resume without manual re-attachment.
//+------------------------------------------------------------------+
void CRiskEngine::CheckBalance() {
    if (m_eaDisabled) return;

    double dd = ComputeBalanceDD();
    if (dd >= InpMaxBalanceDD) {
        m_eaDisabled = true;
        GlobalVariableSet(m_gvDisabled, 1.0);

        string msg = StringFormat(
            "GoldenKafle DISABLED — balance drawdown %.2f%% >= hard limit %.1f%%. "
            "Balance=%.2f  StartBal=%.2f. Remove and re-attach EA to restart.",
            dd, InpMaxBalanceDD,
            AccountInfoDouble(ACCOUNT_BALANCE), m_startingBalance);

        Print("CRiskEngine: ", msg);
        Alert(msg);
        CloseAllPositions("Max balance DD hit — EA disabled");
    }
}

//+------------------------------------------------------------------+
//  IsAllowedToTrade — pre-trade gate
//
//  Returns true only when ALL of the following hold:
//    • EA is not permanently disabled
//    • EA is not halted for today
//    • EA is not paused pending review
//    • Open position count is below InpMaxOpenTrades
//+------------------------------------------------------------------+
bool CRiskEngine::IsAllowedToTrade() const {
    if (m_eaDisabled) {
        Print("CRiskEngine::IsAllowedToTrade: BLOCKED — EA is permanently disabled.");
        return false;
    }
    if (m_haltedToday) {
        Print("CRiskEngine::IsAllowedToTrade: BLOCKED — daily DD halt active.");
        return false;
    }
    if (m_pausedForReview) {
        Print("CRiskEngine::IsAllowedToTrade: BLOCKED — paused for review (consecutive losses).");
        return false;
    }

    // Count only positions belonging to this EA
    int openCount = 0;
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) openCount++;
    }
    if (openCount >= InpMaxOpenTrades) {
        PrintFormat("CRiskEngine::IsAllowedToTrade: BLOCKED — %d/%d positions open.",
                    openCount, InpMaxOpenTrades);
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//  CalcLotSize — risk-based lot calculation per SRS Section 3.5
//
//  Parameters:
//    symbol     — trading symbol (e.g. "XAUUSD")
//    entryPrice — planned entry price
//    slPrice    — planned stop-loss price
//
//  Returns 0.0 on any calculation error (caller must treat as abort).
//+------------------------------------------------------------------+
double CRiskEngine::CalcLotSize(string symbol, double entryPrice, double slPrice) const {
    if (slPrice <= 0.0 || entryPrice <= 0.0 || MathAbs(entryPrice - slPrice) < 1e-10) {
        Print("CRiskEngine::CalcLotSize: Invalid entry or SL price.");
        return 0.0;
    }

    double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmt   = equity * InpRiskPerTrade / 100.0;

    double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

    if (point <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0) {
        PrintFormat("CRiskEngine::CalcLotSize: Symbol info error on '%s' "
                    "(point=%.10f  tickSize=%.10f  tickValue=%.10f)",
                    symbol, point, tickSize, tickValue);
        return 0.0;
    }

    // SL distance in points
    double slPoints   = MathAbs(entryPrice - slPrice) / point;
    if (slPoints < 1.0) {
        Print("CRiskEngine::CalcLotSize: SL distance < 1 point — aborting.");
        return 0.0;
    }

    // Monetary value per 1 lot per 1 point move
    double pointValue = tickValue / tickSize * point;
    if (pointValue <= 0.0) {
        Print("CRiskEngine::CalcLotSize: pointValue <= 0 — aborting.");
        return 0.0;
    }

    double rawLots = riskAmt / (slPoints * pointValue);

    // Normalise to broker lot step and clamp to [MinLot, MaxLot]
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

    if (lotStep <= 0.0) lotStep = 0.01;

    double lots = MathFloor(rawLots / lotStep) * lotStep;
    lots = MathMax(minLot, MathMin(maxLot, lots));

    PrintFormat("CRiskEngine::CalcLotSize: [%s] Equity=%.2f  Risk=%.2f  "
                "SLpts=%.1f  PointVal=%.6f  RawLots=%.4f  FinalLots=%.2f",
                symbol, equity, riskAmt, slPoints, pointValue, rawLots, lots);

    return lots;
}

//+------------------------------------------------------------------+
//  OnTradeClosed — called by M4 / main EA after every position close
//
//  Updates the consecutive-loss counter per SRS Section 3.7:
//    • Losing trade  → increment counter; halt if limit reached
//    • Winning trade → reset counter to zero
//+------------------------------------------------------------------+
void CRiskEngine::OnTradeClosed(bool win) {
    if (win) {
        if (m_consecLosses > 0)
            PrintFormat("CRiskEngine: Winning trade — consecutive loss counter reset (was %d).",
                        m_consecLosses);
        m_consecLosses = 0;
    } else {
        m_consecLosses++;
        PrintFormat("CRiskEngine: Losing trade — consecutive losses now %d / %d.",
                    m_consecLosses, InpMaxConsecLoss);

        if (m_consecLosses >= InpMaxConsecLoss && !m_pausedForReview) {
            m_pausedForReview = true;
            string msg = StringFormat(
                "GoldenKafle PAUSED — %d consecutive losses (limit: %d). "
                "No new trades will open. Manual reset required.",
                m_consecLosses, InpMaxConsecLoss);
            Print("CRiskEngine: ", msg);
            Alert(msg);
        }
    }
}

//+------------------------------------------------------------------+
//  ResetPause — clears the PAUSED_REVIEW state
//  Called via chart button or EA re-attach with a reset input flag.
//+------------------------------------------------------------------+
void CRiskEngine::ResetPause() {
    if (m_pausedForReview) {
        m_pausedForReview = false;
        m_consecLosses    = 0;
        Print("CRiskEngine::ResetPause: Pause cleared — EA resuming normal operation.");
    }
}

//+------------------------------------------------------------------+
//  GetState — returns the current EA state machine state
//  Priority: DISABLED > HALTED_TODAY > PAUSED_REVIEW > ACTIVE
//+------------------------------------------------------------------+
ENUM_EA_STATE CRiskEngine::GetState() const {
    if (m_eaDisabled)      return EA_DISABLED;
    if (m_haltedToday)     return EA_HALTED_TODAY;
    if (m_pausedForReview) return EA_PAUSED_REVIEW;
    return EA_ACTIVE;
}

#endif // RISKENGINE_MQH
