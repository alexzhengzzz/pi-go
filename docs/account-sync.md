# 华为账号设置同步

Pi Go 通过华为云空间同步电脑地址和连接方式、主题配色以及显示模式。相同账号在新手机登录后，可在「电脑管理」看到恢复的连接，在「系统主题」使用已保存的偏好。电脑备注和连接归组保存在设置它们的手机上。「跟随系统」在每台设备上按本机系统外观显示。

电脑端为每台手机单独发放配对凭证。新手机点「在本机配对」后，使用电脑上生成的新票据或配对包。配对票据、连接令牌、TLS 证书和固定公钥、当前连接、聊天记录都保存在各自的设备或现有系统内。账号列表移除操作会同步到其他设备，已经在其他手机上建立的本机配对仍可使用，直到本机移除或电脑端吊销。

## 配置云空间开发环境

1. 在 AppGallery Connect 的 Pi Go 应用（`com.alex.pigo`）里配置设备调试签名指纹和 Account Kit。将该应用的 OAuth 2.0 Client ID 填入 `harmony/entry/src/main/module.json5` 的 `client_id`。
2. 给该应用启用「云空间」，在「构建 → 云空间服务」的开发环境创建容器 `pigo_sync`，对应本地数据库 `pigo_sync.db`。
3. 创建数据类型 `accountsettings`，字段配置如下。保留字段可空的默认配置。端侧使用 `recordkey` 作为去重主键。

   | 字段 | 云端类型 | 高级设置 |
   | --- | --- | --- |
   | `recordkey` | String | 端侧去重主键 |
   | `payload` | Encrypted String | |

4. 使用支持云空间同步的鸿蒙真机，在系统「设置 → 云空间」打开 Pi Go 同步。设备登录同一个华为账号后，在 Pi Go「我的」登录并点「立即同步」。已登录的设备打开页面或修改设置时也会触发同步。
5. 在第一台手机保存一个电脑条目、配色和显示模式并确认同步成功。在第二台手机检验三个设置是否恢复，再从第二台修改主题并在第一台同步，检查主题更新。最后移除一个恢复的电脑记录，确认账号列表同步移除，对应本机配对是否仍有效以各设备界面和电脑端授权为准。

调试签名连接开发环境，发布签名连接生产环境。发布前需要将通过真机验证的云端配置部署到生产环境。

- [华为云空间部署指南](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/data-sync-with-cloud/)
- [ArkData 关系型数据库端云同步](https://developer.huawei.com/consumer/cn/doc/harmonyos-Guides/data-cloud-sync-of-rdb-store/)
