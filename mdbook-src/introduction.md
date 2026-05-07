# 剖析与实现 MicroClaw

> 基于 v0.1.57 源码的多渠道 Agent Runtime 架构、最小实现与生产实践

## 关于这本书

MicroClaw 是一个用 Rust 写的多渠道 Agent Runtime。它把 Telegram、Discord、Slack、飞书、IRC、Web、邮件、Matrix、微信、WhatsApp、Signal、iMessage、钉钉、QQ、Nostr 等十余个渠道的接入收敛到同一个内核，把工具执行、会话恢复、记忆、调度、子代理、MCP、技能、A2A、ACP 这些能力放在一个进程内统一治理。

这本书不是一份功能清单。它是一份基于 v0.1.57 完整源码的工程拆解，回答的是这样一个问题：**当一个 Agent 系统从 Demo 走向长期运行时，内核应该怎么组织、状态应该怎么持久化、风险应该怎么治理？**

全书 18 章 + 4 附录。所有代码示例统一使用 Rust，所有架构判断统一以 v0.1.57 实际源码为准。每一章基于具体的 crate、模块和代码路径展开，不做空洞的"AI 系统应该如何如何"的论述。

如果你发现技术细节与上游代码有偏差，欢迎提 Issue 或 PR：

- [MicroClaw](https://github.com/microclaw/microclaw) — Agent Runtime 本体
- [BuildBook](https://github.com/everettjf/buildbook) — 本书源码

---

## 这本书写给谁

1. **已经做过 LLM 应用**，但还没有把 Agent 做成长期运行系统的工程师。
2. **正在评估或实现多渠道 Agent Runtime**，需要一套从架构到生产治理的完整心智模型的团队。
3. **负责 AI 产品基础设施**的技术负责人，希望用工程视角而非框架视角理解 Agent Runtime。

## MicroClaw 是什么

| 维度 | 描述 |
|------|------|
| **定位** | 多渠道 Agent Runtime，不是聊天机器人框架 |
| **语言** | Rust 2021 + Tokio 异步运行时 |
| **架构** | 8 个 workspace crate，单进程统一循环 |
| **工具** | ~50 个内置工具 + MCP/插件，wave-based 并行执行 |
| **渠道** | Telegram、Discord、Slack、飞书、Matrix、邮件、Web、Weixin、WhatsApp、Signal、IRC、iMessage、钉钉、QQ、Nostr |
| **记忆** | 双层设计：文件记忆（AGENTS.md/SOUL.md）+ 结构化记忆（SQLite + 可选 sqlite-vec 向量） |
| **扩展** | MCP、Skills（ClawHub）、本地 Plugins、Hooks、A2A、ACP 六种机制 |
| **存储** | SQLite 本地状态，WAL 模式，schema 在代码内迁移 |

## 阅读建议

全书按"先建立问题意识，再拆开内核，再进入生产约束"的顺序展开：

1. **Part I 基础篇**（Chapter 1–4）：建立问题意识与技术判断标准
2. **Part II 内核篇**（Chapter 5–12）：理解主链路与内核实现
3. **Part III 生产篇**（Chapter 13–18）：推进到可托管、可演进、可交付状态
4. **附录 A–D**：能力对比、源码导读、落地模板与最小实现主线

不建议跳过基础篇直接进入实现细节——本书的实现细节都假设你已经接受了基础篇的架构判断。

## 下载离线版本

- [PDF 版本](./downloads/book.pdf) — 适合打印和离线阅读
- [EPUB 版本](./downloads/book.epub) — 适合 Kindle / Apple Books
