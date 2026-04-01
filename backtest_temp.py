import numpy as np
import pandas as pd

EMA_PERIOD=46; PRICE_THRESHOLD_PIPS=600; SLOPE_THRESHOLD_PIPS=80
TRAILING_STOP_PIPS=260; MAX_TRADES_PER_CROSSOVER=9; PROFIT_CHECK_BARS=12
PIP=0.0001; PRICE_THRESHOLD=PRICE_THRESHOLD_PIPS*PIP; SLOPE_THRESHOLD=SLOPE_THRESHOLD_PIPS*PIP
TRAILING_STOP=TRAILING_STOP_PIPS*PIP; TIMEOUT_BARS=max(1,800//3600)
INITIAL_CAPITAL=10000; LOT_SIZE=0.03; PIP_VALUE_PER_LOT=10.0

def make_eurusd(n=1260, seed=42):
    rng=np.random.default_rng(seed); kappa=0.05; sigma=0.006
    log_p=np.zeros(n); log_p[0]=np.log(1.10)
    for t in range(1,n):
        log_p[t]=log_p[t-1]+kappa*(0.0-log_p[t-1])/252+sigma*rng.standard_normal()
    prices=np.exp(log_p)
    dates=pd.date_range("2020-01-02",periods=n,freq="B")
    return pd.DataFrame({"close":prices},index=dates)

df=make_eurusd()
df["ema"]=df["close"].ewm(span=EMA_PERIOD,adjust=False).mean()
df["slope"]=df["ema"].diff(); df.dropna(inplace=True)

trades,position=[],None
pta=sta=ma=False; msb=tic=0; pcve=None
closes=df["close"].values; emas=df["ema"].values; slopes=df["slope"].values; dates=df.index.values

for i in range(1,len(df)):
    c,ema,slp,dt=closes[i],emas[i],slopes[i],dates[i]
    if np.isnan(ema) or np.isnan(slp): continue
    ca=c>ema
    if pcve is not None and ca!=pcve: tic=0
    pcve=ca
    if position is not None:
        pt,ep,eb,sl,bars=position["type"],position["entry"],position["entry_bar"],position["sl"],i-position["entry_bar"]
        pnl=(c-ep)/PIP if pt=="BUY" else (ep-c)/PIP
        if pt=="BUY" and pnl>0:
            ns=c-TRAILING_STOP
            if ns>sl: position["sl"]=sl=ns
        elif pt=="SELL" and pnl>0:
            ns=c+TRAILING_STOP
            if sl==0 or ns<sl: position["sl"]=sl=ns
        slh=(pt=="BUY" and sl>0 and c<sl) or (pt=="SELL" and sl>0 and c>sl)
        mre=(pt=="BUY" and c<ema) or (pt=="SELL" and c>ema)
        ts=bars>=PROFIT_CHECK_BARS and pnl<=0
        if slh or mre or ts:
            reason="SL" if slh else ("MeanRevExit" if mre else "TimeStop")
            pusd=pnl*PIP_VALUE_PER_LOT*LOT_SIZE*100
            trades.append({"type":pt,"pnl_pips":pnl,"pnl_usd":pusd,"bars":bars,"reason":reason,
                           "entry_date":pd.Timestamp(position["entry_date"]),"exit_date":pd.Timestamp(dt)})
            position=None; continue
    pdp=abs(c-ema)/PIP; sp=abs(slp)/PIP
    if pdp>PRICE_THRESHOLD_PIPS and not pta: pta=True
    if sp>SLOPE_THRESHOLD_PIPS and not sta: sta=True
    if pta and sta and not ma: ma=True; msb=i
    if ma and (i-msb)>TIMEOUT_BARS: ma=pta=sta=False
    if ma and position is None and tic<MAX_TRADES_PER_CROSSOVER:
        d="BUY" if c>ema else ("SELL" if c<ema else None)
        if d:
            position={"type":d,"entry":c,"entry_bar":i,"entry_date":dt,"sl":0.0}
            tic+=1; ma=pta=sta=False

if position is not None:
    c=closes[-1]; pnl=(c-position["entry"])/PIP if position["type"]=="BUY" else (position["entry"]-c)/PIP
    trades.append({"type":position["type"],"pnl_pips":pnl,"pnl_usd":pnl*PIP_VALUE_PER_LOT*LOT_SIZE*100,
                   "bars":len(df)-1-position["entry_bar"],"reason":"EndOfData",
                   "entry_date":pd.Timestamp(position["entry_date"]),"exit_date":pd.Timestamp(dates[-1])})

if not trades:
    print("NO TRADES GENERATED - thresholds too high")
else:
    r=pd.DataFrame(trades); r["equity"]=INITIAL_CAPITAL+r["pnl_usd"].cumsum()
    n=len(r); wins=r[r.pnl_pips>0]; losses=r[r.pnl_pips<=0]
    wr=len(wins)/n*100; total=r.pnl_usd.sum()
    pf=wins.pnl_usd.sum()/-losses.pnl_usd.sum() if losses.pnl_usd.sum()<0 else float("inf")
    ec=r.equity.values; dd=ec-np.maximum.accumulate(ec); mdd=dd.min(); mdd_pct=mdd/INITIAL_CAPITAL*100
    dr=r.set_index("exit_date").pnl_usd.resample("D").sum()/INITIAL_CAPITAL
    sharpe=dr.mean()/dr.std()*np.sqrt(252) if dr.std()>0 else 0
    avg_w=wins.pnl_pips.mean() if len(wins)>0 else 0; avg_l=losses.pnl_pips.mean() if len(losses)>0 else 0
    print("="*56)
    print("  BACKTEST RESULTS - Synthetic EURUSD daily 1260 bars")
    print("="*56)
    print(f"  Total trades    : {n}")
    print(f"  Win rate        : {wr:.1f}%")
    print(f"  Profit factor   : {pf:.2f}")
    print(f"  Total P&L       : ${total:+.2f}  ({total/INITIAL_CAPITAL*100:+.1f}%)")
    print(f"  Avg win         : {avg_w:+.1f} pips")
    print(f"  Avg loss        : {avg_l:+.1f} pips")
    print(f"  Max drawdown    : ${mdd:.2f}  ({mdd_pct:.1f}%)")
    print(f"  Sharpe ratio    : {sharpe:.2f}")
    print(f"  Avg bars held   : {r.bars.mean():.1f}")
    print(f"\n  EXIT BREAKDOWN:")
    for reason,cnt in r.reason.value_counts().items():
        print(f"    {reason:<18}: {cnt}")
    print("="*56)
    print("\n  FIRST 15 TRADES:")
    print(f"  {'#':3}  {'Type':5}  {'Date':12}  {'Pips':>8}  {'USD':>8}  {'Bars':>5}  Reason")
    print("  "+"-"*62)
    for idx,row in r.head(15).iterrows():
        print(f"  {idx+1:3}  {row.type:5}  {str(row.entry_date.date()):12}  {row.pnl_pips:>8.1f}  {row.pnl_usd:>8.2f}  {row.bars:>5}  {row.reason}")
    print()
    print("  EQUITY PROGRESSION (every 10 trades):")
    for idx in range(0,len(r),max(1,len(r)//10)):
        print(f"    Trade {idx+1:3}: equity=${r.equity.iloc[idx]:.2f}")
    print(f"    FINAL   : equity=${r.equity.iloc[-1]:.2f}")
