# .github/copilot-instructions.md

> SDD 开发脚手架 - GitHub Copilot 配置
> 本文件由 SDD 脚手架自动生成

---

## 项目类型

SDD（Specification-Driven Development）规范驱动开发项目

---

## 开发规范

### 核心原则

1. **SPEC 是唯一真相源** - 所有需求必须来自 SPEC.md
2. **先 SPEC，后代码** - 任何修改前先确认 SPEC 中是否已定义
3. **验收标准驱动** - 实现必须满足 SPEC 中的验收标准
4. **变更必须更新 SPEC** - 代码变更前先更新 SPEC

### 工作流程

```
需求 → SPEC编写 → 开发实现 → 自测验证 → 验收确认
```

---

## 代码补全规范

### 应该补全

- [ ] 符合 SPEC 描述的功能代码
- [ ] 符合项目风格的代码
- [ ] 补充缺失的验收标准

### 不应补全

- [ ] 未在 SPEC 中定义的功能
- [ ] 与验收标准不符的代码
- [ ] 违反项目规范的内容

---

## 注释规范

使用中文注释，保持一致的风格：

```javascript
// 计算总价
function calculateTotal(items) {
  return items.reduce((sum, item) => sum + item.price, 0);
}
```

---

## 项目文档

- 详细规范：`docs/03-工作流程.md`
- 模板：`docs/templates/SPEC模板.md`
- 场景指南：`docs/06-场景指南.md`

---

*本文档由 SDD 脚手架自动生成*
