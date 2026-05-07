# Appendix B 源码导读索引

## 目标

针对 MicroClaw v0.1.57，给出一条推荐的阅读顺序，并在每个文件后用一句话回答：读这个文件能解决什么问题。本附录不替代源码，只把"主链路"先建立起来，避免读者从某个渠道适配器开始，看到平台细节但看不见统一内核。

## 仓库总览（v0.1.57）

主二进制位于 `microclaw/microclaw`，其下有 8 个 workspace crate：

| Crate | 责任 | 关键路径 |
|---|---|---|
| 主二进制（root） | CLI、runtime 装配、agent 主循环、协议层、Web 控制面 | `src/` |
| `microclaw-core` | LLM 类型、文本工具、错误类型 | `crates/microclaw-core/src/` |
| `microclaw-storage` | SQLite schema、迁移、call_blocking 桥接 | `crates/microclaw-storage/src/db.rs` |
| `microclaw-tools` | Tool trait、风险分级、并发类、sandbox、path/url 校验 | `crates/microclaw-tools/src/runtime.rs` |
| `microclaw-channels` | ChannelAdapter trait、ChannelRegistry、消息路由 | `crates/microclaw-channels/src/` |
| `microclaw-clawhub` | 远程技能仓库客户端、lockfile、闸门策略 | `crates/microclaw-clawhub/src/` |
| `microclaw-observability` | OTLP metrics / traces / logs 导出器 | `crates/microclaw-observability/src/` |
| `microclaw-app` | 应用级胶水、可选 journald 等特性 | `crates/microclaw-app/src/` |

## 推荐阅读顺序

按下列顺序读，能在最短时间里建立"系统怎么启动、怎么处理一次请求、怎么持久化、怎么扩展"的整体心智。每个条目后面那一句话是这个文件能回答的问题。

### 阶段 1：装配与主循环

1. **`Cargo.toml`（workspace 根）** — 想知道项目分了几个 crate、版本号怎么传递、哪些是可选 feature（`channel-matrix`、`sqlite-vec`、`journald` 等）就读它。

2. **`src/main.rs`** — 想知道 CLI 子命令边界、`start` 与 `acp` 两种运行模式如何分流、配置加载失败时如何触发 setup wizard 就读它。

3. **`src/runtime.rs`** — 想知道 `AppState` 装配哪些字段、ChannelRegistry 注册哪些 adapter、ToolRegistry / HookManager / OTLP 导出器如何串起来就读它。

4. **`src/agent_engine.rs`** — 想知道一次完整 turn 的状态机：消息入队、resume 上下文、调用 LLM、解析 tool_use、提交 tool 执行、回灌结果、再次循环、终止条件、`AgentEvent` 八种事件、per-chat turn lock、与 `tokio::select!` 的取消协作，就读它。

5. **`src/tool_executor.rs`** — 想知道 `partition_into_waves` 如何把一组 tool_use 切成多个 wave、ReadOnly 并行 / SideEffect 串行 / Exclusive 独占的策略、超时与审批门、tool_use_fingerprint 如何防重复，就读它。

### 阶段 2：工具与渠道抽象

6. **`crates/microclaw-tools/src/runtime.rs`** — 想知道 `Tool` trait 的形状、`ToolRisk`（L/M/H）、`ToolConcurrencyClass`（ReadOnly/SideEffect/Exclusive）、`ToolExecutionPolicy` 如何参与决策，就读它。

7. **`src/tools/mod.rs`** — 想知道 `ToolRegistry::new` 注册的内置工具有哪些、子代理用的 `new_sub_agent` 如何裁剪工具集、`execute_with_auth` 如何把鉴权与执行连起来，就读它。

8. **`crates/microclaw-channels/src/channel_adapter.rs`** — 想知道 ChannelAdapter trait 与 ChannelRegistry 的契约、chat_type 路由怎么从 DB 字符串映射到 adapter，就读它。

9. **`src/channels/*.rs`（任选 1–2 个）** — 想知道某个具体平台（Telegram、Discord、Slack、Feishu、Email、IRC、Matrix、Weixin、DingTalk、Signal、WhatsApp、Nostr、iMessage、QQ）如何接入统一循环，就挑你最关心的那一个读。Web 渠道见后文 web 模块。

### 阶段 3：存储与调度

10. **`crates/microclaw-storage/src/db.rs`** — 想知道 schema v25+ 的迁移脚本、`call_blocking` 怎样把同步 rusqlite 包成 async、sessions / messages / scheduled_tasks / memory / metrics / audit / subagent 表的字段，就读它。

11. **`src/scheduler.rs`** — 想知道分钟级 tick 如何驱动 once / cron / interval 任务、失败补偿与 DLQ 重放的策略、Reflector 如何与 scheduler 协作，就读它。

### 阶段 4：Web 控制面

12. **`src/web.rs`** — 想知道 Web 控制面顶层路由、`WebState` 如何承载 AppState、鉴权中间件如何挂到所有路由，就读它。

13. **`src/web/auth.rs` + `sessions.rs` + `metrics.rs` + `config.rs`** — 想知道 token 认证、会话查询、metrics 输出、运行时配置读写的具体实现，就读它们。

14. **`src/web/stream.rs`（SSE） + `src/web/ws.rs`（WebSocket）** — 想知道控制面如何把 agent 的 turn 事件实时推送给前端、SSE 与 WebSocket 各承担什么场景，就读它们。SSE 走 `/api/send_stream`，WebSocket 走 ws 协议帧并维护协议版本与心跳。

15. **`src/web/a2a.rs`** — 想知道 `/api/a2a/agent-card` 与 `/api/a2a/message` 两个端点如何承载 A2A 互通，就读它。

### 阶段 5：协议层（互操作）

16. **`src/mcp.rs`** — 想知道 MCP 多服务端配置、rate limit、circuit breaker、stdio 子进程生命周期与 reconnect 策略，就读它。

17. **`src/a2a.rs`** — 想知道 AgentCard、`A2AMessageRequest`、HTTP 对等通信的协议字段，就读它。注意：A2A 走 HTTP，是对等通信。

18. **`src/acp.rs`** — 想知道 ACP（Agent Client Protocol）作为 stdio 模式被外部 host 调用时的初始化、prompt、tool_use 转换、session 管理，就读它。注意：ACP 仅 stdio。

19. **`src/acp_subagent.rs`** — 想知道当 MicroClaw 作为 host 启动外部 ACP 进程作为子代理时的进程管理、流式回传、取消协议，就读它。

### 阶段 6：扩展与治理

20. **`crates/microclaw-clawhub/src/lib.rs` 与 `client.rs` / `install.rs` / `lockfile.rs` / `gate.rs`** — 想知道 ClawHub 远程技能仓库的协议、安装流程、本地 lockfile、可信源闸门策略，就读它。

21. **`src/clawhub/mod.rs` 与 `service.rs` / `tools.rs`** — 想知道主二进制如何把 ClawHub 客户端封装成 Tool 与 service 调用，就读它。

22. **`src/skills.rs`** — 想知道 SkillManager 如何加载本地与远程技能、技能与 prompt / tool 的拼接顺序，就读它。

23. **`src/plugins.rs`** — 想知道 Plugin manifest（commands + tools + context providers）如何被加载、命名空间冲突如何处理，就读它。

24. **`src/hooks.rs`** — 想知道 Hook 三阶段事件（BeforeLLMCall / BeforeToolCall / AfterToolCall）、frontmatter 解析、allow / block / modify 三种结果、超时与失败语义，就读它。

### 阶段 7：长期运行的治理细节

25. **`src/run_control.rs`** — 想知道 register / unregister / abort 的 AtomicBool + Notify 实现、source_message_id 去重、abort 信号如何穿透到执行中的 tool 与 LLM 调用，就读它。

26. **`src/chat_turn_queue.rs`** — 想知道同一 chat 的多次输入如何排队、TurnLock 如何避免并发、PendingMessage 的合并策略，就读它。

27. **`src/memory_service.rs` + `src/memory_backend.rs`** — 想知道结构化记忆、Reflector 自动提取、本地 DB 与 MCP 后端双写、Jaccard 去重，就读它。

28. **`src/scheduler.rs`（再读）** — 第二轮重点读 DLQ 路径与 Reflector 策略，第一轮关注主流程即可。

### 阶段 8：可观测与运维

29. **`crates/microclaw-observability/src/lib.rs`（与 `metrics.rs` / `traces.rs` / `logs.rs` / `sdk.rs`）** — 想知道 OTLP 三信号导出器如何统一封装、span 如何在 tool / LLM / wave 各处插入，就读它。

30. **`src/gateway.rs`** — 想知道 macOS launchd、Linux systemd、Windows 服务的安装 / 启停 / 卸载脚本如何由统一抽象生成，就读它。

31. **`src/doctor.rs`** — 想知道环境自检覆盖了哪些项（配置、可执行文件、Web 控制面、OTLP 端点、磁盘、依赖工具），就读它。

32. **`src/setup.rs`** — 想知道交互式 setup 向导如何分章节收集配置、首次运行的兜底逻辑，就读它。

## 三条主题路线

依据问题类型选一条：

**「系统怎么跑起来」**
`Cargo.toml` → `src/main.rs` → `src/runtime.rs` → `src/agent_engine.rs` → `src/tool_executor.rs` → `crates/microclaw-storage/src/db.rs`

**「为什么能长期运行」**
`src/agent_engine.rs` → `src/run_control.rs` → `src/chat_turn_queue.rs` → `src/memory_service.rs` → `src/scheduler.rs` → `src/hooks.rs` → `src/web/stream.rs` + `src/web/ws.rs`

**「怎么扩展它」**
`src/tools/mod.rs` → `crates/microclaw-tools/src/runtime.rs` → `src/tool_executor.rs` → `src/mcp.rs` → `src/skills.rs` → `src/plugins.rs` → `src/hooks.rs` → `src/acp.rs` → `src/a2a.rs`

## 阅读时最容易犯的错误

| 错误 | 后果 |
|------|------|
| 从某个渠道文件开始读 | 看到平台细节，看不到统一内核 |
| 只看 README 不看 storage / agent_engine | 知道功能清单，不知道主状态机 |
| 把 MCP / Skills / Plugins / Hooks 混着读 | 它们在不同层解决不同问题，混读会觉得"功能重复" |
| 跳过 tool_executor.rs | 漏掉 wave 分区与 concurrency class 的整个设计 |
| 把 ACP 与 A2A 混为一谈 | ACP 仅 stdio（host-agent 编排），A2A 才走 HTTP（对等通信） |
| 跳过 run_control + chat_turn_queue | 看不到"取消信号 + 同 chat 排队"这两个长期运行的关键 |
