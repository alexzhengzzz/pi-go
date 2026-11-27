# HarmonyOS 任务实况窗

Pi Go 使用 Live View Kit 的 `PROGRESS`（进度类型）场景。用户在手机前台发送任务或重新生成回复，电脑端确认派发后，Pi Go 为当前会话的这次运行创建一个本地实况窗。状态栏胶囊和卡片显示「排队中」「运行中」「等待处理」「重新连接中」。点击卡片返回对应会话；需要审批时，可在会话内处理。状态栏、锁屏和通知中心只显示通用任务标题和状态。

## 白名单联调

1. 在华为 HarmonyOS 开发者中心选择 Pi Go（`com.alex.pigo`）。项目的推送服务须已开通，且应用须已获实况窗功能入口。
2. 使用开启 Push Kit 后生成的调试 Profile 签名，构建并安装调试 HAP。需要登记新设备时，在 DevEco Studio 调试期间读取 `pushService.getToken()` 的返回值。出现 `1000900010` 时，检查调试包实际使用的 Profile 是否含推送服务能力。
3. 在「推送服务 → 配置」选择 Pi Go，从「实况窗 → 白名单设备管理」登记该调试包的 Push Token。华为说明入口和名单均可能延迟生效。系统设置中也要允许 Pi Go 显示实况窗。
4. 配对电脑，从手机发起一项有足够运行时间的任务，验证胶囊、通知中心卡片和锁屏效果，再点击实况窗回到对应会话。验证待处理、短暂断线后恢复、完成或终止、切换会话或电脑、关闭应用内开关和退出应用。仅浏览电脑发起的运行或定时任务时，检查是否保持无实况窗。
5. 保存真实联调截图。正式权限材料包含各状态节点的卡片、胶囊和锁屏效果、展示时机、点击路径及断线或用户关闭等特殊场景。按华为要求合并到一张不超过 3 MB 的图片，并在控制台提交进度类型场景正式权限申请。准备华为应用市场可下载的验收版本和配对体验步骤。
6. 正式权益通过后，在「证书、APP ID和Profile → Profile」新增并下载适用于 Pi Go 的发布 Profile，在 DevEco Studio 的发布签名配置中选用，再构建发布包。

参考：[接入准备](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V13/liveview-preparations-V13/) · [实况窗设计规范](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-design-formula#section596543013594) · [申请正式权限](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-formal-authority/)

## 生命周期与排查

- 同时只跟踪当前会话里由手机发起的一次运行。任务完成、取消、切换会话或电脑、关闭应用内开关时结束实况窗，通知中心随即清除卡片。
- 展示实际阶段，状态变化才更新系统实况窗。运行中如需审批，卡片提示返回会话处理。整个过程使用静默提醒。
- 退到后台时，应用进程仍可运行的情况下，通过现有事件流和轮询尝试更新和结束。HarmonyOS API 26.0.0 起，应用进程结束时由系统关闭实况窗。系统冻结期间本地状态更新可能延迟。
- `1003500005` 表示设备或应用版本缺少场景权益。如果调测设备已登记，按华为[错误码说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/liveview-error-code/)等待登记满 24 小时后复测。系统开关关闭时，可从系统设置重新开启。「我的 → 通知 → 任务实况窗」显示应用最近收到的状态。
- 胶囊图标使用 `entry/src/main/resources/rawfile/pigo.png`。已验证缺少该图标时可能返回参数错误 `401`。

```sh
npm test
zsh harmony/scripts/build-harmony.sh
zsh harmony/scripts/install-usb.sh
```
