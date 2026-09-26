#!/bin/bash
# UU远程 CPU 转换路径修复 —— 卸载（恢复原状）
#
# 做了什么：
#   ① 从 UU 自己的 LaunchAgent plist 里移除我们加的 DYLD_INSERT_LIBRARIES（只删这一个键）
#   ② 清除历史遗留的**全局**注入变量（老版本曾用 launchctl setenv，会伤害系统进程）
#   ③ 删掉本工具自己的运行时目录与 LaunchAgent
#
# 说明：plist 无需显式卸载——删掉文件后下次登录不再加载；
#       当前会话中若已加载，因目录已删除它什么也不做（无害）。
set -u

DEST_DIR="$HOME/Library/Application Support/UUCpuPath"
PLIST="$HOME/Library/LaunchAgents/com.uuremote-cg-patch.cpupath.plist"
UU_AGENT="com.netease.uuremote.agent"
UU_PLIST="/Library/LaunchAgents/com.netease.uuremote.agent.plist"

echo "=== 1. 从 UU plist 移除注入（只删我们的键）==="
if [ -f "$UU_PLIST" ]; then
    # 若 EnvironmentVariables 里只有我们这一个键，就删整个 dict；否则只删该键
    NKEYS=$(sudo -n plutil -p "$UU_PLIST" 2>/dev/null | awk '/EnvironmentVariables/{f=1;next} f&&/^\s+"/{c++} END{print c+0}')
    if sudo -n plutil -p "$UU_PLIST" 2>/dev/null | grep -q "DYLD_INSERT_LIBRARIES"; then
        if [ "${NKEYS:-0}" -le 1 ]; then
            sudo -n /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables" "$UU_PLIST" 2>&1
            echo "   已删除 EnvironmentVariables（其中只有本工具的键）"
        else
            sudo -n /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:DYLD_INSERT_LIBRARIES" "$UU_PLIST" 2>&1
            echo "   已删除 DYLD_INSERT_LIBRARIES（保留了 EnvironmentVariables 里的其它键）"
        fi
        echo "   语法校验：$(sudo -n plutil -lint "$UU_PLIST" 2>&1)"
    else
        echo "   UU plist 中本就没有本工具的注入 ✓"
    fi
else
    echo "   找不到 ${UU_PLIST}（UU 未安装？）—— 跳过"
fi

echo
echo "=== 2. 删除本工具的 LaunchAgent 与运行时目录 ==="
[ -f "$PLIST" ] && rm -f "$PLIST" && echo "   已删除 $PLIST" || echo "   无需删除 $PLIST"
[ -d "$DEST_DIR" ] && rm -rf "$DEST_DIR" && echo "   已删除 $DEST_DIR" || echo "   无需删除 $DEST_DIR"

echo
echo "=== 3. 清除全局注入变量（历史遗留，务必清）==="
launchctl unsetenv DYLD_INSERT_LIBRARIES
echo "   DYLD_INSERT_LIBRARIES=[$(launchctl getenv DYLD_INSERT_LIBRARIES)]"

echo
echo "=== 4. 让 UU 重读 plist（unload + load；kickstart 不会重读）==="
launchctl unload "$UU_PLIST" 2>/dev/null
sleep 3
launchctl load -w "$UU_PLIST" 2>/dev/null
sleep 8
open -a UURemote 2>/dev/null
sleep 6

echo
echo "=== 5. UU 组件状态 ==="
pgrep -fl "UURemoteServer|MacOS/UURemote" | head -4 | sed 's/^/   /'

echo
echo "完成。UU 已恢复原状（画面会再次黑屏——因本机无 Metal）。"
echo "注意：libstreamer.dylib 的磁盘补丁属于另一个工具，未在此卸载；"
echo "      如需一并还原，见 ../uu.sh shim-restore 与备份文件 libstreamer.dylib.orig。"
