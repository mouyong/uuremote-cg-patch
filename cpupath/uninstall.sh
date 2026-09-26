#!/bin/bash
# UU远程 CPU 转换路径修复 —— 卸载（恢复原状）
#
# 说明：plist 无需显式卸载——删掉文件后下次登录不再加载；
#       当前会话中若已加载，因 apply.sh 已删除，它什么也不做（无害）。
set -u

DEST_DIR="$HOME/Library/Application Support/UUCpuPath"
PLIST="$HOME/Library/LaunchAgents/com.uuremote-cg-patch.cpupath.plist"
UU_AGENT="com.netease.uuremote.agent"

echo "=== 1. 删除 LaunchAgent 与应用脚本（下次登录不再自启）==="
rm -f "$PLIST" && echo "   已删除 $PLIST"
rm -rf "$DEST_DIR" && echo "   已删除 $DEST_DIR"
ls "$PLIST" >/dev/null 2>&1 && echo "   ！plist 仍存在" || echo "   ✓ plist 已清除"

echo
echo "=== 2. 清除注入环境变量 ==="
launchctl unsetenv DYLD_INSERT_LIBRARIES
echo "   DYLD_INSERT_LIBRARIES=[$(launchctl getenv DYLD_INSERT_LIBRARIES)]"

echo
echo "=== 3. 重启 UU 栈（恢复原状）==="
P1="UURemote""Server"; P2="MacOS/UU""Remote"; P3="UU""RemoteService"
pkill -f "$P1" 2>/dev/null; pkill -f "$P2" 2>/dev/null; pkill -f "$P3" 2>/dev/null
sleep 4
launchctl kickstart -k "gui/$(id -u)/$UU_AGENT" 2>&1
sleep 8
open -a UURemote 2>/dev/null
sleep 10

echo
echo "=== 4. UU 组件状态 ==="
pgrep -fl "UURemoteServer|MacOS/UURemote" | head -4

echo
echo "完成。UU 已恢复原状（画面会再次黑屏——因本机无 Metal）。"
echo "注意：libstreamer.dylib 的磁盘补丁属于另一个工具，未在此卸载；"
echo "      如需一并还原，见 ../patch_tool.py unpatch 与备份文件 libstreamer.dylib.orig。"
