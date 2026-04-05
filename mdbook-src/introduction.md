# 剖析与实现 MicroClaw

> 基于 v0.1.38 源码的多渠道 Agent Runtime 架构、最小实现与生产实践

## 关于这本书

这本书是使用 [Claude Code](https://claude.ai/code) 自动生成的一次实验。

MicroClaw 是一个基于 Rust 的多渠道 Agent Runtime，支持 Telegram、Discord、Slack、飞书等十余个渠道的统一接入。在项目迭代到 v0.1.38 之后，我们决定让 AI 来尝试一件事：**基于完整源码，自动生成一本系统性的技术书**。

全书 18 章 + 4 附录，从架构设计到生产实践，从工具系统到安全体系，覆盖了 MicroClaw 的完整技术栈。每一章都基于真实源码分析，包含 Rust 和 Python 双语代码示例。

> **声明**：本书内容由 AI 生成，仅供参考。如果你发现技术细节有误或有改进建议，欢迎提 Issue 或 PR。

如果觉得这个项目有意思，欢迎 Star：

- [MicroClaw](https://github.com/niceclaw/microclaw) — Agent Runtime 本体
- [BuildBook](https://github.com/niceclaw/buildbook) — 本书源码

---

## 这本书写给谁

1. **已经做过 LLM 应用**，但还没有把 Agent 做成长期运行系统的工程师。
2. **正在评估或实现多渠道 Agent Runtime**，需要一套从架构到生产治理的完整心智模型的团队。

## MicroClaw 是什么

| 维度 | 描述 |
|------|------|
| **定位** | 多渠道 Agent Runtime，不是聊天机器人框架 |
| **语言** | Rust 2021 Edition + Tokio 异步运行时 |
| **架构** | 8 个 workspace crate，单进程统一循环 |
| **工具** | 44 个内置工具，wave-based 并行执行 |
| **渠道** | Telegram、Discord、Slack、飞书、IRC、Web、Email、Matrix 等 |
| **记忆** | 双层设计：文件记忆（AGENTS.md）+ 结构化记忆（SQLite） |
| **扩展** | MCP、Skills、Plugins、Hooks、A2A、ACP 六种机制 |
| **存储** | SQLite 本地状态，支持会话恢复与调度任务 |

## 阅读建议

全书按"先建立问题意识，再拆开内核，再进入生产约束"的顺序展开：

1. **Part I 基础篇**（Chapter 1-4）：建立问题意识与技术判断标准
2. **Part II 内核篇**（Chapter 5-12）：理解主链路与内核实现
3. **Part III 生产篇**（Chapter 13-18）：推进到可托管、可演进、可交付状态
4. **附录 A-D**：比较、落地、源码跟读与最小实现的参考工具

## 下载离线版本

- [PDF 版本](./downloads/book.pdf) — 适合打印和离线阅读
- [EPUB 版本](./downloads/book.epub) — 适合 Kindle / Apple Books
