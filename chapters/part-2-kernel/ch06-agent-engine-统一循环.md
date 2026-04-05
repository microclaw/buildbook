# Chapter 6 Agent Engine 统一循环

## 从请求入口到最终回复，agent_engine.rs 里到底发生了什么？

如果说前一章讲的是"系统怎么装起来"，那这一章讲的就是"系统实际怎样工作"。真正定义 MicroClaw 产品灵魂的不是某个渠道适配器，也不是某个具体工具，而是 `src/agent_engine.rs` 里的统一循环——3541 行，承载了从请求入口到最终回复的全部逻辑。

这个循环决定了：

- 一次请求如何恢复上下文、注入记忆和 SOUL.md 人格。
- 模型何时继续调用工具、何时结束回答。
- 图像输入如何融入消息序列。
- 超长会话何时压缩，压缩如何保持工具调用一致性。
- 高风险动作何时要求确认。
- 运行过程如何被取消（`run_control`）。
- per-chat 轮次如何串行化（`ChatTurnQueue`）。
- 子代理如何与主循环交互。

这一章读完后，你应该可以把 `process_with_agent` 的执行过程完整讲给别人听——包括它在哪里检查取消、在哪里分发工具批次、在哪里注入人格——而不是只说一句"就是调模型然后调用工具"。

## 统一循环的入口层次

`agent_engine.rs` 对外暴露的入口有明确的层次关系：

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

最外层 `process_with_agent_with_events_guarded` 做两件事：一是获取 per-chat `TurnGuard`（确保同一 chat 同时只有一个 agent run），二是注册 `run_control` 运行并设置取消竞争。这意味着取消能力不是某个渠道的特性，而是 runtime 内核的一部分。

`AgentRequestContext` 很简洁，但每个字段都有用途：

```rust
pub struct AgentRequestContext<'a> {
    pub caller_channel: &'a str,
    pub chat_id: i64,
    pub chat_type: &'a str,
}
```

`caller_channel` 决定 provider/model override 和 SOUL.md 选择；`chat_id` 是记忆、会话、权限的主键；`chat_type` 区分 private 和 group 以选择不同的历史重建策略。

### 每一轮为什么都要带着可恢复的上下文？

统一循环管理的不是"收到一段文本"，而是"在某个聊天上下文里继续一轮执行"。一次运行至少要知道自己属于谁、带着哪些消息、是否从持久化状态恢复而来。

Rust 版本把这些事实压成一个 `TurnContext`。后面的记忆注入、工具循环和最终持久化，都围绕同一个对象展开。

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

Python 版本用 `@dataclass` 表示同一件事。它看起来简单，但可恢复 runtime 的关键特征就在于：运行时上下文必须先成为对象，后续状态机才有可靠支点。

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

## run_control：取消不是附加功能

`run_control.rs` 实现了一套完整的运行取消原语。核心数据结构是 `ACTIVE_RUNS`——一个全局的 `(channel, chat_id) -> Vec<ActiveRun>` 映射。

每次 agent run 开始时：

1. `register_run` 分配唯一 `run_id`，创建 `cancelled: Arc<AtomicBool>` 和 `notify: Arc<Notify>`。
2. 外层用 `tokio::select!` 让取消通知和实际执行竞争。
3. 如果收到取消信号，循环立即结束，返回 `"Current run aborted."`，并通过 `AgentEvent::Cancelled` 通知事件流。
4. 结束后 `unregister_run` 清理。

`abort_runs` 可以取消某个 chat 的所有活跃 run，并把对应的 source_message_id 加入 `ABORTED_SOURCE_MESSAGE_IDS`。后续 session resume 时，被中止的消息会被跳过，避免"被取消的问题又被重新处理"。

这个设计解决了一个非常现实的问题：用户在群里说 `/stop`，系统必须能立即停止当前 run，而不是等工具超时。取消是 runtime 级别的一等公民，不是某个渠道的特殊处理。

## ChatTurnQueue：per-chat 轮次串行化

`chat_turn_queue.rs` 确保同一个 (channel, chat_id) 同时只有一个 agent run。多余的消息不会被丢弃，而是被排队（最多 `chat_turn_queue_max_pending` 条，默认 20）。当前 run 结束后，`maybe_rerun_for_pending` 会检查排队消息并触发新 run。

这意味着 MicroClaw 不会因为用户连续发了三条消息就同时启动三个 agent run。这在群聊场景下尤其重要——没有串行化，并发 run 可能同时读写同一个 session，造成状态混乱。

`TurnGuard` 是 RAII 模式：持有 `OwnedMutexGuard<()>`，drop 时自动释放。这让"保证串行"变成了编译器可检查的事。

## SOUL.md：人格注入的层级策略

MicroClaw 提供了 `SOUL.md` 作为人格自定义机制。`load_soul_content` 按以下优先级搜索：

1. per-channel/account 配置路径（`channels.<name>.soul_path`）
2. 全局配置路径（`config.soul_path`）
3. `~/.microclaw/SOUL.md`（data_root 下）
4. `./SOUL.md`（当前工作目录）
5. per-chat 覆盖：`runtime/groups/{chat_id}/SOUL.md`

如果找到 SOUL.md，其内容会被包裹在 `<soul>...</soul>` 标签内注入系统提示词，替换默认的身份描述。如果没有，系统使用内建的"You are {bot_username}, a helpful AI assistant"。

per-chat 覆盖的优先级最高——这意味着某个特定群组可以有完全不同的 bot 人格，而不影响其他群组。这在多租户场景下非常实用。

这个设计的关键洞察是：人格不是提示词工程的一部分，而是 runtime 配置的一部分。把它做成文件而不是配置字符串，让非工程师也能编辑。

## 显式记忆 fast-path：绕过完整循环

`process_with_agent_logic` 的第一步不是进入工具循环，而是调用 `maybe_handle_explicit_memory_command`。这个函数检测用户消息是否是显式记忆命令（如"记住 X"或"remember X"）。如果是，它会：

1. 提取记忆内容。
2. 执行质量检查（过滤过于模糊的内容）。
3. 与现有记忆做 Jaccard 去重。
4. 如果同一 topic 冲突，走 supersede。
5. 以 0.95 置信度写入结构化记忆。
6. 直接返回确认消息，跳过整个 agent loop。

这条 fast-path 体现了一个很成熟的 runtime 思维：不是所有事情都应该强迫模型决定。对于"请记住 X"这种显式意图，走结构化逻辑比让模型自由发挥更可靠。

## Session Resume 与历史重建

统一循环在一开始就要决定：这次是恢复已有 session，还是从数据库历史重建？

从 `process_with_agent_logic` 可以看到两条清晰的路径：

**路径一：Session 存在。** 反序列化已保存的消息，获取 session 更新时间后的新用户消息，追加到序列中。追加时会跳过已被 `run_control` 中止的消息和斜杠命令。如果 session 数据损坏（反序列化后为空），回退到路径二。

**路径二：无 Session。** 从数据库加载最近历史。私聊场景取最近 `max_history_messages` 条；群聊场景使用 `get_messages_since_last_bot_response`——也就是从上次 bot 回复之后开始捕获，这更符合群聊"被 mention 后处理上下文"的语义。

### 恢复逻辑为什么必须放在核心循环里？

因为这不是渠道特性，而是 runtime 特性。session 保存的是完整消息状态（包括工具调用块），而不仅是纯文本。如果把 resume 放到各渠道适配器里，工具调用链的一致性很快就会丢失。

## 系统提示词构建

`build_system_prompt` 是一个近 200 行的函数，组装内容如下：

| 组成部分 | 来源 | 说明 |
| --- | --- | --- |
| 身份 | SOUL.md 或默认描述 | 定义 bot 人格 |
| 身份规则 | 硬编码 | 如何回答"你是谁" |
| 能力目录 | `ToolRegistry` | 列出所有可用工具及使用场景 |
| 权限模型 | 硬编码 | chat_id 作用域和 control chat |
| 时间上下文 | 运行时 | 当前本地时间和 UTC |
| 执行可靠性 | 硬编码 | 必须等工具返回成功才能声称完成 |
| 内置执行手册 | 硬编码 | 何时直接调工具、何时先确认 |
| 记忆上下文 | `MemoryManager` + `MemoryBackend` | 文件记忆 + 结构化记忆，带 token 预算 |
| 技能目录 | `SkillManager` | 可用 skills 列表 |
| 插件上下文 | `PluginManager` | plugin prompt 和 document 注入 |

关键部分还包括：todo 工具的强制使用规则（"如果你要调用任何工具，必须先创建 todo list"）、子代理编排模板（depth-2 orchestration pattern）和 per-channel 系统提示词扩展。

## 图像输入支持

当 `image_data` 存在时（来自用户发送的图片），系统会把最后一条 user 消息从纯文本转换为 blocks 格式，包含一个 `ContentBlock::Image` 和原有文本。这让多模态输入不需要特殊的渠道处理——任何渠道只要能提取图片的 base64 数据和 media type，就能进入统一循环。

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

## Context Compaction：窗口控制不是附属功能

当 `messages.len() > max_session_messages`（默认 40）时，`compact_messages` 执行：

1. 把消息分为旧片段和最近 `compact_keep_recent`（默认 20）条。
2. 把旧片段序列化为文本（截断到 20000 字符上限）。
3. 调模型生成摘要（带 `compaction_timeout_secs` 超时，默认 180 秒）。
4. 构造新消息序列：`[Conversation Summary]` + assistant 确认 + 最近消息。
5. 修复角色交替（合并连续同角色消息）。

如果摘要生成失败或超时，回退到简单截断（只保留最近消息）。

Compaction 前还会执行 `archive_conversation`——把原始消息归档到文件，作为不可逆压缩的安全网。compaction 的 LLM 用量会被单独记录为 `"compaction"` 类型，方便成本追踪。

### Compaction 为什么必须和工具消息结构保持一致？

`llm.rs` 中的 `sanitize_messages` 专门清理无法匹配最近 `ToolUse` 的 `ToolResult` 块。一旦 compaction 造成工具调用链断裂，下次恢复时就可能出现"tool result does not follow tool call"。这也是为什么 compaction 属于内核，而不是提示词层的小技巧。

## Tool Loop 与防失控保护

统一循环最核心的部分是主 for 循环，最多运行 `max_tool_iterations`（默认 100）轮。整体流程如下：

```
取消检查 → BeforeLLMCall Hook → 调模型 → 记录 trace/用量
  → stop_reason 分支：
      end_turn → 提取文本 → 保存 session → 返回
      tool_use → 指纹检测 → execute_tool_batch → 追加结果 → 继续
      其他    → 安全结束
```

每轮：

1. 发送 `AgentEvent::Iteration`。
2. 执行 `BeforeLLMCall` hook（可 block 或修改 system prompt）。
3. 调模型（流式或非流式，取决于是否有 event_tx）。
4. 记录 OTLP trace span。
5. 记录 LLM 用量。
6. 根据 `stop_reason` 分支：
   - `end_turn` / `max_tokens`：提取文本，处理 thinking tags，保存 session，返回。
   - `tool_use`：提取 `PendingToolCall`，委托给 `tool_executor::execute_tool_batch`，追加结果，继续。
   - 其他：安全结束。

### 重复工具指纹检测

每次 `stop_reason=tool_use` 时，系统会计算 `tool_use_fingerprint`——把所有工具调用的 `name:input` 拼接成字符串。如果连续 6 轮（`MAX_IDENTICAL_TOOL_USE_STREAK`）指纹完全相同，循环立即中止。

这比单纯设置"最多 100 轮"重要得多。很多 agent 失控不是随机发散，而是卡在"同一个工具、同一组参数、同一个报错"里机械重试。指纹检测能更早止损。

### 空可见回复重试

如果模型返回的文本在去除 `<think>` / `<thought>` tags 后为空，系统会注入一条 `[runtime_guard]` 消息要求重试——但只重试一次。这防止了"模型只输出思考但不输出可见文本"的边缘情况。

### stop_reason=tool_use 但无可执行工具

如果模型声称 `tool_use` 但解析不出任何工具调用，系统记录警告并安全结束。这是典型的 runtime 防御性设计——模型的 `stop_reason` 不能盲信。

## Provider 和 Model 运行时解析

`resolve_effective_provider_and_model` 按以下优先级确定实际使用的 provider 和 model：

1. per-channel provider override（`llm_provider_overrides`）
2. 全局 provider（`config.llm_provider`）
3. per-channel model override（`llm_model_overrides`）
4. profile default model
5. provider 级别默认 model（如 anthropic 对应 `claude-sonnet-4-5-20250929`）

还会读取 per-chat `SessionSettings`，其中的 `thinking_level` 可以覆盖 `show_thinking` 行为。如果 provider override 指向不同的 profile，系统会创建独立的 `scoped_provider`，确保不同渠道可以使用完全不同的 LLM 后端。

## 事件流与可观测性

`AgentEvent` 枚举是统一循环的可观测接口：

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

`ToolWaveStart`/`ToolWaveComplete`（来自并行工具执行）和 `Cancelled`（来自 run_control）也是重要事件。这组事件服务于 Web 流式界面、SSE 和 tracing/metrics。

每次 LLM 调用和工具执行都会生成 OTLP `SpanData`，包含 trace_id、span_id、parent_span_id，形成完整的分布式追踪链。工具 span 的 attributes 包含 tool name、input、output、duration，让排查"哪个工具在哪一轮出了什么问题"成为可能。

## 子代理集成点

统一循环本身不直接管理子代理——子代理通过 `sessions_spawn` 等工具间接创建。但循环提供了几个关键集成点：

- `ToolAuthContext` 的 `caller_chat_id` 和 `control_chat_ids` 决定子代理的权限边界。
- `skill_env_files` 在工具执行期间动态积累，通过 `activate_skill` 的 metadata 返回。
- Session 保存时会连带保存 `skill_env_files`，确保 resume 后技能环境一致。
- `ToolRegistry::new_sub_agent` 提供受限工具集，可选是否暴露编排工具（取决于嵌套深度配置）。

```{=typst}
#pagebreak(weak: true)
```

## 示例代码：统一循环为什么必须自己持有状态和工具边界？

真正的 `agent_engine.rs` 比下面复杂得多，但核心结构没有变：它必须自己维护消息状态、自己消费模型返回、自己决定何时停下。只要这些责任被拆散到外层脚本里，循环就不再可恢复，也不再可观测。

Rust 版本把模型、工具和取消信号都收进 `AgentEngine`，让 `run_turn` 只暴露一个明确的异步入口。

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

第一段先回答统一循环"手里到底握着什么"。只有模型、工具、消息历史和取消信号都属于同一个对象，后面的状态机推进才不会退化成外层脚本帮它拼装。

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

Python 版本保留同样的状态机意图，用 `Protocol` 标出模型边界。

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

### 决策一：把会话恢复、SOUL 注入、记忆、工具循环集中在一个引擎中

优点是行为一致、易于观测。代价是 `agent_engine.rs` 达到 3541 行，必须依赖 `tool_executor.rs`（877 行）做工具执行拆分，以及 `memory_service.rs` 做记忆相关逻辑拆分。

### 决策二：取消和串行化作为内核原语

优点是所有渠道都免费获得取消和排队能力。代价是必须在循环的每个关键点考虑取消状态，增加了状态机的复杂度。

### 决策三：SOUL.md 作为文件注入而非配置字符串

优点是非工程师可以编辑人格，per-chat override 的灵活度很高。代价是文件系统成为依赖，SOUL.md 的缺失或损坏需要有明确的回退策略。

### 决策四：把 compaction 当成正式机制，而不是临时补救

优点是成本和上下文窗口更可控。代价是需要持续维护摘要质量，compaction 前必须归档原始消息作为安全网。

### 决策五：把审批逻辑嵌入循环内部

优点是用户确认和工具重试语义一致。代价是循环状态机比纯工具调用链更复杂——`waiting_for_user_approval` 会提前结束循环并保存 session，等用户下次 approve 时 resume。

## 容易走错的地方

### 失败模式 1：把统一循环误解成"模型调用包装器"

如果只关注 LLM 请求本身，就会低估 session resume、SOUL 注入、记忆、审批、compaction、run_control、事件流这些关键机制。

### 失败模式 2：把会话恢复放到渠道层处理

不同渠道的行为会开始分叉。MicroClaw 的 session resume 保存完整消息状态（包括工具调用块），只有在核心循环里才能保证一致性。

### 失败模式 3：只设置迭代上限，不做重复工具死循环检测

系统可能在几十轮内白白消耗大量 token 和工具成本。fingerprint 检测在连续 6 次相同调用后即止损。

### 失败模式 4：忽视取消信号的传播

如果取消只停止 LLM 调用但不停止工具执行，或者不标记 source message 以避免重新处理，系统行为会变得不可预测。

## 读到这里，你应该能回答

- 你是否能画出 `process_with_agent` 的主要阶段，包括取消竞争和轮次锁？
- 你是否理解 SOUL.md 的五级搜索优先级？
- 你是否知道 Session Resume 和历史重建为什么必须放在核心循环里？
- 你是否把 Context Compaction 看成正式状态管理机制（带归档和超时回退）？
- 你是否理解 `tool_use`、审批、取消、重复指纹检测在这里是同一套状态机的一部分？

## 证据来源（v0.1.38）

- 核心源码路径：`src/agent_engine.rs`（3541 行，统一循环全部逻辑）、`src/run_control.rs`（运行注册/取消/中止）、`src/chat_turn_queue.rs`（per-chat 串行化）、`src/memory_service.rs`（显式记忆 fast-path、build_db_memory_context）
- 关键函数：`process_with_agent_with_events_guarded`（取消竞争）、`process_with_agent_logic`（主循环）、`load_soul_content`（SOUL.md 加载）、`build_system_prompt`（系统提示词构建）、`compact_messages`（compaction）、`resolve_effective_provider_and_model`（provider/model 解析）
- 关键配置项：`max_session_messages=40`、`compact_keep_recent=20`、`compaction_timeout_secs=180`、`max_tool_iterations=100`、`MAX_IDENTICAL_TOOL_USE_STREAK=6`、`chat_turn_queue_max_pending=20`

## 小结

MicroClaw 的统一循环之所以重要，是因为它把原本容易分散在各处的能力——session 恢复、SOUL 人格、记忆注入、图像输入、工具循环、并行执行、compaction、审批、取消、串行化、子代理集成——收敛成了一条可恢复、可压缩、可观测、可中断的主链路。取消和串行化从"渠道特性"升级为"内核原语"，SOUL.md 从"提示词技巧"升级为"runtime 配置"。

下一章我们把视角从"循环如何调度工具"进一步下探，专门拆开工具系统本身：44 个内置工具如何分类、wave-based 并行执行如何工作、concurrency class 如何决定谁能并行谁必须串行。

## 图表清单

### 图 6-1：`process_with_agent` 统一循环

![图 6-1：`process_with_agent` 统一循环](../assets/figures/fig-06-agent-loop.svg)

这张图直接对应本章最核心的状态机：取消竞争、轮次锁、session 恢复、SOUL/记忆注入、模型决策、工具批次分发、compaction、审批和结束条件都被压在同一个循环里。

如需继续扩展配图，本章还可补：

- 图 6-2：run_control 取消信号传播路径
- 图 6-3：SOUL.md 五级搜索优先级
- 图 6-4：Context Compaction 前后消息结构示意
