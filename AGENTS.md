# AGENTS.md

## 项目定位

本仓库用于写作并发布技术书《从零构建 MicroClaw》。
采用 `Markdown + Pandoc + Typst` 构建链路。

核心目标：
- 维护高质量书稿源码。
- 保持仓库结构稳定、可审计、可重复构建。
- 禁止无用途文件进入版本库。

## 目录约束

根目录关键文件：
- `00-项目总览.md`
- `01-全书目录.md`
- `02-写作规范.md`
- `03-写作路线图.md`
- `04-进度看板.md`
- `05-出版构建.md`
- `06-封面设计-prompt.md`
- `README.md`
- `Makefile`
- `.gitignore`

正文与资料目录：
- `chapters/part-1-foundation/`
- `chapters/part-2-kernel/`
- `chapters/part-3-production/`
- `appendices/`
- `research/compare/`

构建配置与脚本：
- `build/metadata.yaml`
- `theme/book-theme.typ`
- `scripts/build-book.sh`
- `scripts/audit-files.sh`

构建产物目录：
- `dist/`（仅放生成物，不作为长期源码）

## 写作规则

- 章节结构以 `01-全书目录.md` 为唯一权威。
- 每章目前采用规划结构：
  - `条目列表`
  - `关键词`
  - `参考链接`
  - `写作思路`
  - `资料来源`
- 未经明确确认，不要擅自把“规划章”改为“正文章”。
- 对比研究仅存放在 `research/compare/`，正文引用后需重写，不直接复制。

## 构建与校验

常用命令：
```bash
make check
make audit
make pdf
make clean
```

说明：
- `make audit` 必须通过，才可继续提交。
- `make pdf` 生成 `dist/book.pdf`。
- `make clean` 清理 `dist/` 产物。

## 文件治理

以下文件应删除或忽略：
- 编辑器状态文件（如 `.obsidian/*`）
- 临时文件（如 `*.tmp`, `*.swp`）
- 无引用的草稿/重复文档

已忽略：
- `.DS_Store`
- `.obsidian/`
- `dist/`
- `*.swp`
- `*.tmp`

## 变更原则

- 优先修复路径、构建、审计一致性问题。
- 对目录结构调整后，必须同步更新：
  - `Makefile`
  - `scripts/build-book.sh`
  - `scripts/audit-files.sh`
  - `README.md`
  - `05-出版构建.md`
  - `AGENTS.md`
- 任何“新增文件类型/新增目录”都必须有明确用途，并更新审计规则。
