#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

OUT_DIR="dist"
BOOK_TYP="$OUT_DIR/book.typ"
BOOK_PDF="$OUT_DIR/book.pdf"
COVER_IMAGE="surface.png"

mkdir -p "$OUT_DIR"

INPUTS=(
  "00-项目总览.md"
  "01-全书目录.md"
  "chapters/part-1-foundation/ch01-为什么是-microclaw.md"
  "chapters/part-1-foundation/ch02-系统全景.md"
  "chapters/part-1-foundation/ch03-领域模型与数据流.md"
  "chapters/part-1-foundation/ch04-技术选型方法论.md"
  "chapters/part-2-kernel/ch05-项目骨架与工程基线.md"
  "chapters/part-2-kernel/ch06-agent-engine-统一循环.md"
  "chapters/part-2-kernel/ch07-工具系统.md"
  "chapters/part-2-kernel/ch08-记忆系统.md"
  "chapters/part-2-kernel/ch09-多渠道架构.md"
  "chapters/part-2-kernel/ch10-调度与后台任务.md"
  "chapters/part-2-kernel/ch11-web-与-api.md"
  "chapters/part-2-kernel/ch12-mcp-skills-plugins.md"
  "chapters/part-3-production/ch13-安全体系.md"
  "chapters/part-3-production/ch14-可观测性与运维.md"
  "chapters/part-3-production/ch15-测试策略.md"
  "chapters/part-3-production/ch16-性能与成本优化.md"
  "chapters/part-3-production/ch17-架构演进.md"
  "chapters/part-3-production/ch18-综合实战.md"
  "appendices/appendix-a-能力矩阵.md"
  "appendices/appendix-b-源码导读索引.md"
  "appendices/appendix-c-实施模板.md"
  "appendices/appendix-d-最小实现主线.md"
)

for f in "${INPUTS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing input file: $f" >&2
    exit 1
  fi
done

if [[ ! -f "$COVER_IMAGE" ]]; then
  echo "Missing cover image: $COVER_IMAGE" >&2
  exit 1
fi

pandoc \
  --from markdown \
  --to typst \
  --metadata-file build/metadata.yaml \
  --standalone \
  "${INPUTS[@]}" \
  -o "$BOOK_TYP"

python3 - <<'PY'
from pathlib import Path

book_typ = Path("dist/book.typ")
text = book_typ.read_text()
text = text.replace("#outline(\n  title: auto,", "#outline(\n  title: [目录],", 1)
book_typ.write_text(text)
PY

TMP_TYP="$(mktemp)"
{
  echo '#import "/theme/book-theme.typ": *'
  echo '#set page(margin: 0pt)'
  echo '#image("/surface.png", width: 100%, height: 100%)'
  echo '#pagebreak()'
  echo '#set page(margin: (top: 24mm, bottom: 24mm, left: 22mm, right: 22mm), numbering: "1")'
  echo
  cat "$BOOK_TYP"
} > "$TMP_TYP"
mv "$TMP_TYP" "$BOOK_TYP"

typst compile --root "$ROOT_DIR" "$BOOK_TYP" "$BOOK_PDF"

echo "Built: $BOOK_PDF"
