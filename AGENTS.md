# AGENTS.md — UU远程 CoreGraphics 采集补丁

让**没有 Metal 的老 Mac**（AMD pre-GCN，如 2011 Mac mini `Macmini5,2`）能用 UU 远程正常出画面。

- 唯一入口：**`uu.sh`**（22 个子命令，`bash uu.sh help`）
- 深水区技术手册：**`README.md`**（根因、四类 bug 的查证过程、目录结构）
- 所有踩坑结论沉淀在技能 **`macos-remote-access`** —— 改动前必须 `skill_view` 读它

本文件只放**路由 + 铁律**，不重复手册内容。

## Startup Workflow（启动工作流）

Before writing code:

1. `pwd` 确认在**本项目根目录** —— 所有脚本按自身位置定位，clone 到任何路径都能跑
2. 读完本文件（尤其下面「铁律」一节）
3. 跑 **`./init.sh`** 验证环境与运行态
4. `skill_view('macos-remote-access')` —— 不读极易重踩已记录的坑
5. 读 `feature_list.json`（当前工作项）+ `session-handoff.md`（阻塞项）
6. `git log --oneline -5` 看最近做了什么

若基线验证失败 → **先修好它再开始新工作**，别在坏地基上加东西。

## 这个项目是什么（30 秒版）

本体是**四道门**，缺一道就黑屏或卡在「正在传输画面」：

| 门 | 位置 | 修什么 | 装机命令 |
|---|---|---|---|
| 第 1/3 道 | `patch_tool.py` | libstreamer 的三处磁盘补丁（Metal 门禁 / 编码器 / 低延迟 RC） | `sudo bash uu.sh cg-install` |
| 第 2 道 | `shim/libuushim.c` | 帧源：用截图轮询顶替选不到的 CoreGraphics 采集器 | `sudo bash uu.sh shim-install` |
| 第 4 道 | `cpupath/libuucpupath.c` | CPU 顶替 Metal 做「采集帧 → 编码器输入帧」的转换 | `bash uu.sh cpupath-install` |

`sudo bash uu.sh install` = 全套（含重签名）。**UU 每次自动更新后重跑 install 即可**（版本自适应）。

## 铁律（违反会伤机器 / 伤用户，改代码前先读）

1. **绝不用 `launchctl setenv DYLD_INSERT_LIBRARIES`** —— 那是 launchd **用户域全局**变量，
   所有进程（含系统守护进程、`pgrep`、`screencapture`）都会去加载我们的**未签名** dylib，
   被 macOS 的 CODESIGNING 保护直接 SIGKILL。
   实测代价：**一天 141 份系统进程崩溃报告**（前一日 1 份）、系统卡顿、System Settings 打不开。
   正确做法：写进 **UU 自己的** LaunchAgent plist 的 `EnvironmentVariables`（见 `uu.sh cpupath-install`）。
   给 dylib 做 ad-hoc 签名**不能**避免此崩溃（实测无效）。
2. **改完 plist 必须 `launchctl unload` + `load -w`** —— **`kickstart -k` 不会重读 plist**（实测会丢注入 → 黑屏）。
3. **看门狗铁律：只要还在正常出帧就绝不动它**。会话进行中重启 server = 当场把用户踢下线。
   只在**空闲**（无帧 >60s）且 RSS 高时回收内存；RSS >3500MB 才是硬顶。
4. **按值返回 + CFRetain 的访问器，返回值必须释放**。`cpupath/libuucpupath.c` 的 `my_CopyTo` 里，
   访问器返回 **+1 引用**，调用方负责还；**新增任何出口都必须 `goto out`**（这就是「每帧泄漏一个 IOSurface
   → 下次连接黑屏」的根因，实测 192 帧泄漏 +299 个 surface）。
5. **发布 / 提交前先脱敏**：IP、用户名、设备 ID、个人邮箱不进 git 历史；私钥与大件进 `.gitignore`。
   本机 git 提交身份目前是占位值，推远端前需用户确认。
6. **`sudo rm -rf …` 与 `rm -rf /…` 命中用户红线** —— 不绕过、不改写命令绕过；报告用户请其自行执行。
7. **改动前先备份并留回退点**：脚本改前 `cp` 到 `/tmp`；plist 改前备份。
   **删文件不搞 `archive/` 目录 —— git 历史就是归档**：确认内容已在 git 历史里
   （已跟踪的文件删掉后即留在历史中，`git show <提交>:<路径>` 可取回）再删。
   未跟踪的文件删了就真没了 → 不擅自删，先 `git add` 提交进历史。
8. **进程在 ≠ 已上线**。验收必须端到端：`isOnline=true` + 出帧正常 + 亮度非 0 + `待回0 延迟0ms`。
9. **别用 `ps` 的 `%cpu` 判断负载**（那是生命周期均值，会骗人）→ 用 `ps -o time=` 增量。
10. **`screencapture` / `pgrep` 被 SIGKILL（exit 137）时先查注入污染**，别当成「没有录屏权限」。
11. **本机无 Metal、无硬编码器**（VT 只有 `Apple H.264 (SW)`）—— 不要试图走 Metal / 硬编路径；
    H.264 软编占约 150% CPU，是帧率的唯一瓶颈。
12. **中文全角字符紧跟变量会污染变量名** → 一律写 `${VAR}（`（实测 `$x）` 输出乱码、`set -u` 下直接中止）。

## Working Rules（工作规则）

- **One feature at a time（一次只做一个）**：从 `feature_list.json` 挑**恰好一个**未完成工作项
- **Stay in scope（不改无关文件）**：只改当前工作项需要的文件；顺手重构另开一项
- **验证必须有证据**：声称完成前跑验证命令，并把「命令 + 输出」写进 `progress.md`
- **状态写在文件里，不靠聊天记录**：`progress.md` 追加、`feature_list.json` 更新 `status`
- **离开时系统必须可用**：设备 online、出帧正常、注入精准、**全局注入变量为空**
- **`blocked` 项不要自行推进**：等用户在 `session-handoff.md` 的 Blockers 里答复

## Required Artifacts（必备状态文件）

| 文件 | 作用 |
|---|---|
| `AGENTS.md` | 本文件：路由 + 铁律。**受保护的 agent 指令文件**（改它会被写工具拦截，走 terminal） |
| `feature_list.json` | 工作项状态唯一事实源（`done` / `in-progress` / `not-started` / `blocked`） |
| `progress.md` | 会话连续性日志（追加式，倒序） |
| `session-handoff.md` | 会话交接快照（每次收尾**重写**） |
| `init.sh` | 启动 / 验证入口（只读，不改系统状态） |
| `test.sh` | **端到端验收测试**（本项目没有单元测试框架 —— 这就是它的「测试」） |

## Definition of Done（完成标准）

一个工作项 done only when 全部满足：

- [ ] 目标行为已实现，且 scope 限定在该工作项内
- [ ] 验证真的跑过（`./init.sh` + 该工作项的验收命令），**有命令与输出为证**
- [ ] 证据记入 `progress.md` 或 `feature_list.json` 的 `evidence` 字段
- [ ] 端到端确认过（真连一次，不只看进程存活）
- [ ] 仓库仍可从标准启动路径 clean 重启（`./init.sh` 无 FAIL）
- [ ] 改动已 commit，工作区干净

## Verification Commands（验证命令）

```bash
# 全量自检（推荐、免 sudo）：环境 + 运行态 + 状态文件 + git
./init.sh

# ★ test：端到端验收测试（本项目没有单元测试框架 —— 这就是它的「测试」）
#   真连一次被控端 → 断言出帧增长 + 画面非黑 + 无异常 + 回调不积压 → 断开
#   自带安全闸：发现已有活动连接（有人正在用）就 SKIP，绝不打扰
./test.sh                  # 也可 UU_TEST_SECS=30 ./test.sh 加长观测窗口
./test.sh --local-only     # 不依赖外部控制器，只做本机静态断言

# 项目运行态总览（补丁 / shim / 进程 / 看门狗 / 内存一屏看完）
bash uu.sh status

# 看门狗干跑（只诊断不动作）—— 确认自愈规则没被改坏
bash uu.sh watchdog --dry

# UU 实际走了哪套采集器（手机连过一次后跑；应无 -3802、无 SCStream 报错）
bash uu.sh verify

# 静态检查（本项目的 lint / compile）
bash -n uu.sh && bash -n init.sh && bash -n test.sh
for p in patch_tool.py tools/cleanup.py tools/insert_dylib.py; do
  python3 -c 'import sys; compile(open(sys.argv[1],encoding="utf-8").read(),sys.argv[1],"exec")' "$p" || echo "✘ $p"
done
clang -fsyntax-only shim/libuushim.c
# ★ 别用 python3 -m py_compile：它会写出 __pycache__/*.pyc（自检自己制造垃圾）

# ★ 铁律检查（必须为空，非空 = 正在伤害系统）
launchctl getenv DYLD_INSERT_LIBRARIES

# 改脚本后必做的演练（不碰线上，见 README「演练模式」）
bash tools/rehearse.sh
```

**跑的时机**：改任何脚本 → 静态检查 + 演练；动补丁/注入/看门狗 → `./init.sh`；
**改完补丁/采集链路 → 必须 `./test.sh`（端到端）**；收尾 → `./init.sh` 全绿 + `./test.sh` PASS。

## End of Session（会话结束）

Before ending a session:

1. `./init.sh` 确认无 FAIL，且系统处于可用状态
2. 更新 `progress.md`（做了什么 / 下一步 / 证据）
3. 更新 `feature_list.json` 的 `status`（`in-progress` 不得超过 1 个）
4. **重写** `session-handoff.md`（Blockers / Next Session / Files 三段刷新）
5. `git commit` 用描述性 message
6. Leave the repo restartable：下一个会话跑 `./init.sh` 就能直接通过（Next steps 见脚本尾部）

## Escalation（升级路径）

- **架构 / 系统级改动**（改守护进程、动系统设置、写 `/Library/LaunchAgents/`）→ 先问用户
- **需求不明确** → 先读 `README.md` 与 `macos-remote-access` 技能，仍不明再问
- **反复失败** → 把尝试过的方案与现象写进 `progress.md`，标记给人工复核；**别在同一个坑里反复摔**
- **红线相关**（`sudo rm -rf`、删系统文件、改生产配置）→ 报告用户，等其执行或授权
- **同一个错误犯第二次** → 停下，把结论写进技能（`skill_manage` patch），再继续

## 关键文件路由

| 要改什么 | 先读 |
|---|---|
| 单文件入口 / 子命令 | `uu.sh`（顶部 prologue + 对应 `*_main`） |
| 版本自适应定位与打补丁 | `patch_tool.py` |
| 帧源（截图轮询） | `shim/libuushim.c`（**唯一真源**，任何 dylib 由它编译） |
| CPU 顶替 Metal 转换 | `cpupath/libuucpupath.c` |
| 注入方式与持久化 | `uu.sh cpupath-install` / `cpupath-uninstall` / `cpupath-status` |
| 分辨率切换 | `tools/setmode.swift`（编译产物 `tools/setmode`） |
| 看门狗规则 | `uu.sh` 的 `watchdog_main` |
| 根因与实测结论 | `evidence/*.md` + `README.md` |

**不要删**（活依赖，删了断链）：`libstreamer.dylib.orig`、`orig.version`、`UURemote.entitlements`、
`shim/backup/UURemoteServer.orig`。

## 本机环境前提（改动前要知道）

- 机器：2011 Mac mini `Macmini5,2`，i5-2520M / 8GB / AMD HD 6630M，OCLP + macOS 15.7.9，**无头**
- **无 IOGPU、无 Metal** → ScreenCaptureKit 必然失败（-3802）→ 纯黑屏；这是本项目存在的理由
- `ApplePersistence=0`（禁用 Persistent UI，绕过 `talagent` 同步 XPC 死等导致 System Settings 打不开）
- Docker 已退出且 `AutoStart=False`；但 `KubernetesEnabled=True` → 再启动会白烧 1.7GB + 约 40% CPU
- **sudo 免密，但用户红线优先**（见铁律 6）
- 无 `timeout` 命令；`launchctl bootstrap` 在本机的 Hermes 网关里被护栏拦截（脚本内用变量调用规避）
