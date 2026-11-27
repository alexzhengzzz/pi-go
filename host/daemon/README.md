# Pi Go daemon

Pi Go 是个人电脑 AI Agent 与后台任务的常驻宿主及移动指挥台。daemon 通过统一的 `AgentProvider` 注册表启动并管理 Pi CLI（RPC）、Codex CLI（`codex app-server`）和 Antigravity（`agy acp`）会话，负责定时任务调度与本机事件推送，供手机在「动态」页统一收取汇报并在需要时一键拉起会话介入。

```
鸿蒙手机 ──HTTP(S)/SSE── broker.mjs ── w-*.sock ── Pi 扩展 (phase0.ts)
                             │                  └── agent-worker.mjs (Codex / AGY)
                             └── host-*.sock ── daemon ── AgentRegistry / RuntimePool
```

- `daemon.mjs` 提供常驻入口，由 launchd 或终端启动。收到 SIGTERM 时停止托管会话。
- `host.mjs` 通过本机 Unix socket 提供会话接续、工作区登记和扩展交互接口。
- `runtimes.mjs` 在工作区中运行 `pi --mode rpc [--session <file>]`，通过 stdin/stdout 处理 RPC。手机可应答 `confirm`、`select`、`input` 和 `editor`。
- `catalog.mjs` 扫描原生会话存储，按工作区真实路径匹配历史，支持 `<id>.jsonl` 和 `<slug>_<id>.jsonl`。
- `registry.mjs` 把工作区登记持久化到 `PIGO_STATE_DIR/daemon/workspaces.json`。关闭工作区会停止托管进程、移除登记并保留文件。

## macOS 无界面安装

日常使用由 [Pi Go.app](../../docs/pairing-gui.md) 统一接管宿主和连接。以下命令适用于开发调试或无界面运行。

1. 在仓库根目录执行以下命令。已有 USB 配对可以继续使用，桥接端口保持一致。

   ```sh
   pi install "$PWD"
   PIGO_USB_PORT=18977 npm run install:daemon
   ```

   daemon 和 USB 桥由 launchd 登录自启，并在退出后重启。仅需安装宿主时可省略 `PIGO_USB_PORT`。日志在
   `~/Library/Logs/dev.pi.go.daemon.log` 与 `~/Library/Logs/dev.pi.go.bridge.usb.18977.log`。
   已配置的 LAN 和公网桥可以继续发现同一个 daemon。
2. USB 调试和反向端口配置见 [USB 真机联调](../../docs/usb.md)。手机连接后可打开现有历史，daemon 会登记该会话所在的工作区。启用整机访问后，已配对的桥会自动发现加载了 Pi Go 扩展的活跃 Pi CLI 会话。

前台调试可在无后台宿主运行时执行 `node host/daemon/daemon.mjs`。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PIGO_IPC_DIR` | `$TMPDIR/pigo-<uid>` | host/worker socket 目录（与 broker、扩展共享） |
| `PIGO_STATE_DIR` | `<ipc>/state` 或 `~/.pi-go` | 注册表等持久化状态 |
| `PI_CODING_AGENT_DIR` | `~/.pi/agent` | Pi 会话存储与会话历史来源 |
| `PIGO_PI_BIN` | `pi` | pi 可执行文件 |
| `PIGO_PI_ARGS` | `[]` | JSON 字符串数组，追加到每个 Pi RPC 子进程的启动参数 |
| `PIGO_CODEX_BIN` / `PIGO_CODEX_ARGS` | `codex` / `[]` | Codex CLI 路径与额外参数 |
| `PIGO_CODEX_PERMISSION` | `bypass` | Codex 权限策略（`bypass` 或 `ask`） |
| `PIGO_AGY_BIN` / `PIGO_AGY_ARGS` | `agy` / `[]` | Antigravity CLI 路径与额外参数 |
| `PIGO_AGY_PERMISSION` | `bypass` | Antigravity 权限策略（`bypass` 或 `ask`） |
| `PIGO_PUSH_ACCOUNT_FILE` | — | 华为后台推送服务账号 JSON 路径 |

## Pi CLI 配置与共享会话

daemon 托管的 RPC 会话沿用 Pi CLI 的用户配置。可通过 `PIGO_PI_ARGS` 附加启动参数。手机打开桥已发现的活跃会话时，broker 复用既有进程。这些会话的终端交互仍在 Mac 上处理，daemon 托管会话的扩展交互可在手机上应答。

## 定时任务

在手机底部打开「任务」，在「定时任务」区块为当前电脑已共享的工作区添加计划。支持指定时间、按 Mac 时区每日执行和固定分钟间隔。Mac daemon 将计划和最近 80 次已结束的运行记录保存在 `PIGO_STATE_DIR/daemon/schedules.json`，每次运行创建独立 Pi 会话。

Mac 恢复后，默认跳过已错过的运行。设置补跑窗口后，窗口内最多补最近的一次，后续触发仍按原计划。中途重启的运行标记为中断，可从计划手动再运行。遇到需要输入或确认的扩展交互时，定时运行结束并记录原因。

手机在前台收取已配对电脑的运行结果，在底部「动态」页统一查看。App 回到前台会尝试补收。任务在 Mac 端保存成功后生效。

## 工作区提醒（本地事件推送）

任何本机脚本或后台服务都可以通过 `host/scripts/pigo-notify.mjs`（或本机 Unix socket 的 `POST /alerts/emit`）向 Pi Go 发送通用提醒，零 LLM token 即可到达手机收件箱、Push Kit 后台通知和已连接的华为手表：

```sh
node host/scripts/pigo-notify.mjs \
  --source my-watcher \
  --title "监控命中" \
  --body "关键指标已触发阈值" \
  --dedupe "rule-1-20261127" \
  --cwd "/path/to/workspace" \
  --prompt "结合当前工作区分析这次触发的原因"
```

绑定了已共享工作区（`--cwd`）的提醒，在手机收件箱中点开即可一键新建该工作区的 AI 会话并预填提示词；不带 `--cwd` 则作为全局提醒仅展示与推送。

## 测试

全量回归使用 `npm test`，使用隔离的 Pi 配置和 IPC 目录。

`PIGO_LIVE_PORT=<端口> node host/scripts/live-smoke.mjs` 使用真实模型验证 LAN 入口。先在独立端口启动 LAN 桥；脚本要求该桥尚未配对，测试结束后可停止测试桥并撤销测试凭证。

`node --test test/daemon.test.mjs` 用真实 `pi --mode rpc` + 离线 fixture provider 跑完整链路：open/new/authorize/catalog/projects/close-workspace、UI 请求应答（confirm/select/input/editor 含非法应答分支）、broker 配对后手机端 `/open` `/chat` 端到端、单实例互斥、SIGTERM 清理。
