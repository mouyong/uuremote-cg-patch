#!/bin/bash
# UU远程 CPU 转换路径修复 —— 安装 / 持久化
#
# 作用：让 UU远程 在无 Metal 的老 Mac（AMD pre-GCN，如 2011 Mac mini）上也能把画面编出来并发出去，
#       否则对端连接后永远黑屏 / 卡在"正在连接"。
# 原理：运行时把 libstreamer 的 IOSurfaceFrame::CopyTo(VideoFrame&) 换成 CPU memcpy 实现
#       （该函数原本用 Metal 渲染，无 Metal 时必然失败 → 编码器收不到帧）。
#       不改 UU 的二进制，只注入一个 dylib。
#
# ★★★ 注入方式（2026-09-27 改，原因务必读完再动）
#
#   正确做法：把 DYLD_INSERT_LIBRARIES 写进 **UU 自己的 LaunchAgent plist** 的
#             EnvironmentVariables —— 只有 UU 及其子进程会加载本库。
#   禁止做法：`launchctl setenv DYLD_INSERT_LIBRARIES ...`
#             —— 那是 **launchd 用户域全局**变量，所有由 launchd 启动/继承环境的进程
#             都会读到它（AppleSpell、bluetooth、cloudd、Keychain、ScreenTime、
#             ScreenSharing、devicecheckd、biomesyncd、ModelCatalogAgent、
#             甚至命令行工具 pgrep / screencapture …）。
#             这些进程带 Apple 签名 + library validation，加载**未签名**的 dylib 会触发
#             macOS 的 CODESIGNING 保护，被直接 SIGKILL（崩溃报告特征：
#             namespace=CODESIGNING, indicator=Invalid Page,
#             signal=SIGKILL (Code Signature Invalid)）。
#
#   实测代价（这就是改掉它的原因）：
#     · 安装全局注入当天产生 **141 份**系统进程崩溃报告（前一天只有 1 份）
#     · `screencapture` / `pgrep` 一类工具执行即被杀（容易被误判成"没有录屏权限"）
#     · 系统卡顿，连 System Settings 都可能起不来
#     · 收窄到 plist 后：系统立刻安静，UU 功能不受影响
#
#   注意：给 dylib 做 ad-hoc 签名（本脚本仍会做）**并不能**避免上述崩溃 ——
#         实测无效，必须靠收窄注入范围。
#
# 持久化两层：
#   ① 改 /Library/LaunchAgents/com.netease.uuremote.agent.plist（注入本体，需 sudo）
#   ② 本目录自己的 LaunchAgent（登录时幂等复核；UU 升级覆盖 ① 后能自动补回）
#
# 用法：bash install.sh / bash uninstall.sh / bash status.sh
set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/Library/Application Support/UUCpuPath"
LIBSRC="$SRC_DIR/libuucpupath.dylib"
LIBDST="$DEST_DIR/libuucpupath.dylib"
PLIST="$HOME/Library/LaunchAgents/com.uuremote-cg-patch.cpupath.plist"
UU_AGENT="com.netease.uuremote.agent"
UU_PLIST="/Library/LaunchAgents/com.netease.uuremote.agent.plist"

if [ ! -f "$LIBSRC" ]; then
    echo "!! 找不到 $LIBSRC —— 先编译："
    echo "   clang -dynamiclib -O2 -o libuucpupath.dylib libuucpupath.c \\"
    echo "         -framework CoreVideo -framework CoreFoundation -framework IOSurface"
    exit 1
fi

echo "=== 1. 安装运行时文件 ==="
mkdir -p "$DEST_DIR"
cp -f "$LIBSRC" "$LIBDST"
xattr -c "$LIBDST" 2>/dev/null
codesign -f -s - "$LIBDST" 2>/dev/null
echo "   $LIBDST  ($(stat -f%z "$LIBDST") 字节)"

echo
echo "=== 2. 把注入写进 UU 自己的 LaunchAgent（只对 UU 生效）==="
if [ ! -f "$UU_PLIST" ]; then
    echo "   !! 找不到 $UU_PLIST —— UU 未按标准方式安装？中止以免注入到错误位置"
    exit 1
fi
# 改系统目录里的 plist 需要 sudo；本机已免密。无权限时明确报错，不要静默失败。
sudo -n /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$UU_PLIST" 2>/dev/null
sudo -n /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:DYLD_INSERT_LIBRARIES $LIBDST" "$UU_PLIST" 2>/dev/null \
  || sudo -n /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DYLD_INSERT_LIBRARIES string $LIBDST" "$UU_PLIST"
if [ $? -ne 0 ]; then
    echo "   !! 写入失败（需要 sudo 权限）"
    exit 1
fi
echo "   语法校验：$(sudo -n plutil -lint "$UU_PLIST" 2>&1)"
sudo -n plutil -p "$UU_PLIST" 2>/dev/null | grep -A2 EnvironmentVariables | sed 's/^/     /'

echo
echo "=== 3. 撤销历史遗留的全局注入（重要：它才是伤害系统的那个）==="
if [ -n "$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null)" ]; then
    launchctl unsetenv DYLD_INSERT_LIBRARIES
    echo "   已清除（原值见 git 历史/安装日志）"
else
    echo "   全局变量本来就是空的 ✓"
fi
echo "   现在 DYLD_INSERT_LIBRARIES=[$(launchctl getenv DYLD_INSERT_LIBRARIES)]"

echo
echo "=== 4. 写登录时复核用的 LaunchAgent（UU 升级覆盖 UU plist 后自动补回）==="
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$DEST_DIR/apply.sh" <<EOF
#!/bin/bash
# 登录时由 LaunchAgent 调用：幂等复核 UU 的 plist 里是否还有我们的注入。
# ★ 这里**只改 UU 自己的 plist**，绝不调 launchctl setenv（全局变量会伤害系统进程）。
UU_PLIST="$UU_PLIST"
LIB="$LIBDST"
LOG="$DEST_DIR/apply.out.log"
[ -f "\$LIB" ] || exit 0
[ -f "\$UU_PLIST" ] || exit 0
if sudo -n plutil -p "\$UU_PLIST" 2>/dev/null | grep -q "libuucpupath"; then
    echo "\$(date '+%F %T') 注入仍在 UU plist 中，无需处理" >> "\$LOG"
    exit 0
fi
# UU 升级覆盖了 plist → 补回
sudo -n /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "\$UU_PLIST" 2>/dev/null
sudo -n /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DYLD_INSERT_LIBRARIES string \$LIB" "\$UU_PLIST" 2>/dev/null
if sudo -n plutil -p "\$UU_PLIST" 2>/dev/null | grep -q "libuucpupath"; then
    echo "\$(date '+%F %T') UU plist 被覆盖，已补回注入（下次 UU 重启生效）" >> "\$LOG"
else
    echo "\$(date '+%F %T') !! 补回失败（需要 sudo 权限），请手动运行 install.sh" >> "\$LOG"
fi
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
launchctl print "gui/$(id -u)/com.uuremote-cg-patch.cpupath" >/dev/null 2>&1 \
  && echo "   ✓ 复核用 LaunchAgent 已加载" \
  || echo "   ！复核用 LaunchAgent 未加载（下次登录仍会生效）"

echo
echo "=== 5. 让 UU 重读 plist 并生效 ==="
# ★ 必须 unload + load：kickstart 不会重读 plist（实测新进程拿不到新环境变量）。
launchctl unload "$UU_PLIST" 2>/dev/null
sleep 3
launchctl load -w "$UU_PLIST" 2>/dev/null
sleep 8
NEWPID=$(pgrep -x UURemoteService | head -1 || true)
if [ -n "$NEWPID" ]; then
    if ps eww "$NEWPID" 2>/dev/null | tr ' ' '\n' | grep -q DYLD_INSERT; then
        echo "   ✓ UU agent(pid=$NEWPID) 已从 plist 取得注入"
    else
        echo "   !! UU agent 未取得注入（plist 可能未生效）"
    fi
fi
open -a UURemote 2>/dev/null
sleep 6

echo
echo "=== 6. 验证 ==="
if grep -q "vtable 槽替换" /tmp/uucpu.log 2>/dev/null; then
    echo "   ✓ 修复已生效"
    grep -E "libuucpupath 已加载|vtable 槽替换" /tmp/uucpu.log 2>/dev/null | tail -2 | sed 's/^/     /'
else
    echo "   ！未检测到生效记录，最近日志："
    tail -5 /tmp/uucpu.log 2>/dev/null || echo "   （无日志）"
fi
echo
echo "   当前加载本库的进程（应该只有 UU 系的）："
sudo -n lsof -n 2>/dev/null | grep -i libuucpupath | awk '{print $1}' | sort -u | head -10 | sed 's/^/     /'

echo
echo "完成。"
echo "  注入位置：$UU_PLIST 的 EnvironmentVariables（只对 UU 生效）"
echo "  持久化：  ① 上述 plist（UU 升级会覆盖 → ② 补回）"
echo "            ② ${PLIST}（登录时幂等复核，见 ${DEST_DIR}/apply.out.log）"
echo "  依赖项：libstreamer.dylib 的磁盘补丁（Metal 门禁 / 低延迟 RC）需另行保持，"
echo "          见 ../patch_tool.py + uu.sh；UU 自动更新会覆盖，需重跑。"
