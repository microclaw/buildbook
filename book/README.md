# Buildbook

## Files

1. `00-目录.md`：全书目录。
2. `chapters/`：逐章稿件。
3. `从零构建MicroClaw.md`：合并后的整书稿。
4. `从零构建MicroClaw-typst.pdf`：当前推荐导出的 PDF（中文可读）。

## Export PDF (Recommended: Typst)

```bash
cd /Users/eevv/focus/buildbook/book
{
  echo '# 从零构建MicroClaw'
  echo ''
  for f in \
    chapters/ch01-为什么是microclaw.md \
    chapters/ch02-架构总览.md \
    chapters/ch03-agent-loop全景.md \
    chapters/ch04-agent-loop深潜.md \
    chapters/ch05-工具系统设计.md \
    chapters/ch06-安全机制.md \
    chapters/ch07-sandbox机制.md \
    chapters/ch08-记忆系统.md \
    chapters/ch09-todo与计划执行.md \
    chapters/ch10-定时任务系统.md \
    chapters/ch11-多渠道适配层.md \
    chapters/ch12-web控制面与可观测性.md \
    chapters/ch13-配置体系与设计决策.md \
    chapters/ch14-从代码到发布.md \
    chapters/ch15-源码结构化导读.md \
    chapters/ch16-安全深水区.md \
    chapters/ch17-sandbox实战与攻防.md \
    chapters/ch18-agent-loop案例工坊.md \
    chapters/ch19-配置项设计百科.md \
    chapters/ch20-事故复盘与演练.md \
    chapters/ch21-全书总结.md \
    chapters/ch22-实战练习题库.md \
    chapters/ch23-设计决策备忘录.md \
    chapters/appendices.md; do
    cat "$f"
    echo ''
  done
} > _export.md

# Fix image paths for merged export file
sed -i '' 's#../assets/#assets/#g' _export.md

pandoc _export.md -o 从零构建MicroClaw-typst.pdf \
  --pdf-engine=typst \
  --toc \
  --number-sections \
  -V mainfont="PingFang SC" \
  -V fontsize=16pt \
  -V papersize=a5
```

## Page Count

```bash
python3 - <<'PY'
from pypdf import PdfReader
r = PdfReader('从零构建MicroClaw-typst.pdf')
print('pages =', len(r.pages))
PY
```
