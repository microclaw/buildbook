# Chapter 6 Agent Engine 统一循环

## 这一章要回答什么问题

如果说前一章讲的是“系统怎么装起来”，那这一章讲的就是“系统实际怎样工作”。对 MicroClaw 来说，真正定义产品灵魂的不是某个渠道适配器，也不是某个具体工具，而是 `src/agent_engine.rs` 里的统一循环。

这个循环决定了：

- 一次请求如何恢复上下文。
- 记忆何时注入。
- 模型何时继续调用工具、何时结束回答。
- 超长会话何时压缩。
- 高风险动作何时要求确认。
- 运行过程如何留下可观测信号。

这一章读完后，你应该可以把 `process_with_agent` 的执行过程完整讲给别人听，而不是只说一句“就是调模型然后调用工具”。

## 统一循环的入口到底是什么

`agent_engine.rs` 对外暴露的核心入口是：

- `process_with_agent`
- `process_with_agent_with_events`

它们接收的上下文并不复杂，却非常关键：

- `caller_channel`
- `chat_id`
- `chat_type`
- 可选的 `override_prompt`
- 可选的 `image_data`

这组输入说明 MicroClaw 的循环不是“围绕 HTTP 请求”设计的，而是围绕“一个聊天上下文中的一次 agent 运行”设计的。无论入口来自 Telegram、Discord、Scheduler 还是 Web，本质上都会被收敛到同一种请求语义。

这就是统一循环最重要的第一步：把所有 ingress 先压平。

### 小例子：为什么每一轮都要带着可恢复的 TurnContext？

统一循环真正管理的并不是“收到一段文本”，而是“在某个聊天上下文里继续一轮执行”。这意味着一次运行至少要知道自己属于谁、带着哪些消息、是否从持久化状态恢复而来。

Rust 版本把这些事实压成一个 `TurnContext`。这样后面的记忆注入、工具循环和最终持久化，都能围绕同一个对象展开，而不是靠调用栈顺手传几个零散参数。

```rust
struct TurnContext {
    chat_id: i64,
    caller_channel: String,
    messages: Vec<String>,
    resumed_from_session: bool,
}

impl TurnContext {
    fn append_user_text(&mut self, text: &str) {
        self.messages.push(format!("user: {text}"));
    }
}
```

Python 版本用 `@dataclass` 表示同一件事。它看起来简单，但这正是可恢复 runtime 的关键特征：运行时上下文必须先成为对象，后续状态机才有可靠支点。

```python
from dataclasses import dataclass, field


@dataclass
class TurnContext:
    chat_id: int
    caller_channel: str
    resumed_from_session: bool
    messages: list[str] = field(default_factory=list)

    def append_user_text(self, text: str) -> None:
        self.messages.append(f"user: {text}")
```

## Session Resume 与历史重建

一个成熟的 Agent Runtime，不能假设每次请求都从零开始。MicroClaw 的统一循环在一开始就要决定：这次是恢复已有 session，还是回退到消息历史重建？

从 `agent_engine.rs`、`DEVELOP.md` 和存储层结构可以看出，这个过程至少包含几层逻辑：

1. 先根据 `chat_id` 尝试读取已保存的 session。
2. 如果 session 存在，则在已有消息状态上追加最近用户消息。
3. 如果 session 不存在，则从数据库历史构建上下文。
4. 在群聊场景下，不是简单拿最近 N 条，而是按“自上次 bot 回复之后的消息”做 catch-up。

这个设计的价值在于，它同时解决了两个常见问题。

第一，工具调用状态不会轻易丢失。因为 session 保存的是完整消息状态，而不仅是纯文本历史。

第二，群聊语义更接近真实使用场景。用户在群里提一句 bot 名字时，系统需要知道 mention 之后上下文发生了什么，而不是只看到最后一条孤立消息。

### 为什么恢复逻辑必须放在核心循环里

因为这不是渠道特性，而是 runtime 特性。如果把 session resume 放到 Telegram 或 Discord 各自处理，很快就会出现行为漂移：某个渠道支持恢复，另一个渠道只读消息历史，再加一个 Web 或 Scheduler 时又要重写一遍。

MicroClaw 把它放在统一循环里，本质上是在说：恢复能力属于 agent 内核，不属于平台边缘。

## 记忆注入与显式记忆 fast-path

统一循环并不只是恢复会话。它还会在进入模型前准备额外上下文，其中最重要的就是记忆。

当前实现里有两种不同性质的记忆路径。

### 第一层：文件记忆和结构化记忆注入

请求开始时，系统会装载文件记忆、结构化记忆、技能和运行时上下文。这意味着模型看到的并不是“裸聊天历史”，而是一个已经被环境、偏好、规则、历史事实增强过的上下文。

这也是为什么 MicroClaw 可以在多个渠道之间维持相对一致的行为。真正被注入的是 runtime 的共享记忆，而不是某个平台私有的 prompt 拼装。

### 第二层：显式记忆 fast-path

`memory_service.rs` 里有一个很值得注意的函数：`maybe_handle_explicit_memory_command`。它会在某些情况下绕过完整 agent loop，直接处理用户明确表达的记忆指令，并做：

- 质量检查
- 去重
- topic 冲突判断
- supersede 处理

这条 fast-path 体现了一个很成熟的 runtime 思维：不是所有事情都应该强迫模型决定。对于“请记住 X”这种显式意图，系统应该优先走更可靠的结构化逻辑，而不是把它完全外包给模型自由发挥。

## Context Compaction：窗口控制不是附属功能

只要系统支持长期会话，就一定会碰到上下文膨胀问题。MicroClaw 在 `config.rs` 里给出了明确的默认值：

- `max_session_messages = 40`
- `compact_keep_recent = 20`
- `compaction_timeout_secs = 180`

而 `agent_engine.rs` 中的 `compact_messages` 会在会话过长时执行总结和裁剪。

### 压缩流程的核心思路

从源码可以看出，这个过程不是简单删历史，而是：

1. 选出较旧的会话片段。
2. 生成用于总结的输入文本。
3. 调模型生成摘要。
4. 把摘要作为一条显式的“Conversation Summary”消息插回上下文。
5. 保留最近若干条消息原样存在。

这个设计比“只保留最近 N 条”强很多，因为它尽量保留任务连续性；但它也明显比“永不压缩”更可控，因为 token 成本和上下文噪声不会无限增长。

### 为什么压缩前后还要做消息清洗

`llm.rs` 中的 `sanitize_messages` 专门清理无法匹配最近 `ToolUse` 的 `ToolResult` 块。这个细节很重要。因为一旦 session compaction 或历史重建造成工具调用链断裂，下次恢复时就可能出现“tool result does not follow tool call”之类的不一致状态。

也就是说，Context Compaction 在 MicroClaw 中不是“写一段摘要 prompt”那么简单，它还必须和工具调用消息的结构保持一致。这也是为什么这项能力必须属于内核，而不能当成提示词层的小技巧。

## Tool Loop、`stop_reason` 与防失控保护

统一循环最核心的部分，是模型返回后系统到底怎么继续。

MicroClaw 把模型返回的控制语义压缩成少数几种 `stop_reason`，例如：

- `tool_use`
- `end_turn`
- `max_tokens`

这让循环可以写成非常明确的状态机：

1. 调用模型。
2. 如果要求工具调用，则执行工具。
3. 把工具结果追加回消息序列。
4. 继续下一轮。
5. 如果 `end_turn`，提取最终文本并结束。

### 为什么 `tool_use` 不能盲信

`docs/llm-provider-conventions.md` 明确要求：如果返回 `stop_reason=tool_use`，但解析不出任何可执行工具调用，运行时必须记录警告并安全结束本轮。

这是一个典型的 runtime 防御性设计。Agent 系统里最危险的假设之一，就是“模型说自己要用工具，那它一定给了正确 payload”。现实不是这样。Provider 兼容层、流式事件拼装、模型输出偏差都会产生异常情况。

MicroClaw 通过这层保护，把“模型格式不一致”从逻辑灾难降级成一次可诊断的请求失败。

### 迭代上限与重复工具指纹

`config.rs` 里把 `max_tool_iterations` 默认设为 `100`。这不是唯一保护。`agent_engine.rs` 还会对 `tool_use` 内容计算 fingerprint，如果模型连续多轮请求完全相同的工具调用，就会触发中止逻辑。

这一步的意义非常大。很多多轮 Agent 失控，不是无限随机发散，而是卡在“同一个工具、同一组参数、同一个报错”里机械重试。重复指纹检测可以更快识别这类死循环，并给用户明确说明为什么停止。

对生产系统来说，这比单纯设置“最多 100 轮”更重要，因为它能更早止损。

## 高风险工具审批与运行中断

统一循环还负责处理一个非常现实的问题：工具不是都能直接执行。

在 `agent_engine.rs` 中，高风险工具执行失败时，如果错误类型是 `approval_required`，系统会根据配置和最新用户消息判断是否能自动重试，或者进入等待确认状态。

这里至少有三层保护：

1. 工具风险分级。
2. `high_risk_tool_user_confirmation_required` 配置开关。
3. 对最近用户文本做“显式批准语义”识别。

这意味着审批不是外挂流程，而是循环内部的一部分。只有这样，模型请求、用户确认、工具重试三者之间的状态才能保持一致。

此外，`process_with_agent` 外层还接入了 `run_control`，支持运行取消和停止信号。也就是说，这条统一循环不仅要能“继续跑”，还要能“安全停”。

## 事件流与可观测性：循环必须能被看见

`AgentEvent` 枚举揭示了另一个关键事实：统一循环不是黑箱。它会发出：

- `Iteration`
- `ToolStart`
- `ToolResult`
- `TextDelta`
- `FinalResponse`

这组事件一方面服务 Web 流式界面和 SSE，另一方面也让 tracing/metrics 可以围绕同一套执行语义建立。

对工程团队来说，这一步非常关键。没有事件流，你只能在“最终回复错了”时做结果导向排查；有了事件流，你才能知道是：

- 模型连续要求错误工具
- 某个工具超时
- 审批卡住
- compaction 触发得太早
- session 恢复不完整

统一循环之所以叫统一，不只是因为所有请求都走这里，还因为所有请求都能在这里被观察。

```{=typst}
#pagebreak(weak: true)
```

## 示例代码：为什么统一循环必须自己持有状态和工具边界？

真正的 `agent_engine.rs` 比下面复杂得多，但核心结构并没有变：它必须自己维护消息状态、自己消费模型返回、自己决定何时停下。只要这些责任被拆散到外层脚本里，循环就不再可恢复，也不再可观测。

Rust 版本把模型和工具都收进 `AgentEngine`，让 `run_turn` 只暴露一个明确的异步入口。这样状态机的推进逻辑被固定在一个对象里，而不是由调用方一轮轮手动拼接。

```rust
#[async_trait::async_trait]
trait ModelClient {
    async fn next(&self, messages: &[String]) -> anyhow::Result<ModelResponse>;
}

struct AgentEngine<M> {
    model: M,
    tools: ToolRegistry,
    messages: Vec<String>,
}
```

第一段先回答统一循环“手里到底握着什么”。只有模型、工具和消息历史都属于同一个对象，后面的状态机推进才不会退化成外层脚本在帮它拼装。

```rust

impl<M: ModelClient> AgentEngine<M> {
    async fn run_turn(&mut self) -> anyhow::Result<String> {
        for _ in 0..10 {
            let response = self.model.next(&self.messages).await?;
            if let ModelResponse::EndTurn(text) = response {
                return Ok(text);
            }
            let (name, input) = response.require_tool_use()?;
            let result = self.tools.execute(&name, input).await?;
            self.messages.push(format!("tool_result: {result}"));
        }
        anyhow::bail!("too many tool iterations")
    }
}
```

```{=typst}
#pagebreak(weak: true)
```

Python 版本保留同样的状态机意图，但用 `Protocol` 标出模型边界，用 `@dataclass` 持有消息和工具。这样读者能更直观地看到：统一循环不是一个辅助函数，而是运行时里的主控对象。

```python
from dataclasses import dataclass, field
from typing import Protocol


class ModelClient(Protocol):
    async def next(self, messages: list[str]) -> dict: ...


@dataclass
class AgentEngine:
    model: ModelClient
    tools: ToolRegistry
    messages: list[str] = field(default_factory=list)
```

这里也先停在对象边界，再进入循环细节。这样读者会先理解状态归属，再理解每轮如何前进，分页也更自然。

```python

    async def run_turn(self) -> str:
        for _ in range(10):
            response = await self.model.next(self.messages)
            if response["type"] == "end_turn":
                return response["text"]
            if response["type"] == "tool_use":
                result = await self.tools.execute(response["name"], response["input"])
                self.messages.append(f"tool_result: {result}")
        raise RuntimeError("too many tool iterations")
```

## 关键权衡

### 决策一：把会话恢复、记忆注入、工具循环集中在一个引擎中

优点是行为一致、易于观测。代价是 `agent_engine.rs` 复杂度会持续上升，必须依赖明确的辅助模块做拆分。

### 决策二：优先使用结构化状态机，而不是让模型自由控制流程

优点是可恢复、可中止、可审计。代价是某些“更灵活”的 agent 行为会被 runtime 规则约束。

### 决策三：把 compaction 当成正式机制，而不是临时补救

优点是成本和上下文窗口更可控。代价是需要持续维护摘要质量和工具消息一致性。

### 决策四：把审批逻辑嵌入循环内部

优点是用户确认和工具重试语义一致。代价是循环状态机会比纯工具调用链更复杂。

## 容易走错的地方

### 失败模式 1：把统一循环误解成“模型调用包装器”

如果只关注 LLM 请求本身，就会低估 session、记忆、审批、压缩、事件流这些关键机制。

### 失败模式 2：把会话恢复放到渠道层处理

这样做最直接的结果，就是不同渠道的行为开始分叉，后续几乎无法统一治理。

### 失败模式 3：只设置迭代上限，不做重复工具死循环检测

系统仍然可能在几十轮内白白消耗大量 token 和工具成本。

## 读到这里，你应该能回答

- 你是否能画出 `process_with_agent` 的主要阶段？
- 你是否理解 Session Resume 和历史重建为什么必须放在核心循环里？
- 你是否把 Context Compaction 看成正式状态管理机制，而不是“摘要一下旧消息”？
- 你是否知道 `tool_use`、审批、取消、中止在这里是同一套状态机的一部分？

## 证据来源（v0.1.16 / 95491b7）

- 源码基线：<https://github.com/microclaw/microclaw/tree/95491b787a61a71f43aeb6556c695a3bd1c006ce>
- 核心源码路径：`src/agent_engine.rs`、`src/llm.rs`、`src/memory_service.rs`
- 关键配置项：`src/config.rs` 中与 `max_session_messages`、`compact_keep_recent`、`compaction_timeout_secs`、`max_tool_iterations`、`high_risk_tool_user_confirmation_required` 相关的默认值
- 测试 / 运行文档路径：`docs/llm-provider-conventions.md`（`Rules`）；`DEVELOP.md`（`Architecture overview` -> `Data flow`）；`TEST.md`（`5. Session Management`, `20. Multi-Step Tool Use (Agentic Loop)`, `26. Error Handling & Recovery`）；`docs/test/blackbox-core-20-cases.md`（`TC01`, `TC02`, `TC04`, `TC06`）

## 小结

MicroClaw 的统一循环之所以重要，是因为它把原本容易分散在各处的能力，收敛成了一条可恢复、可压缩、可观测、可中断的主链路。只要这条链还保持稳定，系统就能继续扩展渠道、工具和生态而不至于立即失控。

下一章我们把视角从“循环如何调度工具”进一步下探，专门拆开工具系统本身：它如何注册、授权、执行、审批，并在风险可控的前提下给 Agent 真正的执行力。

## 图表清单

### 图 6-1：`process_with_agent` 统一循环

![图 6-1：`process_with_agent` 统一循环](../assets/figures/fig-06-agent-loop.svg)

这张图直接对应本章最核心的状态机：恢复、注入、模型决策、工具回灌、压缩、审批和结束条件都被压在同一个循环里。

如需继续扩展配图，本章还可补：

- 图 6-2：Session Resume 与历史重建路径
- 图 6-3：Context Compaction 前后消息结构示意
