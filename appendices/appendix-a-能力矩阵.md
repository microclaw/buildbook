# Appendix A 能力矩阵

## 目标

把 MicroClaw 与同生态位的开源 Agent Runtime（NanoClaw、OpenClaw、Moltis、NanoBot、ZeroClaw、NullClaw）放进同一张能力矩阵，把每个项目的工程事实摊开，让读者按自己的工程约束做选择，而不是按"功能多少"或主观印象做判断。

判断原则只有一个：先列约束，再读矩阵；不要倒过来。

## 一页对照（v0.1.57 时间点）

| 项目 | 主语言 | 架构形态 | 状态持久化 | 渠道数量 | 工具系统 | 子代理 | 并发模型 | 扩展机制 | 可观测性 | 审批 / 风险分级 | 安全机制 | 运维形态 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| MicroClaw v0.1.57 | Rust | 单进程 + 8 workspace crate | SQLite（schema v25+） | 15（Telegram/Discord/Slack/Feishu/Email/IRC/Web/Matrix/Weixin/DingTalk/Signal/WhatsApp/Nostr/iMessage/QQ） | 统一 ToolRegistry，约 50 个内置工具 | session-native + ACP 双模式 | wave-based（ReadOnly 并行 / SideEffect 串行 / Exclusive 独占） | MCP / Skills / Plugins / Hooks / A2A / ACP | OTLP metrics + traces + logs | High / Medium / Low 三级 + 配置门 | path/url 校验 + Docker/OCI sandbox + 控制面鉴权 + Hooks 拦截 | Gateway（launchd/systemd/Win 服务）+ doctor + setup wizard + Web 控制面 |
| OpenClaw | TypeScript | 平台 / 控制平面 | 平台数据库 | 多端覆盖较广 | 插件化工具集 | 平台级编排 | 平台调度为主 | 插件 + 控制平面 API | 平台监控 | 平台权限模型 | 平台鉴权 + 隔离 | 控制平面 + 多端运维 |
| NanoClaw | Node.js / TS | 单进程极简主干 | 文件 / 轻量 DB | 较少（聚焦核心） | Skills 驱动定制 | 简洁子任务 | 串行为主 | Skills + MCP | 基础日志 | 基础风险标记 | 容器隔离默认姿态 | CLI + 容器 |
| Moltis | Rust | 多 crate 模块化平台 | 平台级（含外存） | 多渠道，分层细 | 分模块工具集 | 平台编排 | 平台调度 | Channels / MCP / Skills 细分 | 平台级 telemetry | 制度化审批 | 企业安全特性 | 平台运维流程 |
| NanoBot | Python | 轻量框架 | 文件 / 轻量 DB | 偏单端实验 | MCP + Skills | 轻量子任务 | 异步串行 | MCP + Skills | heartbeat + 简单日志 | 配置白名单 | 白名单 + 配置控制 | CLI + cron + heartbeat |
| ZeroClaw | Rust | trait-driven，特性旗标丰富 | 多 backend 可选 | 配置化 | trait 边界多 | 平台级 | trait 抽象，可替换 | 多 trait 扩展点 | 多 backend telemetry | 可配置矩阵 | 多 backend sandbox 组合 | 多种部署组合 |
| NullClaw | Zig | 单体二进制，编译期裁剪 | SQLite hybrid + 自研 engine | 可裁剪 | 自研工具集 | 偏底层 | 系统级并发 | Skills + MCP + 多 backend sandbox | 自研 telemetry | 系统级隔离 | 系统级多后端隔离 | 单体二进制部署 |

## 维度展开

### 架构形态

- 单进程 + workspace crate（MicroClaw / NanoClaw / Moltis / ZeroClaw）：部署一个二进制，模块边界靠 crate 切。
- 平台 / 控制平面（OpenClaw）：把 Agent 看作平台一部分，控制平面与端协同。
- 单体二进制 + 编译期裁剪（NullClaw）：通过编译开关缩到很小。
- 轻量框架（NanoBot）：模块靠目录组织，偏脚本化。

### 状态持久化

- SQLite 内嵌（MicroClaw / NullClaw 部分）：单机 runtime 默认，无外部依赖。MicroClaw schema v25+，迁移由 db.rs 内置。
- 平台数据库（OpenClaw / Moltis）：通常依赖 Postgres / MySQL，运维成本更高。
- 文件 / 轻量 DB（NanoClaw / NanoBot）：起步简单，长期运行需要自管理。

### 渠道数量与工具系统

MicroClaw 注册 15 个 ChannelAdapter（见 `src/runtime.rs` 中的 `registry.register` 调用）。工具系统集中在 `ToolRegistry`，约 50 个内置工具按风险（Low / Medium / High）和并发类（ReadOnly / SideEffect / Exclusive）分类，外部 MCP 工具按同一抽象注入。

### 子代理

- session-native：MicroClaw 把子代理视为同一 runtime 中的一个 session，共享 DB 与 ToolRegistry，受 run_control 与 ChatTurnQueue 约束。
- ACP 子代理：MicroClaw 也支持启动外部 ACP 进程作为子代理，由 stdio 通信。
- 平台编排（OpenClaw / Moltis）：子代理是平台级对象，跨进程协调。

### 并发模型

MicroClaw 的 wave-based 调度由 `partition_into_waves` 实现：同一波内 ReadOnly 工具并行，SideEffect 工具单波单工具串行，Exclusive 工具独占整个波次。`tool_concurrency_overrides` 允许把外部 MCP 工具显式归类。

### 扩展机制

MicroClaw 同时承载 MCP（多服务端 + rate limit + circuit breaker，见 `src/mcp.rs`）、Skills（本地目录 + ClawHub 远程仓库）、Plugins（manifest + commands + tools + context providers）、Hooks（BeforeLLMCall / BeforeToolCall / AfterToolCall 三阶段）、A2A（HTTP 对等通信）、ACP（stdio 模式作为 host 或 guest）。这些机制不互相替代，而是各自解决不同维度的扩展问题。

### 可观测性

- OTLP 三信号（MicroClaw）：metrics / traces / logs 走同一导出器。tool 调用、LLM 调用、wave 调度都有 span。
- 自研 telemetry（其它项目）：覆盖度差异较大，需要逐项评估。

### 审批与风险

- MicroClaw：工具自带风险等级，配置项 `high_risk_tool_user_confirmation_required` 控制是否在高风险前打断。Hooks 提供 allow / block / modify 三种结果。
- 平台型项目：通常通过平台权限模型集中控制。
- 极简型项目：风险控制让位于易上手。

### 运维形态

- MicroClaw：Gateway 把 macOS launchd / Linux systemd / Windows 服务统一抽象。`microclaw doctor` 做环境自检，`microclaw setup` 做交互式向导，Web 控制面（带鉴权）暴露 sessions / metrics / config / SSE 流（`src/web/stream.rs`）/ WebSocket（`src/web/ws.rs`）。
- 平台型项目：依赖平台运维流程。
- 单端项目：交给用户自管。

## 如何使用这份矩阵

把"约束"映射到"维度"，再读相应那一列。常见映射如下。

### 约束：单机 / 小规模部署，希望少依赖

- 关注列：架构形态、状态持久化、运维形态。
- 指向：单进程 + SQLite + 内置 Gateway 的项目（MicroClaw、NullClaw、NanoClaw）。
- MicroClaw 在这个约束下的优势是：自带 doctor/setup/Gateway，Web 控制面可选启用，OTLP 默认禁用，启动门槛与运维成本平衡得较好。

### 约束：多团队 / 平台化建设

- 关注列：扩展机制、可观测性、安全机制。
- 指向：平台型项目（OpenClaw、Moltis）。
- 注意：这些项目需要更重的运维投入与权限模型，不要按单机思路去选。

### 约束：渠道覆盖广

- 关注列：渠道数量、并发模型、子代理。
- MicroClaw 注册了 15 个 ChannelAdapter，所有渠道走同一个统一循环，调度差异只在 adapter 层。

### 约束：工具调用密集，单轮多工具

- 关注列：并发模型、工具系统、风险分级。
- MicroClaw 的 wave-based 调度对"一次返回多个 tool_use"是结构性优化；只支持串行调度的项目在这个场景会浪费 LLM 给出的并发提示。

### 约束：长期运行，需要恢复 / 取消 / 治理

- 关注列：状态持久化、审批 / 风险分级、可观测性。
- MicroClaw 把 run_control（取消信号）、ChatTurnQueue（同 chat 排队）、scheduler（DLQ + 失败补偿）、Hooks（策略拦截）、OTLP（指标 / 跟踪 / 日志）放在同一 runtime，因此长期运行的恢复与治理动作比较一致。

### 约束：体积 / 系统级裁剪

- 关注列：架构形态、扩展机制。
- 指向：NullClaw（编译期裁剪 + 单体二进制）。

## 选择流程建议

1. 先列约束（部署环境、运维成本、扩展需求、并发量、风险与合规、可观测性预期）。
2. 把约束映射到维度。
3. 从矩阵中筛掉明显不匹配的项目。
4. 对剩下的项目读源码（见 Appendix B）核实关键路径，不要只看 README。
5. 用 Appendix C 的需求澄清模板把决策写下来，避免事后拉扯。
