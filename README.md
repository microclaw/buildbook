# Analyzing MicroClaw Book

本仓库是《剖析与实现 MicroClaw》书稿工程，采用 `Markdown + Pandoc + Typst` 流水线。

目标：只保留“写作与出版必须文件”，删除无源价值文件（临时文件、编辑器状态、可再生构建产物）。

版本基线：`microclaw/microclaw@95491b787a61a71f43aeb6556c695a3bd1c006ce`（`v0.1.16`）。

## 快速开始

```bash
cd /Users/eevv/focus/buildbook
make check
make audit
make pdf
```

构建产物默认输出到 `dist/`（已加入 `.gitignore`，不作为源码管理）。

## 仓库结构（全部有效文件）

### 根目录

- `README.md`：仓库总说明与文件治理规则
- `AGENTS.md`：仓库协作约束与执行规则
- `todo.md`：从写作到发布的执行清单
- `surface.png`：书籍封面图（PDF 首页）
- `Makefile`：一键命令入口（`check`/`audit`/`pdf`/`clean`）
- `.gitignore`：忽略编辑器与构建产物
- `scripts/build-book.sh`：主构建脚本（固定编译顺序）
- `scripts/audit-files.sh`：文件治理审计脚本（检测“无用途文件”）
- `assets/figures/*.svg`：正文图表资源

### 书稿控制文件（根目录）

- `00-项目总览.md`：范围定义（做什么/不做什么）
- `01-全书目录.md`：唯一权威目录
- `02-写作规范.md`：术语、证据、章节写法规范
- `03-写作路线图.md`：阶段推进计划
- `04-进度看板.md`：章节状态管理
- `05-出版构建.md`：构建与排版操作手册
- `06-封面设计-prompt.md`：封面生成提示词

### 排版与构建配置

- `build/metadata.yaml`：书籍元数据
- `theme/book-theme.typ`：Typst 版式主题

### 正文章节

- `chapters/part-1-foundation/*.md`：基础篇（Chapter 1-4）
- `chapters/part-2-kernel/*.md`：内核篇（Chapter 5-12）
- `chapters/part-3-production/*.md`：生产篇（Chapter 13-18）

### 附录

- `appendices/appendix-a-能力矩阵.md`
- `appendices/appendix-b-源码导读索引.md`
- `appendices/appendix-c-实施模板.md`
- `appendices/appendix-d-最小实现主线.md`

### 研究资料（仅用于写作参考）

- `research/compare/01-microclaw-vs-openclaw.md`
- `research/compare/02-microclaw-vs-nanoclaw.md`
- `research/compare/03-microclaw-vs-moltis.md`
- `research/compare/04-microclaw-vs-zeroclaw.md`
- `research/compare/05-microclaw-vs-nanobot.md`
- `research/compare/06-microclaw-vs-nullclaw.md`
- `research/compare/README.md`

## 文件治理规则

满足以下任一条件的文件会被删除：

1. 可由命令重新生成（如 `dist/*.pdf`、`dist/*.typ`）。
2. 仅包含编辑器本地状态（如 `.obsidian/*`）。
3. 与当前目录体系重复且无新增信息。
4. 无法被目录、章节或构建流程引用。

## 写作原则

1. 目录先行：章节结构以 `01-全书目录.md` 为准。
2. 证据先行：关键结论必须可追溯。
3. 工程先行：先讲架构决策，再讲实现细节。
4. 可落地先行：每章必须给出实践清单。

## 参与与反馈

- 上游仓库：<https://github.com/microclaw/microclaw>
- 如果项目或这本书对你有帮助，欢迎给 `microclaw/microclaw` 点一个 star。
- 如果你发现书稿、源码或构建链路中的问题，欢迎提交 issue。
- 如果你补充了修正、文档、图表或示例，欢迎提交 PR。
- 也欢迎关注我的其它作品：<https://github.com/everettjf>
