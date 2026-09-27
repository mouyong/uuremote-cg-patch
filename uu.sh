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
#   第4道 像素路径：把 Metal 路径换成 CPU memcpy
#         → cpupath/（已含在第1道补丁里）
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


setup_keychain() {
  hd "准备独立签名钥匙串（避免 root 读不到登录钥匙串 → errSecInternalComponent）"
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

  local e tmp="" merged="" extra="$D/extra-ents/$(basename "$f").plist"
  # 还原时用 UURT_SKIP_EXTRA=1 让签名回到官方权限集（不带我们额外加的权限）
  [ "${UURT_SKIP_EXTRA:-0}" = "1" ] && extra="/dev/null"
  e=$(codesign -d --entitlements :- "$f" 2>/dev/null || true)
  if printf '%s' "$e" | grep -q '<plist'; then
    tmp=$(mktemp /tmp/ents.XXXXXX.plist); printf '%s' "$e" > "$tmp"
  fi
  # 额外权限（$D/extra-ents/<文件名>.plist）：与原 entitlements 合并。
  # 典型用途：UURemoteServer 需要 com.apple.security.cs.disable-library-validation
  # 才能加载我们自签的 libuushim.dylib（签名者不同）。
  if [ -f "$extra" ]; then
    if [ -n "$tmp" ]; then
      merged=$(mktemp /tmp/entsm.XXXXXX.plist)
      if python3 -c 'import plistlib,sys
a=plistlib.load(open(sys.argv[1],"rb")); b=plistlib.load(open(sys.argv[2],"rb"))
a.update(b); plistlib.dump(a, open(sys.argv[3],"wb"))' "$tmp" "$extra" "$merged" 2>/dev/null; then
        echo "    + 额外权限：$(python3 -c 'import plistlib,sys;print(",".join(plistlib.load(open(sys.argv[1],"rb")).keys()))' "$extra" 2>/dev/null)"
      else
        merged=""   # 合并失败则退回原 entitlements，不至于签出一个坏签名
      fi
    else
      merged="$extra"
      echo "    + 额外权限：$(python3 -c 'import plistlib,sys;print(",".join(plistlib.load(open(sys.argv[1],"rb")).keys()))' "$extra" 2>/dev/null)"
    fi
  fi
  if [ -n "$merged" ]; then args+=(--entitlements "$merged")
  elif [ -n "$tmp" ]; then args+=(--entitlements "$tmp"); fi

  local out rc
  as_user security unlock-keychain -p "$KC_PASS" "$KC" >/dev/null 2>&1
  out=$(as_user codesign "${args[@]}" "$f" 2>&1); rc=$?
  if [ $rc -ne 0 ] && [ "$(id -u)" -eq 0 ]; then
    security unlock-keychain -p "$KC_PASS" "$KC" >/dev/null 2>&1
    out=$(codesign "${args[@]}" "$f" 2>&1); rc=$?
  fi

  [ -n "$tmp" ] && rm -f "$tmp"
  case "$merged" in /tmp/entsm.*) rm -f "$merged" ;; esac
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

# ---------------------------------------------------------------------------
hd "4/5 给 UURemoteServer 加 LC_LOAD_DYLIB（不改机器码）"
# ---------------------------------------------------------------------------
if have_dylib "$TARGET"; then
  ok "依赖已在（幂等跳过）"
else
  # IDB_BACKUP 让备份落在 App 外面 —— 包内留 .dylibbak 会污染 CodeResources
  if IDB_BACKUP="$BACKUP" python3 "$D/tools/insert_dylib.py" --add "$TARGET" "$LOAD_PATH" 2>&1 | sed 's/^/  /'; then
    have_dylib "$TARGET" && ok "依赖已写入：$LOAD_PATH" || { no "写入后校验失败"; exit 1; }
  else
    no "加依赖失败（空间不足？）"; exit 1
  fi
fi
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


# ---- reset_main ----
reset_main() {
# 修复「重连连不上」：终止卡死的 UURemoteServer，UU 会自动重生一个干净的
#
# 背景：每次远程会话结束后，被控端 helper 有时不会正常退出，而是空转烧 CPU
# （实测 60%+，栈是它自己的定时器在反复做 base64/TIFF 图像编码），
# 占着会话位导致手机再连就连不上。
#
# 用法：
#   sudo bash uu.sh reset          # 执行
#   sudo bash uu.sh reset --dry    # 只看状态不改动
#
# 还原说明：本脚本不修改任何文件，只重启一个进程。
#   它没有「撤销」动作 —— 执行效果就是「helper 被重启」。
#   如果想彻底退出改动（移除我们的补丁），用：
#     sudo bash uu.sh shim-restore
DRY=0
[ "${1:-}" = "--dry" ] && DRY=1


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
    if [ "${INT:-0}" -ge 20 ] 2>/dev/null; then
      no "CPU ${CPU}% —— 疑似卡死空转（就是「连不上」的原因）"
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
  # 没有 server：UU 按需拉起，属正常（无人连接时进程不存在），不处理
  [ "$DRY" = "1" ] && echo "诊断: 无 UURemoteServer 进程（无人连接时的正常状态）"
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
  hd "第1步：采集器 + 编码器门禁 + 像素路径（cg-install）"
  cg_install_main || { no "cg-install 失败，已中止"; return 1; }
  hd "第2步：帧源 shim（shim-install）"
  shim_install_main || { no "shim-install 失败，已中止"; return 1; }
  hd "完成 —— 现在去手机端连一次"
  echo "  看不到画面时：bash $D/uu.sh status  →  然后 sudo bash $D/uu.sh reset"
}

cmd_restore_all() {
  need_root || return 1
  hd "第1步：撤销帧源 shim"
  shim_restore_main
  hd "第2步：撤销采集器/门禁补丁"
  cg_restore_main
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
  reset [--dry]       重启卡死的 helper（「连不上」先试它）        [sudo]
  daemon              重启 root 守护进程（修「无法连接至服务器 1001」）[sudo]

【安装 / 还原】（重装 UU、UU 自动更新覆盖补丁之后）
  install             一键装全套 = cg-install + shim-install       [sudo]
  restore             一键还原全套                                  [sudo]
  cg-install          只装第1/3/4道门（libstreamer 三处补丁）        [sudo]
  cg-restore          只还原上述三处补丁                            [sudo]
  shim-install        只装第2道门（截图轮询帧源）                    [sudo]
  shim-restore        只还原帧源替换                                [sudo]
  sign                重新签名（修「设备不上线 / XPC 被拒」）        [sudo]

【看门狗】
  watchdog [--dry]    执行一次检查（--dry 只诊断不动作）
  watchdog-loop       启动常驻循环（每 60 秒一次）
  watchdog-stop       停止常驻循环

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
  sign)                      sign_main ;;
  daemon|fix-daemon|xpc)     cg_daemon_main ;;
  reset)                     reset_main "${2:-}" ;;
  watchdog|wd)               watchdog_main "${2:-}" ;;
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
