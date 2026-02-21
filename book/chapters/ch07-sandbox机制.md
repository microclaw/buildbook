## <a id="ch7"></a>第7章 Sandbox 机制：隔离执行与失败策略

本章导读：本章围绕该主题展开，先交代问题背景，再说明实现与取舍，最后给出实践建议。

### <a id="ch7-1"></a>7.1 Off / All 模式与运行时路由

MicroClaw 的沙箱配置核心是 `sandbox.mode`，当前有两个主模式：`off` 与 `all`。

1. `off`：直接在宿主执行命令。
2. `all`：优先通过沙箱后端执行（当前主后端为 Docker）。

路由逻辑由 `SandboxRouter` 统一处理。它根据模式和后端可用性决定实际执行路径，而不是让各工具自行判断。这种集中式路由有两个优势：

1. 策略一致，避免工具间行为分裂。
2. 观测统一，便于统计 fallback 与失败原因。

默认 `off` 的原因并非忽视安全，而是权衡首次部署摩擦。项目文档也明确建议：生产或高风险场景应启用沙箱并配合白名单。

### <a id="ch7-2"></a>7.2 DockerSandbox 资源与网络约束

在 `all` 模式下，若 Docker 可用，命令会进入容器执行。创建容器时系统做了多项限制：

1. `--cap-drop ALL` 去掉额外 Linux capabilities。
2. `--security-opt no-new-privileges` 阻止进程提权。
3. 默认可配置 `--network=none` 关闭网络。
4. 支持 `memory_limit`、`cpu_quota`、`pids_limit` 等资源约束。

这一组合体现了“默认限制、按需放开”的思路。对 Agent 执行环境来说，资源限制并不只是成本控制，也是在降低命令失控时的影响面。

容器命名采用固定前缀 + session key 片段，方便复用和诊断；执行时通过 `docker exec` 并可指定工作目录。超时由统一 `timeout` 机制控制，超时会返回结构化错误而不是阻塞主流程。

### <a id="ch7-3"></a>7.3 挂载路径、符号链接与白名单防护

Sandbox 的高风险点之一是“挂载路径”。如果挂载了敏感目录，容器隔离价值会显著下降。为此，MicroClaw 对 mount path 做了多层校验：

1. 拒绝包含符号链接组件的路径。
2. 拒绝敏感目录组件（如 `.ssh`、`.aws`、`.gnupg` 等）。
3. 拒绝敏感文件名片段（如 `.env`、私钥类文件名）。
4. 支持外部 allowlist 文件，只允许挂载在白名单根路径内。

如果校验失败，系统会记录 warning 并回退到原始工作目录路径（兼容路径）。这是一种工程化妥协：尽量保证可运行，同时把风险显性化。对于生产环境，更推荐显式配置 allowlist 并将异常视为阻断条件。

这种校验不仅保护容器执行，也保护“误配置”场景。很多安全事故来自配置错误而非攻击；路径校验能在错误进入生产前给出明确信号。

### <a id="ch7-4"></a>7.4 require_runtime 与 fail-open / fail-closed

现实中最常见的问题是：配置开了沙箱，但目标机器没有可用 Docker runtime。MicroClaw 通过 `require_runtime` 明确两种行为：

1. `require_runtime = false`：告警后回退宿主执行（fail-open）。
2. `require_runtime = true`：直接报错中止（fail-closed）。

这不是“哪个更好”的问题，而是“业务容忍度”问题：

1. 个人环境和开发环境通常更重可用性，可先 fail-open。
2. 生产或高风险自动化场景更重边界一致，应 prefer fail-closed。

更关键的是，系统把该行为做成显式配置，并在自检与文档中明确提示。这避免了“用户以为在沙箱，实际在宿主”的隐性风险。

推荐实践是把 sandbox 策略与环境分层绑定：

1. 本地开发：`mode=off` 或 `mode=all + require_runtime=false`。
2. 测试环境：`mode=all + require_runtime=true`，验证工具兼容性。
3. 生产环境：`mode=all + require_runtime=true + allowlist + 资源限制`。

### <a id="ch7-5"></a>7.5 本章小结

Sandbox 章节的核心结论是：隔离不只是“开关”，而是一组策略组合。MicroClaw 通过路由器、容器约束、路径校验和 runtime 失败策略，把“可选隔离”逐步升级为“可治理隔离”。

下一章将进入记忆系统，讨论长期状态如何被提取、筛选、注入并保持质量稳定。

### 源码片段与图示

#### 图示：系统总体架构（含执行路径）

![System Architecture](../assets/01-system-architecture.svg)

#### 源码片段：sandbox 路由决策（节选，`crates/microclaw-tools/src/sandbox.rs`）

```rust
if self.config.mode == SandboxMode::Off {
    return exec_host_command(command, opts).await;
}
if !self.backend.is_real() {
    if self.config.require_runtime {
        bail!("sandbox is enabled but no docker runtime is available");
    }
    tracing::warn!("sandbox enabled but docker unavailable, falling back to host");
    return exec_host_command(command, opts).await;
}
self.backend.ensure_ready(session_key).await?;
self.backend.exec(session_key, command, opts).await
```

#### 源码片段：挂载路径防护（节选）

```rust
const MOUNT_BLOCKED_COMPONENTS: &[&str] = &[
    ".ssh", ".gnupg", ".aws", ".azure", ".gcloud", ".kube", ".docker",
];

if contains_symlink_component(path)? {
    bail!("mount path contains symlink component");
}
if has_sensitive_mount_component(path) {
    bail!("mount path contains sensitive component");
}
```

### 实践误区速览

1. 先写工具实现，再补风险策略和权限检查。
2. 把审批机制当作唯一安全手段，忽略隔离执行。
3. 在没有观测数据的情况下调整安全策略阈值。
