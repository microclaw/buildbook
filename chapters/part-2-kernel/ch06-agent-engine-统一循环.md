# Chapter 6 Agent Engine 统一循环

## 入口层次

`src/agent_engine.rs`（3541 行）承载从请求入口到最终回复的全部逻辑。

```
process_with_agent                          // 最简入口
  └─ process_with_agent_with_events         // 带事件流
       └─ process_with_agent_with_events_guarded  // 带轮次锁
            ├─ run_control::register_run     // 注册运行，获取取消信号
            ├─ tokio::select!               // 取消 vs 正常执行竞争
            │   └─ DefaultAgentEngine::process_with_events
            │        └─ process_with_agent_impl   // 追踪 span 包装
            │             └─ process_with_agent_logic  // 真正的主循环
            └─ run_control::unregister_run   // 清理
```

最外层：获取 per-chat `TurnGuard` + 注册 `run_control` 取消竞争。

```rust
struct TurnContext {
    chat_id: i64,
    caller_channel: String,
    chat_type: String,
    messages: Vec<Message>,
    resumed_from_session: bool,
}

impl TurnContext {
    fn append_user_text(&mut self, text: &str) {
        self.messages.push(Message::user(
            format_user_message("user", text)
        ));
    }
}
```

```python
from dataclasses import dataclass, field


@dataclass
class TurnContext:
    chat_id: int
    caller_channel: str
    chat_type: str
    resumed_from_session: bool
    messages: list[Message] = field(default_factory=list)

    def append_user_text(self, text: str) -> None:
        self.messages.append(Message.user(format_user_message("user", text)))
```

## run_control 与 ChatTurnQueue

- **取消**：`register_run` 创建 `cancelled: Arc<AtomicBool>` + `Notify`，`tokio::select!` 竞争。被中止消息加入 `ABORTED_SOURCE_MESSAGE_IDS`，resume 时跳过。
- **串行化**：同一 `(channel, chat_id)` 同时只有一个 run，多余消息排队（最多 20 条）。`TurnGuard` 用 RAII 模式。

## SOUL.md 与系统提示词

`load_soul_content` 按优先级搜索：per-channel 配置 → 全局 `soul_path` → `~/.microclaw/SOUL.md` → `./SOUL.md` → per-chat `runtime/groups/{chat_id}/SOUL.md`（最高）。找到后包裹 `<soul>` 标签注入。

`build_system_prompt` 组装：身份（SOUL.md）、能力目录（ToolRegistry）、时间上下文、记忆（带 token 预算）、技能/插件、执行手册。

## 显式记忆 fast-path

进入主循环前检测"记住 X"：质量检查 → Jaccard 去重 → topic 冲突走 supersede → 0.95 置信度写入 → 跳过 agent loop。

## Session Resume

| 路径 | 行为 |
| --- | --- |
| Session 存在 | 反序列化 + 追加新消息（跳过被中止的和斜杠命令）|
| 无 Session | 私聊取最近 N 条；群聊取上次 bot 回复后的消息 |

Session 保存完整消息状态（含工具调用块），resume 必须在核心循环里。

## 图像输入

```rust
if let Some((base64_data, media_type)) = image_data {
    if let Some(last_msg) = messages.last_mut() {
        if last_msg.role == "user" {
            let mut blocks = vec![ContentBlock::Image {
                source: ImageSource {
                    source_type: "base64".into(),
                    media_type,
                    data: base64_data,
                },
            }];
            if !text_content.is_empty() {
                blocks.push(ContentBlock::Text { text: text_content });
            }
            last_msg.content = MessageContent::Blocks(blocks);
        }
    }
}
```

## Context Compaction

`messages.len() > 40` 时：旧片段序列化（截断 20000 字符）→ 调模型摘要（180s 超时）→ `[Conversation Summary]` + 最近 20 条。失败回退简单截断。Compaction 前 `archive_conversation` 归档原始消息，`sanitize_messages` 清理断裂的工具调用链。

## Tool Loop 与防失控

```
取消检查 → BeforeLLMCall Hook → 调模型 → 记录 trace/用量
  → stop_reason 分支：
      end_turn → 提取文本 → 保存 session → 返回
      tool_use → 指纹检测 → execute_tool_batch → 追加结果 → 继续
      其他    → 安全结束
```

防失控机制：

- **迭代上限**：`max_tool_iterations`=100
- **重复指纹检测**：连续 6 轮 `name:input` 完全相同 → 立即中止（比上限更重要——失控通常是机械重试）
- **空可见回复重试**：去除 `<think>` tags 后为空 → 注入 `[runtime_guard]` 消息重试一次
- **无工具可执行**：`stop_reason=tool_use` 但解析不出工具 → 记录警告并安全结束

## 事件流

```rust
pub enum AgentEvent {
    Iteration { iteration: usize },
    ToolStart { name: String, input: Value },
    ToolResult { name: String, is_error: bool, preview: String, duration_ms: u128, ... },
    TextDelta { delta: String },
    ToolWaveStart { wave: usize, tool_count: usize },
    ToolWaveComplete { wave: usize },
    Cancelled { final_text: String },
    FinalResponse { text: String },
}
```

每次 LLM 调用和工具执行生成 OTLP `SpanData`，形成分布式追踪链。

```{=typst}
#pagebreak(weak: true)
```

## 示例代码

```rust
#[async_trait::async_trait]
trait ModelClient {
    async fn next(&self, messages: &[Message]) -> anyhow::Result<ModelResponse>;
}

struct AgentEngine<M> {
    model: M,
    tools: ToolRegistry,
    messages: Vec<Message>,
    cancelled: Arc<AtomicBool>,
}
```

```rust

impl<M: ModelClient> AgentEngine<M> {
    async fn run_turn(&mut self) -> anyhow::Result<String> {
        for iteration in 0..100 {
            if self.cancelled.load(Ordering::Relaxed) {
                return Ok("Current run aborted.".into());
            }
            let response = self.model.next(&self.messages).await?;
            if let ModelResponse::EndTurn(text) = response {
                return Ok(text);
            }
            let pending = response.extract_tool_calls()?;
            let results = execute_tool_batch(&self.tools, &pending).await;
            self.messages.extend(results);
        }
        anyhow::bail!("too many tool iterations")
    }
}
```

```{=typst}
#pagebreak(weak: true)
```

```python
from dataclasses import dataclass, field
from typing import Protocol


class ModelClient(Protocol):
    async def next(self, messages: list[Message]) -> dict: ...


@dataclass
class AgentEngine:
    model: ModelClient
    tools: ToolRegistry
    messages: list[Message] = field(default_factory=list)
    cancelled: bool = False
```

```python

    async def run_turn(self) -> str:
        for iteration in range(100):
            if self.cancelled:
                return "Current run aborted."
            response = await self.model.next(self.messages)
            if response["type"] == "end_turn":
                return response["text"]
            if response["type"] == "tool_use":
                pending = response["tool_calls"]
                results = await execute_tool_batch(self.tools, pending)
                self.messages.extend(results)
        raise RuntimeError("too many tool iterations")
```

## 关键权衡

| 决策 | 优点 | 代价 |
| --- | --- | --- |
| 集中在一个引擎 | 行为一致、易于观测 | 3541 行，需拆出 `tool_executor.rs` 和 `memory_service.rs` |
| 取消/串行化为内核原语 | 所有渠道免费获得 | 每个关键点都要考虑取消状态 |
| SOUL.md 文件注入 | 非工程师可编辑 | 文件系统成为依赖 |
| Compaction 作为正式机制 | 成本和窗口可控 | 需维护摘要质量 + 归档安全网 |
| 审批嵌入循环 | 确认和重试语义一致 | 状态机更复杂 |

## 容易走错的地方

1. **把统一循环误解成"模型调用包装器"**：session resume、SOUL 注入、记忆、审批、compaction、run_control、事件流都是关键机制。
2. **把会话恢复放到渠道层**：工具调用链一致性会丢失。
3. **只设迭代上限不做重复检测**：系统可能几十轮内白白消耗 token。fingerprint 连续 6 次相同即止损。
4. **忽视取消信号传播**：取消必须同时停止 LLM 和工具，并标记 source message 避免重处理。

## 小结

统一循环把 session 恢复、SOUL 人格、记忆、工具循环、compaction、审批、取消、串行化收敛成一条可恢复、可观测、可中断的主链路。

## 证据来源（v0.1.38）

`src/agent_engine.rs`、`src/run_control.rs`、`src/chat_turn_queue.rs`、`src/memory_service.rs`。关键配置：`max_session_messages=40`、`max_tool_iterations=100`、`MAX_IDENTICAL_TOOL_USE_STREAK=6`

## 图表清单

### 图 6-1：`process_with_agent` 统一循环

![图 6-1：`process_with_agent` 统一循环](../assets/figures/fig-06-agent-loop.svg)
