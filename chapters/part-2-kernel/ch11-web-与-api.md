# Chapter 11 Web 与 API

## 纯聊天入口不够用时，控制面应该提供什么？

当一个 Agent Runtime 从个人玩具走向可长期运行系统时，纯聊天入口很快不够用。你会需要：

- 一个能查看会话历史和子代理状态的控制面。
- 一个可流式观察执行过程、支持 SSE 和 WebSocket 的界面。
- 一个可以中止运行中请求的机制。
- 一套可自动化访问的 API，带 bootstrap token 和 API key 生命周期管理。
- 一个前端，使用 React+Vite+TypeScript 和 @assistant-ui/react 构建，能展示 session tree、fork/delete、skills panel 和 usage metrics。

MicroClaw v0.1.38 的 `src/web.rs` 已经膨胀到 5500+ 行，`src/web/` 下有 10 个子模块。它不再是一个简单的"聊天前端"，而是 runtime 的完整控制面和可编程界面。

这一章读完后，你应该理解：

1. Web 适配器为什么被视为特殊渠道，以及它与 ACP 的相似性。
2. RunHub 如何支撑 SSE + WebSocket 双通道的事件广播和历史回放。
3. Chat abort 机制如何安全地中止运行中的 agent run。
4. Bootstrap token 和 API key 生命周期管理如何建立安全基线。
5. Session tree、fork/delete、skills panel 和 usage metrics 如何让控制面具备运维价值。

## Web 也是渠道，但它是特殊渠道

`src/web.rs` 里定义了 `WebAdapter`，并明确声明：

```rust
impl ChannelAdapter for WebAdapter {
    fn name(&self) -> &str { "web" }
    fn chat_type_routes(&self) -> Vec<(&str, ConversationKind)> {
        vec![("web", ConversationKind::Private)]
    }
    fn is_local_only(&self) -> bool { true }
    fn allows_cross_chat(&self) -> bool { false }
    async fn send_text(&self, _external_chat_id: &str, _text: &str) -> Result<(), String> {
        Ok(()) // Web 消息通过 SSE/WS 推送，不需要主动外发
    }
}
```

这三个属性把 Web 的定位说得很清楚：它参与统一会话体系，也可以触发统一循环，但它不是外部渠道——它是本地控制面入口。`send_text` 直接返回 Ok 是因为 Web 的消息推送走的是 RunHub + SSE/WebSocket，而不是适配器的外发机制。

有趣的是，ACP（Agent Client Protocol）也有完全相同的姿态：`is_local_only = true`、`allows_cross_chat = false`。这说明 MicroClaw 区分了两类控制面入口——图形化的 Web 和程序化的 ACP——但它们共享同样的权限边界。

## API 路由按运维域划分

Web 作为特殊渠道的身份确立之后，下一个问题是：它暴露的 API 应该怎么组织？很多项目按"前端页面需要什么就加什么接口"的方式堆路由，结果 API 很快变成一个无法维护的杂物间。MicroClaw 选择了另一条路。从 `src/web.rs` 和 `src/web/` 子模块可以看出，它的 Web API 围绕几个运维域组织：

| 子模块 | 职责 |
|--------|------|
| `auth` | 登录、session、bootstrap token、API key CRUD、scope 管理 |
| `sessions` | 会话列表、历史、fork、delete、reset |
| `config` | 配置读取、自检、风险提示 |
| `metrics` | 观测视图、SLO、usage report |
| `stream` | SSE 流式事件推送 |
| `ws` | WebSocket 双向通信 |
| `skills` | 技能列表、激活 |
| `a2a` | Agent-to-Agent 协议端点 |
| `chat_abort` | 运行中止 |
| `middleware` | 鉴权、节流、CORS |

按运维域组织路由避免了"前端页面需要什么就加什么接口"的无序增长。每个路由域都对应一类稳定的运行时职责。

## RunHub：事件广播 + 历史回放

RunHub 是 v0.1.38 控制面的核心基础设施。它为每个运行维护一个 `RunChannel`：

```rust
struct RunChannel {
    sender: broadcast::Sender<RunEvent>,
    history: VecDeque<RunEvent>,
    next_id: u64,
    done: bool,
    aborted: bool,
    owner_actor: String,
}
```

`RunEvent` 携带 `id`、`event`（事件类型）和 `data`（事件数据）。系统通过 RunHub 向前端持续推送：

- 迭代开始
- 工具启动 / 工具结果
- 文本增量
- 最终完成 / 中止

RunHub 的关键设计是 **history + replay**。每个 `RunChannel` 保存了事件历史（受 `run_history_limit` 限制，默认 512 条）。当前端断线后重新订阅时，可以从历史中回放，而不是丢掉所有中间状态。

### SSE 和 WebSocket 的双通道

v0.1.38 同时支持 SSE 和 WebSocket 两种实时通信方式。

**SSE**（`src/web/stream.rs`）是经典的单向服务器推送，适合浏览器原生 `EventSource` API。优点是实现简单、浏览器兼容性好、自动重连。

**WebSocket**（`src/web/ws.rs`）是双向通信，使用 JSON 帧协议。帧类型包括：

- `req`：客户端请求（method + params）
- `res`：服务端响应
- `event`：服务端推送事件

WebSocket 协议有版本控制（`PROTOCOL_VERSION = 3`），客户端连接时需要在 `connect` 帧中声明 `min_protocol` 和 `max_protocol`。这让前后端可以独立演进而不破坏兼容性。

WebSocket 还增加了一些 SSE 没有的能力：

- 客户端可以主动发送 chat 消息
- 客户端可以执行 slash command
- 客户端可以请求中止当前 run
- 心跳 tick 保持连接活跃（`TICK_INTERVAL_MS = 15_000`）

### 控制面事件为什么需要稳定 DTO？

控制面真正要展示的不是框架内部对象，而是运行时公开承诺的事件结构。只有事件 DTO 稳定了，前端回放、日志关联和 API 合约才不会一起漂移。

Rust 版本把一次运行中的事件压成 `RunEvent`，显式携带 id、类型和值。

```rust
struct RunEvent {
    id: u64,
    event: String,
    data: String,
}
```

Python 版本用 `@dataclass` 保持相同语义。

```python
from dataclasses import dataclass


@dataclass
class RunEvent:
    id: int
    event: str
    data: str
```

## Chat Abort：安全中止运行中的请求

`src/web/chat_abort.rs` 实现了一个完整的运行中止机制。这在交互式 Agent 系统中至关重要——用户可能在 Agent 执行了一半时意识到请求是错误的，或者 Agent 陷入了某种循环，需要强制停止。

### 设计

系统维护一个全局 `CHAT_ABORT_CONTROLLERS` registry：

```rust
static CHAT_ABORT_CONTROLLERS: LazyLock<RwLock<HashMap<String, ChatAbortControllerEntry>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));
```

每个 `ChatAbortControllerEntry` 包含：

- `aborted: Arc<AtomicBool>`：中止信号
- `buffer: Arc<RwLock<String>>`：已累积的文本 delta
- `session_key: String`：所属 session

### 中止流程

1. 前端 POST `/api/chat/abort`（或 WebSocket abort 帧）。
2. 系统查找对应 run_id 的 controller entry。
3. 验证 session_key 匹配（防止跨 session 中止）。
4. 设置 `aborted` flag 为 true。
5. 返回已累积的 partial text。

Agent engine 在每次迭代和工具调用之间检查 abort flag。一旦检测到中止，engine 停止执行，RunHub 标记 run 为 aborted。

### 批量中止

`abort_chat_runs_for_session_key` 支持中止一个 session 下的所有 runs。这在用户重置 session 或切换话题时非常有用。

## Bootstrap Token 与 API Key 生命周期

### Bootstrap Token

v0.1.38 引入了 bootstrap token 机制。首次启动时，如果数据库中没有密码，系统会生成一个 bootstrap token 并在日志中打印。管理员用这个 token 调用 `POST /api/auth/set-password` 设置初始密码。

```rust
struct WebState {
    bootstrap_token: Arc<Mutex<Option<String>>>,
    // ...
}
```

一旦密码设置成功，bootstrap token 即销毁（`*guard = None`）。bootstrap token 只存在于内存中，使用一次即失效。

### API Key 管理

`src/web/auth.rs` 实现了完整的 API key 生命周期管理。API key 有 scope 控制：

```rust
const ALLOWED_API_KEY_SCOPES: &[&str] = &[
    "operator.read",
    "operator.write",
    "operator.admin",
    "operator.approvals",
];
```

scope 模型让不同的 API key 有不同的权限范围。`operator.read` 只能查看数据，`operator.write` 可以发送消息，`operator.admin` 可以管理用户和配置，`operator.approvals` 可以执行审批操作。

### 鉴权中间件

所有 API 请求都经过 `require_scope` 中间件检查。支持两种认证方式：

- `Authorization: Bearer <api-key-or-session-token>`
- `mc_session` cookie

登录有节流保护（`AuthHub.login_buckets`），防止暴力破解。API key 也有独立的 rate limit bucket。

## Session 管理：tree、fork、delete

Web 控制面不只是"发消息的界面"。`src/web/sessions.rs` 提供了完整的会话管理能力：

### Session 列表

`GET /api/sessions` 返回最近 400 个会话，每个会话包含 chat_id、session_key、chat_type、最后消息时间等元数据。会话通过 `map_chat_to_session` 被映射为统一的 session 视图。

### Session 历史

`GET /api/history?session_key=xxx` 返回指定 session 的完整消息历史。支持 `limit` 参数做分页。

### Session Reset/Delete

`POST /api/sessions/reset` 可以重置一个 session。如果目标是 web session，直接删除 chat data；如果是外部渠道 session，只清除消息但保留 chat 元数据。这个区分很重要——Web session 是本地的，删除不影响任何外部系统；但外部渠道的 chat 有自己的身份信息，不应该随意删除。

delete 操作还会清理 todo 数据（`clear_todos`），保持状态一致。

## 请求限流与并发控制

`WebLimits` 和 `RequestHub` 提供了精细的资源控制：

```rust
struct WebLimits {
    max_inflight_per_session: usize,  // 默认 10
    max_requests_per_window: usize,   // 默认 8
    rate_window: Duration,             // 默认 10s
    run_history_limit: usize,          // 默认 512
    session_idle_ttl: Duration,        // 默认 300s
}
```

`RequestHub` 维护两层配额：

- **per-session**：限制同一个 session 的并发请求数和窗口内请求数。
- **per-actor**：限制同一个认证身份的请求，防止多 tab 页绕过 session 限制。

这些限制很务实。控制面面对的不是互联网海量流量，但它需要防止用户或脚本误触发大量并发请求、长时间挂住的 session 占满资源、流式运行历史无界增长。

## Web Metrics 与可观测

`WebMetrics` 结构追踪了丰富的运行时指标：

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

这些指标不只是"给 Prometheus 看的数字"——它们被 Web 面板的 `/api/metrics`、`/api/metrics/summary`、`/api/metrics/history` 直接消费，让运维人员能在同一个界面看到 LLM 用量、工具成功率、MCP 可用性和 HTTP 层健康度。

`/api/metrics/summary` 暴露了显式 SLO 结构，这意味着前端不是自己从原始计数器拼装"健康度"，而是和后端共享同一套指标解释。

此外，`build_usage_report` 提供了按 session 的 token usage 报告，让 API keys panel 能够展示每个 key 的消费情况。

## 嵌入式前端：React + Vite + TypeScript

Web 前端使用 `include_dir` 宏在编译时嵌入到二进制文件中。这意味着部署 MicroClaw 不需要额外的静态文件服务器——前端资产直接从内存中提供。

前端使用 React + Vite + TypeScript 构建，集成了 `@assistant-ui/react` 组件库。这个组件库提供了专业的聊天 UI 组件，包括消息气泡、流式文本显示、工具调用展示等。

前端的主要面板包括：

- **Chat 面板**：消息历史、流式输入、abort 按钮
- **Session Tree**：左侧栏展示所有 session，支持 fork 和 delete
- **Skills 面板**：查看和激活已安装的 skills
- **API Keys 面板**：管理 API key 的创建、scope 和吊销
- **Usage/Metrics 面板**：token 消耗、工具使用统计
- **Memory/Reflector 面板**：查看记忆系统状态和 reflector 运行日志

```{=typst}
#pagebreak(weak: true)
```

## 示例代码：流式控制面为什么必须暴露运行事件？

流式接口最重要的不是框架语法，而是它必须把统一循环里的中间事件稳定暴露给控制面。只有这样，前端和运维人员才能判断系统究竟卡在模型、工具还是审批上。

Rust 版本把事件输出收敛到 `EventSink` trait，再由一个 `RunStreamer` 负责按顺序推送关键阶段。

```rust
#[async_trait::async_trait]
trait EventSink {
    async fn send(&self, event: RunEvent) -> anyhow::Result<()>;
}

struct RunStreamer<S> {
    sink: S,
    run_hub: RunHub,
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

Python 版本保留同样的接口语义。

```python
from dataclasses import dataclass
from typing import Protocol


@dataclass
class RunEvent:
    id: int
    event: str
    data: str


class EventSink(Protocol):
    async def send(self, event: RunEvent) -> None: ...


@dataclass
class RunStreamer:
    sink: EventSink

    async def stream_run(self) -> None:
        await self.sink.send(RunEvent(1, "iteration_start", "1"))
        await self.sink.send(RunEvent(2, "tool_start", "bash"))
        await self.sink.send(RunEvent(3, "text_delta", "Hello"))
        await self.sink.send(RunEvent(4, "done", ""))
```

## 关键权衡

### 决策一：同时支持 SSE 和 WebSocket

优点是 SSE 对浏览器兼容性好、实现简单，WebSocket 支持双向通信和更丰富的交互。代价是需要维护两套推送通道的一致性。

### 决策二：Bootstrap token + API key scope 模型

优点是安全基线从 Day 1 就建立。代价是初始设置比"默认密码直接用"更复杂。但这正是正确的取舍——安全不应该是事后补的。

### 决策三：Chat abort 作为一等能力

优点是用户和自动化脚本都能安全中止失控的 agent run。代价是需要在 agent engine 的每个迭代点检查 abort flag，增加了执行路径的复杂度。

### 决策四：嵌入式前端

优点是部署极简——一个二进制文件包含全部资产。代价是前端更新需要重新编译整个二进制。

### 决策五：用 RunHub 承载流式执行状态

优点是前端能真实观察执行过程，并支持 replay。代价是需要维护运行历史、订阅权限和清理策略。

## 容易走错的地方

### 失败模式 1：把 Web 当成单纯聊天前端

这样会低估它在会话管理、配置治理、API key 管理和观测上的职责。MicroClaw 的 Web 是一个完整的运维控制面。

### 失败模式 2：不做 abort 就上线流式 API

没有 abort 机制的流式 API，用户只能等待 agent run 自然结束。如果 run 陷入循环或选择了错误的工具，用户完全束手无策。

### 失败模式 3：控制面上线后再补鉴权

到那时通常已经形成了不安全的默认用法和外部依赖。bootstrap token 的设计就是为了避免这个问题。

### 失败模式 4：前端自己拼健康度，后端只给原始数据

这会导致口径漂移，最终无法形成稳定运维标准。`/api/metrics/summary` 的 SLO 结构确保前后端共享同一套解释。

## 读到这里，你应该能回答

- 你是否理解 Web 在 MicroClaw 中是特殊渠道，而不是普通 UI 外壳？
- 你是否能说清 RunHub 如何同时支撑 SSE 和 WebSocket 的事件广播和 replay？
- 你是否为控制面设计了 bootstrap token 和 API key scope 模型？
- 你是否让 chat abort 成为流式 API 的一等能力？
- 你是否按运维职责组织 API 路由，而不是按页面临时需求堆接口？

## 证据来源（v0.1.38）

- 核心源码路径：`src/web.rs`（5548 行）、`src/web/auth.rs`、`src/web/sessions.rs`、`src/web/stream.rs`、`src/web/ws.rs`、`src/web/chat_abort.rs`、`src/web/metrics.rs`、`src/web/config.rs`、`src/web/skills.rs`、`src/web/a2a.rs`、`src/web/middleware.rs`
- 关键配置项：`src/config.rs` 中与 `web_enabled`、`web_port`、`web_host`、`web_max_inflight_per_session`、`web_max_requests_per_window`、`web_rate_window_seconds`、`web_run_history_limit`、`web_session_idle_ttl_seconds` 相关的默认值
- WebSocket 协议：`src/web/ws.rs` 中的 `PROTOCOL_VERSION = 3`、`ClientFrame`、`ResponseFrame`、`EventFrame`

## 小结

MicroClaw v0.1.38 的 Web 与 API 设计已经从 v0.1.16 的"基础控制面"演进为一个完整的运维界面。RunHub 支撑了 SSE + WebSocket 双通道事件广播和历史回放。Chat abort 让用户和自动化脚本能安全中止失控的 agent run。Bootstrap token 和 API key scope 模型建立了安全基线。嵌入式 React+Vite 前端提供了 session tree、skills panel、API keys 管理和 usage metrics 等专业运维能力。控制面不是附加组件，而是 runtime 可托管性的核心组成部分。

下一章我们进入最后一个内核主题：MCP、Skills、Plugins 和新增的 A2A、ACP 和 Hooks。它们决定了这个 runtime 不只是能运行自身能力，还能怎样在不破坏主链路的前提下持续吸收外部能力和被外部控制。

## 图表清单

### 图 11-1：Web 控制面在 runtime 中的位置

![图 11-1：Web 控制面在 runtime 中的位置](../assets/figures/fig-11-web-control-plane.svg)

这张图展示 Web 作为特殊渠道在 runtime 中的位置，包括 RunHub 的 SSE/WS 双通道事件广播、Chat abort 机制和 API 路由的运维域划分。

如需继续扩展配图，本章还可补：

- 图 11-2：RunHub 事件广播与 replay 机制
- 图 11-3：Bootstrap token + API key scope 鉴权流程
