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

    ★ 必须排除本脚本自己：它的 ARCHIVE_LIST 里写着这些文件名，
      grep 一定会命中 → 全部误报「有引用」（自测时踩到过）。
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
    ("--analyze.stack",            "0 字节的误建文件（某个命令把 --analyze 当文件名了）"),
    ("app-bundle-backup",          "空目录（残留）"),
    ("stage",                      "整包构建产物：tools/stage-app-bundle.sh 每次 rm -rf 后重建"),
]

# ---------- B. 归档（陈旧实验产物，保留可查）----------
ARCHIVE_LIST = [
    # 旧 shim 版本（保留 v13=上一版、v14=现役）
    "shim/libuushim_v6_shipped.dll.bak",
    "shim/libuushim_v8.dylib",
    "shim/libuushim_v9.dylib",
    "shim/libuushim_v10.dylib",
    "shim/libuushim_v11.dylib",
    "shim/libuushim_v12.dylib",
    # Sept-14 那轮 interpose 实验的中间产物
    "shim/harness_mid",
    "shim/harness.c",
    "shim/harness_mid.c",
    "shim/libmid.c",
    "shim/libmid.dylib",
    "shim/uushim.c",
    "shim/measure.sh",
    "shim/harness3-结果-20260914-1804.log",
    "shim/rehearsal-20260914-1700.log",
    "shim/rehearsal-20260914-184520.log",
    "shim/rehearsal-v2-20260914-1716.log",
    "shim/rehearsal-v3-20260914-1736.log",
    "shim/rehearsal-v4-20260914-1806.log",
    "shim/rehearsal-v4-20260914-1809-ok.log",
    "shim/rehearsal-v5-20260914-1819-ok.log",
    "shim/rehearsal-v5-20260914-1819.log",
    "shim/rehearsal-v5-复核-1825.log",
    "shim/rehearsal-v6-1837.log",
    "shim/rehearsal-v6-ok-1841.log",
    "shim/shim-log-v2-实测-20260914-1736.log",
    "shim/shim-log-v4-会话-1811.log",
    "shim/卡死采样-20260914-1804.txt",
    "shim/采样-v4-卡CFRelease-1811.txt",
    # evidence 里的原始大转储（结论已写进 .md）
    "evidence/sample-卡空转-2321.txt",
    "evidence/shim-2321.log",
    "evidence/sp8.stack",
    "evidence/th.stack",
    # 无人引用的历史工具
    "tools/lint-scripts.sh",
    "tools/screen-change.py",
    "tools/uu-autowatch.sh",
    "tools/uu-forensics.sh",
    "tools/uu-live-trace.sh",
    "tools/uu-session-watch.sh",
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

print("\n【B】归档：陈旧实验产物（移到 archive/，可随时取回）")
moved = 0
skipped_ref = []
for rel in ARCHIVE_LIST:
    src = os.path.join(ROOT, rel)
    if not os.path.exists(src):
        print(f"  – 跳过（不存在）: {rel}")
        continue
    base = os.path.basename(rel)
    # 真代码引用（.sh/.py，排除本脚本与文档）才阻止归档
    hard_ref = refs(base)
    if hard_ref:
        skipped_ref.append((rel, hard_ref))
        print(f"  ⚠ 保留（被 {hard_ref} 个脚本引用）: {rel}")
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
if skipped_ref:
    print("因被引用而保留：")
    for rel, n in skipped_ref:
        print(f"  · {rel}（{n} 处引用）")
if not APPLY:
    print("\n【演练模式】未做任何改动。加 --apply 实际执行。")
else:
    print("\n已执行。")
