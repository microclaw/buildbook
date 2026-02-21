## <a id="ch12"></a>第12章 Web 控制面与可观测性

本章导读：本章围绕该主题展开，先交代问题背景，再说明实现与取舍，最后给出实践建议。

### <a id="ch12-1"></a>12.1 Web API 安全面与配置自检

Web 控制面是 MicroClaw 的运维入口，也是高风险入口。与聊天渠道不同，Web 常用于管理动作，安全需求更高。

当前体系包含两部分：

1. 认证授权：逐步从 legacy token 过渡到 session + API key + scope。
2. 配置自检：`/api/config/self_check` 输出风险级别和警告项。

自检项覆盖范围很实用：沙箱开关、runtime 可用性、allowlist 文件、web host 暴露、限流阈值、hooks 输出大小、OTLP 配置完整性等。它把“安全建议”转化为“可执行检查”。

这类接口的价值不在于“发现所有问题”，而在于“让高概率错误变得显而易见”。

### <a id="ch12-2"></a>12.2 使用量、记忆与稳定性指标

MicroClaw 的可观测不仅统计请求量，还覆盖工具、调度和记忆注入路径。主要指标面包括：

1. 请求成功率与延迟（端到端）。
2. 工具可靠性与策略阻断率。
3. Scheduler 可恢复率。
4. 记忆注入命中与省略统计。
5. MCP 可靠性（限流、舱壁、断路器拒绝）。

这些指标形成了“Agent 运行健康图谱”。对传统 bot 来说，关注 CPU/RAM 可能足够；对 Agent runtime，必须额外关注“决策-执行链路质量”。

例如工具可靠性下降可能不是服务崩溃，而是审批策略误配；记忆注入下降可能不是 DB 故障，而是 token 预算过低。没有领域指标就看不见这些问题。

### <a id="ch12-3"></a>12.3 运行手册与 SLO 告警闭环

`docs/operations/runbook.md` 展示了一个完整的运维闭环：症状 -> 检查点 -> 快速动作 -> SLO 告警 -> 回滚/修复路径。

关键 SLO 包括：

1. `request_success_rate`。
2. `e2e_latency_p95_ms`。
3. `tool_reliability`。
4. `scheduler_recoverability_7d`。

当 burn alert 触发时，runbook 建议冻结非关键合并、指定 incident owner、必要时准备回滚。这是典型 SRE 实践迁移到 Agent runtime 的做法。

另外，DLQ replay、hooks disable、metrics history 查询等操作都被纳入标准流程，避免事故处理依赖“谁记得命令”。

可观测体系成熟标志不是图表多，而是“发生异常时，团队能在固定时间内完成定位与处置”。从这个标准看，MicroClaw 已经具备清晰的工程化方向。

### <a id="ch12-4"></a>12.4 本章小结

Web 控制面与可观测体系让 MicroClaw 从“功能可用”走向“运营可控”。自检接口降低配置风险，指标体系提升诊断效率，runbook 与 SLO 形成事故闭环。

下一章将系统解析配置体系，解释每组参数背后的设计思路与取舍。

### 源码片段与图示

#### 图示：数据库与观测模型

![Database ER](../assets/10-database-er.svg)

#### 源码片段：配置自检（节选，`src/web/config.rs`）

```rust
if matches!(
    state.app_state.config.sandbox.mode,
    crate::config::SandboxMode::Off
) {
    warnings.push(ConfigWarning {
        code: "sandbox_disabled",
        severity: "medium",
        message: "Sandbox is disabled; bash tool executes on host by default.".to_string(),
    });
} else if !sandbox_runtime_available {
    warnings.push(ConfigWarning {
        code: "sandbox_runtime_unavailable",
        severity: if state.app_state.config.sandbox.require_runtime {
            "high"
        } else {
            "medium"
        },
        message: "Sandbox is enabled but docker runtime is unavailable...".to_string(),
    });
}
```
