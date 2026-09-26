#!/bin/bash
# 会话实时监测：帧产出 / 真实亮度 / 脏矩形查询 / 上行流量（每条连接）
# 用法： bash tools/uu-monitor.sh [秒数]
DUR=${1:-60}
P=$(cat /Users/Shared/UURemote/Shared/.active_pid 2>/dev/null)
if [ -z "$P" ] || ! ps -p "$P" >/dev/null 2>&1; then
  P=$(pgrep -f 'Helpers/UURemoteServer' | head -1)
fi
echo "== 监测 UURemoteServer pid=$P  ${DUR}s =="
[ -z "$P" ] && { echo "✘ 没有 UURemoteServer 进程"; exit 1; }

frame() { grep '出帧' /tmp/uushim.log 2>/dev/null | tail -1 | sed 's/.*总 \([0-9]*\) 帧.*/\1/'; }
cpu()   { ps -o time= -p "$P" 2>/dev/null | tr -d ' '; }
tot()   { nettop -P -l 1 -x -J bytes_in,bytes_out -p "$P" 2>/dev/null | awk -v p="UURemoteServer.$P" '$1==p {print $2" "$3; exit}'; }

f1=$(frame); t1=$(cpu); a=$(tot)
echo "T0 帧=$f1 cpu=$t1 累计in/out=$a"
sleep "$DUR"
f2=$(frame); t2=$(cpu); b=$(tot)
echo "T1 帧=$f2 cpu=$t2 累计in/out=$b"

python3 - "$DUR" "$f1" "$f2" "$a" "$b" "$t1" "$t2" <<'PY'
import sys
dur, f1, f2, a, b, t1, t2 = sys.argv[1:8]
try: fps = (int(f2 or 0) - int(f1 or 0)) / float(dur)
except Exception: fps = 0
def secs(x):
    try:
        h, m, s = x.split(':'); return int(h)*3600 + int(m)*60 + float(s)
    except Exception: return 0.0
cpu_pct = (secs(t2) - secs(t1)) / float(dur) * 100
def mb(x):
    try: return int(x) / 1048576.0
    except Exception: return 0.0
try:
    o1 = int(a.split()[1]); o2 = int(b.split()[1]); i1 = int(a.split()[0]); i2 = int(b.split()[0])
    out_kbs = (o2 - o1) / float(dur) / 1024.0
    in_kbs  = (i2 - i1) / float(dur) / 1024.0
except Exception:
    out_kbs = in_kbs = 0.0
print(f"→ 帧产出 {fps:.1f} FPS   进程 CPU {cpu_pct:.1f}%（单核百分比）")
print(f"→ 上行 {out_kbs:.0f} KB/s ({out_kbs*8/1000:.2f} Mbps)  下行 {in_kbs:.0f} KB/s")
print(f"→ 累计 出/入 = {mb(b.split()[1]) if b.split() else 0:.1f} MB / {mb(b.split()[0]) if b.split() else 0:.1f} MB")
if fps > 1 and out_kbs < 50:
    print("⚠ 有帧但几乎没有上行 → 帧被 UU 丢掉，没进编码器")
elif fps > 1 and out_kbs > 100:
    print("✔ 有帧且有上行 → 视频真的在传输（问题在接收端/解码）")
PY

echo
echo "-- 各连接流量（本次会话累计）--"
nettop -l 1 -x -J bytes_in,bytes_out -p "$P" 2>/dev/null | tail -n +2 | awk '{printf "  %-50s in=%-10s out=%s\n", $4" "$5, $2, $3}' | head -10
echo
echo "-- shim 最新日志 --"
tail -4 /tmp/uushim.log 2>/dev/null | sed 's/^/  /'
