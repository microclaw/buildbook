# Chapter 1 为什么是 MicroClaw

## 这一章要回答什么问题

很多团队第一次做 Agent 系统，起点往往是“把大模型接进聊天窗口”。这个起点没有错，但它很快会暴露一个结构性问题：真正有价值的任务，通常不只是文本问答，而是一个持续运行、可调用工具、可跨渠道、可恢复的执行过程。

MicroClaw 的意义，就在于把 Agent 从“一个会回复消息的机器人”推进到“一个可以长期运行的工程化 runtime”。这一章读完后，你应该能回答三个问题：

1. 为什么传统聊天机器人范式不足以支撑复杂任务。
2. MicroClaw 想解决的核心问题是什么。
3. 它与同类项目相比，选择了怎样的工程边界。

## 从聊天机器人到执行型 Runtime

传统聊天机器人强调的是一次输入、一次回复。它的关键路径通常很短：

1. 收到一条消息。
2. 组装 prompt。
3. 调一次模型。
4. 把回复发出去。

这个模型对 FAQ、客服和轻量助手很有效，但一旦任务变复杂，问题就出现了。

第一个问题是工具执行。真正的生产任务往往需要：

- 读写文件
- 执行 shell 命令
- 查数据库或 HTTP API
- 抓取网页
- 调度定时任务

这意味着系统不再只是“生成文本”，而是要在模型和外部世界之间建立一层可靠的工具执行边界。

第二个问题是会话恢复。用户不会只在一个短会话里工作。一个任务可能跨越几小时、几天，甚至在多个渠道之间切换。系统必须知道：

- 这是谁的任务
- 当前会话状态是什么
- 上次停在了哪里
- 需要恢复哪些上下文

第三个问题是长期记忆。用户偏好、环境细节、项目背景、常用命令，如果每次都重新输入，系统就没有实际生产力。记忆必须具备最少三个条件：

- 可持久化
- 可注入到后续请求
- 可审计和可纠错

第四个问题是运维与成本。Agent 一旦具备多轮工具调用能力，就会带来新的工程风险：

- 无限工具循环
- 成本失控
- 任务卡死
- 输出不可追踪

因此，一个可用的 Agent 系统必须把“执行、恢复、记忆、观测、成本控制”放进同一套 runtime 设计里。MicroClaw 的定位，正是在这里。

### 小例子：为什么请求对象不能只包含一段文本？

如果系统只打算“一问一答”，那输入里只有 `text` 也许够用。但一旦系统要恢复会话、区分渠道、决定是否允许工具，它就必须在请求对象里显式携带更多运行时事实。

Rust 版本把“文本请求”和“运行时请求”区分成两个 `struct`。这样读者能立刻看到，复杂度并不是凭空长出来的，而是系统职责变多以后，输入语义必然变厚。

```rust
struct ChatRequest {
    text: String,
}

struct RuntimeRequest {
    channel: String,
    chat_id: i64,
    session_key: String,
    text: String,
    allow_tools: bool,
}
```

Python 版本用 `@dataclass` 表达同样的差异。动态语言里更容易把这些字段散成几个松散参数，所以这里故意把它们收成明确对象。

```python
from dataclasses import dataclass


@dataclass
class ChatRequest:
    text: str


@dataclass
class RuntimeRequest:
    channel: str
    chat_id: int
    session_key: str
    text: str
    allow_tools: bool
```

## MicroClaw 解决的是什么问题

MicroClaw 不是“再做一个聊天 UI”，也不是“只做一个模型接入层”。它要解决的是更具体的工程问题：如何把一个多渠道智能体，做成可持续运行、可维护、可扩展的统一内核。

从源码结构看，这个目标非常明确：

- `src/agent_engine.rs` 负责统一 Agent Loop。
- `src/llm.rs` 负责统一 provider 抽象。
- `src/channels/*.rs` 负责渠道适配。
- `src/tools/*.rs` 负责工具系统。
- `crates/microclaw-storage/src/db.rs` 负责持久化。
- `src/scheduler.rs` 负责计划任务与后台循环。
- `src/web.rs` 负责 Web 控制面与 API。

这说明 MicroClaw 不是围绕“某个渠道”组织代码，而是围绕“运行时内核”组织代码。渠道只是入口，核心循环和状态模型才是主体。

这个选择有两个直接好处。

第一，功能不会被渠道绑死。只要一个能力被实现为内核特性，它就可以复用到 Telegram、Discord、Slack、Feishu、Web 等多个入口，而不必为每个平台各写一套。

第二，系统更容易演进。工具、记忆、调度、可观测性这些能力都挂在统一 runtime 上，后续扩展新入口时，成本主要是适配 ingress/egress，而不是重写核心逻辑。

## MicroClaw 的四个核心设计目标

### 1. 多渠道，但核心单一

MicroClaw 的第一原则不是“支持更多平台”，而是“支持多个平台时不分裂核心逻辑”。这就是为什么它把共享 Agent Loop 放在 `src/agent_engine.rs`，而把 Telegram、Discord、Slack、Web 适配器拆成边缘模块。

这类设计能避免一个常见陷阱：每加一个平台，系统就多一套行为分支，最后变成无法维护的渠道特化代码。

### 2. 允许 Agent 真正执行任务

MicroClaw 默认不是只返回文本。它内置 bash、文件操作、glob、grep、web 搜索、调度、memory 等工具，这意味着它的基本操作单元不是“回复一句话”，而是“完成一个带外部副作用的工作单元”。

这也是本书反复使用“runtime”而不是“chatbot”的原因。前者强调执行过程，后者强调对话界面。

### 3. 状态必须可恢复

一个工程系统不能假设每次调用都是全新开始。MicroClaw 使用 SQLite 保存聊天、消息、session、task、memory 等状态，这让它具备以下能力：

- 中断后恢复
- 长会话继续
- 任务历史追踪
- 观察系统行为

这类能力对个人使用很重要，对团队部署更是刚需。

### 4. 成本和风险要可控

Agent 系统最大的幻觉之一，是“看上去很聪明，所以应该可以自动跑很久”。现实恰好相反：越是允许多轮推理和工具调用，越要控制预算、超时、权限和副作用。

MicroClaw 在配置和实现里都体现了这种思路：

- 工具超时
- 高风险工具确认
- 会话压缩
- subagent 预算
- 审计与可观测性

它不是追求“最自由的代理”，而是追求“可控的执行系统”。

## 与同类项目相比，MicroClaw 的位置在哪里

和 OpenClaw 这类更强调 Gateway / Control Plane 的系统相比，MicroClaw 更偏向“单机优先、运行时内聚”。它已经有 Web API、SSE、WebSocket bridge、A2A、ACP、Hooks，但这些能力仍然围绕一个本地 runtime 展开，而不是先构建一个巨大的分布式控制平面。

和更轻量的个人代理项目相比，MicroClaw 又明显更重工程性。它不仅支持文件和命令，还包含：

- 结构化记忆
- 反射器（reflector）
- 调度器
- OTLP 指标
- Web 控制台
- 审计日志

所以它的适用场景非常明确：

- 不只是做 Demo
- 不只是做一个 CLI 玩具
- 而是要让 Agent 在真实聊天环境里长期运行

这也是它与“聊天助手”最根本的区别。聊天只是表面形态，真正的产品是 runtime。

## 关键权衡

## 示例代码：为什么把状态和工具纳入 Runtime，比只返回一段文本更重要？

下面这组代码故意把“聊天 bot”和“执行型 runtime”并排放在一起。真正的差异不在回复文案，而在系统是否显式持有状态、依赖和后续动作。

Rust 版本用 `trait + struct + async fn` 把执行边界写死：工具能力是稳定接口，运行时自己持有会话状态，异步方法只出现在真实的执行路径上。这样写能直接体现 MicroClaw 不是“调一次模型”，而是“驱动一段会持续演化的会话”。

```rust
#[async_trait::async_trait]
trait ToolExecutor {
    async fn run(&self, command: &str) -> anyhow::Result<String>;
}

struct EchoBot;

impl EchoBot {
    async fn reply(&self, user_text: &str) -> String {
        format!("echo: {user_text}")
    }
}

struct AgentRuntime<T: ToolExecutor> {
    tool_executor: T,
    session_messages: Vec<String>,
}
```

这段先只定义运行时真正持有的边界。先把工具接口和会话状态钉住，后面的消息处理流程才会显得像 runtime，而不是一段偶然拼起来的回调。

```rust

impl<T: ToolExecutor> AgentRuntime<T> {
    async fn handle_message(&mut self, user_text: &str) -> anyhow::Result<String> {
        self.session_messages.push(format!("user: {user_text}"));
        let tool_output = self.tool_executor.run("pwd").await?;
        let reply = format!("tool says: {tool_output}");
        self.session_messages.push(format!("assistant: {reply}"));
        Ok(reply)
    }
}
```

Python 版本保留同样的协作关系，但用 `Protocol` 约束依赖、用 `@dataclass` 承载状态。这样即使语言更动态，示例也不会退化成一堆彼此隐式耦合的全局函数。

```python
from dataclasses import dataclass, field
from typing import Protocol


class ToolExecutor(Protocol):
    async def run(self, command: str) -> str: ...


class EchoBot:
    async def reply(self, user_text: str) -> str:
        return f"echo: {user_text}"


@dataclass
class AgentRuntime:
    tool_executor: ToolExecutor
    session_messages: list[str] = field(default_factory=list)
```

这里也先把状态容器单独放出来，再展示处理入口。这样读者会先看到对象形状，再看到一次 turn 怎样推进，版面和理解负担都会更稳。

```python

    async def handle_message(self, user_text: str) -> str:
        self.session_messages.append(f"user: {user_text}")
        tool_output = await self.tool_executor.run("pwd")
        reply = f"tool says: {tool_output}"
        self.session_messages.append(f"assistant: {reply}")
        return reply
```

### 决策一：先统一内核，再扩展渠道

优点是复用强、维护成本低、行为一致。代价是某些渠道特性不能原样暴露给核心，必须经过抽象层。

### 决策二：优先 SQLite 本地状态，而不是外部服务依赖

优点是部署简单、单机体验好、可审计。代价是横向扩展不是默认路径，需要后续演进。

### 决策三：把工具系统做成一等公民

优点是系统具备真正的执行力。代价是要同时面对权限、安全、超时和副作用问题。

### 决策四：把记忆做成双层

文件记忆适合可读、可编辑、可解释；结构化记忆适合检索、生命周期管理和自动提取。代价是实现复杂度更高，但这是值得的，因为纯文件和纯向量都不够。

## 容易走错的地方

### 失败模式 1：把 MicroClaw 当成“套壳聊天 UI”

如果只把它当成一个聊天机器人，很容易低估它在状态管理、工具执行和会话恢复上的设计重点。这样会导致错误的扩展方式，比如把逻辑散落到各个渠道适配器里。

### 失败模式 2：只关注模型，不关注 runtime

模型能力当然重要，但在长期运行系统里，真正决定稳定性的往往是：

- 会话如何恢复
- 任务如何中断
- memory 如何写入
- 工具是否可控

如果只讨论模型，不讨论 runtime，系统很难落地。

### 失败模式 3：过早追求“大而全”

分布式控制平面、节点编排、复杂权限网格都很有吸引力，但如果基本 Agent Loop 还不稳定，这些都会变成额外复杂度。MicroClaw 当前的选择是先把本地 runtime 做厚，再逐步开放桥接层，这是更现实的路径。

## 读到这里，你应该能回答

- 你是否已经把 MicroClaw 看作 runtime，而不是聊天机器人？
- 你是否明确区分了核心内核与渠道适配的职责？
- 你是否理解工具、状态、记忆和调度在这里是一体化设计？
- 你是否能说清楚 MicroClaw 相比其他项目更偏内聚 runtime，而不是 control plane？

## 证据来源（v0.1.16 / 95491b7）

- 源码基线：<https://github.com/microclaw/microclaw/tree/95491b787a61a71f43aeb6556c695a3bd1c006ce>
- 核心源码路径：`src/agent_engine.rs`、`src/llm.rs`、`src/tools/mod.rs`、`crates/microclaw-storage/src/db.rs`、`src/scheduler.rs`、`src/web.rs`
- 关键配置项：`src/config.rs` 中与会话恢复、工具超时、Web 控制面和高风险工具确认相关的默认值
- 测试 / 运行文档路径：`README.md`、`DEVELOP.md`、`TEST.md`

## 小结

MicroClaw 之所以值得单独讨论，不是因为它“支持很多平台”，而是因为它试图回答一个更难的问题：如何把 Agent 做成一个真正可运行、可恢复、可维护的系统。

本章建立了全书的判断标准。后面每一章都围绕这个问题继续展开：一个多渠道 Agent Runtime，究竟应该由哪些结构组成，怎样保持一致性，又怎样在真实环境里长期工作。

下一章，我们不再停留在定位层面，而是直接进入系统全景：从一次请求如何流动开始，拆开 MicroClaw 的分层、边界和关键模块。

## 图表清单

如果你打算把本章整理成演示、课程或配图版文章，下面三张图最值得保留。

- 图 1-1：传统聊天机器人与执行型 Agent Runtime 的能力差异
- 图 1-2：MicroClaw 的问题域：渠道、工具、状态、记忆、调度
- 图 1-3：MicroClaw 与典型同类项目的定位对比
