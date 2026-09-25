#!/usr/bin/env bash
# 草稿 → content/posts/ → 直接提交并推送到 master（不建分支、不开 PR）
# 用法：scripts/publish.sh [<草稿路径>]
#   - 草稿可以在仓库外（流水线的工作目录就是这种情况），会被一并复制进 drafts/ 归档
#   - 省略参数时取 drafts/ 下最新修改的那个 .md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export https_proxy="${https_proxy:-http://127.0.0.1:7892}"
export http_proxy="${http_proxy:-http://127.0.0.1:7892}"
export GIT_TERMINAL_PROMPT=0

BRANCH="master"
DRAFT="${1:-$(ls -t drafts/*.md 2>/dev/null | head -1 || true)}"
[ -n "$DRAFT" ] && [ -f "$DRAFT" ] || { echo "找不到草稿文件：${DRAFT:-drafts/ 下没有 .md}" >&2; exit 1; }

BASE="$(basename "$DRAFT")"
SLUG="$(echo "${BASE%.md}" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')"
[ -n "$SLUG" ] || { echo "无法从文件名推导 slug：$BASE" >&2; exit 1; }

TITLE="$(grep -m1 '^title:' "$DRAFT" | sed -E 's/^title:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')"
[ -n "$TITLE" ] || TITLE="$SLUG"

TARGET="content/posts/$SLUG/index.md"
REPO_DRAFT="drafts/$BASE"

echo "草稿   : $DRAFT"
echo "标题   : $TITLE"
echo "目标   : $TARGET"
echo "分支   : $BRANCH（直推，不建新分支）"

# 同步到远端最新，避免非快进
git fetch -q origin "$BRANCH"
git switch -q "$BRANCH" 2>/dev/null || git switch -q -c "$BRANCH" "origin/$BRANCH"
git pull -q --ff-only origin "$BRANCH"

mkdir -p "$(dirname "$TARGET")"
cp "$DRAFT" "$TARGET"
[ "$(cd "$(dirname "$DRAFT")" && pwd)/$BASE" != "$ROOT/$REPO_DRAFT" ] && cp "$DRAFT" "$REPO_DRAFT"

# 只提交这两个路径：工作区里与本篇无关的改动不会被带进去
git add "$TARGET" "$REPO_DRAFT"
git -c user.name="$(git config --global user.name)" \
    -c user.email="$(git config --global user.email)" \
    commit -q -m "post: $TITLE"

GIT_TERMINAL_PROMPT=0 git push -q origin "$BRANCH"

SHA="$(git rev-parse --short HEAD)"
echo "已推送：$SHA"
echo "远端核验（本地 HEAD 必须等于远端 master）："
echo "  local : $(git rev-parse HEAD)"
echo "  remote: $(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"
echo "Actions 构建部署约 1 分钟：https://zzzrrrhhh.github.io/tech-articles/"
