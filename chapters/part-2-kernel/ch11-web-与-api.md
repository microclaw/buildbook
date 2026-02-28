# Chapter 11 Web 与 API

## 条目列表
- 规划 Web API 路由边界：auth、sessions、config、metrics、stream。
- 规划流式输出协议（SSE/WebSocket）的事件格式。
- 规划控制面安全：会话、API key、审计日志。
- 规划可观测页面与接口的一致口径。

## 关键词
- Control Plane
- SSE
- API Key
- 审计日志
- 指标接口

## 参考链接
- [出版构建](../../05-出版构建.md)
- [MicroClaw vs Moltis](../../research/compare/03-microclaw-vs-moltis.md)
- [MDN Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)

## 写作思路
- 先按路由域划分职责，再展开鉴权与流式传输细节。
- 把“控制面安全”作为主线而非附录内容。
- 用可观测接口统一口径，确保前后端理解一致。

## 资料来源
- https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events
- https://github.com/moltis-org/moltis/blob/main/README.md
- [MicroClaw vs Moltis](../../research/compare/03-microclaw-vs-moltis.md)
