#!/usr/bin/env bash
# 草稿 → content/posts/ → 建分支推送 → 开 PR（不合并，合并动作留给人）
# 用法：scripts/publish-pr.sh [drafts/2026-09-25-slug.md]
#   省略参数时取 drafts/ 下最新修改的那个 .md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export https_proxy="${https_proxy:-http://127.0.0.1:7892}"
export http_proxy="${http_proxy:-http://127.0.0.1:7892}"
export GIT_TERMINAL_PROMPT=0

TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:?需要 GITHUB_PERSONAL_ACCESS_TOKEN}"
REMOTE_URL="$(git remote get-url origin)"
OWNER_REPO="$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"

DRAFT="${1:-$(ls -t drafts/*.md 2>/dev/null | head -1 || true)}"
[ -n "$DRAFT" ] && [ -f "$DRAFT" ] || { echo "找不到草稿文件：${DRAFT:-drafts/ 下没有 .md}" >&2; exit 1; }

BASE="$(basename "$DRAFT")"
SLUG="$(echo "${BASE%.md}" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')"
[ -n "$SLUG" ] || { echo "无法从文件名推导 slug：$BASE" >&2; exit 1; }

TITLE="$(grep -m1 '^title:' "$DRAFT" | sed -E 's/^title:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//')"
[ -n "$TITLE" ] || TITLE="$SLUG"

BRANCH="post/$SLUG"
TARGET="content/posts/$SLUG/index.md"

echo "草稿   : $DRAFT"
echo "标题   : $TITLE"
echo "分支   : $BRANCH"
echo "目标   : $TARGET"

if [ -n "$(git status --porcelain)" ]; then
  echo "工作区不干净，先提交或 stash（避免把无关改动混进 PR）：" >&2
  git status --short >&2
  exit 1
fi

git fetch -q origin main
git switch -q -c "$BRANCH" origin/main 2>/dev/null || git switch -q "$BRANCH"

mkdir -p "$(dirname "$TARGET")"
cp "$DRAFT" "$TARGET"

git add "$TARGET"
git -c user.name="$(git config --global user.name)" -c user.email="$(git config --global user.email)" \
  commit -q -m "post: $TITLE"
GIT_TERMINAL_PROMPT=0 git push -q -u origin "$BRANCH"

PR_BODY=$(python3 - "$TITLE" "$DRAFT" <<'EOF'
import sys
title, draft = sys.argv[1], sys.argv[2]
print(f"""## 文章

**{title}**

来源草稿：`{draft}` → `content/posts/`

## 合并前检查

- [ ] frontmatter 只含 title / date / tags / author 四个字段
- [ ] 正文里的命令、输出都是实际执行过的
- [ ] 没有 token、密钥、内网地址等敏感内容
- [ ] tags 用词与既有文章一致

合并到 main 后由 Actions 自动构建并部署到 Pages。
""")
EOF
)

PR_JSON=$(python3 - "$TOKEN" "$OWNER_REPO" "$TITLE" "$BRANCH" "$PR_BODY" <<'EOF'
import json, sys, urllib.request
token, repo, title, head, body = sys.argv[1:6]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/pulls",
    data=json.dumps({"title": f"post: {title}", "head": head, "base": "main", "body": body}).encode(),
    headers={"Authorization": f"token {token}", "Accept": "application/vnd.github+json",
             "Content-Type": "application/json", "User-Agent": "hermes-publisher"},
    method="POST")
try:
    with urllib.request.urlopen(req, timeout=40) as r:
        d = json.load(r)
    print(json.dumps({"number": d["number"], "url": d["html_url"], "state": d["state"],
                      "head": d["head"]["ref"], "base": d["base"]["ref"]}))
except urllib.error.HTTPError as e:
    print(json.dumps({"error": e.code, "body": e.read().decode()[:400]}))
EOF
)

echo "PR: $PR_JSON"
python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print('PR 已创建：', d.get('url') or d) if 'url' in d else print('创建 PR 失败：', d)
" "$PR_JSON"

echo
echo "下一步：复核 PR diff，然后合并（合并即发布）："
echo "  git switch main && git pull && git merge --no-ff $BRANCH && git push"
