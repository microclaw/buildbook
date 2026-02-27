# Appendix B 源码导读索引

## 核心路径

- `src/agent_engine.rs`
- `src/runtime.rs`
- `src/llm.rs`
- `src/scheduler.rs`
- `src/web/*.rs`
- `crates/microclaw-storage/src/db.rs`

## 阅读顺序

1. 先读运行入口（main/runtime）
2. 再读核心循环（agent_engine）
3. 再读存储与调度
4. 最后读渠道适配与 Web 控制面
