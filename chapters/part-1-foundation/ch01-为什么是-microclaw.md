# Chapter 1 为什么是 MicroClaw

## 你的第一个 Agent 为什么会卡在第二周？

很多团队第一次做 Agent 系统，起点是"把大模型接进聊天窗口"。这个起点没有错，但它很快暴露一系列结构性问题：真正有价值的任务不只是文本问答，而是一个持续运行、可调用工具、可跨渠道、可恢复、可取消的执行过程。

MicroClaw 到了 v0.1.38，已经从早期实验演进为工程化 runtime：8 个 workspace crate、44 个内置工具、16 个渠道适配器、session-native subagent 体系、A2A 跨实例协议、ACP headless 控制协议。理解它的价值，不是看它"支持了多少功能"，而是看它为什么要把这些功能收进同一个进程。

这一章读完后，你应该能回答三个问题：

1. 为什么传统聊天机器人范式不足以支撑复杂任务。
2. MicroClaw 想解决的核心问题是什么，以及它在 v0.1.38 的覆盖面。
3. 它与同类项目相比，选择了怎样的工程边界和权衡。

## "一问一答"为什么撑不住复杂任务？

传统聊天机器人的关键路径很短：

1. 收到一条消息。
2. 组装 prompt。
3. 调一次模型。
4. 把回复发出去。

这个模型对 FAQ、客服和轻量助手很有效，但一旦任务变复杂，问题就接连浮现。

第一个问题是工具执行。生产任务需要读写文件、执行 shell 命令、抓取网页、查数据库、调度定时任务、委托子任务给 subagent。这些工具往往需要并行执行——模型一次返回多个 tool_use 块时，系统必须判断哪些可以并发、哪些必须串行、哪些必须独占。这远不是"顺序调一下函数"那么简单。

第二个问题是会话恢复。用户不会只在一个短会话里工作。一个任务可能跨越几小时、几天，甚至在 Telegram、Discord、Web 之间切换。系统必须知道这是谁的任务、当前会话状态是什么、上次停在了哪里、需要恢复哪些上下文。

第三个问题是长期记忆。用户偏好、环境细节、项目背景、常用命令，如果每次都重新输入，系统就没有实际生产力。MicroClaw 对此给出了双层设计：文件记忆（AGENTS.md / SOUL.md）负责可读可编辑的长期偏好，结构化记忆（memories 表）负责可检索可归档的机器事实。这种分层后面章节会展开，但它的存在本身就说明单层记忆不够用。

第四个问题是运维与成本。Agent 一旦具备多轮工具调用能力，就会带来新的工程风险：无限工具循环、成本失控、任务卡死、输出不可追踪。v0.1.38 在这一层投入很大：`run_control` 支持取消，`ChatTurnQueue` 做 per-chat turn 序列化，Hooks 在 BeforeLLMCall/BeforeToolCall/AfterToolCall 三个点位拦截，OTLP 指标导出让系统行为可观测。

第五个问题是多实例协作与 headless 控制。Agent 可以通过 ACP（Agent Client Protocol）被 IDE 或自动化脚本驱动，也可以通过 A2A（Agent-to-Agent）协议与其他 MicroClaw 实例通信。此时它的身份不再是"聊天机器人"，而是可编排的执行单元。

因此，一个可用的 Agent 系统必须把"执行、恢复、记忆、观测、成本控制、并发编排、跨实例协作"放进同一套 runtime 设计里。MicroClaw 的定位，正是在这里。

### 请求对象为什么不能只包含一段文本？

如果系统只做"一问一答"，输入里只有 `text` 也许够用。但系统一旦要恢复会话、区分渠道、决定是否允许工具、追踪 run control 状态、注入 subagent 上下文，请求对象就必须显式携带更多运行时事实。

Rust 版本把"文本请求"和"运行时请求"区分成两个 `struct`。v0.1.38 的实际请求上下文（`AgentRequestContext`）还包括 `caller_channel` 和 `chat_type`，因为 runtime 需要根据渠道来源决定行为策略。

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
    chat_type: str
    session_key: str
    text: str
    allow_tools: bool
```

## MicroClaw 把什么问题收进了同一个进程？

MicroClaw 不是"再做一个聊天 UI"，也不是"只做一个模型接入层"。它要解决的工程问题更具体：如何把一个多渠道智能体，做成可持续运行、可维护、可扩展的统一内核。

从 v0.1.38 的源码结构看，这个目标非常明确。系统核心是 `agent_engine.rs` 里的统一 Agent Loop，负责并行工具调度和 subagent 编排。`tool_executor.rs` 实现了 wave-based 并行工具执行，区分 ReadOnly/SideEffect/Exclusive 三种并发类。`llm.rs` 提供统一的 provider 抽象。`channels/` 目录下的 16 个渠道适配器——从 Telegram 到 ACP——只是消息进出的边缘层。

在状态和治理维度上，`microclaw-storage` crate 管理 19 版 schema，涵盖会话、消息、记忆、调度任务、子代理运行、审计日志等完整运行时状态。`hooks.rs` 在 LLM 调用和工具执行前后提供三个策略拦截点。`run_control.rs` 保障可取消性，`chat_turn_queue.rs` 保障 per-chat 并发安全。`web.rs` 挂出嵌入式 React+Vite 控制面。`acp.rs` 和 `a2a.rs` 让 MicroClaw 既能被外部程序驱动，又能与其他实例互通。`gateway.rs` 把跨平台 service 管理标准化，`doctor.rs` 做环境诊断，`setup.rs`（11,000+ 行）是交互式配置向导。

把这些放在一起看，MicroClaw 不是围绕"某个渠道"组织代码，而是围绕"运行时内核"组织代码。渠道只是入口，核心循环和状态模型才是主体。

这个选择有两个直接好处。

第一，功能不会被渠道绑死。只要一个能力被实现为内核特性，它就可以复用到 Telegram、Discord、Slack、Feishu、Web、ACP、A2A 等多个入口，而不必为每个平台各写一套。

第二，系统更容易演进。v0.1.16 到 v0.1.38 之间新增了并行工具执行、subagent 体系、run control、hooks、A2A、ACP、gateway、doctor 等大量能力，但这些都挂在统一 runtime 上，渠道适配层几乎不需要感知这些变化。

## MicroClaw 的五个核心设计目标

### 1. 多渠道接入，内核不分裂

MicroClaw 的第一原则不是"支持更多平台"，而是"支持多个平台时不分裂核心逻辑"。共享 Agent Loop 放在 `src/agent_engine.rs`，16 个渠道适配器拆成边缘模块。v0.1.38 的渠道数量足以暴露一个事实：如果每个渠道都有自己的 Agent 行为分支，系统早就无法维护了。

### 2. 44 个内置工具，支持 wave-based 并行执行

MicroClaw 默认不只返回文本。它内置 44 个工具，覆盖 bash、文件操作、glob、grep、web 搜索、web 抓取、调度、memory、subagent、A2A、浏览器、时间计算、todo、技能同步、聊天导出等类别。

更关键的是，v0.1.38 引入了 wave-based parallel tool execution（`src/tool_executor.rs`）。当模型一次返回多个 tool_use 块时，系统不是简单地串行执行，而是：

- 按 concurrency class 分类（ReadOnly 可并行、SideEffect 需串行、Exclusive 必须独占）
- 将工具调用分成多个 wave
- 同一 wave 内的 ReadOnly 工具通过 `tokio::JoinSet` 并行执行
- wave 之间严格串行

这个设计直接影响了系统的吞吐量和响应速度。一次请求如果涉及 5 个 `read_file` 和 1 个 `bash`，系统会把 5 个读操作并行完成，再单独执行 bash。

### 3. 状态可恢复，运行可取消

工程系统不能假设每次调用都是全新开始。MicroClaw 使用 SQLite 保存聊天、消息、session、task、memory、subagent run 等状态。v0.1.38 的 schema 已经演进到第 19 版。

同时，v0.1.38 加入了完整的 run control 机制。`run_control.rs` 为每个 (channel, chat_id) 维护活跃 run 列表。每个 run 持有一个 `AtomicBool` 取消标记和一个 `Notify` 通知器。当用户发送 `/stop` 或通过 Web UI 点击 abort 时，系统可以干净地取消当前 run，而不是杀进程或等超时。

`ChatTurnQueue` 进一步确保同一个 chat 同一时刻只有一个 agent run 在执行。如果新消息在 run 进行中到达，它会被排队并在 run 完成后合并处理。这种设计避免了并发 run 之间的状态竞争。

### 4. 成本和风险可控

Agent 系统最大的幻觉之一是"看上去很聪明，所以应该可以自动跑很久"。现实恰好相反：越是允许多轮推理和工具调用，越要控制预算、超时、权限和副作用。

v0.1.38 在这一层的工具箱比 v0.1.16 丰富很多。Hooks 在 BeforeLLMCall、BeforeToolCall、AfterToolCall 三个点位提供拦截能力，每个 hook 可以返回 allow/block/modify，让外部脚本在工具执行前审查或修改输入。工具风险分为 Low/Medium/High 三级，高风险工具默认需要用户审批确认。工具超时可按工具名单独配置。Subagent 有独立的 token 预算和嵌套深度限制。OTLP 指标、traces、logs 三合一导出让系统行为可追踪，审计日志记录关键操作的完整轨迹。

### 5. 可编排、可互联

v0.1.38 的一个显著变化是，MicroClaw 不再只是一个"人对机器聊天"的系统。

ACP（Agent Client Protocol）让它可以作为 headless runtime 被 IDE 插件或自动化脚本驱动。`src/acp.rs` 实现了完整的 stdio 协议，包括 session 创建/加载、prompt 发送、流式响应、取消等操作。

A2A（Agent-to-Agent）让多个 MicroClaw 实例之间可以互发消息。`src/a2a.rs` 定义了 agent card 发现和消息交换协议，`src/tools/a2a.rs` 提供了 `a2a_list_peers` 和 `a2a_send` 工具，让 Agent 自己就能与其他实例协作。

这两个协议把 MicroClaw 从"一个聊天入口的后端"推向了"一个可编排的 Agent 节点"。

## MicroClaw 在同类项目中处于什么位置？

和 OpenClaw 这类更强调 Gateway / Control Plane 的系统相比，MicroClaw 更偏向"单机优先、运行时内聚"。它已经有 Web API、SSE、WebSocket bridge、A2A、ACP、Hooks、Gateway service，但这些能力仍然围绕一个本地 runtime 展开，而不是先构建分布式控制平面。

和更轻量的个人代理项目相比，MicroClaw 又明显更重工程性。它的 44 个内置工具、session-native subagent 生命周期、wave-based 并行执行、per-chat turn serialization、11,000 行 setup wizard、跨平台 doctor 诊断，都说明它不是一个周末项目。

和框架类产品（LangChain、CrewAI 等）相比，MicroClaw 是一个完整的 runtime binary，而不是一个让你组装自己 Agent 的库。它自己就是 Agent，你通过配置和 hooks 来调整行为，而不是通过 import 它来写自己的循环。

所以它的适用场景非常明确：你想让 Agent 在真实聊天环境里长期运行，跨多个渠道保持一致行为，支持工具执行、记忆积累、任务调度和可观测性，而不是从零搭建一套这些能力。

## 关键权衡

MicroClaw 背后几个最核心的设计取舍需要摊开来看。每一个选择都不是免费的——它既带来收益，也带来约束。后面的章节会逐一深入，这里先建立判断框架。

## 示例代码：状态和工具为什么必须纳入 Runtime？

下面这组代码故意把"聊天 bot"和"执行型 runtime"并排放在一起。真正的差异不在回复文案，而在系统是否显式持有状态、依赖和后续动作。

Rust 版本用 `trait + struct + async fn` 把执行边界写死。工具能力是稳定接口，运行时自己持有会话状态和取消标记，异步方法只出现在真实的执行路径上。这样写能直接体现 MicroClaw 不是"调一次模型"，而是"驱动一段可中断、可恢复的执行过程"。

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
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
}
```

这段先只定义运行时真正持有的边界。相比 v0.1.16 的示例，这里增加了 `cancelled` 标记，对应 v0.1.38 的 run control 机制。

```rust

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

Python 版本保留同样的协作关系，但用 `Protocol` 约束依赖、用 `@dataclass` 承载状态。

```python
from dataclasses import dataclass, field
from typing import Protocol
import threading


class ToolExecutor(Protocol):
    async def run(self, command: str) -> str: ...


class EchoBot:
    async def reply(self, user_text: str) -> str:
        return f"echo: {user_text}"


@dataclass
class AgentRuntime:
    tool_executor: ToolExecutor
    session_messages: list[str] = field(default_factory=list)
    cancelled: threading.Event = field(default_factory=threading.Event)
```

这里也先把状态容器单独放出来，再展示处理入口。

```python

    async def handle_message(self, user_text: str) -> str:
        self.session_messages.append(f"user: {user_text}")
        if self.cancelled.is_set():
            return "Run cancelled."
        tool_output = await self.tool_executor.run("pwd")
        reply = f"tool says: {tool_output}"
        self.session_messages.append(f"assistant: {reply}")
        return reply
```

### 决策一：先统一内核，再扩展渠道

优点是复用强、维护成本低、行为一致。代价是某些渠道特性不能原样暴露给核心，必须经过抽象层。v0.1.38 的 16 个渠道适配器证明了这个决策的可行性——如果没有统一内核，16 个渠道早就分裂成 16 套系统了。

### 决策二：优先 SQLite 本地状态，而不是外部服务依赖

优点是部署简单、单机体验好、可审计。代价是横向扩展不是默认路径。v0.1.38 的 schema 已经到第 19 版，覆盖了 subagent、审计、指标等大量新表，说明这个选择在复杂度增长后仍然可行。

### 决策三：把工具系统做成一等公民，并支持并行执行

优点是系统具备真正的执行力，且通过 wave-based 调度提高了吞吐。代价是要同时面对 concurrency class 设计、权限、安全、超时和副作用问题。

### 决策四：把记忆做成双层，把人格做成文件

文件记忆（AGENTS.md）适合可读、可编辑、可解释；结构化记忆适合检索、生命周期管理和自动提取。v0.1.38 新增的 SOUL.md 更进一步：它不是记忆，而是人格注入。全局 SOUL.md 定义 Agent 的默认性格，per-chat override 可以让同一实例在不同聊天中表现不同。这层设计把"Agent 是什么样的人"和"Agent 记住了什么"分开，避免人格描述和事实记忆混在一起。

### 决策五：支持 ACP 和 A2A，但不强制分布式

ACP 和 A2A 让 MicroClaw 可以被外部程序驱动和跨实例通信，但它们不要求你搭建集群或消息队列。这是一种渐进式的可编排性——你可以只用 Telegram，也可以把它当成 headless 节点来编排。

## 容易走错的地方

### 失败模式 1：把 MicroClaw 当成"套壳聊天 UI"

如果只把它当成一个聊天机器人，很容易低估它在并行工具执行、subagent 编排、run control、hooks 和可观测性上的设计重点。这样会导致错误的扩展方式，比如把逻辑散落到各个渠道适配器里。

### 失败模式 2：只关注模型，不关注 runtime

模型能力当然重要，但在长期运行系统里，真正决定稳定性的往往是：会话如何恢复、任务如何中断（run control）、memory 如何写入、工具是否可控（hooks）、并发 turn 如何序列化（ChatTurnQueue）。如果只讨论模型，不讨论 runtime，系统很难落地。

### 失败模式 3：过早追求"大而全"

分布式控制平面、节点编排、复杂权限网格都很有吸引力，但如果基本 Agent Loop 还不稳定，这些都会变成额外复杂度。MicroClaw 当前的选择是先把本地 runtime 做厚，再通过 ACP/A2A/Gateway 逐步开放桥接层，这是更现实的路径。

### 失败模式 4：忽视 setup 和 doctor 的工程价值

11,000 行的 setup wizard 和 1,700 行的 doctor 不是"锦上添花"。对一个有 16 个渠道、8 个 crate、多个 feature flag 的系统来说，配置正确性本身就是最大的运维挑战。如果不把首次安装体验做好，后面的所有设计都无法被用户真正触达。

## 读到这里，你应该能回答

- 你是否已经把 MicroClaw 看作 runtime，而不是聊天机器人？
- 你是否明确区分了核心内核与渠道适配的职责？
- 你是否理解工具、状态、记忆、调度、hooks、run control、subagent、ACP、A2A 在这里是一体化设计？
- 你是否能说清楚 MicroClaw 相比其他项目更偏内聚 runtime，而不是 control plane？
- 你是否理解 wave-based parallel tool execution 和 per-chat turn serialization 的意义？

## 证据来源（v0.1.38）

- 版本与 crate 结构：`Cargo.toml`（workspace members, version = "0.1.38", features）
- 核心源码路径：`src/agent_engine.rs`、`src/tool_executor.rs`、`src/llm.rs`、`src/run_control.rs`、`src/chat_turn_queue.rs`、`src/hooks.rs`、`src/acp.rs`、`src/a2a.rs`、`src/gateway.rs`、`src/doctor.rs`、`src/setup.rs`
- 工具注册：`src/tools/mod.rs`（44 tools registered in `ToolRegistry::new`）
- 渠道适配器：`src/channels/`（16 个文件）、`src/runtime.rs`（all channel runtime builds）
- 数据库 schema：`crates/microclaw-storage/src/db.rs`（SCHEMA_VERSION_CURRENT = 19）
- 并发类定义：`crates/microclaw-tools/src/runtime.rs`（`ToolConcurrencyClass`、`tool_concurrency_class`）
- SOUL.md：根目录 `SOUL.md`
- Web UI：`web/`（React+Vite）
- 安装方式：`install.sh`、`Dockerfile`、`flake.nix`、`packaging/`
- 关键配置项：`src/config.rs`（`max_tool_iterations=100`、`parallel_tool_max_concurrency=8`、`high_risk_tool_user_confirmation_required=true`、`web_enabled=true`）
- 测试与文档：`tests/config_validation.rs`、`docs/test/blackbox-core-20-cases.md`、`CONTRIBUTING.md`

## 小结

MicroClaw 之所以值得单独讨论，不是因为它"支持很多平台"或"有很多工具"，而是因为它试图回答一个更难的问题：如何把 Agent 做成一个真正可运行、可恢复、可中断、可观测、可编排的系统。

v0.1.38 的规模——8 个 crate、44 个工具、16 个渠道、session-native subagent、ACP、A2A、hooks、gateway、doctor——已经足以说明这不是一个实验项目，而是一个有明确工程边界的 runtime。

本章建立了全书的判断标准。后面每一章都围绕这个问题继续展开：一个多渠道 Agent Runtime，究竟应该由哪些结构组成，怎样保持一致性，又怎样在真实环境里长期工作。

下一章，我们不再停留在定位层面，而是直接进入系统全景：从一次请求如何流动开始，拆开 MicroClaw 的分层、边界和关键模块。

## 图表清单

### 图 1-1：传统聊天机器人与执行型 Agent Runtime 的能力差异

![图 1-1：传统聊天机器人与执行型 Agent Runtime 的能力差异](../assets/figures/fig-01-chatbot-vs-runtime.svg)

这张图把传统聊天机器人的"单轮问答"模式和 MicroClaw 的"多轮执行型 Runtime"模式并排对比，突出并行工具、subagent、run control、ACP/A2A 等新增能力维度。

如需继续扩展配图，本章还可补：

- 图 1-2：MicroClaw v0.1.38 的问题域：渠道、工具、状态、记忆、调度、hooks、subagent、协议
- 图 1-3：MicroClaw 与典型同类项目的定位对比（runtime binary vs. framework vs. control plane）
