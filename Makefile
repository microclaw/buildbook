.PHONY: pdf typ clean check audit

pdf:
	./scripts/build-book.sh

typ:
	pandoc --from markdown --to typst --metadata-file build/metadata.yaml --standalone \
		00-项目总览.md 01-全书目录.md \
		chapters/part-1-foundation/ch01-为什么是-microclaw.md \
		chapters/part-1-foundation/ch02-系统全景.md \
		chapters/part-1-foundation/ch03-领域模型与数据流.md \
		chapters/part-1-foundation/ch04-技术选型方法论.md \
		chapters/part-2-kernel/ch05-项目骨架与工程基线.md \
		chapters/part-2-kernel/ch06-agent-engine-统一循环.md \
		chapters/part-2-kernel/ch07-工具系统.md \
		chapters/part-2-kernel/ch08-记忆系统.md \
		chapters/part-2-kernel/ch09-多渠道架构.md \
		chapters/part-2-kernel/ch10-调度与后台任务.md \
		chapters/part-2-kernel/ch11-web-与-api.md \
		chapters/part-2-kernel/ch12-mcp-skills-plugins.md \
		chapters/part-3-production/ch13-安全体系.md \
		chapters/part-3-production/ch14-可观测性与运维.md \
		chapters/part-3-production/ch15-测试策略.md \
		chapters/part-3-production/ch16-性能与成本优化.md \
		chapters/part-3-production/ch17-架构演进.md \
		chapters/part-3-production/ch18-综合实战.md \
		appendices/appendix-a-能力矩阵.md \
		appendices/appendix-b-源码导读索引.md \
		appendices/appendix-c-实施模板.md \
		-o dist/book.typ

check:
	@which pandoc >/dev/null || (echo "pandoc not found" && exit 1)
	@which typst >/dev/null || (echo "typst not found" && exit 1)
	@echo "build toolchain ready"

audit:
	./scripts/audit-files.sh

clean:
	find dist -type f -delete
