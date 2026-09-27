# A 方案：帧源替换 shim（已验证可出帧，已接入安装脚本）

## 它是什么
不改 UU 任何代码、不用自建网络通道：保留 UU 的编码器 + P2P 传输，只把「帧源」换掉。
用 dyld interpose 接管 UU 调用的 `CGDisplayStream*`，内部改用截图轮询
（`CGDisplayCreateImage`，ToDesk 走的就是这条路）产生真帧，写进 IOSurface 后回调给 UU。

## v2 修掉的三个「有帧但无画面」根因（v1 全部踩中）
| # | v1 的错 | 后果 | v2 的修法 |
|---|---|---|---|
| 1 | 回调 status 传 **3** | 3 是 `Stopped`（"流已停止，不再调用 handler"），**0 才是 `FrameComplete`** → UU 丢弃所有帧 | 传 0；`CGDisplayStream.h` 的 `CF_ENUM` 从 0 起，无显式赋值 |
| 2 | `UpdateGetRects` 返回 **0×0** | UU 认为「画面无变化」→ 不推流 | 返回整屏矩形（伪造 update 对象携带 w/h） |
| 3 | 无条件按 **BGRA** 写 surface | UU 请求 `420v`/`420f`（NV12）时编码器拿到错格式 → 黑帧 | 按请求格式转换 BGRA→NV12；**且必须用 `CVPixelBufferCreate`**（`IOSurfaceCreate` 传 420 只建单平面，plane1 地址实测为 0x0） |

附带修正：回调改为 `dispatch_async` 到**调用者传入的 queue**（真实 API 语义，避免 UU 状态机竞态）；
`displayTime` 改用 `mach_absolute_time()`；日志落 `/tmp/uushim.log` 并同步 `os_log`
（UU 由 launchd 启动，stderr 被吞，`log show` 查不到 stderr 输出）。

## 一键安装 / 还原（推荐路径）
```bash
cd <本项目根目录>
sudo bash uu.sh shim-install    # 安装
sudo bash uu.sh shim-restore    # 还原
```
安装脚本会：部署 `libuushim.dylib` → 给 `UURemoteServer` 加一条 `LC_LOAD_DYLIB`
（**不改任何机器码**）→ 用同一张证书重签整包（UURemoteServer 额外带
`disable-library-validation`）。
> 依赖前提：先用 `sudo bash uu.sh cg-install` 装好三处补丁（旧脚本 `uu-cg-patch.sh` 已并入 `uu.sh`）。本方案是它的补充，不是替代。

## 验证结果（本机 2011 Mac mini / macOS 15.7.9 / 无 IOGPU 无 Metal）

**harness 严格验证（测试程序未随仓库分发；三种请求格式各 3 秒）**
| 请求格式 | 完整帧 | 空脏矩形 | 平均亮度 | 结论 |
|---|---|---|---|---|
| BGRA | 14 | 0 | 131.6 | ✔ 通过 |
| 420v | 14 | 0 | 129.0（Cb=131 Cr=128） | ✔ 通过 |
| 420f | 14 | 0 | 131.5 | ✔ 通过 |
| **对照：不注入（真实 API）** | 40 | **40（全空）** | **0.0（全黑）** | 本机真实 API 拿到的是黑帧 |

对照组很关键：本机真实 `CGDisplayStream` **确实在回调 `FrameComplete`**，
但 surface 内容全黑、脏矩形全空 —— 这正是 UU「正在传输画面」卡住的机制。

**注入到真实 UU 后**：`UURemoteServer` 同时加载 `libstreamer` + `libuushim`；
被控端 CPU ≈ 47%（截图轮询确实在跑）。

## CPU 实测（关键疑问：会不会 CPU 狂转）
| 项 | 实测 |
|---|---|
| shim 采集侧（6.7 秒出 52 帧） | user 1.72s + sys 0.67s = **36%（0.36 核）** |
| 对照（不注入、无帧） | 0.19s = 3% |
| 编码器 XPC 进程（1080p 全速） | **55%** |
| 截图单帧成本 | 67~76 ms → 帧率天花板 13~15 FPS |
| **合计（能出 7~8 FPS 画面）** | **≈ 91%（0.91 核）** |

**对比现状**：三处补丁装好、无画面时，UU 自己连着就烧 **~115%**（反复重试）。
→ A 方案 CPU **不增反降**，且终于有画面。限帧率（如 5 FPS）还可再降。

## 用法（本机验证工具，★ 未随仓库分发）
`harness` 用来验证 shim 是否真出帧。它只放在**本机归档**里
（`archive/` 已被 `.gitignore` 排除，克隆下来不会有这个目录）：
```bash
cd archive/20260926-round2/shim-experiments        # 本机归档路径
# 对照（无帧）
./harness
# 注入 shim（出帧）
DYLD_INSERT_LIBRARIES=$PWD/uushim.dylib ./harness
```

## 装进 UU 的前提（尚未执行）
1. 重签 UU 时补两个权限：`disable-library-validation`、`allow-dyld-environment-variables`
2. 给被控侧进程设 `DYLD_INSERT_LIBRARIES`（UURemoteServer 由 UURemoteService 拉起）
3. 必须保留还原命令；UU 自动更新会覆盖

## 已知限制
- 帧率上限 ~8 FPS（截图 67ms 是硬成本；本机 CGDisplayStream 已废）
- 快速拖动/看视频会卡；看日志、看文档、点按钮够用
- 画面无变化时不省 CPU（截图本身是成本，小区域探测也要 12~30ms，不划算）

---

# 路线二：二进制级修复（不用环境变量）—— 已验证

## 与路线一（DYLD_INSERT_LIBRARIES）的区别
| | 路线一 注入 | 路线二 改二进制 |
|---|---|---|
| 加载方式 | 环境变量 | Mach-O 里加一条 `LC_LOAD_DYLIB` |
| 需要 `allow-dyld-environment-variables` | 是 | **不需要** |
| 启动方式受限 | 是（LaunchAgent/GUI 双击可能不生效） | **不受限** |
| 需要 wrapper | 是 | 否 |

## 核心机制
`libstreamer.dylib` 通过 `__got` 表导入 `CGDisplayStreamCreateWithDispatchQueue`。
shim 里用 `__DATA,__interpose` 声明替换 ⇒ dyld 在绑定阶段把**所有其他库**对该符号的
引用指向 shim。**不需要改 libstreamer 的任何一个字节。**

## 实测证据（本机 macOS 15.7.9）
| 实验 | 条件 | 结果 |
|---|---|---|
| A | 给 harness 加 LC_LOAD_DYLIB，**不设环境变量** | 40 帧 ✔ |
| B | 主程序开硬化运行时（`codesign -o runtime`）后再加 | 仍出帧 ✔ |
| C | 主程序加依赖 → 拦截**另一个库**(libmid)里的调用 | 53 帧 ✔（UU 的真实场景）|
| 对照 | 不加依赖 | 0 帧（53 次 Idle）|

## 落点选择
必须加在**被控端采集进程**上：`/Applications/UURemote.app/Contents/Helpers/UURemoteServer`
（它是 `.active_pid` 指向的会话进程，且已导入 libstreamer）。
> 主程序 `UURemote` 也加载了 libstreamer，但那是控制端解码用，加了没意义。

各二进制的 load commands 尾部空间（够放一条 56~88 字节的 LC_LOAD_DYLIB）：
| 二进制 | padding |
|---|---|
| libstreamer.dylib | 23360 字节（超宽裕） |
| UURemoteServer | 216 字节 |
| UURemote（主程序） | 320 字节 |

## 工具
`tools/insert_dylib.py`（自研，支持 fat/thin）：
```bash
python3 tools/insert_dylib.py --check <binary>          # 查空间
python3 tools/insert_dylib.py --add <binary> <dylib>    # 加依赖（自动备份+重签）
python3 tools/insert_dylib.py --restore <binary>        # 还原
```
坑：`LC_LOAD_DYLIB` 的 `lc_str` 名字偏移**相对本命令起始**，必须紧跟在 24 字节头之后
（写成 0 会让 dyld 把名字读成 `\f` 而加载失败）。

## 仍然做不到的
**纯改机器码修 bug 不可行**：需要往 libstreamer 里插入几百字节新逻辑（截图线程、
IOSurface 管理、像素格式转换、回调调度），而 libstreamer **一个截图 API 都没导入**
（只有 `CGDisplayStreamCreate/Start/Stop/UpdateGetRects`），加新导入要重写符号表与
LINKEDIT，极其脆弱；且改调用目标只能指向已存在的函数，没有等价接口可指。

## 仍需注意
- 重建签名时要保留 `disable-library-validation`（shim 是不同签名者；实测 adhoc+runtime
  能过，自签证书组合需在真 App 上再验一次）
- shim 建议用与 UU 相同的证书签名，提高通过率
- UU 自动更新会覆盖，需重跑
