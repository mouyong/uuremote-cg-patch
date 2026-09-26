#!/bin/bash
# ============================================================================
# 验证「Metal 门禁补丁」是否真的把编码器救活了
# 用法：bash tools/uu-verify-encoder.sh
# 前提：已装新补丁（4 类），并且【别的设备已连过一次这台机器】（有被控会话才会出日志）
# ============================================================================
set -uo pipefail
D="${UURT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="${UURT_APP:-/Applications/UURemote.app}"
LIB="$APP/Contents/Frameworks/libstreamer.dylib"
MIN="${1:-30}"          # 回看多少分钟日志，默认 30

c_ok=$'\033[32m'; c_no=$'\033[31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'
ok(){ printf '%s✔%s %s\n' "$c_ok" "$c_off" "$1"; }
no(){ printf '%s✘%s %s\n' "$c_no" "$c_off" "$1"; }
hd(){ printf '\n%s=== %s ===%s\n' "$c_hd" "$1" "$c_off"; }

hd "0. 补丁状态（4 类都要 patched）"
python3 "$D/patch_tool.py" check "$LIB" 2>&1 | sed 's/^/  /'

hd "1. shim 出帧情况（/tmp/uushim.log 末尾）"
if [ -f /tmp/uushim.log ]; then
  tail -25 /tmp/uushim.log | sed 's/^/  /'
  n=$(grep -ac 'FPS' /tmp/uushim.log 2>/dev/null || echo 0)
  ok "日志里有 $n 行 FPS 汇报（>0 说明 shim 在出帧）"
else
  no "/tmp/uushim.log 不存在 —— 还没有被控会话，或日志被系统清理（先让别的设备连一次）"
fi

hd "2. 编码器是否起来（关键对照）"
LOG=$(log show --last "${MIN}m" --predicate 'process == "UURemoteServer"' --style compact 2>/dev/null || true)
bad=$(printf '%s\n' "$LOG" | grep -acE 'Failed to create metal device|error: 12|failed to create compression session' || true)
if [ "${bad:-0}" -gt 0 ]; then
  no "近 ${MIN} 分钟仍有 $bad 条编码器初始化失败 → 补丁没生效 / 没重启进程 / 被 UU 更新覆盖"
  printf '%s\n' "$LOG" | grep -aE 'Failed to create metal device|error: 12|failed to create compression session' | tail -5 | sed 's/^/    /'
else
  ok "近 ${MIN} 分钟没有「metal device 失败 / error 12 / 创建会话失败」"
fi
enc=$(printf '%s\n' "$LOG" | grep -acE 'OnEncodedFrameCallback|EncodeFrame' || true)
if [ "${enc:-0}" -gt 0 ]; then
  ok "出现编码回调痕迹 $enc 条 → 编码器在出码流"
else
  echo "○ 没有直接抓到编码回调行（UU 日志不一定打这些符号，按 §4 的码流判断更准）"
fi

hd "3. 被控端进程 CPU（补丁前：编码器建不起来时会反复重建，CPU 很高）"
PID=$(pgrep -f 'Contents/Helpers/UURemoteServer' | head -1 || true)
if [ -n "$PID" ]; then
  echo "  UURemoteServer pid=$PID"
  top -l 2 -s 1 -pid "$PID" -stats pid,cpu,mem,time 2>/dev/null | tail -3 | sed 's/^/  /'
else
  no "UURemoteServer 没在跑（UU 未启动？）"
fi

hd "4. 上行码流（有被控会话时）"
if command -v nettop >/dev/null 2>&1 && [ -n "$PID" ]; then
  nettop -P -l 2 -p "$PID" 2>/dev/null | tail -4 | sed 's/^/  /' || echo "  (nettop 无输出)"
else
  echo "  (跳过)"
fi

hd "判定"
echo "  ✔ 补丁齐 + 无 error 12 + 控制端能看到画面  → 修复成功"
echo "  ✘ 仍有 error 12                          → 进程没重启（旧代码）或补丁被覆盖，重跑 install"
echo "  ✘ UU 崩了/会话断开                        → 编码路径可能空指针解引用，把崩溃报告发我"
