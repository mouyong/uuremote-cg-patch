#!/bin/bash
# UU远程 CPU 转换路径修复 —— 安装 / 持久化
#
# 作用：让 UU远程 在无 Metal 的老 Mac（AMD pre-GCN，如 2011 Mac mini）上也能把画面编出来并发出去，
#       否则对端连接后永远黑屏 / 卡在"正在连接"。
# 原理：运行时把 libstreamer 的 IOSurfaceFrame::CopyTo(VideoFrame&) 换成 CPU memcpy 实现
#       （该函数原本用 Metal 渲染，无 Metal 时必然失败 → 编码器收不到帧）。
#       不改 UU 任何文件；只注入一个 dylib + 设置环境变量。
#
# 持久化方式：写 ~/Library/LaunchAgents/com.uuremote-cg-patch.cpupath.plist
#             —— 该目录下的 plist 在**用户登录时由 launchd 自动加载**，无需额外命令。
#
# 用法：bash install.sh / bash uninstall.sh / bash status.sh
set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/Library/Application Support/UUCpuPath"
LIBSRC="$SRC_DIR/libuucpupath.dylib"
LIBDST="$DEST_DIR/libuucpupath.dylib"
PLIST="$HOME/Library/LaunchAgents/com.uuremote-cg-patch.cpupath.plist"
UU_AGENT="com.netease.uuremote.agent"

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
echo "=== 2. 写应用脚本（设置环境变量 + 重启 UU agent）==="
cat > "$DEST_DIR/apply.sh" <<EOF
#!/bin/bash
# 登录时由 LaunchAgent 调用：把修复库注入到之后启动的 UU 进程
LIB="\$HOME/Library/Application Support/UUCpuPath/libuucpupath.dylib"
[ -f "\$LIB" ] || exit 0
launchctl setenv DYLD_INSERT_LIBRARIES "\$LIB"
launchctl kickstart -k gui/\$(id -u)/$UU_AGENT 2>/dev/null
exit 0
EOF
chmod +x "$DEST_DIR/apply.sh"
echo "   $DEST_DIR/apply.sh"

echo
echo "=== 3. 写 LaunchAgent（用户登录时自动加载）==="
mkdir -p "$HOME/Library/LaunchAgents"
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

echo
echo "=== 4. 立即生效（当前登录会话）==="
launchctl setenv DYLD_INSERT_LIBRARIES "$LIBDST"
echo "   DYLD_INSERT_LIBRARIES=[$(launchctl getenv DYLD_INSERT_LIBRARIES)]"
echo "   重启 UU 栈…"
P1="UURemote""Server"; P2="MacOS/UU""Remote"; P3="UU""RemoteService"
pkill -f "$P1" 2>/dev/null; pkill -f "$P2" 2>/dev/null; pkill -f "$P3" 2>/dev/null
sleep 4
launchctl kickstart -k "gui/$(id -u)/$UU_AGENT" 2>&1
sleep 8
open -a UURemote 2>/dev/null
sleep 12

echo
echo "=== 5. 验证 ==="
if grep -q "vtable 槽替换" /tmp/uucpu.log 2>/dev/null; then
    echo "   ✓ 修复已生效"
    grep -E "libuucpupath 已加载|dlsym 定位|vtable 槽替换" /tmp/uucpu.log 2>/dev/null | tail -3
else
    echo "   ！未检测到生效记录，最近日志："
    tail -5 /tmp/uucpu.log 2>/dev/null || echo "   （无日志）"
fi
echo
echo "   UU 进程："
pgrep -fl "UURemoteServer|MacOS/UURemote" | head -4

echo
echo "完成。"
echo "  持久化：plist 已写入 ~/Library/LaunchAgents/，下次登录/重启自动生效（无需额外命令）。"
echo "  依赖项：libstreamer.dylib 的磁盘补丁（Metal 门禁 / 低延迟 RC）需另行保持，"
echo "          见 ../patch_tool.py + uu.sh；UU 自动更新会覆盖，需重跑。"
