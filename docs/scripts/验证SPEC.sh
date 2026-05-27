#!/bin/bash
# SDD SPEC 验证脚本
# 用法: ./docs/scripts/验证SPEC.sh [SPEC.md]

SPEC_PATH=${1:-"SPEC.md"}

echo "=== SDD SPEC 验证 ==="

if [ ! -f "$SPEC_PATH" ]; then
    echo "错误: 未找到 SPEC.md 文件"
    exit 1
fi

# 必填章节
REQUIRED_SECTIONS=("项目概述" "功能需求" "非功能需求" "验收标准")

MISSING=()
for section in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -q "$section" "$SPEC_PATH"; then
        MISSING+=("$section")
    fi
done

echo ""
if [ ${#MISSING[@]} -eq 0 ]; then
    echo "[OK] 所有必填章节存在"
else
    echo "[MISSING] 缺失章节:"
    for section in "${MISSING[@]}"; do
        echo "  - $section"
    done
fi

# 检查验收标准
CRITERIA_COUNT=$(grep -c "\[ \]" "$SPEC_PATH" 2>/dev/null || echo "0")
echo ""
echo "[INFO] 发现 $CRITERIA_COUNT 个验收标准"

echo ""
echo "=== 验证完成 ==="
