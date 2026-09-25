---
title: 打通本机 GitHub 推送：PAT、代理与 credential helper
date: 2026-09-25
status: draft
tags: [github, git, 工程实践, macos]
summary: 用 personal access token 让终端里的 git clone/push 不再要密码：分清 token 放在哪个变量、为什么 github.com 直连超时、以及不落盘新密钥的 credential helper 怎么写。
channels: []
published_at:
---

# 打通本机 GitHub 推送：PAT、代理与 credential helper

> 导语：一台新机器上想用脚本推代码到 GitHub，通常会撞上三件事——token 到底在哪个环境变量里、`github.com:443` 连不上、`git push` 卡在输入用户名。这篇把三个坑和各自的验证方法写清楚，全部命令都是实测过的。

## 背景

目标是让自动化流程（Hermes agent 会话里的终端）能对 GitHub 做完整的读和写：读仓库、建仓库、提交、推送。
环境：macOS，Clash 代理监听 `127.0.0.1:7892`（只设了系统代理），`gh` CLI 未安装，只有 `git` 和 `curl`。

## 一、先确认 token 在哪个变量里

配置文件里常见两个名字，写的是同一个 token：

```
GITHUB_TOKEN=ghp_...
GITHUB_PERSONAL_ACCESS_TOKEN=ghp_...
```

但**注入到终端环境变量里的可能只有后者**。判断方法很简单，别猜：

```bash
echo "len=${#GITHUB_TOKEN}"                     # 0 表示没导出
echo "len=${#GITHUB_PERSONAL_ACCESS_TOKEN}"     # 40，正常
```

只看前缀、不看值，确认两边是不是同一个 token：

```bash
python3 - <<'EOF'
import re, hashlib
vals = {}
for line in open('/path/to/.env'):
    m = re.match(r'^(GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN)=(.+)$', line.strip())
    if m:
        vals[m.group(1)] = m.group(2).strip()
for k, v in vals.items():
    print(k, len(v), hashlib.sha256(v.encode()).hexdigest()[:12])
print('identical:', len(set(vals.values())) == 1)
EOF
```

哈希一致就说明两个变量同值，脚本里统一用被导出的那个即可。

**顺手看一眼权限范围**，`-I` 拿响应头，比打开网页快得多：

```bash
curl -sSI -H "Authorization: token $GITHUB_PERSONAL_ACCESS_TOKEN" \
  https://api.github.com/user | grep -i x-oauth-scopes
```

返回的 scopes 里如果同时有 `repo`、`workflow`、`delete_repo`、`admin:org`，说明这是个近乎全权的 classic token——用起来方便，但泄露代价高，建议只放在密钥文件里、别写进代码仓库。

## 二、为什么 github.com 连不上、api.github.com 却通

现象很反直觉：API 一切正常，`git clone` 却卡满 75 秒然后报错。

```
fatal: unable to access 'https://github.com/.../repo.git/':
Failed to connect to github.com port 443 after 75018 ms: Couldn't connect to server
```

原因是代理。macOS 上很多代理工具（Clash 等）只写系统代理设置，而**终端里的 curl / git 不读系统代理**，它们只认环境变量 `http_proxy` / `https_proxy`。浏览器和走云端 API 的工具能通，是因为它们各自走了别的路径。

排查顺序：

```bash
# 1. 直连试试（失败=超时或 DNS 污染）
curl -sS -m 15 -o /dev/null -w "%{http_code}\n" https://github.com/

# 2. 带上代理再试
export https_proxy=http://127.0.0.1:7892 http_proxy=http://127.0.0.1:7892
curl -sS -m 15 -o /dev/null -w "%{http_code}\n" https://github.com/
```

代理一通，git 的 clone/push 也就通了（git 走 libcurl，认同一组环境变量）。
注意这个 export 只对当前 shell 生效；要长期生效就写进 `~/.zshrc`，但要清楚这会让**所有**命令行流量都走代理。

## 三、让 git 自己拿到 token：credential helper

token 有权限 ≠ git 能推送。没配 credential helper 时，git 在需要认证的场合会尝试交互式询问，在非交互环境里直接失败：

```
fatal: could not read Username for 'https://github.com': Device not configured
```

三种做法，按「新增了多少明文密钥」排序：

1. **`credential.helper=store`**：把 token 明文写进 `~/.git-credentials`（简单，但多一份明文密钥落盘）。
2. **URL 里内嵌 token**：`https://user:token@github.com/...`，token 会进 shell 历史、进 `ps` 输出、进 `.git/config`。不推荐。
3. **运行时取值的 helper**（本文采用）：helper 每次被调用时去读环境变量，磁盘上不新增密钥文件。

```bash
git config --global credential."https://github.com".helper \
  '!f() { t="${GITHUB_PERSONAL_ACCESS_TOKEN:-${GITHUB_TOKEN}}"; \
     [ -n "$t" ] || t=$(grep -m1 "^GITHUB_TOKEN=" "$HOME/.hermes/.env" | cut -d= -f2- | tr -d "\r\n"); \
     echo username=x-access-token; echo "password=$t"; }; f'
```

几个细节：

- HTTPS 认证里**用户名可以随便填**，token 当密码用，所以 `username=x-access-token` 就够。
- 加一层 `.env` 兜底，是为了在没导出环境变量的 shell 里也能工作。
- `credential."https://github.com"` 限定作用域，不会影响其他 host。

## 四、不靠直觉，四步验证

非交互环境最容易「看起来成功其实没推上去」，所以每一步都要独立验证。

```bash
# 1. 关掉交互提示，逼出真实错误
export GIT_TERMINAL_PROMPT=0
git clone https://github.com/<owner>/<repo>.git repo && echo "clone ok"

# 2. 提交并推送
cd repo && git branch -M main
echo "test $(date -u +%FT%TZ)" > VERIFY.md
git add VERIFY.md && git commit -q -m "test: push verification"
git push -q -u origin main && echo "push ok"

# 3. 本地和远端比对同一个 commit
echo "local : $(git rev-parse HEAD)"
echo "remote: $(git ls-remote origin refs/heads/main | cut -f1)"

# 4. 绕过 git，用 API 回读远端文件（最硬的一条证据）
curl -sS -H "Authorization: token $GITHUB_PERSONAL_ACCESS_TOKEN" \
  https://api.github.com/repos/<owner>/<repo>/contents/VERIFY.md | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
print(d['path'], d['sha'][:12])
print(base64.b64decode(d['content']).decode().strip())
"
```

第 4 步的意义在于**换一条独立通道**确认远端状态：`git push` 返回 0 只代表本地 git 认为推成功了，API 读到的文件内容才是事实。
测试用的仓库如果是临时建的，记得用 `DELETE /repos/{owner}/{repo}` 清掉，并靠一次 `GET` 返回 404 来确认真的删了——很多 API 的删除接口返回 204 却需要二次确认。

## 结论 / 检查清单

- 先 `echo ${#VAR}` 确认 token 在哪个环境变量里，别靠猜；用 sha256 比对多个变量是否同值。
- 用 `x-oauth-scopes` 响应头核对权限范围，够用就好，不必给全权。
- 终端里的 git/curl 不读 macOS 系统代理，`github.com:443` 超时就 export `https_proxy`/`http_proxy` 再试。
- credential helper 用「运行时读环境变量」的写法，不新增落盘密钥；`GIT_TERMINAL_PROMPT=0` 是暴露认证问题的开关。
- 验证推送要跨通道：`git rev-parse` 对比 `git ls-remote`，再用 REST API 回读文件内容。

## 参考

- GitHub REST API: https://docs.github.com/rest
- git-credential 机制: https://git-scm.com/docs/gitcredentials
- 细粒度 token（更小权限面）: https://github.com/settings/tokens
