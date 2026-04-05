# Appendix A 能力矩阵

## 目标

本附录把 `research/compare/` 中的 6 份对比研究收束成一份适合纸书阅读的决策索引。它不追求"把所有细节挤进一张大表"，而是优先保证两件事：

1. 读者能快速看出各项目的主定位差异。
2. 读者能按自己的工程约束做选择，而不是只按功能多少做判断。

判断原则只有一个：看项目是否适合你的约束，而不是看它是否功能最多。

## 一页总览

| 项目 | 核心定位 | 架构取向 | 更适合的团队 |
|---|---|---|---|
| MicroClaw | 多渠道 Agent Runtime，强调统一 loop 与可控治理 | 内聚 runtime + 8 workspace crate 分层 | 想把 Agent 做成长期运行系统的小中型工程团队 |
| OpenClaw | 全栈 AI 网关 / 控制平面平台 | 平台广度优先，控制平面更重 | 需要更大生态面和多端统一管理的团队 |
| NanoClaw | 极简主干 + Skills over features | 轻主干，强依赖技能改造 | 追求极简、愿意持续定制 fork 的个人或小团队 |
| Moltis | 更企业化的 Rust AI 平台 | 多 crate、模块化更深 | 多团队协作、长期平台化建设的组织 |
| ZeroClaw | trait-driven runtime OS | 高可替换性、特性旗标丰富 | 愿意管理复杂配置矩阵的高级团队 |
| NanoBot | Python 轻量框架化实践 | 目录直观、上手快 | 想快速试验、偏 Python 生态的团队 |
| NullClaw | 极限 Zig 单体与低开销路线 | 单体二进制 + 编译期裁剪 | 对体积、底层能力和可裁剪性极敏感的团队 |

## 项目卡片

### MicroClaw

- 主语言 / 运行时：Rust + Tokio，8 workspace crate（microclaw-core, microclaw-clawhub, microclaw-storage, microclaw-tools, microclaw-channels, microclaw-app, microclaw-observability + 主二进制）
- 内置工具：44 内置工具，涵盖文件系统（bash, read_file, write_file, edit_file, glob, grep）、Web 能力（web_fetch, web_search, browser）、记忆（read_memory, write_memory, structured_memory_search/delete/update）、调度（schedule_task 等 8 个调度工具）、Subagents（sessions_spawn, subagents_list/info/kill/focus/unfocus/focused/send/orchestrate/log/retry_announces 共 11 个）、A2A 通信（a2a_list_peers, a2a_send）、时间计算（get_current_time, compare_time, calculate）、技能管理（activate_skill, sync_skills）、消息与导出（send_message, export_chat, todo_read, todo_write）、ClawHub 集成（clawhub_search, clawhub_install）
- 并行工具执行：基于 wave 的批量调度，按 concurrency class（ReadOnly / SideEffect / Exclusive）分波并行
- 记忆路线：`AGENTS.md` + 结构化记忆 + 可选向量检索 + MCP memory backend + Reflector 自动提取
- 调度 / 后台：Scheduler（分钟级 tick + DLQ + 失败补偿）+ Reflector + Session-native Subagents（Native 与 ACP 双模式）
- 渠道支持：16 个渠道适配器——Telegram, Discord, Slack, Feishu/Lark, Email, IRC, Web, Matrix, WeChat/Weixin, DingTalk, Signal, WhatsApp, Nostr, iMessage, QQ, ACP
- 扩展机制：MCP（多服务端 + rate limit + circuit breaker）、Skills（本地 + ClawHub 远程仓库）、Plugins（manifest + commands + tools + context providers）、Hooks（BeforeLLMCall / BeforeToolCall / AfterToolCall 三阶段）
- 互操作协议：ACP（Agent Client Protocol，stdio 模式，可作为 host 或 guest）、A2A（Agent-to-Agent，HTTP 对等通信）
- 安全姿态：审批门 + sandbox（Docker/OCI）+ path/url 校验 + 控制面鉴权 + Hooks 策略拦截 + 工具风险分级（Low/Medium/High）
- 运维能力：Gateway 服务管理（macOS launchd / Linux systemd / Windows 服务）、Web 控制面（auth + sessions + metrics + stream + config）、OTLP 三信号（metrics + traces + logs）、doctor 诊断、upgrade 自升级
- 安装方式：Homebrew, Docker, Nix, 一键安装脚本（install.sh / install.ps1）
- 一句话判断：如果你最看重"统一主链路 + 长期运行治理 + 渠道广度"，它通常是最平衡的选择。

### OpenClaw

- 主语言 / 运行时：TypeScript 为主，含多端代码
- 记忆路线：更偏插件化 memory 演进
- 调度 / 后台：平台化能力较多
- 扩展机制：丰富插件与端侧生态
- 安全姿态：网络暴露和平台运维安全叙事更强
- 一句话判断：如果你更需要大生态面和控制平面能力，而不是单机优先 runtime，它更合适。

### NanoClaw

- 主语言 / 运行时：Node.js / TypeScript
- 记忆路线：文件记忆为主
- 调度 / 后台：有简洁任务调度
- 扩展机制：Skills 驱动定制
- 安全姿态：容器隔离默认姿态更强
- 一句话判断：如果你想保持主干极简，并愿意通过 skill 和 fork 持续定制，它很有吸引力。

### Moltis

- 主语言 / 运行时：Rust
- 记忆路线：平台级 memory 能力
- 调度 / 后台：平台化后台能力更重
- 扩展机制：Channels / MCP / Skills 更细分
- 安全姿态：安全制度化和企业特性更强
- 一句话判断：如果你的目标是多团队平台化建设，而不是单机优先产品，它更接近企业工程路线。

### ZeroClaw

- 主语言 / 运行时：Rust
- 记忆路线：多 backend、可配置更强
- 调度 / 后台：更平台化
- 扩展机制：trait 边界多，可替换性强
- 安全姿态：安全矩阵和运行组合更广
- 一句话判断：如果你团队能驾驭复杂配置矩阵，并且看重可替换性，它会比更内聚的 runtime 更有吸引力。

### NanoBot

- 主语言 / 运行时：Python
- 记忆路线：轻量 memory 与 heartbeat
- 调度 / 后台：cron + heartbeat
- 扩展机制：MCP + Skills，试验速度快
- 安全姿态：通过白名单和配置控制风险
- 一句话判断：如果你要快速验证想法、并且主要工作流在 Python 生态，它的启动成本最低。

### NullClaw

- 主语言 / 运行时：Zig
- 记忆路线：SQLite hybrid 和更细 memory engine
- 调度 / 后台：平台能力覆盖更底层
- 扩展机制：Skills、MCP、多 backend sandbox
- 安全姿态：系统级多后端隔离更激进
- 一句话判断：如果你最关注体积、低开销和底层系统能力，它提供了其他项目较少覆盖的方向。

## 如何使用这份矩阵

### 如果你最看重"统一内核 + 可治理 + 渠道覆盖"

优先看 MicroClaw。它的优势不是任何单项功能最强，而是把 16 个渠道、44 个内置工具、结构化记忆、调度、Subagent 编排、Hooks 策略、A2A/ACP 互操作、控制面和观测统一在一个较清晰的 runtime 里。v0.1.38 的 wave-based 并行工具执行和 session-native subagents 进一步拉开了它与"只能串行调一次模型"的 Demo Agent 的距离。

### 如果你最看重"生态广度"

优先看 OpenClaw。它更像平台，代价是复杂度和治理成本更高。

### 如果你最看重"极简可读和快速 fork"

优先看 NanoClaw 或 NanoBot。前者更强调 skill 驱动改造，后者更偏 Python 社区和快速实验。

### 如果你最看重"企业级模块化或高度可替换"

优先看 Moltis 或 ZeroClaw。它们更适合有较强平台化诉求的团队，但默认复杂度也更高。

### 如果你最看重"极限系统能力和裁剪"

优先看 NullClaw。它不是最容易上手，但在系统级可裁剪和低开销方向上有独特价值。

## 对 MicroClaw v0.1.38 的定位总结

综合 6 份对比研究，MicroClaw 最稳定的优势并不是"功能最多"，而是：

1. 用 Rust 单二进制 runtime（8 workspace crate 内聚编译）保持较高能力密度。
2. 在 16 个渠道、44 个工具、结构化记忆、Subagent 编排、调度、Hooks 策略、A2A/ACP 互操作、控制面之间维持一致主链路。
3. 并行工具执行（wave-based concurrency class 分波调度）让单轮 turn 的吞吐和延迟有了结构性改善。
4. Session-native subagents 和 ACP 子代理双模式让多 Agent 编排成为 runtime 内建能力，而非外挂脚本。
5. 在安全（三级工具风险 + 审批门 + sandbox + Hooks 策略拦截）、可观测（OTLP 三信号 + tool span tracing）和运行治理（Gateway 服务管理 + doctor 诊断 + upgrade 自升级）上投入明显高于普通 Demo Agent。

它最适合的不是追求最极致某一项能力的场景，而是那些希望在复杂度可控前提下，真正把 Agent 用起来、跑起来、管起来的团队。
