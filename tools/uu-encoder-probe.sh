#!/bin/bash
# 会话中编码器探针：判断 UU 的 H.264 编码器到底有没有在干活
# 用法: bash tools/uu-encoder-probe.sh [采样次数] [每次秒数]
#       bash tools/uu-encoder-probe.sh --analyze <sample文件>   # 只分析（自测用）
#
# 为什么要用采样而不是 hook：给 interpose 加「透传式探针」在本机行不通 ——
# 施加 interpose 后，dlsym 的所有变体（含 RTLD_FIRST / RTLD_NEXT）都返回
# 我们自己的函数，拿不到真实现，无法把调用转回原函数。所以改为「旁观」。
#
# ★ 关键：sample 输出末尾有一段「Binary Images」库清单，里面必然出现
#   VideoToolbox / uushim 等字样。**只统计栈帧部分，否则永远假绿。**
set -u

# 只取「Binary Images:」之前的栈帧部分
stack_only() { awk '/^Binary Images:/{exit} {print}' "$1" 2>/dev/null; }

analyze() {
  local f="$1"
  stack_only "$f" > "$f.stack"
  grep -cE 'VTCompressionSession[A-Za-z]*|GVA[A-Za-z]*|h264|H264' "$f.stack" 2>/dev/null | tr -d ' '
}

VT=$(analyze "${1:-/dev/null}" 2>/dev/null || echo 0)
if [ "${1:-}" = "--analyze" ]; then
  F="${2:?需要文件}"
  echo "  文件: $F"
  echo "  栈帧里编码器痕迹: $(analyze "$F")"
  echo "  栈帧里采集痕迹:   $(grep -cE 'uushim|CGDisplayCreateImage|CheckIfFrameChange' "$F.stack" 2>/dev/null)"
  echo "  栈帧里 RTP 痕迹:  $(grep -cE 'rtp_send|SendPacket|VideoTrack|IceConnection' "$F.stack" 2>/dev/null)"
  echo "  （库清单已被排除，不会把「加载了 VideoToolbox」误当成「在编码」）"
  exit 0
fi

N=${1:-3}; SEC=${2:-3}
PID=$(cat /Users/Shared/UURemote/Shared/.active_pid 2>/dev/null)
echo "== 会话 pid=${PID}，采样 ${N} 次 × ${SEC}s =="
[ -z "$PID" ] && { echo "✘ 无活跃会话"; exit 1; }
kill -0 "$PID" 2>/dev/null || { echo "✘ 进程不存在"; exit 1; }

OUT=/tmp/uu-enc-probe-$(date +%H%M%S); mkdir -p "$OUT"
hit=0; i=1
while [ "$i" -le "$N" ]; do
  sample "$PID" "$SEC" -mayDie > "$OUT/s$i.txt" 2>/dev/null
  V=$(analyze "$OUT/s$i.txt")
  R=$(grep -cE 'rtp_send|SendPacket|VideoTrack|IceConnection' "$OUT/s$i.txt.stack" 2>/dev/null || echo 0)
  C=$(grep -cE 'uushim|CGDisplayCreateImage|CheckIfFrameChange' "$OUT/s$i.txt.stack" 2>/dev/null || echo 0)
  echo "  第${i}次: 编码器栈=$V  RTP/WebRTC栈=$R  采集栈=$C"
  [ "${V:-0}" -gt 0 ] && hit=$((hit+1))
  i=$((i+1))
done

echo
echo "== 编码器相关栈帧（去重）=="
grep -hE 'VTCompressionSession[A-Za-z]*|GVA[A-Za-z]*|h264|H264' "$OUT"/s*.stack 2>/dev/null \
  | sed 's/  *[0-9][0-9]* / /g' | sort -u | head -12 | sed 's/^/  /'
[ "$hit" -gt 0 ] && echo "  ✔ 判定：编码器在跑（${hit}/${N} 次命中栈帧）→ 视频有产出，问题在客户端侧" \
                 || echo "  ✘ 判定：${N} 次采样栈帧里都没有编码痕迹 → 帧没进编码器（被控端管线问题）"
echo "  原始采样: $OUT/"
