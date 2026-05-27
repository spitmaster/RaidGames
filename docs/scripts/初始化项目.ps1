# SDD 项目初始化脚本
# 用法: .\docs\scripts\初始化项目.ps1 -ProjectName "my-app"

param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectName
)

Write-Host "=== SDD 项目初始化 ===" -ForegroundColor Cyan
Write-Host "项目名称: $ProjectName" -ForegroundColor Yellow

# 创建项目目录
$projectPath = Join-Path (Get-Location) $ProjectName
if (Test-Path $projectPath) {
    Write-Host "项目已存在!" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $projectPath -Force | Out-Null

# 创建标准目录结构
$dirs = @("src", "tests", "docs", "config")
foreach ($dir in $dirs) {
    New-Item -ItemType Directory -Path (Join-Path $projectPath $dir) -Force | Out-Null
}

# 创建 SPEC.md
$specContent = @"
# $ProjectName 项目规格说明书

> 最后更新: $(Get-Date -Format "yyyy-MM-dd")

## 1. 项目概述

- **项目名称**: $ProjectName
- **项目简介**:
- **目标用户**:
- **项目背景**:

## 2. 功能需求

### 功能 1: [功能名称]

- **描述**:
- **验收标准**:
  - [ ]

## 3. 非功能需求

- **性能要求**:
- **安全要求**:
- **兼容性要求**:

## 4. UI/UX 规范

## 5. 技术架构

## 6. API 设计

## 7. 验收标准

- [ ]

---

*本文档使用 SDD 方法论编写*
"@

$specPath = Join-Path $projectPath "SPEC.md"
Set-Content -Path $specPath -Value $specContent -Encoding UTF8

Write-Host ""
Write-Host "=== 初始化完成 ===" -ForegroundColor Green
Write-Host "项目路径: $projectPath"
Write-Host ""
Write-Host "下一步:"
Write-Host "  1. cd $ProjectName"
Write-Host "  2. 编辑 SPEC.md"
Write-Host "  3. 开始开发"
