#!/bin/bash
# ============================================================================
# 免 sudo 回退：把备份的正式 App 换回来（撤销 tools/install-app-bundle.sh）
# ============================================================================
set -uo pipefail
D="${UURT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP=/Applications/UURemote.app
BK="$D/app-bundle-backup/UURemote.app"

c_ok=$'\033[32m'; c_no=$'\033[31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'
ok(){ printf '%s✔%s %s\n' "$c_ok" "$c_off" "$1"; }
no(){ printf '%s✘%s %s\n' "$c_no" "$c_off" "$1"; }
hd(){ printf '\n%s=== %s ===%s\n' "$c_hd" "$1" "$c_off"; }

hd "回退：换回备份的正式 App"
[ -d "$BK" ] || { no "找不到备份 $BK"; exit 1; }

pkill -f 'UURemote.app/Contents/MacOS/UURemote'        2>/dev/null || true
pkill -f 'UURemote.app/Contents/Helpers/UURemoteServer' 2>/dev/null || true
pkill -f 'UURemote.app/Contents/XPCServices/UURemoteHelper' 2>/dev/null || true
pkill -f UURemoteService 2>/dev/null || true
sleep 3

rm -rf "$D/app-bundle-returned"
mv "$APP" "$D/app-bundle-returned" 2>/dev/null || true
mv "$BK" "$APP" || { no "回退失败：备份移不回来"; exit 1; }
ok "已换回备份包"

codesign --verify --deep --strict "$APP" 2>/dev/null && ok "签名校验通过" || no "签名校验未通过（可能是备份时已被签名损坏）"
python3 "$D/patch_tool.py" check "$APP/Contents/Frameworks/libstreamer.dylib" | sed 's/^/  /'
open -a UURemote 2>/dev/null || true
echo
ok "回退完成（当前包的补丁状态见上方输出）"
echo "  被换下的补丁包留在：$D/app-bundle-returned（不需要可删）"
