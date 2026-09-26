#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
UU远程 补丁工具（版本自适应）— 本机（Macmini5,2 + OCLP macOS 15）专用

本机两类硬件限制让 UU 默认路径必然失败：
  A. 无 IOGPU → ScreenCaptureKit(SCK) 必挂（-3802 / 远程队列 -16665）
  B. 无 Metal GPU → VideoToolbox 硬件编码器初始化必挂
     （日志：Failed to create metal device. / failed to init VIDEO TOOLBOX
       encoder, error: 12），导致采集正常但零帧 → 控制端永远「正在传输画面」

三处补丁：

【1】视频采集器 force-cg
    CreateScreenCapturer() 内：
        test %eax,%eax
        je   +7               <-- 原本：macOS < 14 才走 CoreGraphics
        call ScreenCapturerSck::Create()   <-- 本机走这条 → -3802
        jmp  +5
        call ScreenCapturerCG::Create()    <-- 要改走这条
    je(0x74) → jmp(0xEB)。

【2】音频采集器 no-sck-audio
    SckAudioCapture 的 构造/析构/Start 各有
        __availability_version_check(1, 13, 0, 0) 守卫；
    掰成「不满足」→ 按老系统处理（不建 SCK 音频流，Start 直接 return 0）。
    代价：本机无远程声音（与本机 SCK 永不成功一致）。

【3】编码器 force-software
    VideoToolboxEncoderT::ResetVTCompressionSession() 里无条件写
        encoderSpec[EnableHardwareAcceleratedVideoEncoder] = kCFBooleanTrue
    本机无 Metal → VT 硬件编码器初始化失败 → 编码器反复重建、零帧。
    改法：只把这条「值加载」的字面量池位移改指向 ___kCFBooleanFalse
    （等价 UU 自带的 force_software_encoder）。不动
    EnableLowLatencyRateControl（那是另一个槽位）。

【4】Metal 门禁 (metal-gate)  ★ 只补【3】没用，必须同时补这一处
    ResetVTCompressionSession() 一开头就先造 Metal 设备：
        0x1fd000: MTLCreateSystemDefaultDevice() → newCommandQueue()
                   → CVMetalTextureCacheCreate()
        回到本函数后：cmpq $0, 0x90(%rbx)   ; 设备指针
                      je   失败块            ; 空 → 打 "Failed to create metal device."
        失败块末尾：cmpq $0, 0x90(%rbx)
                    jne  继续              ; 空的落空 → 打日志 → 返回 false
    → 本机 MTLCreateSystemDefaultDevice() 返回 nil，必然走失败块，
      ResetVTCompressionSession 直接 return false → 上层 make_error_code(0xc)
      → 日志 "failed to init VIDEO TOOLBOX encoder, error: 12"
      → CreateVideoEncoder 反复重建、EncodeFrame 永远为 0 → 控制端永远「正在传输画面」。
    ★ 这一步在写 EnableHardwareAcceleratedVideoEncoder 之前，所以只补【3】毫无作用。
    改法：两处「设备为空就放弃」的分支都掰成「照常继续」：
        je  → 6 字节 NOP（落空继续）
        jne → e9 rel32 + NOP（无条件跳到继续）
      设备留空不影响编码：编码器只用它做 IOSurface→MTLTexture 的 GPU 零拷贝，
      软件编码走 CPU 路径；且该字段在编码器内只被空安全地拷贝/判空，
      不参与 VTCompressionSessionCreate。
    定位靠「互指不变量」：A(je) 的目标 == B(jne) 的落空地址，且
      B(jne) 的目标 == A(je) 的落空地址 —— 两处互为对方反面，唯一配对。

不硬编码偏移：靠符号 + otool 注释定位；定位不确定时返回 unknown，绝不瞎打。

子命令：
  check   <lib>           三行：video/audio/encoder 状态（patched/orig/unknown）
  locate  <lib>           打印视频补丁点（文件偏移 映射差），供脚本自检
  patch   <src> <dst>     打三处补丁
  unpatch <src> <dst>     反向还原
  encsite <lib>           打印编码器补丁点信息
"""
import re
import struct
import subprocess
import sys

# ---- 视频：mov %rbx,%rdi; test %eax,%eax; je/jmp +7; call ...; jmp +5; call ...
VIDEO_PAT = re.compile(rb"\x48\x89\xdf\x85\xc0([\x74\xeb])\x07\xe8")
SCK_SYM = "__ZN8streamer7capture17ScreenCapturerSck6CreateEv"
CG_SYM = "__ZN8streamer7capture16ScreenCapturerCG6CreateEv"

# ---- 音频：movl $1,%edi; movl $13,%esi; xor %edx,%edx; xor %ecx,%ecx; call <avail>
AUDIO_PRO = re.compile(rb"\xbf\x01\x00\x00\x00\xbe\x0d\x00\x00\x00\x31\xd2\x31\xc9\xe8")

# ---- 编码器：VTCompressionSession 的 encoderSpec 里「硬件加速」键与真假值
ENC_KEY = "_kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder"
ENC_TRUE = "___kCFBooleanTrue"      # 对象直取风格（单次解引用）
ENC_FALSE = "___kCFBooleanFalse"
VT_RESET = "ResetVTCompressionSession"


def nm_symbols(path):
    try:
        out = subprocess.run(["nm", "-n", path], capture_output=True, text=True, timeout=300).stdout
    except Exception:
        return {}
    m = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 3 and re.fullmatch(r"[0-9a-fA-F]+", p[0]):
            m[p[2]] = int(p[0], 16)
    return m


def va_to_file(path, va):
    """按 Mach-O 段表把 VA 换算成文件偏移"""
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True, timeout=300).stdout
    vmaddr = fileoff = vmsize = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("segname "):
            vmaddr = fileoff = vmsize = None
        elif s.startswith("vmaddr "):
            vmaddr = int(s.split()[1], 16)
        elif s.startswith("vmsize "):
            vmsize = int(s.split()[1], 16)
        elif s.startswith("fileoff "):
            fileoff = int(s.split()[1], 16)
            if None not in (vmaddr, vmsize, fileoff) and vmaddr <= va < vmaddr + vmsize:
                return va - vmaddr + fileoff
    return None


def got_slots(path):
    """otool -Iv：拿字面量池里各符号的槽位地址（如 ___kCFBooleanFalse）"""
    out = subprocess.run(["otool", "-Iv", path], capture_output=True, text=True, timeout=300).stdout
    slots = {}
    for line in out.splitlines():
        m = re.match(r"\s*0x([0-9a-f]+)\s+\d+\s+(\S+)\s*$", line)
        if m:
            slots.setdefault(m.group(2), int(m.group(1), 16))
    return slots


# ------------------------- 视频补丁点 -------------------------
def video_candidates(data):
    """产出 (跳转指令偏移, sck目标文件偏移, cg目标文件偏移)"""
    out = []
    for m in VIDEO_PAT.finditer(data):
        F = m.start()
        if F + 19 > len(data):
            continue
        if not (data[F + 12] == 0xEB and data[F + 13] == 0x05):
            continue
        sck_off = F + 12 + int.from_bytes(data[F + 8:F + 12], "little", signed=True)
        cg_off = F + 19 + int.from_bytes(data[F + 15:F + 19], "little", signed=True)
        out.append((F + 5, sck_off, cg_off))
    return out


def locate_video(path, data=None):
    """返回 (跳转字节文件偏移, 文件偏移与VA的映射差) 或 (None, None)"""
    data = data if data is not None else open(path, "rb").read()
    syms = nm_symbols(path)
    sck_va, cg_va = syms.get(SCK_SYM), syms.get(CG_SYM)
    cands = video_candidates(data)
    if not cands:
        return None, None
    if sck_va is not None and cg_va is not None:
        matched = [(je, sck_va - sck_off)
                   for je, sck_off, cg_off in cands
                   if sck_va - sck_off == cg_va - cg_off]
        if len(matched) == 1:
            return matched[0]
        if len(matched) > 1:
            for je, d in matched:
                if d in (0, 0x4000, -0x4000):
                    return je, d
            return matched[0]
        return None, None
    if len(cands) == 1:
        return cands[0][0], 0
    return None, None


# ------------------------- 音频补丁点 -------------------------
def audio_candidates(data):
    """
    产出 (跳转指令偏移, 'short'|'near', 'orig'|'patched', 目标文件偏移)
    short: 0x74 <rel8>(orig) / 0xeb <rel8>(patched)
    near : 0x0f 0x84 <rel32>(orig) / 0xe9 <rel32> 0x90(patched)
    """
    out = []
    for m in AUDIO_PRO.finditer(data):
        nxt = m.start() + 19
        if nxt + 8 > len(data):
            continue
        if data[nxt:nxt + 2] != b"\x85\xc0":
            continue
        j = nxt + 2
        op = data[j]
        if op in (0x74, 0xEB):
            out.append((j, "short", "orig" if op == 0x74 else "patched",
                        j + 2 + data[j + 1]))
        elif data[j:j + 2] == b"\x0f\x84":
            rel = int.from_bytes(data[j + 2:j + 6], "little", signed=True)
            out.append((j, "near", "orig", j + 6 + rel))
        elif op == 0xE9:
            rel = int.from_bytes(data[j + 1:j + 5], "little", signed=True)
            out.append((j, "near", "patched", j + 5 + rel))
    return out


# ------------------------- 编码器补丁点 -------------------------
# ResetVTCompressionSession 里构造 encoderSpec 的关键片段（结构特征，不依赖偏移）：
#   48 8b 05 <disp>   movq pool(%rip),%rax        ; 硬件加速键
#   48 8b 00          movq (%rax),%rax
#   48 89 45 <x>      movq %rax,-X(%rbp)
#   48 8b 05 <disp>   movq pool(%rip),%rax        ; 值 = kCFBooleanTrue  ★要改这条
#   48 89 45 <y>      movq %rax,-Y(%rbp)
#   48 8b 3d <disp>   movq pool(%rip),%rdi        ; NSDictionary 类
# 自校验：第二条 load 的目标槽位（文件空间）必须等于 otool -Iv 给出的
#         ___kCFBooleanTrue 槽位地址 —— 对上了才动手。
ENC_PAT = re.compile(
    rb"\x48\x8b\x05(?P<k1>.{4})\x48\x8b\x00\x48\x89\x45.\x48\x8b\x05(?P<v>.{4})\x48\x89\x45.\x48\x8b\x3d",
    re.DOTALL)


def find_reset_sym(path):
    for name in nm_symbols(path):
        if VT_RESET in name:
            return name
    return None


def encoder_site(path):
    """
    返回 dict(file_off, old_disp, new_disp, slot_true, slot_false) 或 None
    file_off = 「值加载」指令里 4 字节位移字段的文件偏移。
    """
    data = open(path, "rb").read()
    slots = got_slots(path)
    slot_key = slots.get(ENC_KEY)
    slot_true = slots.get(ENC_TRUE)
    slot_false = slots.get(ENC_FALSE)
    if None in (slot_key, slot_true, slot_false):
        return None

    hits = []
    for m in ENC_PAT.finditer(data):
        k1pos = m.start("k1")
        d1 = struct.unpack("<i", data[k1pos:k1pos + 4])[0]
        tgt_key = k1pos + 4 + d1          # 键槽位（文件空间，不受补丁影响）
        shift = tgt_key - slot_key        # 代码区「文件空间 - VA」常量
        vpos = m.start("v")
        dv = struct.unpack("<i", data[vpos:vpos + 4])[0]
        val_va = vpos + 4 + dv - shift    # 值槽位换算回 VA
        if val_va not in (slot_true, slot_false):
            continue
        hits.append((vpos, shift, "orig" if val_va == slot_true else "patched"))
    if len(hits) != 1:
        return None
    vpos, shift, state = hits[0]
    old_disp = (slot_true + shift) - (vpos + 4)
    new_disp = (slot_false + shift) - (vpos + 4)
    return {"file_off": vpos, "old_disp": old_disp, "new_disp": new_disp,
            "slot_true": slot_true, "slot_false": slot_false,
            "shift": shift, "state": state}


def encoder_state(path):
    site = encoder_site(path)
    if not site:
        return "unknown", None
    return site["state"], site


# ------------------------- 低延迟 RC 补丁点 -------------------------
# 现场根因：ResetVTCompressionSession 里给 encoderSpec 无条件写
#     encoderSpec[EnableLowLatencyRateControl] = kCFBooleanTrue
# 而 VideoToolbox 的「低延迟码率控制」强制要求**硬件编码器**：
#   本机（仅 Apple H.264 SW，无硬编）→ hw=T + 低延迟=T ⇒ kVTParameterErr(-12902) 建会话失败
#                                      hw=F + 低延迟=T ⇒ 同样失败（只改 hw 无效）
#                                      hw=F + 不设/关低延迟 ⇒ 成功，且 UU 全套属性都吃下、出码正常
#   对照机（M2 有硬编）→ hw=T + 低延迟=T 成功 ⇒ 失败点确认为「低延迟强制要硬编」
# 改法：把「值 = ___kCFBooleanTrue」那条 load 改成指向 ___kCFBooleanFalse（语义等价于 UU 自己的降级重试）。
# 结构特征（与符号槽位自校验，不依赖固定偏移）：
#   48 8b 05 <disp>   movq pool(%rip),%rax   ; 低延迟键
#   48 8b 08          movq (%rax),%rcx
#   48 8b 35 <disp>   movq pool(%rip),%rsi   ; 选择子 setObject:forKeyedSubscript:
#   48 8b 15 <disp>   movq pool(%rip),%rdx   ; 值 = kCFBooleanTrue  ★要改这条
LL_KEY = "_kVTVideoEncoderSpecification_EnableLowLatencyRateControl"
LL_PAT = re.compile(
    rb"\x48\x8b\x05(?P<k>.{4})\x48\x8b\x08\x48\x8b\x35.{4}\x48\x8b\x15(?P<v>.{4})",
    re.DOTALL)


def lowlat_site(path):
    """
    返回 dict(file_off, old_disp, new_disp, slot_true, slot_false, state) 或 None
    file_off = 「值加载」指令里 4 字节位移字段的文件偏移。
    """
    data = open(path, "rb").read()
    slots = got_slots(path)
    slot_key = slots.get(LL_KEY)
    slot_true = slots.get(ENC_TRUE)
    slot_false = slots.get(ENC_FALSE)
    if None in (slot_key, slot_true, slot_false):
        return None

    hits = []
    for m in LL_PAT.finditer(data):
        kpos = m.start("k")
        d1 = struct.unpack("<i", data[kpos:kpos + 4])[0]
        tgt_key = kpos + 4 + d1                 # 键槽位（文件空间）
        shift = tgt_key - slot_key              # 代码区「文件空间 - VA」常量
        vpos = m.start("v")
        dv = struct.unpack("<i", data[vpos:vpos + 4])[0]
        val_va = vpos + 4 + dv - shift
        if val_va not in (slot_true, slot_false):
            continue
        hits.append((vpos, shift, "orig" if val_va == slot_true else "patched"))
    if len(hits) != 1:
        return None
    vpos, shift, state = hits[0]
    return {"file_off": vpos,
            "old_disp": (slot_true + shift) - (vpos + 4),
            "new_disp": (slot_false + shift) - (vpos + 4),
            "slot_true": slot_true, "slot_false": slot_false,
            "shift": shift, "state": state}


def lowlat_state(path):
    s = lowlat_site(path)
    return (s["state"] if s else "unknown"), s


def _apply_lowlat(data, site, to_patched):
    disp = site["new_disp"] if to_patched else site["old_disp"]
    data[site["file_off"]:site["file_off"] + 4] = struct.pack("<i", disp)


# ------------------------- Metal 门禁补丁点 -------------------------
# ResetVTCompressionSession 里两处「Metal 设备为空就放弃」：
#   48 83 bb 90 00 00 00 00   cmpq $0x0, 0x90(%rbx)      ; 设备指针
#   0f 84 <rel32>             je  失败块                  ; A：空 → 失败
#   0f 85 <rel32>             jne 继续                    ; B：非空 → 继续
# 互指不变量：A 的目标 == B 的落空；B 的目标 == A 的落空。
MG_CMP = b"\x48\x83\xbb\x90\x00\x00\x00\x00"
MG_NOP6 = b"\x90" * 6


def _mg_sites(data):
    """扫出所有候选：[(跳转指令文件偏移, 'je'|'jne'|'nop', 目标文件偏移 或 None)]"""
    out = []
    i = data.find(MG_CMP)
    while i != -1:
        j = i + len(MG_CMP)          # 跳转指令起始
        if j + 6 <= len(data):
            nb = data[j:j + 6]
            if nb[:2] == b"\x0f\x84":
                rel = int.from_bytes(nb[2:6], "little", signed=True)
                out.append((j, "je", j + 6 + rel))
            elif nb[:2] == b"\x0f\x85":
                rel = int.from_bytes(nb[2:6], "little", signed=True)
                out.append((j, "jne", j + 6 + rel))
            elif nb == MG_NOP6:
                out.append((j, "nop", None))
            elif nb[0] == 0xE9:
                rel = int.from_bytes(nb[1:5], "little", signed=True)
                out.append((j, "jmp", j + 5 + rel))
        i = data.find(MG_CMP, i + 1)
    return out


def _mg_find(data):
    """
    返回 dict(branch4, branch5, state) 或 None：
      branch4/branch5 为两处跳转指令（je / jne）的文件偏移。
      state = 'orig' | 'patched'
    配对条件（唯一）：
      orig    : je 目标 == jne 落空  且  jne 目标 == je 落空
      patched : je 处已是 6 个 NOP   且  jne 处是 e9 且目标 == je 落空
    定位不到时返回 None（绝不瞎打）。
    """
    sites = _mg_sites(data)
    je = [(o, t) for o, k, t in sites if k == "je"]
    jne = [(o, t) for o, k, t in sites if k == "jne"]
    nop = [o for o, k, t in sites if k == "nop"]
    jmp = [(o, t) for o, k, t in sites if k == "jmp"]

    # 已打过补丁：je 位变成 6 个 NOP，jne 位变成 e9（落空那颗补 0x90）
    for o4 in nop:
        for o5, t5 in jmp:
            if t5 == o4 + 6 and data[o5 + 5] == 0x90:
                return {"branch4": o4, "branch5": o5, "state": "patched"}

    for o4, t4 in je:
        for o5, t5 in jne:
            if t4 == o5 + 6 and t5 == o4 + 6:
                return {"branch4": o4, "branch5": o5, "state": "orig"}
    return None


def metalgate_site(path):
    return _mg_find(open(path, "rb").read())


def metalgate_state(path):
    s = metalgate_site(path)
    return (s["state"] if s else "unknown"), s


def _apply_metalgate(data, site, to_patched):
    """就地改写 bytearray，返回提示字符串"""
    o4, o5 = site["branch4"], site["branch5"]
    # 原始两处 rel（由两个偏移唯一确定，可无损还原）
    rel4 = o5 - o4                     # je  → 失败块
    rel5 = o4 - o5                     # jne → 继续
    if to_patched:
        data[o4:o4 + 6] = MG_NOP6
        data[o5:o5 + 6] = b"\xe9" + struct.pack("<i", rel5 + 1) + b"\x90"
        return f"metalgate {o4:#x}/0x{o5:x} je/jne -> continue"
    data[o4:o4 + 6] = b"\x0f\x84" + struct.pack("<i", rel4)
    data[o5:o5 + 6] = b"\x0f\x85" + struct.pack("<i", rel5)
    return f"metalgate {o4:#x}/0x{o5:x} -> orig"



# ------------------------- 状态 / 转换 -------------------------
def check(path):
    data = open(path, "rb").read()
    je, _ = locate_video(path, data)
    if je is None:
        v = "unknown"
    else:
        v = {0xEB: "patched", 0x74: "orig"}.get(data[je], "unknown")

    sites = audio_candidates(data)
    if not sites:
        a = "unknown"
    else:
        states = {s[2] for s in sites}
        a = states.pop() if len(states) == 1 else "unknown"

    e, _ = encoder_state(path)
    m, _ = metalgate_state(path)
    ll, _ = lowlat_state(path)
    return v, a, e, m, ll


def convert(src, dst, to_patched):
    data = bytearray(open(src, "rb").read())
    msgs = []

    # 1) 视频
    je, delta = locate_video(src, bytes(data))
    if je is None:
        print("ERROR: 无法定位视频补丁点（UU 版本可能大改，需重新分析）", file=sys.stderr)
        return 1
    cur = data[je]
    want = 0xEB if to_patched else 0x74
    if cur not in (0x74, 0xEB):
        print(f"ERROR: 视频补丁点字节为 0x{cur:02x}（既非 0x74 也非 0xeb）", file=sys.stderr)
        return 1
    data[je] = want
    msgs.append(f"video {je:#x} {cur:#02x}->{want:#02x}")

    # 2) 音频
    sites = audio_candidates(bytes(data))
    if not sites:
        print("ERROR: 无法定位音频补丁点（UU 版本可能大改，需重新分析）", file=sys.stderr)
        return 1
    for j, kind, state, _tgt in sites:
        want_state = "patched" if to_patched else "orig"
        if state == want_state:
            continue
        if kind == "short":
            data[j] = 0xEB if to_patched else 0x74
            msgs.append(f"audio-short {j:#x} {state}->{want_state}")
        else:
            if to_patched:   # 0f84(6B) -> e9(5B)+nop，目标 +1 补偿
                rel = int.from_bytes(data[j + 2:j + 6], "little", signed=True)
                data[j:j + 6] = b"\xe9" + struct.pack("<i", rel + 1) + b"\x90"
                msgs.append(f"audio-near {j:#x} 0f84->e9")
            else:            # e9(5B)+nop -> 0f84(6B)，目标 -1 补偿
                rel = int.from_bytes(data[j + 1:j + 5], "little", signed=True) - 1
                data[j:j + 6] = b"\x0f\x84" + struct.pack("<i", rel)
                msgs.append(f"audio-near {j:#x} e9->0f84")

    # 3) 编码器
    site = encoder_site(src)
    if not site:
        print("ERROR: 无法定位编码器补丁点（UU 版本可能大改，需重新分析）", file=sys.stderr)
        return 1
    off = site["file_off"]
    cur = int.from_bytes(data[off:off + 4], "little")
    want_disp = site["new_disp"] if to_patched else site["old_disp"]
    if cur == want_disp:
        msgs.append("encoder 已就位")
    elif cur in (site["old_disp"], site["new_disp"]):
        data[off:off + 4] = struct.pack("<I", want_disp)
        msgs.append(f"encoder {off:#x} {cur:#x}->{want_disp:#x}")
    else:
        print(f"ERROR: 编码器补丁点位移为 {cur:#x}，与预期不符", file=sys.stderr)
        return 1

    # 4) Metal 门禁
    site = metalgate_site(src)
    if not site:
        print("ERROR: 无法定位 Metal 门禁补丁点（UU 版本可能大改，需重新分析）", file=sys.stderr)
        return 1
    want_state = "patched" if to_patched else "orig"
    if site["state"] == want_state:
        msgs.append("metalgate 已就位")
    else:
        msgs.append(_apply_metalgate(data, site, to_patched))
        # 自校验：改完立刻回读
        chk = _mg_find(bytes(data))
        if not chk or chk["state"] != want_state:
            print("ERROR: Metal 门禁改写后回读异常（应为 %s）" % want_state, file=sys.stderr)
            return 1

    # 5) 低延迟 RC（强制要求硬件编码器；本机无硬编 → 必须关掉，否则建会话返回 -12902）
    site = lowlat_site(src)
    if not site:
        print("ERROR: 无法定位低延迟补丁点（UU 版本可能大改，需重新分析）", file=sys.stderr)
        return 1
    off = site["file_off"]
    cur = int.from_bytes(data[off:off + 4], "little")
    want_disp = site["new_disp"] if to_patched else site["old_disp"]
    if cur == want_disp:
        msgs.append("lowlat 已就位")
    elif cur in (site["old_disp"], site["new_disp"]):
        _apply_lowlat(data, site, to_patched)
        msgs.append(f"lowlat {off:#x} {cur:#x}->{want_disp:#x}")
    else:
        print(f"ERROR: 低延迟补丁点位移为 {cur:#x}，与预期不符", file=sys.stderr)
        return 1

    open(dst, "wb").write(bytes(data))
    print("OK " + " | ".join(msgs))
    print(f"delta {delta:#x}")
    return 0


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "check":
        v, a, e, m, ll = check(sys.argv[2])
        print(v)
        print(f"audio {a}")
        print(f"encoder {e}")
        print(f"metalgate {m}")
        print(f"lowlat {ll}")
        return 0
    if cmd == "patch":
        return convert(sys.argv[2], sys.argv[3], True)
    if cmd == "unpatch":
        return convert(sys.argv[2], sys.argv[3], False)
    if cmd == "locate":
        je, delta = locate_video(sys.argv[2])
        if je is None:
            return 1
        print(f"{je:#x} {delta:#x}")
        return 0
    if cmd == "encsite":
        s = encoder_site(sys.argv[2])
        if not s:
            print("ERROR 无法定位编码器补丁点", file=sys.stderr)
            return 1
        print(f"file {s['file_off']:#x} old_disp {s['old_disp']:#x} "
              f"new_disp {s['new_disp']:#x} shift {s['shift']:#x} "
              f"true_slot {s['slot_true']:#x} false_slot {s['slot_false']:#x}")
        return 0
    if cmd == "metalgate":
        s = metalgate_site(sys.argv[2])
        if not s:
            print("ERROR 无法定位 Metal 门禁补丁点", file=sys.stderr)
            return 1
        print(f"je {s['branch4']:#x} jne {s['branch5']:#x} state {s['state']}")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
