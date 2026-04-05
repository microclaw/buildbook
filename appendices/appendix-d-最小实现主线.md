# Appendix D 最小实现主线

## 目标

前面的章节已经把 MicroClaw 的主链路、状态模型、工具治理和生产约束拆开讲清楚了，但很多读者读完仍会卡在一个很具体的问题上：如果我不想先读完整个源码仓库，能不能先把一条最小但连续的实现主线跑起来？

这个附录就回答这个问题。它不试图复刻完整的 MicroClaw，而是抽出 5 个最小但不可再省的构件：

1. 运行时装配对象
2. 可恢复的会话状态
3. 能发起工具调用的统一循环
4. 并行工具执行的 wave 调度
5. 可落盘、可再次恢复的 session store

只要这 5 件事串起来，你就已经拥有了一个真正意义上的最小 Agent Runtime，而不再只是"调一次模型然后打印结果"的脚本。v0.1.38 把并行工具执行从外挂脚本提升为 runtime 内建调度模型，所以最小实现也必须包含这一层。

## 先明确什么叫"最小"

这里的"最小"不是功能最少，而是责任边界最少。下面这些东西必须保留：

- `AppState` 或等价对象：负责装配模型、工具和存储
- `TurnContext`：负责承载某个 chat 的当前消息状态
- `SessionStore`：负责把会话加载和保存下来
- `ModelClient`：负责返回"结束回答"或"请求工具"（可以一次返回多个工具调用）
- `ToolRegistry`：负责执行被允许的工具，并为每个工具标注 concurrency class
- `ToolExecutor`：负责按 concurrency class 把多个工具调用分成 wave 并行执行
- `AgentRuntime::handle_message`：负责把一次 turn 从恢复推进到结束

如果缺少其中任何一项，系统都会退化：

- 没有装配层，依赖会散落到入口脚本。
- 没有 session store，进程重启就无法恢复上下文。
- 没有统一循环，工具调用只能靠外层临时拼接。
- 没有明确模型返回语义，tool loop 很快会失控。
- 没有并行调度，多工具调用只能串行执行，浪费了 LLM 返回多 tool_use 的结构性信息。

## 第一步：先把运行时边界和 crate 结构钉住

最小实现的第一个目标，不是写模型调用，而是先钉住"运行时手里握着什么"。对应 MicroClaw v0.1.38 的 8 workspace crate 架构，最小骨架只需要 3 层：

- 一个模型客户端（对应 `src/llm.rs`）
- 一个带 concurrency class 的工具注册表（对应 `crates/microclaw-tools/src/runtime.rs` + `src/tools/mod.rs`）
- 一个 session store（对应 `crates/microclaw-storage/src/db.rs`）

只有这三个依赖先成为显式对象，后面的恢复、循环、并行执行和保存才能写成稳定主链路，而不是一堆临时函数互相传参。

```rust
struct AppState<M, S> {
    model: M,
    tools: ToolRegistry,
    sessions: S,
}
```

这就是本附录的第一原则：先把边界缩成一个对象，再去考虑一次 turn 如何推进。

## 第二步：把"聊天容器"和"可恢复状态"拆开

最小实现里仍然要保留 Chat 和 Session 的分层意识。为了压缩例子，我们只保留 `chat_id`，但运行时真正恢复的是 `TurnContext`，不是一个裸字符串。

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
struct TurnContext {
    chat_id: i64,
    messages: Vec<Message>,
}
```

这样做的价值有两个：

1. 运行时知道自己恢复的是哪一个 chat。
2. 工具结果、助手输出和用户输入都能被统一持久化。

这已经比"每次都重新拼 prompt"强很多，因为恢复对象开始具备真正的状态含义。

## 第三步：让模型返回控制语义，支持多工具调用

一个最小 Agent Runtime 真正和普通聊天脚本拉开差距的地方，是模型不再只返回字符串，而是返回受控语义。v0.1.38 的 LLM 适配层必须能一次返回多个工具调用——这是并行执行的前提。最少要区分两种结果：

- `EndTurn(text)`：这一轮可以结束
- `CallTools(vec)`：这一轮要执行一个或多个工具

```rust
#[derive(Debug, Clone)]
struct ToolCall {
    name: String,
    input: String,
}

enum ModelDecision {
    EndTurn(String),
    CallTools(Vec<ToolCall>),
}
```

注意这里从 v0.1.16 的 `CallTool`（单数）变成了 `CallTools(Vec<ToolCall>)`。这不是 API 风格的偏好，而是反映了 MicroClaw v0.1.38 的一个核心设计决策：LLM 可以在一次响应中请求多个工具调用，runtime 负责按 concurrency class 决定哪些并行、哪些串行。

## 第四步：引入 concurrency class 和 wave 分区

这是 v0.1.38 相对于旧版本的关键新增。每个工具都有一个 concurrency class，决定它能否被并行执行：

```rust
#[derive(Debug, Clone, Copy, PartialEq)]
enum ConcurrencyClass {
    ReadOnly,    // 可与其他 ReadOnly 工具并行
    SideEffect,  // 必须串行（相对于其他 SideEffect/Exclusive）
    Exclusive,   // 必须独占整个 wave
}

fn tool_concurrency_class(name: &str) -> ConcurrencyClass {
    match name {
        "pwd" | "read_file" | "glob" => ConcurrencyClass::ReadOnly,
        "write_file" => ConcurrencyClass::SideEffect,
        "bash" => ConcurrencyClass::Exclusive,
        _ => ConcurrencyClass::SideEffect,
    }
}
```

Wave 分区规则直接对应 MicroClaw 源码中 `tool_executor.rs` 的 `partition_into_waves`：

1. 所有 ReadOnly 工具 → 单个 wave，全部并行
2. SideEffect 工具 → 每个工具独占一个 wave，按顺序执行
3. Exclusive 工具 → 每个工具独占一个 wave

```rust
fn partition_into_waves(calls: &[ToolCall]) -> Vec<Vec<usize>> {
    if calls.len() <= 1 {
        return if calls.is_empty() { vec![] } else { vec![vec![0]] };
    }

    let classes: Vec<ConcurrencyClass> = calls
        .iter()
        .map(|c| tool_concurrency_class(&c.name))
        .collect();

    let mut readonly = Vec::new();
    let mut sideeffect = Vec::new();
    let mut exclusive = Vec::new();

    for (i, class) in classes.iter().enumerate() {
        match class {
            ConcurrencyClass::ReadOnly => readonly.push(i),
            ConcurrencyClass::SideEffect => sideeffect.push(i),
            ConcurrencyClass::Exclusive => exclusive.push(i),
        }
    }

    let mut waves = Vec::new();
    if !readonly.is_empty() {
        waves.push(readonly);
    }
    for idx in sideeffect {
        waves.push(vec![idx]);
    }
    for idx in exclusive {
        waves.push(vec![idx]);
    }
    waves
}
```

## 第五步：把最小的可恢复、可并行 tool loop 跑起来

下面这份示例刻意保持单文件可运行。它用一个基于 JSON 文件的 session store 来模拟 SQLite 持久化，用一个极小的 `DemoModel` 来模拟"要不要调用工具"的决策（包括一次返回多个工具调用的场景），用 `current_dir()` 和 `read_to_string` 实现两个零依赖工具。

它不是 MicroClaw 的缩写版，而是一个能帮助你真正看懂 `runtime -> session -> model -> wave partition -> parallel execute -> persist` 这条主链路的最小骨架。

### `Cargo.toml`

```toml
[package]
name = "mini-runtime"
version = "0.1.0"
edition = "2021"

[dependencies]
anyhow = "1"
async-trait = "0.1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["macros", "rt-multi-thread", "fs"] }
futures = "0.3"
```

### `src/main.rs`

```rust
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

// ── Messages ──

#[derive(Debug, Clone, Serialize, Deserialize)]
enum Message {
    User(String),
    Assistant(String),
    ToolResult { name: String, content: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TurnContext {
    chat_id: i64,
    messages: Vec<Message>,
}

impl TurnContext {
    fn new(chat_id: i64) -> Self {
        Self { chat_id, messages: Vec::new() }
    }
}

// ── Model Decision (supports multiple tool calls) ──

#[derive(Debug, Clone)]
struct ToolCall {
    name: String,
    input: String,
}

#[derive(Debug, Clone)]
enum ModelDecision {
    EndTurn(String),
    CallTools(Vec<ToolCall>),
}

#[async_trait]
trait ModelClient {
    async fn next(&self, messages: &[Message]) -> Result<ModelDecision>;
}

struct DemoModel;

#[async_trait]
impl ModelClient for DemoModel {
    async fn next(&self, messages: &[Message]) -> Result<ModelDecision> {
        match messages.last() {
            Some(Message::User(text)) if text.contains("both") => {
                // Simulate LLM requesting two read-only tools in parallel
                Ok(ModelDecision::CallTools(vec![
                    ToolCall { name: "pwd".to_string(), input: String::new() },
                    ToolCall { name: "read_file".to_string(), input: "Cargo.toml".to_string() },
                ]))
            }
            Some(Message::User(text)) if text.contains("pwd") => {
                Ok(ModelDecision::CallTools(vec![
                    ToolCall { name: "pwd".to_string(), input: String::new() },
                ]))
            }
            Some(Message::ToolResult { .. }) => {
                // After tool results, produce final answer
                let tool_outputs: Vec<String> = messages.iter().rev()
                    .take_while(|m| matches!(m, Message::ToolResult { .. }))
                    .filter_map(|m| match m {
                        Message::ToolResult { name, content } =>
                            Some(format!("{name}: {content}")),
                        _ => None,
                    })
                    .collect();
                Ok(ModelDecision::EndTurn(
                    format!("Results:\n{}", tool_outputs.join("\n"))
                ))
            }
            Some(Message::User(text)) => {
                Ok(ModelDecision::EndTurn(format!("echo: {text}")))
            }
            _ => Ok(ModelDecision::EndTurn("ready".to_string())),
        }
    }
}

// ── Concurrency Classes ──

#[derive(Debug, Clone, Copy, PartialEq)]
enum ConcurrencyClass {
    ReadOnly,
    SideEffect,
    Exclusive,
}

fn tool_concurrency_class(name: &str) -> ConcurrencyClass {
    match name {
        "pwd" | "read_file" => ConcurrencyClass::ReadOnly,
        "write_file" => ConcurrencyClass::SideEffect,
        "bash" => ConcurrencyClass::Exclusive,
        _ => ConcurrencyClass::SideEffect,
    }
}

fn partition_into_waves(calls: &[ToolCall]) -> Vec<Vec<usize>> {
    if calls.len() <= 1 {
        return if calls.is_empty() { vec![] } else { vec![vec![0]] };
    }
    let classes: Vec<ConcurrencyClass> = calls
        .iter()
        .map(|c| tool_concurrency_class(&c.name))
        .collect();

    let mut readonly = Vec::new();
    let mut sideeffect = Vec::new();
    let mut exclusive = Vec::new();

    for (i, class) in classes.iter().enumerate() {
        match class {
            ConcurrencyClass::ReadOnly => readonly.push(i),
            ConcurrencyClass::SideEffect => sideeffect.push(i),
            ConcurrencyClass::Exclusive => exclusive.push(i),
        }
    }

    let mut waves = Vec::new();
    if !readonly.is_empty() { waves.push(readonly); }
    for idx in sideeffect { waves.push(vec![idx]); }
    for idx in exclusive { waves.push(vec![idx]); }
    waves
}

// ── Tool Registry ──

struct ToolRegistry;

impl ToolRegistry {
    async fn execute(&self, name: &str, input: &str) -> Result<String> {
        match name {
            "pwd" => Ok(std::env::current_dir()?.display().to_string()),
            "read_file" => {
                let content = tokio::fs::read_to_string(input.trim()).await
                    .unwrap_or_else(|e| format!("error: {e}"));
                // Truncate for demo
                Ok(content.chars().take(200).collect())
            }
            other => Err(anyhow!("unknown tool: {other}")),
        }
    }

    /// Execute a batch of tool calls with wave-based parallelism.
    async fn execute_batch(&self, calls: &[ToolCall]) -> Vec<(String, String)> {
        let waves = partition_into_waves(calls);
        let mut results = vec![String::new(); calls.len()];

        for wave in &waves {
            if wave.len() == 1 {
                // Single tool — no spawn overhead
                let idx = wave[0];
                let output = self.execute(&calls[idx].name, &calls[idx].input)
                    .await
                    .unwrap_or_else(|e| format!("error: {e}"));
                results[idx] = output;
            } else {
                // Multiple tools — run in parallel
                let handles: Vec<_> = wave.iter().map(|&idx| {
                    let name = calls[idx].name.clone();
                    let input = calls[idx].input.clone();
                    tokio::spawn(async move {
                        let registry = ToolRegistry;
                        let output = registry.execute(&name, &input)
                            .await
                            .unwrap_or_else(|e| format!("error: {e}"));
                        (idx, output)
                    })
                }).collect();

                for handle in handles {
                    if let Ok((idx, output)) = handle.await {
                        results[idx] = output;
                    }
                }
            }
        }

        calls.iter().enumerate()
            .map(|(i, c)| (c.name.clone(), results[i].clone()))
            .collect()
    }
}

// ── Session Store ──

#[async_trait]
trait SessionStore {
    async fn load(&self, chat_id: i64) -> Result<Option<TurnContext>>;
    async fn save(&self, ctx: &TurnContext) -> Result<()>;
}

struct FileSessionStore {
    root: PathBuf,
}

impl FileSessionStore {
    fn new(root: impl AsRef<Path>) -> Self {
        Self { root: root.as_ref().to_path_buf() }
    }
    fn path_for(&self, chat_id: i64) -> PathBuf {
        self.root.join(format!("chat-{chat_id}.json"))
    }
}

#[async_trait]
impl SessionStore for FileSessionStore {
    async fn load(&self, chat_id: i64) -> Result<Option<TurnContext>> {
        let path = self.path_for(chat_id);
        if !path.exists() { return Ok(None); }
        let bytes = tokio::fs::read(path).await?;
        let ctx = serde_json::from_slice(&bytes)?;
        Ok(Some(ctx))
    }
    async fn save(&self, ctx: &TurnContext) -> Result<()> {
        tokio::fs::create_dir_all(&self.root).await?;
        let bytes = serde_json::to_vec_pretty(ctx)?;
        tokio::fs::write(self.path_for(ctx.chat_id), bytes).await?;
        Ok(())
    }
}

// ── AppState + handle_message ──

struct AppState<M, S> {
    model: M,
    tools: ToolRegistry,
    sessions: S,
}

impl<M, S> AppState<M, S>
where
    M: ModelClient + Send + Sync,
    S: SessionStore + Send + Sync,
{
    async fn handle_message(&self, chat_id: i64, text: &str) -> Result<String> {
        let mut ctx = self.sessions.load(chat_id).await?
            .unwrap_or_else(|| TurnContext::new(chat_id));

        ctx.messages.push(Message::User(text.to_string()));

        for iteration in 0..8 {
            match self.model.next(&ctx.messages).await? {
                ModelDecision::EndTurn(text) => {
                    ctx.messages.push(Message::Assistant(text.clone()));
                    self.sessions.save(&ctx).await?;
                    return Ok(text);
                }
                ModelDecision::CallTools(calls) => {
                    let results = self.tools.execute_batch(&calls).await;
                    let wave_count = partition_into_waves(&calls).len();
                    eprintln!(
                        "[iter {iteration}] {} tool(s) in {} wave(s)",
                        calls.len(), wave_count
                    );
                    for (name, output) in results {
                        ctx.messages.push(Message::ToolResult {
                            name,
                            content: output,
                        });
                    }
                }
            }
        }

        Err(anyhow!("too many tool iterations"))
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let chat_id = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "1".to_string())
        .parse::<i64>()?;
    let text = std::env::args()
        .nth(2)
        .unwrap_or_else(|| "hello runtime".to_string());

    let state = AppState {
        model: DemoModel,
        tools: ToolRegistry,
        sessions: FileSessionStore::new(".demo-sessions"),
    };

    let reply = state.handle_message(chat_id, &text).await?;
    println!("{reply}");
    Ok(())
}
```

## 第六步：按运行顺序理解这段代码

这份示例真正值得看的不是语法，而是运行顺序：

1. `main` 组装 `AppState`
2. `handle_message` 先尝试从 `.demo-sessions/chat-{id}.json` 恢复上下文
3. 当前用户输入被追加到 `messages`
4. `DemoModel` 根据最新消息决定结束还是调用工具——注意它可以一次返回多个 `ToolCall`
5. 多个 `ToolCall` 被 `partition_into_waves` 按 concurrency class 分波
6. ReadOnly 工具（如 `pwd` 和 `read_file`）在同一 wave 中并行执行
7. 所有工具结果被回灌到消息历史
8. 模型再次读取消息历史，生成最终回答
9. 整个 `TurnContext` 被重新写回 session store

这就是一个最小但完整的可恢复、可并行的 agent loop。

## 第七步：怎样验证它真的"可恢复"且"可并行"

在一个空目录里运行：

```bash
cargo run -- 1 "hello"
cargo run -- 1 "tell me both"
cat .demo-sessions/chat-1.json
```

你会看到三类结果：

- 终端里能得到最终回复
- stderr 显示 `2 tool(s) in 1 wave(s)`——两个 ReadOnly 工具被归入同一 wave 并行执行
- 磁盘上能看到连续积累的会话状态，包含多条 `ToolResult`

这就是"恢复能力"和"并行调度"真正成立的最低标准。不是口头上说支持 session 和并行，而是你能指出"状态存在哪里、工具如何被分波、下一次如何读回来"。

## 把它继续长成 MicroClaw 时，下一步该加什么

如果你已经能跑通上面的最小骨架，继续往 MicroClaw 靠近时，建议按下面顺序演进：

1. 把 `FileSessionStore` 换成 SQLite 存储——对应 `crates/microclaw-storage/src/db.rs`。
2. 把 `DemoModel` 换成真实 provider 适配层——对应 `src/llm.rs`，支持 Anthropic 和 OpenAI-compatible。
3. 把 `String` 消息换成带 role、tool use、tool result 的结构化消息——对应 `microclaw-core/src/llm_types.rs`。
4. 给 `ToolRegistry` 加入 `Tool` trait、风险分级和 sandbox 路由——对应 `crates/microclaw-tools/src/runtime.rs`。
5. 加入 Hooks 策略拦截（before-tool / after-tool）——对应 `src/hooks.rs`。
6. 加入显式记忆装载、fast-path 和 Reflector 自动提取——对应 `src/memory_service.rs` + `src/memory_backend.rs`。
7. 加入 run control（per-chat 取消信号）——对应 `src/run_control.rs`。
8. 加入 ChatTurnQueue（per-chat turn lock + pending message drain）——对应 `src/chat_turn_queue.rs`。
9. 加入超时、审批和重复工具指纹保护——对应 `src/tool_executor.rs` 中的 guardrails。
10. 接入渠道适配器——对应 `crates/microclaw-channels/`。
11. 接入 Web 控制面和调度器——对应 `src/web.rs` + `src/scheduler.rs`。
12. 最后接入 ACP/A2A 互操作和 Subagent 编排——对应 `src/acp.rs` + `src/a2a.rs` + `src/tools/subagents.rs`。

这个顺序很重要。先把主链路做稳（步骤 1-4），再加治理层（步骤 5-9），再扩展入口（步骤 10-11），最后加互操作（步骤 12），复杂度才是可控的。

## 这条最小实现主线想让你真正记住什么

从最小 runtime 走到可恢复、可并行的 agent loop，本质上跨了两个关键门槛：

1. 系统开始显式持有状态，并且能把模型输出当成控制语义来消费，而不是只当成文本来打印。
2. 系统开始把多工具调用视为可调度的 batch，按 concurrency class 分波执行，而不是只能逐个串行。

第一个门槛让你拥有了"runtime"。第二个门槛让你拥有了"性能模型"。

一旦跨过这两个门槛，后面的记忆、调度、审批、Hooks、观测、多渠道、Subagent 编排和 ACP/A2A 互操作，其实都只是在这条主链路上继续加规则，而不是另起炉灶。

如果你读完整本书后只想先自己动手做一件事，那就先把这条最小实现主线跑通。它不会替代完整的 MicroClaw，但会让你第一次真正拥有"runtime 已经成形"的手感。

## 证据来源（v0.1.38 / dd9e629）

- 源码基线：<https://github.com/microclaw/microclaw/tree/dd9e62969b0270eb100d07ed7d7656aa9569de26>
- 核心源码路径：`src/runtime.rs`、`src/agent_engine.rs`、`src/tool_executor.rs`、`crates/microclaw-storage/src/db.rs`、`src/llm.rs`、`crates/microclaw-tools/src/runtime.rs`
- 关键配置项：`src/config.rs` 中与 `max_tool_iterations`、`max_session_messages`、`compact_keep_recent`、`default_tool_timeout_secs`、`parallel_tool_max_concurrency`、`tool_concurrency_overrides`、`chat_turn_queue_max_pending` 相关的默认值
- Crate 结构：`Cargo.toml` workspace members 列出 8 个 crate
- 测试 / 运行文档路径：`README.md`、`DEVELOP.md`、`TEST.md`
