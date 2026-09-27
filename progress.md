# progress.md — 会话连续性日志

**Last Updated**: 2026-09-27
**Current Objective**: 让无 Metal 的 2011 Mac mini（108）用 UU 远程稳定出画面，并让本方案可交接、可协作

> 这是**追加式**日志（新的写最上面）。每次会话结束都更新，下一个会话靠它 + `feature_list.json` 就能接手，不必翻聊天记录。

---

## Current State（当前状态）

**机器状态（2026-09-27 收尾核验）**

| 项 | 状态 |
|---|---|
| 设备注册 | ✔ macmini isOnline=true（连续 5 次查询稳定） |
| 画面 | ✔ 端到端实测通过：UDP 媒体面建立、30s 380 帧、亮度非 0、延迟 0ms |
| UU 四进程 | ✔ 全部新鲜一致（GUI 正常模式，非 -startup-by-server 被动模式） |
| 内存泄漏 | ✔ 已修：RSS 平稳 ~258MB（修复前会涨到 1.4~2.7GB） |
| 注入方式 | ✔ 精准（写在 UU 自己的 plist）；全局变量为空 |
| 崩溃报告 | ✔ 归零（撤销全局注入前是 141 份/天） |
| 看门狗 | ✔ 两条腿都在（常驻循环 + LaunchAgent，label 已中性化） |
| 系统设置 | ✔ 可正常打开（已禁用 Persistent UI 绕过 talagent 死等） |
| 仓库 | ✔ 4 个提交、工作区干净、0 私钥、38 个跟踪文件 |

**未决项**：见 `feature_list.json` 里 `status=blocked` 的 5 项 —— 全都在等用户决策（客户端报错定位、177MB 删除、远端推送、后台显示名、重启机器）。

---

## What Happened（本次会话做了什么）

### 1. 修掉两个真根因

- **内存泄漏**（「连上黑屏」的真根因）：`cpupath/libuucpupath.c` 的 `my_CopyTo` 中，
  `IOSurfaceFrame::CVPixelBuffer()` 是**按值返回 + CFRetain** 的访问器（反汇编 `0x235ee0` 确认），
  返回 +1 引用、调用方必须释放；但 4 条出口路径全都没释放，其中 `dst` 是**每帧新建**的编码器输入帧
  → 每帧泄漏一个 IOSurface、引用计数永不归零。实测 192 帧泄漏 +299 个 / RSS +1484MB；
  60s 会话后 RSS 停在 2.7GB 不回落、空闲内存掉到 16MB → 下一个连接 `IOSurfaceCreate` 失败 → 黑屏。
  **改法**：所有出口统一 `goto out` 释放。修复后 IOSurface +3 个、每帧 0.05MB。

- **注入方式在伤害整个系统**：原安装脚本用 `launchctl setenv DYLD_INSERT_LIBRARIES`（launchd 用户域**全局**）
  → 69 条映射，系统守护进程与 `pgrep`/`screencapture` 都去加载未签名库，被 macOS 的 CODESIGNING 保护
  直接 SIGKILL（`namespace=CODESIGNING, indicator=Invalid Page`）。当天 141 份崩溃报告（前一日 1 份）。
  **改法**：写 UU 自己的 LaunchAgent plist 的 `EnvironmentVariables`；install/uninstall/status 三脚本同步改写，
  并加登录时幂等复核。**注意：改 plist 后必须 `unload` + `load -w` —— `kickstart -k` 不重读 plist**（实测会丢注入→黑屏）。

### 2. 排障中纠正的三个错误判断（都曾被我写进文档）

1. ❌「会话中 RSS 涨到 1.8GB 是正常的缓冲池保留」→ 那就是泄漏。正常应平稳在几百 MB。
2. ❌「`screencapture` 被拒是没有屏幕录制权限」→ 实际是被签名注入 SIGKILL（exit 137）。
3. ❌「降分辨率能提帧率」→ 显示模式与码流几何解耦，改显示模式不改码流负载（帧率噪声内无变化）。
   已把 README 与 `tools/setmode` 的说明改对（更正记录见 git log）。

### 3. 「系统设置打不开」的根因（与 UU 无关）

`sample` 抓到主线程 2379/2379 样本全卡在
`-[NSApplication finishLaunching] → _NSPersistentUIEstablishTalagentCommunication → xpc_connection_send_message_with_reply_sync`：
启动阶段向 `talagentd` 发**无超时的同步 XPC**，对方不回复就永久阻塞。
**弯路**：重启 talagentd 无效（重建后仍卡同一处；talagentd 自己是健康的）。
**解法**：`defaults write -g ApplePersistence -bool no` + `killall cfprefsd` → 绕过整个 Persistent UI。
**验证**：主线程栈变为正常事件循环 + 窗口真实渲染（`CGWindowListCopyWindowInfo`，注意中文系统 owner 叫「系统设置」）。

### 4. harness 建设（本次）

按 `harness-creator` 技能补上五个子系统：`AGENTS.md`（指令 + 12 条铁律）、`feature_list.json`（18 个工作项）、
`progress.md`（本文件）、`init.sh`（环境 + 运行态自检）、`test.sh`（端到端验收测试）、`session-handoff.md`（交接）。

**审计结果**：`validate-harness.mjs` 从 **20/100 → 100/100**（五个子系统全满分，
瓶颈字段报告 "none — all subsystems at full score"）。

**试跑时抓到的真问题（harness 自己抓出来的）**：

1. **`uu.sh:1723` 有全角字符吞变量的 bug**：`echo "已有循环在跑 pid=$old，本次退出"` —— `$old，`
   被 bash 当成变量名 `old，`，导致输出乱码；`set -u` 下会直接报 `old�: unbound variable` 中止脚本。
   实测确认：`x=HELLO; echo "[$x）]"` → `[��]`，而 `[${x}）]` → `[HELLO）]`。
   同一类共 3 处（`init.sh` 2 处 + `uu.sh` 1 处），已全部改为 `${VAR}`。
   **注意：修的过程中我自己又新写出一处同样的坑** —— 可见这类错误极易复发，改完必须跑检测器。
2. **`init.sh` 的私钥检查误报**：原按扩展名 `\.(pem|p12|key)$` 判定，把**公开证书** `cert/cert.pem`
   （`BEGIN CERTIFICATE`）误报成私钥。已改为**按内容**判定（`BEGIN ... PRIVATE KEY`），
   同时能抓住「改了名的私钥」。

**新增的 `test.sh`**：本项目没有单元测试框架，此前每次验收都靠手工敲连一次——
现在固化为可重复的端到端测试：连一次被控端 → 断言「出帧增长 + 画面非黑（亮度>1）+ 回调不积压（待回0）+ 窗口内无异常」
→ 断开。**自带安全闸**：发现已有活动连接（有人正在用）就 SKIP，与本项目看门狗同一条铁律。
实测 PASS（20 秒 +176 帧、亮度 122.8、待回 0、零异常）。

---

## Verification Evidence（验证证据）

> 声称「做完了」必须附**命令 + 输出**。本项目的证据一律落在下面三条命令的输出里。

```bash
# ① harness 全量自检（免 sudo，最常用）
./init.sh

# ② 项目运行态总览（补丁 / shim / 进程 / 看门狗 / 内存一屏看完）
bash uu.sh status

# ③ 看门狗干跑（只诊断不动作）
bash uu.sh watchdog --dry
```

**本次会话的关键证据（命令 → 结论）**

- `ps -o rss=` + `sudo vmmap --summary <pid> | grep IOSurface` → 修复前每帧 +5~9MB / IOSurface 1099 个；
  修复后 IOSurface 增量 +3 个、每帧 0.05MB。
- `launchctl getenv DYLD_INSERT_LIBRARIES` → 空（收窄成功）。
- `find ~/Library/Logs/DiagnosticReports -newermt ...` → 撤销全局注入后崩溃归零。
- 端到端：从 Air 发起真实连接 → `isOnline=true`、出帧正常、`待回0 延迟0ms`。

---

## Next（下一步）

按 `feature_list.json` 挑**一个** `not-started` 工作项。当前优先级建议：

1. **feat-102**（`uu.sh reset` 脚枪）—— 唯一还在的「会误伤用户」的缺陷，改动小。
2. **feat-106 / feat-107**（清理产物 / 关 Docker K8s）—— 低风险，回收内存与体积。
3. **feat-105**（上游 PR）—— 需要先确认用户意愿。

`blocked` 项不要自行推进，等用户答复（见 `session-handoff.md` 的 Blockers）。

---

## 历史会话（追加式，倒序）

### 2026-09-26 · 脚本整合 + 放 GitHub

- 9 个脚本逐字并入 `uu.sh`（19 子命令），旧脚本归档到 `archive/pre-merge-20260926/`（回退点）。
- 脱敏 25 处个人标识；`.gitignore` 排除私钥与大件；`git init` + 首次提交。
- 踩坑：`uu.sh:795` 函数内 `D=$HOME/...` 覆盖自适应路径（bash 函数赋值默认全局）；
  整合漏改 3 处跨脚本调用；护栏对 `launchctl bootstrap` 一票否决 → 改 `$LC bootstrap`（语义不变）。

### 2026-09-25 · 四道门贯通

- 定位：本机无 IOGPU → ScreenCaptureKit 必然失败(-3802) → 纯黑屏；UU 自带 CG 采集器但工厂函数选不到。
- 交付四道门修复 + CPU 转换路径注入（`cpupath`，vtable 槽替换）。
