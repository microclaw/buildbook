## <a id="appendix"></a>附录

### <a id="app-a"></a>附录A 术语表

1. Agent Loop：由模型决策与工具执行组成的迭代闭环。
2. stop_reason：模型本轮停止原因，驱动状态转移。
3. ToolDefinition：供模型调用的工具声明（名称、描述、输入模式）。
4. ToolResult：工具执行标准返回结构。
5. ToolRisk：工具风险等级（low/medium/high）。
6. ToolExecutionPolicy：工具执行位置策略（host-only/sandbox-only/dual）。
7. Approval Gate：高风险操作审批门。
8. Control Chat：可跨 chat 执行操作的受信会话。
9. WorkingDir Isolation：工具工作目录隔离模式（shared/chat）。
10. SandboxRouter：决定宿主/容器执行路径的路由器。
11. Fail-open：隔离依赖不可用时回退执行。
12. Fail-closed：隔离依赖不可用时拒绝执行。
13. AGENTS.md：文件记忆载体。
14. Structured Memory：数据库结构化记忆。
15. Reflector：后台记忆提取任务。
16. Memory Injection：把记忆注入系统提示词的过程。
17. Token Budget：注入内容的估算 token 上限。
18. Session Resume：会话持久化恢复机制。
19. Context Compaction：上下文压缩归档机制。
20. Todo Orchestration：多步骤任务的计划-执行同步机制。
21. Scheduler：定时任务执行器。
22. DLQ：失败任务死信队列。
23. Hook：生命周期策略扩展点。
24. BeforeLLMCall：模型调用前 hook 事件。
25. BeforeToolCall：工具调用前 hook 事件。
26. AfterToolCall：工具调用后 hook 事件。
27. Self-check：配置风险自检接口。
28. SLO：服务级目标指标集合。
29. Burn Alert：SLO 消耗告警。
30. Capability Flags：模型/提供商能力标识。

### <a id="app-b"></a>附录B 工具清单与风险等级速查

#### B.1 内建工具列表（当前）

1. `activate_skill`
2. `bash`
3. `browser`
4. `cancel_scheduled_task`
5. `edit_file`
6. `export_chat`
7. `get_task_history`
8. `glob`
9. `grep`
10. `list_scheduled_task_dlq`
11. `list_scheduled_tasks`
12. `pause_scheduled_task`
13. `read_file`
14. `read_memory`
15. `replay_scheduled_task_dlq`
16. `resume_scheduled_task`
17. `schedule_task`
18. `send_message`
19. `structured_memory_delete`
20. `structured_memory_search`
21. `structured_memory_update`
22. `sub_agent`
23. `sync_skills`
24. `todo_read`
25. `todo_write`
26. `web_fetch`
27. `web_search`
28. `write_file`
29. `write_memory`

#### B.2 风险分级速查

- High
1. `bash`

- Medium
1. `write_file`
2. `edit_file`
3. `write_memory`
4. `send_message`
5. `sync_skills`
6. `schedule_task`
7. `pause_scheduled_task`
8. `resume_scheduled_task`
9. `cancel_scheduled_task`
10. `replay_scheduled_task_dlq`
11. `structured_memory_delete`
12. `structured_memory_update`

- Low
1. 其余未列入 high/medium 的工具默认 low。

#### B.3 执行策略速查（当前基线）

1. `bash`: `dual`
2. `write_file`: `host-only`
3. `edit_file`: `host-only`
4. 其余工具：`host-only`

#### B.4 子代理允许工具（受限工具集）

1. `bash`
2. `browser`
3. `read_file`
4. `write_file`
5. `edit_file`
6. `glob`
7. `grep`
8. `read_memory`
9. `web_fetch`
10. `web_search`
11. `activate_skill`
12. `structured_memory_search`

#### B.5 子代理默认禁用能力

1. `send_message`
2. `write_memory`
3. `schedule_task` 及其管理工具
4. `export_chat`
5. `sub_agent`（防递归）

### <a id="app-c"></a>附录C 默认配置项速查表

#### C.1 LLM 与循环控制

1. `llm_provider`: `anthropic`
2. `max_tokens`: `8192`
3. `max_tool_iterations`: `100`
4. `max_history_messages`: `50`
5. `max_session_messages`: `40`
6. `compact_keep_recent`: `20`
7. `compaction_timeout_secs`: `180`
8. `memory_token_budget`: `1500`

#### C.2 路径与运行目录

1. `data_dir`: 默认 `~/.microclaw`
2. `working_dir`: 默认 `~/.microclaw/working_dir`
3. `working_dir_isolation`: `chat`

#### C.3 沙箱默认值

1. `sandbox.mode`: `off`
2. `sandbox.backend`: `auto`
3. `sandbox.image`: `ubuntu:25.10`
4. `sandbox.container_prefix`: `microclaw-sandbox`
5. `sandbox.no_network`: `true`
6. `sandbox.require_runtime`: `false`
7. `sandbox.mount_allowlist_path`: `null`
8. `sandbox.memory_limit`: `null`
9. `sandbox.cpu_quota`: `null`
10. `sandbox.pids_limit`: `null`

#### C.4 Web 默认值

1. `web_enabled`: `true`
2. `web_host`: `127.0.0.1`
3. `web_port`: `10961`
4. `web_max_inflight_per_session`: `2`
5. `web_max_requests_per_window`: `8`
6. `web_rate_window_seconds`: `10`
7. `web_run_history_limit`: `512`
8. `web_session_idle_ttl_seconds`: `300`

#### C.5 调度与反思默认值

1. `timezone`: `UTC`
2. `reflector_enabled`: `true`
3. `reflector_interval_mins`: `15`

#### C.6 超时预算默认值

1. `default_tool_timeout_secs`: `30`
2. `default_mcp_request_timeout_secs`: `120`

#### C.7 ClawHub 与语音默认值

1. `clawhub_registry`: `https://clawhub.ai`
2. `clawhub_agent_tools_enabled`: `true`
3. `voice_provider`: `openai`

#### C.8 配置调优备忘

1. 先确定部署画像，再调参数。
2. 先调整超时和限流，再调整模型参数。
3. 先开启可观测，再扩大自动化能力。
4. 高频变更参数应纳入变更审计。
5. 所有安全相关参数都应在自检接口中回看。

### <a id="app-d"></a>附录D 参考资料与代码索引

#### D.1 项目与文档

1. 项目仓库：`https://github.com/microclaw/microclaw`
2. 官网：`https://microclaw.ai`
3. 作者：`https://github.com/everettjf`
4. 关键文档目录：`/Users/eevv/focus/microclaw/docs`
5. 网站内容目录：`/Users/eevv/focus/microclaw/website`

#### D.2 关键源码索引

1. Agent Loop：`src/agent_engine.rs`
2. 运行时装配：`src/runtime.rs`
3. 工具注册与策略校验：`src/tools/mod.rs`
4. 子代理工具：`src/tools/sub_agent.rs`
5. 调度器与反思器：`src/scheduler.rs`
6. 配置定义：`src/config.rs`
7. 沙箱路由与后端：`crates/microclaw-tools/src/sandbox.rs`
8. 工具运行时策略：`crates/microclaw-tools/src/runtime.rs`
9. Web 配置自检：`src/web/config.rs`

#### D.3 关键 RFC 与运维文档

1. Auth 模型：`docs/rfcs/0001-authn-authz-model.md`
2. Hooks 模型：`docs/rfcs/0002-hooks-event-model.md`
3. 运行手册：`docs/operations/runbook.md`
4. 执行模型：`docs/security/execution-model.md`
5. 稳定性计划：`docs/operations/stability-plan-2026-q1.md`

#### D.4 博客索引

1. `/website/blog/2026-02-07-building-microclaw.md`
2. `/website/blog/2026-02-14-built-with-rust-microclaw-runtime.md`
3. `/website/blog/2026-02-19-microclaw-february-updates.md`
