# GoldenKafle — FTMO-Compliant Multi-Symbol Expert Advisor

A professional-grade Expert Advisor (EA) for **MetaTrader 5 (MQL5)**, built to pass the
**FTMO 2-Phase Evaluation** and sustain a funded account thereafter. It trades **XAUUSD**
(primary) and **EURUSD** (optional secondary) using a trend-following, volatility-breakout,
pullback-entry strategy with strict capital-preservation rules.

> **Not** a scalper, grid, or martingale system. Targets a conservative **3–5% monthly return**
> with controlled drawdowns.

---

## Strategy at a Glance

| Aspect | Detail |
|---|---|
| **Instruments** | XAUUSD (primary), EURUSD (optional) |
| **Timeframes** | H1 (trend context) + M15 (entry timing) |
| **Sessions (UTC)** | London 07–12, Overlap 12–13, New York 13–18 (Asian excluded) |
| **Entry** | EMA trend + ADX strength + M15 breakout + ATR expansion + RSI momentum + pullback confirmation |
| **Exit** | ATR-based SL/TP, break-even at +1R, ATR trailing stop |
| **Risk per trade** | 0.35% of equity (hard cap 0.5%) |

### Entry Logic (all conditions required)

**BUY** — `50-EMA > 200-EMA` (H1) · `ADX ≥ 22` (H1) · `Close[1] > N-bar swing high` (M15) ·
`ATR ≥ 0.8× 20-bar avg` · `RSI 52–70` · pullback `≥ 0.3× ATR` from breakout high ·
no existing position on symbol.

**SELL** — mirror of BUY (bearish EMA, breakdown below swing low, `RSI 30–48`, bounce from low).

---

## FTMO Compliance

| FTMO Rule | EA Enforcement |
|---|---|
| Max daily loss 5% | Halts at **3.5%** daily equity drawdown (conservative buffer) |
| Max overall loss 10% | Disables at **9.5%** balance drawdown (0.5% safety margin) |
| No martingale/grid | Fixed risk-per-trade; no averaging down |
| No tick scalping | 3-minute minimum trade duration |
| Min 10 trading days | Session filter restricts to valid days/hours |
| News restriction | 30-min pre/post high-impact news filter (configurable) |

Additional prudential circuit breaker: pauses after **5 consecutive losses** (manual reset).

---

## Architecture

Five independent modules communicate through global state in the main EA. Each module is a
class in its own `.mqh` header and can be compiled and reasoned about in isolation.

```
Experts/GoldenKafle/
├── GoldenKafle.mq5         Main EA — OnInit / OnTick / OnDeinit, 8-step pipeline
├── Config/
│   └── Inputs.mqh          All input parameters (centralised)
└── Modules/
    ├── Utilities.mqh       M5 — logging, session filter, news filter, dashboard
    ├── RiskEngine.mqh      M1 — daily/balance DD gates, lot sizing, loss counter
    ├── SignalEngine.mqh    M2 — indicators, entry signal logic, SL/TP prices
    ├── Execution.mqh       M3 — order placement, spread/slippage checks, retries
    └── TradeManager.mqh    M4 — break-even, trailing, duration, Friday close
```

| Module | Class | Responsibility |
|---|---|---|
| **M1** | `CRiskEngine` | Equity/balance monitoring, daily loss limits, position sizing |
| **M2** | `CSignalEngine` | Indicator calculations, BUY/SELL/NONE signal generation |
| **M3** | `CExecution` | Order placement, SL/TP submission, spread/slippage validation |
| **M4** | `CTradeManager` | Break-even, trailing stop, partial close, trade lifecycle |
| **M5** | `CUtilities` | Logging, news/session filters, performance stats, dashboard |

### Execution Flow (`OnTick`, SRS §1.5)

Steps 1–3 run **every tick** (safety-critical); steps 4–8 run **only on a new M15 bar**:

1. **M5** Session filter — exit if outside trading windows
2. **M5** News filter — block entries near high-impact events
3. **M1** Daily + balance drawdown checks — halt/disable on breach
4. **M4** Manage open positions — break-even, trailing, duration, Friday close
5. **M2** Recalculate indicators & generate signals (bar-close only, no look-ahead)
6. **M1** Lot sizing if signal valid and not disabled/blocked
7. **M3** Validate spread & place order with computed SL/TP
8. **M5** Update on-chart dashboard

---

## Installation

1. **Download** the project. From GitHub: switch to this branch → **Code → Download ZIP**,
   or clone:
   ```
   git clone https://github.com/ryankafle/kaflestudies.git
   ```
2. **Copy** the `Experts/GoldenKafle/` folder into your MT5 data directory:
   ```
   C:\Users\<you>\AppData\Roaming\MetaQuotes\Terminal\<id>\MQL5\Experts\
   ```
   (In MetaEditor: **File → Open Data Folder**.)
3. **Compile** `GoldenKafle.mq5` in MetaEditor (**F7**). Should produce **0 errors**.
4. *(Optional)* Place a `news_events.csv` in `MQL5/Files/` (see format below) or set
   `InpEnableNewsFilter = false` for initial testing.
5. **Attach** GoldenKafle to an **XAUUSD M15** chart. Enable **AutoTrading**.

### News CSV format (`MQL5/Files/news_events.csv`)

Only `HIGH`-impact rows are loaded; times are UTC.

```csv
Date,Time,Currency,Impact,Event
2024.01.15,08:30,USD,HIGH,Non-Farm Payroll
2024.01.15,13:30,EUR,HIGH,ECB Rate Decision
```

---

## Key Inputs

| Input | Default | Description |
|---|---|---|
| `InpRiskPerTrade` | 0.35 | Risk per trade (% of equity) |
| `InpDailyDDLimit` | 3.5 | Daily equity drawdown halt threshold (%) |
| `InpMaxBalanceDD` | 9.5 | Max balance drawdown — hard disable (%) |
| `InpMaxOpenTrades` | 3 | Maximum simultaneous open positions |
| `InpMaxConsecLoss` | 5 | Consecutive losses before pause |
| `InpMagicNumber` | 20260628 | Unique magic number for this EA instance |
| `InpADXThreshold` | 22.0 | Minimum ADX for trend confirmation |
| `InpSLMultiplier` | 1.8 | ATR multiplier for stop loss |
| `InpTPMultiplier` | 2.7 | ATR multiplier for take profit |
| `InpTrailATRMultiplier` | 1.2 | ATR multiplier for trailing stop distance |
| `InpCloseOnFriday` | true | Close all positions at Friday 20:00 UTC |
| `InpEnableEURUSD` | false | Enable EURUSD as secondary instrument |
| `InpResetPause` | false | Clear `PAUSED_REVIEW` state on next init |

> ⚠️ **Adjust session hours for your broker's offset.** FTMO MT5 uses UTC+2 (winter) /
> UTC+3 (summer). Session inputs assume server time aligned to these windows.

Full parameter list is in [`Config/Inputs.mqh`](Experts/GoldenKafle/Config/Inputs.mqh).

---

## Backtesting & Validation

Per the SRS, before any live deployment:

- **Strategy Tester**: XAUUSD M15, *Every tick based on real ticks*, real (current) spread,
  $10,000 deposit, FTMO commission (~$3.50/lot round trip on Gold).
- **In-sample**: Jan 2021 – Dec 2024 · **Out-of-sample**: Jan 2025 – present (walk-forward).
- **Optimise** (genetic) SL/TP multipliers, ADX threshold, RSI bounds, swing lookback,
  pullback — fitness = `Profit Factor × (1 − MaxDD/10)`. **Do not optimise risk or
  session parameters.**

### Acceptance Criteria (minimum / target)

| Metric | Minimum | Target |
|---|---|---|
| Profit Factor | > 1.7 | > 2.0 |
| Sharpe Ratio | > 1.2 | > 1.5 |
| Win Rate | > 60% | 65–75% |
| Max Drawdown | < 9.5% | < 7% |
| Max Daily Drawdown | < 3.5% | < 2.5% |
| Monthly Return (avg) | > 2% | 3–5% |
| Max Consecutive Losses | ≤ 7 | ≤ 5 |

Also run a **Monte Carlo** stress test (1,000 permutations; 95th-percentile DD < 9.5%) and an
**FTMO challenge simulation** (≥ 8/10 random 30-day windows pass +10% without breaching limits).

---

## Logging & Diagnostics

- **Experts/Journal tab** — real-time operational messages, signal evaluations (per-condition
  pass/fail), trade placements, state changes.
- **`MQL5/Files/GoldenKafle_Log.csv`** — one row per closed trade (ticket, symbol, direction,
  open/close times & prices, SL, TP, lots, P&L, daily DD%, balance DD%, reason). Flushed to
  disk immediately on each trade close.
- **On-chart dashboard** — live EA state, daily/balance DD%, open trades, consecutive losses,
  win rate, profit factor, session & news status.

---

## State Machine

| State | Meaning | New trades? | Trade mgmt? | Reset |
|---|---|---|---|---|
| `ACTIVE` | Normal operation | ✅ | ✅ | — |
| `HALTED_TODAY` | Daily DD limit hit | ❌ | ✅ | Auto at broker midnight |
| `PAUSED_REVIEW` | Consecutive loss limit hit | ❌ | ✅ | Manual (`InpResetPause`) |
| `DISABLED` | Balance DD limit hit | ❌ | ❌ (positions closed) | Remove & re-attach EA |

---

## Disclaimer

This software is provided for educational and research purposes. Trading leveraged instruments
carries substantial risk of loss. Past backtest performance does not guarantee future results.
Test thoroughly on a demo account before risking real or funded capital. The authors accept no
liability for trading losses.

---

*Built per the FTMO EA Software Requirements Specification v1.0 — modular Steps 1–7 complete;
Step 8 (optimisation & validation) is performed in the MT5 Strategy Tester.*
