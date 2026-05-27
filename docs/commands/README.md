# Claude Code Commands

> Claude Code 自定义命令集合

---

## 目录说明

本目录存放 Claude Code 可用的自定义 `/命令`。

### 添加命令

将命令文件复制到 Claude Code 命令目录：

**Windows:**
```bash
copy docs\commands\sdd-starter.md %USERPROFILE%\.claude\commands\
```

**Mac/Linux:**
```bash
cp docs/commands/sdd-starter.md ~/.claude/commands/
```

---

## 现有命令

| 命令文件 | 说明 | 使用方式 |
|----------|------|----------|
| [sdd-starter.md](./sdd-starter.md) | SDD 脚手架初始化 | `/sdd-starter` |

---

## 命令模板

```markdown
# 命令名称

描述这个命令做什么

## 执行步骤

1. 步骤1
2. 步骤2

## 示例输出

预期输出结果
```
