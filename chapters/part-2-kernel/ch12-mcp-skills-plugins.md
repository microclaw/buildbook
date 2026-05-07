# Chapter 12 MCP、Skills、Plugins 与协议扩展

## 这一章要回答什么问题

五种扩展机制（MCP、Skills、Plugins、A2A、ACP）外加治理 Hooks，如何在统一的风险边界内协同？答案是它们最终都要走 `ToolRegistry` → `BeforeToolCall` hook → sandbox 路由这条收敛通道。

## MCP：接入外部工具

`src/mcp.rs` 提供 stdio（`TokioChildProcess`）和 streamable_http 两类传输，每个 server 独立配置韧性参数。

### `McpServerConfig` 关键字段

```rust
pub struct McpServerConfig {
    pub transport: String,              // "stdio" | "streamable_http" | "http"
    pub protocol_version: Option<String>,
    pub timeout_secs: Option<u64>,
    pub max_retries: Option<u32>,
    pub circuit_breaker_failure_threshold: Option<u32>, // 默认 5，0 禁用
    pub circuit_breaker_cooldown_secs: Option<u64>,     // 默认 30s
    pub bulkhead_max_concurrent: Option<u32>,           // 默认 4
    pub bulkhead_acquire_timeout_ms: Option<u64>,       // 默认 200ms
    pub rate_limit_per_minute: Option<u32>,             // 默认 120
    // streamable_http
    pub endpoint: Option<String>,
    pub headers: Option<HashMap<String, String>>,
}
```

调用路径：

```
工具调用请求 → Rate Limiter（默认 120/min）
  → Bulkhead（Semaphore，默认 4 并发，200ms 内拿不到 permit 即拒）
    → Circuit Breaker（连续失败 5 次打开，30s 后自动关）
      → 超时保护 → 重试（最多 max_retries 次）
        → 工具执行 → 返回结果
```

工具列表本身缓存 300s；缓存里没有或返回 "tool not found" 时才触发刷新——在响应延迟与配置实时性之间取折中。

### 配置文件：`mcp.json` + `mcp.d/*.json`

主配置在 `<data_root>/mcp.json`，drop-in 目录 `<data_root>/mcp.d/*.json`。多源合并时同名 server 后者覆盖前者，方便发行版打包默认 server、用户在 drop-in 覆盖。

## Skills：内容形态的扩展

Skill 以目录 + `SKILL.md` + frontmatter 描述：

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

两个来源：内置（启动时 `builtin_skills::ensure_builtin_skills` 写到 `<data_root>/skills/`）+ 用户安装（来自 ClawHub 或本地文件）。

### 工具表面

| 工具 | 作用 |
|------|------|
| `skill_manage` | 本地 skill 生命周期：通过 `action` 完成 list / inspect / delete / patch |
| `clawhub_search` | 在 ClawHub 远端目录中按关键词或标签检索 |
| `clawhub_install` | 从 ClawHub 拉取并写入本地 `skills/`，更新锁文件 |
| `sync_skills` | 与外部源（ClawHub 或镜像）批量同步 |
| `activate_skill` | 加载某 skill 的内容并注入到当前对话 |

激活动作写入 `skill_activation_logs` 表；自动归档脚本据此把长期未用的 skill 移出活跃集，控制 prompt 体积。`skill_manage` 与 `clawhub_*` 的区分体现了 MicroClaw 对"本地状态 vs 远端供应链"的分层：本地动作不需要网络，远端动作走 `gate.rs` 的入站校验。

### ClawHub 客户端

`crates/microclaw-clawhub/src/` 拆成五个文件：

- `client.rs`：HTTP 客户端
- `gate.rs`：入站校验（域名、签名、版本约束）
- `install.rs`：解包、写入文件系统、记账
- `lockfile.rs`：`clawhub.lock.json`（角色等同 `Cargo.lock`，供应链可追踪）
- `types.rs`：序列化结构

## Plugins：本地团队自定义

`src/plugins.rs` 把"团队私有扩展"切成三类：

| 类型 | 结构 | 说明 |
|------|------|------|
| Slash Commands | `PluginCommandSpec` | 通过外部脚本执行 |
| Plugin Tools | `PluginToolSpec` | JSON Schema + 执行策略 + 沙箱 |
| Context Providers | `PluginContextProviderSpec` | 每轮执行前注入 prompt 片段 |

由 `PluginManifest` 聚合，按目录约定加载。`load_plugin_manifests` 验证后注册到 `ToolRegistry`。

### 三档执行策略

```rust
pub enum PluginExecutionPolicy {
    HostOnly,
    SandboxOnly,
    Dual,
}
```

- `HostOnly`：直接在 host 跑，适合可信脚本。
- `SandboxOnly`：必须沙箱可用才执行；沙箱不可用时报错。安全敏感工具的默认值。
- `Dual`：优先沙箱，沙箱不可用 fallback 到 host——便携性优先。

实际执行点（`plugins.rs:941`）：

```rust
match policy {
    PluginExecutionPolicy::HostOnly => host_exec(command, &opts).await,
    PluginExecutionPolicy::SandboxOnly => router.exec(&session_key, command, &opts).await,
    PluginExecutionPolicy::Dual => {
        match router.exec(&session_key, command, &opts).await {
            Ok(out) => Ok(out),
            Err(_) => host_exec(command, &opts).await,
        }
    }
}
```

## A2A：Agent 间 HTTP 通信

`src/a2a.rs` 定义协议 `microclaw-a2a/v1`，两个端点暴露在 HTTP 表面：

```
GET  /api/a2a/agent-card  → A2AAgentCard
POST /api/a2a/message     → A2AMessageResponse
```

### Agent Card

```rust
pub struct A2AAgentCard {
    pub protocol_version: String,        // "microclaw-a2a/v1"
    pub agent_id: String,
    pub agent_name: String,
    pub description: Option<String>,
    pub public_base_url: Option<String>,
    pub endpoints: A2AEndpoints,
    pub capabilities: Vec<String>,
}
```

其他 agent 通过 GET agent-card 发现能力与通信入口；POST `/api/a2a/message` 带 `A2AMessageRequest`、返回 `A2AMessageResponse`。本地 agent 收到外部消息后自动派生 `a2a:{source_name}` session key 隔离对话，互不污染。

Peer 配置严格手填——`base_url` + 可选 `bearer_token`。没有自动发现，没有意外连接到未声明的 agent。Agent 工具：`a2a_list_peers`、`a2a_send`。

## ACP：仅 stdio 的本地无头控制

ACP（`src/acp.rs`）和 A2A 解决不同问题：A2A 是横向 agent 互联，ACP 是上层程序（IDE、Claude Code、自研 launcher）通过 stdio 控制本地 agent。

- 依赖：`agent-client-protocol = "0.10.3"`。
- **传输只有 stdio**，没有 HTTP 端点；与 Web/A2A 的 HTTP 表面互相独立。
- 只实现 chat 模式：`const ACP_MODE_ID: &str = "chat";`——刻意不暴露其它模式，把行为面收敛到对话维度。
- `AcpAdapter` 是虚拟渠道（`name = "acp"`、`chat_type = "acp"`、`is_local_only = true`），与 Web 共享同一份 `process_with_agent`。
- 外部进程委派的子代理实现在 `src/acp_subagent.rs`。
- `flatten_prompt` 处理 Text、ResourceLink、Image、Audio 等多种内容块。
- 流式输出通过 `AgentEvent::TextDelta` 经 ACP 协议回传。
- 取消复用 Web 的 `run_control::abort_runs`。

```rust
impl Agent for MicroClawAcpAgent {
    async fn initialize(&self, args: InitializeRequest) -> AcpResult<InitializeResponse>;
    async fn authenticate(&self, args: AuthenticateRequest) -> AcpResult<AuthenticateResponse>;
    async fn new_session(&self, args: NewSessionRequest) -> AcpResult<NewSessionResponse>;
    async fn load_session(&self, args: LoadSessionRequest) -> AcpResult<LoadSessionResponse>;
    async fn prompt(&self, args: PromptRequest) -> AcpResult<PromptResponse>;
    async fn cancel(&self, args: CancelNotification) -> AcpResult<()>;
}
```

## Hooks：执行路径上的拦截器

以 `HOOK.md` + YAML frontmatter 定义：

```yaml
---
name: block-dangerous-commands
events: [BeforeToolCall]
command: "sh check.sh"
enabled: true
timeout_ms: 2000
priority: 100
---
```

三个拦截点 × 三种响应：

```
BeforeLLMCall / BeforeToolCall / AfterToolCall
  → Allow { patches } / Block { reason }
```

Hook handler 以外部进程运行，stdin/stdout JSON 通讯，超时 10ms-120s，I/O 字节有上限。多个 hook 按 priority 排序，任一 block 即阻断。Block 与 modify 都写 `audit_logs`。

CLI：`microclaw hooks list / info / enable / disable`，启停状态持久化到 `hooks_state.json`。

## 五种扩展机制 + Hooks：为什么能并存

| 扩展 | 解决的问题 | 边界 |
|------|-----------|------|
| MCP | 接入外部既有工具能力 | per-server 韧性 |
| Skills | 给 Agent 注入专业内容 | 平台 + 依赖检查、激活/停用 |
| Plugins | 本地团队私有工具 | 三档执行策略 |
| A2A | Agent 之间 HTTP 通信 | 显式 peer 配置，独立 session |
| ACP | 上层程序 stdio 控制 | 仅本地、仅 chat 模式 |
| Hooks | 拦截 / 审计执行路径 | 外进程 + 超时 + 字节限 |

它们能并存的关键是：**MCP / Skill / Plugin 工具最终都注册进同一个 `ToolRegistry`，所有调用统一过 `BeforeToolCall` hook，再走 sandbox 路由**。新增扩展不会偏路绕过治理面。

```{=typst}
#pagebreak(weak: true)
```

## 示例代码：扩展点的薄封装

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
    async fn check_before_tool(&self, tool_name: &str, input: &serde_json::Value)
        -> anyhow::Result<bool>;
}

struct ExtensionRuntime<M, S, H> {
    mcp: M,
    skills: S,
    hooks: H,
}

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

## 安全边界速查

| 扩展 | 核心防护 |
|------|---------|
| MCP | per-server 超时 / 限流 / 熔断 / 并发 |
| Skills | 平台兼容检查 + 依赖检查 + 激活日志 |
| Plugins | `PluginExecutionPolicy::{HostOnly,SandboxOnly,Dual}` |
| A2A | 显式 peer 配置 + 独立 session key |
| ACP | 仅 stdio + 仅 chat 模式 + `is_local_only = true` |
| Hooks | 超时 + 字节限 + 审计；handler 失败不阻主流程 |

## 容易走错的地方

| 失败模式 | 后果 |
|---------|------|
| 所有扩展塞进一种机制 | 协议过重，或本地体验极差 |
| MCP 没有 per-server 韧性 | 一个问题 server 拖垮整个 agent loop |
| Plugin 默认 `HostOnly` 给陌生用户 | 一次 install 即沦为 RCE |
| Hook handler 无超时 | 挂起的 handler 阻塞整个执行路径 |
| 给 ACP 上 HTTP 表面 | 把本地协议错当远程协议，安全模型崩塌 |
| 把 A2A 当自动发现协议 | 连接到未声明的 peer，越权写入 |

## 关键权衡

| 决策 | 优点 | 代价 |
|------|------|------|
| MCP per-server 韧性 | 按 server 特征独立调参 | 配置面增加 |
| 五种扩展并存 | 覆盖外部工具 / 内容 / 本地 / 互联 / 上层控制 | 用户学习曲线陡 |
| Hooks 外部进程 | 任何语言实现，crash 不影响主进程 | 进程启动开销 |
| ACP 复用完整 runtime | 与 Web 行为一致 | 资源占用高于 thin proxy |
| ACP 仅 chat 模式 | 行为面小，安全审计简单 | 无法暴露其他高级模式 |
| A2A 显式 peer | 不连接未声明 peer | 无自动发现 |

## 证据来源

- 版本：`microclaw v0.1.57`
- MCP：`src/mcp.rs`，配置 `<data_root>/mcp.json` + `mcp.d/*.json`
- Skills：`src/tools/{skill_manage,sync_skills,activate_skill}.rs`、`src/clawhub/tools.rs`（`clawhub_search` / `clawhub_install`）、内置 `builtin_skills::ensure_builtin_skills`
- ClawHub：`crates/microclaw-clawhub/src/{client,gate,install,lockfile,types}.rs`
- Plugins：`src/plugins.rs`（`PluginManifest` / `PluginToolSpec` / `PluginCommandSpec` / `PluginContextProviderSpec` / `PluginExecutionPolicy`）
- A2A：`src/a2a.rs` + `src/web/a2a.rs`，常量 `A2A_PROTOCOL_VERSION = "microclaw-a2a/v1"`，路径 `/api/a2a/agent-card`、`/api/a2a/message`
- ACP：`src/acp.rs`、`src/acp_subagent.rs`，依赖 `agent-client-protocol = "0.10.3"`，常量 `ACP_MODE_ID = "chat"`
- Hooks：审计走 `audit_logs` 表

## 图表清单

### 图 12-1：扩展机制的分层位置图

![图 12-1：扩展机制的分层位置图](../../assets/figures/fig-12-extension-layers.svg)
