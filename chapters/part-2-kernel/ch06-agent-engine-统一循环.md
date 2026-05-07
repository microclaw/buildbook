# Chapter 6 Agent Engine 统一循环

## 一个循环承载所有

Agent 引擎的工程难点不在"调一次模型"，而在把 session 恢复、记忆注入、工具循环、取消、串行化、压缩、事件流收敛成同一条链路。如果每个渠道、每个入口（聊天、ACP、Web）各自实现这套机制，行为差异会迅速膨胀成可观测性灾难。

MicroClaw 把所有运行路径统一到 `src/agent_engine.rs`（4215 行）的 `process_with_agent_*` 系列函数。本章自外向内拆解：入口层次 → run 控制 → 主循环骨架 → 防失控机制 → 事件流。

## 入口层次

```
process_with_agent                          // 最简入口
  └─ process_with_agent_with_events         // 带事件流
       └─ process_with_agent_with_events_guarded  // 带轮次锁
            ├─ run_control::register_run     // 注册运行，获取取消信号
            ├─ tokio::select!                // 取消 vs 正常执行竞争
            │   └─ DefaultAgentEngine::process_with_events
            │        └─ process_with_agent_impl   // tracing span 包装
            │             └─ process_with_agent_logic  // 真正的主循环
            └─ run_control::unregister_run   // 清理
```

最外层做两件事：**获取 per-chat `TurnGuard`**（同一 chat 同时只有一个 run）+ **注册 `run_control` 取消通道**（用户随时可中止）。然后用 `tokio::select!` 让"正常执行"和"取消信号"竞争——取消是一等公民，不是事后补丁。

## `run_control` 与 `ChatTurnQueue`

- **取消**：`register_run` 创建 `cancelled: Arc<AtomicBool>` + `Notify`，`tokio::select!` 在主循环和取消之间竞争。被中止的消息加入 `ABORTED_SOURCE_MESSAGE_IDS`，下次 resume 时跳过——避免被中止的消息再次触发 agent。
- **串行化**：`ChatTurnQueue` 保证同一 `(channel, chat_id)` 同时只有一个 run，多余消息排队（默认上限 20）。`TurnGuard` 用 RAII 释放锁，函数 panic 也不会留下死锁。

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
        self.messages.push(Message::user(format_user_message("user", text)));
    }
}
```

取消必须**同时**停止 LLM 流和工具执行，并标记 source message 避免重复处理——任一环漏了都会出现"用户按了停止，几秒后又出来一段回复"的体验问题。

## 主循环骨架

```
进入 process_with_agent_logic：
  1. session resume：恢复历史消息，跳过被中止的，过滤斜杠命令
  2. 系统提示词组装：SOUL.md + 工具目录 + 时间 + 记忆（带 token 预算） + 技能 + 手册
  3. 显式记忆 fast-path：检测"记住 X"直接走结构化写入，跳过 agent loop
  4. 进入主循环（最多 max_tool_iterations=100 轮）：
       a. 取消检查
       b. BeforeLLMCall hook
       c. 调模型并记录 trace/用量
       d. 分支 stop_reason：
           end_turn → 提取文本 → 持久化 session → 返回
           tool_use → 指纹检测 → wave 调度 → 追加结果 → 继续
           其他    → 安全结束
       e. 中途若有新用户消息进队 → 触发 MidTurnInjection，注入后继续
  5. 退出循环：保存 session、归档可压缩段、emit FinalResponse
```

每一步都是面向"长期运行下出现的真实故障"做出的设计：session resume 让进程重启不丢上下文；显式记忆 fast-path 让"记住我喜欢简洁回答"不消耗 LLM 预算；mid-turn 注入让用户在 agent 思考时仍能补充上下文。

## SOUL.md 与系统提示词

`load_soul_content` 按优先级搜索：per-channel 配置 → 全局 `soul_path` → `~/.microclaw/SOUL.md` → `./SOUL.md` → per-chat `runtime/groups/{chat_id}/SOUL.md`（最高优先级）。命中后用 `<soul>` 标签包裹注入。这种"per-chat 覆盖全局"的优先级让群聊可以独立调教人格，而不影响私聊。

`build_system_prompt` 组装顺序：身份（SOUL.md）→ 能力目录（ToolRegistry 摘要）→ 时间上下文 → 记忆（按 token 预算截断）→ 技能/插件 → 执行手册（边界与禁区）。顺序本身就是优先级——靠前的字段在 LLM 注意力中权重更高。

## 显式记忆 fast-path

进入主循环前先检测"记住 X" / "remember X" 模式：

```
质量检查 → Jaccard 去重（阈值 0.55）→ topic 冲突走 supersede
  → 0.95 置信度写入 → 跳过 agent loop
```

为什么单独走？显式意图本身已是结构化语义，让模型自由发挥反而增加失败面（误解原文、写入垃圾、生成多余对话）。结构化处理比让 LLM "思考一下"更可靠、更省成本。

## Session Resume

| 路径 | 行为 |
| --- | --- |
| Session 存在 | 反序列化完整消息（含工具调用块）+ 追加新消息（跳过被中止的、过滤斜杠命令） |
| 无 Session | 私聊取最近 N 条消息；群聊取上次 bot 回复后的消息 |

Session 必须保存**完整工具调用链**——丢了 `tool_use` 配套的 `tool_result` 会让模型 API 直接拒绝。`sanitize_messages` 在 resume 后清理断裂的工具调用对，是必要的兜底。

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

图像不当作独立消息，而是合并到最近的 user 消息——对模型而言"用户发了一张图并附文字"是同一轮输入，分开发会破坏语义连续性。

## Context Compaction

`messages.len() > 40` 时触发：

```
archive_conversation 归档原始消息 → 旧片段序列化（截断 20000 字符）
  → 调模型摘要（180s 超时）→ [Conversation Summary] + 最近 20 条
  → 失败回退简单截断
```

`sanitize_messages` 在压缩后清理断裂的工具调用链。归档先于压缩——历史不应因为压缩失败而丢失。

## Tool Loop 与防失控

防失控不是单一机制，而是四重叠加：

| 机制 | 阈值 | 作用 |
| --- | --- | --- |
| 迭代上限 | `max_tool_iterations` = 100 | 兜底：防止无限循环 |
| 重复调用抑制 | 连续 6 次 `name:input` 完全相同 → 立即中止 | 关键：失控通常是机械重试 |
| 空可见回复重试 | 去除 `<think>` 后为空 → 注入 `[runtime_guard]` 重试一次 | 防止 LLM 只输出思考链不出回复 |
| 无工具可执行兜底 | `stop_reason=tool_use` 但解析不出工具 → 警告并安全结束 | 防止解析异常陷入死循环 |

重复调用抑制比迭代上限更重要：失控通常是 6 轮内就把同一查询打十几次，迭代上限根本来不及触发。`tool_cache::cache_key()` 把工具名+归一化输入作为指纹，连续命中即止损。

## 事件流

```rust
pub enum AgentEvent {
    Iteration { iteration: usize },
    ToolStart { name: String, input: Value },
    ToolResult {
        name: String,
        is_error: bool,
        preview: String,
        duration_ms: u128,
        status_code: Option<i32>,
        bytes: usize,
        error_type: Option<String>,
    },
    TextDelta { delta: String },
    ToolWaveStart { wave: usize, tool_count: usize },
    ToolWaveComplete { wave: usize },
    Cancelled { final_text: String },
    MidTurnInjection { count: usize },
    FinalResponse { text: String },
}
```

事件流是渠道层（Web SSE、ACP stdio、调试 UI）的统一接入点。每次 LLM 调用和工具执行同时生成 OTLP `SpanData`，形成分布式追踪链——事件流面向用户，trace 面向工程师，二者并行不互相替代。

```{=typst}
#pagebreak(weak: true)
```

## 示例：取消 + 串行化的最小骨架

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
    last_fingerprint: Option<String>,
    fingerprint_streak: u32,
}

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
            let fp = fingerprint(&pending);
            if Some(&fp) == self.last_fingerprint.as_ref() {
                self.fingerprint_streak += 1;
                if self.fingerprint_streak >= 6 {
                    anyhow::bail!("repeated tool calls detected");
                }
            } else {
                self.last_fingerprint = Some(fp);
                self.fingerprint_streak = 1;
            }
            let results = execute_tool_batch(&self.tools, &pending).await;
            self.messages.extend(results);
        }
        anyhow::bail!("too many tool iterations")
    }
}
```

骨架三个要点：每轮先查取消、指纹检测在调模型之后，工具批次执行委托给 `execute_tool_batch`（下一章详解 wave 调度）。

## 关键权衡

| 决策 | 优点 | 代价 |
| --- | --- | --- |
| 集中在一个引擎文件 | 行为一致、易观测 | 4215 行需配套 `tool_executor.rs` 与 `memory_service.rs` 拆解 |
| 取消 / 串行化作为内核原语 | 所有渠道免费获得 | 每个关键点都要考虑取消状态 |
| SOUL.md 文件注入 | 非工程师可编辑 | 文件系统成为依赖 |
| Compaction 作为正式机制 | token 成本与窗口可控 | 需维护摘要质量 + 归档兜底 |
| 显式记忆 fast-path | 预测性强、省 LLM 成本 | 额外维护一条非通用路径 |
| Mid-turn 注入 | 用户体验更自然 | 状态机更复杂 |

## 容易走错的地方

1. **把统一循环误解成"模型调用包装器"**。session resume、SOUL 注入、记忆、压缩、run_control、事件流都是关键机制，少任何一个都会在生产暴露。
2. **把会话恢复放到渠道层**。每个渠道自行恢复 → 工具调用链一致性会丢失。Resume 必须在核心循环里，渠道只负责传消息。
3. **只设迭代上限不做重复检测**。失控通常发生在 6 轮内白白消耗 token，迭代上限根本来不及生效。
4. **忽视取消信号传播**。取消必须同时停止 LLM 与工具，并标记 source message——任何一处漏掉都会出现"取消失效"的体验问题。
5. **把 mid-turn 注入设计成单纯的拼接**。新消息要排在合适位置（一般是当前轮次结束后），并 emit `MidTurnInjection` 让前端知道发生了什么。

## 小结

统一循环把 session 恢复、SOUL 人格、记忆、工具循环、压缩、取消、串行化、事件流收敛成一条**可恢复、可观测、可中断**的主链路。所有渠道与入口共享同一行为骨架，是 agent 系统从 demo 到生产的最关键工程动作。

## 证据来源（v0.1.57）

`src/agent_engine.rs`（4215 行）、`src/run_control.rs`、`src/chat_turn_queue.rs`、`src/memory_service.rs`、`crates/microclaw-tools/src/tool_cache.rs`。关键配置：`max_session_messages=40`、`max_tool_iterations=100`、`MAX_IDENTICAL_TOOL_USE_STREAK=6`。

## 图表清单

### 图 6-1：`process_with_agent` 统一循环

![图 6-1：`process_with_agent` 统一循环](../../assets/figures/fig-06-agent-loop.svg)
