# CONTRACTS — 游戏大厅模块间契约（M1）

> **这是多 agent 并行开发的接口冻结文档。** 任何模块只能依赖本文件声明的 `GL.*` 接口，不得依赖别的模块的内部实现。
> 真相源仍是 [SPEC.md](../SPEC.md)；本文件是 SPEC 落到代码的**接口切分**。接口要改，先改本文件并通知 orchestrator。
> 版本：v1（2026-05-27）· 状态：冻结待实现

---

## 0. 全局约定

- **唯一全局**：`_G.GameLobby`（下文简称 `GL`）。所有模块把自己挂到 `GL.<Module>`。
- **双环境**：每个 `.lua` 文件首行 `local self = aura_env or {}`（同体机制，照 `sample/BiaoGe/Core/Module/AuctionWA.lua:23`）。
- **版本门控**：见 §1 Bootstrap。核心整体版本门控；**每个游戏独立版本门控**（热升级）。
- **命名规范**：玩家名一律用 `GL.Roster:Norm(name)` 归一化（带 `-realm`），字段内禁止逗号。
- **事件总线**：模块间解耦只走 `GL:On/:Emit`（§2），**不准跨模块直接调内部函数**（除本文件声明的公开方法）。
- **版本号格式**：`"x.y.z"` 字符串；比较用 `GL.GetVerNum`（数值化）。

---

## 1. Bootstrap / 生命周期 —— owner: **wow-comm-wa-specialist**

`GL` 由 Bootstrap 建立，幂等 + 版本门控（高版本胜，旧版让位时卸载：Hide 框架、UnregisterAllEvents、wipe）。

```lua
GL.version            -- string, 如 "0.1.0"
GL.GetVerNum(str)     -- "0.1.0" → 可比较数值
GL:Init(fn)           -- 注册初始化回调；核心就绪后按序执行（仿 BiaoGe BG.Init 队列）
GL.L                  -- 本地化表（__index 回落 key 自身），中文文案集中放这
```

引导用 `ADDON_LOADED` / `PLAYER_LOGIN` / `PLAYER_ENTERING_WORLD` 三档延迟初始化。各模块**不自己监听这些事件**，统一用 `GL:Init(fn)` 排队。

**热升级配合（Phase 0 落定，UI/Match 必读）**：顶层框架必须 `GL:_RegisterFrame(frame)` 登记、需清理的逻辑用 `GL:_RegisterTeardown(fn)` 登记——版本门控让位时 Bootstrap 会 Hide 所有登记框架并调 teardown 钩子。**不登记的框架在热升级后会变幽灵框架。**

---

## 2. 事件总线 —— owner: **wow-comm-wa-specialist**（实现），全员消费

```lua
GL:On(event, fn)      -- 订阅；fn(...) 接收 Emit 的可变参数
GL:Off(event, fn)
GL:Emit(event, ...)   -- 发布
```

### 冻结事件名（模块间唯一通信约定）

| 事件 | Emit 方 | 载荷 | 消费方 |
|------|---------|------|--------|
| `ROSTER_CHANGED` | Roster | （无） | UI |
| `GAME_REGISTERED` | Games | gameId | UI |
| `MATCH_STATE` | Match | newPhase, ctx | UI、当前游戏 |
| `MATCH_INVITED` | Match | ctx | UI（弹邀请框） |
| `MATCH_COUNTDOWN` | Match | n（3/2/1/0=GO） | UI（遮罩）、游戏 |
| `MATCH_PLAY_BEGIN` | Match | ctx | UI、游戏（开始采集输入） |
| `MATCH_PLAY_END` | Match | ctx | UI、游戏（停止采集） |
| `LIVE_SCORE` | Match | nameNorm, score | UI（实时排名刷新） |
| `MATCH_FINAL` | Match | ctx（含 ranking、winner） | UI、Stats |
| `MATCH_TIE` | Match | ctx（含 tiedNames） | UI、游戏 |
| `MATCH_CLOSED` | Match | （无） | UI、游戏 |
| `LOG` | 任意 | level("sys"\|"raid"\|"warn"), text | UI（日志条） |

**phase 枚举**（`ctx.phase`）：`"IDLE" "INVITING" "COUNTDOWN" "PLAYING" "COLLECTING" "RESULTS" "TIEBREAK"`。

### matchCtx 结构（贯穿所有模块的共享数据）

```lua
ctx = {
  matchId   = "1716800000-Tank",
  gameId    = "speedclick",
  gameVer   = "1.0.0",
  host      = "Tank-服务器",     -- 归一化
  isHost    = true/false,        -- 本端是否裁判
  phase     = "PLAYING",
  duration  = 10.0,              -- 秒
  round     = 0,                 -- 0=正赛，≥1=加赛轮次
  remaining = 6.3,               -- 剩余秒（仅 PLAYING 有意义）
  prize     = { mode="loot"|"custom"|"friendly", itemLink=?, text=?, rarity=? },
  players   = { [nameNorm] = { name, classFile, ready=bool, isSelf, isLeader, spectator=bool } },
  scores    = { [nameNorm] = number },   -- 实时/最终分数
  ranking   = { {name, score, cps, classFile}, ... }, -- 仅 host 计算后、FINAL 时填充（带 classFile 供 UI 直接着色）
  winner    = "Healer-服务器",
}
```

---

## 3. Comm 通讯层 —— owner: **wow-comm-wa-specialist**

协议见 [SPEC §6](../SPEC.md)。`GL.Comm` 把字节级协议封死，上层只认命令名 + 参数。

```lua
GL.Comm.PREFIX        -- "GameLobby"
GL.Comm.PROTO_VER     -- 协议版本号，进 Start 载荷
GL.Comm.SEP, GL.Comm.MAX_FIELDS, GL.Comm.MAX_BYTES   -- 编码常量
GL.Comm:Broadcast(cmd, ...)        -- 自动 RAID/PARTY（依赖 Roster:GetChannel()，单人=nil 不发）；逗号编码；ChatThrottleLib 节流
GL.Comm:Whisper(target, cmd, ...)
GL.Comm:RegisterHandler(cmd, fn)   -- 见下方签名
GL.Comm.Encode(...) / GL.Comm.Decode(str)            -- 纯函数，WA 版复用
GL.Comm.SplitLead(str, leadCount)  -- 安全拆分：前 leadCount 段后保留含逗号尾段（替代原生 strsplit）
GL.Comm:PackPrize(prizeTbl)        -- prize 表 → 逗号安全串（base64，无逗号），供 Start/State 携带
GL.Comm:UnpackPrize(str)           -- 逆操作，还原 prize 表
```

> **prize 上线（orchestrator 拍板）**：`Start`/`State` 必须携带 prize（参与端大厅/结算需显示奖品，SPEC §4.3/§4.6）。prize 的 name/text 是自由文本可能含逗号，违反 §0「字段内禁逗号」——故用 `Comm:PackPrize` 编码成逗号安全串，作为 `Start`/`State` 的**末位**字段携带；接收端 `UnpackPrize` 还原进 `ctx.prize`。

**handler 实际签名（Phase 0 落定）**：

```lua
fn(sender, a1, a2, a3, a4, a5, a6, a7, rawBody)
-- a1..a7 = cmd 之后的 body 参数；a7 = 第 7 段起的剩余原文
-- rawBody = 去掉 "cmd," 前缀的整段原文
```

> **Match 实现注意（Phase 0 specialist 标注）：**
> - `Final` handler 必须用 `GL.Comm.SplitLead(rawBody, 2)` 取 `matchId, winner, rankingCSV`（含逗号尾段不能靠 a1..a3）；`Tie` 的 `tiedNamesCSV` 同理用 SplitLead。
> - host 编码 `Final` 前**必须自行截断前 N 名**（20 人团 rankingCSV 会超 255 字节，Comm 只兜底丢尾，不能依赖）。
> - 注册 `GetState`（在场者 WHISPER 回 `State`）与 `State`（晚到者据回复补建 ctx）handler；`PLAYER_ENTERING_WORLD` 后 ~1.5s 由 Init.lua 自动广播一次 `GetState`，回复逻辑归 Match。

- 命令名即 SPEC §6 表：`Start Begin Join Result Final Tie GetState State VersionCheck MyVer`。
  - **`Begin`（M1 新增，addon-engineer 实现）**：`Begin,matchId,round`，host → RAID。SPEC §6 协议表原本缺「开局信号」——host `Match:Begin()` 仅本地起倒计时，参与端无从同步。补此命令：host 广播 Begin，参与端 handler 据此 `_StartCountdown`。插件版/WA 版同名同义（不变量 #4）。
  - **`Live`（M1 新增，addon-engineer 实现）**：`Live,matchId,name,score`，参与端 → RAID，**节流广播**（≥0.4s/条，比赛中本端分数变化时发）。各端收到后更新 `ctx.scores` 并 `Emit("LIVE_SCORE", name, score)`，使比赛中 live-board 真·跨端实时（SPEC 功能4 / §4.5 要求）。host 最终仍以 `Result` 汇总为准，`Live` 仅供观感，不参与排名裁决。
- **Match 注册这些 handler**，Comm 只管收发/解码/路由，不懂业务。
- 单条 ≤255 字节，过长（如 ranking）截断前 N 名；只处理当前 matchId，过期/未知丢弃。
- **库自带**（不依赖大脚，invariant #5）：`Libs/` 内嵌 `ChatThrottleLib`、`LibSerialize`、`LibDeflate`、`LibBase64`。本层负责落地这些库 + `embeds.xml`。

---

## 4. Roster 角色识别 —— owner: **wow-addon-engineer**

```lua
GL.Roster:CanInitiate()   -- bool：是团长/助理 且 在队伍/团队中
GL.Roster:IsLeader()      -- UnitIsGroupLeader("player")
GL.Roster:IsAssist()      -- UnitIsGroupAssistant("player")
GL.Roster:GetChannel()    -- "RAID" | "PARTY" | nil（单人）
GL.Roster:GetMembers()    -- { {name, nameNorm, classFile, class, isSelf, isLeader, online}, ... }
GL.Roster:Norm(name)      -- 归一化为 name-realm
GL.Roster:Me()            -- 自己的归一化名
```

成员/身份变化时 `GL:Emit("ROSTER_CHANGED")`（监听 `GROUP_ROSTER_UPDATE` / `PARTY_LEADER_CHANGED`）。

---

## 5. Match 比赛状态机 —— owner: **wow-addon-engineer**（M1 核心）

状态机 + 裁判/参与端职责分离（invariant #3：排名只在 host 算）。

```lua
-- 发起端（host，需 Roster:CanInitiate()）
GL.Match:Start(gameId, opts)   -- opts={ prize=..., duration=? }；生成 matchId；Comm:Broadcast("Start",...)
GL.Match:Begin()               -- host：全员就绪后开局，触发倒计时
GL.Match:Rematch()             -- 再来一局
-- 参与端
GL.Match:Join()                -- 报名 + 打开大厅
GL.Match:SetReady(bool)        -- 准备/取消
GL.Match:SetSpectator()        -- 围观
-- 游戏回调用（见 §6 游戏 api）
GL.Match:ReportScore(score)    -- 当前端上报本轮分数 → Comm Result
-- 通用
GL.Match:GetContext()          -- 返回当前 ctx（见 §2），无比赛时 phase=IDLE
GL.Match:Close()
```

职责：
- 注册并处理所有 §3 通讯 handler（Start/Join/Result/Final/Tie/GetState/State 等）。
- host 端：收 Result → 收集窗口（计时结束后 3 秒）→ 算 ranking（降序）→ 判第一名并列（触发 Tie 加赛，仅并列者，SPEC 功能 6）→ Broadcast Final。
- 分数上限校验：`> duration * 20` 标异常不计冠军（SPEC 功能 5）。
- 状态恢复：收 `GetState` 回 `State`；本端 reload/晚到广播 `GetState` 据回复补建 ctx（SPEC §6）。
- 在 phase 切换/倒计时/开局/结束/最终/平局各点 `Emit` 对应事件（§2）。
- 在 PLAY_BEGIN/END 调用当前游戏的 `host`/`client` 生命周期（§6）。
- 同一时刻只允许一场（已有进行中再发起被拒，Emit LOG warn）。

---

## 6. GameRegistry + 游戏接口 —— owner: **wow-addon-engineer**

```lua
GL:RegisterGame(def)      -- 核心未就绪时压入 GL._pendingGames，引导后回收（D16 聚合串加载顺序）
GL.Games:Get(id)
GL.Games:List()           -- 有序，含 locked 占位游戏
```

### 游戏 def 契约（SpeedClick 即按此实现）

```lua
{
  id        = "speedclick",
  name      = "极速按键",
  version   = "1.0.0",          -- 独立版本门控（热升级）
  glyph     = "⚡",             -- 或贴图路径
  descLines = { "10 秒狂点", "多者胜" },
  duration  = 10.0,             -- 默认计时窗口
  locked    = false,            -- 占位游戏 true（down100/up100）
  code      = "return { ... }", -- 可选：游戏源码文本，供 ExportGame 打包再分享；
                                -- 内置游戏自带（建议游戏「从 code loadstring 出 def」使插件版/WA 版同源），
                                -- 导入的游戏由 GameImport 把 payload.code 写回 def.code

  -- 生命周期（Match 在对应时机调用，传入 ctx 和 api）
  client = function(ctx, api)   -- 参与端：MATCH_PLAY_BEGIN 时调用
      -- 绑定输入（极速按键：smash 按钮 OnMouseDown → api:AddScore(1)）
      -- 计时用 GetTime()；api:Finish() 在 duration 到点时由 Match 统一调用，游戏只负责采集
  end,
  host   = function(ctx, api) end,  -- 裁判端额外逻辑（极速按键无特殊，可空）
  onResult = function(ctx) end,     -- 可选：FINAL 后游戏侧收尾
}
```

### 游戏 ↔ UI ↔ Match 的边界（重要，避免三方打架）

- **UI 拥有 PlayingScreen 骨架**（castbar、计数大数字、live-board、smash 按钮容器）—— 它是「计时内刷分」的**通用**比赛屏，由 ctx 驱动，对 SpeedClick 之外的游戏也复用。
- **游戏只提供输入与计分规则**：SpeedClick 的 `client` 拿到 UI 暴露的 smash 按钮句柄（经 `api`），挂 `OnMouseDown` 计数，调 `api:AddScore(1)`。
- **api 接口**（Match 构造，传给 game + 供 UI 调用）：

```lua
api:AddScore(delta)   -- 累加本端分数 → 内部攒分；Match 节流后 Emit LIVE_SCORE + 广播
api:GetScore()
api:SmashButton()     -- 返回 UI 的狂点钮句柄（仅 PlayingScreen 存在时）；游戏挂输入用
api:IsSpectator()
-- Finish 由 Match 在 duration 到点统一触发 ReportScore，游戏不必自己调
```

- **占位游戏**：Registry 预注册 `down100`/`up100`，`locked=true`，UI 显示「即将上线」灰格、不可发起。

---

## 7. Stats 战绩 —— owner: **wow-addon-engineer**

```lua
GL.Stats:GetSummary()  -- { total, wins, winRate, prizeCount, avgScore }
GL.Stats:GetHistory()  -- { {time, gameId, gameName, count, prize={mode,...}, winner, winnerScore, myResult={rank,score,isWin}}, ... } 倒序
GL.Stats:Clear()       -- 带二次确认（确认 UI 由 UI 层弹，Stats 只清数据）
```

- SavedVariables 账号级：`.toc` `## SavedVariables: GameLobbyDB`。
- 监听 `GL:On("MATCH_FINAL", ...)`，参与即记录（无论输赢）。

---

## 8. Import / WA 导入导出 —— owner: **wow-comm-wa-specialist**（Phase 2）

```lua
GL.Import:ParseWA(str)    -- "!WA:" → base64 → LibDeflate 解压 → LibSerialize 反序列化 → 取自控固定字段
GL.Import:ImportGame(str, onDone)  -- ParseWA + 信任门（默认拒绝）+ loadstring + RegisterGame；onDone(ok,msg) 异步回调（省略则 Emit LOG）
GL.Import:LooksImportable(str)     -- 轻量前缀判断，供 UI 输入框即时校验
GL.Import:ExportGame(id)  -- 返回 (str)|(nil,reason)：把已注册游戏的源码打包成 !GL:1! 自控串（可粘进别人大厅导入框）。
                          -- 依赖 def.code（游戏源码文本）；无 code（如占位游戏/未带源码的内置游戏）返回 nil + 原因。
```

> **导出说明**：`!GL:1!` 是自控格式（base64+serialize，与 ParseWA 同模板，能被本大厅导入框再导入）。**插件↔插件分享用**；面向 WeakAuras 用户的标准 `!WA:2!` 串仍需游戏内 WA 半自动导出（M1 真机待办）。

> **UI 待补（Phase 2 specialist 标注）**：UI 需提供「导入游戏字符串」输入框入口，调 `GL.Import:ImportGame(userStr, function(ok,msg) ... end)`。信任门由 ImportGame 内部自动弹（UI 入口不必再弹）。
>
> **自控 WA 模板固定字段**（导出端↔解析端唯一契约）：反序列化后定位 `payload = { __gl=true, kind="game"|"bundle", id, name, version, coreMin, source, code, items? }`，`code` loadstring 后须 `return def`（§6）。元数据与 code 分离，未执行 code 即可做版本/兼容判断。串前缀 `!WA:2!`（现行 WA）/ `!WA:1!`·`!GL:1!`（自控）。

- 导出端 + 解析端共用同一套 WA 模板（自控固定字段放游戏代码），降低对 WA 内部结构耦合。
- dist/ 三档产物（D16）：`GameLobby-bundle.wa.txt`（全家桶 group 聚合，主推）/ `GameLobby-core.wa.txt` / `SpeedClick.wa.txt`。半自动流程，须写 `dist/README.md` 记录可重复步骤。
- 信任确认门：UI 提供 `GL.UI:ConfirmTrust(source, onYes)`（§9）。

---

## 9. UI —— owner: **wow-ui-developer**

按 [SPEC §4](../SPEC.md) 还原；**M1 仅铁木 Ironwood 主题**。

```lua
GL.UI.theme               -- 铁木令牌的 0–1 RGB 表（hex→RGB）+ 稀有度色 + 9 职业色 + 字距/字号常量
GL.UI:Toggle()/:Show()/:Hide()   -- 主面板（绑 /gl /gamelobby /游戏大厅，slash 注册由 UI 做）
GL.UI:ShowScreen(name)    -- "lobby" "playing" "results" "history" "about"
GL.UI:Countdown(n)        -- 倒计时遮罩（n=3/2/1/0=GO）
GL.UI:Log(level, text)    -- 等价订阅 LOG 事件，刷日志条
GL.UI:Invite(ctx)         -- 收到 Start 的邀请 StaticPopup（参与/围观）
GL.UI:ConfirmTrust(source, onYes)  -- 导入代码信任门（默认拒绝），供 Import 用
GL.UI:SmashButton()       -- 暴露 PlayingScreen 狂点钮句柄给游戏 api
-- Phase 1 落定，UI 自用（不影响其他模块）：
GL.UI:RegisterScreen(name, builderFn)  -- 屏幕惰性注册（各屏幕文件登记自己，Frame 路由调用）
GL.UI:ToggleScreen(name)               -- 战史/关于再点返回上一游戏屏
GL.UI:RefreshBadge()                   -- 刷新角色徽章（内部订阅 ROSTER_CHANGED 调用）
GL.UI:ShowImport() / :HideImport()     -- 「导入游戏字符串」面板（调 GL.Import:ImportGame）
GL.UI:ShowExport(title, str)           -- 只读可复制弹框，展示导出的字符串（自动全选便于 Ctrl+C）
-- GameTile 右键 → 下拉菜单「导出字符串」→ GL.Import:ExportGame(id) → GL.UI:ShowExport(...)
```

- 订阅 §2 事件刷新（ROSTER_CHANGED→参赛者网格；MATCH_*→屏幕切换/倒计时/结算；LIVE_SCORE→实时排名；GAME_REGISTERED→游戏格）。
- 五屏 + 组件按 SPEC §4.2–4.8；金属边框/宝石角/字距/发光按 §4.10 用贴图近似。
- **不碰业务逻辑**：发起/准备/上报一律调 `GL.Match:*`；身份/名单查 `GL.Roster:*`；战绩查 `GL.Stats:*`。

---

## 10. .toc 加载顺序（owner: comm-specialist 维护）

```
Bootstrap.lua → Libs/embeds.xml → Comm.lua → (事件总线在 Bootstrap)
→ Roster.lua → GameRegistry.lua → Stats.lua → Match.lua
→ UI/*.lua（theme 先，frame 次，screens/widgets 后）
→ GameImport.lua
→ Games/SpeedClick.lua（最后；RegisterGame，核心已就绪）
→ Init.lua（最末，触发 GL:Init 队列 flush）
```

---

## 11. 文件归属（防并行撞车）

| Agent | 拥有文件 |
|-------|---------|
| wow-comm-wa-specialist | `GameLobby.toc`、`Core/Bootstrap.lua`、`Core/Init.lua`、`Core/Comm.lua`、`Core/GameImport.lua`、`Libs/**`、`dist/**` |
| wow-addon-engineer | `Core/Roster.lua`、`Core/Match.lua`、`Core/GameRegistry.lua`、`Core/Stats.lua`、`Games/SpeedClick.lua` |
| wow-ui-developer | `Core/UI/**`（theme/frame/lobby/playing/results/history/about/widgets/popups/importpanel） |

跨文件接口只认本契约。需要新增公开方法 → 先在本文件加一行，再实现。
