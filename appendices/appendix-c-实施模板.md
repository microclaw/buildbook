# Appendix C 实施模板

## 使用方式

本附录提供 4 套围绕 MicroClaw 实施过程的模板：

1. 需求澄清
2. 架构评审
3. 发布检查
4. 事故复盘

建议做法：

- 在落地前先填模板 1 和模板 2。
- 每次准备上线前填写模板 3。
- 一旦发生生产事故，强制填写模板 4。

模板的目的不是增加流程，而是把"本应提前讲清楚的事情"结构化下来。每一项都与 MicroClaw 主链路（统一循环、wave 调度、Subagent、Hooks、ACP/A2A、Gateway、OTLP、SQLite schema）直接相关，不是泛 IT 模板。

---

## 模板 1：需求澄清

### 1. 业务目标

- 项目名称：
- 负责人：
- 计划上线时间：
- 业务目标一句话描述：
- 成功标准（可度量）：
- 这次实施替代或共存的现有系统：

### 2. 使用场景

- 目标渠道（在 15 个 ChannelAdapter 中选取：Telegram / Discord / Slack / Feishu / Email / IRC / Web / Matrix / Weixin / DingTalk / Signal / WhatsApp / Nostr / iMessage / QQ）：
- 私聊 / 群聊 / 控制面 / 同时存在：
- 预计活跃 chat 数与并发 turn 数：
- 是否需要多账号或多租户隔离（不同 chat 是否走不同 LLM provider / model）：
- 是否需要 A2A 对等互联（与其他 Agent 通信）：
- 是否暴露 ACP stdio 模式给外部 host（Claude Code、IDE 等）：

### 3. 能力范围

- 必须具备的工具能力（从约 50 个内置工具中选取，列出名字）：
- 是否需要 bash 工具，对应是否启用 Docker/OCI sandbox：
- 是否需要写文件 / edit_file，是否限定根目录与路径白名单：
- 是否需要 web_fetch / web_search / browser，是否限定域名白名单：
- 必须具备的记忆能力（显式记忆 / 结构化记忆 / 知识图谱 / 向量检索 / MCP memory backend）：
- 是否需要 Scheduler（once / cron / interval / DLQ 重放）：
- 是否需要 Subagents（session-native / ACP 子代理 / orchestrate 编排），子代理深度上限：
- 是否需要 MCP 外部工具接入，列出预期的服务端：
- 是否需要 Skills / ClawHub 技能：
- 是否需要 Plugins（commands / tools / context providers）：
- 并行工具执行策略（启用 / 禁用 / 自定义 `tool_concurrency_overrides`）：

### 4. 互操作需求

- 是否需要 ACP 模式（仅 stdio，作为 guest 被外部 host 调用）：
- 是否需要 A2A 端点（HTTP 对等：`/api/a2a/agent-card` 与 `/api/a2a/message`）：
- 是否需要启动外部 ACP 进程作为子代理：
- A2A 公网暴露策略（直连 / 反向代理 / 仅内网）：

### 5. Hooks 与策略

- 是否需要 BeforeLLMCall hook（请求修改或拦截）：
- 是否需要 BeforeToolCall hook（输入修改或策略拦截）：
- 是否需要 AfterToolCall hook（输出审计或结果修改）：
- 自定义 Hook 脚本数量、超时预算、失败时的默认结果（allow / block）：

### 6. 风险边界

- 是否启用 `high_risk_tool_user_confirmation_required`：
- control chat 列表（哪些 chat 可以执行高风险动作）：
- 是否要求 sandbox（Docker / OCI 隔离），目标镜像：
- 工具风险级别 override（哪些工具需要提升或降低）：
- 并行执行 concurrency class override（哪些 MCP 工具应被标记为 read_only）：
- LLM provider / model 黑白名单：

### 7. 运维要求

- 是否启用 Web 控制面，启用后是否设置访问密码与 token：
- 是否需要 OTLP（metrics / traces / logs 各自的端点）：
- 是否需要 Gateway 服务管理（launchd / systemd / Windows 服务）：
- 是否需要 API key 轮换策略：
- 是否需要 doctor 诊断基线（CI 中跑 `microclaw doctor`）：
- 升级 / 回滚预案（保留几个版本、备份脚本路径）：

### 8. 明确排除项

- 这次不做什么：
- 哪些能力放到下一阶段：
- 哪些渠道暂时不接：

---

## 模板 2：架构评审

### 1. 当前决策点

- 决策标题：
- 触发背景：
- 需要在什么时间前定案：
- 参与决策的角色：

### 2. 备选方案

#### 方案 A

- 描述：
- 优点：
- 风险：
- 迁移成本（含 schema 迁移与 Hook 兼容）：

#### 方案 B

- 描述：
- 优点：
- 风险：
- 迁移成本：

#### 方案 C

- 描述：
- 优点：
- 风险：
- 迁移成本：

### 3. 对比维度（与 MicroClaw 主链路相关）

- 对统一循环 `agent_engine` 的影响：
- 对并行工具执行的影响（wave 分区、concurrency class 是否变化）：
- 对 ChatTurnQueue / run_control 的影响（取消语义、turn lock）：
- 对 Subagent 编排的影响（Native vs ACP、深度限制、消息回传）：
- 对存储兼容的影响（SQLite schema 是否需要新版本）：
- 对 Hooks 策略的影响（事件类型新增 / 字段变更 / 超时预算）：
- 对安全姿态的影响（risk 等级、审批门、sandbox、Hooks 拦截）：
- 对部署复杂度的影响（Gateway、渠道数量、外部依赖）：
- 对 ACP / A2A 互操作的影响：
- 对 Web 控制面（SSE / WebSocket）与 OTLP 的影响：
- 对测试与运维的影响（CI 时长、cargo deny / clippy / cargo deny 是否仍能通过）：

### 4. 结论

- 最终采用方案：
- 主要理由：
- 明确放弃其它方案的原因：

### 5. 回滚与演进

- 如果方案失败，回滚路径是什么（包含 schema 回滚步骤）：
- 为后续演进预留了哪些接口：
- 哪些临时妥协必须在某个时间点之前还掉：

---

## 模板 3：发布检查

### 1. 版本信息

- 发布版本：
- 上一个稳定版本：
- 发布负责人：
- 关联 PR / Commit / Tag：
- 发布时间窗口：
- 通知渠道（运维群 / 用户公告）：

### 2. 代码与构建

- `cargo fmt --all` 通过：
- `cargo clippy --all-targets --all-features -- -D warnings` 通过：
- `cargo test --all` 通过：
- `cargo deny check` 通过（许可证 / 已知 advisory / 重复版本）：
- Web 前端构建通过：
- 文档生成物（README、CHANGELOG、website）已更新：
- `microclaw doctor` 在干净环境跑通：
- 跨平台二进制（macOS / Linux / Windows）已构建并能启动：

### 3. 数据与兼容性

- SQLite 数据已备份（备份脚本路径与产物校验通过）：
- schema 迁移测试通过（从上一稳定版数据库直接升级到本版本）：
- 旧配置兼容性已验证（不修改用户 yaml 也能启动）：
- Hooks 脚本兼容性已验证（frontmatter 格式、事件名称未破坏）：
- Skills / ClawHub lockfile 兼容性已验证：
- MCP 配置兼容性已验证：
- 升级步骤已演练（含 setup wizard 兜底路径）：

### 4. 关键能力回归

- 基础对话（输入 / 流式输出 / 终止）：
- 工具调用成功路径与失败路径：
- 并行工具执行（多工具同 wave 并行 + 不同 wave 串行）：
- ReadOnly / SideEffect / Exclusive 三类工具混合调用的行为：
- 跨 chat 权限控制（control chat 列表生效）：
- 显式记忆与召回：
- 结构化记忆 search / update / delete：
- once / cron / interval 任务：
- DLQ 重放：
- Subagent spawn / send / orchestrate / kill：
- ACP stdio 模式（作为 guest 被外部 host 调用）：
- A2A `/api/a2a/agent-card` 与 `/api/a2a/message` 端点：
- Hooks BeforeLLMCall / BeforeToolCall / AfterToolCall 各自的 allow / block / modify：
- Web 控制面登录、SSE 推流（`/api/send_stream`）、WebSocket 推流：
- run_control 取消（用户在执行中触发停止，能在合理时间内回到空闲态）：
- ChatTurnQueue 排队（短时间内同 chat 多次输入按顺序处理）：

### 5. 安全与运维

- 高风险审批配置已验证（`high_risk_tool_user_confirmation_required`）：
- sandbox 姿态已确认（Docker/OCI 镜像存在、bash 工具受限路径）：
- `microclaw doctor` 无未接受的高危告警：
- Web 控制面密码已设置，token 不为空，鉴权中间件生效：
- OTLP 端点已验证（metrics / traces / logs 三路均能落到目标后端）：
- Gateway 服务安装 / 启停 / 卸载已验证（macOS launchd / Linux systemd / Windows 服务三选一或多选）：
- Hooks 启用 / 禁用 CLI 已验证：
- 备份脚本与还原脚本已验证：
- Runbook 已更新（含本版本新增能力 / 默认值变化 / 已知 issue）：
- 回滚负责人已确认，回滚命令已演练：

### 6. 发布判定

- 是否允许发布：
- 若不允许，阻断项是什么：
- 阻断项的负责人与目标修复时间：

---

## 模板 4：事故复盘

### 1. 基本信息

- 事故标题：
- 事故编号：
- 发现时间：
- 缓解时间：
- 完全恢复时间：
- 值班负责人：
- 复盘主持人：

### 2. 影响范围

- 受影响渠道（列出具体的 ChannelAdapter）：
- 受影响功能（工具 / 记忆 / 调度 / Subagent / Hooks / A2A / ACP / Web 控制面）：
- 受影响 chat 数量与用户数量：
- 是否影响数据完整性：
- 影响时长：

### 3. 事故时间线

- T0（最早异常出现）：
- 首次告警 / 用户反馈：
- 值班响应时间：
- T0 + 5 min：
- T0 + 30 min：
- T0 + 1 h：
- 缓解动作完成：
- 完全恢复：

### 4. 根因分析（围绕 MicroClaw 主链路）

- 直接触发原因：
- 更深层系统原因：
- 是否与 run_control 取消语义有关（取消信号是否在某个 await 点丢失，是否有 tool 没响应取消）：
- 是否与 ChatTurnQueue 有关（是否有积压、TurnLock 是否死锁、PendingMessage 是否丢失）：
- 是否与并行工具执行有关（wave 竞争、concurrency class 误配、外部 MCP 工具被错误标记为 read_only）：
- 是否与 Subagent 编排有关（嵌套深度爆炸、ACP 子进程泄漏、子代理消息回传丢失）：
- 是否与 Hooks 策略有关（Hook 超时阻塞、误拦截、modify patch 副作用）：
- 是否与 MCP 熔断状态有关（circuit breaker 是否打开、rate limit 是否撞限、stdio 子进程是否假死）：
- 是否与 schema 迁移有关（升级路径是否漏处理某个版本）：
- 是否与 Scheduler / DLQ 有关（DLQ 是否堵塞、cron 是否漂移）：
- 是否与 OTLP 导出器有关（导出阻塞主路径、采样错误）：
- 为什么没有被测试 / 监控 / `microclaw doctor` 提前发现：

### 5. 处置过程

- 临时止血动作（关闭哪些渠道 / 关闭哪些工具 / 临时禁用 Hook）：
- 是否回滚版本（回滚到哪个版本，回滚耗时）：
- 是否通过 Gateway 重启服务：
- 是否通过 run_control 主动中止活跃 run：
- 是否通过 ChatTurnQueue 清空积压：
- 是否需要数据恢复（从备份还原 / 手工修复 SQLite）：
- 哪些动作有效，哪些动作无效，哪些动作把问题放大了：

### 6. 改进项（每条都要有负责人与截止时间）

- 代码修复项：
- 测试补充项（特别是回归测试和混沌测试）：
- 监控 / 告警补充项（OTLP metrics 阈值、traces 采样、logs 关键字）：
- Hooks 策略调整项：
- 配置默认值调整项（`tool_concurrency_overrides`、`tool_timeout`、subagent 深度限制、Hook 超时）：
- 文档 / Runbook 更新项：
- doctor / setup 检查项补充：
- 备份与还原流程补充：

### 7. 复盘结论

- 这次事故真正暴露的系统问题是什么（不是表面现象）：
- 下次如何更早发现：
- 下次如何更快恢复：
- 是否需要修改架构评审或发布检查模板，使同类问题不再溜过去：
