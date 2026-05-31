# dist/ — 可分享的游戏字符串（`!GL:`）产物与生成

> 真相源是仓库里的 `.lua`（`Core/`、`Games/`、`Libs/`）。本目录的 `.txt` 是**生成产物**。
> 串与代码不一致时**重新生成串**，不要手改串。
>
> **注：WeakAuras 整包分发路线已于 2026-05-31 暂停（见 `requirements.md` D19）** —— 完整核心当纯 WA 跑会被 WA 沙箱拦截（`loadstring`/`/命令`/命名框架/SavedVariables 全禁）。本项目走**插件路线**：核心当插件装一次，**小游戏靠 `!GL:` 串 / 右键聊天推送在插件之间传播**。原 WA 打包脚手架（`build_bundle.py`/`verify_bundle.lua`/`HOW-TO-EXPORT-BUNDLE.md`/`*.wa.txt`/`_bundle-*.paste.txt`）已删除，需要时从 git 历史或重新开发恢复。

## 本目录内容

| 文件 | 内容 | 给谁 / 怎么用 |
|------|------|------|
| `SpeedClick.gl.txt` ✅即用 | 极速按键的自控游戏载荷（`!GL:1!` 串） | 已装核心的人：大厅「**+ 导入游戏**」框粘入 → 信任确认 → 即玩。离线生成 + `ParseWA` 往返校验（`code` 字节一致）。 |
| `export-tool.lua` | 离线把游戏 def 源码打包成 `!GL:1!` 串的工具 | 做新游戏时离线生成可分享串（无需进游戏） |

> 大厅内**也能直接产串**：右键游戏格 →「导出字符串」，或左上「分享游戏」按钮。`export-tool.lua` 是其离线等价物。

## 三个传播入口（插件↔插件，都已实现）

1. **右键参赛者卡 → 推送游戏**（`GL.Push:SendGame`，分片 WHISPER 即时直推；接收端信任门确认后即玩）。
2. **左上「分享游戏」按钮** → 选游戏 → 导出 `!GL:` 串供 Ctrl+C 发出。
3. **右键游戏格 → 导出字符串** → 同 2，另一入口。

收发都被 `Core/GameImport.lua` 的 `ParseWA` 支持：`!GL:1!` → `LibBase64.Decode` → `DecompressDeflate` → `LibSerialize:Deserialize`（本项目自控裸串，零 WeakAuras 耦合）。`!WA:2!` 前缀也兼容解析，但本项目不再主动生产 WA 串。

## 自控载荷结构（导出端 ↔ 解析端唯一契约）

反序列化后必有一个**自控载荷表**：

```lua
payload = {
  __gl    = true,            -- 魔法标记，识别「这是游戏大厅载荷」（必填）
  kind    = "game",          -- "game" 单游戏 | "bundle" 聚合（子项在 items）
  id      = "speedclick",    -- 游戏 id（kind=game 必填）
  name    = "极速按键",       -- 展示名（可选）
  version = "1.0.0",         -- 游戏版本（可选；权威以 def 内为准）
  coreMin = "0.1.0",         -- 需要的最低核心版本（可选；不满足给「请升级核心」提示）
  source  = "RaidGames 官方", -- 来源标识（喂给信任门展示给用户）
  code    = "return { id=..., client=function(ctx,api) ... end }",  -- 游戏 Lua 源码（必填，loadstring 后须 return def）
  items   = { payload, ... }, -- 仅 kind=bundle：子载荷数组
}
```

> 字段名 `__gl` / `gameLobby` 与 `kind/id/version/coreMin/source/code` 是冻结契约。
> 改字段必须同步改 `Core/GameImport.lua`（`MAGIC` / `PAYLOAD_FIELD` / 探测逻辑）+ `export-tool.lua`。

## 生成 `!GL:1!` 游戏串（离线，`export-tool.lua`）

1. 装好「游戏大厅」插件（`Libs/` 内嵌库已就绪）。
2. 把 `export-tool.lua` 内容贴进临时执行环境，或 `/run`。
3. 准备游戏 def 源码字符串（`Games/<game>.lua` 的 `SOURCE`，即 `return def` 形态）。
4. 执行：
   ```lua
   /run GameLobby_Export.Game("speedclick", [[ <return def 源码> ]], {name="极速按键", version="1.0.0", coreMin="0.1.0"})
   ```
5. 复制打印的 `!GL:1!....` 整行，替换对应 `.gl.txt`。

> 多游戏聚合：`GameLobby_Export.Bundle({ {id=..,code=..,meta=..}, ... })`。
> `gen_smashball.py` 是仓库既有的未跟踪脚本，与本分发流程无关，未纳入本说明。
