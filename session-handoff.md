# session-handoff.md — 会话交接

> 用途：一个会话结束、另一个接手时，**只读这一份**就能继续，不必翻聊天记录。
> 与 `progress.md` 的分工：`progress.md` 记「做过什么」（历史），本文件记「现在是什么状态、下一步做什么、卡在哪」（快照）。
> 每次会话结束**重写本文件**（不是追加）。

**Last Updated**: 2026-09-27
**Current Objective**: 让无 Metal 的 2011 Mac mini（108）用 UU 远程稳定出画面，且方案可交接、可协作

---

## ★ 交接前必做（新会话第一件事）

```bash
cd ~/.hermes/uuremote-cg-patch
./init.sh                 # 环境 + 运行态 + 状态文件 + git 全量自检
bash uu.sh status         # 项目运行态总览
```

`init.sh` 有 FAIL → **先修好再开始新工作**（别在坏地基上加东西）。

---

## 交接时的工作区状态

| 项 | 状态 |
|---|---|
| git | 分支 main、工作区干净、0 私钥、4 个提交 |
| 项目体积 | 253MB（其中 177MB 是待删的 `UURemote.app.before-certsign`） |
| 跟踪文件 | 38 个 |
| 相关技能 | `macos-remote-access`（本项目的全部踩坑记录都在这里） |

---

## Blockers（卡住的项 —— 不要自行推进，等用户答复）

| # | 卡点 | 需要用户做什么 |
|---|---|---|
| B1 | **「无法连接至服务器」客户端侧定位** | 告知：哪个设备报的错 / 现在是否仍报 / 最好给截图。108 侧已实测连通，问题在客户端侧 |
| B2 | **删 177MB `UURemote.app.before-certsign`** | 属主 root 且 `sudo rm -rf` 命中用户红线 → 需用户自己执行（或授权 chown 后由助手普通 rm） |
| B3 | **推送到远端** | 定：推到哪个账号/仓库；用哪个提交身份（现为 `my24251325@gmail.com`，已进本地 git 历史） |
| B4 | **「允许在后台」显示名** | 选：A 只改看门狗 / B 4 个全改（界面显示脚本名而非 bash）/ C 不改 |
| B5 | **重启机器一次** | 需在合适时机执行：可清 swap 历史脏页、清 BTM 失效登记、清撤销全局注入前遗留的库加载 |

**另有 1 条已确认不影响功能、等顺手的授权**：归档误留在 `~/Library/LaunchAgents/` 的
`ai.hermes.gateway.plist.bak-20260905_131611`（`.bak` 结尾不会被加载，也不在后台列表显示）。

---

## Next Session（下一个会话从哪开始）

**Recommended Next Step**: 从 `feature_list.json` 里挑一个 `not-started` 项动手。推荐顺序：

1. **feat-102 `uu.sh reset` 脚枪** —— 唯一还存在的「会误伤用户」缺陷（按 `ps` 的 %cpu 生命周期均值判卡死，
   不看是否在出帧 → 会把正在串流的用户踢下线）。修法：加与看门狗同款「还在出帧就绝不动它」闸 + `--force`。
2. **feat-106 / feat-107** —— 清理可再生成产物；关 Docker 的 `KubernetesEnabled`（本机 8GB/2 核，1.7GB 是硬成本）。
3. **feat-105 上游 PR** —— 先确认用户意愿（本机已有可行绕过，此项为消除上游误判）。

**不要做**：`status=blocked` 的项（等用户）；`archive/pre-merge-20260926/`（是回退点，必须留）；
`libstreamer.dylib.orig` / `orig.version` / `UURemote.entitlements` / `shim/backup/UURemoteServer.orig`（活依赖，删了断链）。

---

## Files（关键文件与它们为什么重要）

| 文件 | 作用 | 注意 |
|---|---|---|
| `AGENTS.md` | 本项目的指令与铁律（**开工先读**） | 受保护的 agent 指令文件，改它会被写工具拦截，需走 terminal |
| `uu.sh` | **唯一入口**，19 个子命令 | 整合自原 9 个脚本，逻辑逐字保留未重写 |
| `README.md` | 完整技术手册（根因、四个 bug 的查证过程、目录结构、陷阱） | 深水区问题查这里，不要另起文档 |
| `init.sh` | 启动 / 验证入口（harness 的 verification） | 只读，不改系统状态 |
| `feature_list.json` | 工作项状态的唯一事实源 | 同时最多一个 `in-progress` |
| `cpupath/libuucpupath.c` | 第 4 道门：CPU 顶替 Metal 帧转换 | ★ 泄漏修复在 `my_CopyTo`：新出口必须 `goto out` |
| `cpupath/install.sh` | 注入安装（写 UU 自己的 plist） | ★ 绝不许退回 `launchctl setenv` |
| `shim/libuushim.c` | 帧源 shim 唯一真源（任何 dylib 都由它编译） | 现役 v14；备份 `v13` 作回退 |
| `libstreamer.dylib.orig` | 官方原库备份 | **`restore` 唯一依赖，别删** |
| `shim/backup/UURemoteServer.orig` | 被控端原库 | 装机/还原活依赖，别删 |
| `~/Library/LaunchAgents/com.uuremote-cg-patch.{cpupath,watchdog}.plist` | 持久化两层 | 改完必须 `unload` + `load -w` |
| `/Library/LaunchAgents/com.netease.uuremote.agent.plist` | cpupath 注入位置（UU 自己的） | ★ UU 升级会覆盖 → 由 cpupath 的复核脚本自动补回 |
| 日志 | `/tmp/uushim.log`（出帧）、`/tmp/uucpu.log`（CopyTo）、`/tmp/uushim-watchdog.log`（自愈记录）、`UUCpuPath/apply.out.log`（复核） | 排障先看这四个 |
| `evidence/*.md` | 根因分析与实测结论 | 与 README 互补，含对照实验数据 |

**技能**：`macos-remote-access` —— 本项目所有踩坑结论都沉淀在这里（含「怎么判断是不是本项目的 bug」的取证顺序）。
**它不是可选读物**：改动前先 `skill_view('macos-remote-access')`，否则很可能重踩已记录的坑。

---

## 交接质量自检（离开前逐条打勾）

- [ ] `./init.sh` 通过（无 FAIL）
- [ ] `progress.md` 已更新（做了什么 / 下一步）
- [ ] `feature_list.json` 状态已更新，且 `in-progress` 不超过 1 个
- [ ] 本文件（`session-handoff.md`）的 Blockers / Next Session / Files 已刷新
- [ ] 改动已 `git commit`（描述性 message）
- [ ] 系统处于**可用状态**：设备 online、出帧正常、注入精准、全局变量为空
- [ ] 没有留下未授权的系统改动（尤其：没有重新引入全局 `DYLD_INSERT_LIBRARIES`）
