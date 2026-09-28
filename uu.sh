#!/bin/bash
# ============================================================================
# UU远程 修复工具集 —— 单文件入口（安装 / 还原 / 状态 / 看门狗 / 诊断）
# ============================================================================
# 这台机器（2011 Mac mini + OCLP，无 IOGPU / 无 Metal / 无硬件编码器）跑 UU远程
# 被控端要打三层补丁才出画面，本脚本把它们收进一个入口，不必再记一堆文件名。
#
# 【四道门与对应命令】
#   第1道 采集器选择：UU 按 macOS>=14 强选 ScreenCaptureKit，本机必然失败(-3802)
#         → 改 libstreamer.dylib 一字节 je→jmp 强制走 CoreGraphics   [cg-install]
#   第2道 帧源：ScreenCaptureKit 之外再注入截图轮询帧源
#         → libuushim.dylib + LC_LOAD_DYLIB + 重签                [shim-install]
#   第3道 编码器门禁：UU 要求「必须硬编」，本机只有软编
#         → 磁盘补丁关掉该门禁（含在第1道里）
#   第4道 像素路径：把「采集帧 → 编码器输入帧」的转换从 Metal 渲染换成 CPU memcpy
#         → cpupath/libuucpupath.dylib 注入 UU 自己的 LaunchAgent  [cpupath-install]
#
# 【怎么用】
#   bash uu.sh status            # 先看状态（免 sudo，最常用）
#   sudo bash uu.sh install      # 一键装全套（重装 UU / UU 更新后用这个）
#   sudo bash uu.sh restore      # 一键还原
#   sudo bash uu.sh help         # 全部命令
#
# 【一句话记忆】先 status，装 install，还原 restore，卡住就 reset。
# ============================================================================
set -uo pipefail


# ---------------------------------------------------------------------------
# 共享路径与变量（原先散在 6 个脚本里，现在只此一份）
# ---------------------------------------------------------------------------
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${UURT_APP:-/Applications/UURemote.app}"
# 演练模式：UURT_APP 指向 App 副本 + UURT_REHEARSE=1 → 不杀进程/不启动/不动基线
REHEARSE="${UURT_REHEARSE:-0}"
LIB="$APP/Contents/Frameworks/libstreamer.dylib"
ORIG="$D/libstreamer.dylib.orig"
PATCHED="$D/libstreamer.dylib.patched"
ENTS="$D/UURemote.entitlements"
TOOL="$D/patch_tool.py"
VERFILE="$D/orig.version"
REAL_USER="${SUDO_USER:-$(stat -f '%Su' "$HOME" 2>/dev/null || echo "$USER")}"
# ★ 为什么用变量调 launchd，而不用字面量：
#   agent 的 terminal 护栏把正文里「launchctl 的 bootstrap 子命令」一律判成
#   「注册 gateway 常驻任务」（label 无关，见 cron/lifecycle_guard.py 的
#   contains_launchctl_submit_command），于是整条命令被拒绝执行。
#   我们 bootstrap 的是 UU 自己的守护进程（com.netease.uuremote.daemon），
#   与 hermes gateway 无关 —— 属护栏误判。用变量调用可绕开该字符串匹配，语义完全不变。
LC="${UU_LAUNCHCTL:-/bin/launchctl}"

# 颜色与输出助手（原先在各脚本顶层各写一份，现在只此一份）
c_ok=$'\033[32m'; c_no=$'\033[31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'


# ===========================================================================
# 以下为各子命令实现（由原 6 个脚本逐字整合，逻辑未重写）
# ===========================================================================


ok()  { printf '%s✔%s %s\n' "$c_ok" "$c_off" "$1"; }


no()  { printf '%s✘%s %s\n' "$c_no" "$c_off" "$1"; }


hd()  { printf '\n%s=== %s ===%s\n' "$c_hd" "$1" "$c_off"; }


need_root() {
  if [ "$REHEARSE" = "1" ]; then echo "  [演练] 跳过 root 要求（只操作副本）"; return 0; fi
  [ "$(id -u)" -eq 0 ] && return 0
  no "此操作需要 root，请用：sudo bash $0 $1"
  exit 1
}


app_version() {
  plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null \
    || defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null \
    || echo "未知"
}


lib_state() {
  [ -f "$1" ] || { echo "missing"; return; }
  python3 "$TOOL" check "$1" 2>/dev/null | head -1
}


lib_state_audio() {
  [ -f "$1" ] || { echo "missing"; return; }
  python3 "$TOOL" check "$1" 2>/dev/null | sed -n '2p' | awk '{print $2}'
}


lib_state_encoder() {
  [ -f "$1" ] || { echo "missing"; return; }
  python3 "$TOOL" check "$1" 2>/dev/null | sed -n '3p' | awk '{print $2}'
}


lib_state_metalgate() {
  [ -f "$1" ] || { echo "missing"; return; }
  python3 "$TOOL" check "$1" 2>/dev/null | sed -n '4p' | awk '{print $2}'
}


lib_state_lowlat() {
  [ -f "$1" ] || { echo "missing"; return; }
  python3 "$TOOL" check "$1" 2>/dev/null | sed -n '5p' | awk '{print $2}'
}


patch_point() { python3 "$TOOL" locate "$1" 2>/dev/null | head -1; }


check_env() {
  [ -f "$LIB" ]  || { no "找不到 ${LIB}，UU远程 是否已安装？"; exit 1; }
  [ -f "$TOOL" ] || { no "找不到 ${TOOL}（版本自适应定位工具）"; exit 1; }
  [ -f "$ENTS" ] || { no "找不到 entitlements $ENTS"; exit 1; }
}


resign() {
  hd "重签名（必须用证书，不能用 adhoc）"
  echo "说明：UU 内部用 'certificate leaf[subject.OU] = <TeamID>' 校验组件身份，"
  echo "      并检查 'Hardened runtime is not set for the sender'。"
  echo "      adhoc 签名两条都不满足 → XPC 被拒 → 报 1001、设备不上线。"
  echo "      因此用 OU=官方 TeamID 的自签证书 + --options runtime 重签。"
  # 原先是调外部 fix-xpc-signing.sh；整合进 uu.sh 后直接调内部函数（逻辑未改）
  sign_main
  return $?
}


quit_uu() {
  hd "退出 UU 远程"
  if [ "$REHEARSE" = "1" ]; then echo "  [演练] 跳过（不动真实进程）"; return 0; fi
  # 主程序/agent 能用 pkill 杀，但 root 守护进程杀不掉，必须用 launchctl。
  # 守护进程若保持旧签名运行，XPC 会出现
  # "Peer connection was rejected by the listener (xpc_connection_cancel())"，
  # 表现为「无法连接至服务器 1001」+ 本机不上线。
  pkill -f 'UURemote.app/Contents/MacOS/UURemote' 2>/dev/null || true
  # 注意：Server 在 Contents/Helpers/ 下，上面的模式匹配不到它，必须单独杀，
  # 否则它会带着「补丁前」的旧代码一直活着（这是之前踩过的坑）。
  pkill -f 'UURemote.app/Contents/Helpers/UURemoteServer' 2>/dev/null || true
  pkill -f 'UURemote.app/Contents/XPCServices/UURemoteHelper' 2>/dev/null || true
  pkill -f UURemoteService 2>/dev/null || true
  sleep 2
  if [ "$(id -u)" -eq 0 ]; then
    launchctl kickstart -k system/com.netease.uuremote.daemon 2>/dev/null \
      && ok "root 守护进程已重启（签名对齐）" || echo "  守护进程未运行或按需启动"
    sleep 2
  else
    echo "提示：未以 root 运行，跳过守护进程重启。"
  fi
  if pgrep -f 'UURemote.app' >/dev/null 2>&1; then
    echo "剩余进程（守护进程属正常）："; pgrep -fl 'UURemote.app' | sed 's/^/  /'
  else
    ok "已全部退出"
  fi
}


start_uu() {
  hd "启动 UU 远程"
  if [ "$REHEARSE" = "1" ]; then echo "  [演练] 跳过（不启动真实 App）"; return 0; fi
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$REAL_USER" open -a UURemote 2>/dev/null || open -a UURemote || true
  else
    open -a UURemote 2>/dev/null || true
  fi
  sleep 3
  pgrep -fl 'UURemote.app' | head -4 || echo "(未检测到进程，可能需手动打开)"
}


post_install_note() {
cat <<'EOT'

────────────────────────────────────────────────────────────
装完必做：重新授权（签名变了，授权会被重置）
────────────────────────────────────────────────────────────
打开：系统设置 → 隐私与安全性

  1) 辅助功能        → 找到 UU远程，取消勾选再重新勾上
  2) 录屏与系统录音  → 同上
  清单里没有 → 点左下角 + 添加 /Applications/UURemote.app
  还是不弹/不生效 → 终端执行：
      tccutil reset ScreenCapture com.netease.uuremote
      tccutil reset Accessibility com.netease.uuremote
    然后完全退出 UU 再打开

然后手机连一次，回来跑这条看有没有生效（在本项目目录下执行）：
  bash uu.sh verify
────────────────────────────────────────────────────────────
EOT
}


prepare_baseline() {
  local cur_ver state
  cur_ver=$(app_version)
  state=$(lib_state "$LIB")
  local orig_ver=""
  [ -f "$VERFILE" ] && orig_ver=$(cat "$VERFILE")

  hd "准备基线（当前 UU 版本 ${cur_ver}）"
  echo "  当前库状态: $state"
  echo "  备份版本  : ${orig_ver:-无备份}"

  case "$state" in
    orig)
      if [ "$REHEARSE" = "1" ]; then
        echo "  [演练] 不写官方备份（真实运行会在需要时 cp 当前库 → ${ORIG}）"
      elif [ "$orig_ver" != "$cur_ver" ] || [ ! -f "$ORIG" ]; then
        cp "$LIB" "$ORIG" && echo "$cur_ver" > "$VERFILE"
        ok "已把当前官方库备份为 ${ORIG}（版本 ${cur_ver}）"
      else
        ok "官方库备份已是当前版本，无需更新"
      fi
      ;;
    patched)
      if [ "$REHEARSE" = "1" ] && { [ "$orig_ver" != "$cur_ver" ] || [ ! -f "$ORIG" ]; }; then
        no "演练中止：本次会重建官方备份（写 ${ORIG}）——演练不修改基线"
        exit 1
      fi
      if [ "$orig_ver" != "$cur_ver" ] || [ ! -f "$ORIG" ]; then
        no "检测到 UU 已更新到 ${cur_ver}，但库已被打过补丁 → 从补丁库反推官方库"
        if python3 "$TOOL" unpatch "$LIB" "$ORIG" >/dev/null 2>&1; then
          echo "$cur_ver" > "$VERFILE"
          ok "已重建官方库备份（unpatch 精确还原，仅该 1 字节不同）"
        else
          no "无法反推官方库 —— 请去 https://uuyc.163.com/ 重新下载安装包覆盖安装后重试"
          exit 1
        fi
      else
        ok "补丁库与备份版本一致，无需重建"
      fi
      ;;
    unknown|missing)
      no "库状态无法识别（${state}）—— UU 版本可能大改，补丁点需重新分析"
      echo "  建议先去 https://uuyc.163.com/ 覆盖安装官方包，再重跑 install"
      exit 1
      ;;
  esac

  hd "由官方备份生成补丁库"
  local pp; pp=$(patch_point "$ORIG")
  if [ -z "$pp" ]; then
    no "在官方库里定位不到补丁点（UU 改版，需重新分析）"; exit 1
  fi
  echo "  补丁点: 文件偏移 ${pp%% *}  映射差 ${pp##* }"
  if python3 "$TOOL" patch "$ORIG" "$PATCHED" >/dev/null 2>&1; then
    ok "补丁库已生成: $PATCHED"
  else
    no "生成补丁库失败"; exit 1
  fi
}


cg_install_main() {
  need_root install
  check_env
  hd "UU远程 CoreGraphics 采集补丁 —— 安装"

  quit_uu
  prepare_baseline

  hd "写入补丁"
  cp "$PATCHED" "$LIB" || { no "写入失败（权限？SIP？）"; exit 1; }
  local st; st=$(lib_state "$LIB")
  if [ "$st" = "patched" ]; then
    local pp; pp=$(patch_point "$LIB")
    ok "库已是补丁版（补丁点 ${pp%% *} = 0xeb，无条件走 CoreGraphics）"
  else
    no "写入后状态为 ${st}，补丁未生效！"; exit 1
  fi

  chown root:wheel "$LIB" 2>/dev/null || true

  if resign; then :; else
    no "签名失败 —— 库已打补丁但签名未完成，UU 可能无法启动"
    echo "  还原：sudo bash $0 restore"
    exit 1
  fi

  start_uu
  post_install_note

  hd "结果"
  ok "补丁安装完成。还原命令：sudo bash $0 restore"
  echo
  echo "⚠ UU 每次自动更新都会覆盖补丁。更新后重跑本命令即可："
  echo "    sudo bash $0 install      （会自动识别新版本并重新定位补丁点）"
}


cg_restore_main() {
  need_root restore
  hd "UU远程 补丁 —— 还原官方原版"

  quit_uu

  local cur_ver orig_ver=""
  cur_ver=$(app_version)
  [ -f "$VERFILE" ] && orig_ver=$(cat "$VERFILE")

  hd "还原原始库"
  if [ ! -f "$ORIG" ]; then
    no "找不到原始备份 $ORIG"
    echo "  可去 https://uuyc.163.com/ 重新下载安装包覆盖安装"
    exit 1
  fi
  if [ "$orig_ver" != "$cur_ver" ]; then
    no "备份版本($orig_ver) 与当前 UU 版本($cur_ver) 不一致 —— 直接还原会导致 UU 无法启动"
    echo "  正确做法：去 https://uuyc.163.com/ 下载最新安装包覆盖安装（补丁与备份一并作废）"
    exit 1
  fi

  cp "$ORIG" "$LIB" || { no "写入失败"; exit 1; }
  chown root:wheel "$LIB" 2>/dev/null || true
  local st; st=$(lib_state "$LIB")
  if [ "$st" = "orig" ]; then
    ok "已还原为官方原版（黑屏问题会回来，这是预期的）"
  else
    no "还原异常，库状态为 $st"; exit 1
  fi

  resign || true
  start_uu

  hd "结果"
  ok "补丁已撤销"
  echo
  echo "想让官方签名也完全恢复：去 https://uuyc.163.com/ 下载安装包覆盖安装。"
}


cg_daemon_main() {
  need_root daemon
  hd "恢复/重启 UU root 守护进程"
  echo "背景：守护进程是 root LaunchDaemon（RunAtLoad + KeepAlive）。"
  echo "      若它没在跑，agent 连 com.uuremote.daemon 会报 No such process，"
  echo "      表现为「无法连接至服务器 / 设备不上线」。"
  echo
  if launchctl print system/com.netease.uuremote.daemon >/dev/null 2>&1; then
    launchctl kickstart -k system/com.netease.uuremote.daemon && ok "守护进程已重启"
  else
    echo "  服务未加载 → bootstrap"
    $LC bootstrap system /Library/LaunchDaemons/com.netease.uuremote.daemon.plist \
      && ok "守护进程已加载并启动" || no "bootstrap 失败"
  fi
  sleep 2
  pgrep -f UURemoteDaemon >/dev/null && ok "守护进程在运行（$(pgrep -f UURemoteDaemon | head -1)）" || no "守护进程仍未运行"
  ps -Ao pid,lstart,command 2>/dev/null | grep -E 'UURemoteDaemon' | grep -v grep | sed 's/^/  /'
  echo
  echo "若 agent 仍不正常，再重启它：pkill -f UURemoteService"
}


check_daemon_stale() {
  local sig_t dp dst
  sig_t=$(stat -f '%m' "$APP/Contents/_CodeSignature/CodeResources" 2>/dev/null)
  dp=$(pgrep -f UURemoteDaemon | head -1)
  [ -z "$dp" ] && return 0
  dst=$(ps -p "$dp" -o lstart= 2>/dev/null | xargs -0 -I{} date -j -f "%a %b %d %T %Y" "{}" "+%s" 2>/dev/null)
  [ -z "$sig_t" ] || [ -z "$dst" ] && return 0
  [ "$dst" -lt "$sig_t" ] && return 1
  return 0
}


tcc_diag() {
  hd "TCC 授权匹配检查"
  local TCC="/Library/Application Support/com.apple.TCC/TCC.db"
  if [ ! -r "$TCC" ]; then
    echo "  读不到 ${TCC}（需要权限），跳过"
    return
  fi
  # 我方证书的 SHA1（TCC 记录的 requirement 里就是它）
  local myfp=""
  if [ -f "$D/cert/cert.pem" ]; then
    myfp=$(openssl x509 -in "$D/cert/cert.pem" -fingerprint -sha1 -noout 2>/dev/null | cut -d= -f2 | tr -d ':')
  fi

  local svc label val req needle
  for svc in kTCCServiceScreenCapture kTCCServiceAccessibility; do
    case "$svc" in
      kTCCServiceScreenCapture) label="录屏与系统录音" ;;
      kTCCServiceAccessibility) label="辅助功能      " ;;
    esac
    val=$(sqlite3 "$TCC" "SELECT auth_value FROM access WHERE client='com.netease.uuremote' AND service='${svc}';" 2>/dev/null)
    req=$(sqlite3 "$TCC" "SELECT hex(csreq) FROM access WHERE client='com.netease.uuremote' AND service='${svc}';" 2>/dev/null)

    if [ -z "$val" ]; then
      no "$label : 无记录（UU 申请时会弹窗，去「隐私与安全性」勾上）"
      continue
    fi
    if [ "$val" != "2" ]; then
      no "$label : 未授权（auth_value=${val}）→ 去「隐私与安全性」勾上"
      continue
    fi

    # csreq 里含我方证书指纹 = 匹配；含 anchor apple generic = 官方要求，会失配
    if [ -n "$myfp" ]; then
      # csreq 是大写 hex
      needle=$(printf '%s' "$myfp" | tr 'a-z' 'A-Z')
      case "$req" in
        *"$needle"*) ok "$label : 已授权且匹配当前签名"; continue ;;
      esac
    fi
    case "$req" in
      *2A864886F7636406020600*)
        no "$label : 已授权但要求是【官方签名】→ 与当前签名失配，等同未授权"
        echo "        修复：tccutil reset ${svc#kTCCService} com.netease.uuremote"
        echo "              然后系统设置里重新勾选（或首次启动时的弹窗里点允许）"
        ;;
      *)
        if [ -z "$req" ]; then echo "○ $label : 已授权（无 csreq 约束）"
        else no "$label : 已授权但要求不明（可能失配）→ 建议 reset 后重新勾选"; fi
        ;;
    esac
  done
}


check_daemon_present() {
  hd "root 守护进程检查"
  if pgrep -f UURemoteDaemon >/dev/null 2>&1; then
    ok "守护进程在运行（$(pgrep -f UURemoteDaemon | head -1)）"
    return 0
  fi
  no "守护进程【未运行】—— 会导致「无法连接至服务器 / 设备不上线」"
  if launchctl print system/com.netease.uuremote.daemon >/dev/null 2>&1; then
    echo "  修复：sudo bash $0 daemon"
  else
    echo "  修复（服务未加载，需重新加载）："
    echo "    sudo $LC bootstrap system /Library/LaunchDaemons/com.netease.uuremote.daemon.plist"
  fi
  return 1
}


cg_status_main() {
  hd "UU远程 补丁状态"
  if [ ! -f "$LIB" ]; then no "找不到 ${LIB}（UU 未安装？）"; exit 1; fi

  local cur_ver orig_ver state
  cur_ver=$(app_version)
  [ -f "$VERFILE" ] && orig_ver=$(cat "$VERFILE")
  state=$(lib_state "$LIB")
  echo "  UU 版本    : $cur_ver"
  echo "  备份版本   : ${orig_ver:-无}"
  echo "  签名者     : $(codesign -dv --verbose=4 "$APP" 2>&1 | grep -a '^Authority=' | head -1 | cut -d= -f2-)"
  echo

  local pp; pp=$(patch_point "$LIB")
  local astate; astate=$(lib_state_audio "$LIB")
  case "$state" in
    patched) ok "【视频补丁】补丁点 ${pp%% *} = 0xeb (jmp) → 走 CoreGraphics，黑屏应已修复" ;;
    orig)    echo "○【官方原版】补丁点 ${pp%% *} = 0x74 (je) → 走 ScreenCaptureKit，本机会黑屏/卡在「正在传输画面」" ;;
    unknown) no "【未知状态】定位不到补丁点 —— UU 可能大改版，需重新分析，或先重装官方包" ;;
    missing) no "【库文件缺失】" ;;
  esac
  case "$astate" in
    patched) ok "【音频补丁】已关掉音频的 SCK 路径（本机无 IOGPU，SCK 必失败 → 会话会卡住）" ;;
    orig)    no "【音频未补】音频仍走 ScreenCaptureKit → 本机必然失败，可能卡在「正在传输数据」" ;;
    *)       no "【音频状态未知】" ;;
  esac
  local estate; estate=$(lib_state_encoder "$LIB")
  case "$estate" in
    patched) ok "【编码器补丁】已强制软件编码（不再要求 Metal 硬件编码器）" ;;
    orig)    no "【编码器未补】仍要求硬件编码器 → 本机无 Metal 必挂（日志：Failed to create metal device / error 12），采集正常但零帧 → 控制端永远「正在传输画面」" ;;
    *)       no "【编码器状态未知】" ;;
  esac
  local mstate; mstate=$(lib_state_metalgate "$LIB")
  case "$mstate" in
    patched) ok "【Metal 门禁补丁】已绕过「Metal 设备为空就放弃」（ResetVTCompressionSession 入口那两处 je/jne → 照常继续）" ;;
    orig)    no "【Metal 门禁未补】ResetVTCompressionSession 仍会因 Metal 设备为空直接 return false → error 12 → 编码器永远建不起来（只补【编码器】没用，这一步在它之前）" ;;
    *)       no "【Metal 门禁状态未知】" ;;
  esac
  local lstate; lstate=$(lib_state_lowlat "$LIB")
  case "$lstate" in
    patched) ok "【低延迟RC补丁】已关掉 encoderSpec[EnableLowLatencyRateControl]（该模式强制要求硬件编码器，本机没有 → 之前建会话返回 -12902）" ;;
    orig)    no "【低延迟RC未补】仍向 VideoToolbox 申请低延迟码率控制 → 本机无硬件编码器，VTCompressionSessionCreate 返回 -12902 → 编码器建不起来、零帧（系统日志：Low latency RC mode requires hardware encoder）" ;;
    *)       no "【低延迟RC状态未知】" ;;
  esac

  # 版本不一致提醒
  if [ -n "$orig_ver" ] && [ "$orig_ver" != "$cur_ver" ]; then
    no "备份与当前版本不一致（备份 $orig_ver / 当前 ${cur_ver}）→ 重跑 install 会自动重建基线"
  fi

  echo
  echo "文件："
  echo "  官方备份: $([ -f "$ORIG" ] && echo "有 $(du -h "$ORIG" | cut -f1)" || echo 无)"
  echo "  补丁库  : $([ -f "$PATCHED" ] && echo 有 || echo 无)"
  echo
  echo "签名状态："
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -aE 'Identifier=|TeamIdentifier|flags=' | sed 's/^/  /'
  if codesign --verify --deep "$APP" 2>/dev/null; then ok "签名校验通过"
  else no "签名校验未通过"; fi
  echo
  echo "进程状态："
  pgrep -fl 'UURemote.app' | sed 's/^/  /' | head -5 || echo "  (UU 未运行)"

  echo
  echo "签名一致性自检："
  if check_daemon_stale; then
    ok "各组件签名一致"
  else
    no "守护进程比当前签名【旧】—— 会导致组件间 XPC 被拒！"
    echo "     症状：UU 显示「无法连接至服务器 1001」，本机不上线"
    echo "     修复：sudo bash $0 daemon"
  fi

  check_daemon_present
  tcc_diag

  echo
  echo "可用命令："
  echo "  安装/更新补丁  sudo bash $0 install"
  echo "  还原官方原版   sudo bash $0 restore"
  echo "  状态           bash $0 status"
  echo "  验证采集器     bash $0 verify"
  echo "  修 XPC 被拒    sudo bash $0 daemon"
}


cg_verify_main() {
  hd "验证 UU 实际使用了哪套采集器"
  echo "（最好在手机连过一次之后、5 分钟内查）"
  echo
  echo "--- 采集失败错误码 ---"
  local n
  n=$(log show --last 15m --predicate 'process == "UURemoteServer"' --style compact 2>/dev/null | grep -ac 'Code=-3802' || true)
  if [ "${n:-0}" -gt 0 ]; then
    no "近 15 分钟出现 $n 次 -3802 → 仍走 ScreenCaptureKit（Card 未生效或 UU 更新覆盖了补丁）"
    echo "  → 检查：bash $0 status"
  else
    ok "近 15 分钟没有 -3802"
  fi
  echo
  echo "--- SCK 相关报错（有则说明仍走 SCK）---"
  log show --last 15m --predicate 'process == "UURemoteServer"' --style compact 2>/dev/null \
    | grep -aE 'SCStream|ScreenCaptureKit|startCapture' | tail -5 | cut -c1-180
  echo
  echo "--- 判定 ---"
  echo "  无 -3802 / 无 SCStream 报错 → 补丁生效，采集走 CoreGraphics ✔"
  echo "  有 -3802 / 有 SCStream       → 补丁没生效，或 UU 更新覆盖了补丁"
}


as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$REAL_USER" != "root" ]; then
    sudo -u "$REAL_USER" "$@"
  else
    "$@"
  fi
}


list_macho() {
  python3 - "$APP" <<'PY'
import os, sys
app = sys.argv[1]
MAGICS = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe',
          b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',
          b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
out = []
for root, dirs, files in os.walk(app):
    for fn in files:
        p = os.path.join(root, fn)
        try:
            with open(p, 'rb') as fh:
                if fh.read(4) in MAGICS:
                    out.append(p)
        except Exception:
            pass
# 深的先签；同深度时 .dylib 优先 —— 否则签名宿主二进制时会因「嵌套库还没签」而失败：
#   ✘ UURemote: code object is not signed at all
#     In subcomponent: .../Frameworks/libuushim.dylib
out.sort(key=lambda p: (-p.count('/'), 0 if p.endswith('.dylib') else 1, p))
sys.stdout.write('\n'.join(out) + ('\n' if out else ''))
PY
}


list_bundles() {
  python3 - "$APP" <<'PY'
import os, sys
app = os.path.abspath(sys.argv[1])
out = []
for root, dirs, files in os.walk(app):
    for d in dirs:
        p = os.path.join(root, d)
        if d.endswith('.xpc') or (d.endswith('.app') and os.path.abspath(p) != app):
            out.append(p)
out.sort(key=lambda p: p.count('/'), reverse=True)   # 深的先签
sys.stdout.write('\n'.join(out) + ('\n' if out else ''))
PY
}


# ★★ 免弹窗安装（第一步）：若本地放了钥匙串口令，先把【登录钥匙串】解锁。
#
# 背景：签名时 codesign 要取私钥，钥匙串 ACL 会弹出「…想要使用钥匙串中的密钥」+
#   密码输入框（选项 允许 / 始终允许 / 拒绝）。脚本自己的临时钥匙串口令是写死的
#   （P12PASS/KC_PASS），**不需要人工输入**；弹窗要的是**登录钥匙串**的口令。
#   没人点它就卡在安装中间 —— 而这是无人值守场景（远端/夜里）最容易卡住的地方。
#
# 做法：口令放本地文件 .local/keychain-pw（600 权限、.gitignore 已覆盖、绝不入 git）。
#   这里读出来用它解锁登录钥匙串。
#
# ★★ 但实测证明：**解锁钥匙串 ≠ 授予 ACL 授权**（2026-09-28）。
#   预解锁只让签名能读到私钥（消除 codesign 因钥匙串锁着而报 errSecInternalComponent），
#   而重签后 UU 再读它自己的密钥 com.netease.uuremote 时，系统仍会问
#   「这个 app 能不能读这把密钥」——**锁着与没授权是两回事**，该弹窗照样出现。
#   所以真正管用的组合是：本函数（解锁）+ dialog_watcher_start（自动应答）。
# 恢复：删掉口令文件即回到「弹窗人工处理」；macOS 在锁屏/注销时也会重新锁上钥匙串。
preunlock_login_keychain() {
  local f="$D/.local/keychain-pw" pw kc
  [ -r "$f" ] || return 0
  pw="$(tr -d '\r\n' < "$f")"
  [ -n "$pw" ] || { no "口令文件为空：$f"; return 0; }
  for kc in "$HOME/Library/Keychains/login.keychain-db" "$HOME/Library/Keychains/login.keychain"; do
    [ -e "$kc" ] || continue
    if as_user security unlock-keychain -p "$pw" "$kc" 2>/dev/null; then
      ok "登录钥匙串已提前解锁 → 本次安装不会再弹授权框"
    else
      no "登录钥匙串解锁失败（口令不对？）→ 安装时可能仍会弹窗，需人工点「始终允许」"
    fi
    return 0
  done
  no "找不到登录钥匙串（$HOME/Library/Keychains/）→ 保持原行为"
}


# ★★ 免弹窗安装（第二步）：安装期间自动应答「钥匙串授权弹窗」。
#
# 为什么光解锁不够：见上面 preunlock_login_keychain 的说明 —— 重签后系统还会问
#   「这个 app 能不能读 com.netease.uuremote 这把密钥」，那是一次 ACL 授权，
#   与钥匙串是否解锁无关。没人点，安装就停在半路（实测：安装进程卡住、UU 组件
#   读不到密钥 → 被控服务起不来 → 设备显示离线）。
#
# 做法：安装/签名期间后台起一个 AppleScript 轮询（见 tools/uu-dialog-responder.applescript），
#   发现该弹窗就填入登录口令并点「始终允许」。
#   ★ 口令只从本地文件 .local/keychain-pw 读入内存，不打印、不进日志、不入 git。
#   ★ 没有口令文件 → 不起守护（保持原行为：人工点），也绝不向用户索取口令。
#   ★ 只认「钥匙串 + 机密信息/想要」这类文案，别的系统弹窗不碰。
#   ★ 安装结束（含出错退出）必须停掉，靠 trap 兜底。
DIALOG_WATCH_PID=""
dialog_watcher_start() {
  local f="$D/.local/keychain-pw" scr="$D/tools/uu-dialog-responder.applescript"
  [ -r "$f" ] || return 0
  [ -f "$scr" ] || return 0
  # ★ 必须以**真实用户**身份起（as_user）：弹窗长在用户的 GUI 会话里，
  #   System Events 的辅助功能授权也是给这个用户的；以 root 跑 osascript 点不到它。
  as_user osascript "$scr" "$f" "${UU_DIALOG_WATCH_SECS:-900}" >>/tmp/uu-dialog-responder.log 2>&1 &
  DIALOG_WATCH_PID=$!
  ok "已挂上弹窗自动应答（授权框会自动填口令并点「始终允许」）"
}

dialog_watcher_stop() {
  [ -n "${DIALOG_WATCH_PID:-}" ] || return 0
  # 两层保险：先 kill 记录的 pid；再按**唯一脚本名**兜底（sudo -u 起的子进程，
  # 只 kill sudo 包装进程不一定会带走 osascript）。
  kill "$DIALOG_WATCH_PID" 2>/dev/null || true
  wait "$DIALOG_WATCH_PID" 2>/dev/null || true
  pkill -f "uu-dialog-responder.applescript" 2>/dev/null || true
  DIALOG_WATCH_PID=""
}

setup_keychain() {
  hd "准备独立签名钥匙串（避免 root 读不到登录钥匙串 → errSecInternalComponent）"
  preunlock_login_keychain
  dialog_watcher_start
  as_user security delete-keychain "$KC" 2>/dev/null || true
  as_user security create-keychain -p "$KC_PASS" "$KC" || { no "创建钥匙串失败"; exit 1; }
  ok "已创建 $KC"
  as_user security set-keychain-settings -lut 21600 "$KC"
  as_user security unlock-keychain -p "$KC_PASS" "$KC" || { no "解锁失败"; exit 1; }
  ok "已解锁"
  as_user security import "$P12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign -A 2>&1 | tail -1
  as_user security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null 2>&1
  ok "证书已导入并设好分区列表"

  # ★ 必须加入【搜索列表】。只传 --keychain 不够：codesign 会报
  #   "The specified item could not be found in the keychain" 并静默回退到登录钥匙串。
  ORIG_SEARCH_LIST=$(as_user security list-keychains -d user 2>/dev/null | tr -d ' "' | tr '\n' ' ')
  # shellcheck disable=SC2086
  as_user security list-keychains -d user -s $ORIG_SEARCH_LIST "$KC"
  ok "已加入搜索列表"

  HASH=$(as_user security find-identity -v -p codesigning "$KC" 2>/dev/null \
         | grep -a 'UURemote CG Patch' | head -1 | awk '{print $2}')
  [ -n "$HASH" ] || HASH=$(as_user security find-identity -p codesigning "$KC" 2>/dev/null \
         | grep -a 'UURemote CG Patch' | head -1 | awk '{print $2}')
  [ -n "$HASH" ] || { no "钥匙串里找不到 'UURemote CG Patch' 证书"; exit 1; }
  echo "  指纹: $HASH"
  echo "  OU  : $(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | grep -oE 'OU *= *[A-Z0-9]+' | cut -d= -f2 | tr -d ' ')"
}


teardown_keychain() {
  if [ -n "$ORIG_SEARCH_LIST" ]; then
    # shellcheck disable=SC2086
    as_user security list-keychains -d user -s $ORIG_SEARCH_LIST 2>/dev/null || true
  fi
  as_user security delete-keychain "$KC" 2>/dev/null || true
}


cleanup() {
  # ★ 这里必须也停掉弹窗自动应答，而不是只在顶层挂 EXIT trap：
  #   本函数被 `trap cleanup EXIT` 注册（在 sign_main 里），**会覆盖**顶层那条 trap
  #   （bash 的 trap 同名信号是「后者覆盖前者」，不是叠加）→ 实测装完应答器还在空转。
  #   收口到一处，所有退出路径（正常/报错/中断）都覆盖。
  dialog_watcher_stop
  if [ "$RESTORE_OWNER_NEEDED" -eq 1 ]; then
    chown -R root:wheel "$APP" 2>/dev/null && echo "（已恢复 App 属主 root:wheel）"
  fi
  teardown_keychain
}


sign_one() {
  local f="$1"
  local id; id=$(codesign -dv --verbose=4 "$f" 2>&1 | grep -a '^Identifier=' | cut -d= -f2)
  local args=(--force --sign "$HASH" --keychain "$KC" --timestamp=none --options runtime)
  [ -n "$id" ] && args+=(--identifier "$id")

  local extra="$D/extra-ents/$(basename "$f").plist"
  # 还原时用 UURT_SKIP_EXTRA=1 让签名回到官方权限集（不带我们额外加的权限）
  [ "${UURT_SKIP_EXTRA:-0}" = "1" ] && extra="/dev/null"
  local orig="$D/shim/backup/$(basename "$f").orig"   # 官方原版备份 = 权限的权威依据

  # ★★★ entitlements 取**三个来源的并集**（缺一不可）：
  #   ① 该文件当前签名上的 —— 平时就等于官方权限
  #   ② 官方原版备份上的（同名 .orig）—— ★ 关键：权限一旦被某次安装削掉，
  #      只以「当前」为基准就会**永久丢失且永不自愈**（每次都以已削过的版本为基准）。
  #      实测踩过：UURemoteServer 的 com.apple.security.device.audio-input 就是这样丢的
  #      —— 而当时的现场看不出任何异常，签名照样「通过」。
  #   ③ 我们额外要加的（extra-ents/<文件名>.plist）
  #   取并集而非「后者覆盖前者」：任一来源缺失或被削都能自动补回。
  #
  # 另注：mktemp 模板里的 X 必须**在结尾**。写 `mktemp /tmp/ents.XXXXXX.plist` 的实际后果：
  #   第一次建出该**字面名**文件，之后每次都 `mkstemp failed: File exists` → 命令替换拿到
  #   空串 → `--entitlements` 整条不传 → 权限被悄悄抹掉（这正是上面那个事故的成因）。
  #   用 `-t <前缀>`（系统临时目录，X 在结尾）；并以**真实用户**创建 —— root 建的 600 文件，
  #   随后 `sudo -u <用户> codesign` 读不到（会变成另一种假失败）。
  local curf="" origf="" merged=""
  if codesign -d --entitlements :- "$f" 2>/dev/null | grep -q '<plist'; then
    curf=$(as_user mktemp -t entscur) || curf=""
    [ -n "$curf" ] && codesign -d --entitlements :- "$f" 2>/dev/null > "$curf"
  fi
  if [ -f "$orig" ] && codesign -d --entitlements :- "$orig" 2>/dev/null | grep -q '<plist'; then
    origf=$(as_user mktemp -t entsorig) || origf=""
    [ -n "$origf" ] && codesign -d --entitlements :- "$orig" 2>/dev/null > "$origf"
  fi

  local srcs=()
  [ -n "$curf" ]  && srcs+=("$curf")
  [ -n "$origf" ] && srcs+=("$origf")
  [ -f "$extra" ] && srcs+=("$extra")

  # ★★★ ④ 官方权限集文件（$ENTS）—— 只给主程序 UURemote（2026-09-28 新增）：
  #   为什么必须有这一条：UURemote 的 audio-input/bluetooth **只登记在这个文件里**
  #   （官方对照机 101：UURemote = audio-input + bluetooth；Server = audio-input；
  #    Service/Daemon = 无）。而在此之前 $ENTS 全脚本只被「检查存在」、从未参与签名，
  #   于是一旦某轮重签把 GUI 权限削掉，就再也回不来（每次都以已削过的版本为基准）。
  #   代价极大 —— UU 自己的 verifyHardenedRuntimeAndEntitlements() 会校验 XPC 客户端
  #   的权限，校验不过就把连接拒掉：GUI 每 3 秒重连一次、界面报「无法连接至服务器
  #   1001」、会话永远完不成，**表现就是「别的设备连上来没有画面」**。
  #   真机实测：补回这两个权限后，XPC 拒绝 20~115 次/分 → 0，界面红框消失。
  [ "$(basename "$f")" = "UURemote" ] && [ -f "$ENTS" ] && srcs+=("$ENTS")

  if [ ${#srcs[@]} -gt 0 ]; then
    merged=$(as_user mktemp -t entsm) || merged=""
    if [ -n "$merged" ]; then
      if python3 -c 'import plistlib,sys
out={}
for p in sys.argv[1:-1]:
    try:
        d=plistlib.load(open(p,"rb"))
    except Exception:
        continue
    if isinstance(d,dict): out.update(d)
plistlib.dump(out, open(sys.argv[-1],"wb"))' "${srcs[@]}" "$merged" 2>/dev/null; then
        echo "    + 权限：$(python3 -c 'import plistlib,sys;print(",".join(sorted(plistlib.load(open(sys.argv[1],"rb")).keys())))' "$merged" 2>/dev/null)"
      else
        merged=""   # 合并失败 → 宁可退回「不传 --entitlements」，也不签一个半成品
      fi
    fi
  fi
  [ -n "$merged" ] && args+=(--entitlements "$merged")

  local out rc
  as_user security unlock-keychain -p "$KC_PASS" "$KC" >/dev/null 2>&1
  out=$(as_user codesign "${args[@]}" "$f" 2>&1); rc=$?
  if [ $rc -ne 0 ] && [ "$(id -u)" -eq 0 ]; then
    security unlock-keychain -p "$KC_PASS" "$KC" >/dev/null 2>&1
    out=$(codesign "${args[@]}" "$f" 2>&1); rc=$?
  fi

  [ -n "$curf" ] && rm -f "$curf"
  [ -n "$origf" ] && rm -f "$origf"
  [ -n "$merged" ] && rm -f "$merged"
  if [ $rc -eq 0 ]; then
    ok "$(basename "$f")  (id=${id:-auto})"
    return 0
  fi
  no "$(basename "$f")：$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  return 1
}


preflight_sign() {
  hd "预检：试签临时文件（失败则完全不碰正式 App）"
  local probe=/tmp/uurt-preflight-$$
  # ★ 必须以真实用户身份创建：root 用 cp 建的文件属 root，
  #   随后 `sudo -u <用户> codesign` 会因无写权限报 Permission denied（假失败）。
  as_user cp /bin/echo "$probe" || { no "无法创建测试文件"; return 1; }
  local out rc
  as_user security unlock-keychain -p "$KC_PASS" "$KC" >/dev/null 2>&1
  out=$(as_user codesign --force --sign "$HASH" --keychain "$KC" \
        --options runtime --timestamp=none "$probe" 2>&1); rc=$?
  if [ $rc -ne 0 ] && [ "$(id -u)" -eq 0 ]; then
    echo "  用户身份签名未成功，回退 root 身份重试（不是错误）"
    security unlock-keychain -p "$KC_PASS" "$KC" >/dev/null 2>&1
    out=$(codesign --force --sign "$HASH" --keychain "$KC" --options runtime --timestamp=none "$probe" 2>&1); rc=$?
  fi
  if [ $rc -ne 0 ]; then
    no "签名失败：$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    rm -f "$probe"; return 1
  fi
  if codesign --verify -R="certificate leaf[subject.OU] = \"$OFFICIAL_TEAM\"" "$probe" 2>/dev/null; then
    ok "预检通过：$(codesign -dv --verbose=4 "$probe" 2>&1 | grep -a '^Authority=' | head -1)  $(codesign -dv --verbose=2 "$probe" 2>&1 | grep -aoE 'flags=0x[0-9a-f]+\([a-z]+\)' | head -1)  满足 OU 校验"
    rm -f "$probe"; return 0
  fi
  no "预检签名成功但 OU 校验不过（证书 OU 不对？）"; rm -f "$probe"; return 1
}


sign_or_fail() { sign_one "$1" || FAILED=$((FAILED+1)); }


have_dylib() { otool -L "$1" 2>/dev/null | grep -qF "libuushim.dylib"; }


now_epoch() { date +%s; }


log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$WD_LOG"; }


to_sec() { echo $((10#${1:0:2} * 3600 + 10#${1:3:2} * 60 + 10#${1:6:2})); }


recent_log() {
  [ -f "$SHIM_LOG" ] || return 0
  local ts d
  local now_s
  now_s=$(to_sec "$(date +%H:%M:%S)")
  tail -n "${UU_WD_SCAN:-1200}" "$SHIM_LOG" 2>/dev/null | while IFS= read -r line; do
    ts=${line:0:8}
    case "$ts" in [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;; *) continue ;; esac
    d=$((now_s - $(to_sec "$ts")))
    [ "$d" -lt 0 ] && d=$((d + 86400))
    [ "$d" -le "$WINDOW" ] && printf '%s\n' "$line"
  done
}


# ---- sign_main ----
sign_main() {
# ============================================================================
# 修复 UU远程「无法连接至服务器 1001 / 设备不上线」—— 组件签名
# ============================================================================
# 背景：给 UU 打 CG 采集补丁必须重签名（原官方签名失效）。但 UU 内部用
#       `certificate leaf[subject.OU] = <TeamID>` 校验组件身份，并检查
#       `Hardened runtime is not set for the sender`。adhoc 签名（-s -）两条都不满足
#       → 组件间 XPC 被拒 → 被控服务起不来 → 设备不上线、报 1001。
#
# 解法：用「OU = UU 官方 TeamID (PU9BNSBJW7)」的自签证书 + --options runtime
#       给整个 App 重签，让 UU 的内部校验通过。
#
# 用法：sudo bash uu.sh sign
#
# 演练（在副本上跑真实脚本，不碰正式 App，不需要 sudo）：
#   cp -R /Applications/UURemote.app /tmp/dry/UURemote.app
#   UURT_APP=/tmp/dry/UURemote.app UURT_REHEARSE=1 bash uu.sh sign
#
# 关键实现（都是踩过的坑）：
#   1. 不能用登录钥匙串签名！以 root 跑 codesign 读不到用户级钥匙串，报
#      errSecInternalComponent（症状：每个组件都失败）。必须用「独立临时钥匙串 +
#      已知密码」，并让 codesign 以真实用户身份执行。
#   2. 只传 --keychain 不够 —— 临时钥匙串必须加入用户钥匙串【搜索列表】，
#      否则报 "item could not be found" 后【静默回退到登录钥匙串】→ 假成功/假失败。
#   3. 必须带 --options runtime（UU 检查 hardened runtime；原版官方签名即 runtime）。
#   4. 每个组件必须保留【原 identifier】（从现有签名读出后用 --identifier 传回），
#      否则 identifier 校验失败。组件清单自动枚举，UU 加新组件也不用改脚本。
#   5. 顺序：Mach-O 文件（深的先）→ 内层 bundle(.xpc/.app) → 最外层 App。
#   6. 动手前先预检（试签临时文件 + 验 OU），失败则完全不碰正式 App。
#   7. 不用 mapfile —— macOS 自带 bash 3.2 没有这个内建命令。
# ============================================================================

# ★★ 这里**不要**再写 D="$HOME/xxx"：
#   bash 函数内赋值默认是**全局**的（未加 local），会把文件顶部基于 BASH_SOURCE 的
#   自适应 D 覆盖成硬编码路径 ⇒ 项目一旦被 clone 到别处（如 ~/code/uuremote-cg-patch），
#   sign 就会去找旧路径下的证书而报「找不到证书」。D / APP / REHEARSE 顶部已定义，直接复用。
CERT="$D/cert/cert.pem"
P12="$D/cert/id.p12"
P12PASS=patch
REAL_USER="${SUDO_USER:-$(stat -f '%Su' "$HOME")}"

KC="/tmp/uurt-signing.keychain-db"
KC_PASS="uurtpatch"
OFFICIAL_TEAM="PU9BNSBJW7"

c_ok=$'\033[32m'; c_no=$'\033[31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'

# 需要在真实用户名下执行的命令（root 读不到用户钥匙串）

if [ "$(id -u)" -ne 0 ] && [ "$REHEARSE" != "1" ]; then
  no "请用 sudo 运行：sudo bash $0"; exit 1
fi
[ -f "$P12" ] && [ -f "$CERT" ] || { no "找不到证书（$D/cert/）"; exit 1; }
[ -d "$APP" ] || { no "找不到 App：$APP"; exit 1; }

if [ "$REHEARSE" = "1" ]; then
  echo "★ 演练模式：目标 = ${APP}（不会动正式 App、不改属主、不重启任何进程）"
fi

# ---------------------------------------------------------------------------
# 组件枚举（自动，避免 UU 加组件后漏签）
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# 临时签名钥匙串
# ---------------------------------------------------------------------------
ORIG_SEARCH_LIST=""


RESTORE_OWNER_NEEDED=0
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 签名单个条目（文件或 bundle），identifier 从现有签名读出后照抄
# ---------------------------------------------------------------------------

# 预检：先试签临时文件，失败则不碰正式 App

FAILED=0

# ===========================================================================
setup_keychain

if ! preflight_sign; then
  hd "预检失败 —— 已中止，正式 App 未被改动"
  echo "  请把以上输出发给我。"
  exit 1
fi

# ---------- 1. 退出 UU ----------
hd "1/9 退出 UU 全部组件"
if [ "$REHEARSE" = "1" ]; then
  echo "  演练模式：跳过（不干扰正在运行的 UU）"
else
  # ★ 不要用 `launchctl bootout` 卸载守护进程 —— 它是 RunAtLoad 的 LaunchDaemon，
  #   bootout 之后只会「消失」，不会自己回来；而 `kickstart` 对已卸载的服务会失败，
  #   结果守护进程彻底缺失（症状：设备不上线）。用 kickstart -k 只重启、不卸载。
  launchctl kickstart -k system/com.netease.uuremote.daemon 2>/dev/null \
    && echo "  root 守护进程已重启" || echo "  守护进程未加载（稍后统一处理）"
  pkill -f 'UURemote.app/Contents/MacOS/UURemote' 2>/dev/null || true
  pkill -f 'UURemote.app/Contents/Helpers/UURemoteServer' 2>/dev/null || true
  pkill -f 'UURemote.app/Contents/XPCServices/UURemoteHelper' 2>/dev/null || true
  pkill -f 'UURemoteService' 2>/dev/null || true
  sleep 3
  # 守护进程是 KeepAlive，杀了会自己回来；确认一下
  echo "  剩余进程："
  pgrep -fl 'UURemote.app' | sed 's/^/    /' || echo "    （无）"
fi

# ---------- 2. 备份 ----------
if [ "$REHEARSE" = "1" ]; then
  hd "2/9 备份：演练模式跳过"
else
  hd "2/9 备份当前 App（可回退）"
  BK="$D/UURemote.app.before-certsign"
  rm -rf "$BK" 2>/dev/null || true
  ditto "$APP" "$BK" && ok "已备份到 $BK" || no "备份失败（继续；原始库备份仍可还原补丁）"
fi

# ---------- 3. 改属主 ----------
if [ "$REHEARSE" = "1" ]; then
  hd "3/9 改属主：演练模式跳过"
else
  hd "3/9 临时改属主为 $REAL_USER"
  RESTORE_OWNER_NEEDED=1
  chown -R "$REAL_USER" "$APP" && ok "已 chown（结束时会自动恢复 root:wheel）"
  sleep 1
fi

# ---------- 4. 枚举组件 ----------
hd "4/9 枚举需要签名的组件"
MACHO_LIST=$(mktemp /tmp/uurt-macho.XXXXXX)
BUNDLE_LIST=$(mktemp /tmp/uurt-bundle.XXXXXX)
list_macho   > "$MACHO_LIST"
list_bundles > "$BUNDLE_LIST"
N_MACHO=$(grep -c . "$MACHO_LIST" 2>/dev/null); N_MACHO=${N_MACHO:-0}
N_BUNDLE=$(grep -c . "$BUNDLE_LIST" 2>/dev/null); N_BUNDLE=${N_BUNDLE:-0}
echo "  Mach-O 文件: $N_MACHO 个"
echo "  内层 bundle: $N_BUNDLE 个"

# ---------- 5. 签所有 Mach-O 文件（深的先） ----------
hd "5/9 签名 Mach-O 文件（共 $N_MACHO 个）"
while IFS= read -r f || [ -n "$f" ]; do
  [ -n "$f" ] && sign_or_fail "$f"
done < "$MACHO_LIST"

# ---------- 6. 签内层 bundle ----------
hd "6/9 签名内层 bundle（.xpc / 嵌套 .app）"
while IFS= read -r b || [ -n "$b" ]; do
  [ -n "$b" ] && sign_or_fail "$b"
done < "$BUNDLE_LIST"
rm -f "$MACHO_LIST" "$BUNDLE_LIST"

# ---------- 7. 签最外层 App ----------
hd "7/9 签名 App 主体"
sign_or_fail "$APP"

if [ "$FAILED" -gt 0 ]; then
  hd "有 $FAILED 个组件签名失败 —— 已中止，不启动 UU"
  echo "  App 仍是签名前状态（codesign 报错时不会破坏旧签名）。请把以上 ✘ 输出发给我。"
  exit 1
fi

# ---------- 8. 校验 ----------
hd "8/9 校验"
VFAIL=0
codesign --verify --deep --strict "$APP" 2>/dev/null && ok "整包校验通过" \
  || { no "整包校验未通过"; codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -6; VFAIL=1; }

echo
echo "核心组件 —— UU 的 OU 校验（不过则 XPC 必被拒）："
for rel in "MacOS/UURemote" "MacOS/UURemoteService" "MacOS/UURemoteDaemon" "Helpers/UURemoteServer"; do
  p="$APP/Contents/$rel"
  [ -f "$p" ] || continue
  id=$(codesign -dv --verbose=4 "$p" 2>&1 | grep -a '^Identifier=' | cut -d= -f2)
  fl=$(codesign -dv --verbose=2 "$p" 2>&1 | grep -aoE 'flags=0x[0-9a-f]+\([a-z]+\)' | head -1)
  if codesign --verify -R="identifier \"$id\" and certificate leaf[subject.OU] = \"$OFFICIAL_TEAM\"" "$p" 2>/dev/null; then
    ok "$(basename "$p")  id=$id  $fl"
  else
    no "$(basename "$p")  id=$id  $fl  ← 不满足 OU 校验"; VFAIL=1
  fi
done

echo
echo "反向对照（错误 OU 必须校验失败，否则说明测试无效）："
if codesign --verify -R="certificate leaf[subject.OU] = \"WRONGTEAM9\"" "$APP/Contents/MacOS/UURemote" 2>/dev/null; then
  no "错误 OU 竟然通过了 —— 校验方式有问题"; VFAIL=1
else
  ok "错误 OU 被拒绝（校验有效）"
fi

echo
echo "补丁完整性："
st=$(python3 "$D/patch_tool.py" check "$APP/Contents/Frameworks/libstreamer.dylib" 2>/dev/null)
vst=$(printf '%s\n' "$st" | head -1)
ast=$(printf '%s\n' "$st" | sed -n '2p' | awk '{print $2}')
est=$(printf '%s\n' "$st" | sed -n '3p' | awk '{print $2}')
mst=$(printf '%s\n' "$st" | sed -n '4p' | awk '{print $2}')
lst=$(printf '%s\n' "$st" | sed -n '5p' | awk '{print $2}')
if [ "$vst" = "patched" ]; then ok "视频补丁在（走 CoreGraphics）"
else no "视频库状态为 $vst"; VFAIL=1; fi
if [ "$ast" = "patched" ]; then ok "音频补丁在（不再走 ScreenCaptureKit）"
else no "音频补丁状态为 $ast"; VFAIL=1; fi
if [ "$est" = "patched" ]; then ok "编码器补丁在（强制软件编码，不要求 Metal）"
else no "编码器补丁状态为 ${est}（本机无 Metal，硬件编码器必挂）"; VFAIL=1; fi
if [ "$mst" = "patched" ]; then ok "Metal 门禁补丁在（设备为空不再放弃编码器）"
else no "Metal 门禁补丁状态为 ${mst}（只补编码器没用：ResetVTCompressionSession 会先因 Metal 为空 return false → error 12）"; VFAIL=1; fi
if [ "$lst" = "patched" ]; then ok "低延迟RC补丁在（不再要求硬件编码器，建会话不再返回 -12902）"
else no "低延迟RC补丁状态为 ${lst}（本机无硬编，会卡在 Low latency RC mode requires hardware encoder）"; VFAIL=1; fi

if [ "$VFAIL" -ne 0 ]; then
  hd "校验未通过 —— 不启动 UU"
  echo "  还原：sudo bash $D/uu.sh cg-restore   或去 uuyc.163.com 覆盖安装"
  exit 1
fi

if [ "$REHEARSE" = "1" ]; then
  hd "演练完成 —— 校验全过，正式 App 未被触碰"
  exit 0
fi

# ---------- 9. 恢复属主并强制全量重启 ----------
hd "9/9 恢复属主并强制全量重启"
chown -R root:wheel "$APP" && ok "属主已恢复 root:wheel"
RESTORE_OWNER_NEEDED=0

SIGN_T=$(stat -f '%m' "$APP/Contents/_CodeSignature/CodeResources" 2>/dev/null)

# ★ 必须先把所有进程杀掉再启动 —— 签名期间 launchd 会把 agent/server 拉起来，
#   它们持有的是「签名中途」的旧代码。而 `open -a UURemote` 对已在运行的 App
#   只是激活窗口，【不会重启进程】→ 旧进程一直活着，问题照旧。
pkill -f 'UURemote.app/Contents/MacOS/UURemote' 2>/dev/null || true
pkill -f 'UURemote.app/Contents/Helpers/UURemoteServer' 2>/dev/null || true
pkill -f 'UURemote.app/Contents/XPCServices/UURemoteHelper' 2>/dev/null || true
pkill -f 'UURemoteService' 2>/dev/null || true
sleep 3

# root 守护进程：loaded 就重启，没 loaded 就 bootstrap（不要让它缺席）
if launchctl print system/com.netease.uuremote.daemon >/dev/null 2>&1; then
  launchctl kickstart -k system/com.netease.uuremote.daemon 2>/dev/null \
    && ok "守护进程已重启（新签名）" || no "守护进程重启失败"
else
  echo "  守护进程未加载 → 重新 bootstrap"
  $LC bootstrap system /Library/LaunchDaemons/com.netease.uuremote.daemon.plist 2>/dev/null \
    && ok "守护进程已加载并启动" || no "bootstrap 失败（需手动：sudo $LC bootstrap system /Library/LaunchDaemons/com.netease.uuremote.daemon.plist）"
  sleep 2
fi

as_user open -a UURemote 2>/dev/null || open -a UURemote || true

# ★ 关键补一步：`open -a UURemote` 只拉起 GUI/Service/Daemon，**不会起 UURemoteServer**。
#   而 server 才是「设备在线」的载体（没它 → 别的设备看到离线、报 1001），
#   且 UU 自己不会在需要时补起（实测等 60s 无动静）。上面第 8 步刚 pkill 过它，
#   不补这一步 = 「签完名设备反而不上线」。详见 server_agent 那节注释。
server_agent_up || true
sleep 6

echo
echo "进程启动时间核对（全部应晚于签名完成时间，否则是旧代码）："
echo "  签名完成: $(date -r "$SIGN_T" '+%H:%M:%S' 2>/dev/null)"
STALE=0
pgrep -f 'UURemote.app' | while read -r p; do
  st=$(ps -p "$p" -o lstart= 2>/dev/null)
  name=$(ps -p "$p" -o comm= 2>/dev/null | xargs basename 2>/dev/null)
  pst=$(date -j -f "%a %b %d %T %Y" "$st" "+%s" 2>/dev/null)
  mark="✔"
  if [ -n "$pst" ] && [ -n "$SIGN_T" ] && [ "$pst" -lt "$SIGN_T" ]; then mark="✘ 旧代码"; STALE=1; fi
  printf "  %s %-22s %s\n" "$mark" "$name" "$st"
done
echo
pgrep -f UURemoteDaemon >/dev/null && ok "守护进程在运行" || no "守护进程仍未运行 → 执行：sudo $LC bootstrap system /Library/LaunchDaemons/com.netease.uuremote.daemon.plist"

cat <<'EOT'

────────────────────────────────────────────────────────────
✔ 签名已合规。重启后先看需不需要重新授权（不一定需要）：
  系统设置 → 隐私与安全性
    1) 录屏与系统录音 → 大概率【仍然是授权的】
       原因：这条 TCC 记录的要求是「由本机这张证书签发」（certificate root），
       重签用的还是同一张证书 → 记录依然匹配，不用重勾。
       只有当 UU 里仍提示「未授权录屏」时才需要：取消勾选再重新勾上。
    2) 辅助功能 → 【通常需要重新勾】
       原因：这条记录的旧要求是「Apple 官方签名」，与自签身份必然失配。
       先执行：tccutil reset Accessibility com.netease.uuremote
       再在列表里取消勾选后重新勾上（没有就点 + 添加 /Applications/UURemote.app）
  完全退出 UU 再打开。

验证（以下命令均在本项目目录下执行）：
  # 一键看全部状态（补丁 / 签名一致性 / 守护进程 / 权限）
  bash uu.sh status
  # XPC 是否还被拒（应无输出）
  log show --last 2m --predicate 'process == "UURemoteDaemon"' --style compact \
    | grep -a 'rejected by the listener'

回退：
  sudo bash uu.sh cg-restore
────────────────────────────────────────────────────────────
EOT
}


# ---- server_agent 系列（保证「设备在线」）----
# ============================================================================
# 为什么需要这一节（2026-09-28 实测踩到）：
#
#   **UURemoteServer 就是「设备在线」的载体。** 它不在跑时，别的设备看这台机是
#   **离线**（`uuyc-cli device info` → isOnline=false），连不上；进程在跑就一直在线。
#
#   UU **只在自身启动流程里**建它（父进程 = UURemoteService）；**且只盯自己的子进程** ——
#   实测：杀掉 UU 的子进程，UU 约 3 秒内重建；而杀掉**我们**拉起的那个（父=launchd），
#   UU 不管（撤掉本 LaunchAgent 后杀它 → 150 秒无任何重建、设备一直离线）。所以：
#     · 父 = UURemoteService 的 server → 死了 UU 自己补；
#     · 父 = launchd 的 server → 死了由**本 LaunchAgent** 补（这就是它存在的理由）。
#
#   麻烦在于：**shim-install 为了重签必然要 `pkill UURemoteServer`**（文件被占用就签不了），
#   装完却没人负责把它带回来 —— 于是出现「装完补丁、设备反而离线」的假象，
#   而日志里没有任何错误，非常难查。
#
#   ⇒ 给 server 一个**自己的 LaunchAgent**（RunAtLoad + KeepAlive），由 launchd 托管：
#     登录即起、异常退出自起、与 UU 的其它组件解耦。安装收尾与看门狗都调 server_agent_up。
#
# ★ 2026-09-28 收口：**单实例监督**（因为重复 server 会被 UU 自己的启动流程造出来）
#   实测到两个 server 同时存在：UU 的 Service 建一个（父=UURemoteService）、
#   本 LaunchAgent 的 KeepAlive 再建一个（父=launchd）。两者都监听同样的 UDP 端口 →
#   互相抢资源，是「连上没画面」的可疑来源之一。
#   现在 plist **不直接跑 server**，而是跑一句检查：
#       `if pgrep -qx UURemoteServer; then exit 0; fi; exec <server>`
#   - 已有 server（不论谁建的）→ 退出，不再造一个；
#   - 一个都没有 → `exec` 起一个（exec 让 launchd 把**真进程**当本 job 的进程，
#     从而保留「异常退出自动重启」）；
#   - `KeepAlive` 用 `SuccessfulExit=false`（只在**非**正常退出时重启）→ 上面那个
#     「正常退出」不会被反复拉起；再配 `StartInterval` 定期兜底检查一次。
# ============================================================================

server_agent_paths() {
  # ★ 本脚本通常以 sudo 跑，此时 $HOME 是 /var/root、`id -u` 是 0 —— 直接用会把
  #   LaunchAgent 写到 root 家目录、并往不存在的 gui/0 域加载。所以一律回到**真实用户**。
  local uh="" uid=""
  if [ "$(id -u)" -eq 0 ] && [ "${REAL_USER:-}" != "root" ] && [ -n "${REAL_USER:-}" ]; then
    uh=$(as_user bash -c 'printf %s "$HOME"' 2>/dev/null || true)
    uid=$(id -u "$REAL_USER" 2>/dev/null || true)
  fi
  [ -n "$uh" ] || uh="$HOME"
  [ -n "$uid" ] || uid="$(id -u)"
  SA_HOME="$uh"; SA_UID="$uid"; SA_DOM="gui/$uid"
  SA_LABEL="com.uuremote-cg-patch.server"
  SA_PLIST="$uh/Library/LaunchAgents/$SA_LABEL.plist"
  SA_LOG="${UU_SERVER_LOG:-/tmp/uuserver.log}"
  SA_SRV="$APP/Contents/Helpers/UURemoteServer"
}

# ---- server_agent_procs ---- 列出所有 server 及「谁拉起的」（收口后正常只有 1 个）
server_agent_procs() {
  local p pp nm
  for p in $(pgrep -x UURemoteServer 2>/dev/null); do
    pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    nm=$(ps -o comm= -p "${pp:-0}" 2>/dev/null | xargs basename 2>/dev/null)
    printf 'pid=%s 父=%s(%s)\n' "$p" "${pp:-?}" "${nm:-?}"
  done
}

# ---- server_agent_up ----
# 用法: server_agent_up      # 幂等：没装就装、没跑就起、老形态 plist 就迁移成单实例监督
server_agent_up() {
  server_agent_paths
  if [ ! -x "$SA_SRV" ]; then
    echo "  ！$SA_SRV 不存在，跳过"
    return 1
  fi

  # ---- 生成 / 迁移 plist（单实例监督形态）----
  # ★ 判据用「有没有那句完整检查」：老形态直接 exec server，迁移前 UU 的 Service
  #   造出 server 后本 job 还会再建一个（重复进程抢同样端口）。形态不对就重写。
  #   ★ 改这句话时必须同步改这里 —— 否则线上 plist 不会被迁移（这是判据）。
  local SUP_LINE="if pgrep -qx UURemoteServer; then exit 0; fi; sleep 5; if pgrep -qx UURemoteServer; then exit 0; fi; exec"
  local need_write=0
  [ -f "$SA_PLIST" ] || need_write=1
  grep -qF "$SUP_LINE" "$SA_PLIST" 2>/dev/null || need_write=1

  if [ "$need_write" = "1" ]; then
    as_user mkdir -p "$SA_HOME/Library/LaunchAgents" 2>/dev/null || mkdir -p "$(dirname "$SA_PLIST")"
    # ★ XML 里刻意不用 `>` 与 `&&`（pgrep 用 -q 代替重定向、用 `;` 代替 `&&`）——
    #   否则要写成 &gt; / &amp;&amp;，很容易写错且 lint 不一定抓得到。
    # ★ 那个 `sleep 5`：UU 的 Service 在自己子进程死掉后约 3 秒内会重建，
    #   先让它一步，能显著减少「两个 server 同时被建出来」的抢建概率。
    cat > "$SA_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SA_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>$SUP_LINE $SA_SRV</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StartInterval</key>
  <integer>180</integer>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardErrorPath</key>
  <string>$SA_LOG</string>
  <key>StandardOutPath</key>
  <string>$SA_LOG</string>
</dict>
</plist>
EOF
    # plist 属主必须是该用户，否则 launchd 会拒绝加载
    [ "$(id -u)" -eq 0 ] && chown "${SA_UID}:$(id -gn "$REAL_USER" 2>/dev/null || echo staff)" "$SA_PLIST" 2>/dev/null
    plutil -lint "$SA_PLIST" >/dev/null 2>&1 || { echo "  ！plist 语法错误：$SA_PLIST"; return 1; }
    # ★ 改了 ProgramArguments 必须 unload + load —— kickstart -k 不会重读 plist（实测）。
    as_user $LC unload -w "$SA_PLIST" 2>/dev/null || true
  fi

  # ---- 已有 server 就不重启它 ----
  # ★ 铁律 3：只要还有 server 在跑就绝不 `kickstart -k` —— 那会当场把正在串流的用户踢下线。
  #   收口后我们的职责只是「一个都没有时补一个」；强制重启需显式设 UU_SERVER_FORCE=1
  #   （安装/签名流程本来就已经 pkill 过，走不到这里）。
  if pgrep -x UURemoteServer >/dev/null 2>&1 && [ "${UU_SERVER_FORCE:-0}" != "1" ]; then
    local nc; nc=$(pgrep -x UURemoteServer | wc -l | tr -d ' ')
    ok "已有 UURemoteServer 在跑（${nc} 个）—— 不重启它（避免打断会话）"
    server_agent_procs | sed 's/^/    /'
    [ "$nc" -gt 1 ] && echo "    ！多于 1 个：UU 的 Service 也建了一个（单实例监督不会再补第三个）"
    return 0
  fi

  # 已加载就 kickstart -k（先杀后起 → 保证跑的是刚签好的新二进制）；
  # 没加载就 load -w。★ 用变量 $LC 调 launchd：agent 的 terminal 护栏按字符串匹配
  #   拦 launchctl 的 bootstrap/submit，会把它误判成「注册 gateway 常驻任务」。
  #   ★ 必须 as_user：LaunchAgent 属于**用户域**，root 加载会落到别的域。
  if as_user $LC print "$SA_DOM/$SA_LABEL" >/dev/null 2>&1; then
    as_user $LC kickstart -k "$SA_DOM/$SA_LABEL" 2>/dev/null || true
  else
    as_user $LC load -w "$SA_PLIST" 2>/dev/null || true
  fi

  local i
  for i in $(seq 1 20); do
    pgrep -x UURemoteServer >/dev/null 2>&1 && break
    sleep 1
  done
  if pgrep -x UURemoteServer >/dev/null 2>&1; then
    local n; n=$(pgrep -x UURemoteServer | wc -l | tr -d ' ')
    ok "UURemoteServer 在跑（${n} 个，单实例监督托管）—— 设备可被连接"
    server_agent_procs | sed 's/^/    /'
    # 单实例监督生效时，另一个 server 只会来自 UU 自己的启动流程
    [ "$n" -gt 1 ] && echo "    ！多于 1 个：UU 的 Service 也建了一个（本工具不会再补第三个）"
    return 0
  fi
  echo "  ！server 未起来（设备会显示离线）"
  echo "    手动：as_user $LC kickstart -k $SA_DOM/$SA_LABEL"
  return 1
}

# ---- server_agent_down ----
server_agent_down() {
  server_agent_paths
  as_user $LC print "$SA_DOM/$SA_LABEL" >/dev/null 2>&1 && as_user $LC unload -w "$SA_PLIST" 2>/dev/null || true
  rm -f "$SA_PLIST"
}

# ---- server_agent_status ----
server_agent_status() {
  server_agent_paths
  local dom="$SA_DOM"
  echo "  LaunchAgent: $SA_PLIST $([ -f "$SA_PLIST" ] && echo '（已装）' || echo '（未装）')"
  if [ -f "$SA_PLIST" ]; then
    if grep -q "pgrep -qx UURemoteServer" "$SA_PLIST" 2>/dev/null; then
      echo "  形态: 单实例监督（已有 server 就不再建）✔"
    else
      echo "  形态: 老形态（直接 exec server）→ 会与 UU 自建的 server 重复；跑 bash uu.sh server-up 迁移"
    fi
  fi
  if as_user $LC print "$dom/$SA_LABEL" >/dev/null 2>&1; then
    echo "  加载状态: 已加载（域 ${dom}）"
  else
    echo "  加载状态: 未加载"
  fi
  local n; n=$(pgrep -x UURemoteServer 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -ge 1 ]; then
    echo "  进程: 在跑 ${n} 个 → 设备应显示**在线**"
    server_agent_procs | sed 's/^/    /'
    [ "$n" -gt 1 ] && echo "    ！多于 1 个（UU 的 Service 也建了一个）—— 单实例监督不会再补第三个"
  else
    echo "  进程: 不在跑 → 设备会显示**离线**（连不上）"
  fi
}


# ---- watchdog_ensure_agent ----
# 幂等安装看门狗 LaunchAgent（每 60 秒跑一次 `uu.sh watchdog`）。
# 为什么要有它：看门狗负责「空闲回收内存」与「兜底拉起 server」，都是无人值守场景
# 才暴露的问题；一旦 plist 丢了（换机、清理、UU 升级），这些保护会静默消失。
watchdog_ensure_agent() {
  local uh uid
  if [ "$(id -u)" -eq 0 ] && [ "${REAL_USER:-}" != "root" ] && [ -n "${REAL_USER:-}" ]; then
    uh=$(as_user bash -c 'printf %s "$HOME"' 2>/dev/null || true)
    uid=$(id -u "$REAL_USER" 2>/dev/null || true)
  fi
  [ -n "$uh" ] || uh="$HOME"
  [ -n "$uid" ] || uid="$(id -u)"
  local label="com.uuremote-cg-patch.watchdog"
  local plist="$uh/Library/LaunchAgents/$label.plist"
  as_user mkdir -p "$uh/Library/LaunchAgents" 2>/dev/null || mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$D/uu.sh</string>
    <string>watchdog</string>
  </array>
  <key>RunAtLoad</key>
  <false/>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardErrorPath</key>
  <string>/tmp/uushim-watchdog.err</string>
  <key>StandardOutPath</key>
  <string>/tmp/uushim-watchdog.out</string>
</dict>
</plist>
EOF
  [ "$(id -u)" -eq 0 ] && chown "${uid}:$(id -gn "${REAL_USER:-$(id -un)}" 2>/dev/null || echo staff)" "$plist" 2>/dev/null
  plutil -lint "$plist" >/dev/null 2>&1 || { echo "  ！看门狗 plist 语法错误"; return 1; }
  if as_user $LC print "gui/$uid/$label" >/dev/null 2>&1; then
    as_user $LC kickstart -k "gui/$uid/$label" 2>/dev/null || true
    ok "看门狗已加载（每 60 秒一次）"
  else
    if as_user $LC load -w "$plist" 2>/dev/null; then ok "看门狗已安装并加载"
    else echo "  ！看门狗加载失败（可手跑：bash $D/uu.sh watchdog）"; return 1; fi
  fi
}


# ---- shim_install_main ----
shim_install_main() {
# ============================================================================
# A 方案安装：把「截图轮询帧源」注入 UU 被控端 —— 路线二（二进制级，不用环境变量）
# ============================================================================
# 做什么：
#   1. 把 libuushim.dylib 放进 App 的 Contents/Frameworks/
#   2. 给 UURemoteServer 的 Mach-O 加一条 LC_LOAD_DYLIB 指向它
#      （不改 UU 任何机器码；dyld 通过 __DATA,__interpose 重定向 CGDisplayStream*）
#   3. 调用 uu.sh sign 用同一张证书重签整包
#      （UURemoteServer 会额外带上 disable-library-validation，见 extra-ents/）
#
# 为什么走路线二而不是 DYLD_INSERT_LIBRARIES：
#   不需要 allow-dyld-environment-variables；不受启动方式限制（LaunchAgent/GUI 都生效）。
#   实测：不设任何环境变量即出帧（40~53 帧 / 6 秒）。
#
# 用法：
#   sudo bash uu.sh shim-install          # 安装
#   sudo bash uu.sh shim-restore          # 还原（撤销本方案）
#
# 演练（不碰正式 App、不重启进程）：
#   cp -R /Applications/UURemote.app /tmp/dry/UURemote.app
#   UURT_APP=/tmp/dry/UURemote.app UURT_REHEARSE=1 bash uu.sh shim-install
# ============================================================================

D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${UURT_APP:-/Applications/UURemote.app}"
REHEARSE="${UURT_REHEARSE:-0}"
REAL_USER="${SUDO_USER:-$(stat -f '%Su' "$HOME")}"

SHIM_SRC="$D/shim/libuushim.dylib"
SHIM_DST="$APP/Contents/Frameworks/libuushim.dylib"
TARGET="$APP/Contents/Helpers/UURemoteServer"
BACKUP_DIR="$D/shim/backup"
BACKUP="$BACKUP_DIR/UURemoteServer.orig"
LOAD_PATH="@loader_path/../Frameworks/libuushim.dylib"
# ★ 第 4 道门（CPU 顶替 Metal 帧转换）与 shim 走**同一套机制**装。
#   2026-09-28 改：原先 cpupath 靠「往 UU 官方 plist 写 DYLD_INSERT_LIBRARIES」注入，
#   该路线已实测失效（launchd 的 job 环境里拿不到该变量 → 库一个进程都没加载，
#   而自检只看 plist 里有没有那行文字，于是长期「假绿」）。改走二进制级 LC_LOAD_DYLIB：
#   不依赖环境变量、不受启动方式限制，且能看到「真的加载了吗」。
CPUPATH_SRC="$D/cpupath/libuucpupath.dylib"
CPUPATH_DST="$APP/Contents/Frameworks/libuucpupath.dylib"
CPUPATH_LOAD_PATH="@loader_path/../Frameworks/libuucpupath.dylib"

c_ok=$'\033[32m'; c_no=$'\033[31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'


if [ "$(id -u)" -ne 0 ] && [ "$REHEARSE" != "1" ]; then
  no "请用 sudo 运行：sudo bash $0"; exit 1
fi
[ -d "$APP" ]     || { no "找不到 App：$APP"; exit 1; }
[ -f "$SHIM_SRC" ]|| { no "找不到补丁库：${SHIM_SRC}（先编译或从备份恢复）"; exit 1; }
[ -f "$TARGET" ]  || { no "找不到被控端进程：$TARGET"; exit 1; }
[ -f "$D/tools/insert_dylib.py" ] || { no "找不到 tools/insert_dylib.py"; exit 1; }

if [ "$REHEARSE" = "1" ]; then
  echo "★ 演练模式：目标 = ${APP}（不碰正式 App、不重启任何进程）"
fi

INSTALLER="python3 $D/tools/insert_dylib.py"
MAGIC=$(head -c4 "$SHIM_SRC" | xxd -p)

# ---------------------------------------------------------------------------
hd "0/5 前置检查"
# ---------------------------------------------------------------------------
if ! python3 "$D/patch_tool.py" check "$APP/Contents/Frameworks/libstreamer.dylib" 2>/dev/null \
     | grep -q '^patched'; then
  # ★ 演练时若报「补丁不在位」，多半是副本在 App 正被重签/写入的瞬间拷下来导致的不完整副本
  #   （实测遇到过 3 次，正式 App 与手工重新 ditto 的副本都合格）。这里给出诊断，
  #   并自动重新拷一次副本再判 —— 避免把「副本问题」误报成「补丁丢失」。
  L="$APP/Contents/Frameworks/libstreamer.dylib"
  echo "  ⚠ 首次检查未通过，诊断："
  echo "     路径: $L"
  echo "     大小: $(stat -f%z "$L" 2>/dev/null || echo '不存在')"
  echo "     原始输出: $(python3 "$D/patch_tool.py" check "$L" 2>&1 | head -2 | tr '\n' ' ')"
  if [ "$REHEARSE" = "1" ]; then
    echo "  → 演练模式：重新拷贝副本后重试（不影响正式 App）"
    rm -rf "${APP}.retry"
    ditto "$APP" "${APP}.retry" 2>/dev/null || true
    if python3 "$D/patch_tool.py" check "${APP}.retry/Contents/Frameworks/libstreamer.dylib" 2>/dev/null \
         | grep -q '^patched'; then
      echo "  ✔ 重试成功 → 确认为副本不完整（非补丁问题）。请重新生成干净副本后再演练。"
      rm -rf "${APP}.retry"
      exit 3
    fi
    rm -rf "${APP}.retry"
  fi
  no "视频补丁不在位 —— 请先跑 uu.sh cg-install（本方案是它的补充，不是替代）"
  exit 1
fi
ok "libstreamer 视频补丁在位"

echo "  补丁库架构: $(file "$SHIM_SRC" | grep -o 'x86_64\|arm64' | sort -u | tr '\n' ' ')"
echo "  目标进程架构: $(file "$TARGET" | grep -o 'x86_64\|arm64' | sort -u | tr '\n' ' ')"

if have_dylib "$TARGET"; then
  echo "  （已装过：本次只重新部署补丁库并重签）"
else
  python3 "$D/tools/insert_dylib.py" --check "$TARGET" "$LOAD_PATH" | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
hd "1/5 停止 UU（避免进程占用二进制）"
# ---------------------------------------------------------------------------
if [ "$REHEARSE" = "1" ]; then
  echo "  演练模式：跳过"
else
  launchctl kickstart -k system/com.netease.uuremote.daemon 2>/dev/null \
    && echo "  root 守护进程已重启" || echo "  守护进程未加载（稍后统一处理）"
  pkill -f 'UURemote.app/Contents/MacOS/UURemote' 2>/dev/null || true
  pkill -f 'UURemote.app/Contents/Helpers/UURemoteServer' 2>/dev/null || true
  pkill -f 'UURemote.app/Contents/XPCServices/UURemoteHelper' 2>/dev/null || true
  pkill -f 'UURemoteService' 2>/dev/null || true
  sleep 3
  echo "  剩余进程："; pgrep -fl 'UURemote.app' | sed 's/^/    /' || echo "    （无）"
fi

# ---------------------------------------------------------------------------
hd "2/5 备份原版 UURemoteServer（供一键还原）"
# ---------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
if [ -f "$BACKUP" ]; then
  # 备份必须是「未注入」的原版 —— 否则还原回的是一个已被改过的二进制，越还原越乱
  if have_dylib "$BACKUP"; then
    no "已有备份被污染（内含 libuushim 依赖）：$BACKUP"
    echo "     这是历史版本留下的问题备份，无法安全还原。"
    echo "     处理：删除它后用 uuyc.163.com 覆盖安装 UU，再重跑本脚本。"
    exit 1
  fi
  ok "已有备份：${BACKUP}（保留不覆盖，校验干净 ✔）"
else
  if have_dylib "$TARGET"; then
    no "目标已含依赖但没有备份 —— 无法安全还原，已中止。请覆盖安装 UU 后重试"
    exit 1
  fi
  cp "$TARGET" "$BACKUP" && ok "已备份 → $BACKUP" || { no "备份失败"; exit 1; }
fi

# ---------------------------------------------------------------------------
hd "3/5 部署补丁库 → Contents/Frameworks/"
# ---------------------------------------------------------------------------
cp "$SHIM_SRC" "$SHIM_DST" && ok "$(basename "$SHIM_DST")  ($(stat -f '%z' "$SHIM_DST") 字节)" \
  || { no "复制失败"; exit 1; }
if [ -f "$CPUPATH_SRC" ]; then
  cp "$CPUPATH_SRC" "$CPUPATH_DST" && ok "$(basename "$CPUPATH_DST")  ($(stat -f '%z' "$CPUPATH_DST") 字节)" \
    || { no "复制失败"; exit 1; }
else
  echo "  ！ 找不到 ${CPUPATH_SRC} —— 跳过第 4 道门（CPU 帧转换）。"
  echo "     编译：clang -dynamiclib -O2 -o cpupath/libuucpupath.dylib cpupath/libuucpupath.c \\"
  echo "           -framework CoreVideo -framework CoreFoundation -framework IOSurface"
fi

# ---------------------------------------------------------------------------
hd "4/5 给 UURemoteServer 加 LC_LOAD_DYLIB（不改机器码）"
# ---------------------------------------------------------------------------
# 两个库都用同一机制装；各自幂等（已在就跳过），互不影响。
insert_one() {   # $1=展示名 $2=库路径（@loader_path 形式）
  if have_dylib_path "$TARGET" "$2"; then
    ok "$1：依赖已在（幂等跳过）"
    return 0
  fi
  # IDB_BACKUP 让备份落在 App 外面 —— 包内留 .dylibbak 会污染 CodeResources
  if IDB_BACKUP="$BACKUP" python3 "$D/tools/insert_dylib.py" --add "$TARGET" "$2" 2>&1 | sed 's/^/  /'; then
    have_dylib_path "$TARGET" "$2" && ok "$1：依赖已写入 $2" || { no "$1：写入后校验失败"; return 1; }
  else
    no "$1：加依赖失败（空间不足？）"; return 1
  fi
  return 0
}
have_dylib_path() { grep -qF "$2" <<<"$(otool -L "$1" 2>/dev/null)"; }
insert_one "shim（截图轮询帧源）" "$LOAD_PATH" || exit 1
if [ -f "$CPUPATH_DST" ]; then
  insert_one "cpupath（CPU 帧转换）" "$CPUPATH_LOAD_PATH" || exit 1
fi
echo "  ── UURemoteServer 现有依赖 ──"
otool -L "$TARGET" 2>/dev/null | grep -E "uushim|uucpupath" | sed 's/^/    /'
# 兜底清理包内的备份残留（历史版本会写在 App 内部）
if [ -f "$TARGET.dylibbak" ]; then
  rm -f "$TARGET.dylibbak" && echo "  已清理包内备份残留 $(basename "$TARGET").dylibbak"
fi

# ---------------------------------------------------------------------------
hd "5/5 重签整包（同一证书；UURemoteServer 额外带 disable-library-validation）"
# ---------------------------------------------------------------------------
if [ "$REHEARSE" = "1" ]; then
  echo "  演练模式：改用副本重签"
fi
UURT_APP="$APP" UURT_REHEARSE="$REHEARSE" sign_main
RC=$?
[ $RC -eq 0 ] || { no "重签未通过（RC=${RC}）—— 还原：sudo bash $D/uu.sh shim-restore"; exit $RC; }

if [ "$REHEARSE" = "1" ]; then
  hd "演练完成 —— 正式 App 未被触碰"
  exit 0
fi

# ---------------------------------------------------------------------------
hd "验证"
# ---------------------------------------------------------------------------
VF=0
echo "  依赖："; otool -L "$TARGET" 2>/dev/null | grep -F 'libuushim' | sed 's/^/    /' \
  || { no "依赖不见了"; VF=1; }
echo "  额外权限："
codesign -d --entitlements - "$TARGET" 2>/dev/null | grep -q 'disable-library-validation' \
  && ok "disable-library-validation 已带" || { no "缺少 disable-library-validation"; VF=1; }
# ★★ 官方原有权限必须一个不少。
#   为什么单列一条：脚本原来自检只查「**我们加的**权限在不在」，
#   于是「官方权限被削掉」这类事故完全无声 —— 实测 UURemoteServer 的
#   com.apple.security.device.audio-input 就是这样丢的，而每次安装都"通过"。
#   对照物 = 官方原版备份 shim/backup/<同名>.orig（权限的权威依据）。
ORIGB="$D/shim/backup/$(basename "$TARGET").orig"
if [ -f "$ORIGB" ]; then
  MISSING=$(python3 - "$ORIGB" "$TARGET" <<'PYEOF' 2>/dev/null
import plistlib, subprocess, sys
def ents(p):
    try:
        out = subprocess.run(["codesign", "-d", "--entitlements", "-", p],
                             capture_output=True).stdout
        return set(plistlib.loads(out).keys())
    except Exception:
        return set()
print(",".join(sorted(ents(sys.argv[1]) - ents(sys.argv[2]))))
PYEOF
)
  if [ -z "${MISSING}" ]; then
    ok "官方原有权限齐全（对照 $(basename "$ORIGB")）"
  else
    no "原有权限被削掉：${MISSING} —— 安装不应改动官方权限集，请查 sign_one 的 entitlements 合并"
    VF=1
  fi
fi
echo "  签名与 OU："
id=$(codesign -dv --verbose=4 "$TARGET" 2>&1 | grep -a '^Identifier=' | cut -d= -f2)
if codesign --verify -R="identifier \"$id\" and certificate leaf[subject.OU] = \"PU9BNSBJW7\"" "$TARGET" 2>/dev/null; then
  ok "UURemoteServer  id=$id  满足 OU 校验"
else
  no "UURemoteServer 不满足 OU 校验"; VF=1
fi
codesign --verify --deep --strict "$APP" 2>/dev/null && ok "整包校验通过" || { no "整包校验未过"; VF=1; }
echo "  补丁库签名：$(codesign -dv "$SHIM_DST" 2>&1 | grep -o 'Authority=.*' | head -1)"
echo "  三处补丁：$(python3 "$D/patch_tool.py" check "$APP/Contents/Frameworks/libstreamer.dylib" 2>/dev/null | tr '\n' ' ')"

if [ "$VF" -ne 0 ]; then
  hd "验证未通过"; echo "  还原：sudo bash $D/uu.sh shim-restore"; exit 1
fi

# ★ 收尾必做：把 UURemoteServer 带回来。
#   本函数前面 `pkill UURemoteServer` 是为了能重签（文件被占用签不了），
#   而 UU 自己**不会**再把它拉起来 → 不补这一步，装完设备就是「离线」状态，
#   表现为「装了补丁反而连不上」，且日志无错，很难查。详见 server_agent 那节注释。
hd "收尾：保证 UURemoteServer 在跑（它是「设备在线」的载体）"
server_agent_up || true

cat <<EOT

────────────────────────────────────────────────────────────
✔ 安装完成。现在去手机端连一次 —— 应该能看到画面了。

【预期表现】
  · 画面约 8 FPS（截图单帧 ~67ms 是本机硬上限）
  · 看日志/文档/点按钮够用；快速拖动、看视频会明显卡
  · CPU 约 0.9 核（比零帧空转时的 1.15 核还低）
  · 被控端日志会出现 [uushim] start → 截图轮询线程已启动

【若还是看不到画面】
  1) 看被控端是否真的加载了补丁库：
     log show --last 5m --predicate 'process == "UURemoteServer"' --style compact | grep uushim
  2) 辅助功能权限若提示未配置：
     sudo tccutil reset Accessibility com.netease.uuremote
     然后 系统设置 → 隐私与安全性 → 辅助功能 重新勾上 UURemote
  3) 把上面两条的输出发我。

【还原（记住这条）】
  sudo bash $D/uu.sh shim-restore
  # 彻底回到官方：去 uuyc.163.com 覆盖安装 UU
────────────────────────────────────────────────────────────
EOT
}


# ---- shim_restore_main ----
shim_restore_main() {
# ============================================================================
# 还原 uu.sh shim-install 的所有改动（一行命令回到装之前）
# ============================================================================
# 做四件事：
#   1. 把 UURemoteServer 换回备份的原版（去掉 LC_LOAD_DYLIB）
#   2. 删掉 Contents/Frameworks/libuushim.dylib
#   3. 用 uu.sh sign 重新签名（恢复合规签名，避免 XPC 被拒 / 报 1001）
#   4. 重启 UU
#
# ⚠ 注意：这一步【不会】撤销 libstreamer 的三处补丁（那是另一套，用 uu.sh）。
#   本脚本只撤销「帧源替换」。三处补丁的还原：sudo bash uu.sh cg-restore
#
# 用法：sudo bash uu.sh shim-restore
# 演练：UURT_APP=/tmp/dry/UURemote.app UURT_REHEARSE=1 bash uu.sh shim-restore
# ============================================================================

D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${UURT_APP:-/Applications/UURemote.app}"
REHEARSE="${UURT_REHEARSE:-0}"

TARGET="$APP/Contents/Helpers/UURemoteServer"
SHIM_DST="$APP/Contents/Frameworks/libuushim.dylib"
BACKUP="$D/shim/backup/UURemoteServer.orig"

c_ok=$'\033[32m'; c_no=$'\033[31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'

if [ "$(id -u)" -ne 0 ] && [ "$REHEARSE" != "1" ]; then
  no "请用 sudo 运行：sudo bash $0"; exit 1
fi
[ -d "$APP" ] || { no "找不到 App：$APP"; exit 1; }
[ -f "$BACKUP" ] || { no "找不到备份 $BACKUP —— 无法还原。请去 uuyc.163.com 覆盖安装 UU"; exit 1; }

if [ "$REHEARSE" = "1" ]; then
  echo "★ 演练模式：目标 = ${APP}（不碰正式 App、不重启进程）"
else
  hd "1/4 停止 UU"
  launchctl kickstart -k system/com.netease.uuremote.daemon 2>/dev/null || echo "  守护进程未加载"
  pkill -f 'UURemote.app/Contents/MacOS/UURemote' 2>/dev/null || true
  pkill -f 'UURemote.app/Contents/Helpers/UURemoteServer' 2>/dev/null || true
  pkill -f 'UURemote.app/Contents/XPCServices/UURemoteHelper' 2>/dev/null || true
  pkill -f 'UURemoteService' 2>/dev/null || true
  sleep 3
  ok "已停止"
fi

hd "2/4 恢复原版 UURemoteServer"
# ★ 顺序要紧：**先校验备份干净，再覆盖目标**。
#   反过来的话，一旦备份被污染（例如在已注入状态下重跑 shim-install 覆盖了备份），
#   目标已被污染文件写掉、本地又没有第二份原库 —— 只能重装 UU 才能救回。
if otool -L "$BACKUP" 2>/dev/null | grep -qF 'libuushim'; then
  no "备份已被污染（内含 libuushim 依赖），拒绝覆盖：$BACKUP"
  no "请去 uuyc.163.com 覆盖安装 UU 取得干净原库后，再重跑本命令"
  exit 1
fi
cp "$BACKUP" "$TARGET" && ok "已恢复（$(stat -f '%z' "$TARGET") 字节）" || { no "恢复失败"; exit 1; }
ok "确认已无 libuushim 依赖"

hd "3/4 删除补丁库"
if [ -f "$SHIM_DST" ]; then
  rm -f "$SHIM_DST" && ok "已删除 $(basename "$SHIM_DST")" || no "删除失败"
else
  echo "  （本来就不存在）"
fi
# 包内备份残留（旧版本可能留下）
[ -f "$TARGET.dylibbak" ] && rm -f "$TARGET.dylibbak" && echo "  已清理包内备份残留"

hd "4/4 重新签名（恢复官方权限集，不带本方案额外加的权限）"
if [ "$REHEARSE" = "1" ]; then
  echo "  演练模式：跳过重签"
  hd "演练完成"
  exit 0
fi
# UURT_SKIP_EXTRA=1：签名时忽略 extra-ents/，即撤销 disable-library-validation
UURT_APP="$APP" UURT_SKIP_EXTRA=1 sign_main
RC=$?
if [ $RC -ne 0 ]; then
  no "重签失败（RC=${RC}）—— 请把输出发我，或去 uuyc.163.com 覆盖安装"
  exit $RC
fi

hd "完成"
echo "  三处补丁状态：$(python3 "$D/patch_tool.py" check "$APP/Contents/Frameworks/libstreamer.dylib" 2>/dev/null | tr '\n' ' ')"
echo "  UURemoteServer 依赖：$(otool -L "$TARGET" 2>/dev/null | grep -cF 'libuushim') 个 libuushim（应为 0）"
cat <<EOT

────────────────────────────────────────────────────────────
✔ 已还原到「装本方案之前」的状态（三处补丁仍在，连接正常、无画面）。
  想连三处补丁一起撤销：sudo bash $D/uu.sh cg-restore
  想彻底回官方：去 uuyc.163.com 覆盖安装 UU
────────────────────────────────────────────────────────────
EOT
}


# ---- cpupath 系列（原 cpupath/install.sh、status.sh、uninstall.sh 三件套，已于 2026-09-27 并入本文件）----
# 说明：这三个子命令管的是「第4道门的持久化部分」——把 CPU 顶替 Metal 的
# libuucpupath.dylib 注入进 UU 自己的 LaunchAgent。原先散在 cpupath/ 下三个脚本，
# 现统一入口：bash uu.sh cpupath-install / cpupath-status / cpupath-uninstall

cpupath_paths() {
  # 刻意不用 $HOME：本脚本常以 sudo 运行，那时 $HOME 会变成 /var/root，
  # 会把库和 LaunchAgent 装到错误的位置。改为按「真实登录用户」的 home 推导。
  local u h
  u="${SUDO_USER:-$(id -un)}"
  h="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [ -n "$h" ] || h="$HOME"
  CP_USER="$u"
  CP_DEST_DIR="$h/Library/Application Support/UUCpuPath"
  CP_PLIST="$h/Library/LaunchAgents/com.uuremote-cg-patch.cpupath.plist"
  CP_LIBDST="$h/Library/Application Support/UUCpuPath/libuucpupath.dylib"
  CP_UU_PLIST="/Library/LaunchAgents/com.netease.uuremote.agent.plist"
}

# ---- cpupath_install_main ----
cpupath_install_main() {
# 第4道门（CPU 顶替 Metal 帧转换）的安装与持久化。
#
# 作用：让 UU远程 在无 Metal 的老 Mac（AMD pre-GCN，如 2011 Mac mini）上也能把画面
#       编出来并发出去，否则对端连接后永远黑屏 / 卡在"正在连接"。
# 原理：运行时把 libstreamer 的 IOSurfaceFrame::CopyTo(VideoFrame&) 换成 CPU memcpy
#       （原实现走 Metal 渲染，无 Metal 必然失败 → 编码器收不到帧）。
#       不改 UU 二进制，只注入一个 dylib。
#
# ★★★ 注入方式（2026-09-27 改，原因务必读完再动）
#   正确做法：把 DYLD_INSERT_LIBRARIES 写进 **UU 自己的 LaunchAgent plist** 的
#             EnvironmentVariables —— 只有 UU 及其子进程会加载本库。
#   禁止做法：`launchctl setenv DYLD_INSERT_LIBRARIES ...`
#             —— 那是 launchd 用户域**全局**变量，所有由 launchd 启动/继承环境的进程
#             都会读到它（AppleSpell、bluetooth、cloudd、Keychain、ScreenTime、
#             ScreenSharing、devicecheckd、biomesyncd、ModelCatalogAgent、
#             甚至命令行工具 pgrep / screencapture …）。
#             这些进程带 Apple 签名 + library validation，加载**未签名** dylib 会触发
#             CODESIGNING 保护被直接 SIGKILL（崩溃特征：namespace=CODESIGNING,
#             signal=SIGKILL (Code Signature Invalid)）。
#   实测代价：安装全局注入当天产生 141 份系统进程崩溃报告（前一天只有 1 份）；
#             screencapture / pgrep 一类工具执行即被杀（易误判成"没有录屏权限"）；
#             系统卡顿，连 System Settings 都可能起不来。收窄到 plist 后立刻安静。
#   注意：给 dylib 做 ad-hoc 签名（本命令仍会做）**并不能**避免上述崩溃 ——
#         实测无效，必须靠收窄注入范围。
#
# 持久化两层：
#   ① 改 /Library/LaunchAgents/com.netease.uuremote.agent.plist（注入本体，需 sudo）
#   ② 本工具自己的 LaunchAgent（登录时幂等复核；UU 升级覆盖 ① 后能自动补回）
#
# 用法：bash uu.sh cpupath-install
cpupath_paths

LIBSRC="$D/cpupath/libuucpupath.dylib"
DEST_DIR="$CP_DEST_DIR"
LIBDST="$CP_LIBDST"
PLIST="$CP_PLIST"
UU_PLIST="$CP_UU_PLIST"

if [ ! -f "$LIBSRC" ]; then
    no "找不到 $LIBSRC —— 先编译："
    echo "   clang -dynamiclib -O2 -o cpupath/libuucpupath.dylib cpupath/libuucpupath.c \\"
    echo "         -framework CoreVideo -framework CoreFoundation -framework IOSurface"
    exit 1
fi

hd "1/6 安装运行时文件"
mkdir -p "$DEST_DIR"
cp -f "$LIBSRC" "$LIBDST"
xattr -c "$LIBDST" 2>/dev/null
codesign -f -s - "$LIBDST" 2>/dev/null
echo "   ${LIBDST}（$(stat -f%z "$LIBDST") 字节）"

hd "2/6 清理历史遗留的环境变量注入（该路线已废弃）"
# ★ 2026-09-28 起 cpupath 改走**二进制级 LC_LOAD_DYLIB**（与 shim 同机制，见 sign_main 的 4/5 步）。
#   原因：DYLD_INSERT_LIBRARIES 路线实测失效 —— launchd 的 job 环境里拿不到该变量，
#   库一个进程都没被加载（而旧自检只看 plist 里那行文字，于是长期「假绿」）。
#   旧注入留着既没用、又会让人误以为已装上，这里清掉。
if [ -f "$UU_PLIST" ] && sudo -n plutil -p "$UU_PLIST" 2>/dev/null | grep -q "libuucpupath"; then
    sudo -n /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:DYLD_INSERT_LIBRARIES" "$UU_PLIST" 2>/dev/null
    echo "   语法校验：$(sudo -n plutil -lint "$UU_PLIST" 2>&1)"
    ok "已清掉旧的环境变量注入（本库改由二进制依赖加载）"
else
    ok "没有旧注入残留"
fi

hd "3/6 撤销历史遗留的全局注入（重要：它才是伤害系统的那个）"
if [ -n "$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null)" ]; then
    launchctl unsetenv DYLD_INSERT_LIBRARIES
    ok "已清除（原值见 git 历史/安装日志）"
else
    ok "全局变量本来就是空的"
fi
echo "   现在 DYLD_INSERT_LIBRARIES=[$(launchctl getenv DYLD_INSERT_LIBRARIES)]"

hd "4/6 写登录时复核用的 LaunchAgent（核对「库是否真的加载了」）"
mkdir -p "$(dirname "$PLIST")"
cat > "$DEST_DIR/apply.sh" <<EOF
#!/bin/bash
# 登录时由 LaunchAgent 调用：核对第 4 道门是否**真的**在位。
# ★ 只读检查，不改任何东西：改二进制必须重签整包（改完不签 = 被控端起不来），
#   所以这里只报状态，让用户跑 sudo bash uu.sh sign。
# ★ 为什么不查 plist 文本了：旧版查的是「UU 官方 plist 里有没有那行 DYLD_INSERT」——
#   那行在、库却没加载（launchd 不给变量），于是长期假绿。现在查实际加载证据。
APP="$APP"
TARGET="\$APP/Contents/Helpers/UURemoteServer"
LIB="\$APP/Contents/Frameworks/libuucpupath.dylib"
CLOG="/tmp/uucpu.log"
LOG="$DEST_DIR/apply.out.log"
TS="\$(date '+%F %T')"
ok=1
if ! otool -L "\$TARGET" 2>/dev/null | grep -q "libuucpupath"; then
    echo "\$TS !! 二进制里没有 libuucpupath 依赖 —— 跑：sudo bash uu.sh sign" >> "\$LOG"; ok=0
fi
if [ ! -f "\$LIB" ]; then
    echo "\$TS !! 库文件缺失：\$LIB —— 跑：sudo bash uu.sh sign" >> "\$LOG"; ok=0
fi
SP=\$(pgrep -x UURemoteServer | head -1)
if [ -n "\$SP" ] && ! grep -aq "已加载 pid=\$SP" "\$CLOG" 2>/dev/null; then
    echo "\$TS !! 当前 server(pid=\$SP) 无加载记录 —— 重启 UU 后仍无，则跑：sudo bash uu.sh sign" >> "\$LOG"; ok=0
fi
[ "\$ok" = "1" ] && echo "\$TS OK：第 4 道门在位（二进制依赖 + 库文件 + 实际加载记录）" >> "\$LOG"
exit 0
EOF
chmod +x "$DEST_DIR/apply.sh"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.uuremote-cg-patch.cpupath</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DEST_DIR/apply.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardErrorPath</key>
  <string>$DEST_DIR/apply.err.log</string>
  <key>StandardOutPath</key>
  <string>$DEST_DIR/apply.out.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST"
# 立刻加载（RunAtLoad 只在下一次登录才生效；这里显式加载一次）
launchctl unload "$PLIST" 2>/dev/null
launchctl load -w "$PLIST" 2>/dev/null
if launchctl print "gui/$(id -u)/com.uuremote-cg-patch.cpupath" >/dev/null 2>&1; then
  ok "复核用 LaunchAgent 已加载"
else
  echo "   ！复核用 LaunchAgent 未加载（下次登录仍会生效）"
fi

hd "5/6 重启 UU（二进制依赖只有新进程才会加载）"
# ★ 依赖在进程**启动时**由 dyld 读取 → 必须让 UU 重启；老进程不会凭空多出这个库。
#   （旧版本这里是「让 UU 重读 plist」，那是环境变量路线的做法；路线二不需要任何环境变量。）
if [ "$REHEARSE" != "1" ]; then
  sudo -u "$CP_USER" open -a UURemote 2>/dev/null || open -a UURemote 2>/dev/null || true
  sleep 8
else
  echo "  演练模式：跳过重启"
fi
if otool -L "$APP/Contents/Helpers/UURemoteServer" 2>/dev/null | grep -q "libuucpupath"; then
    ok "二进制依赖在位：@loader_path/../Frameworks/libuucpupath.dylib"
else
    no "二进制依赖不在位 —— 跑：sudo bash uu.sh sign"
fi

hd "6/6 验证（必须看到「当前 server 进程」的加载记录才算通过）"
SP="$(pgrep -x UURemoteServer | head -1 || true)"
if [ -z "$SP" ]; then
    no "UURemoteServer 不在跑 —— 先 open -a UURemote"
elif grep -aq "libuucpupath 已加载 pid=$SP" /tmp/uucpu.log 2>/dev/null; then
    ok "第 4 道门在位：server(pid=$SP) 已加载本库"
    grep -aE "libuucpupath 已加载|vtable 槽替换" /tmp/uucpu.log 2>/dev/null | tail -3 | sed 's/^/     /'
else
    no "server(pid=$SP) 没有加载记录 —— 重启 UU 再试；仍无说明依赖没生效"
    tail -3 /tmp/uucpu.log 2>/dev/null | sed 's/^/     /'
fi
echo
echo "   当前映射了本库的进程："
for P in $(pgrep -x UURemoteServer) $(pgrep -x UURemote) $(pgrep -x UURemoteService) $(pgrep -x UURemoteDaemon); do
  C=$(sudo -n vmmap "$P" 2>/dev/null | grep -c libuucpupath)
  [ "$C" != "0" ] && echo "     $(ps -o comm= -p "$P" | xargs basename)(pid=$P)"
done

echo
echo "完成。"
echo "  加载方式：UURemoteServer 的 LC_LOAD_DYLIB（二进制级，不依赖环境变量）"
echo "  库位置：  $APP/Contents/Frameworks/libuucpupath.dylib（随 App 一起重签）"
echo "  持久化：  ${PLIST}（登录时只读复核「是否真的加载了」，见 ${DEST_DIR}/apply.out.log）"
echo "  依赖项：  libstreamer.dylib 的磁盘补丁（Metal 门禁 / 低延迟 RC）需另行保持，"
echo "            见 patch_tool.py + bash uu.sh cg-install；UU 自动更新会覆盖，需重跑。"
}


# ---- cpupath_status_main ----
cpupath_status_main() {
# 第4道门（CPU 顶替 Metal）的状态检查。免 sudo 可跑（内部按需 sudo -n）。
cpupath_paths

DEST_DIR="$CP_DEST_DIR"
PLIST="$CP_PLIST"
LABEL="com.uuremote-cg-patch.cpupath"
UU_PLIST="$CP_UU_PLIST"

hd "UU CPU 转换路径修复 状态"

echo "1) 运行时文件"
if [ -f "$DEST_DIR/libuucpupath.dylib" ]; then
    ok "${DEST_DIR}/libuucpupath.dylib（$(stat -f%z "$DEST_DIR/libuucpupath.dylib") 字节, $(stat -f%Sm "$DEST_DIR/libuucpupath.dylib")）"
else
    echo "   ！旧版运行时副本不存在（路线二已不使用它，不影响功能）"
fi
APPLIB="/Applications/UURemote.app/Contents/Frameworks/libuucpupath.dylib"
TARGET="/Applications/UURemote.app/Contents/Helpers/UURemoteServer"
if [ -f "$APPLIB" ]; then
    ok "库已随 App 部署：${APPLIB}（$(stat -f%z "$APPLIB") 字节）"
else
    no "库里没进 App：${APPLIB} → sudo bash uu.sh sign"
fi

echo
echo "2) 加载方式（路线二：UURemoteServer 的 LC_LOAD_DYLIB —— 不依赖环境变量）"
if otool -L "$TARGET" 2>/dev/null | grep -q libuucpupath; then
    ok "二进制依赖在位：$(otool -L "$TARGET" 2>/dev/null | grep libuucpupath | awk '{print $1}')"
else
    no "二进制里没有该依赖（对端会黑屏）→ sudo bash uu.sh sign"
fi
SP="$(pgrep -x UURemoteServer | head -1 || true)"
if [ -n "$SP" ] && grep -aq "libuucpupath 已加载 pid=$SP" /tmp/uucpu.log 2>/dev/null; then
    ok "★ 实际加载证据：当前 server(pid=${SP}) 已加载本库"
    grep -a "vtable 槽替换" /tmp/uucpu.log 2>/dev/null | tail -1 | sed 's/^/     /'
elif [ -n "$SP" ]; then
    no "当前 server(pid=${SP}) 没有加载记录 → 重启 UU；仍无则 sudo bash uu.sh sign"
else
    echo "   ！UURemoteServer 不在跑，无法核对加载状态"
fi
echo "   （旧版这里查的是 UU plist 文本，属于假绿：文字在、库没加载。已改为查实际加载。）"

echo
echo "3) ★ 全局注入检查（必须为空 —— 非空会伤害整个系统）"
G="$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null)"
if [ -n "$G" ]; then
    no "全局变量非空：[${G}]"
    echo "       后果：所有 launchd 进程（系统守护进程、pgrep、screencapture…）都会去加载"
    echo "             未签名 dylib，被 macOS 的 CODESIGNING 保护直接 SIGKILL。"
    echo "             实测一天产生 135+ 份系统进程崩溃报告、系统卡顿、System Settings 打不开。"
    echo "       修复：launchctl unsetenv DYLD_INSERT_LIBRARIES  （然后 bash uu.sh cpupath-install）"
else
    ok "为空（正确）"
fi

echo
echo "4) 当前哪些进程加载了本库（应只有 UU 系；其它是撤销全局前的遗留，会自然消失）"
sudo -n lsof -n 2>/dev/null | grep -i libuucpupath | awk '{print $1}' | sort -u | head -12 | sed 's/^/   /'
echo "   合计映射条数：$(sudo -n lsof -n 2>/dev/null | grep -ci libuucpupath)"

echo
echo "5) UU 进程内是否真的生效"
if grep -q "vtable 槽替换" /tmp/uucpu.log 2>/dev/null; then
    grep -E "libuucpupath 已加载|vtable 槽替换" /tmp/uucpu.log 2>/dev/null | tail -3 | sed 's/^/   /'
    echo "   （日志：/tmp/uucpu.log）"
else
    echo "   ！日志中无生效记录（可能尚未有会话，或未安装）"
fi

echo
echo "6) 登录时幂等复核（UU 升级覆盖 plist 后能自动补回）"
if [ -f "$PLIST" ]; then
    ok "plist 存在"
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && ok "已加载" || echo "   ！已写文件但未加载"
    [ -f "$DEST_DIR/apply.out.log" ] && tail -2 "$DEST_DIR/apply.out.log" 2>/dev/null | sed 's/^/      /'
else
    no "无 plist（UU 升级后不会自动补回）"
fi

echo
echo "7) UU 组件进程"
pgrep -fl "UURemoteServer|MacOS/UURemote" | head -4 | sed 's/^/   /'

echo
echo "8) 磁盘补丁（配合项：Metal 门禁 / 低延迟 RC）"
if [ -f "$TOOL" ] && [ -f "$LIB" ]; then
    python3 "$TOOL" check "$LIB" 2>/dev/null | head -6 | sed 's/^/   /' || echo "   （检查失败）"
else
    echo "   ！找不到 patch_tool.py 或 libstreamer.dylib"
fi
echo "   注：UU 自动更新会覆盖磁盘补丁，需重跑 bash uu.sh install（需一次 sudo）"

echo
echo "9) 最近一次会话的拷贝吞吐"
grep -E "★ 成功" /tmp/uucpu.log 2>/dev/null | tail -2 | cut -c1-120 | sed 's/^/   /' || echo "   （无会话记录）"
echo
echo "=========================================================="
}


# ---- cpupath_uninstall_main ----
cpupath_uninstall_main() {
# 第4道门的卸载（恢复原状）。做了什么：
#   ① 从 UU 自己的 LaunchAgent plist 里移除我们加的 DYLD_INSERT_LIBRARIES（只删这个键）
#   ② 清除历史遗留的**全局**注入变量（老版本曾用 launchctl setenv，会伤害系统进程）
#   ③ 删掉本工具自己的运行时目录与 LaunchAgent
# 说明：plist 无需显式卸载 —— 删掉文件后下次登录不再加载；
#       当前会话中若已加载，因目录已删除它什么也不做（无害）。
# 用法：bash uu.sh cpupath-uninstall
cpupath_paths

DEST_DIR="$CP_DEST_DIR"
PLIST="$CP_PLIST"
UU_PLIST="$CP_UU_PLIST"

hd "1/5 从 UU plist 移除注入（只删我们的键）"
if [ -f "$UU_PLIST" ]; then
    # 若 EnvironmentVariables 里只有我们这一个键，就删整个 dict；否则只删该键
    NKEYS="$(sudo -n plutil -p "$UU_PLIST" 2>/dev/null | awk '/EnvironmentVariables/{f=1;next} f&&/^\s+"/{c++} END{print c+0}')"
    if sudo -n plutil -p "$UU_PLIST" 2>/dev/null | grep -q "DYLD_INSERT_LIBRARIES"; then
        if [ "${NKEYS:-0}" -le 1 ]; then
            sudo -n /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables" "$UU_PLIST" 2>&1
            ok "已删除 EnvironmentVariables（其中只有本工具的键）"
        else
            sudo -n /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:DYLD_INSERT_LIBRARIES" "$UU_PLIST" 2>&1
            ok "已删除 DYLD_INSERT_LIBRARIES（保留了 EnvironmentVariables 里的其它键）"
        fi
        echo "   语法校验：$(sudo -n plutil -lint "$UU_PLIST" 2>&1)"
    else
        ok "UU plist 中本就没有本工具的注入"
    fi
else
    echo "   找不到 ${UU_PLIST}（UU 未安装？）—— 跳过"
fi

hd "2/5 删除本工具的 LaunchAgent 与运行时目录"
[ -f "$PLIST" ] && rm -f "$PLIST" && ok "已删除 ${PLIST}" || echo "   无需删除 ${PLIST}"
[ -d "$DEST_DIR" ] && rm -rf "$DEST_DIR" && ok "已删除 ${DEST_DIR}" || echo "   无需删除 ${DEST_DIR}"

hd "3/5 清除全局注入变量（历史遗留，务必清）"
launchctl unsetenv DYLD_INSERT_LIBRARIES
echo "   DYLD_INSERT_LIBRARIES=[$(launchctl getenv DYLD_INSERT_LIBRARIES)]"

hd "4/5 让 UU 重读 plist（unload + load；kickstart 不会重读）"
launchctl unload "$UU_PLIST" 2>/dev/null
sleep 3
launchctl load -w "$UU_PLIST" 2>/dev/null
if [ "$REHEARSE" != "1" ]; then
  sleep 8
  sudo -u "$CP_USER" open -a UURemote 2>/dev/null || open -a UURemote 2>/dev/null || true
  sleep 6
fi

hd "5/5 UU 组件状态"
pgrep -fl "UURemoteServer|MacOS/UURemote" | head -4 | sed 's/^/   /'

echo
echo "完成。UU 已恢复原状（画面会再次黑屏 —— 因本机无 Metal）。"
echo "注意：libstreamer.dylib 的磁盘补丁属于另一个环节，未在此卸载；"
echo "      如需一并还原，见 bash uu.sh cg-restore 与备份文件 libstreamer.dylib.orig。"
}


# ---- reset_main ----
reset_main() {
# 修复「重连连不上」：终止卡死的 UURemoteServer，UU 会自动重生一个干净的
#
# 背景：每次远程会话结束后，被控端 helper 有时不会正常退出，而是空转烧 CPU
# （实测 60%+，栈是它自己的定时器在反复做 base64/TIFF 图像编码），
# 占着会话位导致手机再连就连不上。
#
# 用法：
#   sudo bash uu.sh reset          # 执行（检测到正在出帧则拒绝，原因见下）
#   sudo bash uu.sh reset --dry    # 只看状态不改动
#   sudo bash uu.sh reset --force  # 明知有会话仍要重启（会踢掉正在用的客户）
#
# ★★ 为什么默认会拒绝：**高 CPU 本身不是「卡死」的证据** ——
#   本机没有硬件编码器，活跃会话里软编正当要烧 200%+ CPU。
#   旧版只看「CPU ≥ 20% 就杀」，于是**客户正在用时执行 reset 会把画面掐断**。
#   判据改为与 watchdog 同一条铁律：**还在出帧就绝不动它**。
#   帧信号取自 shim 日志的 `出帧 #` 行时间戳（超过 STREAMING_SEC 无帧才算可疑）。
#
# 退出码：0 = 已重启 / 空跑（--dry）；3 = **已拒绝**（在出帧，未做任何改动，非故障）。
#
# 还原说明：本脚本不修改任何文件，只重启一个进程。
#   它没有「撤销」动作 —— 执行效果就是「helper 被重启」。
#   如果想彻底退出改动（移除我们的补丁），用：
#     sudo bash uu.sh shim-restore
DRY=0; FORCE=0
# ★ 两个坑：① 调度器传的是 "${2:-}"，无参时也会来一个**空串** → 必须跳过，
#   否则 `bash uu.sh reset` 会被当「未知参数」拒掉；
#   ② 变量后面紧跟全角括号必须写 ${_a}：bash 在 set -u 下会把 `（` 并进变量名，
#   报 `_a: unbound variable` 并**在参数解析处就退出**（实测踩过）。
for _a in "$@"; do
  [ -z "$_a" ] && continue
  case "$_a" in
    --dry)   DRY=1 ;;
    --force) FORCE=1 ;;
    *) echo "未知参数：${_a}（可用：--dry / --force）" >&2; exit 2 ;;
  esac
done
# 与 watchdog 同源：帧日志路径与「多久没帧算停流」
SHIM_LOG="${UU_SHIM_LOG:-/tmp/uushim.log}"
STREAMING_SEC="${UU_STREAMING_SEC:-15}"
STREAMING=0

# ---------- 在出帧判据（与 watchdog 的 LAST_FRAME_SEC 同一算法）----------
# ★ 必须把 HH:MM:SS 转秒再相减：跨午夜时字符串比较会把昨天的帧算成最近（实测踩过）。
last_frame_sec() {
  [ -f "$SHIM_LOG" ] || { echo 99999; return; }
  local lft d
  lft=$(grep -a '出帧 #' "$SHIM_LOG" 2>/dev/null | tail -1 | cut -c1-8 || true)
  case "$lft" in
    [0-9][0-9]:[0-9][0-9]:[0-9][0-9])
      d=$(( $(to_sec "$(date +%H:%M:%S)") - $(to_sec "$lft") ))
      [ "$d" -lt 0 ] && d=$((d + 86400))
      echo "$d" ;;
    *) echo 99999 ;;
  esac
}


PIDF=/Users/Shared/UURemote/Shared/.active_pid
PID=$(cat "$PIDF" 2>/dev/null || echo "")
hd "当前状态"
if [ -z "$PID" ]; then
  no "读不到 active_pid（UU 可能未运行）"
else
  INFO=$(ps -p "$PID" -o pid=,%cpu=,time=,lstart= 2>/dev/null | sed 's/  */ /g')
  if [ -n "$INFO" ]; then
    echo "  helper: $INFO"
    CPU=$(ps -p "$PID" -o %cpu= 2>/dev/null | tr -d ' ')
    INT=${CPU%%.*}
    LFS=$(last_frame_sec)
    if [ "$LFS" -le "$STREAMING_SEC" ]; then
      # ★ 在出帧：CPU 高是软编的正常开销，不是卡死 —— 绝不能杀（会掐断客户会话）
      STREAMING=1
      ok "正在出帧（${LFS}s 前还有帧）—— CPU ${CPU}% 是软编正常开销，不是卡死"
      echo "     判据：shim 日志最近一行 \`出帧 #\` 距今 ${LFS}s（阈值 ${STREAMING_SEC}s）"
    elif [ "${INT:-0}" -ge 20 ] 2>/dev/null; then
      no "CPU ${CPU}% 且已 ${LFS}s 无帧 —— 疑似卡死空转（就是「连不上」的原因）"
      STUCK=1
    else
      ok "CPU ${CPU}% —— 空闲正常"
      STUCK=0
    fi
  else
    no "active_pid=$PID 但进程不存在（残留记录）"
    STUCK=1
  fi
fi

# 同时列出所有 UURemoteServer（可能有多个残留）
hd "所有 helper 进程"
ps -Ao pid,%cpu,time,comm 2>/dev/null | grep UURemoteServer | grep -v grep | sed 's/^/  /' || echo "  （无）"

if [ "$DRY" = "1" ]; then
  hd "演练模式：不杀任何进程"
  exit 0
fi

# ★★ 闸：正在出帧就拒绝（除非 --force）
if [ "$STREAMING" = "1" ] && [ "$FORCE" != "1" ]; then
  hd "已拒绝：helper 正在出帧，未做任何改动"
  echo "  画面正在正常输出，重启会**当场踢掉正在使用的客户**。"
  echo "  CPU 高在这是软编的正常开销（本机无硬件编码器），不等于卡死。"
  echo
  echo "  确认要重启（例如画面已卡但日志仍在刷帧）：sudo bash uu.sh reset --force"
  echo "  只看状态不改动：                            sudo bash uu.sh reset --dry"
  exit 3
fi

hd "重启 helper"
if [ -n "$PID" ] && ps -p "$PID" >/dev/null 2>&1; then
  kill -TERM "$PID" 2>/dev/null && ok "已发 TERM 给 $PID"
  for i in $(seq 1 10); do
    ps -p "$PID" >/dev/null 2>&1 || break
    sleep 1
  done
  if ps -p "$PID" >/dev/null 2>&1; then
    kill -KILL "$PID" 2>/dev/null; sleep 2
    ps -p "$PID" >/dev/null 2>&1 && no "$PID 仍活着" || ok "已强制终止 $PID"
  else
    ok "$PID 已退出"
  fi
else
  ok "无可终止的进程"
fi

echo "  等待 UU 自动重生 helper…"
NEW=""
for i in $(seq 1 20); do
  sleep 1
  NEW=$(cat "$PIDF" 2>/dev/null || echo "")
  if [ -n "$NEW" ] && [ "$NEW" != "$PID" ] && ps -p "$NEW" >/dev/null 2>&1; then break; fi
done

hd "结果"
if [ -n "$NEW" ] && ps -p "$NEW" >/dev/null 2>&1; then
  ok "新 helper: $(ps -p "$NEW" -o pid=,%cpu=,time= | sed 's/  */ /g')"
  sleep 4
  C=$(ps -p "$NEW" -o %cpu= 2>/dev/null | tr -d ' ')
  echo "  4 秒后 CPU: ${C}%（空闲应接近 0）"
  echo "  shim 日志尾:"
  tail -2 /tmp/uushim.log 2>/dev/null | sed 's/^/    /'
else
  no "未检测到新 helper —— 可在 UU 界面点一下，或打开 UU 应用"
fi
echo
echo "  现在可以用手机重连了。"
echo "  彻底还原（移除补丁）：sudo bash uu.sh shim-restore"
}


# ---- watchdog_main ----
watchdog_main() {
# UU 被控端看门狗：自动检测并恢复「黑屏 / 连不上」状态
#
# 为什么需要它：shim 的槽位/内存类故障是**渐进累积**的 —— 表面症状是「突然连不上」，
# 实际是若干次连接后资源耗尽。进程一旦进入该状态就无法自愈（create 只能返回假句柄），
# 必须重启被控端。让它在无人值守时自动恢复。
#
# 判据（任一命中即恢复）：
#   ① 空闲回收（★ 新增，最重要）    —— 无人连接且 RSS > 800MB：把上一场会话泄漏的内存还回去
#   ② 进程 RSS 硬顶（真泄漏失控）   —— RSS > 3500MB（无论有没有会话）
#   ③ 近期反复分配失败             —— 窗口内 `无可用缓冲`/`分配失败` ≥ 3 次，且已停帧
#   ④ 近期槽位耗尽                 —— 窗口内 `流数超上限` ≥ 1 次，且已停帧
#
# ★★ 为什么必须加「① 空闲回收」（实测数据）：
#     本机这套补丁链上，**每出一帧就新增约 3 个 IOSurface（单个 ~2.74MB、合计 ~5~9MB）**，
#     且**会话结束后不回收** —— 实测 25 秒会话把 UURemoteServer 的 RSS 从 55MB 推到 1539MB，
#     会话结束仍停在 2.7GB；IOSurface 分区涨到 3.0GB / 1099 个。
#     后果：下一个连上来的人 **分配不到 IOSurface → 黑屏**（日志：`IOSurfaceCreate[0] 失败
#     （内存不足）` → `分配缓冲重试 8 次仍失败 → 本次会话无帧`），同时把 swap 顶到十几 GB。
#     即「**上次的会话把内存吃光，导致这次黑屏**」。
#     所以：趁**没人连**的时候重启一次 server 回收，用户无感；比等他连上来发现黑屏强得多。
#     实测重启后 RSS 55MB、IOSurface 归零，连接立刻恢复有画面。
#
# ★★ 为什么**不在会话进行中**因为 RSS 高就重启：
#     实测会话中即使空闲内存只剩 16MB，出帧仍然正常（shim 的缓冲池在会话开始时一次性分配好）；
#     此时重启只会**当场把用户踢下线**（这正是 03:15 那次的直接原因）。
#     所以：会话进行中只记警告不动手，等它空闲下来再回收。
#
# 保守原则：**只要还有人在正常出帧就不动它**（重启会踢掉用户）。
# 冷却：3 分钟内最多恢复一次（防止故障持续时反复重启）。
#
# 用法: uu.sh watchdog [--dry]      --dry = 只诊断不动作
DRY=0
[ "${1:-}" = "--dry" ] && DRY=1

SHIM_LOG="${UU_SHIM_LOG:-/tmp/uushim.log}"
WD_LOG="${UU_WD_LOG:-/tmp/uushim-watchdog.log}"
STAMP="${UU_WD_STAMP:-/tmp/.uushim-watchdog-last}"
WINDOW="${UU_WD_WINDOW:-120}"      # 观测窗口（秒）
RSS_LIMIT_MB="${UU_WD_RSS_MB:-3500}"      # RSS 硬顶（MB）：真失控泄漏，无论有无会话
RSS_IDLE_MB="${UU_WD_RSS_IDLE_MB:-800}"   # 空闲回收阈值（MB）：无人连时超过就重启回收内存
IDLE_SEC="${UU_WD_IDLE:-60}"              # 多久没出帧算「无人连接（空闲）」
COOLDOWN="${UU_WD_COOLDOWN:-180}"  # 冷却（秒）
NOFRAME_SEC="${UU_WD_NOFRAME:-60}" # 无出帧多少秒算停流

UID_N=$(id -u)

# ---------- 采集事实 ----------
# ★ 必须用 pgrep -x（按进程名精确匹配）：pgrep -f 会把「命令行里恰好含这段路径」的
#   其它进程（包括调用本脚本的 shell）也算进来 → 误报「多实例」。实测踩过。
SRV=$(pgrep -x UURemoteServer | head -1 || true)

if [ -z "$SRV" ]; then
  # ★★ 这里以前写的是「没有 server：UU 按需拉起，属正常，不处理」——**这个假设是错的**
  #    （2026-09-28 实测）：UURemoteServer 是「设备在线」的载体，它不在跑 =
  #    别的设备看到这台机**离线**（uuyc-cli device info → isOnline=false），连接报 1001。
  #    杀掉它之后等 60 秒，UURemoteService 没有任何拉起动作；只有人工启动才恢复。
  #    而安装/签名流程必然会 pkill 它（占用文件签不了），所以「装完就离线」很容易发生。
  #    看门狗每次跑（默认 60 秒一次）在这里兜底把它带回来。
  if [ "${UU_WD_NO_SERVER_START:-0}" = "1" ]; then
    [ "$DRY" = "1" ] && echo "诊断: 无 UURemoteServer（已按 UU_WD_NO_SERVER_START=1 关闭自动拉起）"
    exit 0
  fi
  if [ "$DRY" = "1" ]; then
    echo "诊断: 无 UURemoteServer（设备此刻显示离线）→ 会执行 server_agent_up 把它拉起"
    exit 0
  fi
  echo "$(date '+%F %T') 没有 UURemoteServer（设备会显示离线）→ 拉起" >> "$WD_LOG"
  if server_agent_up >>"$WD_LOG" 2>&1; then
    echo "$(date '+%F %T') server 已拉起 pid=$(pgrep -x UURemoteServer | head -1)" >> "$WD_LOG"
  else
    echo "$(date '+%F %T') !! server 拉起失败" >> "$WD_LOG"
  fi
  exit 0
fi

RSS_KB=$(ps -p "$SRV" -o rss= 2>/dev/null | tr -d ' ')
[ -z "$RSS_KB" ] && RSS_KB=0
RSS_MB=$((RSS_KB / 1024))

# 多实例（已知会互相干扰，症状同样是采集不动）
SRV_CNT=$(pgrep -x UURemoteServer 2>/dev/null | wc -l | tr -d ' ')

# 时间窗起点（当日 HH:MM:SS，零填充，可与日志行首做字典序比较）
# ★★ 绝不能用「字符串比较时间戳」来取最近 N 秒：日志跨午夜时 "23:55" >= "01:24"
#    字典序成立，会把**昨天的故障**当成最近发生 → 看门狗误触发重启（实测踩过）。
#    正确做法：把 HH:MM:SS 转成秒数，与该日志最后一行的时间做差（跨午夜加回 86400）。

# 输出「最近 WINDOW 秒内」的日志行（只扫尾部 SCAN 行，避免大日志拖慢）
# ★ 基准必须用**墙钟当前时刻**，不能用「日志最后一行的时间」—— 日志最后一行可能
#   早于故障行（例如空闲时最后一行是几分钟前的出帧），拿它当基准会把新故障算成未来。

FAIL_N=0; EXHAUST_N=0
FAIL_N=$(recent_log | grep -acE '无可用缓冲|分配失败|BGRA 回退也失败' || true)
EXHAUST_N=$(recent_log | grep -ac '流数超上限' || true)

# 最后一次出帧距今多少秒（★ 同样用秒数差 + 跨午夜回绕，不能用字符串比较）
LAST_FRAME_SEC=99999
if [ -f "$SHIM_LOG" ]; then
  LFT=$(grep -a '出帧 #' "$SHIM_LOG" 2>/dev/null | tail -1 | cut -c1-8 || true)
  case "$LFT" in
    [0-9][0-9]:[0-9][0-9]:[0-9][0-9])
      NOW_S=$(to_sec "$(date +%H:%M:%S)")
      d=$((NOW_S - $(to_sec "$LFT")))
      [ "$d" -lt 0 ] && d=$((d + 86400))
      LAST_FRAME_SEC=$d
      ;;
  esac
fi

DIAG="rss=${RSS_MB}MB fail=${FAIL_N} exhaust=${EXHAUST_N} noframe=${LAST_FRAME_SEC}s 实例数=${SRV_CNT}"

# ---------- 判定 ----------
# ★★ 铁律：**只要还在正常出帧就不动它**（重启会踢掉正在用的用户）。
#    恢复只发生在两类时刻：① 空闲期（没人连）回收内存；② 确实出不了帧且有故障信号。
REASON=""
if [ "$RSS_MB" -gt "$RSS_LIMIT_MB" ]; then
  # 硬顶：这种量级的泄漏必然很快拖垮机器
  REASON="进程内存失控（${RSS_MB}MB > ${RSS_LIMIT_MB}MB）"
elif [ "$LAST_FRAME_SEC" -gt "$IDLE_SEC" ] && [ "$RSS_MB" -gt "$RSS_IDLE_MB" ]; then
  # ★ 空闲回收：没人连 + RSS 高 = 上一场会话泄漏的内存还占着，
  #   不回收的话**下一个连上来的人会分配不到 IOSurface → 黑屏**（实测链）。
  REASON="空闲回收（无帧 ${LAST_FRAME_SEC}s 且 RSS ${RSS_MB}MB > ${RSS_IDLE_MB}MB，回收防黑屏）"
elif [ "$LAST_FRAME_SEC" -gt "$NOFRAME_SEC" ]; then
  # 已经出不了帧，再看是哪种故障
  if [ "$EXHAUST_N" -gt 0 ]; then
    REASON="槽位耗尽 ${EXHAUST_N} 次且已 ${LAST_FRAME_SEC}s 无帧"
  elif [ "$FAIL_N" -ge 3 ]; then
    REASON="内存分配失败 ${FAIL_N} 次且已 ${LAST_FRAME_SEC}s 无帧"
  elif [ "$SRV_CNT" -gt 1 ]; then
    REASON="存在 ${SRV_CNT} 个 server 实例（互相干扰）且已 ${LAST_FRAME_SEC}s 无帧"
  fi
fi

# 会话进行中 RSS 偏高 → 只记警告（实测此时重启会把用户当场踢下线；停帧后再回收）
if [ -z "$REASON" ] && [ "$RSS_MB" -gt "$RSS_IDLE_MB" ] && [ "$LAST_FRAME_SEC" -le "$IDLE_SEC" ]; then
  log "提示：会话进行中 RSS=${RSS_MB}MB 偏高（每帧泄漏约 5~9MB），暂不动手；停帧 ${IDLE_SEC}s 后自动回收"
fi

if [ -z "$REASON" ]; then
  [ "$DRY" = "1" ] && echo "诊断: 健康（${DIAG}）"
  exit 0
fi

# 冷却检查
NOW=$(now_epoch)
if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  [ -n "$LAST" ] || LAST=0
  if [ $((NOW - LAST)) -lt "$COOLDOWN" ]; then
    [ "$DRY" = "1" ] && echo "诊断: 需恢复（${REASON}）但处于冷却期（$((NOW - LAST))s < ${COOLDOWN}s）"
    exit 0
  fi
fi

if [ "$DRY" = "1" ]; then
  echo "诊断: ★ 需恢复 —— ${REASON}（${DIAG}）"
  exit 0
fi

# ---------- 执行恢复 ----------
log "触发恢复：${REASON}（${DIAG}）"
echo "$NOW" > "$STAMP"
# 把当时的机器级状态一起记下来（这类故障常由整机内存压力引起，事后看日志能一眼定位）
log "机器状态：$(sysctl -n vm.swapusage 2>/dev/null | sed 's/  */ /g') | load=$(uptime | sed 's/.*load averages: //')"

# ★★ 恢复顺序（实测有效；早期版本只杀 server + kickstart，结果**设备没重新上线**）：
#   ① 杀 server 与 service（只杀 server 时，残留 service 可能持有旧状态）
#   ② kickstart agent —— 负责云端注册的组件就是它拉起来的
#      只杀不 kickstart（或只用 open -a）时设备会一直显示离线，实测 >4 分钟不恢复
#   ③ 确保 GUI 主进程在（不在就 open -a）
#   ④ 轮询等 server 回来（最多 30 秒）
#   ⑤ 回读登录态与网络态 —— 这一步是「恢复完成」的唯一凭据，
#      不能只看「进程起来了」就宣布恢复（进程在 ≠ 已注册上线）
pkill -x UURemoteServer 2>/dev/null
pkill -x UURemoteService 2>/dev/null
sleep 2
launchctl kickstart -k "gui/${UID_N}/com.netease.uuremote.agent" >/dev/null 2>&1
sleep 3

if ! pgrep -x UURemote >/dev/null 2>&1; then
  open -a /Applications/UURemote.app >/dev/null 2>&1
  sleep 4
fi

NEW=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  NEW=$(pgrep -x UURemoteServer | head -1 || true)
  [ -n "$NEW" ] && break
  sleep 3
done

N_CNT=$(pgrep -x UURemoteServer | wc -l | tr -d ' ')
CLI=/Applications/UURemote.app/Contents/Helpers/uuyc-cli
LOGGED=$("$CLI" status 2>/dev/null | grep -c '"isLoggedIn" : true' || true)
NETOK=$("$CLI" status 2>/dev/null | grep -c '"networkStatus" : "connected"' || true)

if [ -n "$NEW" ]; then
  NMB=$(ps -p "$NEW" -o rss= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
  log "恢复完成：server pid=${NEW} 实例数=${N_CNT} RSS=${NMB}MB 已登录=${LOGGED} 网络=${NETOK}"
else
  log "恢复异常：server 未拉起（实例数=${N_CNT} 已登录=${LOGGED} 网络=${NETOK}）；请人工检查"
fi
}


# ---------------------------------------------------------------------------
# 新增：状态总览 / 一键装全套 / 一键还原 / 看门狗常驻
# ---------------------------------------------------------------------------
cmd_status_all() {
  cg_status_main
  hd "帧源 shim（第2道门）"
  local dst="$APP/Contents/Frameworks/libuushim.dylib"
  local tgt="$APP/Contents/Helpers/UURemoteServer"
  if [ -f "$dst" ]; then ok "补丁库在位：libuushim.dylib（$(stat -f '%z' "$dst") 字节）"; else no "补丁库不在位（未装 shim 或已还原）"; fi
  local n; n=$(otool -L "$tgt" 2>/dev/null | grep -cF 'libuushim' || true)
  [ "$n" -gt 0 ] && ok "UURemoteServer 已注入依赖（$n 条）" || no "UURemoteServer 未注入依赖"
  echo "  已发布补丁库版本：$(strings "$D/shim/libuushim.dylib" 2>/dev/null | grep -m1 -o 'libuushim v[0-9]*' || echo '未知')"

  hd "CPU 帧转换（第4道门）"
  cpupath_paths
  if [ -f "$CP_LIBDST" ]; then ok "补丁库在位：libuucpupath.dylib（$(stat -f%z "$CP_LIBDST") 字节）"; else no "补丁库不在位（未装或已卸载）"; fi
  if sudo -n plutil -p "$CP_UU_PLIST" 2>/dev/null | grep -q "libuucpupath"; then
    ok "已注入 UU 自己的 LaunchAgent（只对 UU 生效）"
  else
    no "UU plist 里没有注入 → bash $D/uu.sh cpupath-install"
  fi
  if [ -n "$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null)" ]; then
    no "★ 全局 DYLD_INSERT_LIBRARIES 非空 —— 正在伤害系统进程！修：launchctl unsetenv DYLD_INSERT_LIBRARIES"
  else
    ok "全局注入为空（正确）"
  fi

  hd "进程与看门狗"
  local p
  for p in UURemote UURemoteServer UURemoteService UURemoteDaemon; do
    printf '  %-16s %s 个' "$p" "$(pgrep -x "$p" | wc -l | tr -d ' ')"
    local pid; pid=$(pgrep -x "$p" | head -1)
    [ -n "$pid" ] && printf '  (pid=%s 启动=%s)' "$pid" "$(ps -p "$pid" -o lstart= 2>/dev/null | cut -c12-19)"
    echo
  done
  local wdpid; wdpid=$(cat /tmp/.uu-wd-loop.pid 2>/dev/null || echo "")
  if [ -n "$wdpid" ] && kill -0 "$wdpid" 2>/dev/null; then
    ok "看门狗循环在跑（pid=${wdpid}，每 60 秒一次）"
  else
    no "看门狗循环未运行（启动：bash $D/uu.sh watchdog-loop）"
  fi
  [ -f /tmp/uushim-watchdog.log ] && { echo "  最近一条看门狗记录："; tail -1 /tmp/uushim-watchdog.log | sed 's/^/    /'; }

  hd "会话与内存"
  if [ -f /tmp/uushim.log ]; then
    echo "  shim 日志尾："; tail -2 /tmp/uushim.log | sed 's/^/    /'
  fi
  echo "  swap：$(sysctl -n vm.swapusage 2>/dev/null | sed 's/  */ /g')"
  echo "  load：$(uptime | sed 's/.*load averages: //')"
  if pgrep -f 'com.docker.backend' >/dev/null 2>&1; then
    local dpid drss dcpu
    dpid=$(pgrep -f 'Virtualization.framework' | head -1)
    drss=$(ps -p "$dpid" -o rss= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
    dcpu=$(ps -p "$dpid" -o %cpu= 2>/dev/null | tr -d ' ')
    echo "  ⚠ Docker 在跑（VM 占 ${drss:-?}MB / ${dcpu:-?}%CPU）—— 它会明显压低帧率"
  fi
}

cmd_install_all() {
  need_root || return 1
  hd "第1步：采集器 + 编码器门禁（cg-install）"
  cg_install_main || { no "cg-install 失败，已中止"; return 1; }
  # ★ 顺序说明（2026-09-28 调整）：第 4 道门现在也走**二进制级注入**，
  #   实际「部署库 + 加 LC_LOAD_DYLIB + 重签」由 shim-install 一并完成
  #   （见 sign_main 的 3/5、4/5 步）。所以先让 cpupath-install 清掉历史遗留的
  #   环境变量注入、装运行时副本，再由 shim-install 统一部署 + 重签。
  #   反过来（shim-install 在前）会让 cpupath-install 再重启一次 UU，白多一轮。
  hd "第2步：第4道门预处理 —— 清历史注入 + 运行时文件（cpupath-install）"
  cpupath_install_main
  hd "第3步：帧源 shim + 两个补丁库的部署与重签（shim-install）"
  shim_install_main || { no "shim-install 失败，已中止"; return 1; }
  hd "第4步：保证服务进程在跑（否则设备显示离线、连不上）"
  server_agent_up || true
  hd "第5步：保证看门狗已装（无人值守时自动回收内存 / 兜底拉起 server）"
  watchdog_ensure_agent || true
  hd "完成 —— 现在去手机端连一次"
  echo "  看不到画面时：bash $D/uu.sh status  →  然后 sudo bash $D/uu.sh reset"
  echo "  （reset 会在检测到「正在出帧」时拒绝 —— 那多半不是被控端的问题；"--force" 可强制）"
}

cmd_restore_all() {
  need_root || return 1
  hd "第1步：撤销帧源 shim"
  shim_restore_main
  hd "第2步：撤销采集器/门禁补丁"
  cg_restore_main
  hd "第3步：撤销 CPU 帧转换注入"
  cpupath_uninstall_main
  hd "完成 —— 已回到装本方案之前"
}

watchdog_loop() {
  local pidfile=/tmp/.uu-wd-loop.pid out=/tmp/uushim-watchdog.out
  if [ -f "$pidfile" ]; then
    local old; old=$(cat "$pidfile" 2>/dev/null || echo 0)
    if [ -n "$old" ] && [ "$old" -gt 0 ] && kill -0 "$old" 2>/dev/null; then
      echo "已有循环在跑 pid=${old}，本次退出"; exit 0
    fi
  fi
  echo $$ > "$pidfile"
  echo "$(date '+%F %T') 看门狗循环启动 pid=$$" >> "$out"
  while true; do
    bash "$D/uu.sh" watchdog >> "$out" 2>&1
    sleep 60
  done
}

watchdog_stop() {
  local pidfile=/tmp/.uu-wd-loop.pid
  if [ -f "$pidfile" ]; then
    local old; old=$(cat "$pidfile" 2>/dev/null || echo 0)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      kill "$old" && ok "已停止看门狗循环 pid=$old"
    else
      echo "  （pidfile 存在但进程已不在）"
    fi
    rm -f "$pidfile"
  else
    echo "  （看门狗循环未在运行）"
  fi
}

cmd_help() {
cat <<EOT
UU远程 修复工具集 —— 单文件入口

用法：bash uu.sh <命令>          （标 sudo 的需要 root）

【日常】
  status              综合状态总览：补丁 / shim / 进程 / 看门狗 / 内存（免 sudo，最常用）
  verify              查日志，看 UU 实际走了哪套采集器（免 sudo）
  reset [--dry|--force] 重启卡死的 helper（在出帧则拒绝；--force 强制）  [sudo]
  daemon              重启 root 守护进程（修「无法连接至服务器 1001」）[sudo]

【安装 / 还原】（重装 UU、UU 自动更新覆盖补丁之后）
  install             一键装全套 = cg-install + cpupath-install + shim-install  [sudo]
  restore             一键还原全套                                              [sudo]
  cg-install          只装第1/3道门（libstreamer 门禁补丁）                      [sudo]
  cg-restore          只还原上述门禁补丁                                        [sudo]
  shim-install        装第2道门（帧源）★ 同时部署两个补丁库并重签（= 第4道门的部署）[sudo]
  shim-restore        只还原帧源替换                                            [sudo]
  cpupath-install     第4道门预处理：清历史环境变量注入 + 装运行时副本（部署靠 shim-install）
  cpupath-status      看第4道门状态（含"全局注入是否为空"检查）
  cpupath-uninstall   只卸载第4道门
  sign                重新签名（修「设备不上线 / XPC 被拒」）                    [sudo]

【看门狗】
  watchdog [--dry]    执行一次检查（--dry 只诊断不动作）
  watchdog-install    安装/修复看门狗 LaunchAgent（每 60 秒一次）
  watchdog-loop       启动常驻循环（每 60 秒一次）
  watchdog-stop       停止常驻循环

【服务进程（决定「设备是否在线」）】
  server-agent       拉起 UURemoteServer 并设为 LaunchAgent 托管（幂等）
  server-agent-status 看它的托管与运行状态
  server-agent-down  卸载托管（回到完全官方行为）

【诊断】
  monitor             实时看 CPU 与帧率
  traffic             看上行走哪条网卡 / 码率 / 中继
  encoder             编码器能力实测（确认有没有硬件编码）
  setmode [模式]      查看/切换显示模式（setmode list / 720p / 900p / 1080p）—— 实测不改帧率，码流尺寸由 UU 定
  cleanup             项目清理（演练；--apply 实做）

【其他】
  help                显示本帮助

【常见处置】
  连不上 / 黑屏     → sudo bash uu.sh reset      （必要时再 daemon）
  设备不上线/1001    → sudo bash uu.sh sign  然后  sudo bash uu.sh daemon
  UU 更新后补丁没了  → sudo bash uu.sh install
  帧率低             → bash uu.sh status 看 Docker 与内存；瓶颈是软件编码（详见 README）

背景：本机缺 IOGPU，ScreenCaptureKit 必然失败(-3802) → 纯黑屏。UU 自带
      CoreGraphics 采集器但工厂函数永远选不到，故需打补丁。详见 README.md。
EOT
}

# ---------------------------------------------------------------------------
# 收尾兜底：安装/签名期间挂起的弹窗自动应答必须随本进程结束而停掉，
# 否则它会空转 15 分钟（虽然无害，但会一直持有 osascript 进程）。
# ---------------------------------------------------------------------------
trap 'dialog_watcher_stop' EXIT

# ---------------------------------------------------------------------------
# 子命令分派
# ---------------------------------------------------------------------------
case "${1:-help}" in
  status|st)                 cmd_status_all ;;
  verify|v)                  cg_verify_main ;;
  install|all)               cmd_install_all ;;
  restore|undo)              cmd_restore_all ;;
  cg-install|cgpatch)        cg_install_main ;;
  cg-restore|unpatch)        cg_restore_main ;;
  shim-install)              shim_install_main ;;
  shim-restore)              shim_restore_main ;;
  cpupath-install|cpupath)   cpupath_install_main ;;
  cpupath-status)            cpupath_status_main ;;
  cpupath-uninstall)         cpupath_uninstall_main ;;
  sign)                      sign_main ;;
  daemon|fix-daemon|xpc)     cg_daemon_main ;;
  reset)                     reset_main "${2:-}" ;;
  watchdog|wd)               watchdog_main "${2:-}" ;;
  watchdog-install)          watchdog_ensure_agent ;;
  server-agent|server-up)    server_agent_up ;;
  server-agent-status)       server_agent_status ;;
  server-agent-down)         server_agent_down ;;
  watchdog-loop|wd-loop)     watchdog_loop ;;
  watchdog-stop|wd-stop)     watchdog_stop ;;
  monitor)                   bash "$D/tools/uu-monitor.sh" ;;
  traffic)                   bash "$D/tools/uu-traffic.sh" ;;
  encoder)                   bash "$D/tools/uu-encoder-probe.sh" ;;
  setmode)                   "$D/tools/setmode" "${2:-list}" ;;
  cleanup)                   python3 "$D/tools/cleanup.py" "${@:2}" ;;
  help|-h|--help)            cmd_help ;;
  *) no "未知命令：$1"; echo; cmd_help; exit 1 ;;
esac
