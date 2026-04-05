# Chapter 12 MCP、Skills、Plugins 与协议扩展

## 这一章要回答什么问题

七种扩展机制（MCP、Skills、Plugins、ClawHub、A2A、ACP、Hooks）如何各司其职而不破坏主链路？

## MCP：接入外部工具

支持 stdio（`TokioChildProcess`）和 streamable_http 两类传输。

### Per-Server 韧性配置

每个 MCP server 独立配置超时、重试、熔断、限流：

```
工具调用请求 → Rate Limiter（120/min） → Bulkhead（4 并发）
  → Circuit Breaker（5 次连续失败触发熔断）
    → 超时保护 → 重试（最多 max_retries 次）→ 返回结果
```

- **熔断器**：连续失败达 threshold（默认 5）→ 打开 → cooldown（默认 30s）后自动关闭。threshold 和 cooldown 设 0 可禁用。
- **Bulkhead**：`Semaphore` 限制并发（默认 4），超出在 200ms 内等待 permit。
- **Rate Limiter**：`FixedWindowRateLimiter`，默认 120/min。
- **工具缓存**：TTL 300s，工具不在缓存或返回 "tool not found" 时触发刷新。
- **多配置源合并**：后面的配置覆盖前面的同名 server。

## Skills：注入专业能力

以 `SKILL.md` 为核心载体，frontmatter 声明元数据：

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

- 通过 `activate_skill` 动态激活，注入 system prompt。
- `sync_skills` 从外部源同步。
- 支持平台兼容检查（OS + 二进制依赖）。

### 统一扩展元数据

```rust
struct ExtensionManifest {
    name: String,
    source: String,   // "mcp", "skill", "plugin"
    kind: String,     // "tool", "prompt", "command"
    execution_mode: String,
}
```

```python
from dataclasses import dataclass


@dataclass
class ExtensionManifest:
    name: str
    source: str
    kind: str
    execution_mode: str
```

## Plugins：本地团队自定义

`src/plugins.rs` 定义三类扩展：

| 类型 | 说明 |
|------|------|
| Slash Commands | `PluginCommandSpec`，通过外部脚本执行 |
| Plugin Tools | `PluginToolSpec`，JSON Schema + 执行策略 + 沙箱 |
| Context Providers | 每轮执行前注入额外 prompt/文档片段 |

执行策略：

```rust
enum PluginExecutionPolicy {
    HostOnly,
    SandboxOnly,
    Dual,
}
```

`SandboxOnly` 要求 sandbox 可用才执行；`Dual` 优先 sandbox，不可用时 fallback host。

## ClawHub：技能分发

- CLI：`search / install / list / inspect / available`
- Agent 工具：`clawhub_search`、`clawhub_install`
- `clawhub.lock.json` 记录安装状态——供应链可追踪，角色类似 `Cargo.lock`。

## A2A：Agent 间通信

### Agent Card

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

暴露在 `/api/a2a/agent-card`，其他 Agent 通过此发现能力和通信入口。

### 消息与 Peer

- `/api/a2a/message` 接受消息，自动生成 `a2a:{source_name}` session key 隔离对话。
- Peers 在配置中显式声明 `base_url` + 可选 `bearer_token`。
- Agent 工具：`a2a_list_peers`、`a2a_send`。

## ACP：外部程序的无头控制

通过 stdio 控制 Agent，实现 `agent_client_protocol` 标准接口：

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

- 构建完整 `AppState`（LLM、tool registry、memory、MCP），与 Web 渠道相同。
- Channel 为 `AcpAdapter`（`is_local_only = true`）。
- `flatten_prompt` 处理 Text、ResourceLink、Image、Audio 等多种内容块。
- 流式输出通过 `AgentEvent::TextDelta`。
- 取消共享 Web 的 `run_control::abort_runs` 基础设施。

## Hooks：事件拦截

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

### 三个拦截点 × 三种响应

```
BeforeLLMCall / BeforeToolCall / AfterToolCall
  → Allow { patches } / Block { reason }
```

Hook handler 以外部进程运行，通过 stdin/stdout 交换 JSON。超时保护（10ms-120s），输入输出字节限制。多 hook 按 priority 排序，任一 block 即阻止。

### CLI 管理

```
microclaw hooks list / info / enable / disable
```

启用/禁用状态持久化到 `hooks_state.json`。Block 和 modify 操作记录审计日志。

## 七种扩展方式总览

| 扩展方式 | 解决的问题 | 方向 |
|---------|-----------|------|
| MCP | 接入外部现成工具能力 | Runtime → 外部 |
| Skills | 向 Agent 注入专业知识和工作流 | 内容 → Agent |
| Plugins | 本地团队快速自定义 | 本地 → Runtime |
| ClawHub | 技能分发与供应链治理 | 生态 → 本地 |
| A2A | Agent 之间通信 | Agent ↔ Agent |
| ACP | 外部程序控制 Agent | 程序 → Agent |
| Hooks | 执行路径拦截与审计 | 安全 → Runtime |

## 安全边界速查

| 扩展 | 核心防护 |
|------|---------|
| MCP | per-server 超时/限流/熔断/并发 |
| Skills | 平台兼容检查 + 依赖检查 + 启停状态 |
| Plugins | 三级执行策略（Host/Sandbox/Dual） |
| Hooks | 超时 + 字节限制 + 审计日志，handler 失败不阻主流程 |
| A2A | 显式 peer 配置，不自动发现 |
| ACP | stdio 本地进程，`is_local_only = true` |

```{=typst}
#pagebreak(weak: true)
```

## 示例代码：MCP 调用 vs Skill 激活

两者都是扩展，但解决不同问题，不应被同一接口抹平。

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

## 容易走错的地方

| 失败模式 | 后果 |
|---------|------|
| 所有扩展塞进一种机制 | 协议过重或本地体验极差 |
| MCP 没有 per-server 韧性 | 一个问题 server 拖垮整个 agent loop |
| Hook handler 无超时 | 挂起的 handler 阻塞执行路径 |
| 外部安装不做版本追踪 | 供应链审计空洞 |
| ACP 只支持纯文本 | 丢失 ResourceLink/Image/Audio 等核心价值 |

## 关键权衡

| 决策 | 优点 | 代价 |
|------|------|------|
| MCP per-server 韧性 | 按 server 特征独立调参 | 配置面增加 |
| 七种扩展路径并存 | 覆盖六大类需求 | 新用户学习曲线陡 |
| Hooks 外部进程运行 | 任何语言实现，crash 不影响主进程 | 进程启动开销 |
| ACP 复用完整 runtime | 与 Web 行为一致 | 资源占用高于 thin proxy |
| A2A 显式 peer 配置 | 安全，不连接未声明 peer | 无自动发现 |

## 图表清单

### 图 12-1：七种扩展机制的分层位置图

![图 12-1：七种扩展机制的分层位置图](../assets/figures/fig-12-extension-layers.svg)
