# Chapter 6 Agent Engine 统一循环

## 条目列表
- 分解 `process_with_agent` 的完整阶段与输入输出。
- 规划 Session Resume 与历史重建策略。
- 规划 Context Compaction 的触发条件与安全回退。
- 规划工具迭代上限、停止条件与异常收口机制。

## 关键词
- Agent Loop
- Session Resume
- Context Compaction
- stop_reason
- Tool Iteration

## 参考链接
- [源码导读索引](../../appendices/appendix-b-源码导读索引.md)
- [MicroClaw vs OpenClaw](../../research/compare/01-microclaw-vs-openclaw.md)
- [Anthropic Tool Use](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use)

## 写作思路
- 严格按循环阶段拆解：输入、推理、工具、收口、持久化。
- 对 stop_reason 分支逐一解释行为差异与风险。
- 结合对比项目，说明为何“统一循环”比“分渠道循环”更稳。

## 资料来源
- https://docs.anthropic.com/en/docs/agents-and-tools/tool-use
- https://github.com/openclaw/openclaw/blob/main/README.md
- [MicroClaw vs OpenClaw](../../research/compare/01-microclaw-vs-openclaw.md)
