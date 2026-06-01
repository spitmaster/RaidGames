---
name: deploy-addon
description: 打包并部署「游戏大厅」(GameLobby) 插件到魔兽世界时光服插件目录。先跑 Lua 5.1 语法预检，通过后镜像复制 GameLobby/ 到游戏 AddOns 目录（排除 Tests/ dist/ 等开发文件）。当用户说「部署插件 / 打包部署 / 装到游戏里 / deploy / 更新游戏里的插件」时使用。
---

# 部署游戏大厅插件

把仓库里的 `GameLobby/` 插件部署到魔兽世界插件目录，让改动能在游戏里生效。

## 游戏插件目录（多机自动检测）

脚本内置候选路径列表 `$KnownRoots`（用户有多台电脑）：

```
E:\games\World of Warcraft\_classic_titan_\Interface\AddOns   # 公司电脑
I:\World of Warcraft\_classic_titan_\Interface\AddOns          # 家里电脑
```

**不传 `-AddonsRoot` 时**：自动部署到**当前这台机器上存在的所有**候选路径（用 `Test-Path` 检测，不存在的自动跳过）。所以换电脑啥都不用改，跑同一条命令即可。
部署目标即 `<某个候选目录>\GameLobby`。新增机器：在 `deploy.ps1` 的 `$KnownRoots` 加一行。

## 怎么做

直接运行本 skill 目录下的部署脚本（PowerShell 工具）：

```powershell
powershell -ExecutionPolicy Bypass -File .claude\skills\deploy-addon\deploy.ps1
```

脚本会依次：
1. **Lua 5.1 语法预检** —— 用本机 lua.exe（见 memory `lua51-test-runner`）对全树 `.lua` 跑 `loadfile`；**任一文件编译失败就中止，不部署半成品**。没装 Lua 则跳过并提示。
2. **镜像部署** —— `robocopy /MIR` 把 `GameLobby/` 同步到目标目录，**排除** `Tests/`、`dist/`、`.git/`（这些不被 `.toc` 加载，不该进游戏）。`/MIR` 会清掉目标里多余的旧文件，保证干净。
3. **报告** —— 版本号、文件数、目标路径，并提醒游戏内 `/reload`。

## 常用参数

- 只部署到某一个目录（覆盖自动检测）：`-AddonsRoot "D:\WoW\...\Interface\AddOns"`
- 只预览不写入：`-DryRun`（先看会复制/删除什么）
- 跳过语法检查：`-NoCheck`（不建议）

例：
```powershell
powershell -ExecutionPolicy Bypass -File .claude\skills\deploy-addon\deploy.ps1 -DryRun
```

## 执行后

- 运行脚本，把脚本的输出（版本/文件数/是否有语法错误）如实转述给用户。
- 若语法预检失败，**不要**绕过去强行部署——先把报错的文件和行号告诉用户，修好再部署。
- 部署成功后提醒：游戏内 `/reload`，或首次安装需在角色选择界面 AddOns 列表启用「游戏大厅」。

## 边界

- 这只做「源码 → 游戏目录」的部署。它**不**生成 `dist/` 的 WeakAuras 分发字符串（那是另一条需游戏内 WeakAuras 半自动导出的流程，见 `GameLobby/dist/README.md`）。
- 不改版本号。要发版时先手动改 `GameLobby/GameLobby.toc` 的 `## Version`，再部署。
