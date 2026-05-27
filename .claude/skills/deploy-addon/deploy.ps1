<#
.SYNOPSIS
    打包并部署「游戏大厅」(GameLobby) 插件到魔兽世界插件目录。
.DESCRIPTION
    1. 语法预检：若本机有 Lua 5.1，对全树 .lua 跑 loadfile，发现编译错误立即中止（不部署半成品）。
    2. 镜像部署：把 GameLobby/ 复制到 <AddOns>\GameLobby，排除开发文件（Tests/ dist/ .git 等）。
    3. 报告：版本号、复制文件数、目标路径。
.PARAMETER AddonsRoot
    游戏的 Interface\AddOns 目录。默认 I:\World of Warcraft\_classic_titan_\Interface\AddOns
.PARAMETER NoCheck
    跳过 Lua 语法预检。
.PARAMETER DryRun
    只列出将要复制/删除的文件，不实际写入。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File deploy.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File deploy.ps1 -AddonsRoot "D:\WoW\Interface\AddOns" -DryRun
#>
param(
    [string]$AddonsRoot = "I:\World of Warcraft\_classic_titan_\Interface\AddOns",
    [switch]$NoCheck,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- 路径解析 ---
# 脚本位于 <repo>\.claude\skills\deploy-addon\deploy.ps1 → 仓库根上溯 3 层
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$Source   = Join-Path $RepoRoot "GameLobby"
$AddonName = "GameLobby"
$Target   = Join-Path $AddonsRoot $AddonName

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

if (-not (Test-Path $Source)) {
    Write-Host "找不到插件源目录：$Source" -ForegroundColor Red
    exit 1
}

# --- 读取版本号（报告用）---
$tocPath = Join-Path $Source "$AddonName.toc"
$version = "?"
if (Test-Path $tocPath) {
    $m = Select-String -Path $tocPath -Pattern '##\s*Version:\s*(.+)' | Select-Object -First 1
    if ($m) { $version = $m.Matches[0].Groups[1].Value.Trim() }
}
Write-Step "插件 $AddonName v$version"
Write-Host  "    源：$Source"
Write-Host  "    目标：$Target"

# --- 1. Lua 语法预检 ---
if (-not $NoCheck) {
    Write-Step "Lua 5.1 语法预检"
    $luaCandidates = @(
        "C:\Program Files (x86)\Lua\5.1\lua.exe",
        "C:\Program Files\Lua\5.1\lua.exe"
    )
    $lua = $null
    foreach ($c in $luaCandidates) { if (Test-Path $c) { $lua = $c; break } }
    if (-not $lua) {
        $cmd = Get-Command lua -ErrorAction SilentlyContinue
        if ($cmd) { $lua = $cmd.Source }
    }
    if (-not $lua) {
        Write-Warn2 "未找到 Lua 5.1 解释器，跳过语法预检（建议 winget install DEVCOM.Lua）"
    } else {
        $luaFiles = Get-ChildItem -Path $Source -Recurse -Filter *.lua -File
        $failed = 0
        foreach ($f in $luaFiles) {
            $p = $f.FullName.Replace('\','/')
            $err = & $lua -e "local ok,e=loadfile('$p'); if not ok then io.stderr:write(e); os.exit(1) end" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    [语法错误] $($f.FullName)" -ForegroundColor Red
                Write-Host "      $err" -ForegroundColor Red
                $failed++
            }
        }
        if ($failed -gt 0) {
            Write-Host "语法预检失败：$failed 个文件有编译错误，已中止部署。" -ForegroundColor Red
            exit 1
        }
        Write-Ok "通过（$($luaFiles.Count) 个 .lua 文件）"

        # 无头集成测试（加载全插件 + 驱动 UI/状态机/线路/战绩；任一失败中止部署）
        $harnesses = @("Tests\Match_selftest.lua", "Tests\run_all.lua", "Tests\run_match.lua")
        $hfail = 0
        foreach ($h in $harnesses) {
            $hp = Join-Path $Source $h
            if (-not (Test-Path $hp)) { continue }
            $out = & $lua $hp 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    [测试失败] $h" -ForegroundColor Red
                ($out | Select-Object -Last 3) | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
                $hfail++
            } else {
                Write-Ok "测试通过 $h"
            }
        }
        if ($hfail -gt 0) {
            Write-Host "集成测试失败：$hfail 个 harness 不过，已中止部署（-NoCheck 可跳过）。" -ForegroundColor Red
            exit 1
        }
    }
}

# --- 2. 镜像部署（robocopy /MIR，排除开发文件）---
Write-Step "部署到游戏插件目录"
if (-not (Test-Path $AddonsRoot)) {
    Write-Host "找不到游戏插件根目录：$AddonsRoot" -ForegroundColor Red
    Write-Host "用 -AddonsRoot 指定正确路径。" -ForegroundColor Red
    exit 1
}

# 排除：开发用目录 + 版本控制。Tests/ 与 dist/ 不被 .toc 加载，不应进游戏。
$excludeDirs  = @("Tests", "dist", ".git", ".github")
$excludeFiles = @()  # 如需排除特定文件可加，如 "*.bak"

$rcArgs = @("`"$Source`"", "`"$Target`"", "/MIR", "/NJH", "/NJS", "/NP", "/NDL")
foreach ($d in $excludeDirs)  { $rcArgs += "/XD"; $rcArgs += "`"$(Join-Path $Source $d)`"" }
foreach ($f in $excludeFiles) { $rcArgs += "/XF"; $rcArgs += $f }
if ($DryRun) { $rcArgs += "/L" }

$rcCmd = "robocopy " + ($rcArgs -join " ")
$out = cmd /c $rcCmd 2>&1
$rc = $LASTEXITCODE

# robocopy 退出码：0-7 = 成功，>=8 = 失败
if ($rc -ge 8) {
    Write-Host "robocopy 失败（退出码 $rc）：" -ForegroundColor Red
    $out | ForEach-Object { Write-Host "    $_" }
    exit 1
}

# 统计复制/删除行
($out | Where-Object { $_ -match '\S' }) | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

if ($DryRun) {
    Write-Step "DryRun：以上为将执行的变更，未实际写入。"
} else {
    $deployed = (Get-ChildItem -Path $Target -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-Ok "部署完成：$AddonName v$version → $Target（$deployed 个文件）"
    Write-Warn2 "游戏内请 /reload 或重进游戏；首次安装需在角色选择界面『AddOns』里启用。"
}
