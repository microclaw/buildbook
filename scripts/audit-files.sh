#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# 允许保留的文件模式（路径相对仓库根目录）
ALLOWED_REGEX='^(README\.md|AGENTS\.md|Makefile|\.gitignore|surface\.png|scripts/(build-book\.sh|audit-files\.sh)|(00-项目总览|01-全书目录|02-写作规范|03-写作路线图|04-进度看板|05-出版构建|06-封面设计-prompt)\.md|build/metadata\.yaml|theme/book-theme\.typ|chapters/part-1-foundation/[^/]+\.md|chapters/part-2-kernel/[^/]+\.md|chapters/part-3-production/[^/]+\.md|appendices/[^/]+\.md|research/compare/[^/]+\.md)$'

UNKNOWN=()
while IFS= read -r f; do
  if [[ ! "$f" =~ $ALLOWED_REGEX ]]; then
    UNKNOWN+=("$f")
  fi
done < <(find . -type f \
  -not -path './.git/*' \
  -not -path './dist/*' \
  | sed 's#^\./##' \
  | sort)

if [[ ${#UNKNOWN[@]} -gt 0 ]]; then
  echo "[audit] Found files outside allowed scope:" >&2
  for f in "${UNKNOWN[@]}"; do
    echo "  - $f" >&2
  done
  echo "[audit] Please delete, move, or update scripts/audit-files.sh allowlist." >&2
  exit 1
fi

echo "[audit] OK: all files are within allowed scope."
