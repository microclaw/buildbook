# Chapter 1 为什么是 MicroClaw

## 第二周失效的 Agent

许多团队第一次做 Agent 系统的起点是"把大模型接进聊天窗口"。第一周演示效果惊艳，第二周开始失效：任务跨小时无法恢复、用户连发三条消息触发竞争、模型陷入工具调用死循环、成本失控、跨渠道行为不一致。问题的共性是：起点是一个聊天 UI，而不是一个执行型 runtime。

MicroClaw 试图回答的是另一个问题：当一个 Agent 必须长时间运行、跨渠道交互、调度数十种工具、可被中断、可被恢复、可被观测时，它应该长成什么样。

到 v0.1.57，它已经是一个 7 子 crate workspace + 主 binary、约 50 个内置工具（含 MCP 动态注入）、15 个渠道适配器、session-native subagent 体系、A2A/ACP 双协议的工程化运行时。本章不罗列功能，而是说明这些功能为什么必须收进同一个进程。

## "一问一答"撑不住的复杂度

传统聊天机器人的关键路径很短：收消息 → 组装 prompt → 调模型 → 发回复。一旦任务变复杂，问题就接连浮现。

| 问题维度 | 单循环聊天机器人会遇到什么 | MicroClaw 的回应 |
|---------|------------------------|-----------------|
| 工具执行 | 多个 tool_use 块同时返回，无法判断并发/串行 | wave-based 并行，按 ReadOnly/SideEffect/Exclusive 分波 |
| 会话恢复 | 进程重启后所有上下文丢失 | SQLite 持久化 + session resume |
| 长期记忆 | 每次都要重新输入背景与偏好 | 文件记忆（AGENTS.md/SOUL.md）+ 结构化记忆（`memories` 表） |
| 运维与成本 | 死循环、重复执行、跑飞预算 | run_control 取消 + ChatTurnQueue 序列化 + Hooks 拦截 + OTLP |
| 多实例协作 | 无法被 IDE 驱动，无法和其他实例通信 | ACP（headless stdio）+ A2A（跨实例 HTTP） |

请求对象本身就反映了上述约束。一个只携带文本的请求，无法支撑会话恢复、渠道路由、工具放行、run control 注册：

```rust
use serde::{Deserialize, Serialize};

// 单循环聊天机器人的请求对象
#[derive(Debug, Deserialize)]
struct ChatRequest {
    text: String,
}

// MicroClaw 实际使用的请求对象（简化）
#[derive(Debug, Clone, Serialize, Deserialize)]
struct RuntimeRequest {
    channel: String,
    chat_id: i64,
    chat_type: String,
    session_key: String,
    sender_id: String,
    text: String,
    allow_tools: bool,
    source_message_id: Option<String>,
}
```

`channel + chat_id + session_key` 是 turn lock 与 run_control 的复合键，`source_message_id` 用于幂等去重，`allow_tools` 控制本轮是否进入工具循环——每个字段都对应一条具体的运行时事实。

## 五个核心设计目标

### 1. 多渠道接入，内核不分裂

共享 Agent Loop 集中在 `src/agent_engine.rs`。15 个渠道适配器（Telegram、Discord、Slack、Matrix、Email、Weixin、WhatsApp、Signal、IRC、iMessage、钉钉、飞书、QQ、Nostr、Web）位于 `src/channels/`，全部通过 `ChannelAdapter` trait 把外部协议归一为同一种 `IngressEvent`。如果每个渠道都拥有自己的 Agent 行为分支，回复格式、记忆注入、工具放行策略迟早会偏离。

### 2. 约 50 个内置工具，wave-based 并行执行

| 类别 | 代表工具 |
|------|---------|
| Shell 与文件 | `bash`、`read_file`、`write_file`、`edit_file`、`glob`、`grep`、`fetch_artifact` |
| Web 与多模态 | `web_fetch`、`web_search`、`browser`、`describe_image`、`generate_image`、`transcribe_audio`、`text_to_speech` |
| 记忆与检索 | `read_memory`、`write_memory`、`structured_memory_search/delete/update`、`session_search`（FTS5）、`knowledge_graph` |
| 调度 | `schedule_task`、`list_scheduled_tasks`、`pause_scheduled_task`、`resume_scheduled_task`、`cancel_scheduled_task`、`get_task_history`、`list_scheduled_task_dlq`、`replay_scheduled_task_dlq` |
| Subagent | `sessions_spawn`、`subagents_list/info/kill/focus/send/orchestrate` |
| A2A 与协作 | `a2a_list_peers`、`a2a_send` |
| 安全与时间 | `osv_check`、`time_math`（聚合 get_current_time/compare_time/calculate）、`fuzzy_match` |
| 技能与归档 | `skill_manage`（带 action）、`sync_skills`、`activate_skill`、`export_chat`、`insights` |
| 交互 | `clarify`、`todo_read`、`todo_write` |

并行调度位于 `src/tool_executor.rs`：工具按 concurrency class 分类 → 划分为多个 wave → 同 wave 内 ReadOnly 工具通过 `tokio::JoinSet` 并行 → wave 之间严格串行。这套规则不需要分析具体工具的依赖图，只看声明分类即可安全并行。

### 3. 状态可恢复，运行可取消

SQLite 是事实源。`crates/microclaw-storage/src/db.rs` 内联管理 schema 迁移，当前版本 v25+（v21 引入 FTS5 `session_search` 表）。`src/run_control.rs` 为每个 `(channel, chat_id)` 维护活跃 run 列表，配合 `Arc<AtomicBool>` 与 `tokio::sync::Notify` 实现可观测的清晰取消。`src/chat_turn_queue.rs` 的 async mutex 保证同一 chat 同一时刻只有一个 agent run 在执行，连发的消息会被 coalesce 而不是触发竞态。

### 4. 成本与风险可控

| 治理维度 | 机制 |
|---------|------|
| 策略拦截 | Hooks 在 BeforeLLMCall / BeforeToolCall / AfterToolCall 三点位（`src/hooks.rs`） |
| 风险分级 | `ToolRisk` 枚举：Low / Medium / High，高风险工具默认要求用户确认（`high_risk_tool_user_confirmation_required=true`） |
| 超时控制 | 全局默认超时 + 按工具名独立覆盖 |
| Subagent 预算 | 独立 token 预算、嵌套深度限制、并发数上限（Semaphore） |
| 可观测性 | OTLP metrics / traces / logs 三合一导出 |

### 5. 可编排、可互联

ACP（Agent Client Protocol，仅 stdio）让 MicroClaw 可以被 IDE 插件或自动化脚本作为 headless runtime 驱动；A2A（Agent-to-Agent，HTTP）让多个实例之间可以互发消息。两个协议把 MicroClaw 从"聊天入口的后端"推向"可编排的 Agent 节点"。

## 同类项目里的位置

```
                    轻量极简                   重度平台
                      ◄────────────────────────────►
  NanoBot ─┤
  NanoClaw ──┤
             MicroClaw ──────┤
                          OpenClaw ──────────┤
                              Moltis ────────────┤
```

- 与 OpenClaw 相比：更偏"单机优先、运行时内聚"，而不是分布式控制平面
- 与轻量个人代理相比：约 50 个工具、session-native subagent、wave-based 并行、per-chat turn serialization 说明它不是周末项目
- 与框架类产品（LangChain、CrewAI）相比：MicroClaw 是完整 runtime binary，不是给你拼装 Agent 的库

## 状态与工具为什么必须纳入 Runtime

下面这段简化代码展示了一个最小化 Agent runtime 必须具备的三件事：可注入的工具执行器、可恢复的会话上下文、可观测的取消信号。它们三者缺一，长任务就会失控。

```rust
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use anyhow::Result;
use async_trait::async_trait;
use serde_json::Value;

#[async_trait]
trait ToolExecutor: Send + Sync {
    async fn run(&self, name: &str, args: Value) -> Result<Value>;
}

struct AgentRuntime<T: ToolExecutor> {
    tool_executor: Arc<T>,
    session_messages: Vec<Value>,
    cancelled: Arc<AtomicBool>,
}

impl<T: ToolExecutor> AgentRuntime<T> {
    async fn handle_turn(&mut self, user_text: &str) -> Result<String> {
        self.session_messages
            .push(serde_json::json!({"role": "user", "text": user_text}));

        for _ in 0..32 {
            if self.cancelled.load(Ordering::Relaxed) {
                return Ok("Run cancelled.".into());
            }
            let output = self
                .tool_executor
                .run("bash", serde_json::json!({"cmd": "pwd"}))
                .await?;
            self.session_messages
                .push(serde_json::json!({"role": "tool", "result": output}));
            // 真实实现里这里会再次调模型，根据 stop_reason 决定是否退出
            break;
        }
        Ok("done".into())
    }
}
```

真实的 `agent_engine.rs` 在此基础上还要做：BeforeLLMCall hook 拦截、wave 分波、subagent 派发、AgentEvent 事件流、stop_reason 分支与持久化。本章所列出的设计目标都是为了让上面这段最小骨架能在生产环境长时间存活。

## 关键权衡

| 决策 | 收益 | 代价 |
|------|------|------|
| 先统一内核，再扩展渠道 | 复用强、行为一致 | 渠道特性必须经过抽象层 |
| 优先 SQLite 本地状态 | 部署简单、可审计 | 横向扩展不是默认路径 |
| 工具系统一等公民 + 并行 | 真正执行力 + 高吞吐 | 必须直面 concurrency class、权限、安全 |
| 双层记忆 + 文件人格 | 可读可编辑 + 可检索可归档 | 两层系统需持续解释边界 |
| ACP/A2A 但不强制分布式 | 渐进式可编排 | 不要求搭建集群 |

## 容易走错的地方

**失败模式 1：把 MicroClaw 当成"套壳聊天 UI"**。会低估并行工具执行、subagent 编排、run control、hooks 的设计重点，逻辑被推回各个渠道适配器，复用立刻失效。

**失败模式 2：只关注模型，不关注 runtime**。决定稳定性的是会话恢复、run control、memory 写入、hooks 拦截、turn 序列化，而不是 prompt 写得多漂亮。

**失败模式 3：过早追求"大而全"**。先把本地 runtime 做厚，再通过 ACP/A2A/Gateway 逐步开放桥接层，是更现实的路径。

**失败模式 4：忽视 setup 与 doctor 的工程价值**。配置正确性本身就是最大的运维挑战。setup wizard 与 doctor 不是锦上添花，而是把"装得上、跑得动"做成可重现流程。

## 小结

MicroClaw 把 Agent 当作一个长期运行、可恢复、可中断、可观测、可编排的系统在做。7 子 crate + 主 binary、约 50 个工具、15 个渠道、session-native subagent、ACP、A2A、hooks、gateway、doctor——这些是它划清工程边界的方式，不是功能清单。

## 证据来源（v0.1.57）

- `Cargo.toml`（workspace、version、features）、`src/agent_engine.rs`、`src/tool_executor.rs`、`src/llm.rs`、`src/run_control.rs`、`src/chat_turn_queue.rs`、`src/hooks.rs`、`src/acp.rs`、`src/a2a.rs`、`src/gateway.rs`、`src/doctor.rs`、`src/setup.rs`
- `src/tools/mod.rs`（约 50 个工具，含 MCP 动态注入）、`src/channels/`（15 个适配器）、`crates/microclaw-storage/src/db.rs`（`SCHEMA_VERSION_CURRENT = 25`）
- `src/config.rs`（`max_tool_iterations=100`、`parallel_tool_max_concurrency=8`、`high_risk_tool_user_confirmation_required=true`）

## 图表清单

### 图 1-1：传统聊天机器人与执行型 Agent Runtime 的能力差异

![图 1-1：传统聊天机器人与执行型 Agent Runtime 的能力差异](../assets/figures/fig-01-chatbot-vs-runtime.svg)
