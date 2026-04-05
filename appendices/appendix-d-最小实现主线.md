# Appendix D 最小实现主线

## 目标

抽出 5 个最小但不可再省的构件，串成一条可运行的最小 Agent Runtime：

1. 运行时装配对象
2. 可恢复的会话状态
3. 能发起工具调用的统一循环
4. 并行工具执行的 wave 调度
5. 可落盘、可再次恢复的 session store

## 最小边界

```
AppState ──► SessionStore ──► TurnContext
                │
          ModelClient ──► ModelDecision (EndTurn | CallTools)
                │
          ToolRegistry ──► ConcurrencyClass ──► partition_into_waves
                │
          handle_message ──► wave parallel execute ──► persist
```

缺少任何一项，系统都会退化：没有装配层 → 依赖散落；没有 session store → 无法恢复；没有并行调度 → 浪费 LLM 返回多 tool_use 的结构性信息。

## 第一步：运行时边界

```rust
struct AppState<M, S> {
    model: M,
    tools: ToolRegistry,
    sessions: S,
}
```

## 第二步：可恢复状态

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
struct TurnContext {
    chat_id: i64,
    messages: Vec<Message>,
}
```

## 第三步：模型返回控制语义

```rust
#[derive(Debug, Clone)]
struct ToolCall { name: String, input: String }

enum ModelDecision {
    EndTurn(String),
    CallTools(Vec<ToolCall>),  // 支持一次返回多个工具调用
}
```

## 第四步：concurrency class 和 wave 分区

```rust
#[derive(Debug, Clone, Copy, PartialEq)]
enum ConcurrencyClass {
    ReadOnly,    // 可与其他 ReadOnly 并行
    SideEffect,  // 必须串行
    Exclusive,   // 独占整个 wave
}

fn partition_into_waves(calls: &[ToolCall]) -> Vec<Vec<usize>> {
    if calls.len() <= 1 {
        return if calls.is_empty() { vec![] } else { vec![vec![0]] };
    }
    let mut readonly = Vec::new();
    let mut sideeffect = Vec::new();
    let mut exclusive = Vec::new();
    for (i, c) in calls.iter().enumerate() {
        match tool_concurrency_class(&c.name) {
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
```

## 第五步：完整可运行示例

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
struct ToolCall { name: String, input: String }

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
enum ConcurrencyClass { ReadOnly, SideEffect, Exclusive }

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
    let (mut ro, mut se, mut ex) = (Vec::new(), Vec::new(), Vec::new());
    for (i, c) in calls.iter().enumerate() {
        match tool_concurrency_class(&c.name) {
            ConcurrencyClass::ReadOnly => ro.push(i),
            ConcurrencyClass::SideEffect => se.push(i),
            ConcurrencyClass::Exclusive => ex.push(i),
        }
    }
    let mut waves = Vec::new();
    if !ro.is_empty() { waves.push(ro); }
    for idx in se { waves.push(vec![idx]); }
    for idx in ex { waves.push(vec![idx]); }
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
                Ok(content.chars().take(200).collect())
            }
            other => Err(anyhow!("unknown tool: {other}")),
        }
    }

    async fn execute_batch(&self, calls: &[ToolCall]) -> Vec<(String, String)> {
        let waves = partition_into_waves(calls);
        let mut results = vec![String::new(); calls.len()];
        for wave in &waves {
            if wave.len() == 1 {
                let idx = wave[0];
                let output = self.execute(&calls[idx].name, &calls[idx].input)
                    .await.unwrap_or_else(|e| format!("error: {e}"));
                results[idx] = output;
            } else {
                let handles: Vec<_> = wave.iter().map(|&idx| {
                    let name = calls[idx].name.clone();
                    let input = calls[idx].input.clone();
                    tokio::spawn(async move {
                        let r = ToolRegistry;
                        let out = r.execute(&name, &input).await
                            .unwrap_or_else(|e| format!("error: {e}"));
                        (idx, out)
                    })
                }).collect();
                for h in handles {
                    if let Ok((idx, out)) = h.await { results[idx] = out; }
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

struct FileSessionStore { root: PathBuf }

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
        Ok(Some(serde_json::from_slice(&bytes)?))
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

impl<M: ModelClient + Send + Sync, S: SessionStore + Send + Sync>
    AppState<M, S>
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
                            name, content: output,
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
    let chat_id = std::env::args().nth(1)
        .unwrap_or_else(|| "1".to_string()).parse::<i64>()?;
    let text = std::env::args().nth(2)
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

## 运行顺序

```
main 组装 AppState
    │
    ▼
handle_message ──► 从 .demo-sessions/ 恢复上下文
    │
    ▼
追加用户输入 ──► DemoModel 决定结束或调用工具
    │                              │
    ▼                         CallTools(vec)
  EndTurn                          │
    │                    partition_into_waves
    ▼                         │
  persist              ReadOnly 同 wave 并行
    │                    wave 间串行
    ▼                         │
  return               工具结果回灌 → 再次调用模型
                              │
                         persist + return
```

## 验证

```bash
cargo run -- 1 "hello"
cargo run -- 1 "tell me both"
cat .demo-sessions/chat-1.json
```

- stderr 显示 `2 tool(s) in 1 wave(s)` —— 两个 ReadOnly 工具同一 wave 并行
- 磁盘上连续积累的会话状态

## 继续往 MicroClaw 靠近的演进顺序

| 阶段 | 步骤 | 对应源码 |
|------|------|---------|
| 主链路 | 1. FileSessionStore → SQLite | `crates/microclaw-storage/src/db.rs` |
| | 2. DemoModel → 真实 provider | `src/llm.rs` |
| | 3. String → 结构化消息 | `microclaw-core/src/llm_types.rs` |
| | 4. ToolRegistry + Tool trait + 风险分级 | `crates/microclaw-tools/src/runtime.rs` |
| 治理层 | 5. Hooks 策略拦截 | `src/hooks.rs` |
| | 6. 记忆 + Reflector | `src/memory_service.rs` + `memory_backend.rs` |
| | 7. run control（取消信号） | `src/run_control.rs` |
| | 8. ChatTurnQueue | `src/chat_turn_queue.rs` |
| | 9. 超时 + 审批 + 重复指纹 | `src/tool_executor.rs` |
| 入口 | 10. 渠道适配器 | `crates/microclaw-channels/` |
| | 11. Web 控制面 + 调度 | `src/web.rs` + `src/scheduler.rs` |
| 互操作 | 12. ACP/A2A + Subagent | `src/acp.rs` + `src/a2a.rs` + `src/tools/subagents.rs` |

先主链路（1-4），再治理层（5-9），再入口（10-11），最后互操作（12）。

## 证据来源（v0.1.38 / dd9e629）

- `src/runtime.rs`、`src/agent_engine.rs`、`src/tool_executor.rs`、`crates/microclaw-storage/src/db.rs`、`src/llm.rs`、`crates/microclaw-tools/src/runtime.rs`
- `src/config.rs`（`max_tool_iterations`、`parallel_tool_max_concurrency`、`tool_concurrency_overrides`）
