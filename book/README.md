# Buildbook

## Files

1. `00-目录.md`：全书目录。
2. `chapters/`：逐章稿件。
3. `从零构建MicroClaw.md`：合并后的整书稿。

## Export PDF (Pandoc)

```bash
cd /Users/eevv/focus/buildbook/book
pandoc 从零构建MicroClaw.md -o 从零构建MicroClaw.pdf \
  --toc \
  --number-sections \
  -V CJKmainfont="PingFang SC" \
  -V geometry:margin=2.2cm
```

## Page Counting (Preview)

```bash
pdfinfo 从零构建MicroClaw.pdf | rg Pages
```
