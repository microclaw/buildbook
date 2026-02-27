.PHONY: pdf typ clean check

pdf:
	./scripts/build-book.sh

typ:
	pandoc --from markdown --to typst --metadata-file book/build/metadata.yaml --standalone \
		book/00-项目总览.md book/01-全书目录.md \
		book/chapters/part-1-foundation/ch01-为什么是-microclaw.md \
		book/chapters/part-1-foundation/ch02-系统全景.md \
		book/chapters/part-1-foundation/ch03-领域模型与数据流.md \
		book/chapters/part-1-foundation/ch04-技术选型方法论.md \
		book/chapters/part-2-kernel/ch05-项目骨架与工程基线.md \
		book/chapters/part-2-kernel/ch06-agent-engine-统一循环.md \
		book/chapters/part-2-kernel/ch07-工具系统.md \
		book/chapters/part-2-kernel/ch08-记忆系统.md \
		book/chapters/part-2-kernel/ch09-多渠道架构.md \
		book/chapters/part-2-kernel/ch10-调度与后台任务.md \
		book/chapters/part-2-kernel/ch11-web-与-api.md \
		book/chapters/part-2-kernel/ch12-mcp-skills-plugins.md \
		book/chapters/part-3-production/ch13-安全体系.md \
		book/chapters/part-3-production/ch14-可观测性与运维.md \
		book/chapters/part-3-production/ch15-测试策略.md \
		book/chapters/part-3-production/ch16-性能与成本优化.md \
		book/chapters/part-3-production/ch17-架构演进.md \
		book/chapters/part-3-production/ch18-综合实战.md \
		book/appendices/appendix-a-能力矩阵.md \
		book/appendices/appendix-b-源码导读索引.md \
		book/appendices/appendix-c-实施模板.md \
		-o dist/book.typ

check:
	@which pandoc >/dev/null || (echo "pandoc not found" && exit 1)
	@which typst >/dev/null || (echo "typst not found" && exit 1)
	@echo "build toolchain ready"

clean:
	find dist -type f -delete
