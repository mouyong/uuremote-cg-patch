#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""项目整理：删除无用物。★ 不搞 archive/ 目录 —— git 历史就是归档。

原则（用户口径：仓库要简洁，归档靠 git 历史）：
  1. **不往 archive/ 挪东西**。要留的东西让它在 git 历史里，工作区保持干净。
  2. 删除前分类：
     · junk        —— 垃圾 / 可再生成的构建产物，随时能重建 → 直接删
     · obsolete    —— 陈旧产物，**必须 git 已跟踪**才删（删除提交后内容即进历史，
                     随时 `git show <commit>:<path>` 取回）→ 未跟踪的一律跳过并报告
  3. 每步打印，便于核对
用法：python3 tools/cleanup.py [--apply]   （不带 --apply 只演练）
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPLY = "--apply" in sys.argv


def human(n):
    for u in ("B", "K", "M", "G"):
        if n < 1024:
            return f"{n:.0f}{u}"
        n /= 1024
    return f"{n:.0f}T"


def size_of(path):
    if os.path.isfile(path):
        return os.path.getsize(path)
    t = 0
    for dp, _, fs in os.walk(path):
        for f in fs:
            try:
                t += os.path.getsize(os.path.join(dp, f))
            except OSError:
                pass
    return t


def git_tracked(rel):
    """该路径是否已被 git 跟踪（跟踪的文件删除后，内容仍留在历史里，可恢复）"""
    r = subprocess.run(["git", "ls-files", "--error-unmatch", rel],
                       cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0


# ---------- 删除清单：(相对路径, 原因, 类别) ----------
#   junk     = 垃圾 / 可再生成的构建产物 → 不要求 git 跟踪
#   obsolete = 陈旧产物 → 要求 git 已跟踪（删掉后从历史取回）
DELETE = [
    ("__pycache__",               "Python 字节码缓存（可随时重建）", "junk"),
    ("tools/__pycache__",         "Python 字节码缓存（可随时重建）", "junk"),
    ("libstreamer.dylib.patched", "补丁库产物：uu.sh cg-install 每次由 patch_tool.py 重新生成", "junk"),
    ("--analyze.stack",           "0 字节的误建文件（某个命令把 --analyze 当文件名了）", "junk"),
    ("stage",                     "整包构建产物（如存在）", "junk"),
    ("app-bundle-backup",         "整包备份残留（如存在）", "junk"),
]

# ---------- 整组删除：互为引用、外部无引用的整套路线 ----------
# ★ 为什么按「组」而不是逐个：这类文件互相 bash 调用，逐个查引用会把彼此算成
#   「被引用」而拒绝清理。它们是一整套路线，要么全留要么全走。
#   恢复方式：git show <删除提交>~1:<路径> > <路径>
OBSOLETE_GROUP = [
    # 免 sudo「整包换位」装机路线：README 从未承认、从未实际使用
    # （stage/ 与 app-bundle-backup/ 两个产物目录始终不存在），
    # 功能已被 uu.sh 的 install / restore 取代。
    ("tools/stage-app-bundle.sh",     "免 sudo 整包换位路线（未使用，功能已被 uu.sh install 覆盖）"),
    ("tools/install-app-bundle.sh",   "同上"),
    ("tools/restore-app-bundle.sh",   "同上"),
    # 同组的验证脚本：唯一引用者就是上面的 install-app-bundle.sh，整组删后即成孤儿；
    # 且功能与 uu.sh 的 encoder / verify 子命令重叠。
    ("tools/uu-verify-encoder.sh",    "同上（验证功能与 uu.sh verify/encoder 重叠）"),
]

print("=" * 68)
print(f"项目整理（{'执行' if APPLY else '演练'}）  根目录: {ROOT}")
print("  口径：不搞 archive/ —— git 历史就是归档")
print("=" * 68)

freed = 0
removed = 0
skipped = []

print("\n【A】垃圾 / 可再生成的构建产物")
for rel, why, _kind in DELETE:
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        print(f"  – 跳过（不存在）: {rel}")
        continue
    s = size_of(p)
    print(f"  ✗ 删除 {rel:<28} {human(s):>7}   ← {why}")
    freed += s
    removed += 1
    if APPLY:
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)

print("\n【B】陈旧产物（★ 仅删 git 已跟踪的 —— 删完内容仍可从历史取回）")
for rel, why in OBSOLETE_GROUP:
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        print(f"  – 跳过（不存在）: {rel}")
        continue
    if not git_tracked(rel):
        # 从未进过 git 的文件删了就真没了 → 不擅自删，报出来让人决定
        skipped.append(rel)
        print(f"  ⚠ 未跟踪，跳过: {rel}（删了不可恢复；要先 git add 提交再删）")
        continue
    s = size_of(p)
    print(f"  ✗ 删除 {rel:<40} {human(s):>7}   ← {why}")
    freed += s
    removed += 1
    if APPLY:
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)

print("\n" + "=" * 68)
print(f"合计释放: {human(freed)}   处理项数: {removed}")
if skipped:
    print("未跟踪而未删（需先提交进 git 才可安全删除）：")
    for rel in skipped:
        print(f"  · {rel}")
if not APPLY:
    print("\n【演练模式】未做任何改动。加 --apply 实际执行。")
else:
    print("\n已执行。请 git add -A 提交本次删除（内容仍在历史里）。")
