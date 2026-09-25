# tech-articles · 技术专栏

工程实践与排障记录。站点：**GitHub Pages + Hugo**（主题 PaperMod），线上地址
https://zzzrrrhhh.github.io/tech-articles/

- 仓库：https://github.com/zzzrrrhhh/tech-articles （public）
- 默认且**唯一**分支：`master`，推送到 `master` 后由 GitHub Actions 自动构建并部署
- 本地工作副本：`/Users/bl_osd/tech-articles`
- 发布方式是**直接在 `master` 上提交**：不建新分支、不开 PR；`master` 已关闭分支保护，可直接 push

## 目录结构

| 路径 | 用途 |
|---|---|
| `content/posts/<slug>/index.md` | **已发布文章**（唯一会被构建进站点的位置）。目录名即 URL 路径 |
| `drafts/YYYY-MM-DD-slug.md` | 未定稿草稿。不在 `content/` 下，**不会被部署**，可以随便改 |
| `assets/` | 配图与附件，文章内用相对路径引用 |
| `archetypes/default.md` | `hugo new` 用的原型 |
| `templates/article-template.md` | 手写新稿时复制的模板 |
| `scripts/new-article.sh` | 生成草稿到 `drafts/` |
| `scripts/publish.sh` | **标准发布**：草稿 → `content/posts/<slug>/index.md` → 提交并直推 `master` |
| `scripts/publish-pr.sh` | 遗留：走分支 + PR 的旧流程，当前不用（`master` 已无分支保护） |
| `scripts/merge-pr.sh` | 遗留：按 PR 号合并，当前不用 |
| `.github/workflows/hugo.yml` | 构建 + 部署 GitHub Pages（触发分支 `master`） |

## 文章格式

Markdown，frontmatter 固定四个字段：

```yaml
---
title: 打通本机 GitHub 推送：PAT、代理与 credential helper
date: 2026-09-25
tags: [github, git, 工程实践]
author: zhangronghui
---
```

- `date` 用 `YYYY-MM-DD`。
- 没有 `status` 字段：**是否已发布由位置决定**——在 `drafts/` 里就是草稿，进了 `content/posts/` 就是已发布（且只有进 `content/posts/` 的才会被构建）。
- `tags` 会驱动站点上的标签页，用词保持稳定，别每次换写法。

## 发布流程

1. `bash scripts/new-article.sh "文章标题" slug` 生成 `drafts/YYYY-MM-DD-slug.md`，写正文。
   （自动化流水线里草稿由上游步骤生成，可以放在仓库外——`publish.sh` 会把它一并归档进 `drafts/`）
2. 审核通过后：`bash scripts/publish.sh <草稿路径>`
   该脚本复制到 `content/posts/<slug>/index.md`、归档草稿、提交，并**直接推送 `master`**（不建分支、不开 PR）。
3. 推送后 GitHub Actions 自动 `hugo --minify` 构建并部署到 Pages，通常 1 分钟内生效。

> 部署只由 `master` 的 push 触发，所以「push 到 `master`」就是发布动作。
> 仓库只保留 `master` 一个分支；`master` 已关闭分支保护，允许直接 push（不再需要 PR）。

## 本地预览（可选）

```bash
brew install hugo            # 需要 extended 版（brew 默认即是）
cd /Users/bl_osd/tech-articles
hugo server -D               # http://localhost:1313/tech-articles/
```

## 终端环境要求

终端访问 `github.com` 必须带代理（本机 Clash 只设了系统代理，git/curl 不读）：

```bash
export https_proxy=http://127.0.0.1:7892 http_proxy=http://127.0.0.1:7892
```

token 在 `$GITHUB_PERSONAL_ACCESS_TOKEN`（注意不是 `$GITHUB_TOKEN`，会话里为空）；
`~/.gitconfig` 已配 github.com credential helper，直接 `git push` 即可，无需交互。

## 文章索引

| 日期 | 标题 | 状态 | 位置 |
|---|---|---|---|
| 2026-09-25 | 打通本机 GitHub 推送：PAT、代理与 credential helper | 待审 | `drafts/2026-09-25-github-push-with-pat-and-proxy.md` |
