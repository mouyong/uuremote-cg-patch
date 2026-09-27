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

# ---------- ③ reset 安全闸回归（feat-102）----------
# 为什么测试要**成对**：闸如果写成「永远拒绝」，那「在出帧时不杀」这条照样通过 —— 假绿。
# 所以必须同时证明「已经不出帧时确实会动手」。
# 全程用替身进程 + 临时日志，不碰真 helper；.active_pid 用 trap 保证还原。
echo "--- reset 安全闸回归（feat-102）---"
PIDF=/Users/Shared/UURemote/Shared/.active_pid
if [ -e "$PIDF" ] && [ -w "$PIDF" ]; then
  cp -p "$PIDF" /tmp/.uu-gate-pidbak
  gate_restore() { cp -p /tmp/.uu-gate-pidbak "$PIDF" 2>/dev/null || true; }
  trap gate_restore EXIT
  GLOG=/tmp/.uu-gate-fake.log

  # $1=期望退出码  $2=fresh|stale  $3=期望替身存活(1/0)  $4=说明  $5..=额外参数（如 --force）
  gate_case() {
    local want_rc="$1" log_kind="$2" want_alive="$3" what="$4" decoy rc alive
    shift 4   # ★ 必须把额外参数透传下去：漏了的话「--force 用例」其实跑的是无参数版本，
              #   用例照样「通过/失败」但测的不是它声称的东西（本用例第一版就栽在这）。
    decoy=$(python3 -c "import subprocess;p=subprocess.Popen(['sleep','60'],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);print(p.pid)")
    echo "$decoy" > "$PIDF"
    if [ "$log_kind" = "fresh" ]; then
      printf '%s  出帧 #1/9999  fmt=420v 1600x900 亮度=29.0 脏矩形=1 回调进2/出2 待回0 延迟0ms(峰1) 状态[1,0,0,0]\n' \
        "$(date +%H:%M:%S)" > "$GLOG"
    else
      printf '00:00:01  出帧 #1/9999  fmt=420v 1600x900 亮度=29.0 脏矩形=1 回调进2/出2 待回0 延迟0ms(峰1) 状态[1,0,0,0]\n' > "$GLOG"
    fi
    UU_SHIM_LOG="$GLOG" bash "$BASE/uu.sh" reset "$@" >/dev/null 2>/tmp/.uu-gate.err; rc=$?
    kill -0 "$decoy" 2>/dev/null && alive=1 || alive=0
    kill -TERM "$decoy" 2>/dev/null || true
    gate_restore
    # ★ 变量后紧跟全角标点必须写 ${var}：set -u 下 `$what：` 会被当成变量名
    #   `what：` → unbound variable，崩在报错信息处（正是最需要它说话的时候）。
    if   [ "$rc" != "$want_rc" ];        then bad "${what}：期望退出码 ${want_rc}，实际 ${rc}"
    elif [ "$alive" != "$want_alive" ];  then bad "${what}：替身存活=${alive}，期望 ${want_alive}"
    else pass "$what"; fi
  }

  gate_case 3 fresh 1 "在出帧时拒绝执行、不误杀（退出码 3）"
  gate_case 0 stale 0 "已停帧时照常重启（退出码 0，替身被终止）"
  gate_case 0 fresh 0 "--force 时绕过闸（退出码 0，替身被终止）" --force
else
  skip "无法写 ${PIDF}（缺权限）→ 跳过 reset 闸回归"
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

# ★ 先确认设备**在线**再开始观测。
#   为什么必须加：设备在线与否由 UURemoteServer 上报，而 server 刚被（重新）拉起、
#   或刚结束一场会话时，重新上报在线状态有**若干秒到十几秒的延迟**；这期间连接会
#   直接报 1010「设备当前离线」。实测踩过：测试恰好落在这个窗口里 → 报「连接失败 +
#   零出帧」，看着像补丁坏了，其实只是等一等的事（假红会把人骗去查错方向）。
#   所以：不在线就先等，等到上线再观测；等不到才真报红（那才是真故障）。
ONLINE_WAIT="${UU_TEST_ONLINE_WAIT:-90}"
device_online() {
  $SSH "$HOST" "$CLI device info ${DEV}" 2>/dev/null \
    | python3 -c "import sys,json
try: print(json.load(sys.stdin)['data']['matchedItem'].get('isOnline'))
except Exception: print('')" 2>/dev/null
}
if [ "$LOCAL_ONLY" = "0" ]; then
  ISON="$(device_online || true)"
  if [ "$ISON" != "True" ]; then
    echo "  设备当前不在线（isOnline=${ISON:-?}）→ 等它上报（最多 ${ONLINE_WAIT}s）"
    W=0
    while [ "$W" -lt "$ONLINE_WAIT" ]; do
      sleep 5; W=$((W + 5))
      ISON="$(device_online || true)"
      echo "    +${W}s  isOnline=${ISON:-?}"
      [ "$ISON" = "True" ] && break
    done
  fi
  if [ "$ISON" != "True" ]; then
    bad "设备始终未上线（等满 ${ONLINE_WAIT}s）→ 被控端不在线，连不上。先查：pgrep -x UURemoteServer"
    echo
    echo "结果: FAIL ✘ —— 设备离线（不是补丁问题；先让 server 跑起来）"
    exit 1
  fi
  pass "设备在线（isOnline=True）"
fi

# ★★ 判据用「本窗口内新产生的帧行数」，**不用**日志里的累计帧号。
#   为什么：累计帧号是 server 进程内的计数器，测试期间若 server 重启（装完 shim 就跑测试、
#   看门狗回收内存、失败会话让出槽位）它会从 1 重新数 —— 于是「9249 → 576」被误判成
#   「帧号回退」，而那其实是**测试口径**的问题，不是故障。实测踩过。
F0="$(last_frames || true)"
[ -z "${F0}" ] && F0=0
C0="$(grep -ac '出帧 #' "$SHIM_LOG" 2>/dev/null || echo 0)"
echo "  基线累计帧号: ${F0}（仅参照）；窗口判据基线: 日志内 ${C0} 条出帧行"

# 连接（后台起，随后轮询）
$SSH "$HOST" "$CLI device connect ${DEV}" >/tmp/uu_test_connect.out 2>&1 &
CONNECT_PID=$!

ELAPSED=0
while [ "$ELAPSED" -lt "$SECS" ]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  NEW=$(( $(grep -ac '出帧 #' "$SHIM_LOG" 2>/dev/null || echo 0) - C0 ))
  echo "  +${ELAPSED}s  帧号=$(last_frames || echo '?')  窗口内新增=${NEW}  亮度=$(last_lum || echo '?')"
done

F1="$(last_frames || true)"
C1="$(grep -ac '出帧 #' "$SHIM_LOG" 2>/dev/null || echo 0)"
PRODUCED=$((C1 - C0))
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
  # ★ 失败信息要指出**往哪查**：1010「设备当前离线」不是补丁问题，是 server 没跑/刚重启，
  #   两者处置完全不同（一个查 server，一个查采集器/编码器）。别让人从头猜。
  if grep -q '1010\|当前离线' /tmp/uu_test_connect.out 2>/dev/null; then
    bad "连接被拒：设备自报**离线**（错误 1010）→ 查被控端 server：pgrep -x UURemoteServer（应非空）"
  else
    bad "连接指令失败（见 /tmp/uu_test_connect.out）"
  fi
fi

# 帧数是否增长（判据见上：用窗口内新增行数，跨 server 重启依然成立）
if [ "${PRODUCED}" -gt 0 ] 2>/dev/null; then
  pass "窗口内出帧增长：+${PRODUCED} 帧（累计帧号 ${F0} → ${F1}；重启会归零，不影响本判据）"
else
  bad "窗口内零出帧（累计帧号停在 ${F1}）"
fi

# 亮度（黑帧最隐蔽，必须断言）
if [ -n "${LUM}" ] && awk "BEGIN{exit !(${LUM} > 1)}" 2>/dev/null; then
  pass "画面非黑（亮度 ${LUM}）"
else
  bad "亮度异常（${LUM:-空}）：可能是黑帧或没有画面"
fi

# 回调待回
# ★ 判据不能写「必须等于 0」：日志是一行一行刷的，采样那一瞬间**可能正有一个回调在执行**
#   （实测踩过：采样到「回调进192/出191 待回1」，同一会话的 stop 行却是
#   「回调进206/出206 待回0，回调排空=是」）—— 那条是**假红**，会让人去查一个不存在的毛病。
#   真故障长什么样：待回**持续增大**（回调卡住不再返回），或会话结束时报「回调排空=否」。
#   所以这里改成两条：① 在飞回调 ≤ 2（余量）；② 若窗口内出现 stop 行，其排空结论必须是「是」。
PEND_OK=1
if [ -n "${PEND}" ] && [ "${PEND}" -le 2 ] 2>/dev/null; then
  pass "回调无积压（待回 ${PEND}；≤2 视为在飞回调）"
else
  PEND_OK=0
  bad "回调积压（待回 ${PEND:-?}）→ 上层可能卡在回调里"
fi
DRAIN_LINE="$(grep -a '回调排空=' "$SHIM_LOG" 2>/dev/null | tail -1)"
if [ -n "$DRAIN_LINE" ]; then
  case "$DRAIN_LINE" in
    *回调排空=是*) pass "会话结束回调已排空（$(printf '%s' "$DRAIN_LINE" | sed -n 's/.*\(回调进[0-9]*\/出[0-9]*\).*/\1/p')）";;
    *) PEND_OK=0; bad "会话结束回调**未**排空 → 上层真的卡住了：$(printf '%s' "$DRAIN_LINE" | cut -c1-100)";;
  esac
fi
[ "$PEND_OK" = "1" ] || true   # 结果由 bad() 统一置 fail=1，这里无需额外记账

# ---------- ⑤ v15 变化检测是否在位（feat-114 的验收）----------
# 判据看**日志里的计数器**（唯一能证明「跑的是本仓库这版」的运行时证据）。
# 装的是旧版 shim → 日志里根本没有 `同帧=` 字段 → 这里必须报红，
# 否则「装了旧版却以为优化生效」这种假绿没人能发现。
echo
echo "--- v15 变化检测（feat-114）---"
GATE="$(grep -a '出帧 #' "$SHIM_LOG" 2>/dev/null | grep -a '同帧=' | tail -1)"
if [ -z "${GATE}" ]; then
  bad "已装 shim 无 v15 计数器（日志无 \`同帧=\`）—— 装的不是本仓库版本？重跑：sudo bash uu.sh shim-install"
else
  SAME_N="$(printf '%s' "$GATE" | sed -n 's/.*同帧=\([0-9]*\).*/\1/p')"
  ZERO_N="$(printf '%s' "$GATE" | sed -n 's/.*零矩形=\([0-9]*\).*/\1/p')"
  CUR_N="$(printf '%s' "$GATE" | sed -n 's/.*出帧 #[0-9]*\/\([0-9]*\).*/\1/p')"
  if [ "${SAME_N:-0}" -gt 0 ] 2>/dev/null && [ "${ZERO_N:-0}" -gt 0 ] 2>/dev/null; then
    PCT=$(awk "BEGIN{printf \"%.1f\", ${SAME_N}*100/${CUR_N}}")
    pass "静止帧被如实报告：判定没变化 ${SAME_N} 次 / 累计 ${CUR_N} 帧（跳过编码约 ${PCT}%），如实报 0 矩形 ${ZERO_N} 次"
  else
    skip "本轮未观测到「没变化」的帧（画面一直在变）—— 机制在位但这次没机会省；计数器：同帧=${SAME_N:-0} 零矩形=${ZERO_N:-0}"
  fi
  # 反向核对：零矩形 必须与 同帧 一致（判定没变化就应当如实报 0 个矩形）。
  #   不一致说明 GetRects 与帧判定脱节 —— 那正是「机制在白跑」的症状。
  if [ "${SAME_N:-0}" != "${ZERO_N:-0}" ]; then
    bad "计数器不一致（同帧=${SAME_N} 零矩形=${ZERO_N}）：判定与脏矩形报告脱节，机制没真正生效"
  fi
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
