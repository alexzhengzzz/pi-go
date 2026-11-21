# 通过 VPS 公网 IPv4 连接 Pi Desktop

手机直连 VPS 的公网 IPv4，VPS 通过 SSH 反向隧道转发到 Mac 的 `127.0.0.1:18982`。TLS 在 Mac 终止。桌面二维码包含公网地址、证书、公钥指纹和两分钟单次票据。局域网、公网和 USB 使用各自的服务与配对记录，可以同时运行，在手机的电脑列表切换。

## VPS 和 SSH

以下以 VPS 公网 TCP 8443、SSH 别名 `jp` 为例。确保 VPS 的防火墙和云安全组允许手机访问 TCP 8443。

在 Mac 上启动隧道，保持 SSH 进程运行。

```sh
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
  -R 127.0.0.1:29082:127.0.0.1:18982 jp
```

在 VPS 上把公网 TCP 8443 透传到 VPS 的 `127.0.0.1:29082`。例如使用已有 HAProxy，在配置中增加以下两个段并按 VPS 上的部署方式验证、重新加载。公网监听也可以绑定到 VPS 的具体网卡地址。

```haproxy
frontend pigo_remote
    bind 0.0.0.0:8443
    mode tcp
    timeout client 1m
    default_backend pigo_ssh

backend pigo_ssh
    mode tcp
    timeout connect 5s
    timeout server 1m
    server mac 127.0.0.1:29082
```

如果 VPS 已经对专用 SSH 帐号配置了 `GatewayPorts clientspecified`，也可以用 `-R 0.0.0.0:8443:127.0.0.1:18982` 直接监听公网端口，省去 TCP 代理。两种方式都由 Mac 的 HTTPS broker 提供证书。

如果 VPS 有 Python 3，也可以在 Mac 运行 `python3 scripts/run-remote-tunnel.py jp`。脚本同时建立 SSH 反向转发，并在 VPS 上启动 TCP 透传，对来源 IP 的连接速率和并发设上限。长期运行时可用 macOS 的 LaunchAgent 管理此命令，设置登录启动和退出重启，并用另一个 LaunchAgent 启动本地 broker。broker 的启动参数为 `node desktop/broker.mjs 18982 --remote <VPS公网IPv4> 8443`。使用相同的公网地址和本机 Pi 用户目录可复用凭证。

## 配对

1. Mac 安装或更新 Pi Go 扩展并重开 Pi Desktop 会话。运行 `npm run build:pairing`，打开生成的 Pi Go Pairing 应用。手机安装同步更新的 Pi Go。
2. 配对窗口选择「公网」，填 VPS 的公网 IPv4 和端口 `8443`，点「启动公网配对」。
3. 手机打开「公网 → 扫码导入」，确认显示的 VPS 地址，点「配对并连接」。验收时关闭 Wi-Fi，用蜂窝网络打开会话、发送带附件的消息、查看流式回复，并验证工作区文件与手机审批。
4. 平时在手机「我的 → 已配对的电脑」直接点选已保存的「公网」或「Wi-Fi」连接。Mac 保持唤醒，Pi Desktop 和隧道保持运行。停止公网服务后可以按原配置重新启动并复用配对。更换公网地址需要重新扫码。

公网和 Wi-Fi 共用 Pi Desktop 会话目录与聊天界面。两种连接均可在输入框旁切换模型、发送附件、浏览和编辑已共享工作区的文件，以及在手机上回复 Pi Desktop 审批。公网使用独立的配对凭证和请求限流。Pi agent 的实际执行权限由 Mac 上的 Pi Desktop 和运行环境决定。手机遗失时，可以在配对窗口撤销公网凭证并断开现有的公网事件流。
