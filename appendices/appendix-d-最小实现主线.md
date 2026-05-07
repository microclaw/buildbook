# Appendix D 最小实现主线

## 目标

抽出一个最小但不可再省的 Rust 骨架，把 MicroClaw v0.1.57 的主链路串起来：

1. workspace 骨架（一个根 crate + 一个 storage crate）
2. `AppState` 简化版（只含 db、tools、channel_registry）
3. `agent_engine` 主循环（resume → LLM 模拟 → tool 调用 → 持久化）
4. 一个内存 `ChannelAdapter`（给单元测试用）
5. SQLite schema 最小子集（chats、messages、sessions、scheduled_tasks）
6. wave-based tool executor 简化版（ReadOnly 并行 / SideEffect 串行 / Exclusive 独占）
7. 一个最小 `Tool`（echo）和一个 `Hook` 演示
8. `main.rs` 演示一次完整 turn

去掉这条骨架的任何一环，系统都会退化：没有 SessionStore 就无法恢复；没有 Tool trait 就只能写死分支；没有 wave 调度就浪费 LLM 一次返回多个 tool_use 的并发提示；没有 Hook 就把策略写进了执行体。

## 系统边界图

```
ChannelAdapter ──► AppState ──► agent_engine
                       │              │
                       │           HookManager
                       │              │
                       │           ToolRegistry ──► partition_into_waves ──► 并行执行
                       │              │
                       └─────► Database (SQLite)
                              chats / messages / sessions / scheduled_tasks
```

## workspace 骨架

### 根 `Cargo.toml`

```toml
[workspace]
members = [
    ".",
    "crates/mini-storage",
]
resolver = "2"

[package]
name = "mini-runtime"
version = "0.1.0"
edition = "2021"

[dependencies]
mini-storage = { path = "crates/mini-storage" }
anyhow = "1"
async-trait = "0.1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["macros", "rt-multi-thread", "sync"] }
futures = "0.3"
```

### `crates/mini-storage/Cargo.toml`

```toml
[package]
name = "mini-storage"
version = "0.1.0"
edition = "2021"

[dependencies]
anyhow = "1"
rusqlite = { version = "0.31", features = ["bundled"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["sync", "rt"] }
```

## SQLite 最小 schema

`crates/mini-storage/src/lib.rs` 把 schema 迁移与 `call_blocking` 桥接放在一起，对应主仓库 `crates/microclaw-storage/src/db.rs` 的同名思路。

```rust
use anyhow::Result;
use rusqlite::{params, Connection};
use std::path::Path;
use std::sync::Arc;
use tokio::sync::Mutex;

const SCHEMA_VERSION_CURRENT: i64 = 1;

pub struct Database {
    conn: Arc<Mutex<Connection>>,
}

impl Database {
    pub async fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        let conn = tokio::task::spawn_blocking(move || -> Result<Connection> {
            let conn = Connection::open(&path)?;
            init_schema(&conn)?;
            Ok(conn)
        }).await??;
        Ok(Self { conn: Arc::new(Mutex::new(conn)) })
    }

    /// 把同步 rusqlite 调用包成 async，主仓库里这一段叫 call_blocking。
    pub async fn call<F, T>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&Connection) -> Result<T> + Send + 'static,
        T: Send + 'static,
    {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let guard = conn.blocking_lock();
            f(&guard)
        }).await?
    }
}

fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS db_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);",
    )?;
    let version: i64 = conn
        .query_row(
            "SELECT value FROM db_meta WHERE key = 'schema_version'",
            [],
            |r| r.get::<_, String>(0),
        )
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);

    if version < 1 {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS chats(
                channel TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                chat_type TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                PRIMARY KEY (channel, chat_id)
            );

            CREATE TABLE IF NOT EXISTS messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                channel TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_chat_idx
                ON messages(channel, chat_id, id);

            CREATE TABLE IF NOT EXISTS sessions(
                channel TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                state TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (channel, chat_id)
            );

            CREATE TABLE IF NOT EXISTS scheduled_tasks(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                channel TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                kind TEXT NOT NULL,
                payload TEXT NOT NULL,
                run_at INTEGER NOT NULL,
                status TEXT NOT NULL
            );
            "#,
        )?;
    }

    conn.execute(
        "INSERT INTO db_meta(key, value) VALUES('schema_version', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![SCHEMA_VERSION_CURRENT.to_string()],
    )?;
    Ok(())
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct StoredMessage {
    pub role: String,
    pub content: String,
}

impl Database {
    /// 追加一条消息。
    pub async fn append_message(
        &self,
        channel: String,
        chat_id: i64,
        role: String,
        content: String,
    ) -> Result<()> {
        self.call(move |conn| {
            conn.execute(
                "INSERT INTO messages(channel, chat_id, role, content, created_at)
                 VALUES(?1, ?2, ?3, ?4, strftime('%s','now'))",
                params![channel, chat_id, role, content],
            )?;
            Ok(())
        })
        .await
    }

    /// 加载完整会话历史（演示用，实际项目要分页 / 截断）。
    pub async fn load_messages(
        &self,
        channel: String,
        chat_id: i64,
    ) -> Result<Vec<StoredMessage>> {
        self.call(move |conn| {
            let mut stmt = conn.prepare(
                "SELECT role, content FROM messages
                 WHERE channel = ?1 AND chat_id = ?2 ORDER BY id ASC",
            )?;
            let rows = stmt
                .query_map(params![channel, chat_id], |r| {
                    Ok(StoredMessage {
                        role: r.get(0)?,
                        content: r.get(1)?,
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(rows)
        })
        .await
    }

    /// 确保 chat 存在；不存在则插入。对应主仓库装配阶段确保 chat 已注册。
    pub async fn ensure_chat(
        &self,
        channel: String,
        chat_id: i64,
        chat_type: String,
    ) -> Result<()> {
        self.call(move |conn| {
            conn.execute(
                "INSERT OR IGNORE INTO chats(channel, chat_id, chat_type, created_at)
                 VALUES(?1, ?2, ?3, strftime('%s','now'))",
                params![channel, chat_id, chat_type],
            )?;
            Ok(())
        })
        .await
    }
}
```

## Tool trait + Hook 抽象

`src/tools.rs` 定义最小 Tool trait。

```rust
use anyhow::Result;
use async_trait::async_trait;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConcurrencyClass {
    ReadOnly,    // 同 wave 可与其他 ReadOnly 并行
    SideEffect,  // 单工具一波，串行
    Exclusive,   // 独占一整个 wave
}

#[derive(Debug, Clone)]
pub struct ToolCall {
    pub name: String,
    pub input: String,
}

#[async_trait]
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn concurrency_class(&self) -> ConcurrencyClass;
    async fn execute(&self, input: &str) -> Result<String>;
}

#[derive(Default)]
pub struct ToolRegistry {
    tools: Vec<Arc<dyn Tool>>,
}

impl ToolRegistry {
    pub fn register(&mut self, t: Arc<dyn Tool>) {
        self.tools.push(t);
    }

    pub fn get(&self, name: &str) -> Option<Arc<dyn Tool>> {
        self.tools.iter().find(|t| t.name() == name).cloned()
    }
}

/// 最小内置工具：echo。在主仓库里可以替换为 read_file / bash / web_fetch 等。
pub struct EchoTool;

#[async_trait]
impl Tool for EchoTool {
    fn name(&self) -> &str { "echo" }
    fn concurrency_class(&self) -> ConcurrencyClass { ConcurrencyClass::ReadOnly }
    async fn execute(&self, input: &str) -> Result<String> {
        Ok(format!("echo: {input}"))
    }
}

pub struct PwdTool;

#[async_trait]
impl Tool for PwdTool {
    fn name(&self) -> &str { "pwd" }
    fn concurrency_class(&self) -> ConcurrencyClass { ConcurrencyClass::ReadOnly }
    async fn execute(&self, _input: &str) -> Result<String> {
        Ok(std::env::current_dir()?.display().to_string())
    }
}
```

`src/hooks.rs` 定义最小 Hook 抽象，对应主仓库 `src/hooks.rs` 的 BeforeToolCall / AfterToolCall 三阶段中的两个。

```rust
use crate::tools::ToolCall;
use anyhow::Result;
use async_trait::async_trait;
use std::sync::Arc;

#[derive(Debug, Clone)]
pub enum HookOutcome {
    Allow,
    Block(String),
    Modify(String), // 把 tool 输入替换为这段
}

#[async_trait]
pub trait BeforeToolHook: Send + Sync {
    async fn before_tool(&self, call: &ToolCall) -> Result<HookOutcome>;
}

#[async_trait]
pub trait AfterToolHook: Send + Sync {
    async fn after_tool(&self, call: &ToolCall, output: &str) -> Result<String>;
}

#[derive(Default, Clone)]
pub struct HookManager {
    pub before: Vec<Arc<dyn BeforeToolHook>>,
    pub after: Vec<Arc<dyn AfterToolHook>>,
}

/// 演示 Hook：拒绝带 "rm -rf" 的输入。主仓库里这种策略由 YAML frontmatter
/// 加脚本组合实现，原理一致。
pub struct DenyDangerousHook;

#[async_trait]
impl BeforeToolHook for DenyDangerousHook {
    async fn before_tool(&self, call: &ToolCall) -> Result<HookOutcome> {
        if call.input.contains("rm -rf") {
            return Ok(HookOutcome::Block(
                format!("policy: refuse dangerous input for tool {}", call.name)
            ));
        }
        Ok(HookOutcome::Allow)
    }
}

/// 演示 AfterTool：截断超长输出。
pub struct TruncateAfterHook(pub usize);

#[async_trait]
impl AfterToolHook for TruncateAfterHook {
    async fn after_tool(&self, _call: &ToolCall, output: &str) -> Result<String> {
        if output.len() > self.0 {
            Ok(format!("{}…[truncated]", &output[..self.0]))
        } else {
            Ok(output.to_string())
        }
    }
}
```

## wave 分区与 batch 执行

`src/tool_executor.rs` 把 wave 调度独立出来，对应主仓库 `src/tool_executor.rs` 的 `partition_into_waves` 与 `execute_tool_batch`。

```rust
use crate::hooks::{HookManager, HookOutcome};
use crate::tools::{ConcurrencyClass, ToolCall, ToolRegistry};
use anyhow::{anyhow, Result};
use std::sync::Arc;

pub fn partition_into_waves(
    calls: &[ToolCall],
    registry: &ToolRegistry,
) -> Vec<Vec<usize>> {
    if calls.is_empty() { return vec![]; }
    if calls.len() == 1 { return vec![vec![0]]; }
    let (mut ro, mut se, mut ex) = (Vec::new(), Vec::new(), Vec::new());
    for (i, c) in calls.iter().enumerate() {
        let class = registry
            .get(&c.name)
            .map(|t| t.concurrency_class())
            .unwrap_or(ConcurrencyClass::SideEffect);
        match class {
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

pub async fn execute_tool_batch(
    registry: &ToolRegistry,
    hooks: &HookManager,
    calls: &[ToolCall],
) -> Result<Vec<(String, String)>> {
    let waves = partition_into_waves(calls, registry);
    let mut results: Vec<String> = vec![String::new(); calls.len()];

    for wave in &waves {
        // 同一 wave 内 ReadOnly 工具用 join_all 并发；其余 wave 单工具串行。
        if wave.len() > 1 {
            let futures = wave.iter().map(|&idx| {
                let call = calls[idx].clone();
                let registry_tools = registry.get(&call.name);
                let hooks = hooks.clone();
                async move {
                    let out = run_single(&call, registry_tools, &hooks).await;
                    (idx, out)
                }
            });
            let outs = futures::future::join_all(futures).await;
            for (idx, out) in outs {
                results[idx] = out.unwrap_or_else(|e| format!("error: {e}"));
            }
        } else {
            let idx = wave[0];
            let call = &calls[idx];
            let tool = registry.get(&call.name);
            let out = run_single(call, tool, hooks).await;
            results[idx] = out.unwrap_or_else(|e| format!("error: {e}"));
        }
    }

    Ok(calls
        .iter()
        .enumerate()
        .map(|(i, c)| (c.name.clone(), results[i].clone()))
        .collect())
}

async fn run_single(
    call: &ToolCall,
    tool: Option<Arc<dyn crate::tools::Tool>>,
    hooks: &HookManager,
) -> Result<String> {
    // BeforeToolCall：策略可拦截或改写输入
    let mut effective_input = call.input.clone();
    for h in &hooks.before {
        match h.before_tool(call).await? {
            HookOutcome::Allow => {}
            HookOutcome::Block(reason) => {
                return Err(anyhow!("blocked by hook: {reason}"));
            }
            HookOutcome::Modify(new_input) => {
                effective_input = new_input;
            }
        }
    }

    let tool = tool.ok_or_else(|| anyhow!("unknown tool: {}", call.name))?;
    let raw = tool.execute(&effective_input).await?;

    // AfterToolCall：可改写输出
    let mut output = raw;
    for h in &hooks.after {
        output = h.after_tool(call, &output).await?;
    }
    Ok(output)
}
```

## ChannelAdapter（内存实现，给单元测试用）

`src/channels.rs` 把 ChannelAdapter trait 与一个内存实现放在一起，对应主仓库 `crates/microclaw-channels/src/channel_adapter.rs`。

```rust
use anyhow::Result;
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

#[async_trait]
pub trait ChannelAdapter: Send + Sync {
    fn name(&self) -> &str;
    /// 把 agent 输出推到外部平台。这里用内存简化为 Vec。
    async fn send_text(&self, chat_id: i64, text: &str) -> Result<()>;
}

#[derive(Default, Clone)]
pub struct InMemoryChannel {
    pub outbox: Arc<Mutex<HashMap<i64, Vec<String>>>>,
}

#[async_trait]
impl ChannelAdapter for InMemoryChannel {
    fn name(&self) -> &str { "memory" }
    async fn send_text(&self, chat_id: i64, text: &str) -> Result<()> {
        let mut g = self.outbox.lock().unwrap();
        g.entry(chat_id).or_default().push(text.to_string());
        Ok(())
    }
}

#[derive(Default)]
pub struct ChannelRegistry {
    adapters: HashMap<String, Arc<dyn ChannelAdapter>>,
}

impl ChannelRegistry {
    pub fn register(&mut self, a: Arc<dyn ChannelAdapter>) {
        self.adapters.insert(a.name().to_string(), a);
    }
    pub fn get(&self, name: &str) -> Option<Arc<dyn ChannelAdapter>> {
        self.adapters.get(name).cloned()
    }
}
```

## AppState

`src/runtime.rs` 装配 db、tools、channels、hooks。这是主仓库 `src/runtime.rs` 中 `AppState` 的最小子集。

```rust
use crate::channels::ChannelRegistry;
use crate::hooks::HookManager;
use crate::tools::ToolRegistry;
use mini_storage::Database;
use std::sync::Arc;

pub struct AppState {
    pub db: Arc<Database>,
    pub tools: ToolRegistry,
    pub channel_registry: ChannelRegistry,
    pub hooks: HookManager,
}
```

## LLM 模拟与 agent_engine 主循环

`src/agent_engine.rs` 是最小化的统一循环：从 db 取历史 → 调 LLM → 解析 EndTurn / CallTools → wave 调度 → 把 ToolResult 回灌 → 下一轮 → 终止时持久化助手消息并通过 ChannelAdapter 推送。

```rust
use crate::channels::ChannelAdapter;
use crate::hooks::HookManager;
use crate::runtime::AppState;
use crate::tool_executor::{execute_tool_batch, partition_into_waves};
use crate::tools::{ToolCall, ToolRegistry};
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use mini_storage::StoredMessage;
use std::sync::Arc;

#[derive(Debug, Clone)]
pub enum ModelDecision {
    EndTurn(String),
    CallTools(Vec<ToolCall>),
}

#[async_trait]
pub trait ModelClient: Send + Sync {
    async fn next(&self, history: &[StoredMessage]) -> Result<ModelDecision>;
}

/// 演示模型：根据最后一条用户消息决定。
/// "both"  → 同 wave 调用两个 ReadOnly 工具
/// "echo " → 调用 echo 工具
/// 否则     → EndTurn
pub struct DemoModel;

#[async_trait]
impl ModelClient for DemoModel {
    async fn next(&self, history: &[StoredMessage]) -> Result<ModelDecision> {
        let last = history.last().ok_or_else(|| anyhow!("empty history"))?;
        if last.role == "tool" {
            // 工具结果回灌：把所有最近的 tool 消息汇总成最终回复
            let tools: Vec<&StoredMessage> = history
                .iter()
                .rev()
                .take_while(|m| m.role == "tool")
                .collect();
            let summary = tools
                .iter()
                .rev()
                .map(|m| m.content.as_str())
                .collect::<Vec<_>>()
                .join("\n");
            return Ok(ModelDecision::EndTurn(format!("done:\n{summary}")));
        }
        if last.role == "user" {
            if last.content.contains("both") {
                return Ok(ModelDecision::CallTools(vec![
                    ToolCall { name: "echo".into(), input: "first".into() },
                    ToolCall { name: "pwd".into(), input: String::new() },
                ]));
            }
            if let Some(rest) = last.content.strip_prefix("echo ") {
                return Ok(ModelDecision::CallTools(vec![
                    ToolCall { name: "echo".into(), input: rest.to_string() },
                ]));
            }
            return Ok(ModelDecision::EndTurn(format!("noop: {}", last.content)));
        }
        Ok(ModelDecision::EndTurn("ready".into()))
    }
}

pub async fn handle_message(
    state: Arc<AppState>,
    model: Arc<dyn ModelClient>,
    channel: &str,
    chat_id: i64,
    user_text: &str,
) -> Result<String> {
    state.db.ensure_chat(channel.to_string(), chat_id, "private".into()).await?;
    state.db.append_message(
        channel.to_string(), chat_id, "user".into(), user_text.to_string()
    ).await?;

    for iter in 0..8 {
        let history = state.db.load_messages(channel.to_string(), chat_id).await?;
        match model.next(&history).await? {
            ModelDecision::EndTurn(text) => {
                state.db.append_message(
                    channel.to_string(), chat_id, "assistant".into(), text.clone()
                ).await?;
                if let Some(adapter) = state.channel_registry.get(channel) {
                    adapter.send_text(chat_id, &text).await?;
                }
                return Ok(text);
            }
            ModelDecision::CallTools(calls) => {
                let waves = partition_into_waves(&calls, &state.tools);
                eprintln!("[iter {iter}] {} tool(s) in {} wave(s)", calls.len(), waves.len());
                let outputs = execute_tool_batch(&state.tools, &state.hooks, &calls).await?;
                for (name, content) in outputs {
                    state.db.append_message(
                        channel.to_string(), chat_id, "tool".into(),
                        format!("{name}: {content}"),
                    ).await?;
                }
            }
        }
    }
    Err(anyhow!("too many tool iterations"))
}
```

## 模块汇总：`src/lib.rs`

```rust
pub mod channels;
pub mod hooks;
pub mod tools;
pub mod tool_executor;
pub mod runtime;
pub mod agent_engine;
```

## 入口：`src/main.rs`

```rust
use anyhow::Result;
use mini_runtime::agent_engine::{handle_message, DemoModel, ModelClient};
use mini_runtime::channels::{ChannelRegistry, InMemoryChannel};
use mini_runtime::hooks::{DenyDangerousHook, HookManager, TruncateAfterHook};
use mini_runtime::runtime::AppState;
use mini_runtime::tools::{EchoTool, PwdTool, ToolRegistry};
use mini_storage::Database;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<()> {
    let chat_id = std::env::args().nth(1)
        .unwrap_or_else(|| "1".to_string()).parse::<i64>()?;
    let text = std::env::args().nth(2)
        .unwrap_or_else(|| "echo hello".to_string());

    // 1. 装配 db
    let db = Arc::new(Database::open(".mini.db").await?);

    // 2. 装配 tools
    let mut tools = ToolRegistry::default();
    tools.register(Arc::new(EchoTool));
    tools.register(Arc::new(PwdTool));

    // 3. 装配 channels
    let mut channel_registry = ChannelRegistry::default();
    let memory_channel = Arc::new(InMemoryChannel::default());
    channel_registry.register(memory_channel.clone());

    // 4. 装配 hooks
    let mut hooks = HookManager::default();
    hooks.before.push(Arc::new(DenyDangerousHook));
    hooks.after.push(Arc::new(TruncateAfterHook(2_000)));

    // 5. 拼装 AppState
    let state = Arc::new(AppState { db, tools, channel_registry, hooks });

    // 6. 主循环
    let model: Arc<dyn ModelClient> = Arc::new(DemoModel);
    let reply = handle_message(state.clone(), model, "memory", chat_id, &text).await?;
    println!("reply: {reply}");

    // 7. 校验 ChannelAdapter outbox
    let outbox = memory_channel.outbox.lock().unwrap();
    if let Some(items) = outbox.get(&chat_id) {
        for (i, t) in items.iter().enumerate() {
            println!("outbox[{i}]: {t}");
        }
    }
    Ok(())
}
```

## 运行验证

```bash
cargo run -- 1 "echo hello"
cargo run -- 1 "tell me both"
sqlite3 .mini.db "SELECT role, content FROM messages WHERE chat_id=1;"
```

预期：

- stderr 出现 `2 tool(s) in 1 wave(s)`，对应两个 ReadOnly 工具同 wave 并行。
- `messages` 表里依次出现 user / tool / tool / assistant 行。
- `outbox[i]` 显示 ChannelAdapter 收到的最终回复。
- 把输入改成 `echo rm -rf /` 时，`DenyDangerousHook` 会让 tool 执行返回 `error: blocked by hook: ...`，验证 BeforeToolCall 拦截链路。

## 与 MicroClaw 主仓库的对应关系

| 阶段 | 本附录文件 | 主仓库对应 |
|------|------------|------------|
| 装配 | `src/runtime.rs::AppState` | `src/runtime.rs::AppState`（v0.1.57 含 17 字段） |
| 主循环 | `src/agent_engine.rs::handle_message` | `src/agent_engine.rs::process_with_agent_with_events`、`AgentEvent` 8 种事件 |
| 工具 | `src/tools.rs` + `src/tool_executor.rs` | `crates/microclaw-tools/src/runtime.rs`（Tool trait）+ `src/tools/mod.rs`（约 50 工具）+ `src/tool_executor.rs`（wave 调度） |
| 渠道 | `src/channels.rs::InMemoryChannel` | `crates/microclaw-channels/src/channel_adapter.rs` + `src/channels/*.rs`（15 渠道） |
| 存储 | `crates/mini-storage/src/lib.rs` | `crates/microclaw-storage/src/db.rs`（schema v25+） |
| Hook | `src/hooks.rs` | `src/hooks.rs`（BeforeLLMCall / BeforeToolCall / AfterToolCall 三阶段 + frontmatter） |
| 通道 | 内存 outbox | `src/web/stream.rs`（SSE）+ `src/web/ws.rs`（WebSocket） |

## 继续往 MicroClaw 靠近的演进顺序

| 阶段 | 步骤 | 对应主仓库 |
|------|------|------------|
| 主链路 | 1. `Database` 加 sessions / scheduled_tasks 实际读写 | `crates/microclaw-storage/src/db.rs` |
| | 2. `DemoModel` 替换为真实 LLM provider | `src/llm.rs` |
| | 3. 字符串消息替换为结构化消息（ContentBlock / Message） | `crates/microclaw-core/src/llm_types.rs` |
| | 4. Tool trait 加风险分级、超时、审批门 | `crates/microclaw-tools/src/runtime.rs` + `src/tool_executor.rs` |
| 治理层 | 5. Hook 三阶段 + frontmatter 解析 | `src/hooks.rs` |
| | 6. 记忆服务 + Reflector | `src/memory_service.rs` + `src/memory_backend.rs` |
| | 7. run_control（取消信号） | `src/run_control.rs` |
| | 8. ChatTurnQueue（同 chat 排队） | `src/chat_turn_queue.rs` |
| | 9. 调度器 + DLQ 重放 | `src/scheduler.rs` |
| 入口 | 10. 真实渠道适配器 | `src/channels/*.rs`（15 渠道） |
| | 11. Web 控制面 + SSE / WebSocket | `src/web.rs` + `src/web/stream.rs` + `src/web/ws.rs` |
| 互操作 | 12. ACP（仅 stdio）+ A2A（HTTP）+ Subagent | `src/acp.rs` + `src/acp_subagent.rs` + `src/a2a.rs` + `src/tools/subagents.rs` |
| 可观测 | 13. OTLP metrics / traces / logs | `crates/microclaw-observability/src/` |
| 运维 | 14. Gateway 服务管理 + doctor + setup | `src/gateway.rs` + `src/doctor.rs` + `src/setup.rs` |

先主链路（1–4），再治理层（5–9），再入口（10–11），再互操作（12），最后可观测与运维（13–14）。

## 证据来源（v0.1.57）

- `Cargo.toml`（workspace）、`src/main.rs`、`src/runtime.rs`、`src/agent_engine.rs`、`src/tool_executor.rs`
- `crates/microclaw-storage/src/db.rs`（schema v25+）
- `crates/microclaw-tools/src/runtime.rs`（Tool trait、ToolRisk、ToolConcurrencyClass）
- `crates/microclaw-channels/src/channel_adapter.rs`（ChannelAdapter trait、ChannelRegistry）
- `src/hooks.rs`（三阶段 Hook、frontmatter）
- `src/web/stream.rs`（SSE）、`src/web/ws.rs`（WebSocket）
- `src/acp.rs`（ACP 仅 stdio）、`src/a2a.rs`（A2A HTTP）
- `src/config.rs`（`max_tool_iterations`、`parallel_tool_max_concurrency`、`tool_concurrency_overrides`）
