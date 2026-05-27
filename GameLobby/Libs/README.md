# Libs — 内嵌第三方库

> 架构不变量 #5：**不依赖大脚 / BigFoot**。本目录把所有运行所需库内嵌进插件，独立可用。
> WeakAuras 自带 LibSerialize / LibDeflate / LibStub；同体（WA）场景下 Phase 2 的 `GameImport`
> 会优先探测 WeakAuras 提供的实例，插件场景则用本目录的内嵌版。两侧 API 一致。

## 清单

| 库 | 版本 | 许可 | 来源 | 用途 | 改动 |
|----|------|------|------|------|------|
| `LibStub/LibStub.lua` | r2 | Public Domain | WowAce 社区标准版 | 库版本注册/取用框架 | 原样，仅加中文注释头 |
| `LibBase64/LibBase64.lua` | 1.0（ckknight） | MIT | 复用自 `sample/BiaoGe/Libs/LibBase64` | base64 编解码（WA 串解析） | 改为暴露到 `_G.GameLobby_Lib.Base64`（原版用 addon vararg ns），逻辑未动 |
| `ChatThrottleLib/ChatThrottleLib.lua` | 24 | Public Domain | WowAce 社区标准版（Mikk） | addon message 节流，避免被踢线 | 原样移植；`SendAddonMessage` 内部优先 `C_ChatInfo.SendAddonMessage`，回退旧版全局 |
| `LibDeflate/LibDeflate.lua` | 1.0.2-release（MINOR 3） | zlib License | https://github.com/SafeteeWoW/LibDeflate `master` | DEFLATE 压缩/解压（WA 串） | 原样，未改 |
| `LibSerialize/LibSerialize.lua` | MAJOR=LibSerialize MINOR=5 | MIT | https://github.com/rossnichols/LibSerialize `main` | Lua 表序列化/反序列化（WA 串） | 原样，未改 |

## 取用方式

```lua
local Base64       = _G.GameLobby_Lib and _G.GameLobby_Lib.Base64   -- 自挂全局
local ChatThrottle = _G.ChatThrottleLib                              -- 自挂全局
local LibStub      = _G.LibStub
local LibDeflate   = LibStub and LibStub("LibDeflate", true)         -- 经 LibStub 取用
local LibSerialize = LibStub and LibStub("LibSerialize", true)
```

## 加载顺序（embeds.xml）

```
LibStub → LibBase64 → ChatThrottleLib → LibDeflate → LibSerialize
```

`LibDeflate` / `LibSerialize` 依赖 `LibStub` 已就绪才能注册，故 LibStub 必须最先。

## 协议字节级一致（架构不变量 #4）的影响面

- 本阶段 **`Comm` 的逗号编解码协议不经过 base64/deflate/serialize**，纯文本走 addon message。
- LibSerialize / LibDeflate / LibBase64 仅用于 **Phase 2 的 WA 串导入导出**（游戏代码的打包/解包），
  与同场互通的通讯协议无关——通讯协议永远是明文 `命令,arg1,arg2,...`。
