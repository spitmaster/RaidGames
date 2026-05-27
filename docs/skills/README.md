# Skills 目录

> 存放可复用的 skill，AI 可直接调用

---

## 目录说明

本目录存放各种可复用的 skill，每个 skill 是一个独立的功能模块。

---

## 新手入门

### 快速初始化 SDD 项目

```
告诉 AI：
> 初始化 SDD 项目

或：
> 注入 SDD 脚手架
```

AI 会自动从 GitHub 拉取脚手架并注入到当前项目。

详见：[sdd-init.md](./sdd-init.md)

---

## 添加新的 Skill

创建新 skill 文件，命名规范：`{skill-name}.md`

```markdown
# {Skill 名称}

## 用途
描述这个 skill 是做什么的

## 触发词
- `使用 {skill}`
- `调用 {skill}`
- `{关键词}`

## 使用方法
描述如何使用这个 skill

## 示例
```
> {示例输入}
```

## 注意事项
使用时的注意点
```

---

## 现有 Skill

| Skill | 用途 | 触发词 |
|-------|------|--------|
| [sdd-init.md](./sdd-init.md) | ⭐ SDD 脚手架初始化 | `初始化 SDD 项目`、`注入脚手架` |

---

## Skill 模板

```markdown
# {Skill 名称}

## 用途

## 触发词

## 使用方法

## 示例

## 注意事项
```

复制模板创建新 skill：`docs/skills/{你的skill名称}.md`
