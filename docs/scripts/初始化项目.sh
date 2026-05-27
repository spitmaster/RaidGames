#!/bin/bash
# SDD 项目初始化脚本
# 用法: ./docs/scripts/初始化项目.sh my-app

PROJECT_NAME=$1

if [ -z "$PROJECT_NAME" ]; then
    echo "用法: $0 <项目名称>"
    exit 1
fi

echo "=== SDD 项目初始化 ==="
echo "项目名称: $PROJECT_NAME"

# 创建项目目录
PROJECT_PATH="./$PROJECT_NAME"
if [ -d "$PROJECT_PATH" ]; then
    echo "项目已存在!"
    exit 1
fi

mkdir -p "$PROJECT_PATH"/{src,tests,docs,config}

# 创建 SPEC.md
cat > "$PROJECT_PATH/SPEC.md" << 'EOF'
# %PROJECT_NAME% 项目规格说明书

> 最后更新: %DATE%

## 1. 项目概述

- **项目名称**: %PROJECT_NAME%
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
EOF

# 替换占位符
DATE=$(date +%Y-%m-%d)
sed -i "s/%PROJECT_NAME%/$PROJECT_NAME/g" "$PROJECT_PATH/SPEC.md"
sed -i "s/%DATE%/$DATE/g" "$PROJECT_PATH/SPEC.md"

echo ""
echo "=== 初始化完成 ==="
echo "项目路径: $PROJECT_PATH"
echo ""
echo "下一步:"
echo "  1. cd $PROJECT_NAME"
echo "  2. 编辑 SPEC.md"
echo "  3. 开始开发"
