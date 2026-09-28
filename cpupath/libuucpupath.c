// libuucpupath — 让 UU远程 在无 Metal 的老 Mac 上走 CPU 转换路径
//
// 背景：libstreamer.dylib 的被控端编码链最后一步 —— 把采集帧转成编码器输入帧 —— 用 Metal
//       渲染管线实现（IOSurfaceFrame::CopyTo(VideoFrame&) → Texture() →
//       CVMetalTextureCacheCreateTextureFromImage → Metal command buffer）。
//       无 Metal 的机器（AMD TeraScale 2 / pre-GCN，如 2011 Mac mini）上此步必然失败，
//       编码器收不到任何帧 → 零码流 → 对端黑屏。
//
// 本库：运行时把该函数在 vtable 里的指针换成 CPU 实现（两平面 memcpy）。
//       源与目标都是 420v(NV12) 同尺寸 buffer ⇒ 无需缩放/格式转换，纯拷贝即可
//       （实测 1920x1080 约 1ms/帧，占编码耗时 2% 以内；软编吞吐 18fps，UU 只需 8fps）。
//
// 设计要点（都对厂商版本更新免疫）：
//   * 函数用 dlsym 按导出符号定位 —— 不硬编码代码地址
//   * 成员用库自带访问器（IOSurface() / CVPixelBuffer()）读取 —— 不硬编码成员偏移
//   * 任何前提不满足（buffer 不可得 / 尺寸或格式不符 / 锁失败）→ 回退原实现，语义不变
//   * 不改磁盘文件、不改 __TEXT；只改运行时 __DATA_CONST 里的 vtable 指针（COW 可写）
//
// 编译：clang -dynamiclib -O2 -o libuucpupath.dylib libuucpupath.c \
//         -framework CoreVideo -framework CoreFoundation -framework IOSurface
// 注入：把 DYLD_INSERT_LIBRARIES 写进 UU 自己的 LaunchAgent plist 的
//       EnvironmentVariables（见同目录 install.sh / uninstall.sh）。
//       ★ 绝不用 `launchctl setenv` —— 那是 launchd 用户域全局变量，
//         会让系统守护进程与 pgrep/screencapture 也加载本未签名库，
//         被 macOS 的 CODESIGNING 保护直接 SIGKILL（实测一天 141 份崩溃报告）。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurface.h>

#define LOGPATH "/tmp/uucpu.log"

/* libstreamer 导出符号（nm -gU 确认均为全局 T） */
#define SYM_COPYTO      "_ZN8streamer14IOSurfaceFrame6CopyToERNS_10VideoFrameE"
#define SYM_IOSURFACE   "_ZN8streamer14IOSurfaceFrame9IOSurfaceEv"
#define SYM_CVPIXBUF    "_ZN8streamer14IOSurfaceFrame13CVPixelBufferEv"

/* ---------- 日志（静默运行：只打点，不逐帧刷）---------- */
static int g_fd = -1;
static void L(const char *fmt, ...) {
    char buf[1024];
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm; localtime_r(&ts.tv_sec, &tm);
    int n = snprintf(buf, sizeof buf, "%04d-%02d-%02d %02d:%02d:%02d.%03ld [%d] ",
                     tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                     tm.tm_hour, tm.tm_min, tm.tm_sec, ts.tv_nsec/1000000, getpid());
    va_list ap; va_start(ap, fmt);
    n += vsnprintf(buf+n, sizeof buf - n - 2, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof buf - 2) n = sizeof buf - 2;
    buf[n++] = '\n';
    if (g_fd < 0) g_fd = open(LOGPATH, O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (g_fd >= 0) { ssize_t w = write(g_fd, buf, n); (void)w; }
}

/* ---------- 定位 libstreamer 镜像 ---------- */
static uintptr_t g_base = 0;

static int find_libstreamer(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "libstreamer")) {
            g_base = (uintptr_t)_dyld_get_image_header(i);
            return 1;
        }
    }
    return 0;
}

/* ---------- 访问器 ABI ----------
   C++ 按值返回非平凡对象时走隐藏首参（sret）：
       fn(&retbuf, self)
   retbuf 收到一个**已 retain** 的引用，调用方负责 Release。 */
typedef CFTypeRef (*refget_fn)(CFTypeRef *ret, const void *self);
static refget_fn g_getIOSurface = NULL;
static refget_fn g_getCVPixelBuffer = NULL;

static CFTypeRef get_pixelbuffer(const void *self) {
    if (!g_getCVPixelBuffer || !self) return NULL;
    CFTypeRef r = NULL; g_getCVPixelBuffer(&r, self); return r;   /* 已 retain */
}
static CFTypeRef get_iosurface(const void *self) {
    if (!g_getIOSurface || !self) return NULL;
    CFTypeRef r = NULL; g_getIOSurface(&r, self); return r;       /* 已 retain */
}

/* ---------- CPU 实现 ---------- */
struct ec { int v; const void *cat; };          // error_code {value, category*}
typedef struct ec (*copyto_fn)(void *, void *);
static copyto_fn g_orig_CopyTo = NULL;

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static struct ec my_CopyTo(void *self, void *dst) {
    static volatile unsigned long ncall = 0, nok = 0, nfb = 0;
    unsigned long c = __sync_add_and_fetch(&ncall, 1);
    int verbose = (c <= 5) || (c % 240) == 0;   /* 头几帧 + 每 240 帧（约 30 秒 @8FPS）打一次统计 */

    if (!self || !dst) return g_orig_CopyTo(self, dst);

    /* ★★★ 内存泄漏修复（实测每帧 +5~9MB，是「连上黑屏」的真根因）：
       IOSurfaceFrame::CVPixelBuffer() / IOSurface() 返回的都是 **+1 引用**
       —— 反汇编确认（0x235ee0 处 `callq _CFRetain`，sret 返回已 retain 的对象），
       因此**调用方必须 CFRelease**。早期版本只对 IOSurface() 释放了（第 123 行），
       却把两个 CVPixelBuffer() 的返回值一直挂着 —— 其中 dst 是**每帧新建的编码器输入帧**，
       于是每帧泄漏一个 IOSurface（其引用计数永不归零 → 内核不回收该 surface 内存）。
       实测后果：25 秒会话把本进程 RSS 从 55MB 推到 1539MB，断开也不回落（停在 2.7GB），
       IOSurface 分区涨到 3.0GB / 1099 个；**下一个连接随即 IOSurfaceCreate 失败 → 黑屏**
       （日志：`分配缓冲重试 8 次仍失败 → 本次会话无帧`），并把 swap 顶到十几 GB。
       ⇒ 本函数所有出口统一走 out: 释放 srcRef/dstRef/wrapped。新增出口务必复用 out:。 */
    CVPixelBufferRef srcRef = (CVPixelBufferRef)get_pixelbuffer(self);   /* +1，本函数负责还 */
    CVPixelBufferRef dstRef = (CVPixelBufferRef)get_pixelbuffer(dst);    /* +1，本函数负责还 */
    CVPixelBufferRef wrapped = NULL;
    CVPixelBufferRef src = srcRef;
    struct ec ret;

    /* 源 buffer 缺失时用 IOSurface 现场包一个（仍然不依赖成员偏移） */
    if (!src) {
        IOSurfaceRef s = (IOSurfaceRef)get_iosurface(self);
        if (s) {
            if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, s, NULL, &wrapped) == kCVReturnSuccess)
                src = wrapped;
            CFRelease(s);
        }
    }

    if (!src || !dstRef) {
        unsigned long fb = __sync_add_and_fetch(&nfb, 1);
        L("!! CopyTo #%lu 源/目标 buffer 不可得（src=%p dst=%p）→ 回退原实现（第 %lu 次）",
          c, (void*)src, (void*)dstRef, fb);     /* 回退必须无条件记录：否则会被限频掩盖 */
        ret = g_orig_CopyTo(self, dst);
        goto out;
    }

    size_t sw = CVPixelBufferGetWidth(src),  sh = CVPixelBufferGetHeight(src);
    size_t dw = CVPixelBufferGetWidth(dstRef), dh = CVPixelBufferGetHeight(dstRef);
    OSType sf = CVPixelBufferGetPixelFormatType(src), df = CVPixelBufferGetPixelFormatType(dstRef);
    size_t spn = CVPixelBufferGetPlaneCount(src), dpn = CVPixelBufferGetPlaneCount(dstRef);

    if (sw != dw || sh != dh || sf != df || spn != dpn || dpn == 0) {
        unsigned long fb = __sync_add_and_fetch(&nfb, 1);
        L("!! CopyTo #%lu 尺寸/格式不符（源 %zux%zu 0x%08x/%zu 目标 %zux%zu 0x%08x/%zu）→ 回退（第 %lu 次）",
          c, sw,sh,(unsigned)sf,spn, dw,dh,(unsigned)df,dpn, fb);   /* 无条件记录 */
        ret = g_orig_CopyTo(self, dst);
        goto out;
    }

    CVReturn l1 = CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVReturn l2 = (l1 == kCVReturnSuccess) ? CVPixelBufferLockBaseAddress(dstRef, 0) : (CVReturn)-1;

    if (l1 == kCVReturnSuccess && l2 == kCVReturnSuccess) {
        size_t total = 0;
        double t0 = now_ms();
        for (size_t p = 0; p < dpn; p++) {
            void *d = dpn==1 ? CVPixelBufferGetBaseAddress(dstRef) : CVPixelBufferGetBaseAddressOfPlane(dstRef, p);
            void *s = spn==1 ? CVPixelBufferGetBaseAddress(src)   : CVPixelBufferGetBaseAddressOfPlane(src, p);
            if (!d || !s) continue;
            size_t dbpr = dpn==1 ? CVPixelBufferGetBytesPerRow(dstRef) : CVPixelBufferGetBytesPerRowOfPlane(dstRef, p);
            size_t sbpr = spn==1 ? CVPixelBufferGetBytesPerRow(src)   : CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t hh   = dpn==1 ? CVPixelBufferGetHeight(dstRef)      : CVPixelBufferGetHeightOfPlane(dstRef, p);
            size_t row  = sbpr < dbpr ? sbpr : dbpr;
            for (size_t y = 0; y < hh; y++) memcpy((char*)d + y*dbpr, (char*)s + y*sbpr, row);
            total += row * hh;
        }
        CVPixelBufferUnlockBaseAddress(dstRef, 0);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        unsigned long ok = __sync_add_and_fetch(&nok, 1);
        if (verbose) {
            /* 帧率与耗时统计：诊断"延迟高"是采集慢还是拷贝慢 */
            static double prev = 0, sum_copy = 0, sum_gap = 0;
            static int n = 0;
            double t1 = now_ms();
            if (prev > 0) { sum_gap += (t1 - prev); }
            prev = t1; sum_copy += (t1 - t0); n++;
            double avg_gap = (n > 1) ? sum_gap / (n - 1) : 0;
            L("CopyTo #%lu ★ 成功 %zu 字节（成功=%lu 回退=%lu）| 近 %d 帧：间隔 %.1f ms（≈%.1f FPS）拷贝 %.2f ms/帧",
              c, total, ok, (unsigned long)nfb, n, avg_gap,
              avg_gap > 0 ? 1000.0 / avg_gap : 0, sum_copy / n);
            n = 0; sum_copy = 0; sum_gap = 0;
        }
        ret = (struct ec){0, NULL};
        goto out;
    }

    {
        unsigned long fb2 = __sync_add_and_fetch(&nfb, 1);
        L("!! CopyTo #%lu 锁失败（l1=%d l2=%d）→ 回退（第 %lu 次）", c, (int)l1, (int)l2, fb2);
    }
    ret = g_orig_CopyTo(self, dst);

out:
    /* ★ 统一出口：访问器给的 **+1 引用**必须还回去，否则每帧泄漏（见函数开头注释）。
       wrapped 是我们自己 Create 的，同样在这里还。**新增任何出口都必须 goto out**。 */
    if (wrapped) CFRelease(wrapped);
    if (srcRef)  CFRelease(srcRef);
    if (dstRef)  CFRelease(dstRef);
    return ret;
}

/* ---------- vtable 槽替换 ---------- */
static int make_writable(void *addr, size_t len) {
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(PAGE_SIZE-1);
    size_t span = ((vm_address_t)addr + len) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, span, FALSE,
                                  VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
    if (kr != KERN_SUCCESS)
        kr = vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ|VM_PROT_WRITE);
    return kr == KERN_SUCCESS;
}

static int patch_vtable(void) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)g_base;
    const struct load_command *lc = (const void *)(h + 1);
    uint64_t target = (uint64_t)(uintptr_t)g_orig_CopyTo;
    int hits = 0;

    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const void *)lc;
            if (strcmp(sg->segname, "__DATA_CONST")==0 || strcmp(sg->segname, "__DATA")==0) {
                uint64_t *p   = (uint64_t *)(g_base + sg->vmaddr);
                uint64_t *end = (uint64_t *)((char*)p + sg->vmsize);
                for (; p < end; p++) {
                    if (*p == target) {
                        if (make_writable(p, sizeof *p)) {
                            *p = (uint64_t)(uintptr_t)&my_CopyTo;
                            hits++;
                        } else L("!! 槽 %p 改可写失败", (void*)p);
                    }
                }
            }
        }
        lc = (const struct load_command *)((char*)lc + lc->cmdsize);
    }
    return hits;
}

__attribute__((constructor))
static void uucpupath_init(void) {
    if (!find_libstreamer()) { L("!! 未加载 libstreamer，放弃"); return; }

    /* 1) dlsym 定位（版本无关）；取不到才放弃（不做硬编码回退：宁可不动，不要打错地方） */
    void *fn = dlsym(RTLD_DEFAULT, SYM_COPYTO);
    if (!fn) { L("!! dlsym 取不到 %s —— 厂商版本结构已变，未安装", SYM_COPYTO); return; }
    g_orig_CopyTo = (copyto_fn)fn;

    g_getIOSurface     = (refget_fn)dlsym(RTLD_DEFAULT, SYM_IOSURFACE);
    g_getCVPixelBuffer = (refget_fn)dlsym(RTLD_DEFAULT, SYM_CVPIXBUF);
    if (!g_getCVPixelBuffer) {
        L("!! 取不到 IOSurfaceFrame::CVPixelBuffer()，未安装（避免误拷）"); return;
    }

    /* 2) 替换 vtable 槽 */
    int hits = patch_vtable();
    if (hits > 0) {
        L("=== libuucpupath 已加载 pid=%d ===", getpid());
        L("    libstreamer base=%p  CopyTo=%p（dlsym 定位）", (void*)g_base, (void*)g_orig_CopyTo);
        L("    访问器 IOSurface=%p CVPixelBuffer=%p", (void*)g_getIOSurface, (void*)g_getCVPixelBuffer);
        L("    ★ vtable 槽替换 %d 处 → CPU 转换路径启用", hits);
    } else {
        L("!! 未找到指向 CopyTo 的 vtable 槽 pid=%d base=%p CopyTo=%p",
          getpid(), (void*)g_base, (void*)g_orig_CopyTo);
    }
}
