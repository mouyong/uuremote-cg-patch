#!/bin/bash
# ============================================================================
# 免 sudo 装机：把「已打 4 类补丁 + 已重签名」的整包准备好（不动正式 App）
# ----------------------------------------------------------------------------
# 背景：/Applications/UURemote.app 内部是 root:wheel（改不了），
#       但 /Applications 目录本身对 admin 组可写 → 可以「整包换位」：
#         mv /Applications/UURemote.app <备份位置>
#         mv <stage>/UURemote.app /Applications/UURemote.app
#       本脚本只做「准备 stage 包」这一步，换位由 tools/install-app-bundle.sh 干。
# 用法：bash tools/stage-app-bundle.sh
# ============================================================================
set -uo pipefail
D="${UURT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="${UURT_APP:-/Applications/UURemote.app}"
STAGE="$D/stage/UURemote.app"

c_ok=$'\033[32m'; c_no=$'\033[31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'
ok(){ printf '%s✔%s %s\n' "$c_ok" "$c_off" "$1"; }
no(){ printf '%s✘%s %s\n' "$c_no" "$c_off" "$1"; }
hd(){ printf '\n%s=== %s ===%s\n' "$c_hd" "$1" "$c_off"; }

[ -f "$D/libstreamer.dylib.patched" ] || { no "找不到补丁库（先跑 patch_tool.py patch）"; exit 1; }

hd "1/4 复制正式 App 到 stage（不碰正式包）"
rm -rf "$D/stage"; mkdir -p "$D/stage"
ditto "$SRC" "$STAGE" || { no "复制失败"; exit 1; }
ok "已复制到 $STAGE"

hd "2/4 换上打了 4 类补丁的 libstreamer.dylib"
cp "$D/libstreamer.dylib.patched" "$STAGE/Contents/Frameworks/libstreamer.dylib" || { no "替换失败"; exit 1; }
python3 "$D/patch_tool.py" check "$STAGE/Contents/Frameworks/libstreamer.dylib" | sed 's/^/  /'

hd "3/4 用同一张自签证书重签整个 stage 包（演练模式：不杀进程、不启动 UU）"
UURT_APP="$STAGE" UURT_REHEARSE=1 bash "$D/uu.sh" sign
rc=$?
[ $rc -eq 0 ] || { no "签名失败（rc=${rc}）"; exit 1; }

hd "4/4 整包校验"
if codesign --verify --deep --strict "$STAGE"; then ok "stage 包签名校验通过"; else no "stage 包校验未通过"; exit 1; fi
echo
ok "准备就绪：$STAGE"
echo "  装机（免 sudo）：bash $D/tools/install-app-bundle.sh"
echo "  回退：          bash $D/tools/restore-app-bundle.sh"
