# UU远程 CoreGraphics 采集补丁（黑屏 / 卡在「正在传输画面」）

> **记不住就看这里：先 `status`，装 `install`，还原 `restore`，连不上 `reset`。**
>
> **入口只有一个：`uu.sh`**（原来的 9 个脚本已全部并入它，命令见下）

## 救命命令速查

```bash
D=~/.hermes/uuremote-cg-patch/uu.sh

# ① 查现在什么状态（免 sudo，★ 最常用；补丁/shim/进程/看门狗/内存一屏看完）
bash $D status

# ② 装全套 / UU 更新后重装（★ 版本自适应，无需重新分析）
sudo bash $D install

# ③ 还原（回到装本方案之前）
sudo bash $D restore

# ④ 连不上 / 黑屏（先试这个；不会踢掉正在串流的用户）
sudo bash $D reset

# ⑤ 报「无法连接至服务器 1001」/ 本机不上线
sudo bash $D sign      # 重签名（修签名不一致）
sudo bash $D daemon    # 重启 root 守护进程（修状态陈旧）

# ⑥ 查 UU 实际走了哪套采集器（免 sudo，手机连过一次后跑）
bash $D verify

# ⑦ 帧率低：先看 status 里的 Docker 告警，再考虑降分辨率
bash $D setmode list       # 看可选分辨率
bash $D setmode 1280x720   # 降到 720p（像素少 2.25 倍 → 帧率明显回升）
```

`install` = `cg-install`（第1/3/4道门）+ `shim-install`（第2道门），会自动完成：
识别 UU 版本 → 重建基线 → 定位补丁点 → 打补丁 → 注入帧源 → 用证书重签名 → 启动。
**UU 每次自动更新后，直接重跑 `install` 就行。**

全部子命令：`bash $D help`

## 两个问题的根因（都查实了，有对照组）

### 问题一：纯黑屏 / 卡在「正在传输画面」

本机（2011 Mac mini + AMD HD6630M + OCLP 补丁系统）**缺少 `IOGPU`**（GPU 抽象层），
导致 macOS 的 ScreenCaptureKit（SCK）**必然启动失败**：
`SCStream startCaptureWithCompletionHandler error` + 远程队列 `-16665`。

**关键**：UU 其实自带两套采集器，只是永远选不到能用的那套：

```
ScreenCapturerSck   ← ScreenCaptureKit（本机坏）
ScreenCapturerCG    ← CoreGraphics（本机好，实测抓 1920x1080 正常）
```

工厂函数 `CreateScreenCapturer()` 的决策逻辑（4.40.0 反汇编）：

```
movl $0x1, %edi
movl $0xe, %esi            # 参数 14
callq __availability_version_check(1,14,0,0)   # macOS >= 14 ?
testl %eax, %eax
je    +7                   # ★ 版本 <14 时跳去用 CG
call  ScreenCapturerSck::Create()   # 本机走这条 → -3802 → 黑屏
jmp   +5
call  ScreenCapturerCG::Create()    # 我们要走这条
```

**修法**：把那个 `je`（0x74）改成 `jmp`（0xEB），无条件走 `ScreenCapturerCG`。
内容仍是原题，没改动网络/协议/上传行为。

对照证据（同一台机）：
- 走 SCK 的全挂：UU(`-3802`)、`screencapture`(SIGKILL)、cua-driver(SCStream，抓空)
- 走 CoreGraphics 的全正常：ToDesk(`CGDisplayStream`)、系统屏幕共享(只链 CG，不碰 SCK)

### 问题一之二：卡在「正在传输数据」（音频采集器也在用 SCK）

**这是第二处、独立的 SCK 使用点**，容易被漏掉：

```
DesktopAudioCapture → SckAudioCapture  ── macOS>=13 时用 SCK 采音频
  守卫：__availability_version_check(1, 13, 0, 0)
  不满足(老系统) → 不分配 SckAudioDevice，Start() 直接 return 0（优雅跳过）
  满足  → 走 SCK 建流，本机必然 -3802 失败 → 会话卡住
```

UU 4.40 里 SCK 有**两条**路径（都是自建 ObjC 包装类）：

| 路径 | 入口 | 守卫版本 | 加的输出 |
|---|---|---|---|
| 视频 | `CreateScreenCapturer()`（已被补丁 1 修掉） | macOS **14** | 1 个（type=0 屏幕） |
| 音频 | `SckAudioCapture`（构造/析构/Start） | macOS **13** | 2 个（type=1 音频 + type=0 屏幕） |

**怎么区分日志里的 SCK 报错属于哪条**：数 `-[SCStream addStreamOutput:...]` 的出现次数
—— 音频是 **2 次**（type=1、type=0），视频是 1 次。看到 2 次就说明是音频在拖后腿。

**修法（补丁 2）**：把音频那三处守卫掰成「不满足」→ 按老系统处理，完全不碰 SCK。
代价：本机没有远程声音（本来也永远不会有，SCK 在这台机器上不可能成功）；
这等于让 UU 按 macOS 12 的官方行为运行。三处都是分支翻转，可无损还原：

```
构造（短跳 0x74→0xEB）    不分配 SckAudioDevice
析构（短跳 0x74→0xEB）    跳过 SCK 清理
Start（近跳 0f84→e9）    直接 return 0（成功、什么都不做）
```

注意：`0f 84`（near je）是 6 字节、`e9`（jmp）是 5 字节 —— 转换时 rel32 要 **+1** 补偿，
并补一个 `0x90`(nop) 占位；还原时反向 −1。工具已处理，且有「往返无损」自检。

### 问题一之三：采集成功了，但「零帧」→ 还是卡在「正在传输画面」（编码器要 Metal）

**第三处、也是最隐蔽的一处**：UU 无条件要求 VideoToolbox **硬件编码器**。

```
VideoToolboxEncoderT<SystemVideoToolboxEncoderPolicy>::ResetVTCompressionSession()
  encoderSpec[EnableHardwareAcceleratedVideoEncoder] = kCFBooleanTrue   ← 写死，没有任何配置分支
```

本机（OCLP macOS 15 + AMD HD6630M / Intel HD3000）**不支持 Metal**
（`system_profiler SPDisplaysDataType | grep -i Metal` 没有 `Metal:` 行），于是：

```
[E] Failed to create metal device.
[E] failed to init VIDEO TOOLBOX encoder, error: 12 (video encode failed)
```
—— 每 17ms 重试一次，永远出不了帧。采集这关其实**已经过了**：
`start video capture screen 1019215315 success` + `cg desktop capture register dispaly ... frame handler`
都正常，QoS 上报 JSON 里 `"capture_impl":"CG"` 但 `"width":0,"height":0`（零帧）。

**关键反证**：自己写 VT 编码测试，不要求硬件加速（或显式 false），
本机照样能编出帧（1920x1080，10/10 帧）。所以**不是机器不能编码，是 UU 非要硬件编码**。

**修法（补丁 3，等价 UU 自带的 `force_software_encoder`）**：
只把「值加载」那条指令的 4 字节位移改指向 `___kCFBooleanFalse` 槽位：

```
0x1fb287  movq 0x94d1a2(%rip),%rax   ## ___kCFBooleanTrue    ← 改前
0x1fb287  movq 0x94d19a(%rip),%rax   ## ___kCFBooleanFalse   ← 改后
```
槽位地址由 `otool -Iv <lib> | grep kCFBoolean` 给出；
另一处 `EnableLowLatencyRateControl`（0x1fb30d）用的是**另一个槽位**，不受影响。

代价：视频走软件编码（本机 CPU 编 1080p 会吃一些 CPU，但这是唯一可行路径）。

### 怎么判定某台机器是 SCK 系还是 CG 系

```
SCK 系（挂）：UU 黑屏/-3802、screencapture、cua-driver(SCStream)
CG  系（好）：ToDesk(CGDisplayStream)、系统屏幕共享、本工具的截图
```

### 问题二：「无法连接至服务器 1001」+ 本机不上线

**根因：组件签名不满足 UU 的内部校验。** UU 二进制里的校验代码：

```
verifyWithRequirementString(secCode:)
certificate leaf[subject.OU] =              ← 用证书 OU 字段当 TeamID 校验
Client satisfies teamID requirement for:
Hardened runtime is not set for the sender  ← 还检查 hardened runtime
NSXPC client does not match any allowed teamID:
```

所以打补丁后重签时，组件必须同时满足：
1. 有证书，且 `OU = PU9BNSBJW7`（网易官方 TeamID）
2. 启用 hardened runtime（`flags=0x10000(runtime)`）

而 adhoc 签名（`codesign -s -`）**两条都不满足** → 组件间 XPC 被拒
（日志：`Peer connection was rejected by the listener (xpc_connection_cancel())`）→
被控服务注册不上 → 设备不上线、别的电脑看不到它。

**修法**：用一张 `OU=PU9BNSBJW7` 的自签证书 + `--options runtime` 重签全部组件。
UU 的校验串里**不含 `anchor apple generic`**（全组件 grep 计数 = 0），
所以自签证书能满足，不需要 Apple 签发。已实测（含反向对照）：

```
✔ certificate leaf[subject.OU] = "PU9BNSBJW7"                   通过
✔ identifier "com.netease.uuremote" and ...OU = "PU9BNSBJW7"    通过
✘ ...OU = "WRONGTEAM9"                                          失败（对照有效）
```

## 版本自适应（为什么 UU 更新后不用重新分析）

补丁点的**文件偏移随版本变化**，而代码逻辑不变：

| UU 版本 | 工厂函数 VA | 文件偏移 | 映射差 |
|---|---|---|---|
| 4.35.0 | 0x168d31 | **0x16cd31** | +0x4000 |
| 4.40.0 | 0x17c241 | **0x180241** | −0x4000 |

`patch_tool.py` 不靠硬编码偏移，而是：
1. 找字节模式 `48 89 df 85 c0 [74|eb] 07 e8`（mov/test/je/call）
2. 解析两个 `call` 的 rel32，**反查是否命中 `ScreenCapturerSck::Create` 与
   `ScreenCapturerCG::Create` 的符号地址**（用 `nm` 符号表）
3. 两者命中同一映射差 → 才是真补丁点
4. 音频补丁点用「`movl $1,%edi; movl $13,%esi; …; call <可用性检查>`」结构特征定位，
   紧跟着的 `test %eax,%eax` + 分支就是守卫

`check` 第 1 行 = 视频状态，第 2 行 = 音频状态，返回 `patched` / `orig` / `unknown`，
`unknown` 会明确报警而不是瞎打。

```bash
python3 ~/.hermes/uuremote-cg-patch/patch_tool.py check  <库>       # 两行：video / audio
python3 ~/.hermes/uuremote-cg-patch/patch_tool.py locate <库>       # 打印 视频偏移 + 映射差
python3 ~/.hermes/uuremote-cg-patch/patch_tool.py patch   <源> <目标>   # 打两处补丁
python3 ~/.hermes/uuremote-cg-patch/patch_tool.py unpatch <源> <目标>   # 无损还原官方库
python3 ~/.hermes/uuremote-cg-patch/patch_tool.py audiosites <库>       # 列出音频守卫位置
```

## 装完必做：重新授权

签名一变，TCC 授权就对不上了（日志刷 `Failed to match existing code requirement`）。
**系统设置 → 隐私与安全性**：

- **辅助功能** → UU远程，取消勾选再重新勾上
- **录屏与系统录音** → 同上
- 列表里没有 → 点 `+` 添加 `/Applications/UURemote.app`
- 仍不弹窗：

```bash
tccutil reset ScreenCapture com.netease.uuremote
tccutil reset Accessibility com.netease.uuremote
# 然后完全退出 UU 再打开
```

## 怎么确认修好了

```bash
# 1) 状态与签名自检
bash ~/.hermes/uuremote-cg-patch/uu.sh status

# 2) 采集器是否走 CG（应无 -3802、无 SCStream 报错）
bash ~/.hermes/uuremote-cg-patch/uu.sh verify

# 3) XPC 是否还被拒（应无输出）
log show --last 2m --predicate 'process == "UURemoteDaemon"' --style compact \
  | grep -a 'rejected by the listener'
```

## 注意事项（踩过的坑）

1. **`errSecInternalComponent` = 用 root 读不到你的登录钥匙串** —— 最缠人的坑。
   以 root 跑 `codesign` 访问不了用户级钥匙串，于是**每个组件都签名失败**。
   解法：**独立临时钥匙串**（`/tmp/uurt-signing.keychain-db`，已知密码）+ 以你的身份签名。
2. **只传 `--keychain` 还不够** —— 临时钥匙串**必须加入用户钥匙串搜索列表**，
   否则 codesign 报 `item could not be found` 后**静默回退到登录钥匙串**，造成假绿。
3. **不要用 `launchctl bootout` 动守护进程** —— 它是 `RunAtLoad` 的 LaunchDaemon，
   bootout 后**只会消失、不会自己回来**；`kickstart` 对已卸载的服务还会失败。
   症状：agent 每 5 秒报 `No such process`，设备不上线。
   正确：已加载用 `kickstart -k`；未加载用
   `launchctl bootstrap system /Library/LaunchDaemons/com.netease.uuremote.daemon.plist`。
4. **`open -a UURemote` 不会重启已在运行的 UU**（只是激活窗口）——
   签名期间 launchd 拉起的进程会带着「签名中途」的旧代码一直活着。
   必须先 `pkill` 全部组件再启动，并**核对每个进程的启动时间晚于签名完成时间**。
5. **重签后必须重新授权**（签名变了，macOS 记录的代码要求会失配）。用 `status` 自动检查：
   - 录屏：可能记的是我方证书 → 通常仍匹配
   - 辅助功能：通常记的是官方要求（`anchor apple generic`）→ **必然失配**
   修复：`tccutil reset Accessibility com.netease.uuremote` 后在系统设置里重新勾选。
6. **预检文件必须以你的身份创建** —— root 建的属 root，随后以你身份 codesign 会报
   `Permission denied`（假失败，别被误导）。
7. **枚举结果必须带尾部换行符** —— `python3` 用 `'\n'.join()` **不输出结尾换行**，
   `while read` 会**静默丢掉最后一行** → 漏签一个组件 → 其父 bundle 的哈希过期 →
   `nested code is modified or invalid`。脚本已补换行 + 用 `read || [ -n "$x" ]` 兜底。
8. **不能用 `mapfile`** —— macOS 自带 bash 3.2 没有这个内建命令。
9. **VA 与文件偏移差 0x4000**（4.40.0 为 −0x4000）—— 别直接拿 otool 里的地址当文件偏移打。
10. **`$VAR` 后紧跟中文字符必须写 `${VAR}`** —— bash 会把中文首字节并入变量名，
   报 `VAR<乱码>: unbound variable`。写含中文提示的脚本时务必注意。
11. **必须带 `--options runtime`**，且**必须保留每个组件的原 identifier**（脚本自动读取照抄）。
12. **签名顺序**：Mach-O 文件（深的先）→ 内层 bundle（.xpc / 嵌套 .app）→ 最外层 App。
13. **UU 自动更新会覆盖补丁** —— 重跑 `install` 即可（会自动重建基线、重定位补丁点）。
14. **备份别删** —— `libstreamer.dylib.orig` 是还原依赖；版本不匹配时 `restore` 会拒绝执行以免搞坏。
15. **想彻底回官方状态** —— 去 https://uuyc.163.com/ 下载安装包覆盖安装。

## 为什么不能「一处配置全局生效」（必须分 3 处打补丁）

**先给结论**：没有任何配置项/环境变量/plist 开关能一次搞定（已实测排查：`force_software_encoder`
字符串只存在于 `libstreamer.dylib` 里 1 次，没有任何本地配置文件读取它，`defaults` 里也没有
采集/编码相关键）。而且这 3 处**不是同一个开关的三份拷贝**，是**两种不同机制**：

| # | 位置 | 机制 | 能否合并 |
|---|---|---|---|
| 1 | 视频 `CreateScreenCapturer()` | 版本判定 `(1, 14, 0, 0)` 选 SCK / CG | 与 #2 **同机制** |
| 2 | 音频 `SckAudioCapture` 构造/析构/Start | 版本判定 `(1, 13, 0, 0)` 选 SCK / 旧行为 | 与 #1 **同机制** |
| 3 | 编码器 `ResetVTCompressionSession()` | **没有版本判定**，写死 `kCFBooleanTrue` | 与 #1/#2 **不同机制，无法合并** |

**#1、#2 确实共用同一个判定助手**（VA `0x944770`，经 `__availability_version_check` stub 调用）。
理论上「把该助手改成永远返回 false」就能一处搞定这两条 —— **但不能这么干**，因为：

```
该助手在 libstreamer 里被调用 18 次，版本阈值各不相同：
  macOS 10 ×2（OpenSSL padlock）
  macOS 11 ×6（编码器路径）
  macOS 12 ×3（显示器信息 / 显卡信息 / 屏幕配置）
  macOS 13 ×3（音频 SCK）      ← 我们要改的
  macOS 14 ×2（视频 SCK）      ← 我们要改的
  macOS 15 ×1（编码器路径）
```

一律改成 false 等于让整个库以为跑在远古 macOS 上，**编码器和 OpenSSL 的判定会被连带打乱**，
故障模式不可预测。所以选择**按点精确改**：只翻转我们要的那 5 个字节，其余一律不碰。

**另一个「一处生效」的思路也已排除**：用 `DYLD_INSERT_LIBRARIES` interpose
`__availability_version_check`（一处覆盖所有版本判定）。代价是要给 App 加
`com.apple.security.cs.disable-library-validation` 权限（削弱签名强制），
且**仍然治不了 #3 编码器**（它不是版本判定）。所以最少也得是「版本判定 + 编码器」两处，
按点补丁（3 处）反而是更保守、可无损还原的方案。

## 演练模式（改脚本后必做）

不碰正式 App、不需要 sudo，用**真实脚本**在副本上跑完整流程：

```bash
# A) 只演练「打补丁 → 重签」全链路（推荐）
rm -rf /tmp/dry && mkdir -p /tmp/dry
ditto /Applications/UURemote.app /tmp/dry/UURemote.app
UURT_APP=/tmp/dry/UURemote.app UURT_REHEARSE=1 \
  bash ~/.hermes/uuremote-cg-patch/uu.sh cg-install

# B) 只演练签名环节
UURT_APP=/tmp/dry/UURemote.app UURT_REHEARSE=1 \
  bash ~/.hermes/uuremote-cg-patch/uu.sh sign

# C) 只演练 shim（帧源替换）
UURT_APP=/tmp/dry/UURemote.app UURT_REHEARSE=1 \
  bash ~/.hermes/uuremote-cg-patch/uu.sh shim-install
```

演练会跳过退出/启动 UU、改属主、写基线，其余（临时钥匙串、预检、逐组件签名、
整包校验、OU 校验、反向对照、补丁完整性）全部实跑；跑完会核对「基线未被改动」。
**改动 `patch_tool.py` 后务必先跑 A** —— 曾经因为重写工具时删掉了 `locate` 子命令，
主脚本取不到补丁点，install 直接失败（工具与脚本的子命令接口要一起改）。


## 文件说明

### 目录结构

```
uuremote-cg-patch/
├─ uu.sh                   ← ★ 唯一入口（19 个子命令：install/restore/status/verify/
│                            cg-install/cg-restore/shim-install/shim-restore/sign/
│                            daemon/reset/watchdog/watchdog-loop/watchdog-stop/
│                            monitor/traffic/encoder/setmode/cleanup/help）
├─ patch_tool.py           ← 版本自适应定位/打补丁/反推官方库（uu.sh 调用）
├─ cert/                   ← 自签证书
├─ extra-ents/             ← 额外权限声明
├─ cpupath/                ← 第 4 道门修复（CPU 顶替 Metal 帧转换）
├─ shim/                   ← 帧源替换 shim（源码 + 现役/上一版 dylib + 原库备份）
│   ├─ libuushim.c            源码（唯一真源）
│   ├─ libuushim.dylib        现役待装源（= 最新版 v14）
│   └─ backup/UURemoteServer.orig  UURemoteServer 原库（装机/还原的活依赖，别删）
├─ tools/                  ← 辅助工具（setmode 分辨率切换 / 监控 / 探针 / 整理）
├─ evidence/               ← 根因分析与实测结论（.md）
├─ archive/<日期>/         ← 归档的历史产物（含整合前的旧脚本，可随时取回）
├─ libstreamer.dylib.orig  ← 官方原库备份（还原靠它，别删）
└─ libstreamer.dylib.patched
```

**从旧脚本回退**：整合前的 9 个脚本完整保留在 `archive/pre-merge-20260926/`。
要回退：`cp archive/pre-merge-20260926/*.sh .`（放回顶层即可用；它们靠自身路径定位资源）。
其中 `uu-cg-patch.sh` 还支持 `UURT_DIR=<项目目录>` 直接在归档目录里跑。

**版本管理**：`shim/` 只保留现役版 + 上一版（作回退），更老的版本在 `archive/`。
`libuushim.c` 是唯一真源，任何 dylib 都可由它重新编译。

**整理工具**：`bash uu.sh cleanup`（演练）/ `bash uu.sh cleanup --apply`（执行）。
只删「垃圾 + 可再生成的构建产物」，其余 mv 到 `archive/`；
移动前会 grep 全仓引用，被 `.sh`/`.py` 引用的文件一律保留。

### 关键文件

| 文件 | 说明 |
|---|---|
| `uu.sh` | **唯一入口**：19 个子命令（`help` 看全部）。原 9 个脚本的逻辑逐字并入，未重写 |
| `patch_tool.py` | **版本自适应定位/打补丁/反推官方库** |
| `cert/` | 自签证书（`cert.pem` / `key.pem` / `id.p12` / `openssl.cnf`） |
| `libstreamer.dylib.orig` | **官方原库备份**（还原靠它，别删！） |
| `libstreamer.dylib.patched` | 补丁版（可从 orig 随时再生） |
| `shim/backup/UURemoteServer.orig` | **被控端原库**（shim 装机/还原的活依赖，别删！） |
| `UURemote.entitlements` | UU 的权限声明（签名时保留） |
| `tools/setmode` | 分辨率切换（提帧率最有效的一刀，可逆） |

### 看门狗（无人值守时的自愈）

```bash
bash uu.sh watchdog --dry          # 诊断但不动作（安全）
bash uu.sh watchdog-loop           # 启动常驻循环（自带单实例守卫）
bash uu.sh watchdog-stop           # 停止常驻循环
tail -f /tmp/uushim-watchdog.log   # 看它做过什么
```

- **触发**：已 >60s 无出帧 **且** 出现 `流数超上限` / `分配失败≥3` / 多实例；或 RSS >3GB。
- **铁律**：还在出帧就绝不动它（重启会踢掉正在用的用户）。
- **恢复动作**：杀 server+service → kickstart agent → 确保 GUI 在 → 等 server 回来
  → **回读登录态/网络态**才算完成（进程在 ≠ 已注册上线）。
- 冷却 180 秒；`~/Library/LaunchAgents/com.uuremote-cg-patch.watchdog.plist` 负责重启后自动加载。
- **RSS 不能单看**：会话中本进程 RSS 可达 1~1.8GB 且会自然波动回落（缓冲池保留，非泄漏），
  阈值定低会误杀正在串流的会话。
