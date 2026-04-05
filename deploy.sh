#!/usr/bin/env bash
# deploy.sh — 一键构建 HTML (GitHub Pages) + PDF + EPUB 三种格式
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

DIST_DIR="dist"
HTML_DIR="$DIST_DIR/html"
PDF_FILE="$DIST_DIR/book.pdf"
EPUB_FILE="$DIST_DIR/book.epub"
TYP_FILE="$DIST_DIR/book.typ"
COVER_IMAGE="surface.png"

# ── 颜色输出 ──────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 依赖检查 ──────────────────────────────────────────────
check_deps() {
  info "检查构建依赖..."
  local missing=()

  command -v mdbook   >/dev/null || missing+=("mdbook  — cargo install mdbook")
  command -v pandoc   >/dev/null || missing+=("pandoc  — brew install pandoc")
  command -v typst    >/dev/null || missing+=("typst   — brew install typst")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "缺少以下工具:\n$(printf '  • %s\n' "${missing[@]}")"
  fi

  info "依赖检查通过"
}

# ── 清理 ──────────────────────────────────────────────────
clean() {
  info "清理旧构建产物..."
  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR"
}

# ── 构建 HTML (mdBook) ────────────────────────────────────
build_html() {
  info "构建 HTML (mdBook)..."

  # 确保 mdbook-src 的符号链接完好
  cd "$ROOT_DIR/mdbook-src"
  [[ -L chapters   ]] || ln -sf ../chapters   chapters
  [[ -L appendices ]] || ln -sf ../appendices appendices
  [[ -L assets     ]] || ln -sf ../assets     assets
  cd "$ROOT_DIR"

  mdbook build

  info "HTML 构建完成 → $HTML_DIR"
}

# ── 构建 PDF (Pandoc + Typst) ─────────────────────────────
build_pdf() {
  info "构建 PDF (Pandoc → Typst → PDF)..."

  local INPUTS=(
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

  # 检查输入文件
  for f in "${INPUTS[@]}"; do
    [[ -f "$f" ]] || error "缺少输入文件: $f"
  done

  # Pandoc → Typst
  pandoc \
    --from markdown \
    --to typst \
    --metadata-file build/metadata.yaml \
    --standalone \
    "${INPUTS[@]}" \
    -o "$TYP_FILE"

  # 后处理：目录标题改中文
  python3 - <<'PY'
from pathlib import Path
p = Path("dist/book.typ")
t = p.read_text()
t = t.replace("#outline(\n  title: auto,", "#outline(\n  title: [目录],", 1)
p.write_text(t)
PY

  # 插入封面和主题
  local TMP_TYP
  TMP_TYP="$(mktemp)"
  {
    echo '#import "/theme/book-theme.typ": *'
    echo '#set page(margin: 0pt)'
    echo '#image("/surface.png", width: 100%, height: 100%)'
    echo '#pagebreak()'
    echo '#set page(margin: (top: 24mm, bottom: 24mm, left: 22mm, right: 22mm), numbering: "1")'
    echo
    cat "$TYP_FILE"
  } > "$TMP_TYP"
  mv "$TMP_TYP" "$TYP_FILE"

  # Typst → PDF
  typst compile --root "$ROOT_DIR" "$TYP_FILE" "$PDF_FILE"

  info "PDF 构建完成 → $PDF_FILE"
}

# ── 构建 EPUB (Pandoc) ───────────────────────────────────
build_epub() {
  info "构建 EPUB (Pandoc)..."

  local INPUTS=(
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

  local EPUB_ARGS=(
    --from markdown
    --to epub3
    --metadata-file build/metadata.yaml
    --toc
    --toc-depth=3
    --split-level=1
    --css=build/epub.css
  )

  # 如果有封面图则加入
  if [[ -f "$COVER_IMAGE" ]]; then
    EPUB_ARGS+=(--epub-cover-image="$COVER_IMAGE")
  fi

  # 章节中的图片路径以 ../assets/ 开头（相对于 chapters/ 子目录），
  # Pandoc 从根目录运行时需要 --resource-path 指向 chapters 的父目录
  pandoc "${EPUB_ARGS[@]}" \
    --resource-path="chapters/part-1-foundation:chapters/part-2-kernel:chapters/part-3-production:appendices:." \
    "${INPUTS[@]}" -o "$EPUB_FILE"

  info "EPUB 构建完成 → $EPUB_FILE"
}

# ── 将 PDF/EPUB 复制到 HTML 输出目录供下载 ─────────────────
copy_downloads() {
  info "将 PDF/EPUB 复制到 HTML 下载目录..."
  local DL_DIR="$HTML_DIR/downloads"
  mkdir -p "$DL_DIR"

  [[ -f "$PDF_FILE"  ]] && cp "$PDF_FILE"  "$DL_DIR/book.pdf"
  [[ -f "$EPUB_FILE" ]] && cp "$EPUB_FILE" "$DL_DIR/book.epub"

  info "下载文件就绪 → $DL_DIR/"
}

# ── 构建报告 ──────────────────────────────────────────────
report() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "全部构建完成"
  echo ""

  if [[ -d "$HTML_DIR" ]]; then
    local html_size
    html_size=$(du -sh "$HTML_DIR" | cut -f1)
    echo "  HTML (GitHub Pages) : $HTML_DIR ($html_size)"
  fi

  if [[ -f "$PDF_FILE" ]]; then
    local pdf_size
    pdf_size=$(du -sh "$PDF_FILE" | cut -f1)
    echo "  PDF                 : $PDF_FILE ($pdf_size)"
  fi

  if [[ -f "$EPUB_FILE" ]]; then
    local epub_size
    epub_size=$(du -sh "$EPUB_FILE" | cut -f1)
    echo "  EPUB                : $EPUB_FILE ($epub_size)"
  fi

  echo ""
  echo "  本地预览 HTML: mdbook serve"
  echo "  部署到 GitHub Pages: git push (CI 自动部署)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── 主流程 ────────────────────────────────────────────────
main() {
  local target="${1:-all}"

  case "$target" in
    all)
      check_deps
      clean
      build_html
      build_pdf
      build_epub
      copy_downloads
      report
      ;;
    html)
      check_deps
      build_html
      ;;
    pdf)
      check_deps
      build_pdf
      ;;
    epub)
      check_deps
      build_epub
      ;;
    clean)
      clean
      info "清理完成"
      ;;
    *)
      echo "用法: $0 [all|html|pdf|epub|clean]"
      echo ""
      echo "  all   — 构建全部三种格式（默认）"
      echo "  html  — 仅构建 HTML (mdBook)"
      echo "  pdf   — 仅构建 PDF (Pandoc + Typst)"
      echo "  epub  — 仅构建 EPUB (Pandoc)"
      echo "  clean — 清理构建产物"
      exit 1
      ;;
  esac
}

main "$@"
