---
title: 从一句主题到一篇成稿：用 Hermes Kanban 的多 profile 协作搭一条内容发布流水线
date: 2026-09-25
tags: [hermes-agent, multi-agent, kanban, content-pipeline]
author: zhangronghui
---

# 从一句主题到一篇成稿：用 Hermes Kanban 的多 profile 协作搭一条内容发布流水线

「把这个主题写成一篇 2000 字的博客。」把这句话丢给一个 agent，它调研、写稿、自我审阅，输出看着不错。于是你想把它变成每天跑十条的流水线，并不断加长 prompt：调研注意时效，写作统一术语，审稿核对事实。第三天你发现，有条稿子卡在第 4 步，而你不知道前 3 步究竟产出了什么。

这不是 prompt 不够聪明的问题。编排状态一直住在对话里：上下文一截断，中间产物就丢了；某一步失败，你无法定位坏在哪一步；你也没法把调研交给一个模型、写作交给另一个，因为两者共享的只有那段越滚越长的聊天记录。Hermes Agent 的 Kanban 换了个做法——把编排状态从对话里搬进一块共享的 SQLite（默认 ~/.hermes/kanban.db）：任务是一行、handoff 是一行、每次尝试也是一行，dispatcher 作为 agent 进程之外的监督者，默认 60 秒一 tick，负责扫卡、推卡、拉起 worker。这条流水线的可靠性来自「状态外置 + 结构化 handoff」，不来自更聪明的 prompt。

## 把编排状态搬出对话：卡片即状态机

卡片有 8 个状态：triage、todo、ready、running、blocked、review、done、archived。关键不是名字，而是状态由谁改。worker 只在自己那一棒里改状态，跨棒的推进由 dispatcher 的 tick 完成：回收 stale、crashed、timed out 的卡，把依赖满足的卡提升为 ready，按 assignee 领取 ready 卡，再 spawn 出 `hermes -p <assignee> chat -q ...`。

依赖是硬的。用 parents 建卡时，父卡没 done，新卡直接停在 todo 并写一条 dependency_wait 事件（reason=parent_not_done、demoted=true）；更关键的是，即使有人把卡置为 ready，claim_task 在领取时还会再校验一次父卡，不满足就降回 todo 并记 claim_rejected（reason=parents_not_done）——ready 不是对依赖的绕过。

为什么重要：依赖门控写在数据库里、由监督进程执行，所以「上游没完成」这件事不依赖任何模型的记忆。父卡一 done，recompute_ready 在同一秒就把子卡提升回原来的车道（实现来源回 ready，review 来源回 review）。

## 上游产物如何变成下游上下文

每个 worker 被 spawn 时，会拿到一份自动拼装的 worker_context，顺序是：卡头 → Body（截断 8KB）→ 附件绝对路径 → 本卡最近 10 次已结束的 run（含 summary、error、metadata）→ 已 done 父卡最近一次 completed run 的 summary 与 metadata → 同 assignee 在其他卡上的最近 5 次完成摘要 → 评论区最近 30 条（单条 2KB）。单字段上限 4KB，超出会标注 truncated。

这解释了两条实战纪律。第一，handoff 要写成短清单，不是长散文——上游 result 写得太长会被截断，下游就看不全：

```text
result: /abs/path/article.md + 文章标题 + 一句话摘要
metadata: {"checked": ["依赖门控", "heartbeat 阈值"], "changed_files": [...]}
```

第二，兄弟卡不会自动注入。worker_context 里只有父卡 handoff，同一个 dispatch 下的其他分支彼此不可见。需要下游自动知道的决定，必须写进卡 body 或 handoff；写在兄弟卡正文里等于没写。想跨卡查阅只能显式调用 kanban_show(task_id=X)，跨卡评论倒是允许的——它是任务之间的交接通道。

## 五棒流水线：分工与交接契约

一条内容流水线可以是五棒：orchestrator 出规格 → researcher 出带来源的结论 → writer 出初稿 → reviewer 语法校对 → publisher 落库上线。每棒只允许产出结构化 result，不允许「参考上一个的聊天记录」。卡上的 assignee 就是 profile 名，用 `hermes profile list` 枚举；每个 profile 有自己的 model、skills 和上下文预算，所以分棒不只是为了流程好看，更是让每棒只装载它需要的那点上下文。

## 规格卡本身怎么写

第一棒产出的不是文章，是规格：中文标题、目标读者、一条核心主线、4 到 6 节大纲、3 到 6 条待调研问题清单、tags、硬性约束。给下游「问题清单」而不是「参考资料」是刻意的：清单可核验，资料只能猜。researcher 逐条回答必须带 URL，writer 写稿时只引用已核实的数字——包括 tick 间隔这类默认值，写「大约」就等于给下游埋雷。

## 运维现实与失败模式

跑起来之后，真正吃掉你时间的不是写作质量，而是下面这些坑。

未注册的 assignee 会被静默跳过。profile 不存在时，卡不会被 spawn，也不会改派，而是留在 ready 并进入 skipped_nonspawnable 桶；default_assignee 只作用于「未分配」的卡，救不了错名。这是「卡住了但没人报错」的头号来源。

长任务要 heartbeat。stale 判定是两个条件同时成立：运行时长 ≥ 4 小时（dispatch_stale_timeout_seconds=14400），且 last_heartbeat_at 为空或已超过 1 小时。命中后 SIGTERM 掉本地 worker，run 以 outcome 为 stale 关闭，卡回到来源阶段。heartbeat 有两层作用：刷新心跳时间，以及通过 heartbeat_claim 续租 claim（默认 TTL 15 分钟）。反直觉的地方在于：stale 回收不计入失败次数，而 claim 过期回收走的是另一条路径，会计入 consecutive_failures——同一张卡有两条回收通道，惩罚却不同，所以别把「被回收过」当成「被记过」。任何可能跑过一小时的卡，都应至少每小时调一次 heartbeat：

```text
kanban_heartbeat(note="已完成规格与调研，正在整理结论")
```

block 的 kind 决定它去哪。kind=dependency 的卡进的是 todo，不是 blocked，因为它只是在等父卡，不该被人当成待手工处理的项；needs_input、capability、transient 才进 blocked，并且同因重复 block 达到上限 2 次时会被自动路由到 triage 并记 block_loop_detected。同一张卡自己承担实现加评审时用 request_review（卡进 review，反复迭代不触发 block 循环计数）；但任务图里已预建 review 子卡时，实现者就该 kanban_complete 让子卡离开 todo，不要同时再 request_review，否则等于让同一条 review 车道跑两遍。block 只留给真正的外部阻塞。

每个 run 的 outcome 都是可审计的：completed、stale、timed_out、review_requested、changes_requested。连续失败达到 failure_limit（默认 2）会熔断；到点超时先 SIGTERM，5 秒宽限后 SIGKILL。

## 对比、复用与边界

LangGraph 把编排状态存在 checkpointer 的 checkpoint 里、按 thread_id 归属，官方文档给它的定位是会话连续性、human-in-the-loop、time travel 与 fault tolerance，且 checkpointer 与 store 是两套持久化（线程内与跨线程）。CrewAI 的进程由 task list 决定顺序：sequential 按预定义顺序执行、上游 output 作为下游 context，hierarchical 由 manager agent 负责规划、委派与验证。

差别在持久化的对象，以及「谁负责发现失败」。两者持久化的是图或流程的内部状态，谁发现失败、何时重启、如何防重复执行，由开发者自己搭；Hermes Kanban 持久化的是任务行、尝试行、事件行，监督者在 agent 进程之外做死亡检测、超时终止、claim 回收、心跳检查与熔断，并把每次 handoff 写成人类也能读写的行。有一篇 Diagrid 的分析文章主张 checkpoint 不等于 durable execution，逐条列出的正是无自动失败检测、无自动恢复、无防重复执行、单进程执行——注意这是厂商立场（它卖的就是 durable execution 产品），引用时要标明，但用它来对照上述设计取舍仍有参考价值。

### 复用与边界

同一套依赖图可以套到日报、周报、多语言发布上：改的是 assignee 与产出契约，不改状态机。至于哪些环节不该交给 agent——事实核查的最终判断、对外发布的开关——建议留在人手里；Kanban 的价值恰恰是让人的介入变成一个明确动作（unblock、request_changes），而不是在对话里猜模型有没有做完。
