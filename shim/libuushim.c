// libuushim.c —— A 方案 v2：把 UU 失效的 CGDisplayStream 帧源换成「截图轮询」
//
// 用法：本库作为 LC_LOAD_DYLIB 加进 UURemoteServer（或 DYLD_INSERT_LIBRARIES 注入）。
// 通过 __DATA,__interpose 拦截 CGDisplayStream*，内部改用 CGDisplayCreateImage 出帧。
// 不改 UU 任何一个字节，也不需要 UU 改协议/网络。
//
// 为什么需要这个：本机（2011 Mac mini，无 IOGPU、无 Metal）
//   · ScreenCaptureKit  → 0 个 IOGPU 设备 → 必失败
//   · CGDisplayStream   → Create/Start 都成功，但永远只回调 Idle(0)，不出完整帧
//   · CGDisplayCreateImage（截图轮询）→ 正常出图（ToDesk 走的就是这条）
//
// v2 相对 v1 修的三个「有帧但无画面」根因：
//   1. 脏矩形返回 0x0 → UU 认为「画面没变化」→ 不推流。现返回整屏矩形。
//      ★ v15 起改成「如实报告」：真的没变才报 0 个矩形（详见 g_changed 处注释）。
//        当时一律返回 0x0 是因为**没有**变化检测能力，只能恒报「没变」→ 恒不推流。
//   2. 无条件写 BGRA，但 UU 请求的可能是 '420v'/'420f'（NV12，喂编码器的标准格式）
//      → 编码器拿到错格式 → 黑帧。现按请求格式做 BGRA→NV12 转换。
//   3. 回调在自己的线程，而真实 API 在调用者指定的 dispatch queue 上回调
//      → UU 状态机竞态。现统一 dispatch_async 到调用者的 queue。
//
// 日志：/tmp/uushim.log（同时进 os_log，便于 log show 检索）
// 详见同目录 README.md 的实测数据。
#define CGDISPLAYSTREAM_H_
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdarg.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <sys/time.h>
#include <stdint.h>

typedef struct CF_BRIDGED_TYPE(id) CGDisplayStream *CGDisplayStreamRef;
typedef int32_t CGDisplayStreamFrameStatus;
typedef void (^CGDisplayStreamFrameAvailableHandler)(CGDisplayStreamFrameStatus status, uint64_t time,
                                                     IOSurfaceRef surface, void *update);

// 真实符号（interpose 需要引用它们）
extern CGDisplayStreamRef CGDisplayStreamCreate(CGDirectDisplayID, size_t, size_t, OSType,
                                                CFDictionaryRef, CGDisplayStreamFrameAvailableHandler);
extern CGDisplayStreamRef CGDisplayStreamCreateWithDispatchQueue(CGDirectDisplayID, size_t, size_t,
                                                OSType, CFDictionaryRef, dispatch_queue_t,
                                                CGDisplayStreamFrameAvailableHandler);
extern int32_t CGDisplayStreamStart(CGDisplayStreamRef);
extern int32_t CGDisplayStreamStop(CGDisplayStreamRef);
extern CFRunLoopSourceRef CGDisplayStreamGetRunLoopSource(CGDisplayStreamRef);
// ★★ 真实签名（必须与系统一致）：只有 3 个参数，且**返回** const CGRect*。
//   v1~v4 写成「4 参数 + 把矩形写进调用者缓冲区」是致命错误：
//   UU 传的第 3 个参数是 size_t*（8 字节计数槽），我们往里写 16 字节 CGRect
//   → 越界破坏 UU 的栈帧 → 它持有的 CF 对象被踩坏 → 卡死在 CFRelease（cold path）。
extern const CGRect *CGDisplayStreamUpdateGetRects(void *update, int rectType, size_t *rectCount);

// 目标帧率。截图单帧约 67ms（本机硬成本）→ 上限 13~15 FPS；
// 实测 10 FPS 目标时 CPU 约 0.36 核，而 UU 零帧空转本身就要 1.15 核。
// 目标帧率：默认 8。可用环境变量 UUSHIM_FPS 覆盖（1~15；上限受"截图单帧约 67ms"的本机硬成本限制）。
// ★ 帧率越高 → 采集侧等待越短 → 端到端延迟越低，但 CPU 占用越高（截图是纯 CPU 的）。
static int uushim_fps(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("UUSHIM_FPS");
        int v = e ? atoi(e) : 0;
        if (v < 1)  v = 8;
        if (v > 15) v = 15;
        cached = v;
    }
    return cached;
}
#define UUSHIM_TARGET_FPS uushim_fps()
// ★ 首帧延迟：真实 CGDisplayStream 在 Start 之后要过几十~几百毫秒才出第一帧。
//   v3 一 Start 就立刻推帧，实测会让 UU 的采集队列卡死（回调处理里自旋在 objc_retain，
//   之后所有帧永远排队）—— 疑似 UU 尚未完成注册就被塞帧导致的竞态。
#define UUSHIM_FIRST_FRAME_DELAY_MS 400

// ★ 真实枚举（CGDisplayStream.h 的 CF_ENUM 从 0 起，无显式赋值）：
//   FrameComplete = 0, FrameIdle = 1, FrameBlank = 2, Stopped = 3
// 这里一旦写错（例如把 Complete 当 3），UU 会以为流已 Stopped 而丢弃所有帧 ——
// 症状正是「连上了、CPU 在转、但永远停在正在传输画面」。
enum { ST_FRAME_COMPLETE = 0, ST_FRAME_IDLE = 1, ST_FRAME_BLANK = 2, ST_FRAME_STOPPED = 3 };
enum { FK_BGRA = 1, FK_NV12 = 2, FK_OTHER = 0 };

// ---------------------------------------------------------------------------
// 日志：文件 + os_log（launchd 启动时 stderr 会被吞掉，所以必须落文件）
// ---------------------------------------------------------------------------
static FILE *g_log;
static pthread_mutex_t g_loglock = PTHREAD_MUTEX_INITIALIZER;

// ★ v17：画面导出（仅调试用）。设 UUSHIM_DUMP=/tmp/uu-frame 后，把渲染出的 BGRA 画面
//   写成 BMP（限 3 张），用来人工核对「shim 抓到的到底是不是真实桌面」。
//   为什么关键：『连上没画面』可能是①采集侧抓到黑帧/花屏，②传输侧没送出去，③客户端渲染
//   问题。看一张导出的图就能排除①，剩下范围立刻缩小 —— 这正是这次排查缺的证据。
//   声明放这里是为了构造函数也能读到它（C 里先声明后使用）。
static const char *g_dump_path;
static volatile int g_dump_n;

static void ulog(const char *fmt, ...) {
    char buf[640];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tmv; time_t sec = tv.tv_sec; localtime_r(&sec, &tmv);
    pthread_mutex_lock(&g_loglock);
    // ★ 日志路径可用环境变量 UUSHIM_LOG 覆盖：这样「测试用 DYLD_INSERT_LIBRARIES 跑 harness」
    //   不会污染生产日志（曾因直接删 /tmp/uushim.log 让在跑进程写向已删除 inode，遥测全瞎）
    const char *lp = getenv("UUSHIM_LOG");
    if (!lp || !*lp) lp = "/tmp/uushim.log";
    if (!g_log) g_log = fopen(lp, "a");
    if (g_log) {
        fprintf(g_log, "%04d-%02d-%02d %02d:%02d:%02d.%03d  %s\n",
                tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000), buf);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_loglock);
    os_log(OS_LOG_DEFAULT, "[uushim] %{public}s", buf);
}

__attribute__((constructor)) static void uushim_init(void) {
    g_dump_path = getenv("UUSHIM_DUMP");   // ★ v17 调试：非空则把抓到的画面导出 BMP
    ulog("=== libuushim v18 已加载 pid=%d（v9 排空 + v10 Stopped 回调 + v11 关 VT 拦截 + v12 槽位/内存回收【修反复切换连不上】+ v13 空转/无缓冲守卫与分配重试【修内存紧张时黑屏+空载烧CPU】+ v14 失败会话即时让出槽位【修槽位累积泄漏致黑屏】+ v15 如实报告画面变化【静止帧不编码，省 CPU；UUSHIM_DIRTY=0 可退回恒整屏】+ v16 修两处真泄漏（让出槽位/超时回收只摘映射不释放缓冲，每处 ~28MB 显存）并加缓冲记账 + v17 加 UUSHIM_DUMP 画面导出（人工核对「抓到的画面对不对」——这是判断「连上没画面」是采集侧还是传输侧的关键证据）+ **v18 日志时间戳加日期（原先只有 HH:MM:SS、跨天累积 → 会把前一天的行误当今天，实测踩过）**；帧率可 UUSHIM_FPS 覆盖，当前 %d）===", (int)getpid(), UUSHIM_TARGET_FPS);
}

// ---------------------------------------------------------------------------
typedef struct {
    uint32_t display;
    size_t w, h;
    uint32_t fmt;
    int kind;
    CGDisplayStreamFrameAvailableHandler handler;
    dispatch_queue_t queue;
#define NBUF 3
    // ★ 环形缓冲：真实 CGDisplayStream 每帧交出「不同」的 surface（三缓冲）。
    //   UU 导入 IOSurfaceIncrementUseCount/DecrementUseCount 且有
    //   IOSurfaceFrame::CheckIfFrameChange —— 说明它按 surface 身份判「帧有无变化」。
    //   复用同一个 surface ⇒ 被判定为「没变」⇒ 帧不进编码器（实测：有帧但无上行流量）。
    IOSurfaceRef surf[NBUF];
    CVPixelBufferRef pb[NBUF];  // 仅 NV12 用（IOSurfaceCreate 不会给双平面格式建 plane1）
    int nbuf, cur;
    CFTypeRef upd;              // 伪造的 update 对象（携带 w/h 供 GetRects 用）
    uint8_t *buf;               // BGRA 渲染缓冲
    CGContextRef ctx;
    CFRunLoopSourceRef rls;
    volatile int running;
    volatile int started;
    pthread_t thr;
    int idx;
    int logged;
    dispatch_group_t grp;       // ★ 跟踪已派发但未执行完的回调块（stop 时等它归零）
    volatile int inflight;
    // ★ v12：会话结束后释放缓冲、交还槽位。不释放会导致【槽位泄漏】：
    //   每次连接占 1 个槽位，8 次之后 create 只能返回「无采集线程的假句柄」→ 永远黑屏。
    //   实测症状：日志反复刷「流数超上限 8」，且「反复切换设备接管」必现（每切换一次泄漏一个）。
    volatile int released;      // 1 = 缓冲已释放（start 时按需重建）
    double stopped_ms;          // 最近一次停止时刻（回收槽位时优先挑最老的）
    // ★ v14：死会话标记。start 因「无可用缓冲」失败时 UU 往往不再调 stop，
    //   该槽位就会永久占着（started=0 且 released=0 ⇒ 连回收条件都不满足）。
    //   实测：61 次 create 只配到 46 次 stop ⇒ 15 个槽位永久泄漏，累积到全部占满后
    //   create 只能返回「无采集线程的假句柄」→ 黑屏/连不上，且进程 RSS 涨到 1.7GB。
    volatile int dead;          // 1 = 该会话已废（失败），槽位应立刻让出
    double created_ms;          // 创建时刻（判定陈旧死槽位用）
    // ★★★ v15：上一帧的 BGRA 快照。用途见 g_changed 处的长注释：
    //   与当前帧 memcmp 就能如实回答「这一帧到底变没变」，从而让 UU 在画面静止时
    //   不编码、不推流（macOS 自带屏幕共享省 CPU 的核心机制就是这个）。
    uint8_t *prev;
    // ★ v16：缓冲记账标志。alloc_buffers/release_frames 各自只加减一次，
    //   用来让「泄漏有没有真的消失」可被机器核对（看日志里活跃缓冲数是否随连接次数增长）。
    volatile int had_bufs;
} Shim;

#define MAXS 32

// ★ v16：缓冲记账。为什么需要：这次「连上没画面」的两条真根因（slot_detach 与
//   超时回收只摘映射不释放缓冲）**都是人眼看不出来的**——日志正常出帧、设备在线、
//   权限齐全，只有显存悄悄被吃掉。所以修完必须留下**能被机器核对**的数：
//   静止/正常使用时活跃缓冲会话数应长期 ≤ 2，**不随连接次数单调增长**。
static volatile long g_live_buf_sessions = 0;
static volatile long g_live_buf_bytes = 0;

// 估算某会话持有多少缓冲（MB）。BGRA 三缓冲 + 渲染缓冲 + 上一帧快照为上界估值；
// NV12 实际更小，所以这个数只会偏大，用于「有没有泄漏」的判据足够。
static double shim_mb(const Shim *s) {
    if (!s || !s->w || !s->h) return 0;
    double per = (double)s->w * (double)s->h * 4.0;
    return per * (NBUF + 2) / (1024.0 * 1024.0);
}
static void bufs_account(const char *why) {
    ulog("缓冲记账[%s]：活跃 %ld 会话 / 约 %.1f MB（不随连接次数增长才正常）",
         why, g_live_buf_sessions, (double)g_live_buf_bytes / (1024.0 * 1024.0));
}

// ---------------------------------------------------------------------------
// ★ v17：调试用画面导出。把当前渲染出的 BGRA 缓冲写成 BMP（24 位、自底向上）。
//   故意不引任何第三方库、不依赖 CGImage 导出（那需要额外 API 且易失败），
//   直接把内存按 BMP 规范落盘 —— 这样即使上层画面链路有问题，这份图也一定拿得到。
//   用途：一眼判定「连上没画面」到底是①采集侧抓到黑帧/花屏，还是②传输/客户端问题。
//   安全性：只在采集线程里、只写前 3 张、路径来自环境变量（本地调试用）。
static void dump_frame_bmp(const Shim *s, const char *path) {
    if (!s || !s->buf || !s->w || !s->h) return;
    FILE *f = fopen(path, "wb");
    if (!f) return;
    uint32_t w = (uint32_t)s->w, h = (uint32_t)s->h;
    uint32_t rowsz = w * 3;
    uint32_t pad = (4 - (rowsz % 4)) % 4;
    uint32_t imgsz = (rowsz + pad) * h;
    uint32_t fsz = 54 + imgsz, off = 54, ihsz = 40;
    uint16_t planes = 1, bpp = 24;
    uint8_t hdr[54];
    memset(hdr, 0, sizeof hdr);
    hdr[0] = 'B'; hdr[1] = 'M';
    memcpy(hdr + 2, &fsz, 4);   memcpy(hdr + 10, &off, 4);
    memcpy(hdr + 14, &ihsz, 4); memcpy(hdr + 18, &w, 4);
    memcpy(hdr + 22, &h, 4);    memcpy(hdr + 26, &planes, 2);
    memcpy(hdr + 28, &bpp, 2);  memcpy(hdr + 34, &imgsz, 4);
    fwrite(hdr, 1, sizeof hdr, f);
    size_t stride = rowsz + pad;
    uint8_t *row = calloc(1, stride);
    if (!row) { fclose(f); return; }
    for (int y = (int)h - 1; y >= 0; y--) {          // BMP 自底向上
        const uint8_t *src = s->buf + (size_t)y * w * 4;
        for (uint32_t x = 0; x < w; x++) {           // BGRA → BGR
            row[x * 3 + 0] = src[x * 4 + 0];
            row[x * 3 + 1] = src[x * 4 + 1];
            row[x * 3 + 2] = src[x * 4 + 2];
        }
        fwrite(row, 1, stride, f);
    }
    free(row);
    fclose(f);
}
static Shim *g_shim[MAXS];
static CFTypeRef g_handle[MAXS];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_frames;
static volatile int g_rects;   // UU 查询脏矩形的次数：证明它真的在消费我们的帧
// ★★★ v15：如实报告「画面有没有变化」（对标 VNC：静止就不推流，这是省 CPU 的正路）
//
// 背景（为什么原先不做）：v2 为了让画面**先出来**，把两个「变没变」的信号都中立化了：
//   ① GetRects 恒返回整屏（原来的 0x0 让 UU 认为没变化 → 完全不推流 → 黑屏）
//   ② 每帧轮换 3 个 surface（UU 的 IOSurfaceFrame::CheckIfFrameChange 按 surface 身份判变化）
// 代价是 UU 认为「每帧都是新的、且整屏都变了」→ 画面**完全静止也逐帧软编**。
//
// 现在这么做：每帧与上一帧 memcmp（1600x900 约 5.7MB，内存带宽级开销，实测 ~1ms）。
//   · 有变化 → 报告整屏（与今天行为一致，零额外风险）
//   · 无变化 → 如实报告 0 个矩形，让 UU 自己跳过这一帧
// 关键差别：这不是「恒返回 0x0」（那会彻底不推流），而是**只在真的没变时才这么报**。
//
// 回退开关：环境变量 UUSHIM_DIRTY=0 → 退回旧行为（恒整屏）。
//   出问题的症状是「画面不动」或「卡住」→ 设 0 并重装 shim 即可复原。
static volatile int g_changed = 1;   // 最近一帧是否与上一帧不同（1=是，首帧也算）
static volatile int g_same;          // 累计「判定为没变化」的帧数（取证用）
static volatile int g_zero_rects;    // 累计「如实报告 0 个矩形」的次数（取证用）
static int uushim_dirty_mode(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("UUSHIM_DIRTY");
        cached = (!e || !*e) ? 1 : (atoi(e) != 0);
    }
    return cached;
}
static volatile int g_hb;      // 交给 UU 的回调块「开始执行」次数
static volatile int g_ha;      // 交给 UU 的回调块「执行完毕」次数（hb-ha 持续变大 = UU 卡在回调里）
static size_t g_last_w, g_last_h;   // 最近一条流的尺寸（供 GetRects 返回整屏矩形）
// ★ 仪表：回调延迟（从 dispatch 到回调返回的毫秒数）。UU 若在回调里卡住，这个值会暴涨。
static volatile long g_lat_last_ms, g_lat_max_ms;
static volatile int g_st[4];       // 各 status 出现次数：0=Complete 1=Idle 2=Blank 3=Stopped
static volatile int g_wl_calls;    // ★ CGWindowListCreateImage 调用计数（UU 主程序的第二条采集路径）
// ★ update 对象：真实 API 每帧给一个 CF 对象，上层可能 retain/release 它。
//   用单例常量（kCFBooleanTrue）被反复 CFRelease 会破坏 CF 全局状态（实测卡死在 CFRelease.cold.1）。
//   做法：常驻持有 1 个 CFData，每帧再 CFRetain 一次，抵消上层的 CFRelease。
static CFTypeRef g_upd;

static double now_ms(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

// 把 OSType 打成可读四字符（直接 (char*)&f 在小端下会反序，导致日志骗人）
static const char *fourcc(uint32_t f) {
    static __thread char b[5];
    b[0] = (char)(f >> 24); b[1] = (char)(f >> 16);
    b[2] = (char)(f >> 8);  b[3] = (char)f; b[4] = 0;
    for (int i = 0; i < 4; i++) if (b[i] < 32 || b[i] > 126) b[i] = '?';
    return b;
}

static int kind_of(uint32_t f) {
    if (f == 'BGRA' || f == 'RGBA' || f == 'ARGB' || f == 'BGRA') return FK_BGRA;
    if (f == '420v' || f == '420f' || f == 'f420' || f == 'v420') return FK_NV12;
    return FK_OTHER;
}

static CGImageRef (*real_mkimg(void))(CGDirectDisplayID) {
    static CGImageRef (*f)(CGDirectDisplayID);
    if (!f) {
        void *h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
        if (h) f = (CGImageRef (*)(CGDirectDisplayID))dlsym(h, "CGDisplayCreateImage");
    }
    return f;
}

static inline uint8_t clamp8(int v) { return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); }

// BGRA(内存序 B,G,R,A) → NV12 双平面（Y + 交织 CbCr）
static void bgra_to_nv12(const uint8_t *src, size_t w, size_t h,
                         uint8_t *ydst, size_t ystride,
                         uint8_t *cdst, size_t cstride, int full_range) {
    for (size_t y = 0; y < h; y++) {
        const uint8_t *srow = src + y * w * 4;
        uint8_t *yrow = ydst + y * ystride;
        for (size_t x = 0; x < w; x++) {
            int b = srow[x * 4 + 0], g = srow[x * 4 + 1], r = srow[x * 4 + 2];
            int Y;
            if (full_range) Y = (77 * r + 150 * g + 29 * b + 128) >> 8;
            else            Y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            yrow[x] = clamp8(Y);
        }
    }
    for (size_t y = 0; y + 1 < h; y += 2) {
        uint8_t *crow = cdst + (y / 2) * cstride;
        for (size_t x = 0; x + 1 < w; x += 2) {
            // 2x2 块求平均
            int r = 0, g = 0, b = 0;
            for (size_t dy = 0; dy < 2; dy++) {
                const uint8_t *p = src + (y + dy) * w * 4 + x * 4;
                for (size_t dx = 0; dx < 2; dx++) {
                    b += p[dx * 4 + 0]; g += p[dx * 4 + 1]; r += p[dx * 4 + 2];
                }
            }
            r >>= 2; g >>= 2; b >>= 2;
            int Cb, Cr;
            if (full_range) {
                Cb = ((-43 * r - 85 * g + 128 * b + 128) >> 8) + 128;
                Cr = ((128 * r - 107 * g - 21 * b + 128) >> 8) + 128;
            } else {
                Cb = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                Cr = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            }
            size_t ci = (x / 2) * 2;
            if (ci + 1 < cstride) { crow[ci] = clamp8(Cb); crow[ci + 1] = clamp8(Cr); }
        }
    }
}

static void *worker(void *arg) {
    Shim *s = (Shim *)arg;
    double interval = 1000.0 / UUSHIM_TARGET_FPS;
    int local = 0;
    double last_lum = 0;
    double start_at = now_ms() + UUSHIM_FIRST_FRAME_DELAY_MS;
    while (s->running) {
        double t0 = now_ms();
        if (t0 < start_at) { usleep(10 * 1000); continue; }   // 首帧延迟（见 UUSHIM_FIRST_FRAME_DELAY_MS）
        // ★★★ v13 守卫：缓冲未就绪（分配失败，或已被 stop 释放）时绝不进入帧处理。
        //   不守会出两个事故（都实测过）：
        //     ① 亮度自检读 s->buf（此时为 NULL）→ 空指针；
        //     ② 循环末尾 `if (wait > 0) usleep()` 在耗时超预算时不睡 → 满速空转，
        //        实测无会话时 UURemoteServer 空烧 55~62% CPU，且不出帧、不报错。
        if (!s->buf || !s->ctx || s->w == 0 || s->h == 0 ||
            (s->kind == FK_NV12 ? !s->pb[0] : !s->surf[0])) {
            usleep(50 * 1000);
            continue;
        }
        CGImageRef (*mk)(CGDirectDisplayID) = real_mkimg();
        if (mk) {
            CGImageRef img = mk(s->display);
            if (img) {
                CGContextDrawImage(s->ctx, CGRectMake(0, 0, s->w, s->h), img);
                CGImageRelease(img);
            }
        }
        // ★★★ v15：如实判定「这一帧到底变没变」（机制与回退开关见 g_changed 处注释）。
        //   位置很关键：必须在把这一帧交给 UU **之前**定好，UU 随后查脏矩形时才拿得到正确结论。
        {
            int changed = 1;
            if (uushim_dirty_mode() && s->prev && s->buf) {
                size_t nb = s->w * 4 * s->h;
                if (memcmp(s->buf, s->prev, nb) == 0) {
                    changed = 0;                      // 静止：连 memcpy 都省掉
                } else {
                    memcpy(s->prev, s->buf, nb);      // 有变化：更新基线
                }
            }
            g_changed = changed;
            if (!changed) __sync_fetch_and_add(&g_same, 1);
        }
        // 按请求格式写入「当前环形缓冲」，然后轮转到下一个（模仿真实三缓冲）
        int bi = s->cur;
        s->cur = (s->cur + 1) % (s->nbuf > 0 ? s->nbuf : 1);
        if (s->kind == FK_NV12 && s->pb[bi]) {
            CVPixelBufferLockBaseAddress(s->pb[bi], 0);
            uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(s->pb[bi], 0);
            size_t ys = CVPixelBufferGetBytesPerRowOfPlane(s->pb[bi], 0);
            uint8_t *c = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(s->pb[bi], 1);
            size_t cs = CVPixelBufferGetBytesPerRowOfPlane(s->pb[bi], 1);
            if (y && c) bgra_to_nv12(s->buf, s->w, s->h, y, ys, c, cs, (s->fmt == '420f'));
            CVPixelBufferUnlockBaseAddress(s->pb[bi], 0);
        } else if (s->surf[bi]) {
            IOSurfaceLock(s->surf[bi], 0, NULL);
            uint8_t *d = (uint8_t *)IOSurfaceGetBaseAddress(s->surf[bi]);
            size_t ds = IOSurfaceGetBytesPerRow(s->surf[bi]);
            if (d) {
                if (ds == s->w * 4) memcpy(d, s->buf, s->w * 4 * s->h);
                else for (size_t r = 0; r < s->h; r++)
                    memcpy(d + r * ds, s->buf + r * s->w * 4, s->w * 4);
            }
            IOSurfaceUnlock(s->surf[bi], 0, NULL);
        }
        // 亮度自检：证明抓到的不是黑帧（TCC 无录屏权限时会全黑，这是最难察觉的坑）
        {
            long sm = 0, n = 0;
            for (size_t p = 0; p < s->w * s->h; p += 6400) { sm += s->buf[p * 4 + 1]; n++; }
            last_lum = n ? (double)sm / n : 0;
        }
        // ★ v17：按需导出画面（人工核对采集侧是否正确）。只导出前 3 张，避免占盘。
        if (g_dump_path && *g_dump_path && g_dump_n < 3) {
            char dp[400];
            snprintf(dp, sizeof dp, "%s-%d.bmp", g_dump_path, g_dump_n++);
            dump_frame_bmp(s, dp);
            ulog("画面已导出 → %s（用来看 shim 抓到的画面是否为真实桌面）", dp);
        }
        if (s->handler) {
            uint64_t dt = mach_absolute_time();
            IOSurfaceRef surf = s->surf[bi];
            // ★ 每帧提供一个「可被安全 CFRelease 的」update 对象（真实 API 每帧都给新对象）
            if (!g_upd) g_upd = (CFTypeRef)CFDataCreate(NULL, NULL, 0);
            CFRetain(g_upd);          // 抵消上层可能做的 CFRelease（常驻对象不会被释放）
            CFTypeRef upd = g_upd;
            CGDisplayStreamFrameAvailableHandler h = s->handler;
            dispatch_queue_t q = s->queue;
            // 真实 API 在调用者的 queue 上回调 —— 必须一致，否则 UU 状态机竞态
            double t_dis = now_ms();
            if (q) {
                // ★ 用 group 跟踪已派发的块：stop 时必须等它们全部执行完再返回。
                //   否则 UU 的 UnregisterFrameHandler（先 cancel 自己的 GCD 源、再调
                //   CGDisplayStreamStop、然后等 cancel handler 完成）会卡在
                //   std::__libcpp_atomic_wait 死等 → 会话管理瘫痪 → 之后所有新连接都不再
                //   启动采集（现象：连上但黑屏，只有重启进程才恢复）。
                if (!s->grp) s->grp = dispatch_group_create();
                if (s->grp) dispatch_group_enter(s->grp);
                __sync_fetch_and_add(&s->inflight, 1);
                dispatch_async(q, ^{
                    double t0 = now_ms();
                    __sync_fetch_and_add(&g_hb, 1);
                    __sync_fetch_and_add(&g_st[0], 1);
                    h(ST_FRAME_COMPLETE, dt, surf, (void *)upd);
                    long lat = (long)(now_ms() - t_dis);
                    g_lat_last_ms = lat;
                    if (lat > g_lat_max_ms) g_lat_max_ms = lat;
                    __sync_fetch_and_add(&g_ha, 1);
                    __sync_fetch_and_sub(&s->inflight, 1);
                    if (s->grp) dispatch_group_leave(s->grp);
                    (void)t0;
                });
            }
            else {
                __sync_fetch_and_add(&g_hb, 1);
                __sync_fetch_and_add(&g_st[0], 1);
                h(ST_FRAME_COMPLETE, dt, surf, (void *)upd);
                long lat = (long)(now_ms() - t_dis);
                g_lat_last_ms = lat;
                if (lat > g_lat_max_ms) g_lat_max_ms = lat;
                __sync_fetch_and_add(&g_ha, 1);
            }
            local++;
            __sync_fetch_and_add(&g_frames, 1);
            if (!s->logged || local % 24 == 0) {
                s->logged = 1;
                int pend = g_hb - g_ha;
                ulog("出帧 #%d/%d  fmt=%.4s %zux%zu 亮度=%.1f 脏矩形=%d 同帧=%d 零矩形=%d 回调进%d/出%d 待回%d 延迟%.0fms(峰%.0f) 状态[%d,%d,%d,%d]",
                     local, g_frames, fourcc(s->fmt), s->w, s->h, last_lum, g_rects,
                     g_same, g_zero_rects,
                     g_hb, g_ha, pend, (double)g_lat_last_ms, (double)g_lat_max_ms,
                     g_st[0], g_st[1], g_st[2], g_st[3]);
            }
        }
        double spent = now_ms() - t0;
        double wait = interval - spent;
        // ★ v13：至少睡 5ms。原实现只在 wait>0 时睡，一旦单帧耗时超过预算（重负载/内存紧张
        //   时常见）就变成满速空转 —— 实测无会话时 server 空烧 55~62% CPU。
        if (wait < 5) wait = 5;
        usleep((useconds_t)(wait * 1000));
    }
    return NULL;
}

static Shim *lookup(CGDisplayStreamRef ref) {
    pthread_mutex_lock(&g_lock);
    Shim *r = NULL;
    for (int i = 0; i < MAXS; i++) if (g_handle[i] == (CFTypeRef)ref) { r = g_shim[i]; break; }
    pthread_mutex_unlock(&g_lock);
    return r;
}

// ★ v12 前向声明（alloc/release 定义在 shim_create 之后）
static void release_frames(Shim *s);
static int alloc_buffers(Shim *s);

static CGDisplayStreamRef shim_create(CGDirectDisplayID d, size_t w, size_t h, OSType fmt,
                                      CFDictionaryRef props, dispatch_queue_t q,
                                      CGDisplayStreamFrameAvailableHandler handler) {
    (void)props;
    if (!w || !h) { w = (size_t)CGDisplayPixelsWide(d); h = (size_t)CGDisplayPixelsHigh(d); }
    Shim *s = calloc(1, sizeof(Shim));
    if (!s) return NULL;
    int kind = kind_of(fmt);
    if (!fmt) kind = FK_BGRA;
    // 420 要求偶数边长；奇数就回退 BGRA，否则编码器会拿到错位数据
    if (kind == FK_NV12 && ((w & 1) || (h & 1))) {
        ulog("请求 420 但尺寸为奇数 %zux%zu → 回退 BGRA", w, h);
        kind = FK_BGRA; fmt = 'BGRA';
    }
    if (kind == FK_OTHER) { ulog("未知格式 %.4s → 按 BGRA 处理", fourcc(fmt)); kind = FK_BGRA; }
    s->display = d; s->w = w; s->h = h; s->fmt = fmt; s->kind = kind; s->queue = q;
    s->created_ms = now_ms();   // ★ v14：陈腐槽位判定基准
    if (handler) s->handler = Block_copy(handler);

    // ★ v12：缓冲分配走 alloc_buffers（可释放、可按需重建）
    if (alloc_buffers(s) != 0 && s->kind == FK_NV12) {
        // NV12 分配失败（多为内存不足 -6662）→ 试一次 BGRA 回退
        ulog("NV12 缓冲分配失败 → 回退 BGRA 重试");
        s->kind = FK_BGRA; s->fmt = 'BGRA'; kind = FK_BGRA; fmt = 'BGRA';
        if (alloc_buffers(s) != 0) ulog("!! BGRA 回退也失败：本次会话将无帧（请检查内存/槽位）");
    }

    // update 对象改为全局常驻 g_upd（见其定义处的注释）；
    // 这里只记录尺寸，供被接管的 GetRects 返回整屏脏矩形。
    s->upd = NULL;
    g_last_w = w; g_last_h = h;

    // 假句柄必须是合法 CFType，UU 会对它 retain/release
    CFTypeRef handle = (CFTypeRef)CFArrayCreateMutable(NULL, 0, NULL);
    Shim *victim = NULL; CFTypeRef victim_handle = NULL;
    pthread_mutex_lock(&g_lock);
    // ★★★ v14 第二道保险：主动清掉「陈旧死槽位」——create 后超过 60 秒仍未 start 的会话。
    //   正常路径下 my_start 失败会即时 slot_detach；这里兜住任何遗漏，
    //   防止槽位堆满后 create 只能返回假句柄（实测就是这样黑屏的：
    //   61 次 create 只配 46 次 stop，15 个槽位永久泄漏，RSS 涨到 1.7GB）。
    {
        double nowm = now_ms();
        int reaped = 0;
        for (int i = 0; i < MAXS; i++) {
            Shim *c = g_shim[i];
            if (c && !c->started && !c->dead && c->created_ms > 0 &&
                nowm - c->created_ms > 60000) {
                g_handle[i] = NULL; g_shim[i] = NULL;
                c->idx = -1; c->dead = 1;
                // ★★★ v16 关键修复：这里以前只摘映射、**不释放缓冲**，每个被回收的
                //   会话永久泄漏 3 个 IOSurface + 渲染缓冲（1600x900 约 28MB）。本机显存
                //   只有 256MB → 泄漏约 9 次即耗尽 → CVPixelBufferCreate 报 -6662 →
                //   新会话拿不到缓冲 → 连上黑屏。实测日志里 216 次分配失败就是这么攒出来的。
                //   started==0 保证没有 worker 线程在用这些缓冲，释放安全。
                release_frames(c);
                reaped++;
            }
        }
        if (reaped) {
            ulog("槽位回收：清掉 %d 个超过 60 秒未启动的死会话（v16 已连缓冲一起释放）", reaped);
            bufs_account("回收后");
        }
    }
    int idx = -1;
    for (int i = 0; i < MAXS; i++) if (!g_handle[i]) { idx = i; break; }
    if (idx < 0) {
        // ★★ v12：槽位满 → 回收「已停止且缓冲已释放」的最老槽位。
        //   这正是「反复切换设备接管就连不上」的根因：原来 stop 不交还槽位，
        //   8 次连接后 create 只能返回没有采集线程的假句柄（日志刷「流数超上限 8」）。
        //   只回收 not started 且 released 的槽位，运行中的流绝不回收。
        double oldest = 1e18;
        for (int i = 0; i < MAXS; i++) {
            Shim *c = g_shim[i];
            if (c && !c->started && c->released && c->stopped_ms < oldest) {
                oldest = c->stopped_ms; idx = i; victim = c; victim_handle = g_handle[i];
            }
        }
        if (idx >= 0) {
            g_shim[idx] = s; g_handle[idx] = handle; s->idx = idx;
            s->released = 0;
        }
    } else {
        g_shim[idx] = s; g_handle[idx] = handle; s->idx = idx;
    }
    pthread_mutex_unlock(&g_lock);

    if (idx < 0) {
        // 全在运行中，无法回收 —— 只能返回空句柄（无采集线程），并如实报错
        ulog("!! 流数超上限 %d 且全部在运行 → 本次连接将无画面", MAXS);
        release_frames(s);
        free(s);
        return (CGDisplayStreamRef)handle;
    }
    if (victim) {
        ulog("槽位满(%d) → 回收最老停止槽位 idx=%d（v12 槽位回收）", MAXS, idx);
        if (victim->handler) Block_release(victim->handler);
        if (victim->rls) CFRelease(victim->rls);
        if (victim_handle) CFRelease(victim_handle);
        free(victim);
    }

    ulog("create display=%u %zux%zu 请求格式=%.4s → 实际 kind=%d surf0=%p 缓冲数=%d queue=%s idx=%d",
         d, w, h, fourcc(fmt), kind, (void *)s->surf[0], s->nbuf, q ? "有" : "无", idx);
    // 把 UU 传进来的属性字典打出来（色彩空间/YCbCr 矩阵/最小帧间隔/是否含光标）——
    // 这些直接决定它期望的画面语义，是排查「帧在出但画面不出来」的关键输入。
    if (props && CFGetTypeID(props) == CFDictionaryGetTypeID()) {
        char line[640]; int off = 0;
        off += snprintf(line + off, sizeof line - off, "  请求属性:");
        CFIndex n = CFDictionaryGetCount(props);
        const void *keys[16], *vals[16];
        if (n > 16) n = 16;
        CFDictionaryGetKeysAndValues(props, keys, vals);
        for (CFIndex i = 0; i < n && off < (int)sizeof(line) - 80; i++) {
            char kb[128] = "?", vb[128] = "?";
            if (keys[i] && CFGetTypeID(keys[i]) == CFStringGetTypeID())
                CFStringGetCString((CFStringRef)keys[i], kb, sizeof kb, kCFStringEncodingUTF8);
            if (vals[i]) {
                CFTypeID t = CFGetTypeID(vals[i]);
                if (t == CFStringGetTypeID())
                    CFStringGetCString((CFStringRef)vals[i], vb, sizeof vb, kCFStringEncodingUTF8);
                else if (t == CFNumberGetTypeID()) {
                    long long lv = 0; CFNumberGetValue((CFNumberRef)vals[i], kCFNumberLongLongType, &lv);
                    snprintf(vb, sizeof vb, "%lld", lv);
                } else if (t == CFBooleanGetTypeID())
                    snprintf(vb, sizeof vb, "%s", CFBooleanGetValue((CFBooleanRef)vals[i]) ? "true" : "false");
                else
                    snprintf(vb, sizeof vb, "<对象>");
            }
            off += snprintf(line + off, sizeof line - off, " [%s=%s]", kb, vb);
        }
        ulog("%s", line);
    } else {
        ulog("  请求属性: (无)");
    }
    return (CGDisplayStreamRef)handle;
}

static CGDisplayStreamRef my_create(CGDirectDisplayID d, size_t w, size_t h, OSType fmt,
                                    CFDictionaryRef props, CGDisplayStreamFrameAvailableHandler handler) {
    return shim_create(d, w, h, fmt, props, NULL, handler);
}
static CGDisplayStreamRef my_create_dq(CGDirectDisplayID d, size_t w, size_t h, OSType fmt,
                                       CFDictionaryRef props, dispatch_queue_t q,
                                       CGDisplayStreamFrameAvailableHandler handler) {
    return shim_create(d, w, h, fmt, props, q, handler);
}

// ---------------------------------------------------------------------------
// ★ v12：帧缓冲的「分配 / 释放」独立成函数
//   背景：原实现把分配写在 create 里、stop 时故意不释放（当初怕 UU stop 后再 start）。
//   后果是【槽位 + 内存双泄漏】：每连接一次泄漏一个槽位与约 18MB 缓冲，
//   8 次之后 create 只能返回「没有采集线程的假句柄」→ 永远黑屏 / 显示「连不上」。
//   实测「反复切换多个设备接管」必现（每次切换泄漏一个），日志刷「流数超上限 8」。
//   现在：stop 时释放缓冲并交还槽位；start 时若缓冲已释放则按需重建（懒分配）。
// ---------------------------------------------------------------------------
static void release_frames(Shim *s) {
    // ★ v16：与实际释放对称记账。先记录本次是否真的持有缓冲，
    //   没有的话不减（否则计数会被重复调用带成负数，反而失去判据力）。
    int had = (s->surf[0] || s->pb[0] || s->buf || s->prev) ? 1 : 0;
    for (int i = 0; i < NBUF; i++) {
        if (s->pb[i])   { CVPixelBufferRelease(s->pb[i]); s->pb[i] = NULL; }
        if (s->surf[i]) { CFRelease(s->surf[i]);          s->surf[i] = NULL; }
    }
    if (s->buf) { free(s->buf); s->buf = NULL; }
    if (s->prev) { free(s->prev); s->prev = NULL; }   // ★ v15 变化检测缓冲
    if (s->ctx) { CGContextRelease(s->ctx); s->ctx = NULL; }
    if (had && s->had_bufs) {
        s->had_bufs = 0;
        __sync_fetch_and_sub(&g_live_buf_sessions, 1);
        __sync_fetch_and_sub(&g_live_buf_bytes, (long)(shim_mb(s) * 1024.0 * 1024.0));
    }
}

// ★★★ v14：把会话从槽位表摘除（让出槽位号）。
//   为什么需要它：start 失败的会话 UU 往往不再调 stop，槽位就永久占着
//   （started=0 且 released=0，连「已停止且已释放」的回收条件都不满足）。
//   实测泄漏 15 个槽位、进程 RSS 涨到 1.7GB 后 create 只能返回假句柄 → 黑屏。
//   ⚠ 刻意**不 free(s) 也不 CFRelease(handle)**：UU 可能仍持有该句柄并在之后调用
//   stop/getRunLoopSource，释放会造成 use-after-free。摘除后 lookup() 自然返回 NULL，
//   那些调用会走「未知句柄」的安全分支；代价只是每死一个会话泄漏 ~200 字节结构体。
//
//   ★★★ v16 修正：上面那句「只泄漏 200 字节」**是错的** —— 本函数以前只摘映射、
//   不释放缓冲，实际每次泄漏 3 个 IOSurface + 渲染缓冲（1600x900 约 28MB）。本机显存
//   仅 256MB，泄漏约 9 次即耗尽 → 后续 CVPixelBufferCreate 报 -6662 → 新会话无缓冲 →
//   **连上去没画面**（实测日志 216 次分配失败即此）。现在补上 release_frames(s)：
//   结构体仍留着防 UAF，但**大块内存（缓冲）立刻还回去**。
static void slot_detach(Shim *s) {
    if (!s) return;
    pthread_mutex_lock(&g_lock);
    int k = s->idx;
    if (k >= 0 && k < MAXS && g_shim[k] == s) {
        g_handle[k] = NULL;     // 槽位可被下次 create 复用
        g_shim[k]   = NULL;
        s->idx = -1;
        s->dead = 1;
    }
    pthread_mutex_unlock(&g_lock);
    // ★ v16：释放缓冲。仅当采集线程未启动（started==0）时释放 —— 有线程在用就绝不碰，
    //   宁可晚一步回收也不能 use-after-free。本函数的唯一调用点是 my_start 失败分支，
    //   那里 started 必为 0；这里再加一道读取保证正确性。
    if (!s->started) {
        double mb = shim_mb(s);
        release_frames(s);
        ulog("槽位让出：已释放该会话缓冲（约 %.1f MB，防显存泄漏；结构体保留防 use-after-free）", mb);
        bufs_account("让出后");
    } else {
        ulog("!! 槽位让出时采集线程仍在运行 → 本次不释放缓冲（防 use-after-free），交由 stop 处理");
    }
}

// 返回 0 = 缓冲就绪；非 0 = 分配失败
static int alloc_buffers(Shim *s) {
    size_t w = s->w, h = s->h;
    s->nbuf = NBUF;
    if (!w || !h) { ulog("!! alloc_buffers: 尺寸非法 %zux%zu", w, h); return -1; }

    if (s->kind == FK_NV12) {
        // ★ 必须走 CVPixelBuffer：用 IOSurfaceCreate 传 420v/420f 只会建出单平面，
        //   plane1 地址为 0x0（实测），写 CbCr 会直接崩或写坏内存。
        OSType cvfmt = (s->fmt == '420f') ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                          : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        for (int i = 0; i < NBUF; i++) {
            CFMutableDictionaryRef iosp = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                    &kCFTypeDictionaryValueCallBacks);
            CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                      &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, iosp);
            CVReturn cvr = CVPixelBufferCreate(NULL, w, h, cvfmt, attrs, &s->pb[i]);
            CFRelease(attrs); CFRelease(iosp);
            if (cvr != kCVReturnSuccess || !s->pb[i]) {
                // -6662 = kCVReturnAllocationFailed（内存不足）；-6661 = 参数非法
                ulog("!! CVPixelBufferCreate[%d] 失败(%d)（-6662=分配失败/内存不足）", i, (int)cvr);
                release_frames(s);
                return -1;
            }
            s->surf[i] = CVPixelBufferGetIOSurface(s->pb[i]);
            if (!s->surf[i]) { ulog("!! CVPixelBuffer[%d] 无 IOSurface", i); release_frames(s); return -1; }
            CFRetain(s->surf[i]);
            // ★ 色彩附件：真实 CGDisplayStream 出来的帧带色彩描述，UU 里也显式请求了
            //   kCGDisplayStreamYCbCrMatrix / kCGDisplayStreamColorSpace。缺附件时部分编码器
            //   会拒绝该帧（表现为"帧在出但画面不出来"）。我们的系数就是 BT.601，如实声明。
            CVBufferSetAttachment(s->pb[i], kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(s->pb[i], kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_SMPTE_C, kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(s->pb[i], kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        }
    } else {
        int32_t iw = (int32_t)w, ih = (int32_t)h, bpr = (int32_t)(w * 4), pf = (int32_t)s->fmt;
        for (int i = 0; i < NBUF; i++) {
            CFMutableDictionaryRef sp = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                  &kCFTypeDictionaryValueCallBacks);
            CFNumberRef nW = CFNumberCreate(NULL, kCFNumberSInt32Type, &iw);
            CFNumberRef nH = CFNumberCreate(NULL, kCFNumberSInt32Type, &ih);
            CFNumberRef nB = CFNumberCreate(NULL, kCFNumberSInt32Type, &bpr);
            CFNumberRef nP = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
            CFDictionarySetValue(sp, kIOSurfaceWidth, nW);
            CFDictionarySetValue(sp, kIOSurfaceHeight, nH);
            CFDictionarySetValue(sp, kIOSurfaceBytesPerRow, nB);
            CFDictionarySetValue(sp, kIOSurfacePixelFormat, nP);
            s->surf[i] = IOSurfaceCreate(sp);
            CFRelease(sp); CFRelease(nW); CFRelease(nH); CFRelease(nB); CFRelease(nP);
            if (!s->surf[i]) {
                ulog("!! IOSurfaceCreate[%d] 失败（格式 %.4s %zux%zu；内存不足或格式非法）",
                     i, fourcc(pf), w, h);
                release_frames(s);
                return -1;
            }
        }
    }

    s->buf = calloc(1, w * 4 * h);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    s->ctx = CGBitmapContextCreate(s->buf, w, h, 8, w * 4, cs,
                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!s->buf || !s->ctx) { ulog("!! 渲染缓冲分配失败（%zux%zu）", w, h); release_frames(s); return -1; }
    // ★ v15：上一帧快照（变化检测用）。分配失败不致命 —— 只是退回「恒整屏」的旧行为。
    if (uushim_dirty_mode() && !s->prev) {
        s->prev = calloc(1, w * 4 * h);
        if (!s->prev) ulog("!! 变化检测缓冲分配失败 → 本会话退回「恒整屏」行为（不影响出画面）");
    }

    s->released = 0;
    // ★ v16：记账（只计一次；release_frames 对称减回来）
    if (!s->had_bufs) {
        s->had_bufs = 1;
        __sync_fetch_and_add(&g_live_buf_sessions, 1);
        __sync_fetch_and_add(&g_live_buf_bytes, (long)(shim_mb(s) * 1024.0 * 1024.0));
    }
    return 0;
}

static int32_t my_start(CGDisplayStreamRef ref) {
    Shim *s = lookup(ref);
    if (!s) { ulog("start 未知句柄 %p", (void *)ref); return -1; }
    // ★ v13：缓冲未就绪时重试分配。内存压力常是瞬时的（实测 CVPixelBufferCreate 报
    //   -6662 后几秒内又能成功），而 create 时分配失败会让整个会话永远无帧（黑屏）。
    //   这里在真正开流前重试若干次，多数情况下能救回来。
    for (int attempt = 0; attempt < 8; attempt++) {
        int ready = (s->buf && s->ctx && s->w && s->h &&
                     (s->kind == FK_NV12 ? s->pb[0] : s->surf[0]));
        if (ready) break;
        if (attempt > 0 || s->released) {
            if (alloc_buffers(s) == 0) {
                ulog("start：缓冲分配在第 %d 次尝试成功（%d 个 %zux%zu）",
                     attempt + 1, NBUF, s->w, s->h);
                break;
            }
        }
        usleep(300 * 1000);
        if (attempt == 7) ulog("!! start：缓冲分配重试 8 次仍失败 → 本次会话无帧（内存不足）");
    }
    if (!s->buf || !s->ctx || (s->kind == FK_NV12 ? !s->pb[0] : !s->surf[0])) {
        // 仍失败：不启动采集线程（避免空转/空指针），并**立刻让出槽位**。
        // ★ v14：不摘除的话该槽位永久占用（UU 不再对失败的会话调 stop），
        //   累积满后 create 只能返回假句柄 → 黑屏。实测就是这样坏掉的。
        ulog("!! start：无可用缓冲，跳过启动采集线程，并让出槽位 idx=%d", s->idx);
        slot_detach(s);
        return -1;
    }
    if (!s->started) {
        g_dump_n = 0;   // ★ 每次新会话重置导出计数：保证「每次连接都能抓到当前画面」，
                        //   否则只导出进程生命周期内最早那 3 帧，事后取证全失效。
        s->running = 1; s->started = 1;
        if (pthread_create(&s->thr, NULL, worker, s) != 0) { s->running = 0; return -1; }
        ulog("start → 截图轮询线程已启动（目标 %d FPS）", UUSHIM_TARGET_FPS);
    }
    return 0;
}

static int32_t my_stop(CGDisplayStreamRef ref) {
    Shim *s = lookup(ref);
    if (!s) return -1;
    // 只停线程、不释放资源：UU 可能 stop 后再 start（分辨率变化）
    s->running = 0;
    if (s->started) { pthread_join(s->thr, NULL); s->started = 0; }

    // ★★★ v10 关键修复：补发一次 status=Stopped(3) 回调。
    //
    // 取证（反汇编 + sample）：
    //   ScreenCapturerCG::UnregisterFrameHandler 的流程是
    //     +0xad  dispatch_source_set_cancel_handler
    //     +0xb6  dispatch_source_cancel
    //     +0x103 callq 0x17b830        ← 等待①（cancel handler 完成）
    //     +0x10c callq *CGDisplayStreamStop   ← 我们的 my_stop
    //     +0x149 callq 0x17b830        ← 等待②（等回调链收敛）★ 卡在这里
    //   等待函数内部是「自旋 63 次 + std::__libcpp_atomic_wait + __ulock_wait」，
    //   timeout 参数传 0 ⇒ 无限等。
    //   真实 CGDisplayStreamStop 会终止回调链、让上层收到最终状态（status=Stopped）；
    //   我们只停了线程、从不发这个状态（shim 日志「状态[..,..,..,0]」第 4 位恒为 0），
    //   于是 UU 永远等不到 —— 整个会话管理瘫痪，此后任何设备连接都不再启动采集
    //   （现象：连上但黑屏 / 一直「连接中」），只有重启进程才能恢复。
    //
    // 为什么只在长会话后暴露：短会话（几十秒）三次实测均未触发，109 分钟/48543 帧的
    // 会话断开时必现 —— 说明该收敛路径依赖会话期间积累的状态。
    if (s->handler && s->queue) {
        dispatch_queue_t q = s->queue;
        CGDisplayStreamFrameAvailableHandler hh = s->handler;
        dispatch_async(q, ^{
            __sync_fetch_and_add(&g_hb, 1);
            __sync_fetch_and_add(&g_st[3], 1);
            // surface/update 传 NULL（真实语义：停止时没有新帧）；
            // UU 的 handler 对该 CF 参数有 testq/je 空检查，安全。
            hh(ST_FRAME_STOPPED, mach_absolute_time(), NULL, NULL);
            __sync_fetch_and_add(&g_ha, 1);
        });
        ulog("stop：已补发 status=Stopped 回调（v10 修复 UU 注销死锁）");
    }

    // ★ v9：返回前等所有已派发的回调块执行完（防止 cancel handler 排在帧回调之后延迟执行）
    int drained = 0;
    if (s->grp) {
        dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)3 * NSEC_PER_SEC);
        if (dispatch_group_wait(s->grp, dl) == 0) drained = 1;
    } else drained = 1;   // 没有派发过块（同步路径）

    ulog("stop（累计出帧 %d，回调进%d/出%d 待回%d，延迟%.0fms 峰%.0fms，回调排空=%s%s）",
         g_frames, g_hb, g_ha, g_hb - g_ha, (double)g_lat_last_ms, (double)g_lat_max_ms,
         drained ? "是" : "否",
         drained ? "" : " ⚠ 超时：UU 注销流程可能受影响");
    s->inflight = 0;

    // ★★★ v12 关键修复：释放帧缓冲（约 18MB/会话）。不释放会累积到内存不足，
    //   届时 CVPixelBufferCreate 报 -6662（分配失败）→ 回退 BGRA 也失败 →
    //   帧没有 IOSurface → UU 编码链不启动 → 黑屏。
    //   （实测症状：23:35 起连续 3 次连接都是 BGRA + surf0=0x0 + CopyTo=0）
    //   缓冲释放后若 UU 复用同一句柄再次 start，my_start 会自动重建（懒分配）。
    release_frames(s);
    s->released = 1;
    s->stopped_ms = now_ms();
    // ★ v16：stop 后记账归位。正常使用时这里应回落到 0 会话 / 0 MB；
    //   若只涨不落，就是又出现了新的泄漏路径（这次两处就是这么找出来的）。
    bufs_account("stop 后");
    return 0;
}

// 返回一个「永不触发的真 source」：避免真实实现拿到我们的假句柄而崩溃
static CFRunLoopSourceRef my_get_rls(CGDisplayStreamRef ref) {
    Shim *s = lookup(ref);
    if (!s) return NULL;
    if (!s->rls) {
        CFRunLoopSourceContext ctx; memset(&ctx, 0, sizeof(ctx));
        s->rls = CFRunLoopSourceCreate(NULL, 0, &ctx);
    }
    return s->rls;
}

// ★★ 严格匹配真实签名：返回「我们自己的静态矩形数组」指针，并通过 *rectCount 回报个数。
//   **绝不写调用者提供的任何缓冲区** —— 那是 v1~v4 卡死的致命 bug。
//   真实 API 语义：返回的数组归调用者使用，在下一次调用前有效 → 与静态数组语义一致。
static const CGRect *my_update_get_rects(void *upd, int type, size_t *count) {
    (void)upd; (void)type;
    __sync_fetch_and_add(&g_rects, 1);
    static CGRect r[1];
    // ★★★ v15：如实回答「哪里变了」。
    //   没变化 → 报 0 个矩形，UU 自己就不编码这一帧（省 CPU 的正路，同 VNC）。
    //   有变化 → 报整屏（与旧行为一致）。
    //   ⚠ 与「恒返回 0x0」的区别：那只在**真的没变**时才这么报，画面一动就会恢复推流。
    int full = 1;
    if (uushim_dirty_mode() && !g_changed) {
        full = 0;
        __sync_fetch_and_add(&g_zero_rects, 1);
    }
    if (full) {
        if (g_last_w > 0 && g_last_h > 0) r[0] = CGRectMake(0, 0, (CGFloat)g_last_w, (CGFloat)g_last_h);
        else                              r[0] = CGRectMake(0, 0, 1, 1);
        if (count) *count = 1;
    } else {
        // 仍返回一个合法数组（万一调用方不看 count 也不会读到野指针），但如实报 0 个
        r[0] = CGRectMake(0, 0, 0, 0);
        if (count) *count = 0;
    }
    return r;
}

// 丢帧计数：返回 0（不丢）比返回垃圾值安全
static int32_t my_drop_count(void *upd) { (void)upd; return 0; }

// ===========================================================================
// ★ v7：接管 CGWindowListCreateImage —— UURemoteServer 主程序里的**第二条采集路径**
//   实测：UURemoteServer 导入了 CGWindowListCreateImage（libstreamer 里没有），
//   调用形式为 option=0x8(IncludingWindow) + 指定 windowID + imageOption=0x8(BestResolution)，
//   且紧接着 `testq %rax,%rax; je <错误分支>` —— 返回 NULL 就走异常处理。
//   本机 macOS 15 上该 API 已被弃用，很可能恒返回 NULL → UU 判定采集不可用。
//   这里改为「用 CGDisplayCreateImage 抓整屏」返回，并记录调用参数，用于验证该假设。
//   注意：无法调用原实现（interpose 会把本镜像的引用也重定向到自己），
//   所以这是「替换」而非「包装」—— 但原路径本来就返回 NULL（见上），替换不会更差。
// ===========================================================================
static CGImageRef (*p_mkimg)(CGDirectDisplayID);

static CGImageRef my_window_list_create_image(CGRect bounds, uint32_t listOption,
                                             uint32_t windowID, uint32_t imageOption) {
    __sync_fetch_and_add(&g_wl_calls, 1);
    if (!p_mkimg) {
        void *h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        if (h) p_mkimg = (CGImageRef (*)(CGDirectDisplayID))dlsym(h, "CGDisplayCreateImage");
    }
    CGImageRef img = p_mkimg ? p_mkimg(CGMainDisplayID()) : NULL;
    if (g_wl_calls <= 5 || g_wl_calls % 60 == 0)
        ulog("★窗口截图调用 #%d bounds=%.0fx%.0f option=0x%x windowID=%u imgOption=0x%x → %s %zux%zu",
             g_wl_calls, bounds.size.width, bounds.size.height, listOption, windowID, imageOption,
             img ? "返回整屏" : "NULL",
             img ? CGImageGetWidth(img) : 0, img ? CGImageGetHeight(img) : 0);
    return img;
}

__attribute__((used)) static struct { const void *r; const void *e; } i1 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_create, (const void *)(uintptr_t)&CGDisplayStreamCreate };
__attribute__((used)) static struct { const void *r; const void *e; } i2 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_create_dq, (const void *)(uintptr_t)&CGDisplayStreamCreateWithDispatchQueue };
__attribute__((used)) static struct { const void *r; const void *e; } i3 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_start, (const void *)(uintptr_t)&CGDisplayStreamStart };
__attribute__((used)) static struct { const void *r; const void *e; } i4 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_stop, (const void *)(uintptr_t)&CGDisplayStreamStop };
__attribute__((used)) static struct { const void *r; const void *e; } i5 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_get_rls, (const void *)(uintptr_t)&CGDisplayStreamGetRunLoopSource };
__attribute__((used)) static struct { const void *r; const void *e; } i6 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_update_get_rects, (const void *)(uintptr_t)&CGDisplayStreamUpdateGetRects };
extern int32_t CGDisplayStreamUpdateGetDropCount(void *update);
__attribute__((used)) static struct { const void *r; const void *e; } i7 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_drop_count, (const void *)(uintptr_t)&CGDisplayStreamUpdateGetDropCount };
// ★ v7：UU 主程序的第二条采集路径（libstreamer 里没有，只在 UURemoteServer 里被调用）
//   SDK 把 CGWindowListCreateImage 标为 macOS 15 不可用，用 asm 标签绑到同一符号来绕开该标记
extern CGImageRef uu_winimg(CGRect, uint32_t, uint32_t, uint32_t) __asm("_CGWindowListCreateImage");
__attribute__((used)) static struct { const void *r; const void *e; } i8 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_window_list_create_image, (const void *)(uintptr_t)&uu_winimg };

// ===========================================================================
// v8：VideoToolbox 编码器拦截 —— 修「别的设备连上没画面」的第二道门
// ---------------------------------------------------------------------------
// 现场：Metal 门禁绕过后，VTCompressionSessionCreate 仍失败，系统日志出现
//       (VideoProcessing) Low latency RC mode requires hardware encoder
// 实测（本机 108 无硬件编码器）：
//       hw=TRUE  + 低延迟RC=TRUE  → kVTParameterErr(-12902) 建会话失败  ← 原版行为
//       hw=FALSE + 低延迟RC=TRUE  → 同样失败                            ← 只改 hw 无效
//       不设置 / =FALSE           → 建会话成功、8 帧正常出码
//   对照组 Air（M2 有硬编）：hw=TRUE+低延迟 成功、hw=FALSE+低延迟 失败
//   → 失败点确认为「低延迟 RC 强制要求硬件编码器」。本机没有，故必须把该键关掉。
// 做法：拦截 VTCompressionSessionCreate，复制一份 spec 并把低延迟键改成 false 再调真实现；
//       同时包一层输出回调，把「提交帧/出码帧/编码错误」写进日志（原先这类信息全在加密 slog 里）。
// ===========================================================================
#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>

typedef OSStatus (*uuvt_create_t)(CFAllocatorRef, int32_t, int32_t, CMVideoCodecType,
                                  CFDictionaryRef, CFDictionaryRef, CFAllocatorRef,
                                  VTCompressionOutputCallback, void *, VTCompressionSessionRef *);
typedef OSStatus (*uuvt_encode_t)(VTCompressionSessionRef, CVImageBufferRef, CMTime, CMTime,
                                  CFDictionaryRef, void *, VTEncodeInfoFlags *);

typedef struct { VTCompressionOutputCallback cb; void *ref; } uuvt_cbwrap;

static uuvt_create_t g_vt_create;
static uuvt_encode_t g_vt_encode;
static int g_vt_calls, g_vt_ll_fixed, g_vt_create_fail;
static int g_vt_submit, g_vt_submit_err, g_vt_out, g_vt_cb_err;

// 前向声明（uuvt_sym 里要做「别拿到自己」的自检）
static OSStatus my_vt_create(CFAllocatorRef, int32_t, int32_t, CMVideoCodecType,
                             CFDictionaryRef, CFDictionaryRef, CFAllocatorRef,
                             VTCompressionOutputCallback, void *, VTCompressionSessionRef *);
static OSStatus my_vt_encode(VTCompressionSessionRef, CVImageBufferRef, CMTime, CMTime,
                             CFDictionaryRef, void *, VTEncodeInfoFlags *);

static void *uuvt_sym(const char *name) {
    // ★ 必须用 RTLD_NEXT：本库通过 __DATA,__interpose 顶替了该符号，
    //   用 dlopen(handle)+dlsym 拿到的仍是「我们自己」→ 自我递归 → SIGSEGV（踩过）
    void *p = dlsym(RTLD_NEXT, name);
    void *q = NULL;
    static void *h;
    if (!h) h = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_LAZY);
    if (h) q = dlsym(h, name);
    if (getenv("UUSHIM_VTDBG")) {
        Dl_info i1, i2;
        const char *m1 = (p && dladdr(p, &i1)) ? i1.dli_fname : "(none)";
        const char *m2 = (q && dladdr(q, &i2)) ? i2.dli_fname : "(none)";
        ulog("VTDBG %s: RTLD_NEXT=%p[%s]  dlopen=%p dlopen_handle=%p[%s] 自己=%p",
             name, p, m1, (void *)q, h, m2, (void *)(uintptr_t)&my_vt_create);
    }
    if (!p || p == (void *)(uintptr_t)&my_vt_create || p == (void *)(uintptr_t)&my_vt_encode) {
        if (q && q != (void *)(uintptr_t)&my_vt_create && q != (void *)(uintptr_t)&my_vt_encode) return q;
        return NULL;   // 宁可放弃也不能递归
    }
    return p;
}

// 包一层输出回调：统计真正出了多少码流帧
static void my_vt_output_cb(void *refcon, void *srcRefCon, OSStatus status,
                            VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    uuvt_cbwrap *w = (uuvt_cbwrap *)refcon;
    if (status != noErr) {
        g_vt_cb_err++;
        if (g_vt_cb_err <= 6) ulog("VT 编码回调错误 status=%d（累计 %d）", (int)status, g_vt_cb_err);
    } else if (sb) {
        g_vt_out++;
        if (g_vt_out <= 4 || g_vt_out % 120 == 0) ulog("VT 出码 #%d（提交=%d 出错=%d）", g_vt_out, g_vt_submit, g_vt_submit_err);
    }
    if (w && w->cb) w->cb(w->ref, srcRefCon, status, flags, sb);
}

static OSStatus my_vt_create(CFAllocatorRef alloc, int32_t w, int32_t h, CMVideoCodecType codec,
                             CFDictionaryRef spec, CFDictionaryRef srcAttrs, CFAllocatorRef outAlloc,
                             VTCompressionOutputCallback cb, void *cbRef, VTCompressionSessionRef *out) {
    if (!g_vt_create) g_vt_create = (uuvt_create_t)uuvt_sym("VTCompressionSessionCreate");
    if (!g_vt_create) { ulog("VT: 取不到真实现，放弃"); return -1; }
    g_vt_calls++;

    // 复制 spec，把「低延迟 RC」强制关掉（该模式强制要求硬件编码器，本机没有）
    CFMutableDictionaryRef fixed = NULL;
    int had_ll = 0, ll_true = 0;
    if (spec && CFDictionaryContainsKey(spec, kVTVideoEncoderSpecification_EnableLowLatencyRateControl)) {
        CFTypeRef v = CFDictionaryGetValue(spec, kVTVideoEncoderSpecification_EnableLowLatencyRateControl);
        had_ll = 1;
        if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) ll_true = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
        fixed = CFDictionaryCreateMutableCopy(NULL, 0, spec);
        CFDictionarySetValue(fixed, kVTVideoEncoderSpecification_EnableLowLatencyRateControl, kCFBooleanFalse);
    }

    // 包输出回调（回调为 NULL 时不动，避免改变语义）
    uuvt_cbwrap *wrap = NULL;
    VTCompressionOutputCallback useCb = cb;
    void *useRef = cbRef;
    if (cb) {
        wrap = (uuvt_cbwrap *)malloc(sizeof *wrap);
        wrap->cb = cb; wrap->ref = cbRef;
        useCb = my_vt_output_cb; useRef = wrap;
    }

    OSStatus st = g_vt_create(alloc, w, h, codec, fixed ? (CFDictionaryRef)fixed : spec, srcAttrs,
                              outAlloc, useCb, useRef, out);
    if (had_ll) g_vt_ll_fixed++;
    if (st != noErr) g_vt_create_fail++;
    ulog("VT 建会话 #%d codec=0x%x %dx%d 低延迟键=%s → %s(%d) 累计[已改键=%d 失败=%d]",
         g_vt_calls, (unsigned)codec, (int)w, (int)h,
         had_ll ? (ll_true ? "有true→已改false" : "有false") : "无",
         st == noErr ? "成功" : "失败", (int)st, g_vt_ll_fixed, g_vt_create_fail);
    if (fixed) CFRelease(fixed);
    return st;
}

static OSStatus my_vt_encode(VTCompressionSessionRef s, CVImageBufferRef img, CMTime pts, CMTime dur,
                             CFDictionaryRef props, void *refcon, VTEncodeInfoFlags *flags) {
    if (!g_vt_encode) g_vt_encode = (uuvt_encode_t)uuvt_sym("VTCompressionSessionEncodeFrame");
    if (!g_vt_encode) return -1;
    OSStatus st = g_vt_encode(s, img, pts, dur, props, refcon, flags);
    g_vt_submit++;
    if (st != noErr) {
        g_vt_submit_err++;
        if (g_vt_submit_err <= 6 || g_vt_submit_err % 200 == 0)
            ulog("VT 提交帧失败 #%d status=%d（累计失败=%d）", g_vt_submit, (int)st, g_vt_submit_err);
    } else if (g_vt_submit <= 4 || g_vt_submit % 200 == 0) {
        ulog("VT 提交帧 #%d 成功（出码=%d 出错=%d）", g_vt_submit, g_vt_out, g_vt_submit_err);
    }
    return st;
}

// ★★★ v11：默认【不注册】VT 拦截 —— 这是 v10 黑屏的根因，务必保持关闭。
//
// 为什么必须关：
//   interpose 一旦真正生效，本库内 `dlsym(RTLD_NEXT)` 与 `dlopen(框架)+dlsym`
//   **全都只能拿到我们自己**（本机实测；见 skill「给 interpose 加透传式探针在本机行不通」）。
//   于是 `my_vt_create` 的自检只能判定「取不到真实现」→ `return -1`
//   ⇒ 上层每次创建 VT 编码会话都失败 ⇒ 编码链根本起不来 ⇒ 帧转换不被调用（CopyTo=0）
//   ⇒ 对端黑屏。日志特征：`VT: 取不到真实现，放弃` 每秒刷屏 + cpupath 无任何成功记录。
//
// 为什么可以关：
//   这两处拦截的唯一目的是「把 EnableLowLatencyRateControl 键改成 false」，
//   而该功能已由磁盘补丁 `lowlat` 在 UU 内更上游地实现（`patch_tool.py check` 五行全 patched）。
//   属纯冗余；关掉后 VT 走系统原函数，会话可正常创建。
//
// 排查时若要临时启用：把下面的 0 改成 1 重新编译（同时需接受它会阻断编码的现实）。
#if 0
__attribute__((used)) static struct { const void *r; const void *e; } i9 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_vt_create, (const void *)(uintptr_t)&VTCompressionSessionCreate };
__attribute__((used)) static struct { const void *r; const void *e; } i10 __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)&my_vt_encode, (const void *)(uintptr_t)&VTCompressionSessionEncodeFrame };
#endif
