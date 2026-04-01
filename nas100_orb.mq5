//+------------------------------------------------------------------+
//|  NAS100 Open Range Breakout (ORB) EA  v3.0                       |
//|  Broker : IC Markets MT5 (server UTC+2 winter / UTC+3 summer)    |
//|  Session: NY Open = 16:30 server time (constant, DST-safe)       |
//|                                                                  |
//|  v2   : fill-mode, ATR scale, SL fraction, ORB scan, trend TF   |
//|  v2.1 : overnight gap filter, previous-day direction bias        |
//|  v3.0 : IBS filter, EOD hard-close, breakout bar quality,       |
//|          ATR-adaptive buffer, D1 RSI(3), weekly trade cap,       |
//|          false-breakout detection                                |
//+------------------------------------------------------------------+
#property copyright "KahFungL"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

//=== Session Settings ===============================================
input group "=== Session Settings ==="
input int    InpORBStartHour    = 16;          // NY Open Hour (server time)
input int    InpORBStartMin     = 30;          // NY Open Minute
input int    InpORBDurationMin  = 15;          // ORB window (minutes)
input int    InpConfirmTF       = 5;           // Confirmation TF: 1, 5, or 15 (minutes)
input int    InpTradeEndHour    = 19;          // Latest NEW entry hour (server)
input int    InpTradeEndMin     = 0;           // Latest NEW entry minute
input int    InpEODCloseHour    = 19;          // Hard EOD close hour (server) – 19:45 = 14:45 ET
input int    InpEODCloseMin     = 45;          // Hard EOD close minute
input bool   InpSkipMonday      = true;        // Skip Mondays (historically weaker ORB)
input bool   InpSkipFriday      = false;       // Skip Fridays (afternoon risk)

//=== Risk Management ================================================
input group "=== Risk Management ==="
input double InpLotSize         = 0.0;         // Fixed lot (0 = % risk mode)
input double InpRiskPercent     = 1.0;         // Risk % per trade
input double InpSLFraction      = 0.5;         // SL = ORB range × this (0.5 = half range)
input bool   InpUseSLATR        = false;       // Use H1 ATR as SL base instead of range fraction
input double InpSLATRFrac       = 0.5;         // SL = H1 ATR × this (when InpUseSLATR=true)
input bool   InpUseSingleTP     = false;       // Single full-TP mode vs split TP
input double InpSingleTP_RR     = 2.0;         // R:R for single TP mode
input double InpTP1_RR          = 1.5;         // TP1 R:R (split mode – partial close)
input double InpTP2_RR          = 3.0;         // TP2 R:R runner (split mode)
input double InpTP1_ClosePct    = 50.0;        // % to close at TP1
input bool   InpUseTrailingStop = true;        // Trail the TP2 runner
input double InpTrailATR_Mult   = 1.0;         // Trail distance = H1 ATR × this
input int    InpMaxWeeklyTrades = 3;           // Max trades per calendar week (0 = unlimited)

//=== Entry Filters ==================================================
input group "=== Entry Filters ==="
input bool   InpUseATRBuffer    = true;        // ATR-adaptive breakout buffer (replaces fixed pts)
input double InpBufATRMult      = 0.05;        // Buffer = H1 ATR × this (~5 pts at ATR 100)
input double InpBreakoutBuffer  = 5.0;         // Fixed buffer pts (used when InpUseATRBuffer=false)
input bool   InpUseTrendFilter  = true;        // H4 EMA trend alignment
input int    InpTrendPeriod     = 50;          // Trend EMA period
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H4; // Trend EMA timeframe
input bool   InpUseATRFilter    = true;        // ATR range gate (filter choppy/blow-out opens)
input double InpATR_MinMult     = 0.3;         // ORB min = H1 ATR × this
input double InpATR_MaxMult     = 2.0;         // ORB max = H1 ATR × this
input int    InpATRPeriod       = 14;          // ATR period (H1)
input double InpMinRangePts     = 15.0;        // Minimum ORB range in points
input bool   InpUseBarQuality   = true;        // Breakout bar must close convincingly past ORH/ORL
input double InpBarQualityMin   = 0.55;        // Internal bar strength of cfm bar (0=bottom, 1=top)

//=== Dynamic Daily Filters ==========================================
input group "=== Dynamic Daily Filters ==="
input bool   InpUseIBS          = true;        // IBS (Internal Bar Strength) of prev D1 bar
input double InpIBS_LongMax     = 0.5;         // For LONG: prev IBS must be > this (momentum)
input double InpIBS_ShortMin    = 0.5;         // For SHORT: prev IBS must be < this (momentum)
// IBS note: IBS=(close-low)/(high-low). High IBS→strong close→long momentum. Low→short momentum.
// Default: IBS>0.5 = long bias, IBS<0.5 = short bias (momentum continuation model)
input bool   InpUseRSI3         = true;        // D1 RSI(3) mean-reversion guard
input double InpRSI3_OB         = 75.0;        // RSI(3) ≥ this → skip longs (overbought)
input double InpRSI3_OS         = 25.0;        // RSI(3) ≤ this → skip shorts (oversold)
input bool   InpUseGapFilter    = true;        // Skip day if overnight gap > D1 ATR × mult
input double InpGapMaxMult      = 0.5;         // Max gap allowed = D1 ATR × this

//=== Expert Settings ================================================
input int    InpMagicNumber     = 202401;      // EA Magic Number

//====================================================================
CTrade   trade;

// ORB data
double   g_orbHigh       = 0;
double   g_orbLow        = 0;
bool     g_orbSet        = false;
bool     g_tradedToday   = false;
bool     g_tp1Hit        = false;
bool     g_fakeoutLong   = false;   // long breakout already failed today
bool     g_fakeoutShort  = false;   // short breakout already failed today
bool     g_eodClosed     = false;   // EOD close already executed

// Market data
double   g_h1ATR         = 0;
double   g_d1ATR         = 0;
double   g_h4EMA         = 0;
double   g_ibs           = 0.5;    // prev D1 Internal Bar Strength
double   g_rsi3          = 50.0;   // D1 RSI(3)
double   g_gapSize       = 0;

// State
datetime g_lastBarTime   = 0;
datetime g_lastCfmBar    = 0;
datetime g_lastDay       = 0;
int      g_dayOfWeek     = 0;
bool     g_refresh16Done = false;
ulong    g_ticket2       = 0;

// Weekly trade tracking
int      g_weekTrades    = 0;
int      g_lastWeekNo    = -1;

//+------------------------------------------------------------------+
//| Detect fill mode for this symbol                                 |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillMode()
{
   long f = (long)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if ((f & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   if ((f & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

ENUM_TIMEFRAMES CfmPeriod()
{
   if (InpConfirmTF == 1)  return PERIOD_M1;
   if (InpConfirmTF == 15) return PERIOD_M15;
   return PERIOD_M5;
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(DetectFillMode());
   EventSetTimer(60);   // 1-min timer for EOD close

   PrintFormat("NAS100 ORB v3.0 | fill=%s | IBS=%s | RSI3=%s | EOD=%d:%02d",
               EnumToString(DetectFillMode()),
               InpUseIBS   ? "ON" : "OFF",
               InpUseRSI3  ? "ON" : "OFF",
               InpEODCloseHour, InpEODCloseMin);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("NAS100 ORB v3.0 removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer – fires every 60 s; used for EOD hard close               |
//+------------------------------------------------------------------+
void OnTimer()
{
   if (g_eodClosed) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int curMin  = dt.hour * 60 + dt.min;
   int eodMin  = InpEODCloseHour * 60 + InpEODCloseMin;

   if (curMin >= eodMin)
   {
      CloseAllPositions("EOD hard close");
      g_eodClosed = true;
   }
}

//+------------------------------------------------------------------+
//| Close all positions with our magic number                        |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      trade.PositionClose(ticket, 30);
   }
   if (reason != "") Print("Positions closed: ", reason);
}

//+------------------------------------------------------------------+
//| Main tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   // Throttle to once per M1 bar
   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if (barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_dayOfWeek = dt.day_of_week;

   // Daily reset at midnight
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                                 dt.year, dt.mon, dt.day));
   if (today != g_lastDay)
   {
      g_orbHigh       = 0;
      g_orbLow        = 0;
      g_orbSet        = false;
      g_tradedToday   = false;
      g_tp1Hit        = false;
      g_fakeoutLong   = false;
      g_fakeoutShort  = false;
      g_eodClosed     = false;
      g_ticket2       = 0;
      g_refresh16Done = false;
      g_lastCfmBar    = 0;
      g_gapSize       = 0;
      g_lastDay       = today;

      // Reset weekly counter at start of Mon (day_of_week=1)
      int weekNo = WeekNumber();
      if (weekNo != g_lastWeekNo) { g_weekTrades = 0; g_lastWeekNo = weekNo; }
   }

   // Skip whole-day filters
   if (InpSkipMonday  && g_dayOfWeek == 1) return;
   if (InpSkipFriday  && g_dayOfWeek == 5) return;

   // Pre-session data load at exactly 16:00
   if (!g_refresh16Done && dt.hour == 16 && dt.min == 0)
   {
      RefreshPreSessionData();
      g_refresh16Done = true;
   }

   // Manage runner trailing stop
   if (InpUseTrailingStop) ManageTrailingStop();

   // Detect if a confirmed breakout became a fake-out (price returned inside ORB)
   if (g_orbSet && !g_tradedToday) DetectFakeout();

   // Build ORB range
   if (!g_orbSet) BuildORB();

   // Check for breakout entry
   if (g_orbSet && !g_tradedToday) CheckBreakout();
}

//+------------------------------------------------------------------+
//| Calculate ISO week number (Mon=start of week)                    |
//+------------------------------------------------------------------+
int WeekNumber()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // Simple week ID: year * 100 + count of Mondays since Jan 1
   // Approximate: use year*54 + day_of_year/7
   return dt.year * 54 + (dt.day + 6) / 7;
}

//+------------------------------------------------------------------+
//| Refresh all daily data at 16:00 server time                      |
//+------------------------------------------------------------------+
void RefreshPreSessionData()
{
   // H1 ATR(14) – used for: range gate, SL, trailing stop, buffer
   int hATR = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   if (hATR != INVALID_HANDLE)
   {
      double buf[]; ArraySetAsSeries(buf, true);
      if (CopyBuffer(hATR, 0, 0, 3, buf) > 0)
         g_h1ATR = buf[1];   // last completed H1 bar
      IndicatorRelease(hATR);
   }

   // D1 ATR(14) – gap filter scale reference
   int dATR = iATR(_Symbol, PERIOD_D1, 14);
   if (dATR != INVALID_HANDLE)
   {
      double buf[]; ArraySetAsSeries(buf, true);
      if (CopyBuffer(dATR, 0, 1, 1, buf) > 0)
         g_d1ATR = buf[0];
      IndicatorRelease(dATR);
   }

   // H4 EMA trend filter
   if (InpUseTrendFilter)
   {
      int hEMA = iMA(_Symbol, InpTrendTF, InpTrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if (hEMA != INVALID_HANDLE)
      {
         double buf[]; ArraySetAsSeries(buf, true);
         if (CopyBuffer(hEMA, 0, 0, 2, buf) > 0)
            g_h4EMA = buf[0];
         IndicatorRelease(hEMA);
      }
   }

   // IBS of previous D1 bar: (close - low) / (high - low)
   if (InpUseIBS)
   {
      double prevH = iHigh (_Symbol, PERIOD_D1, 1);
      double prevL = iLow  (_Symbol, PERIOD_D1, 1);
      double prevC = iClose(_Symbol, PERIOD_D1, 1);
      double rng   = prevH - prevL;
      g_ibs = (rng > 0) ? (prevC - prevL) / rng : 0.5;
   }

   // D1 RSI(3)
   if (InpUseRSI3)
   {
      int hRSI = iRSI(_Symbol, PERIOD_D1, 3, PRICE_CLOSE);
      if (hRSI != INVALID_HANDLE)
      {
         double buf[]; ArraySetAsSeries(buf, true);
         if (CopyBuffer(hRSI, 0, 1, 1, buf) > 0)
            g_rsi3 = buf[0];
         IndicatorRelease(hRSI);
      }
   }

   // Overnight gap: previous D1 close vs current pre-open bid
   double prevClose = iClose(_Symbol, PERIOD_D1, 1);
   double preOpen   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_gapSize = (prevClose > 0) ? MathAbs(preOpen - prevClose) : 0;

   PrintFormat("Pre-session v3 | H1ATR=%.0f | D1ATR=%.0f | EMA=%.1f | IBS=%.2f | RSI3=%.1f | Gap=%.0f pts",
               g_h1ATR/_Point, g_d1ATR/_Point, g_h4EMA,
               g_ibs, g_rsi3, g_gapSize/_Point);

   // Gap filter – skip day if overnight extension too large
   if (InpUseGapFilter && g_d1ATR > 0 && g_gapSize > g_d1ATR * InpGapMaxMult)
   {
      SkipDay(StringFormat("gap %.0f pts > D1ATR*%.1f (%.0f pts)",
              g_gapSize/_Point, InpGapMaxMult, g_d1ATR*InpGapMaxMult/_Point));
   }
}

//+------------------------------------------------------------------+
//| Build ORB range from M1 bars within the time window              |
//+------------------------------------------------------------------+
void BuildORB()
{
   MqlDateTime mdt; TimeToStruct(TimeCurrent(), mdt);
   datetime midnight   = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                                      mdt.year, mdt.mon, mdt.day));
   datetime orbStart   = midnight + (datetime)(InpORBStartHour * 3600 + InpORBStartMin * 60);
   datetime orbEnd     = orbStart + (datetime)(InpORBDurationMin * 60);
   datetime now        = TimeCurrent();

   if (now < orbStart) return;

   double hi = 0, lo = DBL_MAX;
   bool   found = false;
   int    limit = InpORBDurationMin + 10;

   for (int i = 0; i <= limit; i++)
   {
      datetime bt = iTime(_Symbol, PERIOD_M1, i);
      if (bt == 0 || bt < orbStart) break;
      if (bt >= orbEnd)             continue;
      double bh = iHigh(_Symbol, PERIOD_M1, i);
      double bl = iLow (_Symbol, PERIOD_M1, i);
      if (bh > hi) hi = bh;
      if (bl < lo) lo = bl;
      found = true;
   }

   if (found) { g_orbHigh = hi; g_orbLow = lo; }
   if (now >= orbEnd) FinalizeORB();
}

//+------------------------------------------------------------------+
//| Validate ORB range                                               |
//+------------------------------------------------------------------+
void FinalizeORB()
{
   if (g_orbHigh <= 0 || g_orbLow <= 0 || g_orbHigh <= g_orbLow)
      { SkipDay("no valid ORB data"); return; }

   double range = g_orbHigh - g_orbLow;

   if (range < InpMinRangePts * _Point)
      { SkipDay(StringFormat("range %.0f pts < min %.0f", range/_Point, InpMinRangePts)); return; }

   if (InpUseATRFilter && g_h1ATR > 0)
   {
      double lo_gate = g_h1ATR * InpATR_MinMult;
      double hi_gate = g_h1ATR * InpATR_MaxMult;
      if (range < lo_gate || range > hi_gate)
      {
         SkipDay(StringFormat("range %.0f pts outside ATR gate [%.0f–%.0f]",
                 range/_Point, lo_gate/_Point, hi_gate/_Point));
         return;
      }
   }

   g_orbSet = true;
   PrintFormat("ORB set | High=%.2f  Low=%.2f  Range=%.0f pts",
               g_orbHigh, g_orbLow, range/_Point);
}

void SkipDay(string reason)
{
   PrintFormat("Day skipped: %s", reason);
   g_orbSet      = true;
   g_tradedToday = true;
}

//+------------------------------------------------------------------+
//| Detect fake-out: price broke level but returned inside ORB       |
//+------------------------------------------------------------------+
void DetectFakeout()
{
   if (g_orbHigh <= 0 || g_orbLow <= 0) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // If price has gone above ORH but is now back below it → record long fake-out
   if (!g_fakeoutLong && bid < g_orbLow)
      g_fakeoutLong = true;   // price is deeply below – large move short, long side exhausted

   if (!g_fakeoutShort && bid > g_orbHigh)
      g_fakeoutShort = true;
}

//+------------------------------------------------------------------+
//| Check for breakout entry on each new confirmation bar close      |
//+------------------------------------------------------------------+
void CheckBreakout()
{
   ENUM_TIMEFRAMES tfm = CfmPeriod();
   datetime cfmBar = iTime(_Symbol, tfm, 0);
   if (cfmBar == g_lastCfmBar) return;
   g_lastCfmBar = cfmBar;

   // Time cutoff for new entries
   MqlDateTime dt; TimeToStruct(cfmBar, dt);
   if (dt.hour * 60 + dt.min >= InpTradeEndHour * 60 + InpTradeEndMin) return;

   // After EOD close no new trades
   if (g_eodClosed) return;

   // Weekly cap
   if (InpMaxWeeklyTrades > 0 && g_weekTrades >= InpMaxWeeklyTrades) return;

   // Read last closed bar
   double cfmClose = iClose(_Symbol, tfm, 1);
   double cfmHigh  = iHigh (_Symbol, tfm, 1);
   double cfmLow   = iLow  (_Symbol, tfm, 1);
   if (cfmClose <= 0) return;

   // Adaptive or fixed buffer
   double buf = InpUseATRBuffer && g_h1ATR > 0
                ? g_h1ATR * InpBufATRMult
                : InpBreakoutBuffer * _Point;

   bool longBreak  = (cfmClose > g_orbHigh + buf);
   bool shortBreak = (cfmClose < g_orbLow  - buf);
   if (!longBreak && !shortBreak) return;

   // Bar quality: confirm bar must close convincingly past the level
   if (InpUseBarQuality)
   {
      double barRange = cfmHigh - cfmLow;
      if (barRange > 0)
      {
         double barIBS = (cfmClose - cfmLow) / barRange;
         if ( longBreak && barIBS < InpBarQualityMin)
         { Print("Long filtered: weak breakout bar IBS=", DoubleToString(barIBS,2)); return; }
         if (!longBreak && barIBS > (1.0 - InpBarQualityMin))
         { Print("Short filtered: weak breakout bar IBS=", DoubleToString(barIBS,2)); return; }
      }
   }

   // H4 EMA trend filter
   if (!IsTrendAligned(longBreak)) return;

   // IBS filter (momentum continuation)
   if (InpUseIBS)
   {
      if ( longBreak && g_ibs < InpIBS_LongMax)
      { PrintFormat("Long filtered: IBS=%.2f < %.2f", g_ibs, InpIBS_LongMax); return; }
      if (!longBreak && g_ibs > InpIBS_ShortMin)
      { PrintFormat("Short filtered: IBS=%.2f > %.2f", g_ibs, InpIBS_ShortMin); return; }
   }

   // D1 RSI(3) mean-reversion guard
   if (InpUseRSI3)
   {
      if ( longBreak && g_rsi3 >= InpRSI3_OB)
      { PrintFormat("Long filtered: RSI3=%.1f >= %.1f (overbought)", g_rsi3, InpRSI3_OB); return; }
      if (!longBreak && g_rsi3 <= InpRSI3_OS)
      { PrintFormat("Short filtered: RSI3=%.1f <= %.1f (oversold)", g_rsi3, InpRSI3_OS); return; }
   }

   // Execute
   double entryPx = longBreak
                    ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                    : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   ExecuteTrade(longBreak ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, entryPx);
}

//+------------------------------------------------------------------+
//| H4 EMA trend alignment check                                     |
//+------------------------------------------------------------------+
bool IsTrendAligned(bool isLong)
{
   if (!InpUseTrendFilter || g_h4EMA <= 0) return true;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if ( isLong && bid < g_h4EMA) { Print("Trend filter: long below EMA"); return false; }
   if (!isLong && bid > g_h4EMA) { Print("Trend filter: short above EMA"); return false; }
   return true;
}

//+------------------------------------------------------------------+
//| SL distance: fraction of ORB range or H1 ATR                    |
//+------------------------------------------------------------------+
double CalcSL_Distance()
{
   if (InpUseSLATR && g_h1ATR > 0) return g_h1ATR * InpSLATRFrac;
   return (g_orbHigh - g_orbLow) * InpSLFraction;
}

//+------------------------------------------------------------------+
//| Position size                                                    |
//+------------------------------------------------------------------+
double CalcLots(double slPoints)
{
   if (InpLotSize > 0) return NormLot(InpLotSize);
   double bal     = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk    = bal * InpRiskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickVal <= 0 || tickSz <= 0 || slPoints <= 0) return NormLot(0.01);
   return NormLot(risk / (slPoints / tickSz * tickVal));
}

double NormLot(double lots)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMax(mn, MathMin(mx, MathFloor(lots / st) * st));
}

//+------------------------------------------------------------------+
//| Execute trade (single TP or split TP)                            |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double price)
{
   double slDist = CalcSL_Distance();
   if (slDist < _Point) return;

   double sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
   // SL must always be outside the ORB
   if (type == ORDER_TYPE_BUY)  sl = MathMin(sl, g_orbLow  - _Point);
   else                          sl = MathMax(sl, g_orbHigh + _Point);

   double slPoints = MathAbs(price - sl);
   if (slPoints < _Point) return;

   double totalLots = CalcLots(slPoints);
   if (totalLots <= 0) return;

   string tag = (type == ORDER_TYPE_BUY) ? "L" : "S";

   if (InpUseSingleTP)
   {
      double tp = (type == ORDER_TYPE_BUY)
                  ? price + slPoints * InpSingleTP_RR
                  : price - slPoints * InpSingleTP_RR;
      bool ok = (type == ORDER_TYPE_BUY)
                ? trade.Buy (totalLots, _Symbol, price, sl, tp, "ORB_NAS100_" + tag)
                : trade.Sell(totalLots, _Symbol, price, sl, tp, "ORB_NAS100_" + tag);
      if (ok)
      {
         g_tradedToday = true;
         g_weekTrades++;
         PrintFormat("ORB SINGLE %s | Lots=%.2f | SL=%.2f | TP=%.2f | RR=%.1f",
                     tag, totalLots, sl, tp, InpSingleTP_RR);
      }
      return;
   }

   // Split TP
   double tp1 = (type == ORDER_TYPE_BUY) ? price + slPoints * InpTP1_RR : price - slPoints * InpTP1_RR;
   double tp2 = (type == ORDER_TYPE_BUY) ? price + slPoints * InpTP2_RR : price - slPoints * InpTP2_RR;

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot1   = MathFloor(totalLots * InpTP1_ClosePct / 100.0 / step) * step;
   double lot2   = NormLot(totalLots - lot1);
   if (lot1 < minLot) { lot1 = totalLots; lot2 = 0; }

   bool ok1 = (type == ORDER_TYPE_BUY)
              ? trade.Buy (lot1, _Symbol, price, sl, tp1, "ORB_NAS100_TP1")
              : trade.Sell(lot1, _Symbol, price, sl, tp1, "ORB_NAS100_TP1");

   g_ticket2 = 0;
   if (ok1 && lot2 >= minLot)
   {
      bool ok2 = (type == ORDER_TYPE_BUY)
                 ? trade.Buy (lot2, _Symbol, price, sl, tp2, "ORB_NAS100_TP2")
                 : trade.Sell(lot2, _Symbol, price, sl, tp2, "ORB_NAS100_TP2");
      if (ok2) g_ticket2 = trade.ResultOrder();
   }

   if (ok1)
   {
      g_tradedToday = true;
      g_tp1Hit      = false;
      g_weekTrades++;
      PrintFormat("ORB SPLIT %s | Lots=%.2f+%.2f | SL=%.2f | TP1=%.2f(%.1fR) | TP2=%.2f(%.1fR)",
                  tag, lot1, lot2, sl, tp1, InpTP1_RR, tp2, InpTP2_RR);
   }
}

//+------------------------------------------------------------------+
//| Trailing stop on TP2 runner (H1 ATR based)                      |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if (g_ticket2 == 0 || !g_tp1Hit || g_h1ATR <= 0) return;
   double trailDist = g_h1ATR * InpTrailATR_Mult;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC)  != InpMagicNumber) continue;
      if (StringFind(PositionGetString(POSITION_COMMENT), "TP2") == -1) continue;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double curPx = PositionGetDouble(POSITION_PRICE_CURRENT);
      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if (pt == POSITION_TYPE_BUY)
      {
         double newSL = NormalizeDouble(curPx - trailDist, _Digits);
         if (newSL > curSL + _Point)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else
      {
         double newSL = NormalizeDouble(curPx + trailDist, _Digits);
         if (newSL < curSL - _Point)
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| TP1 hit → move runner to breakeven                              |
//+------------------------------------------------------------------+
void MoveRunnerToBreakeven()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if (StringFind(PositionGetString(POSITION_COMMENT), "TP2") == -1) continue;

      double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      bool needsMove = (pt == POSITION_TYPE_BUY  && curSL < openPx) ||
                       (pt == POSITION_TYPE_SELL && curSL > openPx);
      if (needsMove)
      {
         trade.PositionModify(ticket, NormalizeDouble(openPx, _Digits), curTP);
         PrintFormat("TP1 hit – TP2 runner SL → breakeven %.2f", openPx);
      }
   }
}

//+------------------------------------------------------------------+
//| Trade transaction handler                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
   if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if (!HistoryDealSelect(trans.deal))           return;

   long   magic   = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   long   reason  = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   string comment = HistoryDealGetString (trans.deal, DEAL_COMMENT);

   if (magic != InpMagicNumber) return;
   if (StringFind(comment, "ORB_NAS100_TP1") >= 0 && reason == DEAL_REASON_TP)
   {
      g_tp1Hit = true;
      MoveRunnerToBreakeven();
   }
}
//+------------------------------------------------------------------+
