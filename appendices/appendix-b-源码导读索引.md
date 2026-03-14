# Appendix B 源码导读索引

## 目标

本附录给出当前 `microclaw/microclaw` 仓库的推荐阅读路径。它不是简单列文件名，而是帮助你按“先建立主链路，再进入细节”的顺序读代码。

如果你第一次读源码，建议不要从某个具体渠道文件开始，而是先建立“系统怎样启动、怎样处理一次请求、怎样保存状态”的整体心智。

## 路线一：先读主链路

### 1. `src/main.rs`

为什么先读这里：

- 看 CLI 如何组织 `start`、`setup`、`doctor`、`hooks`、`web`、`skill` 等入口。
- 理解什么能力被视为主产品功能，而不是辅助脚本。

你应该关注：

- 子命令分类
- 配置与升级路径
- Web 密码管理与控制面入口

### 2. `src/runtime.rs`

为什么接着读这里：

- 这里是运行时装配中心。
- `AppState` 决定了哪些模块属于共享主状态。

你应该关注：

- `AppState` 字段
- 渠道 runtime 的构建和启动方式
- `ChannelRegistry`、`ToolRegistry`、Observability exporter 的装配

### 3. `src/agent_engine.rs`

为什么这是全书最关键文件之一：

- 它定义了统一循环。
- 会话恢复、记忆注入、工具循环、审批、中止、事件流都在这里汇合。

你应该关注：

- `process_with_agent`
- Session Resume
- Context Compaction
- `stop_reason` 处理
- 高风险工具审批

## 路线二：再读基础能力层

### 4. `src/llm.rs`

重点看：

- `LlmProvider` trait
- Anthropic 与 OpenAI-compatible 的统一翻译
- `sanitize_messages`

为什么重要：

- 它决定了 provider 差异如何被隔离在协议层，而不污染统一循环。

### 5. `crates/microclaw-storage/src/db.rs`

重点看：

- schema 相关结构体
- `call_blocking`
- session / memory / scheduled_tasks / metrics_history / audit_logs / subagent_runs

为什么重要：

- 这是系统的统一事实源。
- 多数长期运行能力都落在这里。

### 6. `src/memory_service.rs`

重点看：

- 显式记忆 fast-path
- 去重与 supersede
- poisoning 风险控制

为什么重要：

- 它把“记忆”从概念变成了可治理的运行时能力。

## 路线三：再读工具与渠道

### 7. `src/tools/mod.rs`

重点看：

- `ToolRegistry::new`
- 内置工具清单
- sandbox router 初始化

为什么重要：

- 能快速建立“系统到底让 Agent 能做什么”的全局图。

### 8. `crates/microclaw-tools/src/runtime.rs`

重点看：

- `Tool` trait
- 工具风险与执行策略
- 授权上下文和路径解析辅助

为什么重要：

- 这是工具系统的共性规则层。

### 9. `crates/microclaw-channels/src/channel_adapter.rs`

重点看：

- `ChannelAdapter`
- `ChannelRegistry`

为什么重要：

- 能理解多渠道支持为什么没有把主链路撕裂。

### 10. `crates/microclaw-channels/src/channel.rs`

重点看：

- 路由恢复
- 会话来源推断
- `deliver_and_store_bot_message`

为什么重要：

- Scheduler、`send_message`、控制面和渠道回投都会依赖这层。

## 路线四：最后读生产能力

### 11. `src/scheduler.rs`

重点看：

- `spawn_scheduler`
- `run_due_tasks`
- `spawn_reflector`

为什么重要：

- 这里展示了后台任务、记忆提取与失败补偿如何进入主干。

### 12. `src/web.rs` 与 `src/web/*.rs`

重点看：

- `WebAdapter`
- RunHub / SessionHub / RequestHub
- auth / sessions / metrics / stream / config 路由域

为什么重要：

- 这里是控制面，也是很多生产能力的观察窗口。

### 13. `src/mcp.rs`

重点看：

- `McpServerConfig`
- 请求超时
- rate limit
- circuit breaker

为什么重要：

- 可以理解 MicroClaw 为什么把外部能力接入视为韧性问题，而不是纯协议问题。

### 14. `src/skills.rs` 与 `src/plugins.rs`

重点看：

- Skill frontmatter 与 availability diagnostics
- Plugin manifest、commands、tools、context providers

为什么重要：

- 这两处决定了扩展生态的实际治理边界。

## 三条推荐阅读顺序

### 如果你关心“系统怎么跑起来”

顺序：

1. `src/main.rs`
2. `src/runtime.rs`
3. `src/agent_engine.rs`
4. `crates/microclaw-storage/src/db.rs`

### 如果你关心“为什么它能长期运行”

顺序：

1. `src/agent_engine.rs`
2. `src/memory_service.rs`
3. `src/scheduler.rs`
4. `src/web.rs`
5. `docs/operations/runbook.md`

### 如果你关心“怎么扩展它”

顺序：

1. `src/tools/mod.rs`
2. `crates/microclaw-tools/src/runtime.rs`
3. `src/mcp.rs`
4. `src/skills.rs`
5. `src/plugins.rs`

## 阅读时最容易犯的错误

### 错误一：从某个具体渠道文件开始读

这样会看到很多平台细节，却看不到统一内核。

### 错误二：只看 README，不看 storage 和 agent_engine

这样会知道功能清单，却不知道主状态机和持久化语义。

### 错误三：把扩展机制混在一起看

MCP、Skills、Plugins 在不同层解决不同问题，最好分开理解。

## 最后建议

第一次读源码时，建议同时打开本书的 Chapter 5 到 Chapter 12。因为这几章正好对应：

- 工程骨架
- 统一循环
- 工具系统
- 记忆系统
- 多渠道
- 调度
- Web 控制面
- 扩展生态

按这条路径交叉阅读，最快能建立起对 MicroClaw 的整体理解。
