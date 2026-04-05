.PHONY: all html pdf epub clean check audit serve deploy

# 默认：构建全部三种格式
all:
	./deploy.sh all

# 单独构建 HTML (mdBook → GitHub Pages)
html:
	./deploy.sh html

# 单独构建 PDF (Pandoc → Typst → PDF)
pdf:
	./deploy.sh pdf

# 单独构建 EPUB (Pandoc → EPUB)
epub:
	./deploy.sh epub

# 本地预览（启动 mdBook 开发服务器）
serve:
	mdbook serve

# 依赖检查
check:
	@which mdbook  >/dev/null || (echo "mdbook not found  — cargo install mdbook" && exit 1)
	@which pandoc  >/dev/null || (echo "pandoc not found  — brew install pandoc" && exit 1)
	@which typst   >/dev/null || (echo "typst not found   — brew install typst" && exit 1)
	@echo "build toolchain ready"

# 文件审计
audit:
	./scripts/audit-files.sh

# 清理构建产物
clean:
	./deploy.sh clean
