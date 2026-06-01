# CLAUDE.md

> 给未来的 Claude：**先读 [SPEC.md](SPEC.md) 再动手。** 本仓库的设计规格是真相源。
> 本项目遵循 `~/.claude/CLAUDE.md` v1.3 的协作规范，并采用 SDD（规范驱动开发）脚手架。

## 第零步：看当前进度

本项目用 **SDD**，真相源是 **`SPEC.md`**（不是 roadmap/milestones/todo 三档——此处**显式 override** 全局 §5 的发现协议，因为项目用 SDD 脚手架 `docs/`）。

接手序列：
1. 读 `SPEC.md` —— 完整规格（功能、UI、技术架构、通讯协议、验收标准）。
2. 读 `requirements.md` —— 需求来源 + 决策日志（D1–D19）+ 非目标 + 待核实项。**特别注意 D19：WA 整包核心路线已暂停，现走纯插件路线**。
3. 读 `docs/M1-status.md` —— M1 进度报告（哪些验收项已完成/无头验证过/待真机）。
4. 看 `git log` / 当前分支了解代码进度。
5. 当前状态：**M1 全部功能代码已完成**，在无头 WoW 模拟环境端到端跑通（零运行时错），主界面真机已可打开。**剩余是只能真机/多人/真机验证的部分**（见 `docs/M1-status.md` §3）。M1 范围见 SPEC §7 与 requirements §6/§10。

## 第一步：读设计文档

- `SPEC.md` —— 唯一真相源。
- `requirements.md` —— 决策与非目标。
- `docs/` —— SDD 脚手架（方法论、模板、工作流程）。
- **参考蓝本（只读，非本项目代码）**：
  - `sample/BiaoGe/` —— 同类金团插件，**架构蓝本**（插件+WA 同体、通讯协议、引导器）。核心看 `Core/Module/AuctionWA.lua`、`Core/DB/Init.lua`、`BiaoGe.toc`。
  - `sample/RaidGames-handoff/` —— Claude Design **UI 设计稿**（`project/styles.css` 令牌、`screens.jsx` 五屏、`components.jsx` 组件）。

## 项目一句话定位

一个魔兽世界 **WotLK Classic 时光服**（`3.80.1.67621`，TOC `Interface 38001`）插件「游戏大厅」：团本后用小游戏比赛决定战利品归属，替代单纯 roll 点。**框架 + 可插拔游戏**，**插件 + WeakAuras 字符串双分发**，把「低门槛传播」当一等目标。首发游戏「极速按键」。

## 不可违反的架构不变量

1. **双分发同体机制**：核心与每个游戏都用 `local self = aura_env or {}` 兼容「插件/WA」两种运行环境，并用 `_G.GameLobby` 版本门控做幂等引导（高版本胜，支持 WA 字符串热升级）。照 `sample/BiaoGe/Core/Module/AuctionWA.lua`。
2. **游戏逻辑与通讯解耦**：游戏只产出「分数/事件」，收发统一走核心 Comm 层。新增游戏不改通讯。
3. **裁判端(host)与参与端职责分离**：排名汇总只在发起者(host)端算；参与端只上报与展示。
4. **协议字节级一致**：插件版与 WA 版的通讯前缀/编码/gameId 完全相同，否则无法同场互通。
5. **不依赖 BigFoot/大脚**：要独立可用，自带所需库（ChatThrottleLib 等）。
6. **SPEC 是真相源**：实现与 SPEC 冲突时，要么改代码要么先改 SPEC，不允许两者长期矛盾。

> 非目标（别擅自加回）：真正的防作弊、自动分配战利品、游戏内一键推送/P2P 代码传输、跨团队持久共享榜。详见 `requirements.md` §7。

## 关键目录速查

| 路径 | 职责 |
|------|------|
| `SPEC.md` | 唯一真相源：规格 + 验收标准 |
| `requirements.md` | 需求来源 + 决策日志 + 非目标 |
| `docs/` | SDD 脚手架（方法论/模板/流程） |
| `sample/BiaoGe/` | 架构蓝本（只读参考） |
| `sample/RaidGames-handoff/` | UI 设计稿（只读参考） |
| `docs/M1-status.md` | M1 进度报告（已完成/无头验证/待真机清单） |
| `docs/game-dev-spec.md` | 小游戏开发规范（游戏作者契约：分层 api/元数据/生命周期/分享/安全）；M2 目标（D21） |
| `.claude/agents/` | 魔兽插件开发 agent（见下） |
| `GameLobby/` | 插件核心代码（`Core/` 引导/通讯/状态机/UI、`Games/SpeedClick.lua`、`Libs/` 内嵌库、`Tests/` 无头测试、`dist/` 发布产物） |

## 专职 Agent（`.claude/agents/`）

| Agent | 职责 |
|------|------|
| `wow-addon-engineer` | WLK Lua/XML 通用工程：事件/SavedVariables/角色识别/比赛状态机/极速按键玩法/战绩 |
| `wow-comm-wa-specialist` | 核心难点：通讯协议 + 同体机制 + 版本门控 + RegisterGame + WA 导出 + 状态恢复 |
| `wow-ui-developer` | 按设计稿还原 UI：金属边框/宝石角/五屏/castbar/狂点钮/主题令牌/动效 |

## 测试 / 健康检查

**无头自动化（本机可复跑，已设为 `/deploy-addon` 发布前门禁）**：本机 Lua 5.1 跑三个无头测试，覆盖逻辑 + 集成（环境模拟见 `GameLobby/Tests/headless_env.lua`）：

- `GameLobby/Tests/Match_selftest.lua` —— 状态机逻辑：排名/平局加赛/异常分/非 host 不裁决/prize 往返/战绩。
- `GameLobby/Tests/run_all.lua` —— 加载全插件 + 引导 + slash 注册 + 五屏渲染 + host 一整局 + 导入导出面板。
- `GameLobby/Tests/run_match.lua` —— 线路收发：参与端 Start→Join→Begin→倒计时→上报→Final 落战绩；host 并列触发 Tie 加赛。
- 局限：模拟环境只查逻辑/nil/字段错，**不查真机视觉、真实网络**。

**仅能真机验证（见 `docs/M1-status.md` §3）**：

- 插件在时光服正常加载、`/gl` 开面板（已确认）；多人一整局排名一致；平局加赛；视觉细节。
- 极速按键 **`!GL:` 自控串**（非 WA 串，D19 后）导入大厅「+导入游戏」即玩；插件×插件 P2P 推送。

## 沟通约定

- 语言：中文（界面、注释、commit message 视情况）。
- **执行边界**：遵守 `~/.claude/CLAUDE.md` §10 红线——改版本号/发布/push 长期分支/合并/删除被跟踪文件等，一律先经用户明确同意，单次授权不延续。
- 改设计文档（SPEC/requirements）前明确告知改哪节、为什么。
