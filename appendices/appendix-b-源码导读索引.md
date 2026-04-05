# Appendix B 源码导读索引

## 目标

按"先建立主链路，再进入细节"的顺序读 `microclaw/microclaw` 仓库。不要从某个渠道文件开始——先建立"系统怎样启动、怎样处理请求、怎样保存状态"的整体心智。

## 仓库结构总览

| Crate | 职责 | 关键文件 |
|---|---|---|
| 主二进制 | CLI 入口、runtime 装配、agent 循环、Web 控制面 | `src/main.rs` (903L), `src/runtime.rs` (788L), `src/agent_engine.rs` (3541L), `src/web.rs` (5548L) |
| `microclaw-core` | LLM 类型定义、文本处理、错误类型 | `crates/microclaw-core/src/` |
| `microclaw-storage` | SQLite 持久化、schema、memory quality | `crates/microclaw-storage/src/db.rs` (6444L) |
| `microclaw-tools` | Tool trait、风险分级、concurrency class、sandbox | `crates/microclaw-tools/src/runtime.rs` (417L) |
| `microclaw-channels` | ChannelAdapter trait、ChannelRegistry、消息路由 | `crates/microclaw-channels/src/` |
| `microclaw-clawhub` | ClawHub 远程技能仓库客户端 | `src/clawhub/` |
| `microclaw-observability` | OTLP metrics/traces/logs | `crates/microclaw-observability/src/` |
| `microclaw-app` | 应用级胶水 | `crates/microclaw-app/src/` |

## 路线一：主链路（必读）

| # | 文件 | 行数 | 重点关注 |
|---|------|------|---------|
| 1 | `src/main.rs` | 903 | 12 个子命令、start vs acp 两种运行模式、配置加载失败触发 setup wizard |
| 2 | `src/runtime.rs` | 788 | `AppState` 18 个字段、16 渠道构建启动、ToolRegistry/HookManager/Observability 装配 |
| 3 | `src/agent_engine.rs` | 3541 | `AgentEvent` 8 种事件、per-chat turn lock + run control + `tokio::select!` 中止、tool_use_fingerprint 重复检测 |
| 4 | `src/tool_executor.rs` | 877 | `partition_into_waves`（ReadOnly 并行/SideEffect 串行/Exclusive 独占）、`execute_tool_batch`、before/after hook 集成 |

## 路线二：基础能力层

| # | 文件 | 重点 |
|---|------|------|
| 5 | `src/llm.rs` (4303L) | `LlmProvider` trait、Anthropic/OpenAI-compatible 统一翻译、per-chat provider/model override |
| 6 | `db.rs` (6444L) | `call_blocking` async/sync 桥接、session/memory/tasks/metrics/audit/subagent 六大表域 |
| 7 | `src/memory_service.rs` + `memory_backend.rs` | 本地 DB + MCP 双后端、Reflector 自动提取、Jaccard 去重 |

## 路线三：工具与渠道

| # | 文件 | 重点 |
|---|------|------|
| 8 | `src/tools/mod.rs` + 22 子模块 | `ToolRegistry::new`（44 工具）、`new_sub_agent`（受限表）、`execute_with_auth` |
| 9 | `microclaw-tools/src/runtime.rs` (417L) | `Tool` trait、`ToolRisk`(L/M/H)、`ToolConcurrencyClass`(RO/SE/EX)、`ToolExecutionPolicy` |
| 10 | `microclaw-channels/` + `src/channels/` | `ChannelAdapter` trait + 16 渠道实现 |

## 路线四：互操作与治理

| # | 文件 | 重点 |
|---|------|------|
| 12 | `src/acp.rs` (492L) + `acp_subagent.rs` (915L) | stdio 模式被外部调用 / Native vs ACP 双模式子代理 |
| 13 | `src/a2a.rs` (176L) | AgentCard + 对等 HTTP 通信（与 ACP host-agent 互补） |
| 14 | `src/hooks.rs` (766L) | 三阶段事件 + YAML frontmatter + allow/block/modify |
| 15 | `src/run_control.rs` (128L) | register/unregister/abort + AtomicBool + Notify |

## 路线五：生产能力

| # | 文件 | 重点 |
|---|------|------|
| 16 | `src/gateway.rs` (2746L) | macOS launchd / Linux systemd / Windows 服务 |
| 17 | `src/scheduler.rs` (802L) | 分钟 tick + DLQ 补偿 + Reflector |
| 18 | `src/web.rs` (5548L) + `src/web/*.rs` | 10 子模块：auth/sessions/metrics/stream/config/A2A/WebSocket |
| 19 | `src/mcp.rs` (967L) | 分片配置 + rate limit + circuit breaker |
| 20 | `src/skills.rs` + `src/plugins.rs` | SkillManager + Plugin manifest |
| 21 | `src/setup.rs` (11003L) + `src/doctor.rs` (1719L) | 交互式配置向导 + 环境诊断 |

## 三条推荐阅读顺序

**"系统怎么跑起来"**：main.rs → runtime.rs → agent_engine.rs → tool_executor.rs → db.rs

**"为什么能长期运行"**：agent_engine.rs → run_control.rs → memory_service.rs → scheduler.rs → hooks.rs → web.rs

**"怎么扩展它"**：tools/mod.rs → tools/runtime.rs → tool_executor.rs → mcp.rs → skills.rs → hooks.rs → acp.rs → a2a.rs

## 阅读时最容易犯的错误

| 错误 | 后果 |
|------|------|
| 从某个渠道文件开始 | 看到平台细节，看不到统一内核 |
| 只看 README 不看 storage/agent_engine | 知道功能清单，不知道主状态机 |
| 把 MCP/Skills/Plugins/Hooks 混着看 | 它们在不同层解决不同问题 |
| 跳过 tool_executor.rs | 会漏掉 wave 分区和 concurrency class 整个设计 |
| 把 ACP 和 A2A 混为一谈 | ACP 是 host-agent 编排，A2A 是对等通信 |
