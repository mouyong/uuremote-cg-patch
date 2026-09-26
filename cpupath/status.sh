#!/bin/bash
# UU远程 CPU 转换路径修复 —— 状态检查
set -u

DEST_DIR="$HOME/Library/Application Support/UUCpuPath"
PLIST="$HOME/Library/LaunchAgents/com.uuremote-cg-patch.cpupath.plist"
LABEL="com.uuremote-cg-patch.cpupath"
UU_AGENT="com.netease.uuremote.agent"

echo "================ UU CPU 转换路径修复 状态 ================"
echo

echo "1) 运行时文件"
if [ -f "$DEST_DIR/libuucpupath.dylib" ]; then
    echo "   ✓ $DEST_DIR/libuucpupath.dylib ($(stat -f%z "$DEST_DIR/libuucpupath.dylib") 字节, $(stat -f%Sm "$DEST_DIR/libuucpupath.dylib"))"
else
    echo "   ✗ 未安装"
fi

echo
echo "2) LaunchAgent（登录自启）"
if [ -f "$PLIST" ]; then
    echo "   ✓ plist 存在"
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "   ✓ 已加载" || echo "   ！已写文件但未加载"
else
    echo "   ✗ 无 plist（不会开机自启）"
fi

echo
echo "3) 注入环境变量（当前 launchd 环境）"
ENV_VAL="$(launchctl getenv DYLD_INSERT_LIBRARIES)"
if [ -n "$ENV_VAL" ]; then
    echo "   ✓ [$ENV_VAL]"
else
    echo "   ✗ 为空（未注入）"
fi

echo
echo "4) UU 进程内是否真的生效"
if grep -q "vtable 槽替换" /tmp/uucpu.log 2>/dev/null; then
    grep -E "libuucpupath 已加载|vtable 槽替换|CPU 转换成功" /tmp/uucpu.log 2>/dev/null | tail -4
    echo "   （日志：/tmp/uucpu.log）"
else
    echo "   ！日志中无生效记录（可能尚未有会话，或未安装）"
fi

echo
echo "5) UU 组件进程"
pgrep -fl "UURemoteServer|MacOS/UURemote" | head -4

echo
echo "6) 磁盘补丁（配合项：Metal 门禁 / 低延迟 RC）"
LIB="/Applications/UURemote.app/Contents/Frameworks/libstreamer.dylib"
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/patch_tool.py"
if [ -f "$P" ] && [ -f "$LIB" ]; then
    python3 "$P" check "$LIB" 2>/dev/null | head -6 || echo "   （检查失败）"
else
    echo "   ！找不到 patch_tool.py 或 libstreamer.dylib"
fi
echo "   注：UU 自动更新会覆盖磁盘补丁，需重跑 uu.sh install（需一次 sudo）"

echo
echo "7) 实测吞吐（本次会话）"
grep -E "CPU 转换成功" /tmp/uucpu.log 2>/dev/null | tail -2 || echo "   （无会话记录）"

echo
echo "=========================================================="
