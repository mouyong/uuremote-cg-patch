#!/bin/bash
# 会话流量精确测量：区分视频流（UDP/WebRTC）与非视频（TCP 信令/上传）
# 用法: bash tools/uu-traffic.sh [采样次数] [间隔秒]
#
# 为什么需要它：nettop -P 的每进程累计值会随连接关闭而回退，不能单独采信；
# 必须用「固定时间间隔两次采样求增量」+「按连接逐个看」互相印证。
# 判定：若增量为 Mbps 量级且在 UDP/媒体连接上 → 视频真的在流；
#       若增量很小、只在 TCP 443 上 → 那只是信令/日志，视频没流出去。
set -u
N=${1:-12}
IV=${2:-5}
PID=$(cat /Users/Shared/UURemote/Shared/.active_pid 2>/dev/null)
echo "== 会话 pid=${PID}，采样 ${N} 次 × ${IV}s =="
[ -z "$PID" ] && { echo "✘ 无活跃会话"; exit 1; }

prev_out=""; prev_in=""
i=1
while [ "$i" -le "$N" ]; do
  # 每进程总量
  L=$(nettop -P -L 1 -n -x -t wifi -J bytes_in,bytes_out 2>/dev/null | grep "UURemoteServer")
  O=$(echo "$L" | awk -F, '{print $3}'); I=$(echo "$L" | awk -F, '{print $2}')
  T=$(date +%H:%M:%S)
  LINE="[$T] 进程 in=${I:-–} out=${O:-–}"
  if [ -n "$prev_out" ] && [ -n "${O:-}" ]; then
    DO=$(( O - prev_out )); DI=$(( ${I:-0} - ${prev_in:-0} ))
    LINE="$LINE  Δout=$DO Δin=$DI  ($(echo "scale=0; $DO*8/$IV/1000" | bc) kbps↑)"
  fi
  echo "$LINE"
  prev_out=${O:-}; prev_in=${I:-}

  # 每连接明细（TCP + UDP）
  if [ "$i" = "2" ] || [ "$i" = "6" ] || [ "$i" = "10" ]; then
    echo "  --- 连接明细（含 UDP，媒体流多走这里）---"
    netstat -anv 2>/dev/null | awk -v p="$PID" '
      ($0 ~ /udp4|tcp4/) && $0 ~ (" " p " ") {
        printf "    %-6s %-22s %-24s out=%-11s in=%s\n", $1, $4, $5, $8, $7
      }' | head -14
  fi
  sleep "$IV"; i=$((i+1))
done
echo "== 完 =="
