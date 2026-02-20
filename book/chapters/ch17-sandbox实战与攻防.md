## <a id="ch17"></a>第17章 Sandbox 实战与攻防：部署、诊断与演练

### <a id="ch17-1"></a>17.1 三种环境的沙箱模板

#### 模板A：开发机（快速迭代）

- 目标：降低摩擦，保证开发效率。
- 建议：
1. `sandbox.mode=off` 或 `all + require_runtime=false`。
2. 保持 `working_dir_isolation=chat`。
3. 限制工作目录到项目路径。

#### 模板B：测试环境（策略验证）

- 目标：提前验证隔离策略和兼容性。
- 建议：
1. `sandbox.mode=all`。
2. `require_runtime=true`。
3. 配置 mount allowlist。
4. 开启资源限制并记录执行失败类型。

#### 模板C：生产环境（边界优先）

- 目标：稳定、可审计、可回滚。
- 建议：
1. 强制沙箱 + fail-closed。
2. 明确 allowlist 与敏感目录策略。
3. 为高风险工具建立审批和告警。
4. 周期检查 runtime 可用性。

### <a id="ch17-2"></a>17.2 上线前验证清单

1. 运行 `doctor sandbox`，确认 runtime 可用。
2. 检查 `sandbox.mode`、`require_runtime` 与部署画像一致。
3. 验证 allowlist 文件存在且有条目。
4. 验证敏感路径被阻断（如 `.ssh` 相关路径）。
5. 验证符号链接路径被拒绝。
6. 验证超时行为不会卡住主流程。
7. 验证资源限制参数生效。
8. 验证 fallback/blocked 事件会进入日志与监控。

这份清单建议纳入 CI 或预发布脚本，而不是人工口头检查。

### <a id="ch17-3"></a>17.3 典型故障与排障流程

#### 故障1：沙箱已开启但仍在宿主执行

排障步骤：

1. 查配置是否 `mode=all`。
2. 查 runtime 是否可用。
3. 查 `require_runtime` 是否 false 导致 fallback。
4. 查日志中的 fallback warning。
5. 查 self-check 的风险警告输出。

#### 故障2：容器执行频繁超时

排障步骤：

1. 检查默认超时是否过低。
2. 检查命令本身是否需要拆分。
3. 检查资源限制是否过紧。
4. 检查工作目录挂载是否可访问。

#### 故障3：挂载路径被拒绝

排障步骤：

1. 检查路径是否包含符号链接。
2. 检查路径组件是否命中敏感名单。
3. 检查 allowlist 是否覆盖该根路径。
4. 在测试环境复现并记录具体拒绝原因。

### <a id="ch17-4"></a>17.4 攻防演练案例（10 例）

1. 演练：尝试访问 `~/.ssh` 目录。
预期：路径校验拒绝，工具返回错误并记录。

2. 演练：在无 docker 环境启用 `mode=all`。
预期：`require_runtime=true` 时直接失败，false 时告警回退。

3. 演练：通过软链接绕过 allowlist。
预期：符号链接检查拦截。

4. 演练：高频长命令导致资源压测。
预期：受 CPU/内存/pids 限制约束，超时可控。

5. 演练：用户诱导执行破坏性命令。
预期：审批门与策略日志可见。

6. 演练：在 control chat 触发跨 chat 写文件。
预期：权限通过但仍受路径和策略约束。

7. 演练：在普通 chat 触发跨 chat 操作。
预期：授权拒绝。

8. 演练：模拟 docker 临时不可用。
预期：行为与 `require_runtime` 配置一致。

9. 演练：挂载目录包含 `.env.production` 文件名片段。
预期：敏感组件规则触发告警/拒绝。

10. 演练：命令执行过程中进程失控。
预期：超时终止并返回结构化错误。

### <a id="ch17-5"></a>17.5 沙箱策略演进建议

1. 逐步扩大 `sandbox-only` 工具覆盖范围（先高风险）。
2. 把 fallback 行为纳入强告警与发布阻断规则。
3. 为不同环境预制策略矩阵（desktop/server/CI）。
4. 结合工作负载做资源上限分层模板。
5. 对敏感目录名单与 allowlist 机制做团队级标准化。

### <a id="ch17-6"></a>17.6 本章小结

Sandbox 的核心不在“是否使用 Docker”，而在“隔离策略是否被持续执行并可审计”。本章给出了从部署到演练的落地路径。

下一章将回到 Agent Loop，以案例工坊方式拆解复杂任务如何在多轮中稳定收敛。

### 源码片段与图示

#### 图示：Agent Loop + Sandbox 执行路径

![Agent Loop](../assets/agent-loop.svg)

#### 源码片段：runtime 可用性探测（节选，`crates/microclaw-tools/src/sandbox.rs`）

```rust
fn docker_available() -> bool {
    std::process::Command::new("docker")
        .args(["info", "--format", "{{.ServerVersion}}"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}
```

#### 源码片段：Fail-open/Fall-back 警告（节选）

```rust
if !self.backend.is_real() {
    if self.config.require_runtime {
        bail!("sandbox is enabled but no docker runtime is available");
    }
    if !self.warned_missing_runtime.swap(true, Ordering::Relaxed) {
        tracing::warn!("sandbox enabled but docker unavailable, falling back to host");
    }
    return exec_host_command(command, opts).await;
}
```
