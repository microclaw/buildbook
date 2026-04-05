# Chapter 12 MCP、Skills、Plugins 与协议扩展

## 七种扩展机制如何各司其职而不破坏主链路？

任何一个认真做 Agent Runtime 的项目，最终都会碰到同一个问题：内置能力总有边界，但扩展能力如果接得太随意，又会迅速破坏稳定性。MicroClaw v0.1.38 对这个问题的回答，不再只是 MCP + Skills + Plugins 三层扩展，而是新增了三个完整的协议维度：

- **A2A**（Agent-to-Agent）：同级 Agent 之间的通信协议。
- **ACP**（Agent Client Protocol）：外部客户端通过 stdio 控制 Agent 的无头协议。
- **Hooks**：以 `HOOK.md` 为载体的事件拦截扩展，可以 allow、block 或 modify 工具调用和 LLM 请求。

加上已有的 MCP、Skills、Plugins 和 ClawHub，MicroClaw 现在有七种不同层次的扩展机制。它们看起来很多，但解决的问题完全不同。这一章读完后，你应该已经能分清：

1. 哪些扩展是"接外部执行能力"（MCP）。
2. 哪些扩展是"给 Agent 注入专业知识和工作流"（Skills）。
3. 哪些扩展适合本地团队自定义（Plugins）。
4. 哪些扩展是"Agent 之间的通信"（A2A）。
5. 哪些扩展是"外部程序控制 Agent"（ACP）。
6. 哪些扩展是"在执行路径中插入拦截点"（Hooks）。
7. 为什么扩展必须和风险控制一起设计。

## MCP：把外部工具接进统一 runtime

MicroClaw 的 MCP 客户端实现位于 `src/mcp.rs`（967 行），使用 `rmcp` crate 作为底层传输。v0.1.38 支持两类传输：

- **stdio**：启动一个子进程，通过 stdin/stdout 通信。使用 `TokioChildProcess`。
- **streamable_http**（别名 `http`）：通过 HTTP 连接远程 MCP server。使用 `StreamableHttpClientTransport`。

### Per-Server 韧性配置

v0.1.38 最重要的 MCP 改进是 per-server 韧性配置。每个 MCP server 可以独立配置：

```rust
pub struct McpServerConfig {
    pub transport: String,
    pub request_timeout_secs: Option<u64>,
    pub max_retries: Option<u32>,
    pub health_interval_secs: Option<u64>,
    pub circuit_breaker_failure_threshold: Option<u32>,
    pub circuit_breaker_cooldown_secs: Option<u64>,
    pub max_concurrent_requests: Option<u32>,
    pub queue_wait_ms: Option<u64>,
    pub rate_limit_per_minute: Option<u32>,
    // ... transport-specific fields
}
```

这些不是全局默认值——每个 MCP server 都可以有自己的超时、重试、熔断和限流参数。这非常重要，因为不同的 MCP server 有完全不同的可靠性特征。一个本地文件系统 server 可以很激进（短超时、不限流），而一个远程 API server 需要更保守的配置。

### 熔断器实现

`CircuitBreakerState` 实现了经典的 circuit breaker 模式：

- **关闭状态**（正常）：请求通过，记录成功/失败。
- **触发条件**：连续失败次数达到 `threshold`（默认 5）。
- **打开状态**（熔断）：所有请求直接被拒绝，返回"circuit open; retry in ~Ns"。
- **冷却期**：`cooldown_secs`（默认 30）后自动关闭，允许试探性请求通过。

threshold 和 cooldown 都可以通过配置为 0 来禁用。不需要熔断保护的本地 server 可以跳过这层检查。

### 并发控制与限流

- **Bulkhead**：`inflight_limiter`（`Semaphore`）限制每个 server 的最大并发请求数（默认 4），超出的请求在 `queue_wait`（默认 200ms）内等待 permit。
- **Rate Limiter**：`FixedWindowRateLimiter` 限制每分钟的请求数（默认 120）。

### 工具缓存与刷新

MCP server 的工具列表被缓存在 `tools_cache` 中，TTL 为 300 秒。调用工具时，如果工具名不在缓存中，会先强制刷新缓存。如果调用返回"tool not found"错误，也会触发缓存刷新。这种 lazy + reactive 的刷新策略平衡了性能和正确性。

### 多配置源合并

`merge_config_sources` 支持从多个配置文件加载 MCP server 定义。后面的配置文件会覆盖前面的同名 server。这让组织级配置和项目级配置可以分层叠加。

## Skills：给 Agent 注入可发现、可激活的专业能力

`src/skills.rs` 展示了另一条完全不同的扩展路径。Skill 不是远程工具，而是以 `SKILL.md` 为核心载体的专业化能力包。系统会解析 frontmatter，识别：

```rust
pub struct SkillMetadata {
    pub name: String,
    pub description: String,
    pub dir_path: PathBuf,
    pub platforms: Vec<String>,
    pub deps: Vec<String>,
    pub source: String,
    pub version: Option<String>,
    pub updated_at: Option<String>,
    pub env_file: Option<String>,
}
```

v0.1.38 的 Skills 系统增加了更丰富的元数据支持，包括 `compatibility` 检查（OS 和二进制依赖）和 `metadata.openclaw` / `metadata.clawdbot` 扩展字段。这意味着 Skill 不仅可以声明自己需要哪些平台和依赖，还可以在安装时自动检查这些条件是否满足。

Skills 的运行方式：

- 通过 `activate_skill` 工具动态激活，把 SKILL.md 的内容注入到当前会话的 system prompt 中。
- 通过 `sync_skills` 从外部来源同步并规范化 frontmatter。
- 兼容 Anthropic Skills 路线。

### 扩展元数据为什么必须先变成统一清单？

一旦系统同时支持 MCP、Skills ��� Plugins，最危险的不是扩展太少，而是每种扩展都用自己的元数据口径。

Rust 版本用统一结构收敛扩展元数据：

```rust
struct ExtensionManifest {
    name: String,
    source: String,   // "mcp", "skill", "plugin"
    kind: String,     // "tool", "prompt", "command"
    execution_mode: String,
}
```

Python 版本用 `@dataclass` 表达同一结构：

```python
from dataclasses import dataclass


@dataclass
class ExtensionManifest:
    name: str
    source: str
    kind: str
    execution_mode: str
```

## Plugins：给团队本地自定义留下空间

`src/plugins.rs`（1728 行）定义了三类本地扩展能力：

### 自定义 Slash Commands

通过 `PluginCommandSpec` 定义，例如 `/uptime`、`/announce`。命令执行通过外部脚本完成。

### 自定义 Plugin Tools

通过 `PluginToolSpec` 定义。每个 tool 有完整的 JSON Schema、执行策略和沙箱配置。

### Context Providers

这是插件里最容易被忽视但工程价值最高的设计。它允许插件在每轮执行前注入额外 prompt 或文档片段，从而把本地规则、runbook、策略文档变成 runtime 的上下文组成部分。

### 执行策略

插件执行支持三种模式：

```rust
enum PluginExecutionPolicy {
    HostOnly,
    SandboxOnly,
    Dual,
}
```

`SandboxOnly` 要求 sandbox runtime 可用时才允许执行，这是一个重要的安全约束。`Dual` 则优先在 sandbox 中执行，不可用时 fallback 到 host。

## ClawHub：技能分发与供应链治理

`src/clawhub/` 和 `crates/microclaw-clawhub/` 实现了完整的技能注册中心客户端：

- CLI 支持 `search / install / list / inspect / available`
- Agent 工具支持 `clawhub_search`、`clawhub_install`
- 安装状态通过 `clawhub.lock.json` 记录

lockfile 的重要性无论怎么强调都不为过。一旦能力来自外部源，供应链可追踪性就会变得非常重要：

- 知道装了什么
- 知道版本和来源
- 有利于 CI 审计
- 生产环境可以固定版本

`clawhub.lock.json` 的角色，和 `package-lock.json` 或 `Cargo.lock` 完全类似。默认的 skills 安装目录也被标准化了，让项目间的技能管理保持一致。

## A2A 协议：Agent 之间的通信

`src/a2a.rs` 定义了 Agent-to-Agent 通信协议。这不是简单的"调 HTTP 接口"，而是一个有明确身份、版本和端点发现机制的协议。

### Agent Card

每个 MicroClaw 实例可以发布一个 `A2AAgentCard`：

```rust
pub struct A2AAgentCard {
    pub protocol_version: String,  // "microclaw-a2a/v1"
    pub agent_id: String,
    pub agent_name: String,
    pub description: Option<String>,
    pub public_base_url: Option<String>,
    pub endpoints: A2AEndpoints,
    pub capabilities: Vec<String>,
}
```

Agent Card 暴露在 `/api/a2a/agent-card`，其他 Agent 可以通过这个端点发现对方的能力和通信入口。

### 消息通信

`/api/a2a/message` 接受 `A2AMessageRequest`，包含 session_key、sender_name、source_agent 和 message。系统会为每个来源 agent 自动生成默认 session key（`a2a:{source_name}`），让对话历史自然隔离。

### Peer 配置

A2A peers 在配置中声明：

```rust
pub struct A2APeerConfig {
    pub enabled: bool,
    pub base_url: String,
    pub bearer_token: Option<String>,
    pub description: Option<String>,
    pub default_session_key: Option<String>,
}
```

Agent 工具侧提供 `a2a_list_peers` 和 `a2a_send`，让 Agent 可以在对话中主动联系其他 Agent。这意味着 MicroClaw 实例之间可以形成一个松耦合的 Agent 网络。

## ACP 协议：外部客户端的无头控制

`src/acp.rs`（492 行）实现了 Agent Client Protocol——一个通过 stdio 控制 Agent 的标准化协议。这和 Web 控制面解决的是不同的问题：Web 是给人用的图形界面，ACP 是给程序用的无头接口。

### 协议能力

ACP 实现了 `agent_client_protocol` crate 定义的标准接口：

```rust
impl Agent for MicroClawAcpAgent {
    async fn initialize(&self, args: InitializeRequest) -> AcpResult<InitializeResponse>;
    async fn authenticate(&self, args: AuthenticateRequest) -> AcpResult<AuthenticateResponse>;
    async fn new_session(&self, args: NewSessionRequest) -> AcpResult<NewSessionResponse>;
    async fn load_session(&self, args: LoadSessionRequest) -> AcpResult<LoadSessionResponse>;
    async fn set_session_mode(&self, args: SetSessionModeRequest) -> AcpResult<SetSessionModeResponse>;
    async fn prompt(&self, args: PromptRequest) -> AcpResult<PromptResponse>;
    async fn cancel(&self, args: CancelNotification) -> AcpResult<()>;
}
```

### 完整 runtime 复用

ACP 不是一个简化版的 Agent。它构建了完整的 `AppState`，包括 LLM provider、tool registry、memory backend、MCP manager——和 Web 渠道用的完全相同。唯一的区别是：

- Channel 是 `AcpAdapter`（`is_local_only = true`）
- 没有 OTLP 观测 exporter（ACP 是轻量 CLI 模式）
- Session 管理通过 ACP 的 session_id 机制完成

### 内容块处理

`flatten_prompt` 函数处理 ACP 协议中的多种内容块类型：Text、ResourceLink、TextResource、BlobResource、Image、Audio。这意味着 ACP 客户端可以附带文件上下文、嵌入资源等富内容，而不仅是纯文本。

### 流式输出

ACP 通过 `AgentEvent::TextDelta` 向客户端推送增量文本。这让 CLI 客户端能够实时显示 Agent 的输出，体验接近 Web 的流式响应。

### 取消支持

`cancel` 方法通过 `run_control::abort_runs` 实现请求取消。这和 Web 的 chat abort 机制共享同一套底层基础设施。

## Hooks：事件拦截扩展

`src/hooks.rs`（766 行）引入了一种全新的扩展机制——在 Agent 执行路径的关键点插入拦截器。

### Hook 定义

Hooks 以 `HOOK.md` 文件为载体，使用 YAML frontmatter 定义元数据：

```yaml
---
name: block-dangerous-commands
description: Block potentially dangerous bash commands
events: [BeforeToolCall]
command: "sh check.sh"
enabled: true
timeout_ms: 2000
priority: 100
---
```

### 三个拦截点

```rust
pub enum HookEvent {
    BeforeLLMCall,      // LLM 调用前
    BeforeToolCall,     // 工具调用前
    AfterToolCall,      // 工具调用后
}
```

### 三种响应

Hook handler 脚本通过 stdin 接收 JSON payload，通过 stdout 返回 JSON response：

```rust
enum HookOutcome {
    Allow { patches: Vec<serde_json::Value> },  // 放行，可选修改
    Block { reason: String },                    // 阻止，附带原因
}
```

- **allow**：放行。
- **block**：阻止执行，附带阻止原因。
- **modify**：放行，但应用 patch（例如修改工具参数）。

### 执行模型

Hook handler 以外部进程运行：

1. 系统通过 shell 执行 hook 的 `command`。
2. 通过 stdin 传入 JSON payload（包含 event、chat_id、tool_name、tool_input 等）。
3. 设置环境变量 `MICROCLAW_HOOK_EVENT` 和 `MICROCLAW_HOOK_NAME`。
4. 等待 handler 返回 JSON response。
5. 超时保护（默认 1500ms，可配置 10ms - 120s）。
6. 输入和输出均有字节限制（`max_input_bytes`、`max_output_bytes`）。

### 优先级与排序

多个 hook 匹配同一事件时，按 `priority` 排序（数值越小越优先），相同优先级按名称排序。任何一个 hook 返回 block，整个操作被阻止。

### CLI 管理

```
microclaw hooks list          # 列出所有发现的 hooks
microclaw hooks info <name>   # 查看 hook 详情
microclaw hooks enable <name> # 启用
microclaw hooks disable <name># 禁用
```

启用/禁用状态持久化到 `hooks_state.json`，独立于 hook 本身的 `enabled` 默认值。

### 审计

Hook 的 block 和 modify 操作会被记录到审计日志（`log_audit_event`），让安全团队可以追踪哪些操作被拦截了。

## 七种扩展方式分别解决什么问题

| 扩展方式 | 解决的问题 | 方向 |
|---------|-----------|------|
| MCP | 接入外部现成工具能力 | Runtime → 外部 |
| Skills | 向 Agent 注入专业知识和工作流 | 内容 → Agent |
| Plugins | 本地团队快速加上特定能力 | 本地 → Runtime |
| ClawHub | 技能分发与供应链治理 | 生态 → 本地 |
| A2A | Agent 之间的通信 | Agent ↔ Agent |
| ACP | 外部程序控制 Agent | 程序 → Agent |
| Hooks | 在执行路径中插入拦截和审计 | 安全 → Runtime |

一旦分清这七件事，你就不会再问"为什么不只保留一种扩展机制"。因为它们根本不在同一层。

## 扩展的安全边界

### MCP 的风险边界

per-server 的超时、限流、熔断和并发控制，确保外部 server 的抖动不会拖垮整个 agent loop。工具缓存的 reactive 刷新机制也防止了过时工具定义导致的错误调用。

### Skills 的风险边界

通过平台兼容检查（OS、二进制依赖）、依赖检查、启停状态文件和 availability diagnostics，系统避免"看到一个 SKILL.md 就直接启用"。

### Plugins 的风险边界

`PluginExecutionPolicy` 的三级模型（HostOnly / SandboxOnly / Dual）确保敏感插件不会在没有沙箱的环境中裸执行。

### Hooks 的风险边界

Hook handler 以外部进程运行，有超时保护、输入输出字节限制和审计日志。handler 失败不会阻止主流程——它只会在日志中记录错误并 continue。

### A2A 的风险边界

peer 配置需要显式声明 `base_url` 和可选的 `bearer_token`。Agent 不会自动发现和连接未配置的 peer。

### ACP 的风险边界

ACP 运行在 stdio 上，天然只对本地进程开放。它使用独立的 `AcpAdapter`（`is_local_only = true`），不会影响其他渠道。

```{=typst}
#pagebreak(weak: true)
```

## 示例代码：MCP 调用和 Skill 载入为什么要走不���扩展路径？

这组例子故意拆成两类：一个代表远程能力调用，一个代表本地技能激活。两者都属于扩展，但它们解决的问题完全不同，所以不应该被同一种接口强行抹平。

Rust 版本用两个 trait 明确区分"远程工具联邦"和"本地能力目录"，加上 hook 拦截，再用一个 struct 编排：

```rust
#[async_trait::async_trait]
trait McpClient {
    async fn call_tool(&self, name: &str, input: serde_json::Value) -> anyhow::Result<String>;
}

#[async_trait::async_trait]
trait SkillCatalog {
    async fn activate(&self, skill_name: &str) -> anyhow::Result<String>;
}

#[async_trait::async_trait]
trait HookRunner {
    async fn check_before_tool(&self, tool_name: &str, input: &serde_json::Value) -> anyhow::Result<bool>;
}

struct ExtensionRuntime<M, S, H> {
    mcp: M,
    skills: S,
    hooks: H,
}
```

```rust
impl<M: McpClient, S: SkillCatalog, H: HookRunner> ExtensionRuntime<M, S, H> {
    async fn extend(
        &self,
        tool: &str,
        input: serde_json::Value,
        skill: &str,
    ) -> anyhow::Result<(String, String)> {
        if !self.hooks.check_before_tool(tool, &input).await? {
            return Err(anyhow::anyhow!("blocked by hook"));
        }
        let remote = self.mcp.call_tool(tool, input).await?;
        let local = self.skills.activate(skill).await?;
        Ok((remote, local))
    }
}
```

```{=typst}
#pagebreak(weak: true)
```

Python 版本保留相同的分层：

```python
from dataclasses import dataclass
from typing import Any, Protocol


class McpClient(Protocol):
    async def call_tool(self, name: str, input: dict[str, Any]) -> str: ...


class SkillCatalog(Protocol):
    async def activate(self, skill_name: str) -> str: ...


class HookRunner(Protocol):
    async def check_before_tool(self, tool_name: str, input: dict[str, Any]) -> bool: ...


@dataclass
class ExtensionRuntime:
    mcp: McpClient
    skills: SkillCatalog
    hooks: HookRunner
```

```python

    async def extend(
        self, tool_name: str, input: dict[str, Any], skill_name: str
    ) -> tuple[str, str]:
        if not await self.hooks.check_before_tool(tool_name, input):
            raise RuntimeError("blocked by hook")
        tool_result = await self.mcp.call_tool(tool_name, input)
        skill_result = await self.skills.activate(skill_name)
        return tool_result, skill_result
```

## 关键权衡

### 决策一：MCP per-server 韧性配置

优点是每个 MCP server 可以根据自身特征独立调参。代价是配置面增加，需要更清晰的文档来解释每个参数的含义和默认值。

### 决策二：同时保留七种扩展路径

优点是能覆盖外部能力联邦、专业能力包、本地定制、Agent 间通信、程序化控制和事件拦截六大类需求。代价是概念面增加，新用户的学习曲线更陡。

### 决策三：Hooks 以外部进程运行

优点是 hook handler 可以用任何语言实现，crash 不影响主进程。代价是每次 hook 调用有进程启动开销，不适合高频执行。

### 决策四：ACP 复用完整 runtime

优点是 ACP 和 Web 行为完全一致。代价是 ACP 进程的资源占用和启动时间比一个纯 stdio proxy 更高。

### 决策五：A2A 使用显式 peer 配置

优点是安全——Agent 不会连接未声明的 peer。代价是没有自动发现机制，新增 peer 需要修改配置。

## 容易走错的地方

### 失败模式 1：把所有扩展问题都塞进一种机制

这样要么会让协议负担过重（如果都走 MCP），要么会让本地定制体验极差（如果都走 Plugins）。

### 失败模式 2：MCP 没有 per-server 韧性配置

一个有问题的 MCP server 会拖垮所有使用该 server 的工具调用，进而拖垮整个 agent loop。

### 失败模式 3：Hook handler 没有超时和字节限制

一个挂起的 hook handler 会阻塞整个执行路径。MicroClaw 通过 `timeout_ms.clamp(10, 120_000)` 和 `max_input_bytes` / `max_output_bytes` 防止这种情况。

### 失败模式 4：从外部安装能力时不做版本与来源追踪

这会在生产环境里留下非常糟糕的供应链审计空洞。`clawhub.lock.json` 的设计就是为了解决这个问题。

### 失败模式 5：ACP 实现只支持纯文本

ACP 协议支持 ResourceLink、EmbeddedResource、Image 和 Audio 等富内容类型。如果只实现纯文本，就会丢失 ACP 的核心价值。

## 读到这里，你应该能回答

- 你是否知道 MCP、Skills、Plugins、A2A、ACP、Hooks 各自解决的是什么问题？
- 你是否为每个 MCP server 配置了独立的超时、限流、熔断参数？
- 你是否让 Hook handler 有超时保护和审计日志？
- 你是否理解 ACP 为什么需要复用完整 runtime 而不是做一个 thin proxy？
- 你是否为外部安装能力保留了 lockfile 和来源审计？

## 证据来源（v0.1.38）

- 核心源码路径：`src/mcp.rs`、`src/skills.rs`、`src/plugins.rs`、`src/a2a.rs`、`src/acp.rs`、`src/hooks.rs`、`src/clawhub/`、`src/tools/a2a.rs`、`src/web/a2a.rs`
- 关键配置项：`src/config.rs` 中与 MCP server 韧性、Skills 目录、Plugins 执行策略、A2A peer、ACP 启用和 Hooks 运行时设置相关的配置
- 外部 crate 依赖：`rmcp`（MCP 传输）、`agent_client_protocol`（ACP 协议）、`microclaw-clawhub`（ClawHub 客户端）

## 小结

MicroClaw v0.1.38 的扩展生态从 v0.1.16 的三层（MCP + Skills + Plugins）扩展到了七层（加上 A2A、ACP、Hooks 和增强的 ClawHub）。MCP 获得了 per-server 韧性配置，让外部工具的可靠性可以被精确治理。A2A 让 Agent 实例之间能够通信，形成松耦合的 Agent 网络。ACP 让外部程序能够通过 stdio 完整控制 Agent。Hooks 在执行路径的关键点插入了可编程的拦截机制。

这些扩展机制共同说明了一点：真正可持续的 runtime，不是只会不断往内核里加功能，而是能在不破坏主链路稳定性的前提下，通过多层次协议逐步吸收外部能力、建立安全边界、支持团队自定义和 Agent 间协作。

下一章，我们不再继续扩展能力面，而是转向生产视角：安全、可观测、测试、性能、演进和交付实践。这些内容决定了一个已经"能跑"的 MicroClaw，能否真的变成一个可托管的系统。

## 图表清单

### 图 12-1：七种扩展机制的分层位置图

![图 12-1：七种扩展机制的分层位置图](../assets/figures/fig-12-extension-layers.svg)

这张图展示 MCP、Skills、Plugins、ClawHub、A2A、ACP、Hooks 七种扩展机制在 runtime 架构中的分层位置和方向性（Runtime → 外部、内容 → Agent、Agent ↔ Agent、安全 → Runtime 等）。

如需继续扩展配图，本章还可补：

- 图 12-2：MCP 客户端的 per-server 韧性控制链（rate limit → bulkhead → circuit breaker → timeout → retry）
- 图 12-3：Hook 事件拦截流程（BeforeLLMCall / BeforeToolCall / AfterToolCall → allow / block / modify）
