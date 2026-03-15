# Chapter 11 Web 与 API

## 这一章要回答什么问题

当一个 Agent Runtime 从个人玩具走向可长期运行系统时，纯聊天入口很快不够用。你会需要：

- 一个能查看会话和运行历史的控制面
- 一个可流式观察执行过程的界面
- 一组可自动化访问的 API
- 一套配置自检、鉴权和速率限制机制

MicroClaw 的 `web.rs` 和 `src/web/*` 子模块，承担的正是这个角色。它不是一个独立产品外壳，而是运行时的本地控制面和可编程界面。

这一章读完后，你应该理解：

1. Web 适配器为什么被视为特殊渠道。
2. API 路由如何围绕运维任务组织。
3. 流式执行、SSE 和会话管理是如何接进统一循环的。
4. 为什么控制面安全必须从 Day 1 开始做。

## Web 也是渠道，但它是特殊渠道

`src/web.rs` 里定义了 `WebAdapter`，并明确声明：

- `name() = "web"`
- `is_local_only() = true`
- `allows_cross_chat() = false`

这三个细节已经把 Web 的定位说得很清楚了。Web 在 MicroClaw 中不是另一个普通外部渠道，而是一个本地控制面入口：

- 它参与统一会话体系。
- 它也可以触发统一循环。
- 但它默认不具备对其他 chat 的跨界能力。

这种设计很合理。因为控制面最常见的风险，不是“消息收不到”，而是“管理接口能力过大”。把 Web 视为特殊渠道，能让它复用统一 runtime，同时又保持更保守的权限边界。

## API 路由是按运维域划分的

从 `src/web.rs` 以及 `src/web/` 子模块命名可以看出，MicroClaw 的 Web API 不是随意堆 endpoint，而是围绕几个运维域组织：

- `auth`
- `sessions`
- `config`
- `metrics`
- `stream`
- `skills`
- `a2a`
- `ws`

这种路由组织方式非常重要，因为它避免了“前端页面需要什么就加什么接口”的无序增长。每个路由域都对应一类稳定的运行时职责：

- `auth` 负责登录、session、API key 和权限。
- `sessions` 负责聊天历史和会话分支。
- `config` 负责配置读取、自检和风险提示。
- `metrics` 负责观测视图。
- `stream` / `ws` 负责执行过程的实时反馈。
- `skills` / `a2a` 负责扩展生态的控制面暴露。

这意味着 Web API 不只是 UI 后端，它已经是对 runtime 主能力的一个稳定映射层。

### 小例子：为什么控制面事件需要稳定 DTO？

控制面真正要展示的不是一堆框架内部对象，而是运行时公开承诺的事件结构。只有事件 DTO 稳定了，前端回放、日志关联和 API 合约才不会一起漂移。

Rust 版本把一次运行中的事件压成 `RunEvent`，显式携带 `run_id`、类型和值。这样 Web 层输出的就是 runtime 事件，而不是某个 SSE 实现细节。

```rust
struct RunEvent {
    run_id: String,
    kind: String,
    value: String,
}

impl RunEvent {
    fn as_sse_payload(&self) -> String {
        format!("{}:{}:{}", self.run_id, self.kind, self.value)
    }
}
```

Python 版本用 `@dataclass` 保持相同语义。这样例子能说明一个关键点：Web 控制面首先是事件模型，不是页面模型。

```python
from dataclasses import dataclass


@dataclass
class RunEvent:
    run_id: str
    kind: str
    value: str

    def as_sse_payload(self) -> str:
        return f"{self.run_id}:{self.kind}:{self.value}"
```

## 流式执行：RunHub、SSE 和事件回放

一个好的控制面，不应该只显示“最后结果”。真正有用的是能看到执行过程。MicroClaw 在这里用了一个很实用的设计：RunHub。

`web.rs` 中的 RunHub 会为每个运行维护：

- 广播通道
- 历史事件队列
- 事件 ID
- done 状态
- run owner

这让系统能通过 SSE 或 WebSocket 向前端持续推送：

- 迭代开始
- 工具启动
- 工具结果
- 文本增量
- 最终完成

更重要的是，它还支持 replay。也就是说，前端断线后重新订阅，不必从零开始丢掉所有中间状态。

这是一个典型的“runtime-first”设计。前端不是自己猜测执行进度，而是订阅统一循环发出的真实事件。

## 会话管理：控制面必须看得见状态

Web 控制面的另一个核心价值，是把持久化状态变成可查询对象。`sessions` 路由不仅负责列出历史，还在 RFC 中规划了 session fork 能力。

这类能力非常适合聊天型 runtime：

- 可以重放某条会话的上下文。
- 可以围绕某个分叉点创建探索分支。
- 可以让调试和实验不破坏主会话。

即便部分能力仍在演进中，方向已经非常明确：Web 不只是发消息界面，而是会话与运行状态的操作台。

## 配置自检：控制面不只是展示配置

`docs/operations/runbook.md` 和当前 API 设计都强调 `config self-check`。这类接口的价值远大于“把 YAML 原样显示在网页上”。

配置自检会帮助回答这些问题：

- 当前部署是否处于高风险姿态？
- 某些必要凭据是否缺失？
- sandbox 是否启用且可用？
- 某些策略是否处于危险默认值？

这意味着控制面承担了运行时治理职责，而不仅是配置浏览器。对于生产环境来说，这非常关键。因为很多事故不是代码写错，而是配置不安全、依赖不完整、权限开关误设。

## 控制面安全：鉴权、会话、速率限制

### 鉴权不能后补

`web.rs` 默认就把认证状态、登录节流和 API key 机制纳入主干。运行手册也明确提到：

- 可以用 `Authorization: Bearer <api-key-or-legacy-token>`
- 也可以用 `mc_session` cookie
- 登录会被节流

这说明 Web 控制面从一开始就按“需要保护的管理接口”设计，而不是先裸奔、后加登录页。

### 请求配额和并发限制

`WebLimits` 和 `RequestHub` 进一步提供：

- 每 session 最大并发
- 窗口内请求数量
- session idle TTL
- run history limit

这类限制非常务实。控制面面对的不是互联网海量流量，但它同样需要防止：

- 用户或脚本误触发大量并发请求
- 长时间挂住的 session 占满资源
- 流式运行历史无界增长

### 默认密码不是长期策略

源码里存在 `DEFAULT_WEB_PASSWORD`，这本身就是一个提醒：启动引导和长期安全姿态不是一回事。真正可托管的部署必须尽快完成密码重置、会话吊销和 API key 管理，而不能长期依赖引导态。

## 可观测接口：控制面与观测面必须统一口径

Web 控制面的另一个价值，是把观测信息直接暴露出来。当前至少已有：

- `/api/metrics`
- `/api/metrics/summary`
- `/api/metrics/history`

其中 `/api/metrics/summary` 还暴露了显式 SLO 结构。这意味着前端不是自己从原始计数器拼装“健康度”，而是和后端共享同一套指标解释。

这类统一口径非常重要。否则前端会有一套“看起来健康”的解释，运维脚本又有另一套解释，最终谁都不相信谁。

## Web 控制面为什么仍然属于 runtime，而不是独立服务

很多团队在这一步会选择把 UI 和 API 独立成另一个服务。MicroClaw 当前没有这样做，而是把 Web 保持在单进程内。

这样做的收益是：

- 部署简单
- 能直接访问共享 `AppState`
- 不需要再为控制面复制一套状态读取逻辑
- 流式执行与实时事件天然更近

代价当然也存在：

- Web bug 可能影响主进程
- 单进程职责继续增加
- 权限和资源边界必须更谨慎

但对单机优先产品阶段而言，这仍是非常合理的选择。

```{=typst}
#pagebreak(weak: true)
```

## 示例代码：为什么流式控制面必须暴露运行事件，而不是只返回最终答案？

流式接口最重要的不是框架语法，而是它必须把统一循环里的中间事件稳定暴露给控制面。只有这样，前端和运维人员才能判断系统究竟卡在模型、工具还是审批上。

Rust 版本把事件输出收敛到 `EventSink` trait，再由一个 `RunStreamer` 负责按顺序推送关键阶段。这样控制面依赖的是运行事件语义，而不是某个 Web 框架的偶然写法。

```rust
#[async_trait::async_trait]
trait EventSink {
    async fn send(&self, event: &str) -> anyhow::Result<()>;
}

struct RunStreamer<S> {
    sink: S,
}

impl<S: EventSink> RunStreamer<S> {
    async fn stream_run(&self) -> anyhow::Result<()> {
        self.sink.send("iteration:1").await?;
        self.sink.send("tool_start:bash").await?;
        self.sink.send("final_response:done").await?;
        Ok(())
    }
}
```

Python 版本保留同样的接口语义，但用 `Protocol` 和 `@dataclass` 把责任边界写清楚。这样即使你换成别的异步 Web 框架，控制面仍然是在消费稳定的运行事件，而不是框架专属对象。

```python
from dataclasses import dataclass
from typing import Protocol


class EventSink(Protocol):
    async def send(self, event: str) -> None: ...


@dataclass
class RunStreamer:
    sink: EventSink

    async def stream_run(self) -> None:
        await self.sink.send("iteration:1")
        await self.sink.send("tool_start:bash")
        await self.sink.send("final_response:done")
```

## 关键权衡

### 决策一：把 Web 视为特殊渠道接入统一 runtime

优点是共享主链路与会话体系。代价是要额外定义 Web 与普通外部渠道不同的权限姿态。

### 决策二：用 RunHub 承载流式执行状态

优点是前端能真实观察执行过程，并支持 replay。代价是需要维护运行历史、订阅权限和清理策略。

### 决策三：控制面按运维域组织路由

优点是 API 结构更稳定。代价是新增能力时要先思考它属于哪个领域，而不是随手加 endpoint。

### 决策四：鉴权、节流、自检默认纳入主干

优点是控制面更早具备托管价值。代价是前期实现成本更高，调试也更复杂。

## 容易走错的地方

### 失败模式 1：把 Web 当成单纯聊天前端

这样会低估它在会话管理、配置治理和观测上的职责。

### 失败模式 2：前端自己拼健康度，后端只给原始数据

这会导致口径漂移，最终无法形成稳定运维标准。

### 失败模式 3：控制面上线后再补鉴权和速率限制

到那时通常已经形成了不安全的默认用法和外部依赖。

## 读到这里，你应该能回答

- 你是否理解 Web 在 MicroClaw 中是特殊渠道，而不是普通 UI 外壳？
- 你是否按运维职责组织 API，而不是按页面临时需求堆接口？
- 你是否为流式执行设计了真实事件源和 replay 语义？
- 你是否把鉴权、节流和配置自检纳入控制面基线？

## 证据来源（v0.1.16 / 95491b7）

- 源码基线：<https://github.com/microclaw/microclaw/tree/95491b787a61a71f43aeb6556c695a3bd1c006ce>
- 核心源码路径：`src/web.rs`、`src/web`、`src/runtime.rs`、`src/agent_engine.rs`
- 关键配置项：`src/config.rs` 中与 `web_enabled`、`web_port`、控制面鉴权和流式事件相关的默认值
- 测试 / 运行文档路径：`README.md`（`Local Web UI (cross-channel history)`, `HTTP Request Trigger (headless automation)`, `Configuration`）；`docs/rfcs/0001-authn-authz-model.md`（`API Surface`, `Security Considerations`, `Testing Plan`）；`docs/observability/metrics.md`（`Endpoints`, `SLO Contract (`/api/metrics/summary`)`）；`TEST.md`（`25. Gateway Service Management`）

## 小结

MicroClaw 的 Web 与 API 设计说明了一件事：控制面不是附加组件，而是 runtime 可托管性的组成部分。它让系统不只“能运行”，还“能被看见、被配置、被限制、被自动化接入”。这也是从个人 bot 迈向工程系统的关键一步。

下一章我们进入最后一个内核主题：MCP、Skills 和 Plugins。它们决定了这个 runtime 不只是能运行自身能力，还能怎样在不破坏主链路的前提下持续吸收外部能力。

## 图表清单

如果你打算把本章整理成演示、课程或配图版文章，下面三张图最值得保留。

- 图 11-1：Web 控制面在 runtime 中的位置
- 图 11-2：RunHub 事件流与 SSE/WS 关系
- 图 11-3：按运维域组织的 API 路由图
