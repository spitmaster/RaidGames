# 代码可视化阅读器 — 项目层文档

> 项目代号:**codeviz**(代码可视化阅读器)
> 目标:读取任意源码库,生成一个 3D 空间,让程序员能像看流水一样观察"业务从一个 IO 入口出发,经过哪些函数、读写哪些表、操作哪些文件系统"。
> 本文件是 codeviz 项目的"项目层"入口——agent 编排、中间表示 schema、红线、里程碑路径都在这里。

---

## 一句话定位

把 AI 对代码的语义理解 + 静态分析 + 3D 可视化,组合成一种**"业务流水"级别的代码阅读体验**——选一个 endpoint / 按钮 / CLI 命令,系统在 3D 空间里把这次业务的完整数据流转放映出来。

差异化的核心**不是 3D**(那是表现层),而是 **"AI 把代码翻译成业务语言 + 流水追踪 + IO 入口驱动"** 三者的组合。

---

## 双层架构:通用 agent + 项目编排

```text
┌──────────────────────────────────────────────────────────┐
│  项目层(codeviz 专属,本目录)                            │
│                                                          │
│    codeviz-orchestrator.md  — 编排、契约注入、联调       │
│    codeviz-overview.md     — 本文档:schema、红线、路径   │
│                                                          │
└──────────────────────────────────────────────────────────┘
                          ▼ 注入项目契约
┌──────────────────────────────────────────────────────────┐
│  通用领域 agent(跨项目复用,本目录)                       │
│                                                          │
│    static-code-analyzer       │  business-translator      │
│    io-entry-mapper            │  3d-rendering-engineer    │
│    dataflow-tracer            │  3d-interaction-designer  │
│    fixture-validator          │                          │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**关键原则**:

- 通用 agent 不知道"codeviz"是什么。它们等 orchestrator 下发任务时,从项目 overview 读取本项目的 schema 与红线
- 下次做新项目(代码搜索、重构辅助、API 文档生成),**只写新项目的 orchestrator + overview**,复用同一批通用 agent
- 项目层文档(本文件)是通用 agent 与项目对话的"协议文档"

---

## 通用 agent → codeviz 角色映射

| 通用 Agent | 在 codeviz 中的角色 | 产出 |
| ---------- | ------------------- | ---- |
| [static-code-analyzer](./static-code-analyzer.md) | 代码事实抽取 | SymbolGraph |
| [io-entry-mapper](./io-entry-mapper.md) | IO 入口识别 | IOEntryRegistry |
| [dataflow-tracer](./dataflow-tracer.md) | 单入口数据流追踪 | FlowGraph(每入口一份) |
| [business-translator](./business-translator.md) | 中文业务翻译 | BusinessAnnotations |
| [3d-rendering-engineer](./3d-rendering-engineer.md) | 3D 场景渲染 | 嵌入式 3D 组件 |
| [3d-interaction-designer](./3d-interaction-designer.md) | 3D 交互/导航 | 周边 UI 组件 |
| [fixture-validator](./fixture-validator.md) | 夹具 + e2e 回归 | 夹具项目 + ground-truth + 报告 |

---

## 拓扑与数据流

```text
                       ┌─────────────────────────────┐
                       │  codeviz-orchestrator (调度)  │
                       └──────────────┬──────────────┘
                                      │ 注入契约
        ┌─────────────────┬───────────┼───────────┬────────────────┐
        ▼                 ▼           ▼           ▼                ▼
  ┌──────────┐    ┌─────────────┐ ┌───────┐  ┌─────────────┐  ┌──────────┐
  │ 静态分析  │    │  IO 入口     │ │ 数据流 │  │  业务翻译     │  │ 夹具验证  │
  │          │    │             │ │       │  │              │  │          │
  └────┬─────┘    └──────┬──────┘ └───┬───┘  └──────┬──────┘  └──────────┘
       │                 │             │             │
       └─────────────────┴─────────────┴─────────────┘
                         │
                         ▼ 中间表示(JSON)
                         │
        ┌────────────────┴──────────────────┐
        ▼                                   ▼
  ┌──────────────────┐              ┌──────────────────┐
  │ 3D 渲染           │              │ 3D 交互           │
  └──────────────────┘              └──────────────────┘
```

**单向数据流**:

- 后端 agent 只产出 JSON 中间表示
- 前端 agent 只消费 JSON,不反向修改
- orchestrator 是唯一允许跨层协调的角色

---

## 项目特定的中间表示(schema 草案)

通用 agent 等本文档定义具体 schema 后再开工。schema 版本号必须显式声明,变更需 orchestrator + 用户共同同意。

### SymbolGraph(static-code-analyzer 产出)

```json
{
  "schemaVersion": "0.1.0",
  "rootPath": "...",
  "languages": ["typescript", "python"],
  "frameworks": [{"name": "express", "version": "4.x", "confidence": "high"}],
  "symbols": [
    {
      "id": "ts:src/order/service.ts#OrderService.create",
      "kind": "method",
      "name": "create",
      "qualifiedName": "OrderService.create",
      "filePath": "src/order/service.ts",
      "range": {"startLine": 12, "endLine": 30},
      "signature": "(input: CreateOrderDto) => Promise<Order>",
      "visibility": "public",
      "decorators": ["@Injectable"],
      "tags": ["async"]
    }
  ],
  "calls": [
    {
      "callerId": "...",
      "calleeId": "...",
      "callKind": "direct|virtual|dynamic|framework-injected",
      "fileLocation": {"file": "...", "line": 20},
      "confidence": "high|medium|low"
    }
  ],
  "frameworkPoints": [
    {
      "kind": "decorator|annotation|convention",
      "framework": "express",
      "symbolId": "...",
      "meaning": "route-registration",
      "raw": "@Get('/orders')"
    }
  ],
  "dataAccessPoints": [
    {
      "kind": "orm-call|raw-sql|file-io|http-call|queue-publish",
      "symbolId": "...",
      "target": "orders table",
      "operation": "read|write|delete",
      "fileLocation": {"file": "...", "line": 25},
      "confidence": "high|medium|low"
    }
  ]
}
```

ID 命名:`<lang>:<path>#<qualifiedName>`,跨 agent 稳定。

### IOEntryRegistry(io-entry-mapper 产出)

```json
{
  "schemaVersion": "0.1.0",
  "entries": [
    {
      "id": "io:http:POST:/api/orders",
      "kind": "http|frontend-event|cli|queue|cron|websocket",
      "displayName": "POST /api/orders",
      "framework": "nestjs",
      "handlerSymbolId": "ts:src/order/controller.ts#OrderController.create",
      "metadata": {
        "httpMethod": "POST",
        "path": "/api/orders",
        "paramsSchemaSymbolId": "ts:src/order/dto.ts#CreateOrderDto"
      },
      "group": "订单",
      "confidence": "high"
    }
  ]
}
```

### FlowGraph(dataflow-tracer 产出,每入口一份)

```json
{
  "schemaVersion": "0.1.0",
  "entryId": "io:http:POST:/api/orders",
  "nodes": [
    {
      "id": "n1",
      "kind": "function|table|file|external-api|queue|response|input",
      "label": "OrderController.create",
      "symbolId": "...",
      "depth": 1
    }
  ],
  "edges": [
    {
      "id": "e1",
      "from": "n1",
      "to": "n2",
      "kind": "call|read|write|delete|publish|http-call|return|input-bind",
      "confidence": "high",
      "metadata": {"line": 25}
    }
  ],
  "cycles": [["n3", "n4", "n3"]],
  "truncations": [{"at": "n7", "reason": "depth-limit-reached"}]
}
```

### BusinessAnnotations(business-translator 产出,每入口一份)

```json
{
  "schemaVersion": "0.1.0",
  "entryId": "io:http:POST:/api/orders",
  "narrative": "用户提交订单请求后,系统校验库存,扣减库存,创建订单记录,并通知支付服务。最终返回订单 ID 给前端。",
  "narrativeConfidence": "high",
  "nodeAnnotations": [
    {
      "nodeId": "n1",
      "businessLabel": "创建订单接口",
      "businessDescription": "接收下单请求,协调库存校验、订单写入和支付通知",
      "confidence": "high",
      "evidence": ["docstring: 创建订单", "function signature: create(input: CreateOrderDto)"]
    }
  ],
  "edgeAnnotations": [
    {
      "edgeId": "e3",
      "businessLabel": "写入订单",
      "confidence": "high",
      "evidence": ["prisma.order.create call"]
    }
  ]
}
```

---

## 红线(项目级架构不变量)

任何 agent 动手前必须扫一眼:

1. **后端 agent 不允许直接生成可视化代码** — 必须产出中间表示,3D 渲染交给前端 agent
2. **业务翻译禁止臆造** — LLM 翻译只能基于已抽取的代码事实,evidence 为空拒绝采用,猜测必须标 `confidence=low`
3. **3D 不是包装 2D** — 如果一个交互在 2D 节点图里更高效,就不要强行做成 3D
4. **支持的语言/框架显式声明** — 不允许"尽力而为"地分析未声明支持的语言
5. **目标项目源码只读** — 任何 agent 都不允许修改用户输入的目标代码库
6. **中间表示有 schema 版本号** — agent 之间传递的 JSON 必须有版本号与 schema 校验,不允许临时字段

---

## 启动依赖顺序(三阶段)

**阶段 1 — 打通主链路**(优先级最高,验证项目可行性):

1. static-code-analyzer 跑通 TypeScript(没有 AST 一切免谈)
2. io-entry-mapper 锁定 HTTP endpoint(只这一种)
3. dataflow-tracer 跟着 endpoint 追踪一条链路
4. business-translator 把链路翻译成中文业务流
5. fixture-validator 准备最小测试项目(React + Express + Prisma)验证准确率

✅ **里程碑 M1**:给定一个 endpoint,输出一份准确的中文业务流文本(2D 也行,先不上 3D)。
**这一步过不了,3D 没意义,先解决 AI 翻译质量**。

**阶段 2 — 加上 3D 表达**:

1. 3d-rendering-engineer 把中间表示渲染成 3D 场景
2. 3d-interaction-designer 解决 3D 导航与防迷路

✅ **里程碑 M2**:浏览器里能看到流水动画。

**阶段 3 — 扩展覆盖面**:

1. 扩展第二/第三种语言/框架,fixture-validator 持续扩夹具

---

## codeviz 当前支持矩阵(初始)

| 语言 | 框架 | 数据访问 | 状态 |
| ---- | ---- | -------- | ---- |
| TypeScript | React | — | 阶段 1 目标 |
| TypeScript | Express / NestJS | Prisma | 阶段 1 目标 |
| Python | FastAPI | SQLAlchemy | 阶段 3 |
| Java | Spring | MyBatis / JPA | 阶段 3 |

支持矩阵的扩展必须先建夹具,再开发 — 见 fixture-validator 红线。

---

## 与现有 SDD 体系的关系

本项目继承 `~/.claude/CLAUDE.md` v1.3 的文档规范,真正动工时:

- `docs/roadmap.md` — 功能边界(支持哪些语言/框架,不支持什么)
- `docs/milestones.md` + `docs/milestones/<branch>.md` — 里程碑跟踪
- `docs/todo/<branch>.md` — 当前 M 的具体动作
- `docs/design.md` — 沉淀中间表示 schema 与各 agent 在本项目的契约扩展

---

## 如何复用这套架构搭新项目

这套"通用 agent + 项目编排"是一个模板。下次搭新项目(例如"代码搜索"、"重构辅助"、"API 文档生成器"):

1. 在 `docs/agents/` 下写 `<新项目>-orchestrator.md` 和 `<新项目>-overview.md`
2. 在 overview 里:
   - 定义本项目的 agent 角色映射(通用 agent → 本项目角色)
   - 定义本项目的中间表示 schema
   - 定义本项目的红线与里程碑路径
3. **不要**改通用 agent 文件去满足新项目的需求 — 项目特定需求通过 orchestrator 注入,通用 agent 保持通用

---

## 修订日志

| 日期 | 修订 |
| ---- | ---- |
| 2026-05-18 | 重构为双层架构(通用 agent + 项目编排)。原 7 个 `codeviz-*` 专职 agent 改为通用 agent,项目特定细节移到本文件 |
| 2026-05-18 | 初稿。8 agent 体系 + 3 阶段搭建路径 + 4 个中间表示契约 |
