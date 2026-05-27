# SDD 脚手架初始化

执行 SDD（规范驱动开发）脚手架初始化流程。

## 执行步骤

### 1. 检测当前环境

检查以下内容：
- 当前工作目录
- 是否已有 `docs/` 目录
- 是否已有 `olddocs/` 目录
- 是否已有 `.git` 仓库

### 2. 询问用户需求

询问用户：
```
是否需要迁移现有文档到 olddocs/？
- [1] 是，我有老项目文档需要迁移
- [2] 否，新项目直接使用
```

### 3. 执行脚手架注入

使用临时目录克隆脚手架（不影响当前项目 git）：

```bash
GIT_URL="https://github.com/spitmaster/sdd-starter.git"
BRANCH="main"
TEMP_DIR=$(mktemp -d)

git clone --depth 1 --branch $BRANCH $GIT_URL $TEMP_DIR
```

### 4. 复制文件

根据用户选择复制：
- `README.md` → 项目根目录
- `docs/` → 项目根目录（合并，不覆盖已有）
- `olddocs/` → 项目根目录（用户选择迁移时）

### 5. 清理

```bash
rm -rf $TEMP_DIR
```

### 6. 引导初始化

告诉用户：
```
✅ SDD 脚手架注入完成！

📁 已创建/更新：
- README.md
- docs/ 目录

下一步请告诉 AI：
> 请初始化 AI 环境

或直接：
> 请查看 docs/01-使用说明.md
```

## 注意事项

- 使用临时目录克隆，不污染当前项目 .git
- 不覆盖用户已有内容
- 支持 Windows (PowerShell) 和 Mac/Linux (Bash)
