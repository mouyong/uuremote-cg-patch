#!/bin/bash
# ============================================================================
# 免 sudo 装机（整包换位）—— 把 stage 好的「补丁+重签名」包换成正式 App
# ----------------------------------------------------------------------------
# 原理：/Applications 目录对 admin 组可写（drwxrwxr-x root:admin），
#       而 App 内部是 root:wheel。改不了里面，就整包换位 —— 不需要 sudo。
# 前置：先跑 bash tools/stage-app-bundle.sh 准备好 stage 包
# 回退：bash tools/restore-app-bundle.sh
# ============================================================================
set -uo pipefail
D="${UURT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP=/Applications/UURemote.app
STAGE="$D/stage/UURemote.app"
BK="$D/app-bundle-backup/UURemote.app"

c_ok=$'\033[32m'; c_no=$'\033[31m'; c_hd=$'\033[1;36m'; c_off=$'\033[0m'
ok(){ printf '%s✔%s %s\n' "$c_ok" "$c_off" "$1"; }
no(){ printf '%s✘%s %s\n' "$c_no" "$c_off" "$1"; }
hd(){ printf '\n%s=== %s ===%s\n' "$c_hd" "$1" "$c_off"; }

hd "0/6 前置检查"
[ -d "$STAGE" ] || { no "没有 stage 包，先跑 bash $D/tools/stage-app-bundle.sh"; exit 1; }
[ -d "$APP" ]   || { no "找不到 $APP"; exit 1; }
python3 "$D/patch_tool.py" check "$STAGE/Contents/Frameworks/libstreamer.dylib" | sed 's/^/  stage: /'
# 同卷检查：跨卷 mv 会变成「复制+删除」，慢且可能丢属性
v1=$(df "$APP"   | tail -1 | awk '{print $1}')
v2=$(df "$D"     | tail -1 | awk '{print $1}')
[ "$v1" = "$v2" ] || { no "$APP 与 $D 不在同一卷（${v1} vs ${v2}），换位不是原子操作 → 中止，改用 sudo 安装"; exit 1; }
ok "同卷（${v1}），换位是原子 rename"

hd "1/6 退出 UU 用户级进程（root 守护进程不动：证书没变，XPC 仍匹配）"
pkill -f 'UURemote.app/Contents/MacOS/UURemote'        2>/dev/null || true
pkill -f 'UURemote.app/Contents/Helpers/UURemoteServer' 2>/dev/null || true
pkill -f 'UURemote.app/Contents/XPCServices/UURemoteHelper' 2>/dev/null || true
pkill -f UURemoteService 2>/dev/null || true
sleep 3
pgrep -fl 'UURemote.app' | sed 's/^/  仍在跑: /' || ok "用户级进程已退出"

hd "2/6 备份正式 App → $BK"
rm -rf "$BK"; mkdir -p "$(dirname "$BK")"
mv "$APP" "$BK" || { no "备份失败（$APP 移不动？）"; exit 1; }
ok "已备份（原属主 root:wheel，回退脚本会原样移回）"

hd "3/6 换入补丁包"
mv "$STAGE" "$APP" || { no "换入失败 —— 正在回滚"; mv "$BK" "$APP"; exit 1; }
ok "已换入"

hd "4/6 校验（签名 + 补丁）"
if codesign --verify --deep --strict "$APP" 2>/dev/null; then ok "整包签名校验通过"; else no "整包校验未通过"; fi
python3 "$D/patch_tool.py" check "$APP/Contents/Frameworks/libstreamer.dylib" | sed 's/^/  /'

hd "5/6 启动 UU"
open -a UURemote 2>/dev/null || true
sleep 6
pgrep -fl 'UURemote.app' | sed 's/^/  /' | head -6

hd "6/6 提示"
cat <<EOT
  · 首次连接若提示「未授权录屏」：系统设置 → 隐私与安全性 → 录屏与系统录音，取消再勾上 UU远程
    （用的是同一张证书，多数情况不用重勾）
  · 验证编码器：bash $D/tools/uu-verify-encoder.sh
  · 回退：bash $D/tools/restore-app-bundle.sh
EOT
