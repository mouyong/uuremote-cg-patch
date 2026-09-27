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
# ★ 别信 .active_pid（可能为 0 或残留）：直接按进程名精确取。
PID=$(pgrep -x UURemoteServer | head -1)
[ -z "$PID" ] && PID=$(cat /Users/Shared/UURemote/Shared/.active_pid 2>/dev/null)
echo "== 会话 pid=${PID}，采样 ${N} 次 × ${IV}s =="
[ -z "$PID" ] && { echo "✘ 无活跃会话"; exit 1; }

# ★★ 取样纪律（这两个坑都真踩过，会把结论带反方向）：
#  ① 必须 `grep "^UURemoteServer\."` **锚定行首**：不锚定会匹配到命令行/其它行。
#  ② 必须取**最后一行**（`tail -1`）：`nettop -P` 同一进程会打**多行**
#     （按接口拆分的分项 + 最后的总计）。取首行 = 取到某个单接口的小数值 ——
#     实测这一处让「视频在流转 2.5 Mbps」被读成「只有 5 kbps，视频没发出去」，
#     整条排查方向被带偏。分项行通常只有一个接口有值，总计行才是真值。
#  ③ 单位：DO 字节 / IV 秒 × 8 ÷ 1000 = kbit/s（整数运算）。
sample_out() {
  nettop -P -L 1 -n -x -J bytes_in,bytes_out 2>/dev/null \
    | grep "^UURemoteServer\." | tail -1 | awk -F, '{print $3}'
}
sample_in() {
  nettop -P -L 1 -n -x -J bytes_in,bytes_out 2>/dev/null \
    | grep "^UURemoteServer\." | tail -1 | awk -F, '{print $2}'
}

prev_out=""; prev_in=""
i=1
while [ "$i" -le "$N" ]; do
  # 每进程总量（取总计行 —— 见上面的取样纪律）
  O=$(sample_out); I=$(sample_in)
  T=$(date +%H:%M:%S)
  LINE="[$T] 进程 in=${I:-–} out=${O:-–}"
  # ★ 只接受「纯数字」：解析失败时（空串/带单位）宁可显示「—」也不印一个假数字。
  case "${O:-}" in ''|*[!0-9]*) O="";; esac
  case "${I:-}" in ''|*[!0-9]*) I="";; esac
  if [ -n "$prev_out" ] && [ -n "$O" ]; then
    DO=$(( O - prev_out )); DI=$(( ${I:-0} - ${prev_in:-0} ))
    # ★ 增量不可能为负（累计值是只增的）。为负 = 行取错了/进程换了，必须显式说出来，
    #   不能默默印一个负数让人误以为「流量很小」。
    if [ "$DO" -lt 0 ]; then
      LINE="$LINE  Δout=回退（取样行取错或进程已换，本次作废）"
      prev_out=""; prev_in=""
      sleep "$IV"; i=$((i+1)); continue
    fi
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
