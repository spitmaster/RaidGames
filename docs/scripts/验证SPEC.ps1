# SDD SPEC 验证脚本
# 用法: .\docs\scripts\验证SPEC.ps1 [-Path "SPEC.md"]

param(
    [string]$Path = "SPEC.md"
)

Write-Host "=== SDD SPEC 验证 ===" -ForegroundColor Cyan

if (-not (Test-Path $Path)) {
    Write-Host "错误: 未找到 SPEC.md 文件" -ForegroundColor Red
    exit 1
}

$content = Get-Content $Path -Raw

# 必填章节
$requiredSections = @(
    "项目概述",
    "功能需求",
    "非功能需求",
    "验收标准"
)

$missingSections = @()
foreach ($section in $requiredSections) {
    if ($content -notmatch $section) {
        $missingSections += $section
    }
}

Write-Host ""
if ($missingSections.Count -eq 0) {
    Write-Host "[OK] 所有必填章节存在" -ForegroundColor Green
} else {
    Write-Host "[MISSING] 缺失章节:" -ForegroundColor Yellow
    foreach ($section in $missingSections) {
        Write-Host "  - $section" -ForegroundColor Yellow
    }
}

# 检查验收标准
$acceptanceCriteria = Select-String -Path $Path -Pattern "\[ \]" -AllMatches
if ($acceptanceCriteria.Count -gt 0) {
    Write-Host ""
    Write-Host "[INFO] 发现 $($acceptanceCriteria.Count) 个验收标准待完成" -ForegroundColor Cyan
} else {
    Write-Host "[WARNING] 未发现验收标准" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== 验证完成 ==="
