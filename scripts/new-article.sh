#!/usr/bin/env bash
# 新建一篇草稿：从 templates/article-template.md 复制到 drafts/YYYY-MM-DD-slug.md
# 用法：scripts/new-article.sh "文章标题" [slug]
#   slug 省略时用日期 + 时间戳兜底，创建后自己改名即可。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$ROOT/templates/article-template.md"
[ -f "$TPL" ] || { echo "找不到模板：$TPL" >&2; exit 1; }

TITLE="${1:-}"
[ -n "$TITLE" ] || { echo "用法：scripts/new-article.sh \"文章标题\" [slug]" >&2; exit 1; }

SLUG="${2:-$(date +%H%M%S)}"
DATE="$(date +%Y-%m-%d)"
FILE="$ROOT/drafts/${DATE}-${SLUG}.md"

[ -e "$FILE" ] && { echo "已存在，未覆盖：$FILE" >&2; exit 1; }

sed -e "s/^title: .*/title: ${TITLE}/" \
    -e "s/^date: .*/date: ${DATE}/" \
    "$TPL" > "$FILE"

echo "已创建：$FILE"
echo "下一步：编辑正文 → 审核(status: review) → 发布 → 移到 published/ 并更新 README 索引"
