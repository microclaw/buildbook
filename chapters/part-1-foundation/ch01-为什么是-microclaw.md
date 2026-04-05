# Chapter 1 为什么是 MicroClaw

## 你的第一个 Agent 为什么会卡在第二周？

很多团队第一次做 Agent 系统，起点是"把大模型接进聊天窗口"。但真正有价值的任务不只是文本问答，而是一个持续运行、可调用工具、可跨渠道、可恢复、可取消的执行过程。

MicroClaw 已经从早期实验演进为工程化 runtime：8 个 workspace crate、44 个内置工具、16 个渠道适配器、session-native subagent 体系、A2A/ACP 协议。理解它的价值，不是看它"支持了多少功能"，而是看它为什么要把这些功能收进同一个进程。

## "一问一答"为什么撑不住复杂任务？

传统聊天机器人的关键路径很短：收消息 → 组装 prompt → 调模型 → 发回复。一旦任务变复杂，问题就接连浮现：

| 问题维度 | 挑战 | MicroClaw 的回应 |
|---------|------|-----------------|
| 工具执行 | 多个 tool_use 块需判断并发/串行/独占 | wave-based 并行，按 ReadOnly/SideEffect/Exclusive 分波 |
| 会话恢复 | 任务跨小时/天/渠道 | SQLite 持久化 + session resume |
| 长期记忆 | 偏好、背景不能每次重新输入 | 文件记忆（AGENTS.md/SOUL.md）+ 结构化记忆（memories 表） |
| 运维与成本 | 无限循环、成本失控、任务卡死 | run_control 取消 + ChatTurnQueue 序列化 + Hooks 拦截 + OTLP |
| 多实例协作 | 需被 IDE 驱动或与其他实例通信 | ACP（headless stdio）+ A2A（跨实例 HTTP） |

### 请求对象为什么不能只包含一段文本？

系统一旦要恢复会话、区分渠道、决定是否允许工具、追踪 run control 状态，请求对象就必须显式携带运行时事实：

```rust
struct ChatRequest {
    text: String,
}

struct RuntimeRequest {
    channel: String,
    chat_id: i64,
    chat_type: String,
    session_key: String,
    text: String,
    allow_tools: bool,
}
```

```python
from dataclasses import dataclass


@dataclass
class ChatRequest:
    text: str


@dataclass
class RuntimeRequest:
    channel: str
    chat_id: int
    chat_type: str
    session_key: str
    text: str
    allow_tools: bool
```

## MicroClaw 的五个核心设计目标

### 1. 多渠道接入，内核不分裂

共享 Agent Loop 放在 `src/agent_engine.rs`，16 个渠道适配器拆成边缘模块。如果每个渠道都有自己的 Agent 行为分支，系统早就无法维护了。

### 2. 44 个内置工具，支持 wave-based 并行执行

| 类别 | 代表工具 |
|------|---------|
| Shell 与文件 | `bash`、`read_file`、`write_file`、`edit_file`、`glob`、`grep` |
| Web 能力 | `web_fetch`、`web_search`、`browser` |
| 记忆 | `read_memory`、`write_memory`、`structured_memory_search/delete/update` |
| 调度 | `schedule_task`、`list_scheduled_tasks`、`pause/resume/cancel_scheduled_task` |
| Subagent | `sessions_spawn`、`subagents_list/info/kill/focus/send/orchestrate` |
| A2A | `a2a_list_peers`、`a2a_send` |
| 其他 | `get_current_time`、`todo_read/write`、`export_chat`、`activate_skill` |

wave-based parallel tool execution（`src/tool_executor.rs`）：按 concurrency class 分类 → 分成多个 wave → 同一 wave 内 ReadOnly 工具通过 `tokio::JoinSet` 并行 → wave 之间严格串行。

### 3. 状态可恢复，运行可取消

SQLite 保存聊天、消息、session、task、memory、subagent run 等状态（schema v19）。`run_control.rs` 为每个 (channel, chat_id) 维护活跃 run 列表，支持干净取消。`ChatTurnQueue` 确保同一 chat 同一时刻只有一个 agent run 在执行。

### 4. 成本和风险可控

| 治理维度 | 机制 |
|---------|------|
| 策略拦截 | Hooks 在 BeforeLLMCall / BeforeToolCall / AfterToolCall 三点位 |
| 风险分级 | 工具风险分 Low / Medium / High 三级 |
| 超时控制 | 全局默认超时 + 按工具名单独覆盖 |
| Subagent 预算 | 独立 token 预算、嵌套深度限制、并发数上限 |
| 可观测性 | OTLP 指标 / traces / logs 三合一导出 |

### 5. 可编排、可互联

ACP（Agent Client Protocol）让它可以作为 headless runtime 被 IDE 插件或自动化脚本驱动。A2A（Agent-to-Agent）让多个实例之间可以互发消息。这两个协议把 MicroClaw 从"聊天入口的后端"推向"可编排的 Agent 节点"。

## MicroClaw 在同类项目中处于什么位置？

```
                    轻量极简                   重度平台
                      ◄────────────────────────────►
  NanoBot ─┤
  NanoClaw ──┤
             MicroClaw ──────┤
                          OpenClaw ──────────┤
                              Moltis ────────────┤
```

- 和 OpenClaw 相比：更偏"单机优先、运行时内聚"，而非分布式控制平面
- 和轻量个人代理项目相比：44 工具、session-native subagent、wave-based 并行、per-chat turn serialization 说明它不是周末项目
- 和框架类产品（LangChain、CrewAI）相比：MicroClaw 是完整 runtime binary，不是让你组装 Agent 的库

## 示例代码：状态和工具为什么必须纳入 Runtime？

```rust
#[async_trait::async_trait]
trait ToolExecutor {
    async fn run(&self, command: &str) -> anyhow::Result<String>;
}

struct AgentRuntime<T: ToolExecutor> {
    tool_executor: T,
    session_messages: Vec<String>,
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl<T: ToolExecutor> AgentRuntime<T> {
    async fn handle_message(&mut self, user_text: &str) -> anyhow::Result<String> {
        self.session_messages.push(format!("user: {user_text}"));
        if self.cancelled.load(std::sync::atomic::Ordering::Relaxed) {
            return Ok("Run cancelled.".to_string());
        }
        let tool_output = self.tool_executor.run("pwd").await?;
        let reply = format!("tool says: {tool_output}");
        self.session_messages.push(format!("assistant: {reply}"));
        Ok(reply)
    }
}
```

```python
from dataclasses import dataclass, field
from typing import Protocol
import threading


class ToolExecutor(Protocol):
    async def run(self, command: str) -> str: ...


@dataclass
class AgentRuntime:
    tool_executor: ToolExecutor
    session_messages: list[str] = field(default_factory=list)
    cancelled: threading.Event = field(default_factory=threading.Event)

    async def handle_message(self, user_text: str) -> str:
        self.session_messages.append(f"user: {user_text}")
        if self.cancelled.is_set():
            return "Run cancelled."
        tool_output = await self.tool_executor.run("pwd")
        reply = f"tool says: {tool_output}"
        self.session_messages.append(f"assistant: {reply}")
        return reply
```

## 关键权衡

| 决策 | 收益 | 代价 |
|------|------|------|
| 先统一内核，再扩展渠道 | 复用强、行为一致 | 渠道特性必须经过抽象层 |
| 优先 SQLite 本地状态 | 部署简单、可审计 | 横向扩展不是默认路径 |
| 工具系统一等公民 + 并行 | 真正执行力 + 高吞吐 | 需面对 concurrency class、权限、安全 |
| 双层记忆 + 文件人格 | 可读可编辑 + 可检索可归档 | 两层系统需持续解释边界 |
| ACP/A2A 但不强制分布式 | 渐进式可编排 | 不要求搭建集群 |

## 容易走错的地方

### 失败模式 1：把 MicroClaw 当成"套壳聊天 UI"

会低估并行工具执行、subagent 编排、run control、hooks 的设计重点，导致把逻辑散落到各个渠道适配器里。

### 失败模式 2：只关注模型，不关注 runtime

真正决定稳定性的是：会话恢复、任务中断（run control）、memory 写入、工具可控（hooks）、并发 turn 序列化（ChatTurnQueue）。

### 失败模式 3：过早追求"大而全"

先把本地 runtime 做厚，再通过 ACP/A2A/Gateway 逐步开放桥接层，这是更现实的路径。

### 失败模式 4：忽视 setup 和 doctor 的工程价值

11,000 行 setup wizard 和 1,700 行 doctor 不是锦上添花。配置正确性本身就是最大的运维挑战。

## 证据来源（v0.1.38）

- `Cargo.toml`（workspace, version, features）、`src/agent_engine.rs`、`src/tool_executor.rs`、`src/llm.rs`、`src/run_control.rs`、`src/chat_turn_queue.rs`、`src/hooks.rs`、`src/acp.rs`、`src/a2a.rs`、`src/gateway.rs`、`src/doctor.rs`、`src/setup.rs`
- `src/tools/mod.rs`（44 tools）、`src/channels/`（16 adapters）、`crates/microclaw-storage/src/db.rs`（SCHEMA v19）
- `src/config.rs`（`max_tool_iterations=100`、`parallel_tool_max_concurrency=8`、`high_risk_tool_user_confirmation_required=true`）

## 小结

MicroClaw 值得单独讨论，因为它试图回答：如何把 Agent 做成一个真正可运行、可恢复、可中断、可观测、可编排的系统。8 个 crate、44 个工具、16 个渠道、session-native subagent、ACP、A2A、hooks、gateway、doctor——这是一个有明确工程边界的 runtime，不是实验项目。

## 图表清单

### 图 1-1：传统聊天机器人与执行型 Agent Runtime 的能力差异

![图 1-1：传统聊天机器人与执行型 Agent Runtime 的能力差异](../assets/figures/fig-01-chatbot-vs-runtime.svg)
