# SDD 脚手架初始化

## 用途

将 SDD（规范驱动开发）脚手架快速注入到当前项目，自动完成：
1. 从 GitHub 拉取脚手架到临时目录
2. 选择性复制脚手架内容到当前项目
3. 清理临时目录（不污染当前项目的 git）
4. 引导用户完成 AI 环境初始化

## 触发词

- `初始化 SDD 项目`
- `注入 SDD 脚手架`
- `使用 SDD 模板`
- `设置开发规范`
- `SDD init`

## 使用方法

### 1. 检测当前环境

```
检查以下内容：
- 当前工作目录
- 是否已有 docs/ 目录
- 是否已有 olddocs/ 目录
- 是否已有 .git 仓库
```

### 2. 询问用户需求

```
在执行前，询问用户：
1. 是否需要迁移现有文档到 olddocs/？
   - 如果用户有老项目文档，选择性复制到 olddocs/
   
2. 脚手架复制范围：
   - [1] 仅核心文件（docs/ + README.md）
   - [2] 完整复制（包含 scripts、templates 等）
   - [3] 自定义选择
```

### 3. 执行脚手架注入

```bash
# 脚手架仓库
GIT_URL="https://github.com/spitmaster/sdd-starter.git"
BRANCH="main"

# 创建临时目录
TEMP_DIR=$(mktemp -d)
echo "临时目录: $TEMP_DIR"

# 克隆到临时目录
git clone --depth 1 --branch $BRANCH $GIT_URL $TEMP_DIR

# 根据用户选择复制文件
# ... (见下方详细步骤)

# 删除临时目录
rm -rf $TEMP_DIR
echo "临时目录已清理"
```

### 4. 复制规则

#### 4.1 核心文件（必须）

| 源文件 | 目标位置 | 说明 |
|--------|----------|------|
| `README.md` | 项目根目录 | 覆盖或新建 |
| `docs/` | 项目根目录 | 合并（不覆盖已有内容）|

#### 4.2 可选文件

| 源文件 | 目标位置 | 条件 |
|--------|----------|------|
| `olddocs/` | 项目根目录 | 用户选择迁移文档时 |
| `docs/templates/` | docs/ | 用户选择完整复制时 |
| `docs/scripts/` | docs/ | 用户选择完整复制时 |
| `docs/example/` | docs/ | 用户选择完整复制时 |

#### 4.3 不复制

以下文件**不复制**，避免干扰：
- `.git/` 目录
- `node_modules/`（如有）
- 脚手架自身的 `.git/` 引用

### 5. 处理冲突

```
如果目标文件已存在：
1. 不覆盖用户已有内容
2. 询问是否合并或保留现有版本
3. 合并时在文件头部添加注释说明
```

### 6. 引导初始化

复制完成后，执行：

```
告诉用户：
> SDD 脚手架注入完成！
> 
> 📁 已创建/更新：
> - README.md
> - docs/ 目录
> 
> 下一步请告诉 AI：
> > 请初始化 AI 环境
> 
> 或直接：
> > 请查看 docs/01-使用说明.md
```

## 详细执行步骤

### PowerShell 版本（Windows）

```powershell
$gitUrl = "https://github.com/spitmaster/sdd-starter.git"
$branch = "main"
$tempDir = [System.IO.Path]::GetTempPath() + "sdd-clone-" + (Get-Random)

# 克隆到临时目录
git clone --depth 1 --branch $branch $gitUrl $tempDir

# 复制核心文件
Copy-Item "$tempDir\README.md" "." -Force
Copy-Item "$tempDir\docs" "docs" -Recurse -Force

# 清理临时目录
Remove-Item $tempDir -Recurse -Force
```

### Bash 版本（Mac/Linux）

```bash
#!/bin/bash
GIT_URL="https://github.com/spitmaster/sdd-starter.git"
BRANCH="main"
TEMP_DIR=$(mktemp -d)

git clone --depth 1 --branch $BRANCH $GIT_URL $TEMP_DIR

cp "$TEMP_DIR/README.md" .
cp -r "$TEMP_DIR/docs" .

rm -rf $TEMP_DIR
```

## 完整示例对话

```
用户: > 初始化 SDD 项目

AI: 检测当前环境...
   - 工作目录：/path/to/my-project
   - 无 .git 仓库
   - 无 docs/ 目录
   
   是否需要迁移现有文档到 olddocs/？
   - [1] 是，我有老项目文档
   - [2] 否，新项目直接使用

用户: > 2

AI: 好的，开始注入 SDD 脚手架...
   
   ✅ 克隆完成（临时目录）
   ✅ 复制 README.md
   ✅ 复制 docs/ 目录
   ✅ 清理临时目录
   
   📁 项目结构：
   my-project/
   ├── README.md
   └── docs/
       ├── 01-使用说明.md
       ├── 02-SDD方法论.md
       └── ...
   
   🎉 SDD 脚手架注入完成！
   
   下一步请告诉 AI：
   > 请初始化 AI 环境
```

## 注意事项

1. **不影响 git 仓库**：使用临时目录，不会污染当前项目的 .git/
2. **不覆盖已有内容**：优先保留用户已有的文档
3. **兼容性**：支持 Windows (PowerShell) 和 Mac/Linux (Bash)
4. **网络要求**：需要能访问 github.com
5. **Git 要求**：需要本地安装 git
