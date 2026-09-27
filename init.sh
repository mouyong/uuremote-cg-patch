#!/bin/bash
# 本项目启动 / 验证入口（harness 的 verification 子系统）
#
# 做两件事：
#   ① 环境自检 —— 项目文件完整、脚本语法正确、依赖工具在位
#   ② 运行态自检 —— 补丁/注入/看门狗是否处在**正确配置**（不复现故障也能发现配置被改坏）
#
# 用法：./init.sh          （失败即退出，exit code != 0）
#
# ★ 本脚本只读，不改任何东西；需要动系统状态的验证见 AGENTS.md「验证命令」。
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE"

echo "=== UU远程补丁项目 Harness 初始化 ==="
echo "  目录: $BASE"
echo

fail=0
ok()   { echo "[OK]   $*"; }
bad()  { echo "[FAIL] $*"; fail=1; }
warn() { echo "[WARN] $*"; }

# ---------- ① 项目文件完整 ----------
echo "=== ① 项目文件完整性（缺一即断引用链）==="
for f in uu.sh patch_tool.py \
         orig.version UURemote.entitlements \
         shim/libuushim.c shim/libuushim.dylib \
         cpupath/libuucpupath.c cpupath/install.sh cpupath/uninstall.sh cpupath/status.sh \
         tools/setmode README.md test.sh; do
  if [ -e "${f}" ]; then ok "${f}"; else bad "${f} 缺失"; fi
done
# 原厂二进制备份：体积大且属第三方，**按设计不入仓库** → 首次 install / shim-install
# 会自动从官方 App 重建。故新克隆里没有它们是正常现象，不是缺陷（判 FAIL 会误报）。
for f in libstreamer.dylib.orig shim/backup/UURemoteServer.orig; do
  if [ -e "${f}" ]; then
    ok "${f}"
  else
    warn "${f} 尚不存在（原厂备份，按设计不入仓库；首次 install / shim-install 自动生成）"
  fi
done
# 证书（私钥不入 git，但本机必须存在）
for f in cert/cert.pem cert/key.pem cert/openssl.cnf; do
  if [ -e "$f" ]; then ok "$f"; else warn "$f 缺失（重签名会失败；见 README「第一步：生成你自己的签名证书」）"; fi
done

# ---------- ② 静态检查：脚本语法 ----------
echo
echo "=== ② 静态检查（shell 语法 = 本项目的 lint / compile）==="
for s in uu.sh init.sh cpupath/install.sh cpupath/uninstall.sh cpupath/status.sh; do
  [ -f "$s" ] || continue
  if bash -n "$s" 2>/dev/null; then ok "bash -n $s"; else bad "bash -n $s 语法错误"; fi
done
for p in patch_tool.py tools/cleanup.py tools/insert_dylib.py; do
  [ -f "$p" ] || continue
  if python3 -m py_compile "$p" 2>/dev/null; then ok "py_compile $p"; else bad "py_compile $p 失败"; fi
done
if [ -f shim/libuushim.c ]; then
  # 只做语法检查，不产出文件
  if clang -fsyntax-only shim/libuushim.c 2>/dev/null; then ok "clang -fsyntax-only shim/libuushim.c"; else warn "libuushim.c 语法检查未通过（依赖框架头文件时可能误报）"; fi
fi

# ---------- ③ 依赖工具在位 ----------
echo
echo "=== ③ 依赖工具 ==="
for t in git python3 clang otool codesign plutil; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t 不在 PATH"; fi
done

# ---------- ④ 运行态：补丁是否在位 ----------
echo
echo "=== ④ 运行态 · 补丁与注入（★ 最关键的配置项）==="
APP="/Applications/UURemote.app"

# 4.1 第 2 道门（shim）
SRV="$APP/Contents/Helpers/UURemoteServer"
DST="$APP/Contents/Frameworks/libuushim.dylib"
if [ -f "$DST" ]; then
  ok "shim 补丁库在位（$(stat -f '%z' "$DST") 字节）"
  if [ -f "$SRV" ] && otool -L "$SRV" 2>/dev/null | grep -qF libuushim; then
    ok "UURemoteServer 已注入 shim 依赖"
  else
    warn "UURemoteServer 未注入 shim（未装第 2 道门，或 UU 刚更新过 → 跑 sudo bash uu.sh install）"
  fi
else
  warn "shim 补丁库不在位（未安装本方案？见 README）"
fi

# 4.2 第 4 道门（cpupath）—— 注入方式必须精准
UU_PLIST="/Library/LaunchAgents/com.netease.uuremote.agent.plist"
if [ -f "$UU_PLIST" ] && sudo -n plutil -p "$UU_PLIST" 2>/dev/null | grep -q "libuucpupath"; then
  ok "cpupath 已精准注入 UU 的 LaunchAgent plist"
else
  warn "UU plist 里没有 cpupath 注入 → 无 Metal 的机器会黑屏（跑 bash cpupath/install.sh）"
fi

# 4.3 ★★ 全局注入必须为空（非空 = 正在伤害整个系统）
G="$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null || true)"
if [ -z "$G" ]; then
  ok "全局 DYLD_INSERT_LIBRARIES 为空（正确）"
else
  bad "全局 DYLD_INSERT_LIBRARIES 非空：[$G]"
  echo "         所有进程都会去加载未签名库 → 被 CODESIGNING 直接 SIGKILL"
  echo "         （实测一天 141 份系统进程崩溃报告 + 系统卡顿）"
  echo "         修复：launchctl unsetenv DYLD_INSERT_LIBRARIES && bash cpupath/install.sh"
fi

# ---------- ⑤ 运行态：看门狗 ----------
echo
echo "=== ⑤ 运行态 · 看门狗 ==="
LABEL="com.uuremote-cg-patch.watchdog"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  ok "LaunchAgent $LABEL 已加载（每 60 秒）"
else
  warn "$LABEL 未加载 → 无人值守时不会自愈（launchctl load -w ~/Library/LaunchAgents/$LABEL.plist）"
fi
WDPID="$(cat /tmp/.uu-wd-loop.pid 2>/dev/null || true)"
if [ -n "$WDPID" ] && kill -0 "$WDPID" 2>/dev/null; then
  ok "常驻循环在跑（pid=${WDPID}）"
else
  warn "常驻循环未在跑（bash uu.sh watchdog-loop 启动）"
fi
if [ -f uu.sh ]; then
  DRY="$(bash uu.sh watchdog --dry 2>&1 | head -3 || true)"
  echo "         看门狗自检: $DRY"
fi

# ---------- ⑥ 运行态：设备是否真的被云端认到 ----------
echo
echo "=== ⑥ 运行态 · 设备注册（进程在 ≠ 已上线）==="
CLI="$APP/Contents/Helpers/uuyc-cli"
if [ -x "$CLI" ]; then
  ST="$("$CLI" status 2>/dev/null || true)"
  if echo "$ST" | grep -q '"isLoggedIn" : true'; then ok "已登录"; else warn "未登录（打开 UU 应用登录）"; fi
  if echo "$ST" | grep -q '"networkStatus" : "connected"'; then ok "网络已连接"; else warn "网络未连接"; fi
else
  warn "找不到 uuyc-cli（未装 UU？）"
fi
# 出帧证据：看一眼 shim 日志最近有没有出帧（没人在连时无帧是正常的）
if [ -f /tmp/uushim.log ]; then
  LFT="$(grep -a '出帧 #' /tmp/uushim.log 2>/dev/null | tail -1 | cut -c1-8 || true)"
  [ -n "$LFT" ] && echo "         shim 最近出帧时间: ${LFT}（无会话时不刷新属正常）"
fi

# ---------- ⑦ 状态文件 ----------
echo
echo "=== ⑦ 状态文件（harness 的 state 子系统）==="
for f in AGENTS.md feature_list.json progress.md session-handoff.md; do
  if [ -f "$f" ]; then ok "$f"; else warn "$f 缺失（harness 不完整）"; fi
done
if [ -f feature_list.json ]; then
  if python3 -c "import json,sys; d=json.load(open('feature_list.json')); sys.exit(0 if isinstance(d.get('features'),list) else 1)" 2>/dev/null; then
    N=$(python3 -c "import json;print(len(json.load(open('feature_list.json'))['features']))")
    ok "feature_list.json 合法（$N 个工作项）"
    python3 - <<'PY' 2>/dev/null || true
import json
d = json.load(open("feature_list.json"))
from collections import Counter
c = Counter(f.get("status", "?") for f in d["features"])
print("         状态分布: " + ", ".join(f"{k}={v}" for k, v in c.items()))
act = [f for f in d["features"] if f.get("status") == "in-progress"]
if len(act) > 1:
    print(f"         [WARN] 有 {len(act)} 个工作项同时 in-progress（铁律：一次只做一个）")
    for f in act:
        print(f"                - {f.get('id')} {f.get('name')}")
PY
  else
    bad "feature_list.json 不合法（JSON 解析失败或缺 features 数组）"
  fi
fi

# ---------- ⑧ git ----------
echo
echo "=== ⑧ git 状态 ==="
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "         分支: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "         最近提交:"
  git log --oneline -3 2>/dev/null | sed 's/^/           /'
  DIRTY="$(git status --short | wc -l | tr -d ' ')"
  if [ "$DIRTY" = "0" ]; then ok "工作区干净"; else warn "工作区有 $DIRTY 处未提交改动"; fi
  # 私钥绝不能进版本库。
  # ★ 按**内容**判定，不按扩展名：公开证书（cert.pem 是 BEGIN CERTIFICATE）可以入库，
  #   扩展名匹配会把它误报成私钥（实测踩过）。内容匹配同时能抓住「改了名的私钥」。
  LEAK=""
  # ★ 用 -z 读文件名：git 默认把非 ASCII 名转义成 \346\240... 形式，
  #   用 $(git ls-files) 遍历会**静默跳过所有中文名文件**
  #   （实测：44 个跟踪文件里实际只扫到 37 个）。门禁漏扫比没有门禁更危险。
  while IFS= read -r -d '' f; do
    [ -f "${f}" ] || continue
    case "${f}" in
      *.p12|*.pfx|*.key) LEAK="${LEAK} ${f}"; continue ;;
    esac
    # 按**内容**判定，不设扩展名白名单 —— 否则「私钥被贴进 README/.sh/.md」会漏网
    if grep -qE 'BEGIN [A-Z ]*PRIVATE KEY' "${f}" 2>/dev/null; then LEAK="${LEAK} ${f}"; fi
  done < <(git ls-files -z)
  if [ -n "$LEAK" ]; then
    bad "版本库里跟踪了私钥：${LEAK}（违反铁律，见 AGENTS.md）"
  else
    ok "版本库无私钥（公开证书不算，已按内容判定）"
  fi
else
  warn "未初始化 git"
fi

# ---------- 结果 ----------
echo
echo "=== 验证完成 ==="
if [ "$fail" != "0" ]; then
  echo "结果: ✘ 有 FAIL 项（见上）。修好再开始新工作。"
  exit 1
fi
echo "结果: ✔ 全部通过（WARN 属可选/未安装项，不阻断）"
echo
echo "Next steps:"
echo "1. 读 feature_list.json 看当前工作项状态"
echo "2. 只挑 ONE 未完成工作项（铁律：一次只做一个）"
echo "3. 只改该工作项相关的文件（Stay in scope）"
echo "4. 声称完成前必须重跑本脚本 + 该工作项的验收命令"
echo "5. 收尾更新 progress.md / feature_list.json，并保证仓库可 clean 重启"
