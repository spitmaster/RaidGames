# 小游戏开发规范（Game Dev Spec）

> **面向谁**：想给「游戏大厅」写一款小游戏的人——无论是项目自己（下一款官方游戏）还是第三方贡献者。
> **和 [contracts.md](contracts.md) 的区别**：`contracts.md` 是核心内部多 agent 并行开发的接口冻结文档（满是 owner / 防撞车），**你不需要读它**。本文件只讲「写一款游戏要遵守什么、框架给你什么」。
> **真相源**：本规范描述的通用游戏契约是 [SPEC.md](../SPEC.md) §5/§6 的泛化（决策见 [requirements.md](../requirements.md) D21）。规范与代码冲突时，以本文件为准并回写代码。
>
> **里程碑标注**：本规范是 **M2 目标契约**。M1 的极速按键用的是更窄的「刷分专用」接口（`client/host` + `api:SmashButton()`）；M2 落地通用容器时，极速按键会被迁移到本规范的统一生命周期，并以「是男人就下 100 层」作为首个 canvas 档游戏验证本规范。**M2 落地前，本文件描述的 api 尚未全部存在。**
> 版本：v0.1（草案）· 日期：2026-06-01

---

## 0. 30 秒心智模型

一款游戏 = **一张 `def` 表**。框架是一条**比赛流水线**：

```
发起 → 邀请/报名 → 倒计时(3 2 1 GO) → 比赛 → 收分 → 排名 → (平局?加赛) → 结算 → 落战绩
```

你**只负责「比赛」那一格里发生什么**：怎么交互、怎么算分。其余全部归框架。
你和框架之间只有两个接触面：

1. 框架在固定时机**回调你的生命周期函数**（`setup/start/stop/teardown/...`）。
2. 你通过框架给你的 **`api` 对象**上报分数、拿画布、拿时钟、申请键盘——**绝不自己发网络消息、绝不自己碰核心其它模块**（架构不变量 #2）。

记住这条铁律：**游戏只产出「分数 / 事件」，收发统一走核心。** 新增游戏永远不碰通讯层。

---

## 1. 两个档位：先选对档，别过度工程

不是每款游戏都要自绘画面。先判断你的游戏属于哪档：

| 档位 | `tier` | 典型游戏 | 框架给你 | 你写什么 |
|------|--------|---------|---------|---------|
| **刷分档（默认）** | `"score"` | 极速按键、心算闪电战、词牌接龙 | 现成的标准比赛屏（计数大字 + castbar 计时条 + 实时排名榜）+ 现成控件 | 只挂输入 + 调 `api:AddScore`，几十行 |
| **自绘档（opt-in）** | `"canvas"` | 是男人就下 100 层、跳跃闯关、贪吃蛇 | 一块**空 Frame**（`api:Canvas()`）+ 键盘焦点托管 | 自己建 Texture、自己跑游戏循环、自己处理碰撞 |

> **重要**：`canvas` 在 WoW 里**不是**像素画布/帧缓冲，就是一个普通的 `CreateFrame("Frame")` 容器——框架把它建好、定好位、定好尺寸、登记好清理钩子，交给你当根节点。WoW UI 本就是「Frame + Texture」保留模式，你画角色/平台本来就得用 Texture，框架给容器**不增加任何额外重量**。

**选档原则**：能用刷分档就别用自绘档。自绘档自由度高，但你要自己背性能、键盘、清理的责任（见 §5）。

---

## 2. `def` 契约（你要交付的全部）

```lua
return {
    --==== 身份 ====--
    id        = "down100",                 -- 全局唯一，小写无空格；同场互通靠它（不变量 #4）
    name      = "是男人就下 100 层",
    version   = "1.0.0",                   -- "x.y.z"；独立版本门控，热升级靠它（见 §6）
    glyph     = "Interface\\Icons\\...",   -- 游戏格图标：贴图路径 或 单个 emoji 字形
    descLines = { "深渊速降", "踩平台往下，越深越高" },  -- 游戏格两行描述

    --==== 元数据：框架据此「通用地」排名/校验/展示（§3 详解）====--
    tier        = "canvas",          -- "score" | "canvas"；默认 "score"
    endMode     = "elimination",     -- "timed" | "elimination" | "race"
    scoreOrder  = "desc",            -- "desc" 高者胜 | "asc" 低者胜（如用时）
    scoreUnit   = "层",              -- UI 显示单位（"次"/"层"/"秒"/"分"）
    duration    = 60,                -- timed=窗口长度；elimination/race=封顶秒(maxDuration)
    needsKeyboard = true,            -- 要键盘则声明，框架提前托管焦点
    seeded      = true,              -- 要不要统一随机种子（公平，§4）
    scoreCap    = function(dur) return 100 end,  -- 上限校验：超出此值的上报标「异常」不计冠军

    locked      = false,             -- 占位游戏 true（灰格「即将上线」、不可发起）

    --==== 自包含源码（分享用，见 §6）====--
    code        = "...",             -- 见 §6：通常游戏写成 SOURCE 字符串，loadstring 出 def

    --==== 生命周期：框架在对应比赛 phase 调用，传入 (ctx, api) ====--
    setup    = function(ctx, api) end,  -- 倒计时开始时：建场景/UI，但**别动**（别开循环、别收输入）
    start    = function(ctx, api) end,  -- "GO!"：开你的 OnUpdate 循环 + 开始收输入
    stop     = function(ctx, api) end,  -- 时间到 / 你 Finish 了：冻结、停循环、停输入（分数已在 api 里）
    teardown = function(ctx, api) end,  -- 关闭/热升级：清理一切（隐藏画布、解绑键盘、停 OnUpdate）——**必须实现**
    onTie    = function(ctx, api) end,  -- 被选中加赛：重置场景重开一局（可选；不实现则复用 setup+start）
    onResult = function(ctx)      end,  -- 结算后收尾（可选）
}
```

`ctx` 是贯穿全场的共享上下文（matchId/gameId/host/players/scores/prize/round 等，结构见 [contracts.md §2](contracts.md)）。**你只读 ctx，不写 ctx。**

---

## 3. 元数据为什么是关键（多游戏后框架无法再「假设」）

极速按键能把规则写死，是因为 M1 只有它一款。一旦有多款形态不同的游戏，**框架必须从游戏的元数据里读出它的脾气**，否则没法通用地裁决。三个字段最关键：

### `endMode` —— 比赛什么时候算结束

| 值 | 含义 | 例子 | 框架行为 |
|----|------|------|---------|
| `"timed"` | 固定时间窗口，到点全员同时停 | 极速按键 10s | 倒计时结束起 `duration` 秒计时，到点广播停 |
| `"elimination"` | 各自玩到死，先死先停，分数定格 | 下 100 层 | 你调 `api:Finish()` 上报；全员都 Finish 或到 `maxDuration` 封顶则结算 |
| `"race"` | 先达终点者优先 | 限时解谜 | 同 elimination，但 `scoreOrder` 通常配 `asc`（用时短者胜） |

### `scoreOrder` —— 谁是冠军

- `"desc"`：分高者胜（点击数、深度）。
- `"asc"`：分低者胜（用时、步数）。框架排名、并列判定、加赛全部据此反向。

### `scoreCap` —— 轻量防作弊（SPEC 功能 5）

分数客户端自报，框架**不做真防作弊**（项目非目标），只做上限校验：上报值超过 `scoreCap(duration)` 的标「异常」、不计冠军。下 100 层最多 100 层，所以 `scoreCap = function() return 100 end`。极速按键是 `duration * 20`。

> **务必理解**：你的游戏**天生防不住改分**——纯客户端插件，分数自报。设计时**不要假设公平**，靠团队社交信任。这是项目既定非目标（requirements §7），不是 bug。

---

## 4. 公平性：实时游戏必须用统一种子

刷分档无所谓，但**自绘/随机关卡的游戏**（下 100 层的平台布局）如果每个客户端各自随机，「谁下得最深」就没有可比性。

规则：声明 `seeded = true`，框架在 `Start` 广播里下发**全场统一种子**，你用 `api:GetSeed()` 取出来生成关卡：

```lua
function def.setup(ctx, api)
    local seed = api:GetSeed()          -- 全场一致
    math.randomseed(seed)               -- 之后 math.random() 序列各端相同 → 关卡相同
    -- ...用 random 生成平台/缺口布局...
end
```

> 注意：`math.randomseed` 是全局状态，框架会在 `setup` 前后做隔离约定（M2 落地时明确）。在 `setup` 里一次性生成完关卡数据、别在循环里反复 reseed。

---

## 5. `api` 接口（你和框架的唯一服务面）

### 5.1 通用（两档都有）

```lua
api:AddScore(delta)   -- 累加当前分；框架节流后广播 + 刷新实时榜
api:SetScore(n)       -- 直接设当前分（下 100 层：直接 SetScore(当前层数)）
api:GetScore()        -- 读当前分
api:Finish(score?)    -- 主动结束本端（elimination 必用：摔死就调）；省略 score 用已攒的
api:Remaining()       -- 剩余秒（timed 有意义）
api:Elapsed()         -- 已用秒（用游戏时钟 GetTime 算，别自己记）
api:GetSeed()         -- 本场统一随机种子（seeded=true 时）
api:IsSpectator()     -- 围观者只渲染、不收输入（必须判：围观者别绑输入、别计分）
api:Log(text)         -- 往大厅日志条写一行（可选）
```

### 5.2 刷分档专属（`tier="score"`，框架已建好标准屏）

```lua
api:SmashButton()     -- 标准比赛屏的「计数大按钮」句柄；挂 OnMouseDown → api:AddScore(1)
                      -- （极速按键即用此；其它刷分游戏可挂自己的输入控件）
```

### 5.3 自绘档专属（`tier="canvas"`）

```lua
api:Canvas()                    -- 你的根 Frame（已 SetSize/定位在比赛区中央）；往里建 Texture/FontString
api:CaptureKeyboard(on, keys?)  -- 申请/归还键盘焦点；框架统一处理 SetPropagateKeyboardInput + 退出还原
                                -- keys 可选：声明你关心的键，框架只吞这些、其余（ESC 等）透传
```

**为什么键盘要走框架托管**：WoW 里 WASD/方向键默认绑定到角色移动。你若自己 `SetPropagateKeyboardInput(false)` 吞掉按键又忘了还原，会**把玩家锁死在原地**。框架的 `api:CaptureKeyboard` 集中管「比赛开始吞 / 比赛结束还」，并保证 ESC 永远透传（让玩家能逃）。**永远别自己改键位绑定。**

---

## 6. 自包含源码 & 分享（可传播的前提）

游戏要能在玩家间「复制即玩」，靠的是把游戏本体写成一段**自包含源码字符串** `SOURCE`，`loadstring` 出 def（极速按键已示范，见 [SpeedClick.lua](../GameLobby/Games/SpeedClick.lua)）：

```lua
local SOURCE = [[
return {
    id = "down100", version = "1.0.0", tier = "canvas", ...
    setup = function(ctx, api) ... end,
    -- 全部生命周期都在这字符串里
}
]]
local def = assert(loadstring(SOURCE))()
def.code = SOURCE      -- 挂回去，供 GL.Import:ExportGame 打包分享
```

**铁律——自包含**：`SOURCE` 里的代码**只能**引用三种东西：
1. 它自己的参数 `ctx` / `api`；
2. 全局（`GetTime`、`math`、`_G.GameLobby` 等）；
3. 它自己内部定义的 local。

**绝不能**引用 `SOURCE` 字符串外面的 upvalue/local——因为导入方 `loadstring` 时没有你文件的环境，会直接报 nil。这跟「能被分享」是同一个约束。

分享路径（D19/D20 后的现状）：
- 右键游戏格「导出字符串」→ 得到 `!GL:` 自控串 → 别人粘进大厅「+导入游戏」框 → 过信任门 → 立即可玩。
- 右键队友 → P2P 推送（功能 9b）。
- **版本门控热升级**：导入更高 `version` 的同 `id` 游戏，框架自动卸旧装新；低版本被忽略（不降级）。所以**升级游戏务必递增 `version`**。

---

## 7. 安全 / 信任（写之前必须知道）

- 你的游戏代码在用户那边是 `loadstring` 执行的外来代码。导入时用户会看到**强警告**「此游戏含可执行代码，仅从可信来源导入」，**默认拒绝**。
- 代码跑在 WoW 沙箱里（无文件/操作系统访问），但**能做插件能做的事**（发言、改数据）。框架**无法真正沙箱**你——这是 WoW 的限制。
- 作为作者：别干恶意的事；别在游戏里发聊天消息冒名；别动框架其它模块的内部数据。一旦被发现，传播链会断。

---

## 8. 性能指引（自绘档尤其看）

每个客户端**只渲染自己那一局**（别人的「深度」只是实时榜上的一个数字，不渲染别人的画面），所以渲染成本是 O(1) 每端、与团队人数无关。但仍要省着用：

- **复用 Texture，别每帧 `CreateTexture`**：开局建好一池子，循环里只改位置/显隐。
- **OnUpdate 别做重活**：用 `elapsed` 累加器做固定步长更新，别每帧分配新 table（GC 压力）。
- **比赛结束务必停 OnUpdate**：`teardown` 里 `frame:SetScript("OnUpdate", nil)`，否则残留循环空跑。
- 假定**比赛期间非战斗**（小游戏在团本间隙/打完后玩）；不支持战斗中开赛（secure frame 受限）。

---

## 9. 怎么本地测（无需进游戏）

本机有 Lua 5.1，项目用无头测试夹具 [headless_env.lua](../GameLobby/Tests/headless_env.lua) 模拟 WoW API（Frame/Texture/事件/C_Timer/通讯）。

- 刷分档：现成的 `Tests/run_match.lua` 跑「Start→Join→Begin→倒计时→上报→Final」线路即可套你的游戏。
- 自绘档：M2 落地时会扩展夹具，模拟 `OnKeyDown`/`OnUpdate`/`Canvas`，让下 100 层这类游戏也能无头跑逻辑（碰撞/计分/Finish 时机）。模拟环境**查不了真机视觉**，视觉只能真机看。
- 真机调试（时光服屏蔽报错弹窗）：用 `pcall` 把错误打到聊天框——

  ```
  /run local ok,err=pcall(...); print("结果:", ok, err)
  ```

---

## 10. 写一款游戏的清单（Checklist）

- [ ] 选对 `tier`（能刷分就别自绘）。
- [ ] 填全身份 + 元数据，尤其 `endMode` / `scoreOrder` / `scoreUnit` / `scoreCap`。
- [ ] 生命周期：`setup` 只建不动、`start` 才开跑、`stop` 定格、**`teardown` 清干净**。
- [ ] 围观者分支：`if api:IsSpectator() then` 不绑输入、不计分。
- [ ] 随机关卡用 `api:GetSeed()`，别各端各随机。
- [ ] 自绘游戏：键盘走 `api:CaptureKeyboard`，Texture 复用，`teardown` 停 OnUpdate。
- [ ] 游戏本体写成自包含 `SOURCE`，不引用外部 upvalue；`def.code = SOURCE`。
- [ ] 升级游戏递增 `version`。
- [ ] 本地无头测试跑通逻辑，再真机看视觉。

---

## 附：与现有 M1 接口的映射（迁移参考）

| M1 现状（极速按键） | M2 本规范 |
|---------------------|-----------|
| `def.client(ctx, api)`（PLAY_BEGIN 时绑输入） | `def.start(ctx, api)` |
| `def.host(ctx, api)` | 并入 `setup`/`start`（host 额外逻辑按需） |
| 手动 `On("MATCH_PLAY_END"/"MATCH_CLOSED", cleanup)` | `def.stop` / `def.teardown` |
| `api:SmashButton()`（写死狂点钮） | 保留为刷分档专属；自绘档用 `api:Canvas()` |
| 隐含 `endMode="timed"` / `scoreOrder="desc"` | 显式声明在 def 元数据 |
| 无统一种子 | `seeded` + `api:GetSeed()` |
| 无键盘托管 | `api:CaptureKeyboard` |
