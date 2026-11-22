# Pi Go 竞品调研与功能优先级

调研日期 2026-11-23。按仓库现状与厂商公开文档、维护者 README 对照。竞品功能通过资料核实，未做实机横测。优先级以「已经在 Mac 上用 Pi、离开电脑后希望用手机接手」为目标用户假设。

## Pi Go 已经具备什么

- Pi Go 可在手机上打开 Pi 原生历史，由 daemon 启动或恢复 Pi 会话，也可接入已经加载 Pi Go 扩展、并由桥发现的终端会话。手机可处理 daemon 托管会话的扩展问答，现有终端会话的交互仍在 Mac 上处理。[Pi Go 实施计划](../PLAN.md) · [daemon 文档](../host/daemon/README.md)
- 已具备实时文本、思考和工具状态、运行中引导与补发、模型选择、原生技能和扩展命令、语音转文字、文件收发以及工作区文件浏览。部分流程仍待完整真机验收。[Pi Go 实施计划](../PLAN.md)
- 已具备本地定时任务、运行历史和跨电脑前台收件箱。App 冻结或被系统杀死后的可靠推送尚未接入。定时运行遇到扩展交互时会结束并记录原因。现有实况窗覆盖当前主动发起的运行。[daemon 文档](../host/daemon/README.md) · [鸿蒙任务实况窗](live-view.md)
- 已支持 USB、LAN 和公网入口。公网目前使用自备 VPS 与 SSH 隧道，TLS 终止在 Mac。几种连接共用 Pi 的会话体系，分别持有配对记录。[Pi Go 实施计划](../PLAN.md) · [公网配对](remote.md)

## 两个主要对标

| 产品 | 手机工作流 | 对 Pi Go 的启发 |
|---|---|---|
| 腾讯 WorkBuddy | 原生 App 与电脑连接后，任务完成、中断、待回答、待审批可触发系统通知，点击直达会话或交互。通知覆盖手机或电脑发起的任务及定时任务，当前会话可抑制提醒。电脑产物自动回传为卡片，支持预览、分享、批量操作与导出。微信小程序用订阅通知。另有微信、企微、QQ、飞书、钉钉接入，其配置与权限按各入口而异。官方主页也列有鸿蒙手机版。[移动 App 多端互通](https://www.workbuddy.cn/docs/workbuddyapp/features/Multidevice) · [微信小程序多端互通](https://www.workbuddy.cn/docs/workbuddymini/features/Multidevice) · [助理接入指南](https://www.workbuddy.cn/docs/workbuddy/Feishu-Guide) · [WorkBuddy 官网](https://www.workbuddy.cn/) | 优先借鉴「有事找我，结束给我结果」。已有收件箱可以接入及时通知和产物卡。原生鸿蒙体验是产品基础，Pi 原生上下文与连接方式是与 WorkBuddy 的具体区别。 |
| Codex 手机版 | ChatGPT 移动端可扫码连接 macOS 或 Windows 宿主，选择工作区、分支和独立 worktree。手机可查看本轮变更、逐文件 Diff、对行批注并发回 Codex。支持处理审批、接收完成通知直达会话，以及查看截图、终端输出和测试结果。远程连接通过 OpenAI 中继，桌面远程与 Codex Cloud 各有入口。[远程连接](https://learn.chatgpt.com/docs/remote-connections) · [OpenAI 工程实战](https://developers.openai.com/blog/mastering-codex-remote-for-engineering) · [Codex Remote 发布介绍](https://openai.com/index/work-with-codex-from-anywhere/) · [Work 与 Codex 帮助](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex) | 手机需要承接「审阅结果、给精确反馈、继续跑」。Git 之外也有可复用的结果呈现，如测试、截图和交付文件。远程配对与运行边界都值得做得更直观。 |

WorkBuddy 还支持从对话或模板创建定时任务，集中查看历史和产物，本地与云端模式各有运行条件。云端沙箱无法读取本机文件。桌面更新日志列有 Worktree 任务，当前资料不足以把这一入口归到移动端。[WorkBuddy 定时任务](https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Automation-Guide) · [WorkBuddy 更新日志](https://www.workbuddy.cn/docs/workbuddy/Changelog)

## 同类工具验证了哪些方向

- **pi-app / pi Remote Android** 已支持查看本轮或工作树的变更，长按代码行添加评论并纳入下一条消息，切换分支或从消息分叉。外网连接可走 Tailscale、ZeroTier 或 WireGuard。它验证了「手机 Git 审阅」在 Pi 自身生态已有直接对标。[pi-app 手机端](https://github.com/justhil/pi-app#pi-on-your-phone)
- **HAPI** 适合参考跨 Agent、远程接入与分发。产品支持原生 iOS/Android、Web/PWA、Telegram 以及原生和 Web Push。Pi 接入具体走 RPC，官方表格标注远程模式支持、没有本地 TUI 输入路径和通用 Pi 审批模式。它对部分 Pi 会话历史操作与扩展命令也有支持。[HAPI 主项目](https://github.com/tiann/hapi) · [HAPI Pi 能力矩阵](https://hapi.run/docs/guide/agents) · [HAPI 推送文档](https://hapi.run/docs/guide/pwa)
- **Pi Mobile** 主打 Android 上接续 Pi，可查看会话树、跳转继续、从节点分叉，支持会话统计和导入导出。外网通过 Tailscale 访问。适合参考如何把 Pi 会话结构和运行上下文带到手机。[Pi Mobile 功能](https://github.com/ayagmar/pi-mobile#what-this-does)
- **Pi Remote for iPhone** 把扫码和公网传输合成 Tailcat Quick Connect，官方文档介绍其无需公开端口、域名或系统 VPN 配置。另有 Pi 会话续跑、实时流和扩展问答，当前供侧载。它是低门槛远程配对的同生态参考。[Pi Remote 主项目](https://github.com/grimlee/pi-remote)
- **Claude Code Remote Control** 可从手机或浏览器接续本地环境，提醒任务结束与需决定事项，在终端活跃时抑制推送。服务器模式支持为新会话分配独立 worktree。适合参考通知策略和远程并发边界。[Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)
- **CodeBuddy Code Remote Control** 提供手机扫码打开浏览器控制台，可接续终端会话，并复用本机文件、工具与 MCP 配置。公网可用 Cloudflare Tunnel，或在同一局域网内连接。这是腾讯的编码 CLI 入口，与 WorkBuddy 原生 App 各有接入流程。[CodeBuddy Code 远程控制](https://cloud.tencent.com/document/product/1831/137049)

## 建议优先做的功能

| 优先级 | 功能 | 第一版范围 |
|---|---|---|
| P0 | **系统通知与待处理** | 复用现有顶部收件箱，将完成、失败、等回答和待审批纳入统一状态。系统通知点击跳到对应电脑、会话与待处理项，跨端已处理时显示当前状态。用真机验证锁屏、进程冻结或被杀、断网恢复与重复投递。推送只携带定位和通用状态，详情回已授权连接读取。 |
| P1 | **结果卡和轻量审阅** | 每次运行结束给出变化、验证结果与交付文件。先支持只读 Diff、截屏/报告预览和「引用文件或代码行继续修改」。尽量把本轮引入的变化与启动前已有的工作区修改区分。对非 Git 工作区保留测试、截图、报告等结果入口。 |
| P1 | **公网首次连接与诊断** | 保留 USB/LAN/自建 VPS 路径，先为桌面端增加主机在线、隧道可达、手机授权、网络切换等检查。若试用反馈集中在自备 VPS 门槛，再考虑开箱即用的可选连接方式。 |
| P2 | **会话接力与任务隔离** | 先明确已有终端会话的可操作范围和当前处理位置。随后考虑从某条消息分叉，以及从手机新建隔离 worktree，适合同时推进修复、实验与代码审阅。 |
| P2 | **定时任务结果化** | 复用现有定时器和运行历史，加入「把这轮设为定时」、面向 Pi 的日报/测试巡检模板、失败重跑。等审批机制成熟后，再支持定时运行挂起等待答复并恢复。 |

## 值得试的差异化组合

**把 Pi 扩展的结果直接交付到手机。** 新增一个简单的结果描述接口，让技能和扩展声明产物与接手动作。例子包括测试结果卡、构建产物、截图对比、待确认的操作以及「用同一技能再跑一次」。延用现有工作区授权和文件传输能力。通用的 Git 审阅覆盖开发场景，扩展产物覆盖用户现有的 Pi 自动化。

首个可验证场景是「Mac 的 Pi 完成修复 → 手机收到提醒 → 看 Diff 和测试结果 → 圈一行让 Pi 改 → 新结果到达」。建议观察首次蜂窝网连通成功率、待处理通知后恢复运行的比例，以及用户在手机看过结果后完成下一步的比例。若实际用户更常用 Pi 处理非代码任务，结果卡可以先支持文件、截图和报告，再扩充 Git 审阅。
