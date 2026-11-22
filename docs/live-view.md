# HarmonyOS 任务实况窗

手机端使用 Live View Kit 为当前选中的 Agent 运行创建一个本地实况窗。卡片显示会话名、项目和状态，胶囊显示「排队中 / 运行中 / 等待处理 / 重新连接中」。点击实况窗会携带电脑地址和会话 ID 返回原会话；不展示消息正文、工具参数、代码或完整路径。

## 联调准备

仅有系统「实况窗」开关还不够。应用必须取得对应 `PROGRESS` 场景权益，否则 `startLiveView` 会返回 `1003500005`。

1. 在 AppGallery Connect 选择 `com.alex.pigo` 对应的应用，在「项目设置 → 开放能力管理」申请「实况窗服务」。
2. 开通推送服务，在手机端取得该应用的 Push Token。
3. 进入「增长 → 推送服务 → 配置 → 实况窗 → 调测设备管理」，按 Push Token 添加真机。官方说明调测名单最长 24 小时生效。
4. 真机联调通过后，在「增长 → 推送服务 → 配置 → 实况窗」申请 `PROGRESS` 场景正式权益。
5. 正式权益通过后重新生成 Profile，替换 `harmony/.sign/` 中的签名配置并重新构建。系统设置中也要允许 Pi Go 显示实况窗。

参考：[开通实况窗服务权益](https://developer.huawei.com/consumer/cn/doc/harmonyOS-Guides/liveview-rights)、[接入联调测试](https://developer.huawei.com/consumer/cn/doc/harmonyOS-Guides/liveview-joint-commission-test)、[申请正式权限](https://developer.huawei.com/consumer/cn/doc/harmonyOS-Guides/liveview-formal-authority)。

## 生命周期与降级

- 只有应用在前台且存在用户发起的运行时才能创建实况窗。
- 状态更新串行执行并合并到最新值，不转发 token 或每次工具调用。
- 任务结束、切换电脑、关闭功能或销毁 Ability 时结束实况窗，结束后不在通知中心保留。
- 胶囊图标放在 `entry/src/main/resources/rawfile/pigo.png`。真机验证中，缺少该图标会导致参数错误 `401`，即使 API 声明将图标标为可选。
- 应用退到后台时，仅在当前任务运行且实况窗开启的情况下保留事件流和轮询，以便在进程仍存活时更新结束状态。系统仍可能冻结进程；这不是可靠的后台推送。
- 应用被冻结或杀死后的更新与结束需要 Push Kit 和业务服务端投递，当前直连桥接不提供该保证。
- 「我的 → 任务实况窗」可关闭功能，并显示系统开关关闭、场景权益未开通等失败原因。

## 验证

```sh
zsh harmony/scripts/build-harmony.sh
zsh harmony/scripts/install-usb.sh
npm test
```

真机依次检查：创建与结束、排队与待审批、点击回到原会话、切换电脑、关闭开关、退后台后结束，以及无权益时的设置页提示。
