#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""项目整理：删除无用物 + 归档陈旧实验产物（不删任何被脚本/文档引用的文件）

原则：
  1. 什么都不直接删 —— 除「垃圾」与「可再生成的构建产物」外，一律 mv 到 archive/
  2. 移动前先 grep 全仓引用，有引用就跳过（避免把活文件挪走）
  3. 每步打印，便于核对
用法：python3 tools/cleanup.py [--apply]   （不带 --apply 只演练）
"""
import os, re, shutil, subprocess, sys, time

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

def refs(basename):
    """全仓「真代码」引用计数（只算 .sh/.py，不算 .md 的史料记载）

    ★ 保留此函数供后续扩充清理清单时使用（新增单个文件到 ARCHIVE_GROUP 前，
      先手动确认它没被别的脚本引用）。
    ★ 必须排除本脚本自己：清单里写着这些文件名，grep 一定会命中 → 全部误报。
    """
    out = _grep(basename)
    n = 0
    for line in out.splitlines():
        b = os.path.basename(line)
        if b == basename:              # 文件自身
            continue
        if b in ("cleanup.py",):       # 本脚本（含清单文本）
            continue
        if line.endswith(".md"):       # 文档里的历史记载不算依赖
            continue
        n += 1
    return n

def _grep(basename):
    try:
        return subprocess.run(
            ["grep", "-rl", "--include=*.sh", "--include=*.py", "--include=*.md", basename, ROOT],
            capture_output=True, text=True).stdout
    except Exception:
        return ""

ARCHIVE = os.path.join(ROOT, "archive", time.strftime("%Y%m%d"))

# ---------- A. 直接删除（垃圾 / 可再生成的构建产物）----------
DELETE = [
    ("__pycache__",              "Python 字节码缓存（可随时重建）"),
    ("tools/__pycache__",        "Python 字节码缓存（可随时重建）"),
    ("libstreamer.dylib.patched", "补丁库产物：uu.sh cg-install 每次由 patch_tool.py 重新生成"),
    ("shim/libuushim_v14.dylib", "与 shim/libuushim.dylib 字节完全相同（纯重复，违反「只留现役版+上一版」）"),
    ("--analyze.stack",          "0 字节的误建文件（某个命令把 --analyze 当文件名了）"),
    ("stage",                    "整包构建产物（如存在）"),
    ("app-bundle-backup",        "整包备份残留（如存在）"),
]

# ---------- B. 整组归档（互为引用、外部无引用的整套路线）----------
# ★ 为什么按「组」而不是逐个：这类文件互相 bash 调用，逐个检查引用时 refs() 会把
#   彼此算成「被引用」而拒绝移动（死循环）。它们是一整套路线，要么全留要么全走。
ARCHIVE_GROUP = [
    # 免 sudo「整包换位」装机路线：README 从未承认、从未实际使用
    # （stage/ 与 app-bundle-backup/ 两个产物目录始终不存在），
    # 功能已被 uu.sh 的 install / restore 取代。
    "tools/stage-app-bundle.sh",
    "tools/install-app-bundle.sh",
    "tools/restore-app-bundle.sh",
    # 同组的验证脚本：唯一引用者就是上面的 install-app-bundle.sh，
    # 整组移走后即成孤儿；且功能与 uu.sh 的 encoder / verify 子命令重叠。
    "tools/uu-verify-encoder.sh",
]

print("=" * 68)
print(f"项目整理（{'执行' if APPLY else '演练'}）  根目录: {ROOT}")
print("=" * 68)

freed = 0
print("\n【A】删除：垃圾 / 可再生成的构建产物")
for rel, why in DELETE:
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        print(f"  – 跳过（不存在）: {rel}")
        continue
    s = size_of(p)
    print(f"  ✗ 删除 {rel:<26} {human(s):>7}   ← {why}")
    freed += s
    if APPLY:
        if os.path.isdir(p):
            shutil.rmtree(p)
        else:
            os.remove(p)

print("\n【B】整组归档：互为引用的整套路线（一并移走）")
moved = 0
for rel in ARCHIVE_GROUP:
    src = os.path.join(ROOT, rel)
    if not os.path.exists(src):
        print(f"  – 跳过（不存在）: {rel}")
        continue
    s = size_of(src)
    dst = os.path.join(ARCHIVE, rel)
    print(f"  → 归档 {rel:<40} {human(s):>7}")
    moved += 1
    freed += s
    if APPLY:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.move(src, dst)

print("\n" + "=" * 68)
print(f"删除/归档合计释放: {human(freed)}   归档文件数: {moved}")
if not APPLY:
    print("\n【演练模式】未做任何改动。加 --apply 实际执行。")
else:
    print("\n已执行。")
