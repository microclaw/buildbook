#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

OUT_DIR="dist"
BOOK_TYP="$OUT_DIR/book.typ"
BOOK_PDF="$OUT_DIR/book.pdf"

mkdir -p "$OUT_DIR"

INPUTS=(
  "book/00-项目总览.md"
  "book/01-全书目录.md"
  "book/chapters/part-1-foundation/ch01-为什么是-microclaw.md"
  "book/chapters/part-1-foundation/ch02-系统全景.md"
  "book/chapters/part-1-foundation/ch03-领域模型与数据流.md"
  "book/chapters/part-1-foundation/ch04-技术选型方法论.md"
  "book/chapters/part-2-kernel/ch05-项目骨架与工程基线.md"
  "book/chapters/part-2-kernel/ch06-agent-engine-统一循环.md"
  "book/chapters/part-2-kernel/ch07-工具系统.md"
  "book/chapters/part-2-kernel/ch08-记忆系统.md"
  "book/chapters/part-2-kernel/ch09-多渠道架构.md"
  "book/chapters/part-2-kernel/ch10-调度与后台任务.md"
  "book/chapters/part-2-kernel/ch11-web-与-api.md"
  "book/chapters/part-2-kernel/ch12-mcp-skills-plugins.md"
  "book/chapters/part-3-production/ch13-安全体系.md"
  "book/chapters/part-3-production/ch14-可观测性与运维.md"
  "book/chapters/part-3-production/ch15-测试策略.md"
  "book/chapters/part-3-production/ch16-性能与成本优化.md"
  "book/chapters/part-3-production/ch17-架构演进.md"
  "book/chapters/part-3-production/ch18-综合实战.md"
  "book/appendices/appendix-a-能力矩阵.md"
  "book/appendices/appendix-b-源码导读索引.md"
  "book/appendices/appendix-c-实施模板.md"
)

for f in "${INPUTS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing input file: $f" >&2
    exit 1
  fi
done

pandoc \
  --from markdown \
  --to typst \
  --metadata-file book/build/metadata.yaml \
  --standalone \
  "${INPUTS[@]}" \
  -o "$BOOK_TYP"

TMP_TYP="$(mktemp)"
{
  echo '#import "/book/theme/book-theme.typ": *'
  echo
  cat "$BOOK_TYP"
} > "$TMP_TYP"
mv "$TMP_TYP" "$BOOK_TYP"

typst compile --root "$ROOT_DIR" "$BOOK_TYP" "$BOOK_PDF"

echo "Built: $BOOK_PDF"
