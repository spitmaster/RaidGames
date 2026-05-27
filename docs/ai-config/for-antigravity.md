# Antigravity 配置

> SDD 开发脚手架 - Antigravity 配置
> 本文件由 SDD 脚手架自动生成

---

## 项目类型

SDD 规范驱动开发项目

---

## 开发规范

### 核心原则

1. **SPEC 是唯一真相源**
2. **先 SPEC，后代码**
3. **验收标准驱动**
4. **变更必须更新 SPEC**

### 工作流程

```
需求 → SPEC编写 → 开发实现 → 自测验证 → 验收确认
```

---

## Antigravity 快捷命令

| 命令 | 说明 |
|------|------|
| `/sdd init` | 初始化 SDD 项目 |
| `/sdd spec` | 查看 SPEC.md |
| `/sdd validate` | 验证 SPEC 完整性 |
| `/sdd plan` | 从 SPEC 生成开发计划 |
| `/sdd review` | 代码审查 |
| `/sdd diagnose` | 项目诊断 |

---

## 开发场景

### 场景 A：有 PRD

```
/sdd load-prd docs/prd.md
```

### 场景 B：模糊想法

```
/sdd mvp 帮我做个记账应用
```

### 场景 C：已有项目

```
/sdd diagnose
```

---

## 配置同步

Antigravity 会自动读取本目录下的配置。
如需手动同步，运行：

```
/sdd sync
```

---

*本文档由 SDD 脚手架自动生成*
