# Appendix C 实施模板

## 使用方式

本附录提供 4 份可直接套用的模板，分别覆盖：

1. 需求澄清
2. 架构评审
3. 发布检查
4. 事故复盘

建议做法：

- 在正式落地前先填模板 1 和模板 2。
- 每次准备上线前填写模板 3。
- 一旦发生生产事故，强制填写模板 4。

这些模板的目的不是增加流程，而是把"本应提前讲清楚的事情"结构化下来。MicroClaw 提供了并行工具执行、Subagent 编排、Hooks 策略、ACP/A2A 互操作和 Gateway 服务管理等能力，实施模板也相应覆盖了这些维度。

## 模板 1：需求澄清

### 1. 业务目标

- 项目名称：
- 负责人：
- 计划上线时间：
- 业务目标一句话描述：
- 成功标准：

### 2. 使用场景

- 目标渠道（Telegram / Discord / Slack / Feishu / Email / IRC / Web / Matrix / WeChat / DingTalk / Signal / WhatsApp / Nostr / iMessage / QQ）：
- 私聊 / 群聊 / 控制面：
- 预计用户规模：
- 是否需要多账号或多租户：
- 是否需要 A2A 对等互联（与其他 Agent 通信）：

### 3. 能力范围

- 必须具备的工具能力（从 44 内置工具中选取）：
- 必须具备的记忆能力（显式记忆 / 结构化记忆 / 向量检索 / MCP memory backend）：
- 是否需要 Scheduler（定时任务 / DLQ 重放）：
- 是否需要 Subagents（session-native / ACP 子代理 / orchestrate 编排）：
- 是否需要 MCP 外部工具接入：
- 是否需要 Skills / ClawHub 技能：
- 是否需要 Plugins：
- 并行工具执行策略（启用 / 禁用 / 自定义 concurrency override）：

### 4. 互操作需求

- 是否需要 ACP 模式（作为 stdio agent 被外部 host 调用）：
- 是否需要 A2A 端点（暴露 agent-card 供其他 Agent 发现和通信）：
- 是否有 Subagent ACP target 需要配置（启动外部 ACP Agent 进程）：

### 5. Hooks 与策略

- 是否需要 before-tool hook（策略拦截或输入修改）：
- 是否需要 after-tool hook（输出审计或结果修改）：
- 是否需要 before-llm hook（请求修改或拦截）：
- 自定义 Hook 脚本数量与超时预算：

### 6. 风险边界

- 是否允许 shell 执行（bash 工具）：
- 是否允许写文件：
- 是否需要高风险审批（`high_risk_tool_user_confirmation_required`）：
- control chat 列表：
- 是否要求 sandbox（Docker/OCI 隔离）：
- 工具风险级别 override（哪些工具需要提升或降低风险等级）：
- 并行执行 concurrency class override（哪些 MCP 工具可标记为 `read_only`）：

### 7. 运维要求

- 是否需要 Web 控制面：
- 是否需要 OTLP（metrics / traces / logs 分别需要哪些）：
- 是否需要 Gateway 服务管理（launchd / systemd / Windows 服务）：
- 是否需要 API key 自动化接入：
- 是否需要升级 / 回滚预案：
- 是否需要 doctor 诊断基线：

### 8. 明确排除项

- 这次不做什么：
- 哪些能力放到下一阶段：

## 模板 2：架构评审

### 1. 当前决策点

- 决策标题：
- 触发背景：
- 需要在什么时间前定案：

### 2. 备选方案

#### 方案 A

- 描述：
- 优点：
- 风险：
- 迁移成本：

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

### 3. 对比维度

- 对统一循环的影响：
- 对并行工具执行的影响（wave 分区、concurrency class 变化）：
- 对 Subagent 编排的影响（Native vs ACP、深度限制）：
- 对存储兼容的影响：
- 对安全姿态的影响（Hooks 策略、sandbox、审批门）：
- 对部署复杂度的影响（Gateway、渠道数量）：
- 对 ACP/A2A 互操作的影响：
- 对测试与运维的影响：

### 4. 结论

- 最终采用方案：
- 主要理由：
- 明确放弃其它方案的原因：

### 5. 回滚与演进

- 如果方案失败，回滚路径是什么：
- 为后续演进预留了哪些接口：

## 模板 3：发布检查

### 1. 版本信息

- 发布版本：
- 发布负责人：
- 关联 PR / Commit：
- 发布时间窗口：

### 2. 代码与构建

- `cargo fmt` 通过：
- `cargo clippy --all-targets` 通过：
- `cargo test` 通过：
- Web 构建通过：
- 文档生成物检查通过：

### 3. 数据与兼容性

- SQLite 已备份：
- schema migration 已评审：
- 旧配置兼容性已验证：
- 升级步骤已演练：
- Hooks 脚本兼容性已验证（frontmatter 格式、事件名称）：

### 4. 关键能力回归

- 基础对话：
- 工具调用成功 / 失败：
- 并行工具执行（多工具 wave 调度）：
- 跨 chat 权限：
- 显式记忆与召回：
- 结构化记忆 search / update / delete：
- once 任务：
- DLQ 重放：
- Subagent spawn / send / orchestrate / kill：
- ACP stdio 模式：
- A2A agent-card / message 端点：
- Hooks before-tool / after-tool 拦截：
- Metrics summary：
- 控制面登录与 API key：

### 5. 安全与运维

- 高风险审批已验证：
- sandbox 姿态已确认：
- config self-check 无未接受的高危告警：
- Gateway 服务安装 / 启停已验证（目标平台）：
- OTLP 三信号导出已验证：
- Hooks 启用 / 禁用 CLI 已验证：
- Runbook 已更新：
- 回滚负责人已确认：

### 6. 发布判定

- 是否允许发布：
- 若不允许，阻断项是什么：

## 模板 4：事故复盘

### 1. 基本信息

- 事故标题：
- 事故编号：
- 发现时间：
- 恢复时间：
- 值班负责人：

### 2. 影响范围

- 影响渠道（列出受影响的具体渠道适配器）：
- 影响功能（工具 / 记忆 / 调度 / Subagent / Hooks / A2A / ACP）：
- 用户影响描述：
- 影响时长：

### 3. 事故时间线

- T0：
- T0 + 5min：
- T0 + 30min：
- T0 + 1h：
- 恢复完成：

### 4. 根因分析

- 直接触发原因：
- 更深层系统原因：
- 是否与并行工具执行有关（wave 竞争、concurrency class 误配）：
- 是否与 Subagent 编排有关（深度爆炸、ACP 进程泄漏、取消信号丢失）：
- 是否与 Hooks 策略有关（Hook 超时阻塞、误拦截、patch 副作用）：
- 为什么没有被测试 / 监控 / 自检提前发现：

### 5. 处置过程

- 临时止血动作：
- 是否回滚：
- 是否通过 Gateway 重启服务：
- 是否通过 run_control 中止活跃 run：
- 是否恢复数据：
- 哪些动作有效，哪些动作无效：

### 6. 改进项

- 代码修复项：
- 测试补充项：
- 监控 / 告警补充项（OTLP metrics / traces / logs）：
- Hooks 策略调整项：
- 文档 / Runbook 更新项：
- 配置默认值调整项（含 concurrency override、tool timeout、subagent 深度限制）：

### 7. 复盘结论

- 这次事故真正暴露的系统问题是什么：
- 下次如何更早发现：
- 下次如何更快恢复：
