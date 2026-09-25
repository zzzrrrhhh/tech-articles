---
title: Hermes Agent 的 Kanban Swarm 拆解：把多 Agent 协作做成一张可恢复的任务图
date: 2026-09-25
tags: [hermes-agent, agent-orchestration, multi-agent, kanban]
author: zhangronghui
---

# Hermes Agent 的 Kanban Swarm 拆解：把多 Agent 协作做成一张可恢复的任务图

## 一、多 Agent 编排的死法

你大概写过这样的脚本：一个 for 循环串起三次 LLM 调用——规划、检索、成稿。本地跑通很爽，第一次线上事故就露馅：第三步超时，你只能从头重跑，前两步的 token 白付；中间产物躺在进程内存里，进程一挂就没了；产品经理想在中途改一句口径，唯一入口是改代码再部署。缺的不是并发数，是外部化的状态。Hermes Agent 的 Kanban Swarm 针对的正是这一点：它没有发明新的编排 DSL，只是把协作状态搬进一张进程外的共享任务图。

先说清版本事实，免得你照着错误的 changelog 找功能：Kanban board 在 v0.13.0（tag v2026.5.7）正式发布，`hermes kanban swarm` 那套 Swarm v1 拓扑在 v0.15.0（tag v2026.5.28）引入；v0.16.0 对 Kanban 只是增量（goal_mode 卡片、文件附件、default_assignee 与 per-profile 并发上限），并不是 Swarm 的引入版。本文按当前实现（v0.21.x）描述。

## 二、解剖五件套

**board** 是一个 SQLite 文件，默认 `~/.hermes/kanban.db`；命名板落在 `~/.hermes/kanban/boards/<slug>/kanban.db`，各自带独立的 workspaces/ 与 logs/。schema 共 7 张表：tasks、task_links、task_comments、task_events、task_runs、task_attachments、kanban_notify_subs。值得知道的原因是：状态是人和脚本共读的同一份数据，dashboard 与 gateway notifier 读的就是这些表，你也能直接 SQL 查审计。

**任务状态机**在源码里的 VALID_STATUSES 是 triage / todo / scheduled / ready / running / blocked / review / done / archived。为什么值得抠这个：官方文档的 core concepts 只列了 8 个，漏掉 scheduled，以源码为准——你写巡检脚本时会踩到。

**dispatcher** 是长驻循环，默认 60 秒一跳，跑在 gateway 进程内（`kanban.dispatch_in_gateway` 默认 true）。每一跳做四件事：回收过期 claim（默认 TTL 900 秒）、回收 PID 已死的 worker、把依赖已满足的 todo 原子晋升为 ready、用 `hermes -p <assignee> chat -q …` 把对应 profile 拉起来。一个 dispatcher 扫描所有板，worker 被注入 HERMES_KANBAN_BOARD，因而看不到别的板。

**工具面**共 14 个 kanban_* 工具，是 agent 唯一的协调入口：show / list / create / complete / request_review / request_changes / block / unblock / heartbeat / comment / attach / attach_url / attachments / link。为什么重要：线上的 worker 可能跑在 Docker 或 Modal 沙箱里，那里既没装 hermes 也没挂载 kanban.db，走 shell 调 CLI 会直接失效；kanban_* 跑在 agent 自己的 Python 进程里，永远碰得到板，返回的也是结构化 JSON 而不是要解析的 stderr。

**workspace** 隔离三选一：scratch 是任务完成即删的临时目录，dir 是共享绝对路径，worktree 是 git worktree——默认落在 `<repo>/.worktrees/<task-id>/`，未显式给分支时分支名为 `wt/<task-id>`，project 关联任务则确定性命名为 `<project-slug>/<task-id>`，可由任务 id 反查。

## 三、依赖图与自动流转

task_links 记录 parent→child 的有向边；所有 parent 变成 done 时，子卡才从 todo 自动升到 ready。两个边界值得记住：给正在 running 的子卡加边会被拒绝——你不能给已经 claim 出去的工作补门控（例外是 worker 为自己的卡片做 dependency 阻塞）；assignee 写错的卡片既不报错也不兜底，它安静停在 ready，事件里记一条 skipped_nonspawnable。

block 有四种 kind，路由各不相同。dependency 不进人工阻塞桶，停在 todo 等 recompute_ready；但如果此刻没有任何未完成 parent，它会被重新定性为 needs_input（reason=no_open_parent）——因为那个等待永远不可能被满足。needs_input、capability、transient 则进 blocked，浮到人面前。这条设计消灭的是静默死锁：宁可让人看一眼，也别让卡片在 todo→ready→重跑之间空转。

评审是独立车道。kanban_request_review 把任务推进 review 列，它不是 block，所以反复评审不会触发 block-loop 计数；reviewer 用 kanban_complete 批准，或用 kanban_request_changes 退回——后者关掉这次评审 run、重新套用 parent 门控、把卡还给原实现者。review 车道默认自动派发（`review_dispatch` 默认 true）并强制加载 sdlc-review 技能。

Swarm 拓扑本身没有第二个调度器，它只是往既有 kernel 里写一张小图：

```bash
hermes kanban swarm "写一篇 Kanban Swarm 解析" \
  --worker writer:"撰写文章" \
  --worker researcher:"核实事实" \
  --verifier reviewer \
  --synthesizer publisher
```

planning root 立即完成 → 并行 specialist workers 加 verifier（等所有 worker 完成才 todo→ready）→ synthesizer（等 verifier）；shared blackboard 就是 root 卡上一段结构化 JSON 评论，因此 dashboard、notifier、slash command 全都不用改。入口是双份的，状态却只有一份：agent 走 kanban_* 工具，人和脚本走 `hermes kanban …`、`/kanban …` 或 dashboard，两者共用同一个 kanban_db 层，所以你在 dashboard 上手动改一张卡的状态，语义和 agent 调工具完全一致，不会长出两套真相。本文这条流水线（orchestrator→researcher→writer→reviewer→publisher）就是一例：五张卡、五行 task_links，任何一环挂掉或被人工改道，图本身仍然完整。

## 四、抗失败设计

这是全文最重的一节。worker 跑长任务时周期性调用 kanban_heartbeat（工具层自动心跳最小间隔 60 秒，正常工具活动就足以把进程内的存活状态镜像到板上）。dispatcher 判定 reclaim 需要两条同时成立：该 run 已运行超过 `dispatch_stale_timeout_seconds`（默认 14400 秒，即 4 小时），且 last_heartbeat_at 为 NULL 或早于 1 小时（源码中硬编码的 _STALE_HEARTBEAT_GAP_SECONDS）。

关键取舍必须说清：reclaim 会把任务重新排成 ready，但**不计一次失败**。源码注释写得很直白——否则长任务会把熔断器踩爆。代价是丢掉当前 run 的进度，所以超过 1 小时的任务必须至少每小时心跳一次，这条语义还被写进了每个 worker 的系统提示。

失败计数有三道守卫，别混为一谈：failure_limit 默认 2，管同一 task 连续 spawn_failed / timed_out / crashed；protocol_violation 上限 3，管 worker 没有任何 terminal board call 就退出；BLOCK_RECURRENCE_LIMIT 默认 2，管同一原因 block→unblock→re-block 的循环，到顶后 unblock-loop breaker 不再把它送回 blocked（否则 cron 会无限 unblock），而是路由到 triage 等编排者处理，计数只在成功 complete 时重置。熔断阈值优先级是 per-task max_retries > kanban.failure_limit > DEFAULT_FAILURE_LIMIT。退出码也有语义：75（限流、过载、账单墙）只重排不计失败，78（凭证或模型被拒）第一次就熔断并 sticky-block。

幂等与产物回传同样重要：kanban_create 的 idempotency_key 让重试建卡不产生重复；scratch workspace 里的文件只有在 `kanban_complete(artifacts=[...])` 里显式声明才会被复制进 per-task 持久附件，声明了却不存在则会卡住任务让你改路径。另外 task_runs 表一次 run 一行，重试、超时、阻塞都留下多行——这就是可审计的痕迹。

## 五、开发者落地判断

该用：链路长且贵（重跑一次心疼）、跨多个角色或 profile、需要人工闸门、需要事后审计。别用：单次 LLM 调用、延迟敏感、或你只是想要一个进程内 DAG——那用原生 asyncio 或 LangGraph 更轻。

三个真实的坑。第一，assignee 写错：卡片不报错，只是安静停在 ready 永不派发，dispatcher 记一条 skipped_nonspawnable，没有兜底执行者，所以派发前先确认 profile 真实存在。第二，stale reclaim 会丢进度：它是重跑而不是续跑，下游若依赖中间产物，就必须把它写进 board 或 artifacts，而不是留在 worker 的临时目录里。第三，Kanban 是单机设计——本地 SQLite 加本机 PID 崩溃检测，跨主机共享板不受支持，要跨机器就每 host 一张板，或按官方 kanban-multi-gateway 那套部署。

## 六、横向对比与结论

三个问题，三个对照。状态在哪：LangGraph 放在图运行的 checkpointer 里（生产要用 PostgresSaver 这类持久实现），thread_id 是它的持久游标；CrewAI 放在进程内的 flow 状态加本地产物与内存；Claude Code subagents 干脆待在一个 session 里，结果只回给调用者，没有共享面板。失败怎么恢复：LangGraph 靠 checkpointer 支持中断后恢复与时间旅行；CrewAI 的 `crewai replay -t <task_id>` 是回到某一步重放，不是崩溃自愈；Claude Code 官方文档没有崩溃恢复语义。人在环怎么表达：LangGraph 在节点里 interrupt() 挂起、用 Command(resume=…) 恢复；CrewAI 是任务级 human_input=True；Kanban 则把 block 的 kind、review 车道、triage 全建成 board 上的一等公民。

所以 Kanban Swarm 的差异化不是并发数，而是把任务状态、依赖关系、失败计数、人工闸门做成进程外的一等公民。你换来的是一张可恢复、可审计、能被人类中途接管的图；同时接受一个必须认真对待的运维边界：这张图是单机的，心跳是要人管的。
