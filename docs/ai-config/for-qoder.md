# Qoder 配置

> SDD 开发脚手架 - Qoder 配置
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

---

## Qoder 集成

### 自动加载

Qoder 启动时会自动检测 `AGENTS.md` 并加载 agents。

### 手动触发

```
> @SDD-Developer 开始开发
> @SDD-Reviewer 审查代码
> @SDD-Validator 验证 SPEC
```

---

## 项目结构

```
docs/
├── 01-使用说明.md              # 快速开始
├── 03-工作流程.md              # 开发流程
├── 06-场景指南.md              # 三种开发场景
└── templates/SPEC模板.md       # SPEC 模板
```

---

## 快捷指令

- `sdd:init` - 初始化 SDD 项目
- `sdd:spec` - 打开 SPEC.md
- `sdd:validate` - 验证 SPEC
- `sdd:plan` - 生成开发计划

---

*本文档由 SDD 脚手架自动生成*
