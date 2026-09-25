# tech-articles · 技术专栏文章仓库

集中存放技术博文/专栏文章的唯一事实来源（single source of truth）：先写草稿、审核后发布、发布完归档。
由 Hermes（publisher profile）协助维护与推送。

- 仓库：https://github.com/zzzrrrhhh/tech-articles （当前为 **private**，需要对外时一条命令即可转 public）
- 默认真分支：`main`
- 本地工作副本：`/Users/bl_osd/tech-articles`

## 目录约定

| 目录 | 用途 |
|---|---|
| `drafts/` | 草稿，尚未对外发布。可以随便改，允许半成品 |
| `published/` | 已经发到对外渠道（邮件推送 / 站点 / 公众号等）的定稿，只做勘误式小改 |
| `assets/` | 配图、截图、附件。文章用相对路径引用：`../assets/xxx.png` |
| `templates/` | 文章模板，新建文章时复制一份 |

## 命名与格式

- 文件名：`YYYY-MM-DD-slug.md`，slug 用短横线小写英文，例如 `2026-09-25-github-push-with-pat-and-proxy.md`
- 每篇文章开头必须有 YAML front matter（见 `templates/article-template.md`）：

```yaml
---
title: 文章标题
date: 2026-09-25          # 创建日期
updated: 2026-09-25       # 可选，最后修改日期
status: draft             # draft | review | published
tags: [github, git, 工程实践]
summary: 一句话摘要，用于列表页和推送邮件正文开头
channels: []              # 发布渠道，如 [email, blog]，发布后填写
published_at:             # 对外发布时间
---
```

## 发布流程

1. 复制 `templates/article-template.md` 到 `drafts/YYYY-MM-DD-slug.md`，写正文。
2. 审核（改 `status: review` 表示待审）。
3. 发布到目标渠道，记录 `published_at` 与 `channels`。
4. 定稿移动到 `published/`，`status` 改为 `published`。
5. 提交并推送：`git add -A && git commit -m "post: <标题>" && git push`。

> 终端里访问 `github.com` 需要代理：`export https_proxy=http://127.0.0.1:7892 http_proxy=http://127.0.0.1:7892`。
> token 与提交身份已配置好，直接 `git push` 即可，无需交互输入。

## 文章索引

| 日期 | 标题 | 状态 | 文件 |
|---|---|---|---|
| 2026-09-25 | 打通本机 GitHub 推送：PAT、代理与 credential helper | draft | [drafts/2026-09-25-github-push-with-pat-and-proxy.md](drafts/2026-09-25-github-push-with-pat-and-proxy.md) |
