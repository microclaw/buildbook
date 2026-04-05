# Appendix B 源码导读索引

## 目标

本附录给出当前 `microclaw/microclaw` 仓库（v0.1.38）的推荐阅读路径。它不是简单列文件名，而是帮助你按"先建立主链路，再进入细节"的顺序读代码。

如果你第一次读源码，建议不要从某个具体渠道文件开始，而是先建立"系统怎样启动、怎样处理一次请求、怎样保存状态"的整体心智。

## 仓库结构总览

v0.1.38 的仓库由 8 个 workspace crate 组成：

| Crate | 职责 | 关键文件 |
|---|---|---|
| 主二进制 | CLI 入口、runtime 装配、agent 循环、Web 控制面 | `src/main.rs` (903L), `src/runtime.rs` (788L), `src/agent_engine.rs` (3541L), `src/web.rs` (5548L) |
| `microclaw-core` | LLM 类型定义、通用文本处理、错误类型 | `crates/microclaw-core/src/` |
| `microclaw-storage` | SQLite 持久化、schema、memory quality | `crates/microclaw-storage/src/db.rs` (6444L) |
| `microclaw-tools` | Tool trait、风险分级、concurrency class、sandbox、命令执行 | `crates/microclaw-tools/src/runtime.rs` (417L), `crates/microclaw-tools/src/sandbox.rs` |
| `microclaw-channels` | ChannelAdapter trait、ChannelRegistry、消息路由与投递 | `crates/microclaw-channels/src/channel_adapter.rs`, `crates/microclaw-channels/src/channel.rs` |
| `microclaw-clawhub` | ClawHub 远程技能仓库客户端与 CLI | `src/clawhub/` (cli.rs, service.rs, tools.rs) |
| `microclaw-observability` | OTLP metrics / traces / logs 三信号导出 | `crates/microclaw-observability/src/` |
| `microclaw-app` | 应用级胶水 | `crates/microclaw-app/src/` |

## 路线一：先读主链路

### 1. `src/main.rs`（903 行）

为什么先读这里：

- 看 CLI 如何组织 `start`、`acp`、`setup`、`doctor`、`gateway`、`skill`、`hooks`、`weixin`、`web`、`reembed`、`upgrade`、`version` 共 12 个子命令。
- 理解 `start` 和 `acp` 是两种运行模式：`start` 启动完整多渠道 runtime，`acp` 以 stdio 方式暴露 Agent Client Protocol。
- 看数据目录布局迁移（`migrate_legacy_runtime_layout`）和 MCP 配置路径收集（`collect_mcp_config_paths`）。

你应该关注：

- 子命令分类和 launch mode 分发
- 配置加载失败时自动触发 setup wizard
- `runtime_config` 对 `data_dir` 和 `skills_dir` 的修正
- Web 密码管理与控制面入口

### 2. `src/runtime.rs`（788 行）

为什么接着读这里：

- 这里是运行时装配中心。
- `AppState` 的 18 个字段决定了哪些模块属于共享主状态。

你应该关注：

- `AppState` 字段：`config`, `channel_registry`, `db`, `memory`, `skills`, `hooks`, `llm`, `llm_provider_overrides`, `llm_model_overrides`, `embedding`, `memory_backend`, `tools`, `chat_turn_queue`, `metric_exporter`, `trace_exporter`, `log_exporter`
- 16 个渠道适配器的构建和启动方式（Telegram, Discord, Slack, Feishu, Email, IRC, Web, Matrix, WeChat, DingTalk, Signal, WhatsApp, Nostr, iMessage, QQ 等）
- `ChannelRegistry`、`ToolRegistry`、`HookManager`、Observability exporter 的装配

### 3. `src/agent_engine.rs`（3541 行）

为什么这是全书最关键文件之一：

- 它定义了统一循环和所有 agent 事件。
- 会话恢复、记忆注入、工具循环、审批、中止、run control、事件流都在这里汇合。

你应该关注：

- `AgentEvent` 枚举：`Iteration`, `ToolStart`, `ToolResult`, `TextDelta`, `ToolWaveStart`, `ToolWaveComplete`, `Cancelled`, `FinalResponse`——这 8 个事件定义了运行时的完整观察模型
- `process_with_agent_with_events_guarded`：per-chat turn lock（`ChatTurnQueue`）+ run control（注册 / 取消 / 注销）+ `tokio::select!` 中止
- `maybe_rerun_for_pending`：处理 turn 执行期间排队的新消息
- `tool_use_fingerprint`：重复工具调用指纹检测
- `AgentRequestContext`：`caller_channel` + `chat_id` + `chat_type` 三元组

### 4. `src/tool_executor.rs`（877 行）

为什么单独把它提升到主链路：

- v0.1.38 引入了 wave-based parallel tool execution，这是理解性能模型的关键。
- 并行执行不是简单的 `join_all`，而是按 concurrency class 分波调度。

你应该关注：

- `PendingToolCall`、`ToolBatchContext`、`ToolMetrics` 三个核心结构
- `partition_into_waves`：ReadOnly 工具并行、SideEffect 工具串行、Exclusive 工具独占——这是 wave 的分区规则
- `execute_tool_batch`：入口函数，单工具直通、多工具按 wave 调度
- `execute_single_tool`：完整的单工具执行管线——恶意名称检查 → send_message 连续调用护栏 → Feishu 特例 → before-tool hook → 执行 → trace span → approval 自动重试 → activate_skill 元数据 → after-tool hook → 错误追踪 → 事件发射
- `execute_wave_parallel`：before-hook 串行预处理 → `futures::join_all` 并发执行 → after-hook 逐条处理
- `resolve_concurrency_class`：支持配置 override，MCP 工具可由用户提升为 `read_only` 以参与并行

## 路线二：再读基础能力层

### 5. `src/llm.rs`（4303 行）

重点看：

- `LlmProvider` trait
- Anthropic 与 OpenAI-compatible 的统一翻译
- `sanitize_messages`
- Provider / model override 机制

为什么重要：

- 它决定了 provider 差异如何被隔离在协议层，而不污染统一循环。
- v0.1.38 增加了 per-chat provider/model override，支持运行时动态切换。

### 6. `crates/microclaw-storage/src/db.rs`（6444 行）

重点看：

- schema 相关结构体
- `call_blocking`：async/sync 桥接，所有 SQLite 操作的统一入口
- session / memory / scheduled_tasks / metrics_history / audit_logs / subagent_runs 六大表域

为什么重要：

- 这是系统的统一事实源。
- 多数长期运行能力——调度、记忆、Subagent 追踪、审计日志——都落在这里。

### 7. `src/memory_service.rs`（627 行）与 `src/memory_backend.rs`（1493 行）

重点看：

- `build_db_memory_context`：从 DB 装载记忆上下文
- `maybe_handle_explicit_memory_command`：显式记忆 fast-path
- `MemoryBackend`：本地 DB + 可选 MCP memory 后端（`MemoryMcpClient`）
- `apply_reflector_extractions`：Reflector 自动提取结果入库
- Jaccard 相似度去重与 supersede

为什么重要：

- 记忆不是单一存储，而是"本地 DB + MCP 远程"双后端，且 Reflector 自动提取管道在后台持续运行。

## 路线三：再读工具与渠道

### 8. `src/tools/mod.rs` 与 22 个工具模块

重点看：

- `ToolRegistry::new`：44 内置工具的注册清单
- `ToolRegistry::new_sub_agent`：Subagent 专用的受限工具注册表
- `should_inject_default_chat_id`：哪些工具自动注入 `chat_id`
- `execute_with_auth`：统一执行入口，注入 auth context、处理 sandbox 路由、高风险审批
- `add_tool`：MCP 工具运行时动态注入

22 个工具子模块：`a2a`, `activate_skill`, `bash`, `browser`, `edit_file`, `export_chat`, `glob`, `grep`, `mcp`, `memory`, `read_file`, `schedule`, `send_message`, `structured_memory`, `subagents`, `sync_skills`, `time_math`, `todo`, `web_fetch`, `web_search`, `write_file` + ClawHub tools（`clawhub/tools.rs`）

为什么重要：

- 能快速建立"系统到底让 Agent 能做什么"的全局图。
- Subagent 工具族（11 个）是 v0.1.38 的重点新增。

### 9. `crates/microclaw-tools/src/runtime.rs`（417 行）

重点看：

- `Tool` trait：`name`, `definition`, `execute` 三要素
- `ToolRisk`（Low / Medium / High）与 `tool_risk` 函数
- `ToolConcurrencyClass`（ReadOnly / SideEffect / Exclusive）与 `tool_concurrency_class` 函数
- `ToolExecutionPolicy`（HostOnly / SandboxOnly / Dual）
- `ToolAuthContext`：`caller_channel` + `caller_chat_id` + `control_chat_ids` + `env_files`

为什么重要：

- 这是工具系统的共性规则层。风险分级、并行分类和执行策略都在这里定义，而非散落在各工具实现中。

### 10. `crates/microclaw-channels/src/channel_adapter.rs` 与 16 个渠道模块

重点看：

- `ChannelAdapter` trait 与 `ChannelRegistry`
- 16 个渠道实现：`src/channels/` 下的 `telegram.rs`, `discord.rs`, `slack.rs`, `feishu.rs`, `email.rs`, `irc.rs`, `matrix.rs`, `weixin.rs`, `dingtalk.rs`, `signal.rs`, `whatsapp.rs`, `nostr.rs`, `imessage.rs`, `qq.rs` + `startup_guard.rs`

为什么重要：

- 能理解多渠道支持为什么没有把主链路撕裂——所有渠道都通过 `ChannelAdapter` 和 `ChannelRegistry` 汇入统一循环。

### 11. `crates/microclaw-channels/src/channel.rs`

重点看：

- 路由恢复（`get_chat_routing`）
- 会话来源推断
- `deliver_and_store_bot_message`

为什么重要：

- Scheduler、`send_message`、控制面和渠道回投都会依赖这层。

## 路线四：再读互操作与治理

### 12. `src/acp.rs`（492 行）与 `src/acp_subagent.rs`（915 行）

重点看：

- `acp::serve`：以 stdio 模式暴露 Agent Client Protocol，让 MicroClaw 可被外部 host 调用
- `AcpSubagentTaskParams`：ACP 子代理任务参数
- `SubagentExecutionRuntime`：`Native` vs `Acp` 双模式——Native 在进程内运行子循环，ACP 通过 stdio 启动独立进程

为什么重要：

- 这是 MicroClaw 作为"被编排者"和"编排者"的两面。`acp.rs` 让它被外部调用，`acp_subagent.rs` 让它启动外部 ACP Agent 作为子代理。

### 13. `src/a2a.rs`（176 行）

重点看：

- `A2AAgentCard`：Agent 自我描述卡片
- `A2AMessageRequest` / `A2AMessageResponse`：对等通信协议
- 与 Web 控制面中 `src/web/a2a.rs` 的 HTTP 端点对应

为什么重要：

- A2A 是面向 Agent-to-Agent 对等场景的轻量协议，与 ACP（面向 host-agent 编排）互补。

### 14. `src/hooks.rs`（766 行）

重点看：

- `HookEvent`：`BeforeLLMCall`, `BeforeToolCall`, `AfterToolCall` 三阶段
- `HookManager`：从 `hooks/` 目录发现 hook 脚本，按 priority 排序执行
- `HookOutcome`：`Block { reason }` 或 `Allow { patches }`——拦截或放行并可修改输入/输出
- Hook frontmatter：YAML 声明 `name`, `description`, `events`, `command`, `timeout_ms`, `enabled`, `priority`
- CLI 子命令：`microclaw hooks list/info/enable/disable`

为什么重要：

- Hooks 是 v0.1.38 的策略扩展点。它让你不修改源码就能实现"禁止特定工具"、"修改 LLM 请求"、"审计工具输出"等治理需求。

### 15. `src/run_control.rs`（128 行）

重点看：

- `register_run` / `unregister_run`：全局 per-chat 活跃 run 追踪
- `abort_runs`：取消正在进行的 agent loop
- `AtomicBool` + `Notify`：零开销取消信号

为什么重要：

- 这是 `/stop` 命令和 Web 控制面"中止运行"功能的底层机制。

### 16. `src/gateway.rs`（2746 行）

重点看：

- 跨平台服务管理：macOS launchd、Linux systemd、Windows 服务
- `install` / `start` / `stop` / `status` / `logs` 子命令
- WebSocket 健康检查
- 日志目录与服务描述常量

为什么重要：

- 它把 MicroClaw 从"手动启动的进程"变成"可被 OS 管理的长驻服务"。

## 路线五：最后读生产能力

### 17. `src/scheduler.rs`（802 行）

重点看：

- `spawn_scheduler`：分钟对齐的 tick 循环
- `run_due_tasks`：到期任务执行 + DLQ 失败补偿
- `deliver_scheduler_message_with_backoff`：带退避的消息投递（处理渠道限流）
- Reflector 集成

为什么重要：

- 这里展示了后台任务、记忆提取与失败补偿如何进入主干。

### 18. `src/web.rs`（5548 行）与 `src/web/*.rs`

重点看：

- `WebAdapter`
- 10 个子模块：`a2a.rs`, `auth.rs`, `chat_abort.rs`, `config.rs`, `metrics.rs`, `middleware.rs`, `sessions.rs`, `skills.rs`, `stream.rs`, `ws.rs`
- auth / sessions / metrics / stream / config / A2A / WebSocket 路由域

为什么重要：

- 这里是控制面，也是很多生产能力的观察窗口。A2A 端点和 WebSocket 流式输出都在这里暴露。

### 19. `src/mcp.rs`（967 行）

重点看：

- `McpManager::from_config_paths`：支持 `mcp.json` + `mcp.d/*.json` 分片配置
- 请求超时、rate limit、circuit breaker
- MCP 工具动态注入到 `ToolRegistry`

为什么重要：

- 可以理解 MicroClaw 为什么把外部能力接入视为韧性问题，而不是纯协议问题。

### 20. `src/skills.rs`（957 行）与 `src/plugins.rs`（1728 行）

重点看：

- `SkillManager`：从 skills 目录发现技能，解析 frontmatter，检查平台兼容性和依赖
- `SkillAvailability`：可用性诊断（平台不匹配、依赖缺失等）
- Plugin manifest、commands、tools、context providers

为什么重要：

- Skills + Plugins + ClawHub 三者共同构成了扩展生态的治理边界。

### 21. `src/setup.rs`（11003 行）与 `src/doctor.rs`（1719 行）

重点看：

- `run_setup_wizard`：全屏交互式配置向导
- `enable_sandbox_in_config`：单命令启用 sandbox
- `doctor::run_cli`：诊断子命令，支持 `sandbox`、`mcp` 等专项检查

为什么重要：

- 这是用户的第一接触点（`microclaw setup` → `microclaw doctor` → `microclaw start`）。

## 三条推荐阅读顺序

### 如果你关心"系统怎么跑起来"

顺序：

1. `src/main.rs`
2. `src/runtime.rs`
3. `src/agent_engine.rs`
4. `src/tool_executor.rs`
5. `crates/microclaw-storage/src/db.rs`

### 如果你关心"为什么它能长期运行"

顺序：

1. `src/agent_engine.rs`
2. `src/run_control.rs`
3. `src/memory_service.rs` + `src/memory_backend.rs`
4. `src/scheduler.rs`
5. `src/hooks.rs`
6. `src/web.rs`

### 如果你关心"怎么扩展它"

顺序：

1. `src/tools/mod.rs`
2. `crates/microclaw-tools/src/runtime.rs`
3. `src/tool_executor.rs`（理解并行调度）
4. `src/mcp.rs`
5. `src/skills.rs` + `src/plugins.rs`
6. `src/hooks.rs`
7. `src/acp.rs` + `src/acp_subagent.rs`
8. `src/a2a.rs`

## 阅读时最容易犯的错误

### 错误一：从某个具体渠道文件开始读

这样会看到很多平台细节，却看不到统一内核。渠道适配器的价值在于它们都汇入 `ChannelAdapter` trait，而不在于某个渠道的 API 细节。

### 错误二：只看 README，不看 storage 和 agent_engine

这样会知道功能清单，却不知道主状态机和持久化语义。

### 错误三：把扩展机制混在一起看

MCP、Skills、Plugins、Hooks 在不同层解决不同问题。MCP 是外部工具接入，Skills 是本地能力包，Plugins 是命令和 context provider，Hooks 是策略拦截点——最好分开理解。

### 错误四：忽略 tool_executor.rs

v0.1.38 引入了并行工具执行，这不是 agent_engine 的内部细节，而是单独抽取的调度模块。如果你只读 agent_engine 而跳过 tool_executor，会漏掉 wave 分区和 concurrency class 的整个设计。

### 错误五：把 ACP 和 A2A 混为一谈

ACP（Agent Client Protocol）是 host-agent 关系——一方编排另一方。A2A（Agent-to-Agent）是对等关系——两个 Agent 互相发消息。它们的协议形态、使用场景和代码路径完全不同。

## 最后建议

第一次读源码时，建议同时打开本书的 Chapter 5 到 Chapter 12。因为这几章正好对应：

- 工程骨架
- 统一循环
- 工具系统（含并行执行）
- 记忆系统
- 多渠道
- 调度
- Web 控制面
- 扩展生态（MCP / Skills / Hooks / ACP / A2A）

按这条路径交叉阅读，最快能建立起对 MicroClaw 的整体理解。
