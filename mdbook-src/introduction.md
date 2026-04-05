# 剖析与实现 MicroClaw

> 基于 v0.1.38 源码的多渠道 Agent Runtime 架构、最小实现与生产实践

## 这本书写给谁

这本书写给两类读者：

1. **已经做过 LLM 应用**，但还没有把 Agent 做成长期运行系统的工程师。
2. **正在评估或实现多渠道 Agent Runtime**，需要一套从架构到生产治理的完整心智模型的团队。

## 本书基于

- **项目**：MicroClaw — 一个基于 Rust 的多渠道 Agent Runtime
- **版本**：v0.1.38
- **架构**：8 个 workspace crate、44 个内置工具、16 个渠道适配器
- **核心特性**：统一 Agent Loop、并行工具执行、会话原生子代理、双层记忆、MCP/A2A/ACP 协议

## 阅读建议

全书按"先建立问题意识，再拆开内核，再进入生产约束"的顺序展开：

1. **Part I 基础篇**（Chapter 1-4）：建立问题意识与技术判断标准
2. **Part II 内核篇**（Chapter 5-12）：理解主链路与内核实现
3. **Part III 生产篇**（Chapter 13-18）：推进到可托管、可演进、可交付状态
4. **附录 A-D**：比较、落地、源码跟读与最小实现的参考工具

## 下载

- [PDF 版本](./downloads/book.pdf)
- [EPUB 版本](./downloads/book.epub)
