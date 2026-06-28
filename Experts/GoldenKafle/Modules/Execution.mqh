//+------------------------------------------------------------------+
//|  Modules/Execution.mqh — M3: Order Execution                    |
//|  FTMO-Compliant EA — SRS Section 5.5 / Section 6.9 Step 5       |
//+------------------------------------------------------------------+
#ifndef EXECUTION_MQH
#define EXECUTION_MQH

#include <Trade/Trade.mqh>
#include "../Config/Inputs.mqh"
#include "SignalEngine.mqh"   // ENUM_SIGNAL

//+------------------------------------------------------------------+
//|  CExecution — M3 Order Execution Module                          |
//|                                                                  |
//|  All order operations route through this class. CTrade is        |
//|  configured once in Init() and shared across all calls.          |
//|                                                                  |
//|  Key behaviours (SRS Section 5.5):                               |
//|    • ORDER_FILLING_FOK on all market orders                      |
//|    • Slippage capped at InpMaxSlippagePoints                     |
//|    • Spread gate before every PlaceOrder call                    |
//|    • Recoverable errors (requote / off-quotes) retry ONCE        |
//|      after 500 ms; never more than 2 retries per bar            |
//|    • Fatal errors logged and aborted immediately                 |
//|    • All prices normalised to SYMBOL_DIGITS before submission    |
//+------------------------------------------------------------------+
class CExecution {
private:
    CTrade  m_trade;
    int     m_barRetries;   // retry count reset on each new M15 bar

    // Per-symbol max spread (points)
    int     MaxSpread(string symbol) const;

    // Returns true for errors where a single retry is warranted
    bool    IsRecoverable(uint retcode) const;

    // Normalise price to broker's digit precision
    double  NormPrice(string symbol, double price) const;

    // Core retry wrapper around CTrade send operations
    bool    SendWithRetry(string opDesc);

public:
    CExecution();
    bool Init();

    // Reset per-bar retry counter — call on every new M15 bar
    void OnNewBar() { m_barRetries = 0; }

    // ---- Pre-trade gate ------------------------------------------
    // Returns true if spread is within the limit for the symbol
    bool CheckSpread(string symbol) const;

    // ---- Order operations ----------------------------------------
    // Returns ticket on success, 0 on failure
    ulong PlaceOrder(string   symbol,
                     ENUM_ORDER_TYPE type,
                     double   lots,
                     double   sl,
                     double   tp,
                     string   comment = "");

    // Close a specific position by ticket; returns true on success
    bool  ClosePosition(ulong ticket);

    // Modify SL and/or TP of an open position; pass 0 to leave unchanged
    bool  ModifyPosition(ulong ticket, double newSL, double newTP);
};

//+------------------------------------------------------------------+
//  Constructor
//+------------------------------------------------------------------+
CExecution::CExecution() : m_barRetries(0) {}

//+------------------------------------------------------------------+
//  Init — configures CTrade once with magic number, slippage, and
//  filling mode. Called from OnInit().
//+------------------------------------------------------------------+
bool CExecution::Init() {
    m_trade.SetExpertMagicNumber(InpMagicNumber);
    m_trade.SetDeviationInPoints(InpMaxSlippagePoints);
    m_trade.SetTypeFilling(ORDER_FILLING_FOK);
    m_trade.SetAsyncMode(false); // synchronous — we check retcode immediately

    Print("CExecution::Init: CTrade configured — "
          "magic=", InpMagicNumber,
          "  slippage=", InpMaxSlippagePoints, "pts"
          "  filling=FOK");
    return true;
}

//+------------------------------------------------------------------+
//  Private helpers
//+------------------------------------------------------------------+
int CExecution::MaxSpread(string symbol) const {
    // XAUUSD uses the Gold spread limit; everything else uses Forex limit
    if (StringFind(symbol, "XAU") >= 0 ||
        StringFind(symbol, "GOLD") >= 0)
        return InpMaxSpreadGold;
    return InpMaxSpreadForex;
}

bool CExecution::IsRecoverable(uint retcode) const {
    return (retcode == TRADE_RETCODE_REQUOTE       ||   // 10004 requote
            retcode == TRADE_RETCODE_PRICE_OFF     ||   // 10021 no quotes to process (off-quotes)
            retcode == TRADE_RETCODE_PRICE_CHANGED);    // 10020 price changed
}

double CExecution::NormPrice(string symbol, double price) const {
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    return NormalizeDouble(price, digits);
}

//+------------------------------------------------------------------+
//  CheckSpread — returns true if the current live spread for the
//  symbol is within the configured limit.
//  Called by the main EA pipeline before every PlaceOrder attempt.
//+------------------------------------------------------------------+
bool CExecution::CheckSpread(string symbol) const {
    long   spreadPts = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
    int    limit     = MaxSpread(symbol);
    bool   ok        = (spreadPts <= limit);

    if (!ok)
        PrintFormat("CExecution::CheckSpread [%s]: BLOCKED — spread %d pts > limit %d pts",
                    symbol, spreadPts, limit);
    return ok;
}

//+------------------------------------------------------------------+
//  PlaceOrder — submits a market BUY or SELL with the supplied
//  SL and TP.  Retries once (after 500 ms) on recoverable errors.
//  Returns the assigned ticket on success, 0 on failure.
//
//  The caller must have already verified:
//    • M1 IsAllowedToTrade()
//    • M5 CheckSession() and CheckNews()
//    • M3 CheckSpread() (or pass it here — we re-verify internally)
//+------------------------------------------------------------------+
ulong CExecution::PlaceOrder(string          symbol,
                              ENUM_ORDER_TYPE type,
                              double          lots,
                              double          sl,
                              double          tp,
                              string          comment) {
    // Re-verify spread at the moment of execution
    if (!CheckSpread(symbol)) return 0;

    if (lots <= 0.0) {
        Print("CExecution::PlaceOrder: lots <= 0 — aborting.");
        return 0;
    }

    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    if (ask <= 0.0 || bid <= 0.0) {
        Print("CExecution::PlaceOrder: invalid ask/bid prices — aborting.");
        return 0;
    }

    // Normalise SL / TP to broker precision
    sl = NormPrice(symbol, sl);
    tp = NormPrice(symbol, tp);

    // Prefix comment with magic number for easy journal filtering
    string fullComment = StringFormat("GK_%d %s", InpMagicNumber, comment);

    // ---- Attempt order placement (up to 2 tries) -----------------
    bool placed = false;
    for (int attempt = 1; attempt <= 2; attempt++) {
        bool ok = false;
        if (type == ORDER_TYPE_BUY)
            ok = m_trade.Buy(lots, symbol, ask, sl, tp, fullComment);
        else if (type == ORDER_TYPE_SELL)
            ok = m_trade.Sell(lots, symbol, bid, sl, tp, fullComment);
        else {
            PrintFormat("CExecution::PlaceOrder [%s]: unsupported order type %d",
                        symbol, type);
            return 0;
        }

        uint retcode = m_trade.ResultRetcode();

        if (ok && retcode == TRADE_RETCODE_DONE) {
            placed = true;
            break;
        }

        PrintFormat("CExecution::PlaceOrder [%s] attempt %d: retcode=%d (%s)",
                    symbol, attempt, retcode, m_trade.ResultRetcodeDescription());

        // Only retry on recoverable errors and within per-bar retry budget
        if (!IsRecoverable(retcode) || m_barRetries >= 2) {
            PrintFormat("CExecution::PlaceOrder [%s]: non-recoverable or retry limit — aborting.",
                        symbol);
            break;
        }

        m_barRetries++;
        Print("CExecution::PlaceOrder [", symbol, "]: recoverable error — retrying in 500 ms.");
        Sleep(500);

        // Refresh prices after sleep
        ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
        bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    }

    if (!placed) return 0;

    ulong ticket = m_trade.ResultOrder();
    PrintFormat("CExecution::PlaceOrder [%s]: SUCCESS — ticket #%d  type=%s  "
                "lots=%.2f  SL=%.5f  TP=%.5f",
                symbol, ticket,
                (type == ORDER_TYPE_BUY) ? "BUY" : "SELL",
                lots, sl, tp);
    return ticket;
}

//+------------------------------------------------------------------+
//  ClosePosition — closes a specific open position at market.
//  Retries once on recoverable errors within the per-bar budget.
//  Returns true on confirmed close.
//+------------------------------------------------------------------+
bool CExecution::ClosePosition(ulong ticket) {
    if (ticket == 0) {
        Print("CExecution::ClosePosition: invalid ticket 0.");
        return false;
    }

    // Confirm position still exists before attempting close
    if (!PositionSelectByTicket(ticket)) {
        PrintFormat("CExecution::ClosePosition: ticket #%d not found — may already be closed.",
                    ticket);
        return false;
    }

    string symbol = PositionGetString(POSITION_SYMBOL);
    bool closed   = false;

    for (int attempt = 1; attempt <= 2; attempt++) {
        bool ok = m_trade.PositionClose(ticket, InpMaxSlippagePoints);
        uint retcode = m_trade.ResultRetcode();

        if (ok && retcode == TRADE_RETCODE_DONE) {
            closed = true;
            break;
        }

        PrintFormat("CExecution::ClosePosition #%d attempt %d: retcode=%d (%s)",
                    ticket, attempt, retcode, m_trade.ResultRetcodeDescription());

        if (!IsRecoverable(retcode) || m_barRetries >= 2) break;

        m_barRetries++;
        Sleep(500);
    }

    if (closed)
        PrintFormat("CExecution::ClosePosition: SUCCESS — closed #%d (%s)", ticket, symbol);
    else
        PrintFormat("CExecution::ClosePosition: FAILED — could not close #%d", ticket);

    return closed;
}

//+------------------------------------------------------------------+
//  ModifyPosition — updates the SL and/or TP of an open position.
//  Pass 0.0 for newSL or newTP to leave that value unchanged.
//  Returns true when the modification is confirmed by the broker.
//
//  Callers must enforce the minimum trade duration check (SRS 2.6.3)
//  before calling this; ModifyPosition does not check it itself.
//+------------------------------------------------------------------+
bool CExecution::ModifyPosition(ulong ticket, double newSL, double newTP) {
    if (ticket == 0) return false;

    if (!PositionSelectByTicket(ticket)) {
        PrintFormat("CExecution::ModifyPosition: ticket #%d not found.", ticket);
        return false;
    }

    string symbol  = PositionGetString(POSITION_SYMBOL);
    double currentSL = PositionGetDouble(POSITION_SL);
    double currentTP = PositionGetDouble(POSITION_TP);

    // Resolve "leave unchanged" sentinel
    double targetSL = (newSL != 0.0) ? NormPrice(symbol, newSL) : currentSL;
    double targetTP = (newTP != 0.0) ? NormPrice(symbol, newTP) : currentTP;

    // Skip if nothing actually changed (avoids unnecessary round-trips)
    if (MathAbs(targetSL - currentSL) < SymbolInfoDouble(symbol, SYMBOL_POINT) * 0.5 &&
        MathAbs(targetTP - currentTP) < SymbolInfoDouble(symbol, SYMBOL_POINT) * 0.5) {
        return true;  // already at target
    }

    bool modified = false;

    for (int attempt = 1; attempt <= 2; attempt++) {
        bool ok = m_trade.PositionModify(ticket, targetSL, targetTP);
        uint retcode = m_trade.ResultRetcode();

        if (ok && retcode == TRADE_RETCODE_DONE) {
            modified = true;
            break;
        }

        PrintFormat("CExecution::ModifyPosition #%d attempt %d: retcode=%d (%s)",
                    ticket, attempt, retcode, m_trade.ResultRetcodeDescription());

        if (!IsRecoverable(retcode) || m_barRetries >= 2) break;

        m_barRetries++;
        Sleep(500);
    }

    if (modified)
        PrintFormat("CExecution::ModifyPosition: SUCCESS — #%d  SL %.5f → %.5f  TP %.5f → %.5f",
                    ticket, currentSL, targetSL, currentTP, targetTP);
    else
        PrintFormat("CExecution::ModifyPosition: FAILED — #%d unchanged", ticket);

    return modified;
}

#endif // EXECUTION_MQH
