# Chapter 12 MCP、Skills、Plugins

## 这一章要回答什么问题

任何一个认真做 Agent Runtime 的项目，最终都会碰到同一个问题：内置能力总有边界，但扩展能力如果接得太随意，又会迅速破坏稳定性。MicroClaw 对这个问题的回答，不是只选一种扩展方式，而是同时保留多种层次的扩展机制：

- MCP：外部工具联邦
- Skills：面向 Agent 的知识与工作流增强
- Plugins：本地命令、工具和上下文扩展
- ClawHub：技能分发与安装生态

看起来很多，但它们并不是重复造轮子。这一章读完后，你应该已经能分清：

1. 哪些扩展是“接外部执行能力”。
2. 哪些扩展是“给 Agent 注入额外能力和知识”。
3. 哪些扩展适合本地团队自定义。
4. 为什么扩展必须和风险控制一起设计。

## MCP：把外部工具接进统一 runtime

MicroClaw 的 MCP 客户端实现位于 `src/mcp.rs`。从配置结构和代码可以看出，它已经支持两类传输：

- `stdio`
- `streamable_http`

并且不是只做了最小 happy path。当前实现已经包含一套相对成熟的韧性机制：

- 请求超时
- 最大重试次数
- 健康检查周期
- circuit breaker
- 并发量控制
- queue wait budget
- rate limit per minute
- tool list cache TTL

这意味着在 MicroClaw 里，MCP 不是“能连上就行”的外接工具管道，而是被当成不稳定远程依赖来治理。

### 为什么这很重要

MCP 最大的工程风险不是协议本身，而是它把外部系统引入了核心执行路径。一旦没有限流、熔断和超时，远程 MCP server 的抖动会直接拖垮整个 agent loop。

MicroClaw 在客户端层面提前做这些保护，等于把 MCP 从“实验性插件接口”升级成了“可以进入主链路的受控依赖”。

## Skills：给 Agent 注入可发现、可激活的专业能力

`src/skills.rs` 展示了另一条完全不同的扩展路径。Skill 不是远程工具，而是以 `SKILL.md` 为核心载体的专业化能力包。系统会解析 frontmatter，识别：

- `name`
- `description`
- `platforms`
- `deps`
- `source`
- `version`
- `updated_at`
- `env_file`

同时还能判断当前平台是否可用、依赖是否满足、技能是否被禁用。

这说明 MicroClaw 对 Skill 的理解非常明确：它不是 prompt 碎片，而是带元数据、可诊断、可启停的能力单元。

### 小例子：为什么扩展元数据必须先变成统一清单？

一旦系统同时支持 MCP、Skills 和 Plugins，最危险的不是扩展太少，而是每种扩展都用自己的元数据口径。先把来源、名称和执行策略压成统一清单，后面的安装、审计和控制面才能说同一种语言。

Rust 版本用 `ExtensionManifest` 收敛扩展元数据。这样不管能力来自哪里，运行时都能先按统一字段看待它。

```rust
struct ExtensionManifest {
    name: String,
    source: String,
    kind: String,
    execution_mode: String,
}
```

Python 版本用 `@dataclass` 表达同一结构。对扩展生态来说，这一步的价值不在于“省代码”，而在于减少概念漂移。

```python
from dataclasses import dataclass


@dataclass
class ExtensionManifest:
    name: str
    source: str
    kind: str
    execution_mode: str
```

### Skills 的运行方式

从当前设计看，Skills 主要用于：

- 给 Agent 注入专门的说明和工作流程
- 在需要时通过 `activate_skill` 动态激活
- 通过 `sync_skills` 从外部来源同步并规范化 frontmatter

README 还明确说明它兼容 Anthropic Skills 路线。这意味着 MicroClaw 试图让“专业能力包”成为一等资产，而不是项目内部的隐式 prompt 技巧。

## Plugins：给团队本地自定义留下空间

如果 Skill 更像“面向 Agent 的能力包”，那么 Plugin 更像“面向当前部署环境的本地扩展”。`src/plugins.rs` 和 `docs/plugins/overview.md` 描述了插件清单的三类能力：

- 自定义 slash commands
- 自定义 plugin tools
- context providers

这三类设计非常有意思。

### 自定义命令

它适合快速把已有脚本或操作包装为命令，例如 `/uptime`、`/announce`。

### 自定义工具

它把团队本地特有能力接进统一工具系统，例如某个仅在当前环境存在的部署脚本或内部查询命令。

### Context Providers

这是插件里最容易被忽视、但非常强的设计。它允许插件在每轮执行前注入额外 prompt 或文档片段，从而把本地规则、runbook、策略文档变成 runtime 的上下文组成部分。

这意味着 Plugin 不是只能“执行命令”。它还可以参与“塑造 Agent 理解环境的方式”。

## 三种扩展方式分别解决什么问题

理解 MicroClaw 的扩展体系，关键不是记住名词，而是知道它们各自对应哪类问题。

### MCP 解决“如何接入外部现成能力”

适合已有标准化服务端工具能力，尤其当它们本来就以 MCP 形式暴露时。

### Skills 解决“如何向 Agent 注入专业化能力包”

适合把工作流程、专业规则、能力说明打包为可发现、可激活的单元。

### Plugins 解决“如何让本地部署快速加上团队特定能力”

适合那些和当前运行环境强绑定、不一定值得抽成通用 skill 或远程 MCP server 的能力。

一旦分清这三件事，你就不会再问“为什么不只保留一种扩展机制”。因为它们根本不在同一层。

## ClawHub：分发与供应链治理

有了技能系统，还会遇到另一个问题：能力从哪里来、如何安装、如何追踪版本？MicroClaw 通过 ClawHub 给出了一条生态路线。

`docs/clawhub/overview.md` 指出：

- CLI 支持 `search/install/list/inspect/available`
- Agent 工具支持 `clawhub_search`、`clawhub_install`
- 安装状态通过 `clawhub.lock.json` 记录

这里最重要的不是“有个技能商店”，而是 lockfile。因为一旦能力来自外部源，供应链可追踪性就会变得非常重要。`clawhub.lock.json` 的作用，本质上和依赖管理里的 lockfile 类似：

- 知道装了什么
- 知道版本和来源
- 有利于 CI 审计

对生产系统来说，这一步比“能自动安装技能”更关键。

## 扩展的安全边界：不能因为可扩展就失去控制

MicroClaw 在扩展层面做得比较成熟的一点，是它没有把“接入成功”当成全部目标，而是同步设计了治理边界。

### MCP 的风险边界

通过超时、限流、熔断和并发控制，系统避免把外部 server 当成稳定内建能力。

### Skills 的风险边界

通过平台兼容检查、依赖检查、启停状态文件和 availability diagnostics，系统避免“看到一个 `SKILL.md` 就直接启用”。

### Plugins 的风险边界

插件执行支持：

- `host_only`
- `sandbox_only`
- `dual`

同时还能限制：

- `allowed_channels`
- `require_control_chat`

这说明 Plugin 虽然灵活，但仍必须服从运行时权限模型。

### ClawHub 的风险边界

官方文档明确建议：

- 生产环境保留 `clawhub_skip_security_warnings: false`
- 在 CI 审查 lockfile
- 自动化场景固定版本而不是直接拉 latest

这是一种非常健康的生态观：扩展能力可以快，但供应链治理不能缺席。

## 为什么 MicroClaw 还在评估官方 MCP SDK

`docs/mcp-sdk-evaluation.md` 提到，当前 MCP 实现是自研客户端逻辑，同时在评估迁移官方 Rust MCP SDK。这个文档特别值得注意，因为它体现了一个成熟项目的态度：

- 已有实现能工作，不急着为了“官方”而立刻大改。
- 但也不排斥通过适配层逐步验证兼容性和维护收益。

这和前几章的技术选型方法完全一致：先让主链路稳定，再逐步抽换底层实现。对扩展生态来说，这种节奏比追热点更可靠。

## 示例代码：为什么 MCP 调用和 Skill 载入要放在两条不同扩展路径上？

这组例子故意拆成两类：一个代表远程能力调用，一个代表本地技能激活。两者都属于扩展，但它们解决的问题完全不同，所以不应该被同一种接口强行抹平。

Rust 版本用两个 trait 明确区分“远程工具联邦”和“本地能力目录”，再用一个 struct 把它们编排到同一运行时里。这样扩展很多，但边界不会因为概念混用而模糊。

```rust
#[async_trait::async_trait]
trait McpClient {
    async fn call_tool(&self, name: &str, input: serde_json::Value) -> anyhow::Result<String>;
}

#[async_trait::async_trait]
trait SkillCatalog {
    async fn activate(&self, skill_name: &str) -> anyhow::Result<String>;
}

struct ExtensionRuntime<M, S> {
    mcp: M,
    skills: S,
}
```

先把两条扩展路径和统一运行时对象列出来，读者会更容易看清这里的关键不是“怎么调用”，而是“不同扩展能力为什么不能被混成一类”。

```rust
impl<M: McpClient, S: SkillCatalog> ExtensionRuntime<M, S> {
    async fn extend(&self, tool: &str, input: serde_json::Value, skill: &str) -> anyhow::Result<(String, String)> {
        let remote = self.mcp.call_tool(tool, input).await?;
        let local = self.skills.activate(skill).await?;
        Ok((remote, local))
    }
}
```

```{=typst}
#pagebreak(weak: true)
```

Python 版本保留相同的分层，但用 `Protocol` 和 `@dataclass` 表达更清楚的协作关系。这样读者能一眼看出：MCP 是“去外面拿能力”，Skill 是“在本地注入能力包”，二者不是一回事。

```python
from dataclasses import dataclass
from typing import Any, Protocol


class McpClient(Protocol):
    async def call_tool(self, name: str, input: dict[str, Any]) -> str: ...


class SkillCatalog(Protocol):
    async def activate(self, skill_name: str) -> str: ...


@dataclass
class ExtensionRuntime:
    mcp: McpClient
    skills: SkillCatalog
```

Python 也先固定协作关系，再展示一次具体扩展动作。这样页面上先出现的是概念边界，后出现的是编排步骤，结构更清楚。

```python

    async def extend(self, tool_name: str, input: dict[str, Any], skill_name: str) -> tuple[str, str]:
        tool_result = await self.mcp.call_tool(tool_name, input)
        skill_result = await self.skills.activate(skill_name)
        return tool_result, skill_result
```

## 关键权衡

### 决策一：同时保留 MCP、Skills、Plugins 三种扩展路径

优点是能覆盖外部能力联邦、专业能力包和本地定制三类需求。代价是概念面增加，需要更清晰的文档和治理。

### 决策二：把扩展接入也纳入统一风险控制

优点是扩展不会轻易绕过主系统边界。代价是接入成本比“任意脚本都能跑”更高。

### 决策三：用 ClawHub 和 lockfile 管理技能分发

优点是生态能力更可追踪。代价是引入了额外的安装与版本治理流程。

### 决策四：保留对 MCP 实现替换的评估空间

优点是后续演进更稳，不被当前实现绑死。代价是短期内需要维护更多兼容性判断。

## 容易走错的地方

### 失败模式 1：把所有扩展问题都塞进一种机制

这样要么会让协议负担过重，要么会让本地定制体验极差。

### 失败模式 2：扩展接入只看功能，不看治理

没有超时、限流、兼容检查和权限限制，扩展层会很快成为 runtime 的最大不稳定源。

### 失败模式 3：从外部安装能力时不做版本与来源追踪

这会在生产环境里留下非常糟糕的供应链审计空洞。

## 读到这里，你应该能回答

- 你是否知道 MCP、Skills、Plugins 各自解决的是什么问题？
- 你是否为外部能力接入设计了超时、限流、熔断和权限边界？
- 你是否让 Skill 具备元数据、可诊断和启停语义，而不是只存 prompt 文本？
- 你是否为外部安装能力保留了 lockfile 和来源审计？

## 小结

MicroClaw 的扩展生态设计说明了一点：真正可持续的 runtime，不是只会不断往内核里加功能，而是能在不破坏主链路稳定性的前提下，逐步吸收外部能力。MCP、Skills、Plugins 和 ClawHub 共同构成了这套扩展体系，而真正把它们粘在一起的，仍然是前面几章反复强调的统一治理边界。

下一章，我们不再继续扩展能力面，而是转向生产视角：安全、可观测、测试、性能、演进和交付实践。这些内容决定了一个已经“能跑”的 MicroClaw，能否真的变成一个可托管的系统。

## 图表清单

如果你打算把本章整理成演示、课程或配图版文章，下面三张图最值得保留。

- 图 12-1：MCP、Skills、Plugins 的分层位置
- 图 12-2：MCP 客户端的韧性控制链
- 图 12-3：ClawHub 与 lockfile 的供应链治理关系
