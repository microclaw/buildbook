# Appendix D 最小实现主线

## 目标

前面的章节已经把 MicroClaw 的主链路、状态模型、工具治理和生产约束拆开讲清楚了，但很多读者读完仍会卡在一个很具体的问题上：如果我不想先读完整个源码仓库，能不能先把一条最小但连续的实现主线跑起来？

这个附录就回答这个问题。它不试图复刻完整的 MicroClaw，而是抽出 4 个最小但不可再省的构件：

1. 运行时装配对象
2. 可恢复的会话状态
3. 能发起工具调用的统一循环
4. 可落盘、可再次恢复的 session store

只要这 4 件事串起来，你就已经拥有了一个真正意义上的最小 Agent Runtime，而不再只是“调一次模型然后打印结果”的脚本。

## 先明确什么叫“最小”

这里的“最小”不是功能最少，而是责任边界最少。下面这些东西必须保留：

- `AppState` 或等价对象：负责装配模型、工具和存储
- `TurnContext`：负责承载某个 chat 的当前消息状态
- `SessionStore`：负责把会话加载和保存下来
- `ModelClient`：负责返回“结束回答”或“请求工具”
- `ToolRegistry`：负责执行被允许的工具
- `AgentRuntime::handle_message`：负责把一次 turn 从恢复推进到结束

如果缺少其中任何一项，系统都会退化：

- 没有装配层，依赖会散落到入口脚本。
- 没有 session store，进程重启就无法恢复上下文。
- 没有统一循环，工具调用只能靠外层临时拼接。
- 没有明确模型返回语义，tool loop 很快会失控。

## 第一步：先把运行时边界钉住

最小实现的第一个目标，不是写模型调用，而是先钉住“运行时手里握着什么”。最少应当包括：

- 一个模型客户端
- 一个工具注册表
- 一个 session store

只有这三个依赖先成为显式对象，后面的恢复、循环和保存才能写成稳定主链路，而不是一堆临时函数互相传参。

```rust
struct AppState<M, S> {
    model: M,
    tools: ToolRegistry,
    sessions: S,
}
```

这就是本附录的第一原则：先把边界缩成一个对象，再去考虑一次 turn 如何推进。

## 第二步：把“聊天容器”和“可恢复状态”拆开

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

这已经比“每次都重新拼 prompt”强很多，因为恢复对象开始具备真正的状态含义。

## 第三步：让模型返回控制语义，而不是只返回文本

一个最小 Agent Runtime 真正和普通聊天脚本拉开差距的地方，是模型不再只返回字符串，而是返回受控语义。最少要区分两种结果：

- `EndTurn(text)`：这一轮可以结束
- `CallTool(name, input)`：这一轮要执行工具

```rust
enum ModelDecision {
    EndTurn(String),
    CallTool { name: String, input: String },
}
```

只要有了这个枚举，tool loop 就不再是外层脚本的偶然写法，而是运行时的正式状态机。

## 第四步：把最小的可恢复 tool loop 跑起来

下面这份示例刻意保持单文件可运行。它用一个基于 JSON 文件的 session store 来模拟 SQLite 持久化，用一个极小的 `DemoModel` 来模拟“要不要调用工具”的决策，用 `current_dir()` 实现一个零依赖的 `pwd` 工具。

它不是 MicroClaw 的缩写版，而是一个能帮助你真正看懂 `runtime -> session -> model -> tool -> persist` 这条主链路的最小骨架。

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
```

### `src/main.rs`

```rust
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

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
        Self {
            chat_id,
            messages: Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
enum ModelDecision {
    EndTurn(String),
    CallTool { name: String, input: String },
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
            Some(Message::User(text)) if text.contains("pwd") => Ok(ModelDecision::CallTool {
                name: "pwd".to_string(),
                input: String::new(),
            }),
            Some(Message::ToolResult { name, content }) if name == "pwd" => {
                Ok(ModelDecision::EndTurn(format!("当前工作目录是：{content}")))
            }
            Some(Message::User(text)) => Ok(ModelDecision::EndTurn(format!("echo: {text}"))),
            _ => Ok(ModelDecision::EndTurn("ready".to_string())),
        }
    }
}

struct ToolRegistry;

impl ToolRegistry {
    async fn execute(&self, name: &str, _input: &str) -> Result<String> {
        match name {
            "pwd" => Ok(std::env::current_dir()?.display().to_string()),
            other => Err(anyhow!("unknown tool: {other}")),
        }
    }
}

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
        Self {
            root: root.as_ref().to_path_buf(),
        }
    }

    fn path_for(&self, chat_id: i64) -> PathBuf {
        self.root.join(format!("chat-{chat_id}.json"))
    }
}

#[async_trait]
impl SessionStore for FileSessionStore {
    async fn load(&self, chat_id: i64) -> Result<Option<TurnContext>> {
        let path = self.path_for(chat_id);
        if !path.exists() {
            return Ok(None);
        }
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
        let mut ctx = self
            .sessions
            .load(chat_id)
            .await?
            .unwrap_or_else(|| TurnContext::new(chat_id));

        ctx.messages.push(Message::User(text.to_string()));

        for _ in 0..8 {
            match self.model.next(&ctx.messages).await? {
                ModelDecision::EndTurn(text) => {
                    ctx.messages.push(Message::Assistant(text.clone()));
                    self.sessions.save(&ctx).await?;
                    return Ok(text);
                }
                ModelDecision::CallTool { name, input } => {
                    let output = self.tools.execute(&name, &input).await?;
                    ctx.messages.push(Message::ToolResult {
                        name,
                        content: output,
                    });
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

## 第五步：按运行顺序理解这段代码

这份示例真正值得看的不是语法，而是运行顺序：

1. `main` 组装 `AppState`
2. `handle_message` 先尝试从 `.demo-sessions/chat-{id}.json` 恢复上下文
3. 当前用户输入被追加到 `messages`
4. `DemoModel` 根据最新消息决定结束还是调用工具
5. 如果触发 `pwd`，运行时执行工具并把结果回灌到消息历史
6. 模型再次读取消息历史，生成最终回答
7. 整个 `TurnContext` 被重新写回 session store

这就是一个最小但完整的可恢复 agent loop。

## 第六步：怎样验证它真的“可恢复”

在一个空目录里运行：

```bash
cargo run -- 1 "hello"
cargo run -- 1 "请告诉我 pwd"
cat .demo-sessions/chat-1.json
```

你会看到两类结果：

- 终端里能得到最终回复
- 磁盘上能看到连续积累的会话状态

这就是“恢复能力”真正成立的最低标准。不是口头上说支持 session，而是你能指出“状态存在哪里、下一次如何读回来”。

## 把它继续长成 MicroClaw 时，下一步该加什么

如果你已经能跑通上面的最小骨架，继续往 MicroClaw 靠近时，建议按下面顺序演进：

1. 把 `FileSessionStore` 换成 SQLite 存储。
2. 把 `DemoModel` 换成真实 provider 适配层。
3. 把 `String` 消息换成带 role、tool use、tool result 的结构化消息。
4. 加入显式记忆装载和 fast-path。
5. 加入超时、审批和重复工具指纹保护。
6. 最后再接入渠道适配器、Web 控制面和调度器。

这个顺序很重要。先把主链路做稳，再扩展入口和治理层，复杂度才是可控的。

## 这条最小实现主线想让你真正记住什么

从最小 runtime 走到可恢复 agent loop，本质上只跨了一个关键门槛：系统开始显式持有状态，并且能把模型输出当成控制语义来消费，而不是只当成文本来打印。

一旦跨过这个门槛，后面的记忆、调度、审批、观测和多渠道，其实都只是在这条主链路上继续加规则，而不是另起炉灶。

如果你读完整本书后只想先自己动手做一件事，那就先把这条最小实现主线跑通。它不会替代完整的 MicroClaw，但会让你第一次真正拥有“runtime 已经成形”的手感。

## 证据来源（v0.1.16 / 95491b7）

- 源码基线：<https://github.com/microclaw/microclaw/tree/95491b787a61a71f43aeb6556c695a3bd1c006ce>
- 核心源码路径：`src/runtime.rs`、`src/agent_engine.rs`、`crates/microclaw-storage/src/db.rs`、`src/llm.rs`
- 关键配置项：`src/config.rs` 中与 `max_tool_iterations`、`max_session_messages`、`compact_keep_recent`、`default_tool_timeout_secs` 相关的默认值
- 测试 / 运行文档路径：`README.md`、`DEVELOP.md`、`TEST.md`
