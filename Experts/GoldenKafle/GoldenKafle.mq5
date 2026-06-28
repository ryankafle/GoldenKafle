//+------------------------------------------------------------------+
//|  GoldenKafle.mq5 — Main Expert Advisor                          |
//|  FTMO-Compliant Multi-Symbol EA — SRS Version 1.0               |
//|  Section 6.9 Step 7: Integration, OnInit / OnTick / OnDeinit    |
//+------------------------------------------------------------------+
#property copyright "GoldenKafle — Proprietary"
#property version   "1.00"
#property description "GoldenKafle — FTMO-compliant EA: XAUUSD primary, EURUSD optional secondary."
#property description "Trend-following breakout strategy with ATR-based risk management."

//--- Additional deployment inputs (not in Inputs.mqh) --------------
input group "=== Symbol Selection ==="
input bool   InpEnableEURUSD  = false;  // Enable EURUSD as secondary instrument
input group "=== Manual Overrides ==="
input bool   InpResetPause    = false;  // Set true to clear PAUSED_REVIEW state on next init

//--- Module includes -----------------------------------------------
#include "Config/Inputs.mqh"
#include "Modules/Utilities.mqh"
#include "Modules/RiskEngine.mqh"
#include "Modules/SignalEngine.mqh"
#include "Modules/Execution.mqh"
#include "Modules/TradeManager.mqh"

//--- Module instances (one per role; signal engines per symbol) ----
CUtilities    g_utils;
CRiskEngine   g_risk;
CSignalEngine g_sigXAU;       // primary   — XAUUSD
CSignalEngine g_sigEUR;       // secondary — EURUSD (when InpEnableEURUSD)
CExecution    g_exec;
CTradeManager g_tradeMgr;

//--- Runtime state -------------------------------------------------
datetime g_lastBarTime = 0;   // last processed M15 bar timestamp

//--- Fixed symbol identifiers -------------------------------------
const string SYM_XAU = "XAUUSD";
const string SYM_EUR = "EURUSD";

//+==================================================================+
//  HELPERS
//+==================================================================+

//--- Count open positions belonging to this EA ---------------------
int CountOpenPositions() {
    int n = 0;
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) == 0) continue;
        if ((long)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) n++;
    }
    return n;
}

//--- Place one order from a signal engine result -------------------
//  Validates spread, calculates lot size, submits via M3, and
//  registers the new ticket with M4 and logs the placement.
//
//  Returns the assigned ticket, or 0 on failure.
//+------------------------------------------------------------------+
ulong PlaceSignalOrder(CSignalEngine &sig, ENUM_SIGNAL direction) {
    string sym = sig.GetSymbol();

    if (!g_exec.CheckSpread(sym)) return 0;

    ENUM_ORDER_TYPE orderType = (direction == SIGNAL_BUY)
                                ? ORDER_TYPE_BUY
                                : ORDER_TYPE_SELL;

    double entry = (direction == SIGNAL_BUY)
                   ? SymbolInfoDouble(sym, SYMBOL_ASK)
                   : SymbolInfoDouble(sym, SYMBOL_BID);

    if (entry <= 0.0) {
        Print("PlaceSignalOrder [", sym, "]: invalid price — aborting.");
        return 0;
    }

    double sl  = sig.GetSLPrice(direction, entry);
    double tp  = sig.GetTPPrice(direction, entry);
    double atr = sig.GetATR();

    double lots = g_risk.CalcLotSize(sym, entry, sl);
    if (lots <= 0.0) {
        Print("PlaceSignalOrder [", sym, "]: lot size = 0 — aborting.");
        return 0;
    }

    string comment = StringFormat("%s_%s", sym,
                                  (direction == SIGNAL_BUY) ? "BUY" : "SELL");

    ulong ticket = g_exec.PlaceOrder(sym, orderType, lots, sl, tp, comment);
    if (ticket == 0) return 0;

    // Register with M4 so break-even / trailing can reference ATR at entry
    g_tradeMgr.RegisterTrade(ticket, atr);

    PrintFormat("[ENTRY] #%d %s %s | Lots=%.2f  Entry=%.5f  SL=%.5f  TP=%.5f  ATR=%.5f",
                ticket, sym, (direction == SIGNAL_BUY) ? "BUY" : "SELL",
                lots, entry, sl, tp, atr);
    return ticket;
}

//--- Correlation filter + signal dispatch --------------------------
//  If both symbols signal in the same direction simultaneously,
//  only the trade with the higher H1 ADX is placed (SRS 3.6).
//  Opposite-direction signals from both symbols are each accepted.
//+------------------------------------------------------------------+
void ProcessSignals() {
    ENUM_SIGNAL sXAU = g_sigXAU.GetSignal();
    ENUM_SIGNAL sEUR = InpEnableEURUSD ? g_sigEUR.GetSignal() : SIGNAL_NONE;

    // Correlation gate: same direction → take the stronger trend only
    if (sXAU != SIGNAL_NONE && sEUR != SIGNAL_NONE && sXAU == sEUR) {
        if (g_sigXAU.GetADX() >= g_sigEUR.GetADX()) {
            PrintFormat("Correlation filter: XAU ADX %.1f >= EUR ADX %.1f — EUR discarded",
                        g_sigXAU.GetADX(), g_sigEUR.GetADX());
            sEUR = SIGNAL_NONE;
        } else {
            PrintFormat("Correlation filter: EUR ADX %.1f > XAU ADX %.1f — XAU discarded",
                        g_sigEUR.GetADX(), g_sigXAU.GetADX());
            sXAU = SIGNAL_NONE;
        }
    }

    if (sXAU != SIGNAL_NONE) PlaceSignalOrder(g_sigXAU, sXAU);
    if (sEUR != SIGNAL_NONE) PlaceSignalOrder(g_sigEUR, sEUR);
}

//--- Retrieve opening deal info for a position from history --------
bool GetOpeningDealInfo(ulong positionId,
                        datetime &openTime,  double &openPrice,
                        string   &direction, double &sl, double &tp) {
    openTime  = 0; openPrice = 0;
    direction = ""; sl = 0; tp = 0;

    if (!HistorySelectByPosition(positionId)) return false;

    // Opening deal: DEAL_ENTRY_IN
    for (int i = 0; i < HistoryDealsTotal(); i++) {
        ulong dt = HistoryDealGetTicket(i);
        if (dt == 0) continue;
        if ((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
        openTime  = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
        openPrice = HistoryDealGetDouble(dt, DEAL_PRICE);
        direction = ((ENUM_DEAL_TYPE)HistoryDealGetInteger(dt, DEAL_TYPE) == DEAL_TYPE_BUY)
                    ? "BUY" : "SELL";
        break;
    }

    // Opening order: first history order carries initial SL / TP
    for (int i = 0; i < HistoryOrdersTotal(); i++) {
        ulong ot = HistoryOrderGetTicket(i);
        if (ot == 0) continue;
        sl = HistoryOrderGetDouble(ot, ORDER_SL);
        tp = HistoryOrderGetDouble(ot, ORDER_TP);
        break;
    }

    return (openTime > 0 && openPrice > 0.0);
}

//+==================================================================+
//  OnInit
//  Initialises modules in dependency order (SRS 1.5):
//    M5 → M1 → M2 → M3 → M4
//  Returns INIT_FAILED if any mandatory handle creation fails.
//+==================================================================+
int OnInit() {
    ResetLastError();

    // M5 — Utilities (logging infrastructure needed by all modules)
    if (!g_utils.Init()) {
        Print("GoldenKafle::OnInit: Utilities init failed.");
        return INIT_FAILED;
    }

    // M1 — Risk Engine
    if (!g_risk.Init()) {
        Print("GoldenKafle::OnInit: RiskEngine init failed.");
        return INIT_FAILED;
    }

    // Honour manual pause reset before any trading checks
    if (InpResetPause) {
        g_risk.ResetPause();
        Print("GoldenKafle::OnInit: PAUSED_REVIEW state cleared by InpResetPause.");
    }

    // M2 — Signal Engines
    if (!g_sigXAU.Init(SYM_XAU)) {
        PrintFormat("GoldenKafle::OnInit: SignalEngine init failed for %s.", SYM_XAU);
        return INIT_FAILED;
    }
    if (InpEnableEURUSD) {
        if (!g_sigEUR.Init(SYM_EUR)) {
            PrintFormat("GoldenKafle::OnInit: SignalEngine init failed for %s.", SYM_EUR);
            return INIT_FAILED;
        }
    }

    // M3 — Execution
    if (!g_exec.Init()) {
        Print("GoldenKafle::OnInit: Execution init failed.");
        return INIT_FAILED;
    }

    // M4 — Trade Manager (requires M3 pointer)
    if (!g_tradeMgr.Init(&g_exec)) {
        Print("GoldenKafle::OnInit: TradeManager init failed.");
        return INIT_FAILED;
    }

    // Warm up bar-time anchor so first tick doesn't fire a false new-bar
    g_lastBarTime = iTime(SYM_XAU, PERIOD_M15, 0);

    // Warn (do not fail) if EA loaded in a halted / disabled state
    ENUM_EA_STATE state = g_risk.GetState();
    if (state == EA_DISABLED) {
        string msg = "GoldenKafle loaded in DISABLED state (balance DD limit previously hit). "
                     "Remove and re-attach to reset.";
        Print("GoldenKafle::OnInit: ", msg);
        Alert(msg);
    } else if (state == EA_PAUSED_REVIEW) {
        Print("GoldenKafle::OnInit: EA is PAUSED for review. Set InpResetPause=true to resume.");
    }

    PrintFormat("GoldenKafle::OnInit: all modules ready | State=%s | "
                "StartBal=%.2f | Magic=%d | EURUSD=%s",
                (state == EA_ACTIVE) ? "ACTIVE" : "NON-ACTIVE",
                g_risk.StartingBalance(), InpMagicNumber,
                InpEnableEURUSD ? "enabled" : "disabled");

    return INIT_SUCCEEDED;
}

//+==================================================================+
//  OnTick — 8-step pipeline (SRS Section 1.5)
//
//  Steps 1-3 run every tick (safety-critical).
//  Steps 4-8 run only on a new M15 bar (avoids noise / overhead).
//+==================================================================+
void OnTick() {
    // ---------------------------------------------------------------
    // STEP 1 — M5: Session filter
    //   If outside London / NY / overlap windows, exit immediately.
    // ---------------------------------------------------------------
    bool inSession = g_utils.CheckSession();

    // ---------------------------------------------------------------
    // STEP 2 — M5: News filter
    //   If within 30 min of a high-impact event, block new entries.
    // ---------------------------------------------------------------
    bool newsBlocked = g_utils.CheckNews();

    // ---------------------------------------------------------------
    // STEP 3 — M1: Daily DD + balance DD checks (every tick)
    //   If limits breached: halt/disable and close all positions.
    // ---------------------------------------------------------------
    g_risk.CheckDaily();
    g_risk.CheckBalance();

    // Hard stop — disabled EA does nothing further
    if (g_risk.IsDisabled()) return;

    // ---------------------------------------------------------------
    // New M15 bar gate
    //   Steps 4-8 execute only once per completed M15 bar.
    // ---------------------------------------------------------------
    datetime barTime = iTime(SYM_XAU, PERIOD_M15, 0);
    if (barTime == 0 || barTime == g_lastBarTime) return;
    g_lastBarTime = barTime;

    // Reset M3 per-bar retry counter
    g_exec.OnNewBar();

    // ---------------------------------------------------------------
    // STEP 4 — M4: Manage all open positions
    //   Break-even, trailing stop, max duration, Friday close.
    // ---------------------------------------------------------------
    g_tradeMgr.OnNewBar();

    // ---------------------------------------------------------------
    // STEP 5 — M2: Recalculate indicators and generate signals
    //   Calculations are on completed bars — no look-ahead bias.
    // ---------------------------------------------------------------
    g_sigXAU.OnNewBar();
    if (InpEnableEURUSD) g_sigEUR.OnNewBar();

    // ---------------------------------------------------------------
    // STEP 6-7 — M1 + M3: Lot sizing and order placement
    //   Only if state machine allows and all filters pass.
    //
    //   Gate order (SRS 2.5 / 5.3):
    //     IsAllowedToTrade() — not disabled / halted / paused / full
    //     inSession          — London / NY session active
    //     !newsBlocked       — no imminent high-impact news
    // ---------------------------------------------------------------
    if (g_risk.IsAllowedToTrade() && inSession && !newsBlocked)
        ProcessSignals();

    // ---------------------------------------------------------------
    // STEP 8 — M5: Update dashboard
    //   Rendered on each new M15 bar (not per-tick) per SRS 5.8.
    // ---------------------------------------------------------------
    g_utils.DrawDashboard(
        g_risk.GetState(),
        g_risk.DailyDDPct(),
        g_risk.BalanceDDPct(),
        CountOpenPositions(),
        g_risk.ConsecLosses(),
        inSession,
        newsBlocked
    );
}

//+==================================================================+
//  OnTradeTransaction — detects closed positions
//
//  Fires on every trade event. We listen for DEAL_ENTRY_OUT deals
//  belonging to our magic number, then:
//    • Update M1 consecutive-loss counter
//    • Update M5 rolling stats (win rate / profit factor)
//    • Write full trade row to GoldenKafle_Log.csv
//+==================================================================+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result) {
    // Only act on new confirmed deals
    if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    if (!HistoryDealSelect(trans.deal)) return;

    // Only closing deals
    ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
    if (dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY) return;

    // Only our EA's deals
    long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
    if (magic != InpMagicNumber) return;

    // ---- Gather closing-deal data --------------------------------
    ulong    posId      = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
    string   symbol     = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
    datetime closeTime  = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
    double   closePrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
    double   closeLots  = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
    double   profit     = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                        + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                        + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
    bool win = (profit > 0.0);

    // ---- Gather opening-deal + initial order data ----------------
    datetime openTime  = 0;
    double   openPrice = 0.0, sl = 0.0, tp = 0.0;
    string   direction = "";
    GetOpeningDealInfo(posId, openTime, openPrice, direction, sl, tp);

    // ---- Update modules -----------------------------------------
    g_risk.OnTradeClosed(win);
    g_utils.UpdateStats(win, profit);

    // ---- Write CSV log row (SRS 6.8) ----------------------------
    g_utils.LogTrade(
        posId,
        symbol,
        direction,
        openTime,
        closeTime,
        openPrice,
        closePrice,
        sl,
        tp,
        closeLots,
        profit,
        g_risk.DailyDDPct(),
        g_risk.BalanceDDPct(),
        win ? "WIN" : "LOSS"
    );
}

//+==================================================================+
//  OnDeinit — release all indicator handles and chart objects
//+==================================================================+
void OnDeinit(const int reason) {
    g_sigXAU.Deinit();
    if (InpEnableEURUSD) g_sigEUR.Deinit();
    g_utils.Deinit();

    string reasonStr;
    switch (reason) {
        case REASON_REMOVE:      reasonStr = "EA removed";       break;
        case REASON_RECOMPILE:   reasonStr = "recompile";        break;
        case REASON_CHARTCHANGE: reasonStr = "chart change";     break;
        case REASON_PARAMETERS:  reasonStr = "input change";     break;
        case REASON_ACCOUNT:     reasonStr = "account change";   break;
        case REASON_TEMPLATE:    reasonStr = "template applied"; break;
        case REASON_INITFAILED:  reasonStr = "init failed";      break;
        case REASON_CLOSE:       reasonStr = "terminal close";   break;
        default:                 reasonStr = StringFormat("code %d", reason);
    }

    PrintFormat("GoldenKafle::OnDeinit: %s | WinRate=%.1f%%  PF=%.2f  ConsecLoss=%d",
                reasonStr,
                g_utils.WinRate(),
                g_utils.ProfitFactor(),
                g_risk.ConsecLosses());
}
