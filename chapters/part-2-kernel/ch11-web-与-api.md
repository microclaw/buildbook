# Chapter 11 Web 与 API

## 这一章要回答什么问题

纯聊天入口不够用时，控制面应该提供什么？——会话管理、流式观察、运行中止、API key 管理、可视化运维，以及把这些能力做成一个可发布的 HTTP 表面。

## Web 是一个特殊渠道

Web 不是与渠道并列的"另一种"东西，它就是一个 `ChannelAdapter`，但带着两个保守开关：

```rust
impl ChannelAdapter for WebAdapter {
    fn name(&self) -> &str { "web" }
    fn chat_type_routes(&self) -> Vec<(&str, ConversationKind)> {
        vec![("web", ConversationKind::Private)]
    }
    fn is_local_only(&self) -> bool { true }
    fn allows_cross_chat(&self) -> bool { false }
    async fn send_text(&self, _: &str, _: &str) -> Result<(), String> {
        Ok(()) // Web 消息通过 SSE/WS 推送，不主动外发
    }
}
```

`is_local_only = true` 意味着 Web session 不需要外发投递；`allows_cross_chat = false` 意味着 Web 入口不能触发 cross-chat 工具——避免运维台变成攻击面。ACP 共享同一姿态。

## API 路由按运维域划分

`src/web/` 下每个文件对应一个运维域，互不交叉：

| 子模块 | 职责 |
|--------|------|
| `auth.rs` | 登录、session、bootstrap token、API key CRUD |
| `sessions.rs` | 会话列表、历史、fork、delete、reset |
| `config.rs` | 配置读取、自检、风险提示 |
| `metrics.rs` | 观测视图、SLO、usage report |
| `stream.rs` | SSE 流式事件推送 |
| `ws.rs` | WebSocket 双向通信 |
| `skills.rs` | 技能列表、激活、停用 |
| `a2a.rs` | Agent-to-Agent 协议端点（详见第 12 章） |
| `chat_abort.rs` | 运行中止 |
| `middleware.rs` | 鉴权、节流、CORS |

## SSE 与 WebSocket：两条事件通道

事件推送通过两个不同的端点暴露给前端：`src/web/stream.rs` 提供 SSE，`src/web/ws.rs` 提供 WebSocket。两者推送同一份执行事件序列（迭代开始、工具启动 / 结果、文本增量、完成 / 中止），区别在于通道形态。

| 维度 | SSE（`stream.rs`） | WebSocket（`ws.rs`） |
| --- | --- | --- |
| 方向 | 单向（服务器→客户端） | 双向 |
| 协议 | 浏览器原生 `EventSource` | JSON 帧 |
| 发送消息 | 不支持 | 支持（chat、slash command） |
| 中止请求 | 走单独 POST `/api/chat/abort` | 支持 abort 帧 |
| 心跳 | 无（依赖 HTTP keepalive） | 15s |
| 适用场景 | 简单流式展示、命令行 client | 完整交互控制面 |

两端后台共享同一组事件广播：每次 `start_stream_run_internal`（位于 `stream.rs`）创建 `run_id`，把 `AgentEvent` 推入广播总线；同一总线被 SSE 流和 `ws.rs` 的 frame writer 同时订阅。事件历史保留默认 512 条，断线重连可从历史回放。

### 控制面事件 DTO

```rust
struct RunEvent {
    id: u64,
    event: String,   // "iteration_start" | "tool_start" | "text_delta" | "done" | "aborted"
    data: String,    // JSON payload
}
```

事件名对前端是稳定接口，新增字段优先放进 `data`（向后兼容），不新增 event 名。

## Chat Abort：一等能力

```
前端 POST /api/chat/abort → 查找 run_id controller
  → 验证 session_key 匹配 → 设置 aborted flag
    → Agent engine 检测 flag → 停止执行 → 返回 partial text
```

每个 controller 持有 `aborted: Arc<AtomicBool>` + `buffer: Arc<RwLock<String>>` + `session_key`。Agent engine 在每次迭代和工具调用之间检查 flag。批量场景调用 `abort_chat_runs_for_session_key` 一次中止整个 session 的进行中 run，避免 fork 出来的子 run 漏杀。

## Auth：从首次启动就建立基线

### Bootstrap Token

首次启动生成一次性 token（仅存内存）。管理员凭它调用 `POST /api/auth/set-password` 设置初始密码，密码落库后 token 立即销毁（`*guard = None`）。在不暴露默认密码的前提下完成第一次认证。

### 密码与 Session

`auth_passwords` 存 Argon2 哈希，登录通过后写 `auth_sessions`（含 expires_at），cookie 携带 session token。登录端点带节流，防暴力破解。

### API Key + Scope

```rust
const ALLOWED_API_KEY_SCOPES: &[&str] = &[
    "operator.read",
    "operator.write",
    "operator.admin",
    "operator.approvals",
];
```

`api_keys`（含 expires_at、rotated_from_key_id）+ `api_key_scopes` 形成简单的 RBAC。所有受保护路由经 `require_scope` 中间件检查；同时支持 Bearer token 与 cookie 两种认证。`audit_logs` 记录所有敏感操作，按 `kind, created_at DESC` 索引。

## Session 管理与分叉

`sessions.rs` 的核心模型是会话树：

- `GET /api/sessions`：列出最近 400 个 session（Web、外部渠道混合）。
- `GET /api/history?session_key=...`：分页返回消息。
- `POST /api/sessions/fork`：从指定消息分叉出新 session，记录 `parent_session_key` + `fork_point`。
- 树视图：父子关系可视化，方便比较多个走向。
- 删除策略不同：Web session 整条删除；外部渠道 session 只清消息保留 chat 元数据（保留外部 chat id 映射）。
- delete 同时清理 todo 数据，避免孤立条目。

## 请求限流与并发控制

```rust
struct WebLimits {
    max_inflight_per_session: usize,  // 默认 10
    max_requests_per_window: usize,   // 默认 8
    rate_window: Duration,             // 默认 10s
    run_history_limit: usize,          // 默认 512
    session_idle_ttl: Duration,        // 默认 300s
}
```

`RequestHub` 维护 per-session + per-actor 两层配额——单 actor 跨 session 的滥用行为也能被框住。

## Metrics：前后端共享一份指标

```rust
struct WebMetrics {
    http_requests: i64,
    request_ok: i64,
    request_error: i64,
    request_latency_ms: VecDeque<i64>,
    llm_completions: i64,
    llm_input_tokens: i64,
    llm_output_tokens: i64,
    tool_executions: i64,
    tool_success: i64,
    tool_error: i64,
    tool_policy_blocks: i64,
    mcp_calls: i64,
    mcp_rate_limited_rejections: i64,
    mcp_bulkhead_rejections: i64,
    mcp_circuit_open_rejections: i64,
}
```

`/api/metrics/summary` 暴露显式 SLO 结构，前端不再自己拼健康度；`build_usage_report` 提供按 session 的 token usage——账单和异常溯源同一份口径。

## Middleware 链与跨域

`middleware.rs` 把 CORS、actor 解析、scope 校验、节流统一挂到路由树上。约束：

- 默认仅放行同源；外部访问需在 config 中显式声明 origin。
- actor 字符串是节流和 audit 的主键，匿名请求被分配 `anonymous:<ip>` 派生 actor。
- `require_scope` 在握手阶段一次性解析 token + 比对 scope，路由 handler 只看到已通过校验的 `Identity`。
- 5xx 路径必报 `request_error` 计数，前端可一眼看到错误率突变。

## 嵌入式前端

`include_dir!` 宏编译时把 `dist/` 目录嵌进二进制——部署不需要额外静态服务器，前端版本与 backend 锁定。技术栈 React + Vite + TypeScript + `@assistant-ui/react`。

| 面板 | 功能 |
| --- | --- |
| Chat | 消息历史、流式输入、abort |
| Session Tree | 所有 session、fork/delete/切换 |
| Skills | 查看 / 激活 / 停用 |
| API Keys | 创建、scope、吊销 |
| Usage / Metrics | token 消耗、工具统计 |
| Memory / Reflector | 记忆状态、reflector 日志 |

```{=typst}
#pagebreak(weak: true)
```

## 示例代码：流式事件推送

```rust
#[async_trait::async_trait]
trait EventSink {
    async fn send(&self, event: RunEvent) -> anyhow::Result<()>;
}

struct RunStreamer<S> {
    sink: S,
}

impl<S: EventSink> RunStreamer<S> {
    async fn stream_run(&self) -> anyhow::Result<()> {
        self.sink.send(RunEvent { id: 1, event: "iteration_start".into(), data: "1".into() }).await?;
        self.sink.send(RunEvent { id: 2, event: "tool_start".into(), data: "bash".into() }).await?;
        self.sink.send(RunEvent { id: 3, event: "text_delta".into(), data: "Hello".into() }).await?;
        self.sink.send(RunEvent { id: 4, event: "done".into(), data: "".into() }).await?;
        Ok(())
    }
}
```

## 容易走错的地方

| 失败模式 | 后果 |
|---------|------|
| 把 Web 当单纯聊天前端 | 低估会话管理、配置治理、API key、观测的职责 |
| 不做 abort 就上线流式 API | 失控的 run 用户束手无策 |
| 控制面上线后再补鉴权 | 已形成不安全的默认用法 |
| 前端自己拼健康度 | 前后端口径漂移 |
| 把外部渠道 session 整条删掉 | 丢失 chat id 映射，下次同 chat 发消息认不出 |

## 关键权衡

| 决策 | 优点 | 代价 |
|------|------|------|
| SSE + WebSocket 双通道 | 兼容性 + 丰富交互 | 维护两套推送一致性 |
| Bootstrap token + scope | 安全基线 Day 1 建立 | 初始设置比默认密码复杂 |
| Chat abort 一等能力 | 用户/脚本可安全中止失控 run | 每个迭代点需检查 flag |
| 嵌入式前端 | 部署极简，一个二进制 | 前端更新需重编译 |
| SSE/WS 共享事件总线 | 真实观察执行 + replay | 需维护历史和清理策略 |
| Argon2 + 密码 | 标准强度 | 单进程哈希 CPU 占用比明文 token 高 |

## 证据来源

- 版本：`microclaw v0.1.57`
- 子模块：`src/web/{auth,sessions,config,metrics,stream,ws,skills,a2a,chat_abort,middleware}.rs`
- WebAdapter：`src/web/` 中 `WebAdapter` 实现
- Scope 列表：`src/web/auth.rs` 中 `ALLOWED_API_KEY_SCOPES`
- 表结构：`crates/microclaw-storage/src/db.rs` 中 `auth_passwords` / `auth_sessions` / `api_keys` / `api_key_scopes` / `audit_logs`
- 框架：Axum 0.7（含 WebSocket）

## 图表清单

### 图 11-1：Web 控制面在 runtime 中的位置

![图 11-1：Web 控制面在 runtime 中的位置](../../assets/figures/fig-11-web-control-plane.svg)
