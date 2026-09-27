#!/bin/bash
# test.sh — 端到端验收测试
#
# 本项目没有单元测试框架（它是个补丁工具集，不是库）。它的「测试」就是
# **真连一次被控端，断言画面真的出来了** —— 这正是每次改完补丁要做的验收，
# 之前一直靠手工敲，现在固化成脚本。
#
# 断言（全部满足才 PASS）：
#   ① 连接成功，且对端报告设备 online
#   ② shim 累计帧号增长 ≥ 1（真的在出帧）
#   ③ 亮度 > 1（抓到的是画面不是黑帧）
#   ④ 无 `!!` 级异常（分配失败 / 无缓冲 / 槽位超限）
#   ⑤ 回调待回为 0（没有卡在回调里）
#
# ★★ 安全设计：**若发现已有活动连接（有人正在用），直接 SKIP 退出，绝不打扰** ——
#    与本项目看门狗同一条铁律：还在出帧就绝不动它。
#
# 用法：
#   ./test.sh                  # 默认：连 Air 上的 CLI 来测本机
#   UU_TEST_SECS=30 ./test.sh  # 加长观测窗口
#   ./test.sh --local-only     # 不依赖外部控制器，只做本机静态+日志断言
#
# 可用环境变量覆盖：
#   UU_TEST_HOST   控制器 SSH 目标（形如 user@host；不设则跳过端到端）
#   UU_TEST_DEVICE 被控端设备 ID
#   UU_TEST_SECS   观测窗口秒数（默认 20）
set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE"

# ★ 真实取值放在 .uutest.local（已 gitignore，不随仓库分发；实际信息不进 git 历史）。
#   内容形如：  UU_TEST_HOST='<你的控制器 SSH 目标>'
#              UU_TEST_DEVICE='<被控端设备 ID>'
#   也可不改文件、直接用环境变量传入。
[ -f "${BASE}/.uutest.local" ] && . "${BASE}/.uutest.local"

HOST="${UU_TEST_HOST:-}"
DEV="${UU_TEST_DEVICE:-}"
SECS="${UU_TEST_SECS:-20}"
CLI="/Applications/UURemote.app/Contents/Helpers/uuyc-cli"
SHIM_LOG="${UU_SHIM_LOG:-/tmp/uushim.log}"
LOCAL_ONLY=0
[ "${1:-}" = "--local-only" ] && LOCAL_ONLY=1

SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
fail=0
pass() { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; fail=1; }
skip() { echo "  [SKIP] $*"; }

echo "=== 端到端验收测试 ==="
echo "  控制器: ${HOST}"
echo "  设备 ID: ${DEV}"
echo

# ---------- 取证小工具 ----------
# 最后一行出帧记录的「累计帧号」与「亮度」。日志格式：
#   出帧 #<本会话帧序>/<进程累计帧号>  fmt=420v 1600x900 亮度=29.0 ...
last_frames() {
  grep -a '出帧 #' "$SHIM_LOG" 2>/dev/null | tail -1 \
    | sed -n 's/.*#[0-9]*\/\([0-9]*\).*/\1/p'
}
last_lum() {
  grep -a '出帧 #' "$SHIM_LOG" 2>/dev/null | tail -1 \
    | sed -n 's/.*亮度=\([0-9.]*\).*/\1/p'
}
last_pend() {
  grep -a '出帧 #' "$SHIM_LOG" 2>/dev/null | tail -1 \
    | sed -n 's/.*待回\([0-9]*\).*/\1/p'
}

if [ ! -f "$SHIM_LOG" ]; then
  echo "  [FAIL] 找不到 shim 日志 ${SHIM_LOG}（补丁没装？先跑 ./init.sh）"
  exit 1
fi

# ---------- ① 安全闸：有人正在用就不打扰 ----------
if [ "$LOCAL_ONLY" = "0" ] && command -v ssh >/dev/null 2>&1; then
  CONN="$($SSH "$HOST" "$CLI device status" 2>/dev/null | sed -n 's/.*"total" *: *\([0-9]*\).*/\1/p' | head -1 || true)"
  if [ -n "${CONN}" ] && [ "${CONN}" -gt 0 ] 2>/dev/null; then
    skip "当前有 ${CONN} 个活动连接（有人正在用）→ 不打扰，测试跳过"
    echo
    echo "结果: SKIP（未打扰正在使用的会话）"
    exit 0
  fi
fi

# ---------- ② 本地静态断言 ----------
echo "--- 本地静态断言 ---"
if launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null | grep -q .; then
  bad "全局 DYLD_INSERT_LIBRARIES 非空（正在伤害系统，见 AGENTS.md 铁律 1）"
else
  pass "全局注入变量为空"
fi
if [ -x "$CLI" ]; then
  if "$CLI" status 2>/dev/null | grep -q '"isLoggedIn" : true'; then
    pass "本机 UU 已登录"
  else
    bad "本机 UU 未登录"
  fi
else
  echo "  [SKIP] 本机没有 uuyc-cli（未装 UU？）"
fi

if [ "$LOCAL_ONLY" = "1" ]; then
  echo
  echo "--- --local-only：跳过端到端 ---"
  [ "$fail" = "0" ] && echo "结果: PASS（仅静态断言）" || echo "结果: FAIL"
  exit "$fail"
fi

# ---------- ③ 配置闸：没配控制器就跳过端到端 ----------
if [ -z "${HOST}" ] || [ -z "${DEV}" ]; then
  skip "未配置控制器（.uutest.local 里的 UU_TEST_HOST / UU_TEST_DEVICE，或同名环境变量）"
  skip "→ 跳过端到端断言；静态断言结果见上"
  echo
  [ "${fail}" = "0" ] && echo "结果: PASS（仅静态断言）" || echo "结果: FAIL（静态断言未过）"
  exit "${fail}"
fi

# ---------- ③ 控制器可达性 ----------
echo
echo "--- 控制器连通性 ---"
if ! $SSH "$HOST" "true" 2>/dev/null; then
  skip "无法 SSH 到 ${HOST} → 端到端测试跳过（设 UU_TEST_HOST 可改目标）"
  echo
  echo "结果: SKIP（控制器不可达）"
  exit 0
fi
pass "SSH 到 ${HOST} 可达"

# ---------- ④ 端到端 ----------
echo
echo "--- 端到端（观测 ${SECS} 秒）---"
F0="$(last_frames || true)"
[ -z "${F0}" ] && F0=0
echo "  基线累计帧号: ${F0}"

# 连接（后台起，随后轮询）
$SSH "$HOST" "$CLI device connect ${DEV}" >/tmp/uu_test_connect.out 2>&1 &
CONNECT_PID=$!

ELAPSED=0
while [ "$ELAPSED" -lt "$SECS" ]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  echo "  +${ELAPSED}s  帧号=$(last_frames || echo '?')  亮度=$(last_lum || echo '?')"
done

F1="$(last_frames || true)"
LUM="$(last_lum || true)"
PEND="$(last_pend || true)"
[ -z "${F1}" ] && F1=0

# 断开并收尾
$SSH "$HOST" "$CLI device disconnect ${DEV}" >/tmp/uu_test_disconnect.out 2>&1 || true
kill "$CONNECT_PID" 2>/dev/null || true
wait "$CONNECT_PID" 2>/dev/null || true

# 连接本身是否成功
if grep -q '"success" *: *true' /tmp/uu_test_connect.out 2>/dev/null \
   || grep -q '已连接\|connected' /tmp/uu_test_connect.out 2>/dev/null; then
  pass "连接指令被接受"
else
  bad "连接指令失败（见 /tmp/uu_test_connect.out）"
fi

# 帧数是否增长
if [ "${F1}" -gt "${F0}" ] 2>/dev/null; then
  pass "出帧增长：${F0} → ${F1}（+$((F1 - F0))）"
elif [ "${F1}" -lt "${F0}" ] 2>/dev/null; then
  bad "帧号回退（${F0} → ${F1}）：测试期间 server 被重启过（看门狗？）—— 排除干扰后重测"
else
  bad "测试期间零出帧（帧号停在 ${F1}）"
fi

# 亮度（黑帧最隐蔽，必须断言）
if [ -n "${LUM}" ] && awk "BEGIN{exit !(${LUM} > 1)}" 2>/dev/null; then
  pass "画面非黑（亮度 ${LUM}）"
else
  bad "亮度异常（${LUM:-空}）：可能是黑帧或没有画面"
fi

# 回调待回
if [ -n "${PEND}" ] && [ "${PEND}" = "0" ]; then
  pass "回调无积压（待回 0）"
else
  bad "回调积压（待回 ${PEND:-?}）→ 上层可能卡在回调里"
fi

# 本次窗口内的异常行
BADLINES="$(tail -200 "$SHIM_LOG" 2>/dev/null | grep -acE '!!|分配失败|无可用缓冲|流数超上限' || true)"
if [ "${BADLINES}" = "0" ]; then
  pass "窗口内无异常行"
else
  bad "窗口内有 ${BADLINES} 条异常行："
  tail -200 "$SHIM_LOG" | grep -aE '!!|分配失败|无可用缓冲|流数超上限' | tail -3 | sed 's/^/           /'
fi

# ---------- 结果 ----------
echo
if [ "$fail" = "0" ]; then
  echo "结果: PASS ✔ —— 端到端可用（证据见上面每行 [PASS]）"
else
  echo "结果: FAIL ✘ —— 见上面 [FAIL] 行；日志：${SHIM_LOG} / /tmp/uu_test_*.out"
fi
exit "$fail"
