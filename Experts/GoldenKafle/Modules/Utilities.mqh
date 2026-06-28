//+------------------------------------------------------------------+
//|  Modules/Utilities.mqh — M5: Logging, Sessions, News, Stats     |
//|  FTMO-Compliant EA — SRS Section 6.9 Step 2                     |
//+------------------------------------------------------------------+
#ifndef UTILITIES_MQH
#define UTILITIES_MQH

#include "../Config/Inputs.mqh"

//--- EA state machine states (shared across all modules) -----------
enum ENUM_EA_STATE {
    EA_ACTIVE,          // Normal operation — all modules run
    EA_HALTED_TODAY,    // Daily DD limit hit — resets at broker midnight
    EA_PAUSED_REVIEW,   // Consecutive loss limit hit — manual reset required
    EA_DISABLED         // Balance DD limit hit — EA in read-only mode
};

//--- News event record loaded from CSV -----------------------------
struct SNewsEvent {
    datetime eventTime;
    string   currency;
    string   description;
};

//+------------------------------------------------------------------+
//|  CUtilities — M5 Utility Module                                  |
//|                                                                  |
//|  Responsibilities:                                               |
//|    CheckSession()   — UTC session gate (London / NY / overlap)   |
//|    CheckNews()      — 30-min pre/post news exclusion window       |
//|    LogTrade()       — CSV trade log + Experts tab print           |
//|    UpdateStats()    — rolling win rate / profit factor           |
//|    DrawDashboard()  — on-chart OBJ_LABEL overlay                 |
//+------------------------------------------------------------------+
class CUtilities {
private:
    SNewsEvent m_news[];
    int        m_newsCount;

    int        m_totalTrades;
    int        m_winTrades;
    double     m_grossProfit;
    double     m_grossLoss;

    string     m_dashPrefix;    // All dashboard objects share this prefix
    string     m_logPath;       // MQL5/Files relative path

    bool   LoadNewsCSV();
    void   EnsureLabel(string name, int x, int y, int fontSize = 9);
    void   SetLabel(string name, string text, color clr);
    string StateToStr(ENUM_EA_STATE s) const;

public:
    CUtilities();
    bool   Init();
    void   Deinit();

    bool   CheckSession()  const;
    bool   CheckNews()     const;

    void   LogTrade(long     ticket,
                    string   symbol,
                    string   direction,
                    datetime openTime,
                    datetime closeTime,
                    double   openPrice,
                    double   closePrice,
                    double   sl,
                    double   tp,
                    double   lots,
                    double   pl,
                    double   dayDDpct,
                    double   balDDpct,
                    string   signalReason);

    void   UpdateStats(bool win, double profit);

    void   DrawDashboard(ENUM_EA_STATE state,
                         double        dayDDpct,
                         double        balDDpct,
                         int           openTrades,
                         int           consecLoss,
                         bool          inSession,
                         bool          newsBlocked);

    double WinRate()      const;
    double ProfitFactor() const;
};

//+------------------------------------------------------------------+
//  Constructor
//+------------------------------------------------------------------+
CUtilities::CUtilities()
    : m_newsCount(0),
      m_totalTrades(0),
      m_winTrades(0),
      m_grossProfit(0.0),
      m_grossLoss(0.0),
      m_dashPrefix("GK_DASH_"),
      m_logPath("GoldenKafle_Log.csv")
{}

//+------------------------------------------------------------------+
//  Init — called from OnInit()
//  Creates/verifies CSV log header, loads news events into memory.
//  Returns false only on a hard failure that should abort OnInit.
//+------------------------------------------------------------------+
bool CUtilities::Init() {
    // --- Initialise trade log -----------------------------------------
    if (InpEnableLogging) {
        // Only write header if the file does not already exist
        int fh = FileOpen(m_logPath, FILE_READ | FILE_CSV | FILE_ANSI, ',');
        bool exists = (fh != INVALID_HANDLE);
        if (exists) FileClose(fh);

        if (!exists) {
            fh = FileOpen(m_logPath, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
            if (fh == INVALID_HANDLE) {
                Print("CUtilities::Init: Cannot create log file '", m_logPath, "' error ", GetLastError());
                // Non-fatal — continue without logging
            } else {
                FileWrite(fh, "Ticket", "Symbol", "Direction",
                          "OpenTime", "CloseTime",
                          "OpenPrice", "ClosePrice",
                          "SL", "TP", "Lots", "PL",
                          "DailyDD%", "BalanceDD%", "SignalReason");
                FileClose(fh);
            }
        }
    }

    // --- Load news events ---------------------------------------------
    if (InpEnableNewsFilter) {
        if (!LoadNewsCSV()) {
            Print("CUtilities::Init: news_events.csv not found or empty — "
                  "news filter inactive this session. "
                  "Place YYYY.MM.DD,HH:MM,CCY,HIGH,Description CSV in MQL5/Files/.");
        } else {
            Print("CUtilities::Init: Loaded ", m_newsCount, " HIGH-impact news events.");
        }
    }

    Print("CUtilities::Init: Utilities module ready.");
    return true;
}

//+------------------------------------------------------------------+
//  Deinit — removes dashboard objects on EA removal
//+------------------------------------------------------------------+
void CUtilities::Deinit() {
    if (!InpEnableDashboard) return;

    string keys[] = {"HEADER", "STATE", "SESSION", "NEWS",
                     "DAILY_DD", "BAL_DD", "OPEN_TRADES",
                     "CONSEC_LOSS", "WIN_RATE", "UPDATED"};
    for (int i = 0; i < ArraySize(keys); i++)
        ObjectDelete(0, m_dashPrefix + keys[i]);

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//  LoadNewsCSV — reads MQL5/Files/news_events.csv into m_news[]
//
//  Expected CSV format (comma-separated, one header row):
//    Date,Time,Currency,Impact,Event
//    2024.01.15,08:30,USD,HIGH,Non-Farm Payroll
//    2024.01.15,13:30,EUR,HIGH,ECB Rate Decision
//
//  Only HIGH-impact events are loaded. Times are UTC.
//+------------------------------------------------------------------+
bool CUtilities::LoadNewsCSV() {
    const string newsFile = "news_events.csv";
    int fh = FileOpen(newsFile, FILE_READ | FILE_CSV | FILE_ANSI, ',');
    if (fh == INVALID_HANDLE) return false;

    ArrayResize(m_news, 0);
    m_newsCount = 0;

    bool firstRow = true;
    while (!FileIsEnding(fh)) {
        string dateStr  = FileReadString(fh);
        string timeStr  = FileReadString(fh);
        string currency = FileReadString(fh);
        string impact   = FileReadString(fh);
        string desc     = FileReadString(fh);

        // Skip header row (first line, starts with non-digit)
        if (firstRow) {
            firstRow = false;
            ushort firstChar = (StringLen(dateStr) > 0) ? StringGetCharacter(dateStr, 0) : 0;
            if (firstChar < '0' || firstChar > '9') continue;
        }

        if (StringLen(dateStr) < 8) continue;

        // Only load HIGH-impact events
        string impactUpper = impact;
        StringToUpper(impactUpper);
        if (impactUpper != "HIGH") continue;

        // Parse: "YYYY.MM.DD" + " " + "HH:MM" + ":00"
        string dtStr = dateStr + " " + timeStr;
        if (StringLen(timeStr) == 5) dtStr += ":00"; // append seconds
        datetime evTime = StringToTime(dtStr);
        if (evTime <= 0) continue;

        int idx = m_newsCount;
        ArrayResize(m_news, idx + 1);
        m_news[idx].eventTime   = evTime;
        m_news[idx].currency    = currency;
        m_news[idx].description = desc;
        m_newsCount++;
    }

    FileClose(fh);
    return (m_newsCount > 0);
}

//+------------------------------------------------------------------+
//  CheckSession — returns true if current UTC time is within an
//  allowed trading session and it is not Friday 20:00+ UTC.
//
//  Valid windows (UTC):
//    London      07:00 – 12:00
//    Overlap     12:00 – 13:00  (London/NY; highest priority)
//    New York    13:00 – 18:00
//  Asian session is excluded.
//+------------------------------------------------------------------+
bool CUtilities::CheckSession() const {
    MqlDateTime utc;
    TimeToStruct(TimeGMT(), utc);

    int hour = utc.hour;
    int dow  = utc.day_of_week; // 0=Sun … 5=Fri … 6=Sat

    // No trading on weekends
    if (dow == 0 || dow == 6) return false;

    // Friday cut-off (configurable; default 20:00 UTC)
    if (InpCloseOnFriday && dow == 5 && hour >= 20) return false;

    // London: [InpLondonStart, InpLondonEnd)
    // Overlap: [InpLondonEnd, InpNYStart)
    // NY:      [InpNYStart,   InpNYEnd)
    bool inLondon  = (hour >= InpLondonStart && hour < InpLondonEnd);
    bool inOverlap = (hour >= InpLondonEnd   && hour < InpNYStart);
    bool inNY      = (hour >= InpNYStart     && hour < InpNYEnd);

    return (inLondon || inOverlap || inNY);
}

//+------------------------------------------------------------------+
//  CheckNews — returns true if current UTC time is within
//  InpNewsFilterMinutes of any HIGH-impact event in m_news[].
//  A true return means trading is blocked.
//+------------------------------------------------------------------+
bool CUtilities::CheckNews() const {
    if (!InpEnableNewsFilter || m_newsCount == 0) return false;

    datetime now       = TimeGMT();
    long     windowSec = (long)InpNewsFilterMinutes * 60;

    for (int i = 0; i < m_newsCount; i++) {
        long diff = (long)m_news[i].eventTime - (long)now;
        if (MathAbs((double)diff) <= (double)windowSec) return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//  LogTrade — writes one completed trade row to CSV + Experts tab.
//  Called by M4 TradeManager immediately after each position closes.
//  File is opened, written, and closed on each call (no buffering)
//  per SRS Section 6.8.
//+------------------------------------------------------------------+
void CUtilities::LogTrade(long     ticket,
                           string   symbol,
                           string   direction,
                           datetime openTime,
                           datetime closeTime,
                           double   openPrice,
                           double   closePrice,
                           double   sl,
                           double   tp,
                           double   lots,
                           double   pl,
                           double   dayDDpct,
                           double   balDDpct,
                           string   signalReason) {
    // Always echo to Experts tab
    PrintFormat("[TRADE] #%d %s %s | Entry %s @ %.5f → Exit %s @ %.5f | "
                "SL %.5f  TP %.5f  Lots %.2f  P&L %.2f | "
                "DayDD %.2f%%  BalDD %.2f%% | %s",
                ticket, symbol, direction,
                TimeToString(openTime,  TIME_DATE | TIME_MINUTES), openPrice,
                TimeToString(closeTime, TIME_DATE | TIME_MINUTES), closePrice,
                sl, tp, lots, pl,
                dayDDpct, balDDpct, signalReason);

    if (!InpEnableLogging) return;

    // Append row — open in READ|WRITE so existing content is preserved
    int fh = FileOpen(m_logPath, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
    if (fh == INVALID_HANDLE) {
        PrintFormat("CUtilities::LogTrade: Cannot open '%s' (error %d)", m_logPath, GetLastError());
        return;
    }
    FileSeek(fh, 0, SEEK_END);
    FileWrite(fh,
        IntegerToString(ticket),
        symbol,
        direction,
        TimeToString(openTime,  TIME_DATE | TIME_MINUTES),
        TimeToString(closeTime, TIME_DATE | TIME_MINUTES),
        DoubleToString(openPrice,  5),
        DoubleToString(closePrice, 5),
        DoubleToString(sl,  5),
        DoubleToString(tp,  5),
        DoubleToString(lots, 2),
        DoubleToString(pl,   2),
        DoubleToString(dayDDpct, 2),
        DoubleToString(balDDpct, 2),
        signalReason
    );
    FileClose(fh);
}

//+------------------------------------------------------------------+
//  UpdateStats — called by M4 after each trade closes.
//  Maintains in-memory win rate and profit factor.
//+------------------------------------------------------------------+
void CUtilities::UpdateStats(bool win, double profit) {
    m_totalTrades++;
    if (win) {
        m_winTrades++;
        m_grossProfit += profit;
    } else {
        m_grossLoss += MathAbs(profit);
    }
}

//+------------------------------------------------------------------+
//  WinRate / ProfitFactor — read-only accessors
//+------------------------------------------------------------------+
double CUtilities::WinRate() const {
    if (m_totalTrades == 0) return 0.0;
    return (double)m_winTrades / (double)m_totalTrades * 100.0;
}

double CUtilities::ProfitFactor() const {
    if (m_grossLoss <= 0.0)
        return (m_grossProfit > 0.0) ? 999.0 : 0.0;
    return m_grossProfit / m_grossLoss;
}

//+------------------------------------------------------------------+
//  DrawDashboard — renders / updates the on-chart OBJ_LABEL overlay.
//  Called on every new M15 bar (not every tick) per SRS Section 5.8.
//
//  Layout (bottom-left, CORNER_LEFT_LOWER):
//    Row 0   ── GoldenKafle ──────────────
//    Row 1   State   : ACTIVE
//    Row 2   Session : OPEN
//    Row 3   News    : Clear
//    Row 4   Daily DD: 0.45% / 3.5%
//    Row 5   Bal  DD : 0.12% / 9.5%
//    Row 6   Trades  : 1 open / 3 max
//    Row 7   ConsLoss: 0 / 5
//    Row 8   Win Rate: 68.2%  PF: 2.41
//    Row 9   Updated : HH:MM:SS
//+------------------------------------------------------------------+
void CUtilities::DrawDashboard(ENUM_EA_STATE state,
                                double        dayDDpct,
                                double        balDDpct,
                                int           openTrades,
                                int           consecLoss,
                                bool          inSession,
                                bool          newsBlocked) {
    if (!InpEnableDashboard) return;

    // ---- Colour scheme -------------------------------------------
    const color COL_HEADER  = clrSilver;
    const color COL_OK      = clrLimeGreen;
    const color COL_WARN    = clrOrange;
    const color COL_DANGER  = clrRed;
    const color COL_NEUTRAL = clrWhite;

    color stateCol = (state == EA_ACTIVE)        ? COL_OK :
                     (state == EA_DISABLED)       ? COL_DANGER : COL_WARN;

    color ddCol    = (dayDDpct  >= InpDailyDDLimit - 0.5) ? COL_DANGER :
                     (dayDDpct  >= InpDailyDDLimit - 1.5) ? COL_WARN   : COL_OK;

    color balCol   = (balDDpct  >= InpMaxBalanceDD - 1.0) ? COL_DANGER :
                     (balDDpct  >= InpMaxBalanceDD - 3.0) ? COL_WARN   : COL_OK;

    color lossCol  = (consecLoss >= InpMaxConsecLoss - 1)  ? COL_WARN   : COL_NEUTRAL;

    // ---- Pixel layout (bottom-left origin, counting upward) ------
    const int X  = 10;
    const int Y0 = 190;   // bottom row y-offset from corner
    const int DY = 16;    // row height in pixels

    EnsureLabel("HEADER",      X, Y0 + DY * 9);
    EnsureLabel("STATE",       X, Y0 + DY * 8);
    EnsureLabel("SESSION",     X, Y0 + DY * 7);
    EnsureLabel("NEWS",        X, Y0 + DY * 6);
    EnsureLabel("DAILY_DD",    X, Y0 + DY * 5);
    EnsureLabel("BAL_DD",      X, Y0 + DY * 4);
    EnsureLabel("OPEN_TRADES", X, Y0 + DY * 3);
    EnsureLabel("CONSEC_LOSS", X, Y0 + DY * 2);
    EnsureLabel("WIN_RATE",    X, Y0 + DY * 1);
    EnsureLabel("UPDATED",     X, Y0 + DY * 0);

    SetLabel("HEADER",
             "── GoldenKafle ──────────────", COL_HEADER);

    SetLabel("STATE",
             StringFormat("State   : %s", StateToStr(state)), stateCol);

    SetLabel("SESSION",
             StringFormat("Session : %s", inSession ? "OPEN" : "CLOSED"),
             inSession ? COL_OK : COL_NEUTRAL);

    SetLabel("NEWS",
             StringFormat("News    : %s", newsBlocked ? "BLOCKED" : "Clear"),
             newsBlocked ? COL_WARN : COL_OK);

    SetLabel("DAILY_DD",
             StringFormat("Daily DD: %.2f%% / %.1f%%", dayDDpct, InpDailyDDLimit), ddCol);

    SetLabel("BAL_DD",
             StringFormat("Bal  DD : %.2f%% / %.1f%%", balDDpct, InpMaxBalanceDD), balCol);

    SetLabel("OPEN_TRADES",
             StringFormat("Trades  : %d open / %d max", openTrades, InpMaxOpenTrades),
             COL_NEUTRAL);

    SetLabel("CONSEC_LOSS",
             StringFormat("ConsLoss: %d / %d", consecLoss, InpMaxConsecLoss), lossCol);

    SetLabel("WIN_RATE",
             StringFormat("Win Rate: %.1f%%  PF: %.2f", WinRate(), ProfitFactor()),
             COL_NEUTRAL);

    SetLabel("UPDATED",
             StringFormat("Updated : %s", TimeToString(TimeCurrent(), TIME_SECONDS)),
             clrDimGray);

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//  Private helpers
//+------------------------------------------------------------------+
void CUtilities::EnsureLabel(string name, int x, int y, int fontSize) {
    string full = m_dashPrefix + name;
    if (ObjectFind(0, full) < 0) {
        ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, full, OBJPROP_CORNER,     CORNER_LEFT_LOWER);
        ObjectSetInteger(0, full, OBJPROP_XDISTANCE,  x);
        ObjectSetInteger(0, full, OBJPROP_YDISTANCE,  y);
        ObjectSetInteger(0, full, OBJPROP_FONTSIZE,   fontSize);
        ObjectSetString(0,  full, OBJPROP_FONT,       "Courier New");
        ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, full, OBJPROP_HIDDEN,     true);
    }
}

void CUtilities::SetLabel(string name, string text, color clr) {
    string full = m_dashPrefix + name;
    if (ObjectFind(0, full) >= 0) {
        ObjectSetString(0,  full, OBJPROP_TEXT,  text);
        ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
    }
}

string CUtilities::StateToStr(ENUM_EA_STATE s) const {
    switch (s) {
        case EA_ACTIVE:        return "ACTIVE";
        case EA_HALTED_TODAY:  return "HALTED (daily DD)";
        case EA_PAUSED_REVIEW: return "PAUSED (review)";
        case EA_DISABLED:      return "DISABLED";
        default:               return "UNKNOWN";
    }
}

#endif // UTILITIES_MQH
