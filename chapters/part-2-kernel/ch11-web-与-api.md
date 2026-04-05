# Chapter 11 Web 与 API

## 这一章要回答什么问题

纯聊天入口不够用时，控制面应该提供什么？——会话管理、流式观察、运行中止、API key 管理、可视化运维。

## Web 是特殊渠道

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

Web 参与统一会话体系、触发统一循环，但它是本地控制面入口。ACP 也有同样姿态：`is_local_only = true`、`allows_cross_chat = false`。

## API 路由按运维域划分

| 子模块 | 职责 |
|--------|------|
| `auth` | 登录、session、bootstrap token、API key CRUD |
| `sessions` | 会话列表、历史、fork、delete、reset |
| `config` | 配置读取、自检、风险提示 |
| `metrics` | 观测视图、SLO、usage report |
| `stream` | SSE 流式事件推送 |
| `ws` | WebSocket 双向通信 |
| `skills` | 技能列表、激活 |
| `a2a` | Agent-to-Agent 协议端点 |
| `chat_abort` | 运行中止 |
| `middleware` | 鉴权、节流、CORS |

## RunHub：事件广播 + 历史回放

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

推送事件：迭代开始、工具启动/结果、文本增量、完成/中止。每个 `RunChannel` 保存事件历史（默认 512 条），前端断线重连后可从历史回放。

### SSE vs WebSocket

| 维度 | SSE | WebSocket |
| --- | --- | --- |
| 方向 | 单向（服务器→客户端） | 双向 |
| 协议 | 浏览器原生 `EventSource` | JSON 帧，`PROTOCOL_VERSION = 3` |
| 发送消息 | 不支持 | 支持（chat、slash command） |
| 中止请求 | 不支持 | 支持（abort 帧） |
| 心跳 | 无 | 15s |
| 适用场景 | 简单流式展示 | 完整交互控制面 |

### 控制面事件 DTO

```rust
struct RunEvent {
    id: u64,
    event: String,
    data: String,
}
```

```python
from dataclasses import dataclass


@dataclass
class RunEvent:
    id: int
    event: str
    data: str
```

## Chat Abort

```
前端 POST /api/chat/abort → 查找 run_id controller
  → 验证 session_key 匹配 → 设置 aborted flag
    → Agent engine 检测 flag → 停止执行 → 返回 partial text
```

每个 controller 包含 `aborted: Arc<AtomicBool>` + `buffer: Arc<RwLock<String>>` + `session_key`。Agent engine 在每次迭代和工具调用间检查 flag。`abort_chat_runs_for_session_key` 支持批量中止。

## Bootstrap Token 与 API Key

### Bootstrap Token

首次启动时生成，管理员用它调用 `POST /api/auth/set-password` 设置初始密码。密码设置后 token 即销毁（`*guard = None`），只存内存、一次性。

### API Key Scope

```rust
const ALLOWED_API_KEY_SCOPES: &[&str] = &[
    "operator.read",
    "operator.write",
    "operator.admin",
    "operator.approvals",
];
```

所有请求经 `require_scope` 中间件检查。支持 Bearer token 和 cookie 认证。登录有节流保护防暴力破解。

## Session 管理

- **列表**：`GET /api/sessions` 返回最近 400 个会话。
- **历史**：`GET /api/history?session_key=xxx`，支持 `limit` 分页。
- **Reset/Delete**：Web session 直接删除；外部渠道 session 只清消息保留 chat 元数据。delete 同时清理 todo 数据。

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

`RequestHub` 维护 per-session + per-actor 两层配额。

## Metrics 与可观测

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

`/api/metrics/summary` 暴露显式 SLO 结构，前后端共享同一套指标解释。`build_usage_report` 提供按 session 的 token usage。

## 嵌入式前端

`include_dir` 宏编译时嵌入——部署无需额外静态服务器。React + Vite + TypeScript + `@assistant-ui/react`。

| 面板 | 功能 |
| --- | --- |
| Chat | 消息历史、流式输入、abort |
| Session Tree | 所有 session、fork/delete/切换 |
| Skills | 查看/激活/停用 |
| API Keys | 创建、scope、吊销 |
| Usage/Metrics | token 消耗、工具统计 |
| Memory/Reflector | 记忆状态、reflector 日志 |

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

## 容易走错的地方

| 失败模式 | 后果 |
|---------|------|
| 把 Web 当单纯聊天前端 | 低估会话管理、配置治理、API key、观测职责 |
| 不做 abort 就上线流式 API | 用户对失控 run 束手无策 |
| 控制面上线后再补鉴权 | 已形成不安全的默认用法 |
| 前端自己拼健康度 | 前后端口径漂移，运维标准不稳 |

## 关键权衡

| 决策 | 优点 | 代价 |
|------|------|------|
| SSE + WebSocket 双通道 | 兼容性 + 丰富交互 | 维护两套推送一致性 |
| Bootstrap token + scope | 安全基线 Day 1 建立 | 初始设置比默认密码复杂 |
| Chat abort 一等能力 | 用户/脚本可安全中止失控 run | 每个迭代点需检查 flag |
| 嵌入式前端 | 部署极简，一个二进制 | 前端更新需重编译 |
| RunHub 承载流式状态 | 真实观察执行 + replay | 需维护历史和清理策略 |

## 图表清单

### 图 11-1：Web 控制面在 runtime 中的位置

![图 11-1：Web 控制面在 runtime 中的位置](../assets/figures/fig-11-web-control-plane.svg)
