---
title: Hermes Agent 插件体系拆解：先选对扩展层，再谈怎么写
date: 2026-09-25
tags: [hermes-agent, plugins, extension-points, developer-experience]
author: zhangronghui
---

# Hermes Agent 插件体系拆解：先选对扩展层，再谈怎么写

## 一、一个需求，五种落法

“给 Hermes 加个功能”，听起来像一道填空题，其实是一道选择题。

同样是“让 agent 能查内部工单系统”，至少有五种写法：写一个 skill，把流程写成提示词；起一个 MCP server，让工具跑在独立进程里；写一个 Python plugin，注册工具、挂后端 API、订阅事件；写一个 desktop UI plugin，只做界面；或者直接改核心 `tools/` 下的代码。

五条路都能跑起来，代价却差得很远。写进核心 `tools/` 的功能，下次上游升级时就可能被覆盖；指望 desktop plugin 提供工具能力，则是彻底的方向性错误——那一层只管界面。所以真正的问题不是“怎么写插件”，而是**先选对扩展层**。

先交代一句边界。官方文档写得很直接：desktop、dashboard、Python 三套插件 “do not share code, APIs, or delivery”，也不存在 `PLUGIN_API_VERSION`。本文说的“体系”，特指 Python 侧那套有 manifest、有书面兼容契约、有统一 CLI 的系统——它确实是成体系的一等公民；但“插件”作为一个总称，在 Hermes 里并不统一。

## 二、五层扩展点，从外到内

按“离核心的远近”排序，五层大致是这样：

**skill**（提示词层，无版本概念）：一段流程与规范，agent 读到即用。零代码、零构建、零升级风险，但模型遵不遵守是概率问题。

**MCP server**（外部进程）：工具跑在自己的进程里，通过 MCP 协议把能力交给 agent。隔离好、易复用，代价是每次调用都要走一遍协议、进程生命周期要自己管。

**Python plugin**（`~/.hermes/plugins/<id>/`，v0.3.0 起，2026-03-17）：`plugin.yaml` 加 Python 代码，能注册 tools、hooks、slash command、CLI 子命令，也能提供 memory provider、context engine 这类东西。这是能力最强、又真正可分发的层。

**desktop UI plugin**（`$HERMES_HOME/desktop-plugins/<id>/plugin.js`，v0.20.0 起，2026-08-03）：负责界面那一半。热加载、无构建，但碰不到 agent 能力。

**核心 `tools/*.py` + `toolsets.py`**：能力可以进所有平台，但改的是上游代码。

判断维度就四个：能力上限、隔离程度、升级风险、谁会看到它。越靠外，越不侵入核心、升级越安全、能力越受限；越靠内，能力越强、和上游耦合越深、升级要自己扛。

定层之后还要再问一句：这个能力最终是给模型用，还是给人看？前者得能被 tool calling 描述清楚，后者得能跟随主题与布局——两者的验收标准完全不同。

顺带说明一句：这五层是本文的选型排序图，不是官方分类——官方口径是 “four kinds of plugins” 加两张对照表。

## 三、Python plugin：一个文件夹装一整个功能

Python 插件是唯一有正式封装契约的一层。发现顺序是 bundled（随核心分发）→ 用户 `~/.hermes/plugins/` → 项目 `./.hermes/plugins/`（需 `HERMES_ENABLE_PROJECT_PLUGINS`）→ pip entry-points，靠后的覆盖靠前的。`hermes plugins list` 里的 `plugins/*/provider.py` 属于随核心分发的 bundled 树，和用户目录同源不同层，别混为一谈。

manifest 的必备字段只有 `name` / `version` / `description`，缺一个 `hermes plugins validate` 就失败；`kind` 取 `standalone`、`backend`、`exclusive`、`platform`、`model-provider` 之一。

```yaml
name: ticket-lookup
version: 0.1.0
description: 查询内部工单系统的 Hermes 插件
kind: standalone
manifest_version: "2"
requires_hermes: ">=0.21"
provides_tools: [ticket_lookup]
```

语义上有两点值得注意：`manifest_version` 缺省即 v1（官方承诺永久支持），未知字段只警告不阻断；`api_version` 与 `manifest_version` 是两条独立的轴，不要当成版本升级的同义词。

门控上，`plugins.enabled` 是白名单，`plugins.disabled` 是黑名单，后者永远获胜。白名单默认 opt-in，这正是“装上没反应”成为最高频问题的原因。

封装契约的讨巧之处在“一个文件夹装一整个功能”：统一包可以把 Python 半边与 desktop 半边放在同一个 `<id>/` 目录下，安装与卸载同进同出；桌面那半由 Electron 主进程复制到 app 级目录，并在旁边写 `.hermes-package.json` 标记，用来把 desktop 那半配回 agent 那一行，源文件变更时重拷。桌面侧还会强制 `defaultEnabled` 为关闭，所以“装了但惰性”是设计，不是 bug。

## 四、界面扩展：契约窄，约束硬

desktop plugin 的交付方式很讨喜：渲染层只从 `$HERMES_HOME/desktop-plugins/<id>/plugin.js` 加载，没有构建步骤，改完即生效。但约束同样硬。

import 面只有三个 specifier——`@hermes/plugin-sdk`、`react`、`react/jsx-runtime`，其它（包括 `https:` URL）一加载就失败，admission 侧的静态 lint 会在更早一步拦下越界 `import()`。磁盘上的文件是未编译执行的，写 JSX 语法会直接报错，必须用 `jsx()` / `jsxs()`。

```js
// 宿主看不到这些裸全局：禁用和每次热重载都会叠加
window.setInterval(poll, 1000)   // ❌ ESM 无法卸载
```

其余几个坑同样真实：handler 里要现场 `$atom.get()` 读 state，只在渲染叶子用 `useValue` 订阅，否则读到旧值；颜色要用 `var(--ui-*)`，硬编码会破坏主题跟随，canvas 场景得在挂载时用 `getComputedStyle` 取一次；定时器与事件监听要交给 `ctx.setInterval` / `ctx.addEventListener`，并在 `ctx.onDispose` 里收尾。import 越界还有一个变体：忘了 import 组件，表现是渲染期的 ReferenceError。

最能说明这层契约有多窄的是这一条：聊天里的 directive 类 contribution 必须由插件**主动告诉模型它存在**，模型不会自己发现。另外，插件是以 ESM 在渲染进程里全权限求值的，宿主只提供错误隔离——那不是沙箱。

## 五、选层决策与运维现实

判断顺序可以固定下来：单次工具调用或流程规范 → skill；通用外部能力 → 先看已有 toolset 与 MCP；需要后端 API、事件钩子、打包分发 → Python plugin；只动界面 → desktop plugin；要进每个平台的核心能力 → 才考虑改核心。

运维现实比选型更容易翻车，几条硬事实：

其一，**两把独立的门**。`plugins.enabled` 管 Python 半边；桌面侧是 app 内 Capabilities → Plugins 的 live toggle，它**不会 import Python**，官方把这称为安全边界。装了没效果，先分清是哪半边的问题。

其二，门控与生命周期不同步。`tools` 与 `prompt` 段的变更要等下一个 session，`mcp_servers` 要等 `mcp.reload`，而**禁用不会 un-wire**，得重启 gateway。

其三，超时是硬死线：`plugins.load_timeout_seconds` 默认 10 秒，超时直接跳过并忽略迟到的注册；`plugins.hook_callback_timeout` 默认 30 秒。

其四，作用域会咬人：用户插件按 `HERMES_HOME` 隔离，同一台机器上换个 profile 就看不到了。另外 2026-09-14 之后，插件导入旧内部路径的兼容层已不再兜底——今天仍用旧路径的插件不会被加载。

其五，跨端有两处静默失效值得先记住：`ctx.socket` 在 OAuth remote 上是 no-op，实时推送别当唯一通道，必须留轮询兜底；`ctx.os` 是唯一的 OS 门，能力不可用时返回 false 而不是抛错，通知还会按插件节流。至于 `ctx._cli_ref`，在 gateway、`hermes chat -q` 与 kanban worker 里恒为 None，用到它就得换成 `ctx.profile_name` 加 `ctx.dispatch_tool`。

```bash
HERMES_PLUGINS_DEBUG=1 hermes plugins list --plain --no-bundled
hermes plugins doctor
hermes plugins compat ./my-plugin
```

## 六、结论：什么时候别写插件

给 AI 开发者的最小行动清单：先枚举扩展点，再按隔离性排序，只在最外层不够用时往里走一步。

更重要的是一句反向话术：如果只是一段流程规范，写 skill；如果只是接一个现成服务，先接 MCP；如果只想换个界面，别碰 Python 半边；如果只在一个项目里用，别急着做成可分发插件。

Hermes 的“插件”从来不是一个万能 API，而是一组按离核心远近排序的扩展点。选层对了，写法是查文档的事；选层错了，写得再漂亮也是给下游升级添麻烦。
