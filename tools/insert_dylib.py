#!/usr/bin/env python3
"""Mach-O 直接修补：往二进制里加一条 LC_LOAD_DYLIB（不用环境变量）
支持 fat/universal 与 thin；优先复用 load commands 尾部 padding，不够则整体后移。
用法:
  自查:  insert_dylib.py --check <binary>
  修补:  insert_dylib.py --add <binary> <dylib_path> [--arch x86_64]
  还原:  insert_dylib.py --restore <binary>   # 依赖同目录 .dylibbak 备份
"""
import struct, sys, os, shutil, subprocess

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D


def parse_slices(data):
    """返回 [(cputype, offset, size)]；thin 时 offset=0"""
    magic = struct.unpack('>I', data[:4])[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack('>I', data[4:8])[0]
        is64 = magic == FAT_MAGIC_64
        esz = 32 if is64 else 20
        out = []
        for i in range(nfat):
            base = 8 + i * esz
            cputype = struct.unpack('>i', data[base:base + 4])[0]
            off = struct.unpack('>I', data[base + 8:base + 12])[0]
            size = struct.unpack('>I', data[base + 12:base + 16])[0]
            out.append((cputype, off, size))
        return out, True
    return [(struct.unpack('<i', data[4:8])[0], 0, len(data))], False


CPU_NAMES = {7: 'i386', 0x01000007: 'x86_64', 12: 'arm', 0x0100000C: 'arm64'}


def slice_info(data, off):
    magic = struct.unpack('<I', data[off:off + 4])[0]
    if magic != MH_MAGIC_64:
        return None
    ncmds = struct.unpack('<I', data[off + 16:off + 20])[0]
    sizeofcmds = struct.unpack('<I', data[off + 20:off + 24])[0]
    cputype = struct.unpack('<i', data[off + 4:off + 8])[0]
    # 第一个段文件偏移
    p = off + 32
    first_sect_off = None
    text_filesize = None
    csoff = cssize = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', data[p:p + 8])
        if cmd == LC_SEGMENT_64 and first_sect_off is None:
            segname = data[p + 8:p + 24].rstrip(b'\0').decode(errors='replace')
            nsects = struct.unpack('<I', data[p + 64:p + 68])[0]
            filesize = struct.unpack('<Q', data[p + 48:p + 56])[0]
            # 段内第一个 section 的 offset（相对 slice 起点）——真正的可用空间边界
            sp = p + 72
            for _s in range(nsects):
                soff = struct.unpack('<I', data[sp + 48:sp + 52])[0]
                if first_sect_off is None or soff < first_sect_off:
                    first_sect_off = soff
                sp += 80
            if segname == '__TEXT':
                text_filesize = filesize
        if cmd == LC_CODE_SIGNATURE:
            csoff, cssize = struct.unpack('<II', data[p + 8:p + 16])
        p += cmdsize
    # 若段内无 section（罕见），退化为按 __TEXT 段 filesize 判断
    boundary = first_sect_off if first_sect_off is not None else text_filesize
    return dict(ncmds=ncmds, sizeofcmds=sizeofcmds, cputype=cputype,
                hdr_end=off + 32 + sizeofcmds, boundary=boundary,
                csoff=csoff, cssize=cssize, lc_start=off + 32)


def do_check(path, want=None):
    data = open(path, 'rb').read()
    slices, isfat = parse_slices(data)
    print(f"  文件: {os.path.basename(path)}  {'FAT(通用二进制)' if isfat else 'thin'}  {len(data)} 字节")
    ok_any = False
    for cputype, off, size in slices:
        si = slice_info(data, off)
        if not si:
            continue
        name = CPU_NAMES.get(cputype, hex(cputype))
        hdr_end_rel = si['hdr_end'] - off
        pad = si['boundary'] - hdr_end_rel
        need = 0
        if want:
            n = len(want.encode()) + 1
            need = (24 + n + 7) // 8 * 8
        verdict = '够 ✔' if (not want or pad >= need) else f'不够（差 {need - pad}）✘'
        print(f"    [{name:>7}] 段数={si['ncmds']:>4} lc_end={hdr_end_rel} 首section={si['boundary']} "
              f"padding={pad} {'需 '+str(need) if want else ''} → {verdict}")
        if not want or pad >= need:
            ok_any = True
    return ok_any


def do_add(path, dylib, want_arch=None):
    data = bytearray(open(path, 'rb').read())
    slices, isfat = parse_slices(data)
    plan = []
    for cputype, off, size in slices:
        if want_arch and CPU_NAMES.get(cputype) != want_arch:
            continue
        si = slice_info(bytes(data), off)
        if not si:
            continue
        n = len(dylib.encode()) + 1
        cmdsize = (24 + n + 7) // 8 * 8
        hdr_end_rel = si['hdr_end'] - off
        pad = si['boundary'] - hdr_end_rel
        plan.append((cputype, off, si, cmdsize, pad, n))
        print(f"    [{CPU_NAMES.get(cputype,hex(cputype)):>7}] 需 {cmdsize} 字节, padding {pad} → "
              f"{'直接插入 ✔' if pad >= cmdsize else '需后移 ✘（暂不支持，改用 x86_64 slice）'}")

    # 从后往前处理，避免偏移失效（fat 各 slice 独立，thin 只有一个）
    for cputype, off, si, cmdsize, pad, n in sorted(plan, key=lambda x: -x[1]):
        if pad < cmdsize:
            return False
        lc_start = si['lc_start']
        newcmd = struct.pack('<II', LC_LOAD_DYLIB, cmdsize)
        # struct dylib { lc_str name; uint32 timestamp; current_ver; compat_ver; }
        # lc_str 偏移相对本 load command 起始 ⇒ 名字紧跟在 24 字节头部之后
        newcmd += struct.pack('<IIII', 24, 0, 0, 0)
        newcmd += dylib.encode() + b'\0'
        newcmd += b'\0' * (cmdsize - len(newcmd))
        hdr_end_abs = si['hdr_end']
        data[hdr_end_abs:hdr_end_abs + cmdsize] = newcmd
        # 明确清零 padding 中可能残留的旧数据（保证 dyld 解析安全）
        struct.pack_into('<I', data, off + 16, si['ncmds'] + 1)
        struct.pack_into('<I', data, off + 20, si['sizeofcmds'] + cmdsize)
        print(f"    [{CPU_NAMES.get(cputype,hex(cputype))}] 已加 LC_LOAD_DYLIB → {dylib}")
    open(path, 'wb').write(bytes(data))
    return True


def resign(path):
    ident = os.path.basename(path)
    r = subprocess.run(['codesign', '-f', '-s', '-', '--identifier', ident, path],
                       capture_output=True, text=True)
    return r.returncode == 0


def main():
    if len(sys.argv) < 3:
        print(__doc__); return 1
    mode, path = sys.argv[1], sys.argv[2]
    if mode == '--check':
        want = sys.argv[3] if len(sys.argv) > 3 else None
        do_check(path, want); return 0
    if mode == '--restore':
        bak = path + '.dylibbak'
        if not os.path.exists(bak):
            print(f"  ✘ 找不到备份 {bak}"); return 1
        shutil.copy2(bak, path)
        print(f"  ✔ 已还原 {path}")
        return 0
    if mode == '--add':
        if len(sys.argv) < 4:
            print("  用法: --add <binary> <dylib_path>"); return 1
        dylib = sys.argv[3]
        arch = None
        if '--arch' in sys.argv:
            arch = sys.argv[sys.argv.index('--arch') + 1]
        # 备份路径可用 IDB_BACKUP 指定 —— 目标常位于 .app 包内，
        # 把 .dylibbak 留在包里会污染 CodeResources 且会被一起签名。
        bak = os.environ.get('IDB_BACKUP') or (path + '.dylibbak')
        if not os.path.exists(bak):
            shutil.copy2(path, bak)
            print(f"  ✔ 已备份 → {bak}")
        else:
            print(f"  （沿用已有备份 {bak}）")
        if not do_add(path, dylib, arch):
            print("  ✘ 失败：padding 不足")
            shutil.copy2(bak, path)
            return 1
        print(f"  重签名: {'✔' if resign(path) else '✘'}")
        return 0
    print(__doc__); return 1


if __name__ == '__main__':
    sys.exit(main())
