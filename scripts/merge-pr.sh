#!/usr/bin/env bash
# 合并 PR 并核验（main 已开分支保护：enforce_admins=true，只能通过 PR 合并，直接 push 会被 GH006 拒绝）
# 用法：scripts/merge-pr.sh <PR号> [--keep-branch]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export https_proxy="${https_proxy:-http://127.0.0.1:7892}"
export http_proxy="${http_proxy:-http://127.0.0.1:7892}"
export GIT_TERMINAL_PROMPT=0

TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:?需要 GITHUB_PERSONAL_ACCESS_TOKEN}"
OWNER_REPO="$(git remote get-url origin | sed -E 's|.*github\.com[:/]||; s|\.git$||')"

PR="${1:-}"
[ -n "$PR" ] || { echo "用法：scripts/merge-pr.sh <PR号> [--keep-branch]" >&2; exit 1; }
KEEP_BRANCH="${2:-}"

python3 - "$TOKEN" "$OWNER_REPO" "$PR" "$KEEP_BRANCH" <<'EOF'
import json, sys, urllib.request, urllib.error

token, repo, pr, keep = sys.argv[1:5]
H = {"Authorization": f"token {token}", "Accept": "application/vnd.github+json",
     "Content-Type": "application/json", "User-Agent": "hermes-publisher"}
API = f"https://api.github.com/repos/{repo}"


def call(method, path, payload=None):
    req = urllib.request.Request(API + path,
                                 data=json.dumps(payload).encode() if payload is not None else None,
                                 headers=H, method=method)
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            body = r.read().decode()
            return r.status, (json.loads(body) if body.strip() else {})
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:300]}


_, before = call("GET", f"/pulls/{pr}")
print(f"PR #{pr}: {before.get('title')}")
print(f"  state={before.get('state')} mergeable_state={before.get('mergeable_state')} "
      f"head={before.get('head', {}).get('ref')} base={before.get('base', {}).get('ref')} "
      f"+{before.get('additions')}/-{before.get('deletions')} files={before.get('changed_files')}")
if before.get("state") != "open":
    sys.exit(f"PR #{pr} 不是 open 状态，终止")

status, res = call("PUT", f"/pulls/{pr}/merge", {"merge_method": "merge"})
print(f"  merge 接口 -> {status} merged={res.get('merged')} {res.get('message', res.get('error', ''))}")
if not res.get("merged"):
    sys.exit("合并失败")

_, after = call("GET", f"/pulls/{pr}")
print(f"  核验: state={after.get('state')} merged={after.get('merged')} "
      f"merge_commit={str(after.get('merge_commit_sha'))[:8]} merged_at={after.get('merged_at')}")

head = before.get("head", {}).get("ref", "")
if keep != "--keep-branch" and head and head != "main":
    st, _ = call("DELETE", f"/git/refs/heads/{head}")
    print(f"  删除已合并分支 {head} -> {st} (204=成功)")

_, commits = call("GET", "/commits?per_page=1")
if commits:
    c = commits[0]
    print(f"  main 最新提交: {c['sha'][:8]} {c['commit']['message'].splitlines()[0][:70]}")
print("下一步：等 Actions 部署完（GET /actions/runs?per_page=1 看 conclusion），再 curl 线上页面确认")
EOF

git fetch -q origin main
echo "本地 main 与远端同步: $(git rev-parse --short origin/main)"
