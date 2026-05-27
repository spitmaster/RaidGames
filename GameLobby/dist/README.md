# dist/ — WA 分发串产物与生成流程

> 真相源是仓库里的 `.lua`（`Core/`、`Games/`、`Libs/`）。本目录的 `.wa.txt` 是**生成产物**。
> 任何串与代码不一致时，**重新生成串**，不要手改串。
> 本流程对应 SPEC §5「WA 导出与构建」+「三档供给（D16）」，承认纯离线生成完整 WA 串复杂，故 M1 用**半自动**。

## 产物清单（D16 三档，并存不互斥）

| 文件 | 内容 | 给谁 | 编码 | 状态 |
|------|------|------|------|------|
| `SpeedClick.gl.txt` ✅即用 | 仅极速按键（自控游戏载荷） | 已装核心者加新游戏 | `!GL:1!`（本项目自控） | **离线生成、已往返校验，可直接用** |
| `GameLobby-bundle.wa.txt` ★主推 | 核心 + 极速按键（WA group 聚合单串） | 新人，一串即玩 | `!WA:2!`（WeakAuras 原生） | 占位 — 真机待生成 |
| `GameLobby-core.wa.txt` | 仅核心 | 想先要壳、游戏后补 | `!WA:2!`（WeakAuras 原生） | 占位 — 真机待生成 |
| `SpeedClick.wa.txt` | 仅极速按键，给纯 WA 用户 | 不装插件、只用 WeakAuras 的人 | `!WA:2!`（WeakAuras 原生） | 占位 — 真机待生成 |

### 两种格式 / 两个导入入口（务必分清）

| 格式 | 谁生成 | 导入入口 | 说明 |
|------|--------|----------|------|
| **`!GL:1!`**（如 `SpeedClick.gl.txt`） | 仓库 `.lua` **离线**经 `export-tool.lua`/同链路生成，**无需 WeakAuras** | 大厅界面「**+ 导入游戏**」框 → `GL.Import:ImportGame` → 信任门 → 即玩 | 本项目自控裸串；base64 链；零 WeakAuras 结构耦合，最稳。已离线往返校验（解析端 `ParseWA` 还原出的 `code` 字节一致）。 |
| **`!WA:2!`**（如 `GameLobby-bundle.wa.txt`） | **游戏内** WeakAuras 原生导出（需运行中 WeakAuras + 游戏客户端） | WeakAuras **自带导入框**（也可走大厅导入框，`ParseWA` 同样认） | WeakAuras 现行格式；`EncodeForPrint` 链。给纯 WA 用户 / 全家桶一串即玩。离线无法生成，故为真机待办。 |

两种串前缀都被 `Core/GameImport.lua` 的 `ParseWA` 支持（大厅导入框通吃）：
- `!WA:2!` → `LibDeflate:DecodeForPrint` → `DecompressDeflate` → `LibSerialize:Deserialize`（WeakAuras 现行格式）
- `!WA:1!` / `!GL:1!` → `LibBase64.Decode` → `DecompressDeflate` → `Deserialize`（自控/旧式）

> 区别一句话：**`.gl.txt`（`!GL:`）离线可造、即用、进大厅导入框；`.wa.txt`（`!WA:`）需真机 WeakAuras 生成、可进 WA 自带导入框或大厅导入框。**

## 自控载荷结构（导出端 ↔ 解析端唯一契约）

反序列化后必须能找到一个**自控载荷表**（降低对 WeakAuras 内部结构的耦合，SPEC 功能 9 第 3 点）：

```lua
payload = {
  __gl    = true,            -- 魔法标记，识别「这是游戏大厅载荷」（必填）
  kind    = "game",          -- "game" 单游戏 | "bundle" 聚合（子项在 items）
  id      = "speedclick",    -- 游戏 id（kind=game 必填）
  name    = "极速按键",       -- 展示名（可选）
  version = "1.0.0",         -- 游戏版本（可选，提示用；权威以 def 内为准）
  coreMin = "0.1.0",         -- 需要的最低核心版本（可选；不满足给「请升级核心」提示）
  source  = "RaidGames 官方", -- 来源标识（喂给信任门展示给用户）
  code    = "return { id=..., client=function(ctx,api) ... end }",  -- 游戏 Lua 源码（必填，loadstring 后须 return def）
  items   = { payload, ... }, -- 仅 kind=bundle：子载荷数组
}
```

`ParseWA` 会在三处探测此载荷（任一命中即可，故导出布局可自由选）：
1. **顶层即 payload**（`!GL:1!` 裸串，`export-tool.lua` 默认产出，零 WA 耦合）；
2. WeakAuras 单 aura 导出 → payload 挂在 `data.d.gameLobby`；
3. WeakAuras group 导出 → payload 在 `data.c[i]` 或 `data.c[i].gameLobby`。

> 字段名 `__gl` / `gameLobby` 与 `kind/id/version/coreMin/source/code` 是冻结契约。
> 改字段必须同步改 `Core/GameImport.lua`（`MAGIC` / `PAYLOAD_FIELD` / 探测逻辑）+ `export-tool.lua`，
> 并保证插件版与 WA 版逐字一致（不变量 #4）。

---

## 生成步骤（可重复）

### A. 仅游戏档（`SpeedClick.wa.txt`）= 自控 `!GL:1!` 裸串【最简，推荐先做】

游戏内无法读硬盘，故把游戏 def 源码内联成字符串后用 `export-tool.lua` 打包：

1. 装好「游戏大厅」插件（`Libs/` 内嵌库已就绪）。
2. 把 `dist/export-tool.lua` 内容贴进一个 WeakAuras「自定义代码」aura 的 init custom，或 `/run`。
3. 准备游戏 def 源码字符串：把 `Games/SpeedClick.lua` 改写成 `return def` 形态
   （即去掉文件尾部的注册分支，让 chunk 直接 `return def`）。整段作为 Lua 字符串。
4. 执行：

   ```lua
   /run GameLobby_Export.Game("speedclick", [[ <return def 源码> ]], {name="极速按键", version="1.0.0", coreMin="0.1.0"})
   ```

5. 复制聊天框打印的 `!GL:1!....` 整行，替换 `SpeedClick.wa.txt` 的占位区。

> 多游戏聚合（已装核心者批量加游戏）：用 `GameLobby_Export.Bundle({ {id=..,code=..,meta=..}, ... })`。

### B. 核心档 / 全家桶（`GameLobby-core.wa.txt` / `GameLobby-bundle.wa.txt`）= WeakAuras group 原生导出

核心是一整套 `.lua` + 事件帧 + UI，**不走** `export-tool` 那条单段游戏载荷链。用 WeakAuras 原生导出：

**核心档：**
1. WeakAuras 建一个「自定义代码」aura（无触发器，纯 init custom）。
2. 按 `.toc` 顺序把 `Libs/*.lua` + `Core/*.lua` 拼接，贴进该 aura 的 `actions.init.custom`。
3. 右键 aura → 导出到字符串 → 得 `!WA:2!....`，替换 `GameLobby-core.wa.txt` 占位区。

**全家桶档：**
1. WeakAuras 建一个 group（群组）。
2. group 内子 aura A =「核心」（同上拼接）。
3. group 内子 aura B =「极速按键」（贴 `Games/SpeedClick.lua` 原文即可——它自带加载顺序兜底，
   核心未就绪时压 `_pendingGames`）。
4. 右键 group → 导出 → 得含两子项的 `!WA:2!....` 单串，替换 `GameLobby-bundle.wa.txt` 占位区。

---

## 真机待办（M1，需运行中 WeakAuras + 游戏客户端验证）

`!GL:1!` 自控串（`SpeedClick.gl.txt`）已**离线生成并往返校验**（仓库 `.lua` → 序列化/压缩/base64 → `ParseWA` 还原，`code` 字节一致），无需真机即可用。
`!WA:2!` 串无 WeakAuras 运行时 / 无游戏客户端无法离线生成，以下标记为 M1 真机待办：

- [x] **A 档自控串（`!GL:1!`）**：已离线生成 `SpeedClick.gl.txt` 并往返校验，可直接用。
- [ ] **B 档真串**：真机 WeakAuras 导出核心 / 全家桶 `!WA:2!` 串，落对应文件。
- [ ] **回环验证**：把生成的串用大厅「导入游戏字符串」入口导入 → `ParseWA` 解析成功 → 信任门弹出
      → 确认后游戏出现且可发起（无需 /reload）。
- [ ] **WA 原生导入验证**：`!WA:2!` 串能在 WeakAuras 自带导入框导入（核心/全家桶给 WA 用户用）。
- [ ] **`DecodeForPrint` 兼容性**：确认内嵌 `LibDeflate` 的 `DecodeForPrint` 与当前服 WeakAuras
      导出的 `!WA:2!` 编码同源（同 MINOR）；不同源则 `ParseWA` 的 print 模式需适配。
- [ ] **版本门控实测**：已装核心者导入全家桶 → 核心子项让位、游戏子项注册；导入更高版本游戏串 → 热升级。
