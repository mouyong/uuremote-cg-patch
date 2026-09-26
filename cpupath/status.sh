#!/bin/bash
# UU远程 CPU 转换路径修复 —— 状态检查
set -u

DEST_DIR="$HOME/Library/Application Support/UUCpuPath"
PLIST="$HOME/Library/LaunchAgents/com.uuremote-cg-patch.cpupath.plist"
LABEL="com.uuremote-cg-patch.cpupath"
UU_PLIST="/Library/LaunchAgents/com.netease.uuremote.agent.plist"

echo "================ UU CPU 转换路径修复 状态 ================"
echo

echo "1) 运行时文件"
if [ -f "$DEST_DIR/libuucpupath.dylib" ]; then
    echo "   ✓ $DEST_DIR/libuucpupath.dylib ($(stat -f%z "$DEST_DIR/libuucpupath.dylib") 字节, $(stat -f%Sm "$DEST_DIR/libuucpupath.dylib"))"
else
    echo "   ✗ 未安装"
fi

echo
echo "2) 注入位置（正确做法：只在 UU 自己的 LaunchAgent plist 里）"
if [ -f "$UU_PLIST" ]; then
    UU_INJ="$(sudo -n plutil -p "$UU_PLIST" 2>/dev/null | grep -o 'libuucpupath[^"]*' | head -1)"
    if [ -n "$UU_INJ" ]; then
        echo "   ✓ UU plist 已注入：${UU_INJ}"
        UPID=$(pgrep -x UURemoteService | head -1 || true)
        if [ -n "$UPID" ] && ps eww "$UPID" 2>/dev/null | tr ' ' '\n' | grep -q DYLD_INSERT; then
            echo "   ✓ 当前 UU agent(pid=${UPID}) 已取得该变量"
        else
            echo "   ！UU agent 进程里没有该变量（plist 改动尚未生效）→ 重跑 bash install.sh"
        fi
    else
        echo "   ✗ UU plist 里没有注入（对端会黑屏）→ bash install.sh"
    fi
else
    echo "   ✗ 找不到 ${UU_PLIST}（UU 未安装？）"
fi

echo
echo "3) ★ 全局注入检查（必须为空——非空会伤害整个系统）"
G="$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null)"
if [ -n "$G" ]; then
    echo "   ✗✗ 全局变量非空：[${G}]"
    echo "       后果：所有 launchd 进程（系统守护进程、pgrep、screencapture…）都会去加载"
    echo "             未签名 dylib，被 macOS 的 CODESIGNING 保护直接 SIGKILL。"
    echo "             实测一天产生 135+ 份系统进程崩溃报告、系统卡顿、System Settings 打不开。"
    echo "       修复：launchctl unsetenv DYLD_INSERT_LIBRARIES  （然后 bash install.sh）"
else
    echo "   ✓ 为空（正确）"
fi

echo
echo "4) 当前哪些进程加载了本库（应该只有 UU 系；其它是撤销全局前的遗留，会自然消失）"
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
    echo "   ✓ plist 存在"
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "   ✓ 已加载" || echo "   ！已写文件但未加载"
    [ -f "$DEST_DIR/apply.out.log" ] && tail -2 "$DEST_DIR/apply.out.log" 2>/dev/null | sed 's/^/      /'
else
    echo "   ✗ 无 plist（UU 升级后不会自动补回）"
fi

echo
echo "7) UU 组件进程"
pgrep -fl "UURemoteServer|MacOS/UURemote" | head -4 | sed 's/^/   /'

echo
echo "8) 磁盘补丁（配合项：Metal 门禁 / 低延迟 RC）"
LIB="/Applications/UURemote.app/Contents/Frameworks/libstreamer.dylib"
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/patch_tool.py"
if [ -f "$P" ] && [ -f "$LIB" ]; then
    python3 "$P" check "$LIB" 2>/dev/null | head -6 | sed 's/^/   /' || echo "   （检查失败）"
else
    echo "   ！找不到 patch_tool.py 或 libstreamer.dylib"
fi
echo "   注：UU 自动更新会覆盖磁盘补丁，需重跑 uu.sh install（需一次 sudo）"

echo
echo "9) 最近一次会话的拷贝吞吐"
grep -E "★ 成功" /tmp/uucpu.log 2>/dev/null | tail -2 | cut -c1-120 | sed 's/^/   /' || echo "   （无会话记录）"

echo
echo "=========================================================="
