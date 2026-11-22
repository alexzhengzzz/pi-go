# Pi Go daemon

一个零依赖的 Node 守护进程，替代打了补丁的 Pi Desktop，充当 Pi Go 桥的手机侧常驻宿主。Pi Desktop 退出后，手机仍可打开历史、管理工作区和新建会话。

## 它是什么

```
鸿蒙手机 ──HTTPS/SSE── broker.mjs（不变）── worker socket ── phase0.ts 扩展（不变）
                        │                        （pi --mode rpc 子进程，由 daemon 派生）
                        └── host socket ── daemon（本目录）
```

- **`daemon.mjs`** — 入口。单实例（发现活的 host socket 即退出）、SIGTERM 优雅停机、常驻运行（launchd 或直接 `node daemon/daemon.mjs`）。
- **`host.mjs`** — 实现 `pi-go-desktop-host/1` 协议（`desktop/pi-go-host.ts` 的对等物）：`/health /open /new /catalog /projects /authorize /pending /answer /create-workspace /close-workspace`。broker 通过 `local-ipc.mjs` 的 `desktopHosts()` 按 socket 文件名 + 协议字符串发现它，**broker、扩展、手机端均零改动**。
- **`runtimes.mjs`** — RPC 子进程池。每个会话 spawn 一个 `pi --mode rpc [--session <file>]`（cwd = 工作区），走公开的 JSON-lines RPC 协议（stdin 命令 / stdout 响应与事件）。`extension_ui_request`（confirm/select/input/editor）被跟踪并经 `/pending` `/answer` 暴露给手机，应答以 `extension_ui_response` 写回。校验语义（类型、长度上限、选项归属）逐条对齐 Desktop 补丁的 `pendingForPiGo` / `respondFromPiGo`。
- **`catalog.mjs`** — 扫描原生会话存储（`PI_CODING_AGENT_DIR/sessions`）按项目 realpath 过滤历史，支持 `<id>.jsonl` 与 `<slug>_<id>.jsonl` 两种文件名。
- **`registry.mjs`** — 工作区注册表（JSON 持久化于 `PIGO_STATE_DIR/daemon/workspaces.json`），替代 Desktop 的 `WorkspaceManager` 持久层。关闭工作区 = 停进程 + 移除登记，**不删文件**。

## macOS 安装与 USB 切换

1. 退出 Pi Desktop，让 daemon 成为该账号唯一的 Pi Go 宿主。已共享的交互式 Pi CLI 会话可继续运行。
2. 在仓库根目录执行以下命令。已有 USB 配对可以继续使用，桥接端口保持一致。

   ```sh
   pi install "$PWD"
   PIGO_USB_PORT=18977 npm run install:daemon
   ```

   daemon 和 USB 桥由 launchd 登录自启，并在退出后重启。仅需安装宿主时可省略 `PIGO_USB_PORT`。日志在
   `~/Library/Logs/dev.pi.go.daemon.log` 与 `~/Library/Logs/dev.pi.go.bridge.usb.18977.log`。
   已配置的 LAN 和公网桥可以继续发现同一个 daemon。
3. USB 调试和反向端口配置见 [USB 真机联调](../docs/usb.md)。手机连接后可打开现有历史，daemon 会登记该会话所在的工作区。需要继续分享交互式 Pi CLI 会话时，在该会话运行 `/pi-go-share`，再在手机上打开活跃会话。

前台调试可直接运行 `node daemon/daemon.mjs`。返回 Desktop 前，先执行
`launchctl bootout "gui/$(id -u)/dev.pi.go.daemon"` 停止当前 daemon；若需要恢复为 Desktop-only 的登录方式，再移除对应的 daemon LaunchAgent plist。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PIGO_IPC_DIR` | `$TMPDIR/pigo-<uid>` | host/worker socket 目录（与 broker、扩展共享） |
| `PIGO_STATE_DIR` | `<ipc>/state` 或 `~/.pi-go` | 注册表等持久化状态 |
| `PI_CODING_AGENT_DIR` | `~/.pi/agent` | Pi 会话存储与会话历史来源 |
| `PIGO_PI_BIN` | `pi` | pi 可执行文件 |
| `PIGO_PI_ARGS` | `[]` | JSON 字符串数组，追加到每个 RPC 子进程的启动参数 |

## 与 Desktop 宿主的差异

- **并发仲裁简化**：没有桌面 UI 抢答对话框，手机是唯一应答端；Desktop 补丁中“至多赢一次”的竞争逻辑不再需要。
- **扩展加载**：被托管的 RPC 会话沿用 Pi CLI 的配置。可通过 `PIGO_PI_ARGS` 显式指定附加启动选项。
- **宿主授权与手机配对独立**：只授权了单个项目的桥需要为 daemon 重新授予项目访问。沿用同一端口及 Pi 数据目录时，现有 USB 配对继续有效。
- **共享活跃会话**：手机打开已由 Pi CLI 共享的会话时，broker 复用既有进程。CLI 会话的终端交互仍在 Mac 上处理，daemon 启动的会话可以在手机上应答。

## 测试

全量回归使用 `npm test`。要同时回归旧宿主，可用 `PIGO_DESKTOP_APP` 指定已经打过 Pi Go 补丁的 Desktop 应用，测试会使用隔离的 Pi 配置和 IPC 目录。

`PIGO_LIVE_PORT=<端口> node scripts/live-smoke.mjs` 使用真实模型验证 LAN 入口。先在独立端口启动 LAN 桥；脚本要求该桥尚未配对，测试结束后可停止测试桥并撤销测试凭证。

`node --test test/daemon.test.mjs` 用真实 `pi --mode rpc` + 离线 fixture provider 跑完整链路：open/new/authorize/catalog/projects/close-workspace、UI 请求应答（confirm/select/input/editor 含非法应答分支）、broker 配对后手机端 `/open` `/chat` 端到端、单实例互斥、SIGTERM 清理。
