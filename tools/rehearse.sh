#!/bin/bash
# 演练包装：生成「已校验」的 App 副本 → 跑安装/还原演练 → 归档日志
# 用法: bash tools/rehearse.sh
#
# 为什么需要它：ditto 生成的副本偶尔不完整（实测 4 次），会让演练的前置检查
# 误报「视频补丁不在位」。这里先校验副本的关键文件哈希与正式 App 一致，
# 不一致就重拷（最多 3 次），确保演练结果可信。
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
SRC=/Applications/UURemote.app
COPY=/tmp/uur-reh.app
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$D/shim/rehearsal-$STAMP.log"

echo "=== 演练开始 $STAMP ==="
echo "源: $SRC"
rm -rf "$COPY"

ok_copy=0
for attempt in 1 2 3; do
  ditto "$SRC" "$COPY" 2>/dev/null
  s1=$(shasum -a 256 "$SRC/Contents/Frameworks/libstreamer.dylib" 2>/dev/null | cut -d' ' -f1)
  s2=$(shasum -a 256 "$COPY/Contents/Frameworks/libstreamer.dylib" 2>/dev/null | cut -d' ' -f1)
  t1=$(shasum -a 256 "$SRC/Contents/Helpers/UURemoteServer" 2>/dev/null | cut -d' ' -f1)
  t2=$(shasum -a 256 "$COPY/Contents/Helpers/UURemoteServer" 2>/dev/null | cut -d' ' -f1)
  if [ -n "$s1" ] && [ "$s1" = "$s2" ] && [ -n "$t1" ] && [ "$t2" = "$t1" ]; then
    echo "✔ 副本校验通过（第 $attempt 次尝试）"
    ok_copy=1; break
  fi
  echo "⚠ 第 $attempt 次副本不完整（libstreamer ${s1:0:8}≠${s2:0:8} / server ${t1:0:8}≠${t2:0:8}），重试"
  rm -rf "$COPY"
  sleep 2
done

if [ "$ok_copy" != "1" ]; then
  echo "✘ 三次都无法生成完整副本，中止（正式 App 未受影响）"
  rm -rf "$COPY"
  exit 1
fi

{
  echo "--- 安装演练 ---"
  UURT_APP="$COPY" UURT_REHEARSE=1 bash "$D/uu.sh" shim-install
  echo "INSTALL_RC=$?"
  echo "--- 还原演练 ---"
  UURT_APP="$COPY" UURT_REHEARSE=1 bash "$D/uu.sh" shim-restore
  echo "RESTORE_RC=$?"
} > "$LOG" 2>&1

echo
echo "=== 结果 ==="
grep -E 'INSTALL_RC|RESTORE_RC' "$LOG" | sed 's/^/  /'
echo "  ✘ 失败条数: $(grep -c '✘' "$LOG")（应为 0）"
grep -E '错误 OU|整包校验|补丁在|确认已无' "$LOG" | head -6 | sed 's/^/  /'
echo "  日志: $LOG"

rm -rf "$COPY"
echo "=== 演练结束（副本已清理）==="
