import { unboundAction } from './ComponentAction';
import { Companion } from '../CredentialVault';
import { APPEARANCE_MODES, AppearanceMode, THEME_STYLES, ThemeStyle, appearanceMode, themeStyle } from '../Appearance';
import { HuaweiProfile } from '../HuaweiProfile';
import { CloudComputer } from '../AccountSync';
import { validUsb } from '../PairingCode';
import { connectionLabel } from '../CompanionCheck';
import { ComputerGroup, computerGroups, computerGroupTitle } from '../ComputerGroups';

@Extend(Button)
function chatAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@Component
export struct SettingsView {
  @Prop accountBusy: boolean;
  @Prop accountNotice: string;
  @Require addComputerConnection: (id?: string) => void = unboundAction;
  @Prop addingComputer: boolean;
  @Link address: string;
  @Prop appearanceNotice: string;
  @Require assignComputerConnection: (address: string, group?: ComputerGroup) => void = unboundAction;
  @Link avatarUnavailable: boolean;
  @Prop base: string;
  @Prop bottomContentClearance: number;
  @Prop busy: boolean;
  @Require chooseComputer: (record: Companion) => void = unboundAction;
  @Require closeComputerEditors: () => void = unboundAction;
  @Link cloudComputers: CloudComputer[];
  @Prop cloudSyncBusy: boolean;
  @Prop cloudSyncStatus: string;
  @Require computerConnectionMenu: (record: Companion) => MenuElement[] = unboundAction;
  @Link computerNameDraft: string;
  @Link computers: Companion[];
  @Prop darkMode: boolean;
  @Require dismissKeyboard: () => void = unboundAction;
  @Require findLanCompanions: () => Promise<void> = unboundAction;
  @Prop huaweiProfile?: HuaweiProfile;
  @Prop isPaired: boolean;
  @Link lanCandidates: string[];
  @Prop liveViewStatus: string;
  @Prop liveViewsEnabled: boolean;
  @Link minePage: string;
  @Prop modeId: string;
  @Prop moveConnectionAddress: string;
  @Prop openingSession: boolean;
  @Require pair: () => Promise<void> = unboundAction;
  @Link pairingBundle: string;
  @Prop pairingComputerId: string;
  @Prop pairingMode: string;
  @Prop reachable: boolean;
  @Require removeCloudComputer: (computer: CloudComputer) => void = unboundAction;
  @Require removeComputer: (address: string) => void = unboundAction;
  @Link removeTarget: string;
  @Link renameComputerId: string;
  @Require restoreCloudComputer: (computer: CloudComputer) => void = unboundAction;
  @Prop restoringComputer?: CloudComputer;
  @Prop runNoticesEnabled: boolean;
  @Require saveComputerName: (id: string) => void = unboundAction;
  @Require scanPairingBundle: () => Promise<void> = unboundAction;
  @Require scheduleCloudSync: (delay?: number) => void = unboundAction;
  @Require selectAppearanceMode: (mode: AppearanceMode) => void = unboundAction;
  @Require selectPairingMode: (mode: string) => void = unboundAction;
  @Require selectTheme: (id: string) => void = unboundAction;
  @Require setLiveViewsEnabled: (enabled: boolean) => Promise<void> = unboundAction;
  @Require setRunNoticesEnabled: (enabled: boolean) => Promise<void> = unboundAction;
  @Require signInHuawei: () => Promise<void> = unboundAction;
  @Require signOutHuawei: () => Promise<void> = unboundAction;
  @Prop themeId: string;
  @Link ticket: string;
  @Prop topContentClearance: number;
  @Prop accent: string;
  @Prop accentForeground: string;
  @Prop accentTint: string;

  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.minePage === 'computers') {
          if (!this.addingComputer) {
            this.computerList()
            this.cloudComputerList()
          }
          if (this.addingComputer || !this.computers.length) {
            this.pairingForm()
          } else {
            Button('添加电脑').chatAction().id('add-computer').width('100%').height(46)
              .backgroundColor(this.accent).fontColor(this.accentForeground)
              .enabled(!this.busy && !this.openingSession && !this.removeTarget)
              .onClick(() => { this.addComputerConnection(); })
          }
        } else if (this.minePage === 'theme') {
          this.themeSettings()
        } else {
          this.profileCard()
          this.mineEntry('computers', '电脑管理', this.isPaired ?
            `${this.computerTitle()} · ${this.reachable ? '已连接' : '离线'}` :
            (this.computers.length ? `${computerGroups(this.computers).length} 台电脑` : '配对并连接电脑'))
          this.mineEntry('theme', '系统主题', `${themeStyle(this.themeId).label} · ${appearanceMode(this.modeId).label}`)
          this.runNoticeSettings()
          this.liveViewSettings()
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: this.topContentClearance, bottom: this.bottomContentClearance })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
  }
  @Builder
  computerConnection(record: Companion, group: ComputerGroup) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Row({ space: 6 }) {
                if (this.isPaired && this.base === record.address) {
                  Blank().width(7).height(7).borderRadius(4)
                    .backgroundColor(this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
                }
                Text(connectionLabel(record))
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
                if (this.isPaired && this.base === record.address) {
                  Text(this.reachable ? '当前 · 已连接' : '当前 · 离线')
                    .fontSize(11).fontWeight(FontWeight.Medium)
                    .fontColor(this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
                }
              }
              Text(record.address.split('://')[1]).fontSize(12).fontColor($r('app.color.pigo_muted'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            if (this.isPaired && this.base === record.address) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.accent])
            }
          }.width('100%')
        }.id(`computer-${record.address}`).accessibilityText(`${connectionLabel(record)} ${record.address.split('://')[1]}`)
          .layoutWeight(1).padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(this.isPaired && this.base === record.address ? this.accentTint : $r('app.color.pigo_control'))
          .border({ width: this.isPaired && this.base === record.address ? 1 : 0, radius: 12, color: this.accent })
          .enabled(!this.busy && !this.openingSession && !this.removeTarget)
          .onClick(() => {
            if (!this.isPaired || this.base !== record.address) this.chooseComputer(record);
          })
        if (this.removeTarget === record.address) {
          Button('确认移除').chatAction().id('confirm-remove').height(40).enabled(!this.busy)
            .backgroundColor($r('app.color.pigo_error_panel')).fontColor($r('app.color.pigo_error'))
            .onClick(() => { this.removeComputer(record.address); })
          Button('取消').chatAction().height(40).enabled(!this.busy).onClick(() => { this.removeTarget = ''; })
        } else {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_more')).width(18).height(18).fillColor($r('app.color.pigo_muted'))
          }.id(`remove-${record.address}`).width(40).height(44).padding(0).borderRadius(12)
            .backgroundColor(Color.Transparent)
            .accessibilityText('连接操作')
            .enabled(!this.busy && !this.openingSession && !this.removeTarget)
            .bindMenu(this.computerConnectionMenu(record))
        }
      }.width('100%')
      if (this.moveConnectionAddress === record.address) {
        Column({ space: 6 }) {
          Text('将此连接归到哪台电脑？').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
          ForEach(computerGroups(this.computers).filter((other: ComputerGroup): boolean => other.id !== group.id),
            (other: ComputerGroup) => {
              Button(computerGroupTitle(other)).chatAction().id(`move-to-${other.id}`).width('100%').height(40)
                .onClick(() => { this.assignComputerConnection(record.address, other); })
            }, (other: ComputerGroup) => `${other.id}|${other.name}`)
          if (group.connections.length > 1) {
            Button('设为独立电脑').chatAction().id('separate-connection').width('100%').height(40)
              .onClick(() => { this.assignComputerConnection(record.address); })
          }
          Button('取消').chatAction().width('100%').height(38).onClick(() => { this.closeComputerEditors(); })
        }.width('100%').padding(10).borderRadius(12).backgroundColor($r('app.color.launch_background'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  computerList() {
    ForEach(computerGroups(this.computers), (group: ComputerGroup) => {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.computer')).fontSize(20).fontColor([this.accent])
          Text(computerGroupTitle(group)).fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(18).fontColor([$r('app.color.pigo_text')])
          }.id(`add-connection-${group.id}`).width(36).height(36).padding(0).borderRadius(10)
            .backgroundColor($r('app.color.pigo_control'))
            .accessibilityText(`为${computerGroupTitle(group)}添加连接`)
            .enabled(!this.busy && !this.openingSession && !this.removeTarget)
            .onClick(() => { this.addComputerConnection(group.id); })
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.pencil_line')).fontSize(17).fontColor([$r('app.color.pigo_muted')])
          }.id(`rename-computer-${group.id}`).width(36).height(36).padding(0).borderRadius(10)
            .backgroundColor(Color.Transparent)
            .accessibilityText(`修改${computerGroupTitle(group)}备注`)
            .enabled(!this.busy && !this.removeTarget)
            .onClick(() => {
              this.closeComputerEditors();
              this.computerNameDraft = group.name;
              this.renameComputerId = group.id;
            })
        }.width('100%')
        if (this.renameComputerId === group.id) {
          TextInput({ placeholder: '电脑备注名', text: this.computerNameDraft }).id('computer-name-input')
            .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
            .placeholderColor($r('app.color.pigo_muted'))
            .maxLength(40).onChange((value: string) => { this.computerNameDraft = value; }).width('100%')
          Row({ space: 8 }) {
            Button('保存').chatAction().id('save-computer-name').height(38)
              .backgroundColor(this.accent).fontColor(this.accentForeground)
              .onClick(() => { this.saveComputerName(group.id); })
            Button('取消').chatAction().height(38).onClick(() => { this.closeComputerEditors(); this.dismissKeyboard(); })
          }.width('100%')
        }
        ForEach(group.connections, (record: Companion) => {
          this.computerConnection(record, group)
        }, (record: Companion) => record.address)
      }.width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
        .border({ width: 1, color: $r('app.color.pigo_line') })
    }, (group: ComputerGroup) => `${group.id}|${group.name}|${group.connections.map((record: Companion): string => record.address).join('|')}`)
    if (this.removeTarget) {
      Text(this.huaweiProfile ? '移除手机上的配对和账号列表中的连接记录。' : '移除手机上的这条配对记录。')
        .fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
    }
  }
  @Builder
  cloudComputerList() {
    if (this.cloudOnlyComputers().length) {
      Text('从账号恢复的连接').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).width('100%')
      ForEach(this.cloudOnlyComputers(), (computer: CloudComputer) => {
        Column({ space: 8 }) {
          Text(`${computer.mode === 'usb' ? 'USB' : computer.mode === 'lan' ? '局域网' : '公网'} · ${computer.address.split('://')[1]}`)
            .fontSize(15).fontColor($r('app.color.pigo_text')).width('100%')
          Row({ space: 8 }) {
            if (this.removeTarget === computer.address) {
              Button('从账号移除').chatAction().enabled(!this.busy)
                .backgroundColor($r('app.color.pigo_error_panel')).fontColor($r('app.color.pigo_error'))
                .onClick(() => { this.removeCloudComputer(computer); })
              Button('取消').chatAction().onClick(() => { this.removeTarget = ''; })
            } else {
              Button('在本机配对').chatAction().backgroundColor(this.accent).fontColor(this.accentForeground)
                .enabled(!this.busy && !this.openingSession && !this.removeTarget)
                .onClick(() => { this.restoreCloudComputer(computer); })
              Button('移除').chatAction().enabled(!this.busy && !this.removeTarget)
                .onClick(() => { this.removeTarget = computer.address; })
            }
          }.width('100%')
        }.width('100%').padding(14).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
          .border({ width: 1, color: $r('app.color.pigo_line') })
      }, (computer: CloudComputer) => computer.address)
    }
  }
  @Builder
  pairingForm() {
    Column({ space: 14 }) {
      if (this.pairingComputerId) {
        Text(this.pairingComputerTitle()).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.pigo_text')).width('100%')
      }
      if (this.restoringComputer) {
        Text('请从这台电脑获取新的配对码或配对包。')
          .fontSize(14).fontColor($r('app.color.pigo_text')).width('100%')
      }
      Row({ space: 4 }) {
        Button('USB', { type: ButtonType.Normal }).chatAction().id('usb-transport').layoutWeight(1).height(38).borderRadius(10)
          .accessibilitySelected(this.pairingMode === 'usb')
          .backgroundColor(this.pairingMode === 'usb' ? this.accent : Color.Transparent)
          .fontColor(this.pairingMode === 'usb' ? this.accentForeground : $r('app.color.pigo_muted'))
          .onClick(() => { this.selectPairingMode('usb'); })
        Button('局域网', { type: ButtonType.Normal }).chatAction().id('transport').layoutWeight(1).height(38).borderRadius(10)
          .accessibilitySelected(this.pairingMode === 'lan')
          .backgroundColor(this.pairingMode === 'lan' ? this.accent : Color.Transparent)
          .fontColor(this.pairingMode === 'lan' ? this.accentForeground : $r('app.color.pigo_muted'))
          .onClick(() => { this.selectPairingMode('lan'); })
        Button('公网', { type: ButtonType.Normal }).chatAction().id('remote-transport').layoutWeight(1).height(38).borderRadius(10)
          .accessibilitySelected(this.pairingMode === 'remote')
          .backgroundColor(this.pairingMode === 'remote' ? this.accent : Color.Transparent)
          .fontColor(this.pairingMode === 'remote' ? this.accentForeground : $r('app.color.pigo_muted'))
          .onClick(() => { this.selectPairingMode('remote'); })
      }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
        .enabled(!this.busy && !this.removeTarget)
      if (this.pairingMode !== 'usb') {
        Text(this.pairingMode === 'remote' ? '扫描或粘贴 Pi Go.app「公网」生成的配对包。' :
          '扫描或粘贴 Pi Go.app「局域网扫码」生成的配对包。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
        Row({ space: 8 }) {
          if (this.pairingMode === 'lan') {
            Button('发现电脑').chatAction().id('lan-discover').enabled(!this.busy && !this.removeTarget).onClick(() => { void this.findLanCompanions(); })
          }
          Button('扫码导入').chatAction().id(this.pairingMode === 'remote' ? 'remote-scan' : 'lan-scan')
            .enabled(!this.busy && !this.removeTarget).onClick(() => { void this.scanPairingBundle(); })
        }.width('100%')
        if (this.lanCandidates.length) {
          Text('附近地址（未验证）').fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
          Scroll() {
            Column({ space: 4 }) {
              ForEach(this.lanCandidates, (candidate: string) => {
                Text(candidate).width('100%').fontSize(14).fontColor($r('app.color.pigo_text'))
              }, (candidate: string) => candidate)
            }.width('100%')
          }.constraintSize({ maxHeight: 100 }).width('100%').scrollBar(BarState.Off)
        }
        TextInput({ placeholder: this.pairingMode === 'remote' ? '公网配对包' : '局域网配对包', text: this.pairingBundle })
          .id(this.pairingMode === 'remote' ? 'remote-bundle' : 'lan-bundle').type(InputType.Password).maxLength(4096)
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.pairingBundle = value; }).width('100%')
      } else {
        Text('用 USB 连接电脑并允许调试，再在 Pi Go.app 选择「USB」并点「连接手机」。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
        TextInput({ placeholder: 'USB 地址', text: this.address }).id('address')
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.address = value; }).width('100%')
        TextInput({ placeholder: '8 位配对码或一次性票据', text: this.ticket }).id('ticket').type(InputType.Password)
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.ticket = value; }).width('100%')
      }
      Button('配对并连接').chatAction().id('pair').enabled(!this.busy && !this.openingSession && !this.removeTarget)
        .backgroundColor(this.accent).fontColor(this.accentForeground).width('100%').height(46)
        .onClick(() => { void this.pair(); })
    }.padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(16).width('100%')
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }
  @Builder
  profileCard() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        Stack() {
          if (this.huaweiProfile?.avatar && !this.avatarUnavailable) {
            Image(this.huaweiProfile.avatar).width(50).height(50).objectFit(ImageFit.Cover)
              .onError(() => { this.avatarUnavailable = true; })
          } else {
            SymbolGlyph($r('sys.symbol.person')).fontSize(24).fontColor([this.accent])
          }
        }.width(50).height(50).backgroundColor(this.accentTint).borderRadius(25).clip(true)
        Column({ space: 4 }) {
          Text(this.huaweiProfile?.name || '个人资料').fontSize(19).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.huaweiProfile ? '华为账号已登录' : '华为账号未登录').fontSize(13).fontColor($r('app.color.pigo_muted'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.huaweiProfile) {
          Button(this.accountBusy ? '请稍候…' : '退出', { type: ButtonType.Normal })
            .id('huawei-signout').height(34).padding({ left: 12, right: 12 }).borderRadius(10)
            .fontSize(13).fontWeight(FontWeight.Medium)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.pigo_muted'))
            .enabled(!this.accountBusy)
            .onClick(() => { void this.signOutHuawei(); })
        }
      }.width('100%')
      if (!this.huaweiProfile) {
        Button(this.accountBusy ? '请稍候…' : '使用华为账号登录')
          .chatAction().id('huawei-account').width('100%').height(44).enabled(!this.accountBusy)
          .backgroundColor(this.accent).fontColor(this.accentForeground)
          .onClick(() => { void this.signInHuawei(); })
      }
      if (this.accountNotice) {
        Text(this.accountNotice).fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      if (this.huaweiProfile) {
        Divider().color($r('app.color.pigo_line'))
        Row({ space: 10 }) {
          Text(this.cloudSyncStatus || '通过华为云空间同步电脑列表和主题偏好。')
            .fontSize(13).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button(this.cloudSyncBusy ? '同步中…' : '立即同步').chatAction().id('sync-account-settings')
            .height(34).fontSize(13).padding({ left: 12, right: 12 })
            .enabled(!this.cloudSyncBusy && !this.accountBusy)
            .onClick(() => { this.scheduleCloudSync(0); })
        }.width('100%')
      }
    }.width('100%').padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }
  @Builder
  mineEntry(page: string, label: string, summary: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Stack() {
          if (page === 'computers') {
            SymbolGlyph($r('sys.symbol.computer')).fontSize(21).fontColor([this.accent])
          } else {
            Row({ space: 3 }) {
              Blank().width(6).height(6).borderRadius(3).backgroundColor(this.accentFor(THEME_STYLES[0]))
              Blank().width(6).height(6).borderRadius(3).backgroundColor(this.accentFor(THEME_STYLES[1]))
              Blank().width(6).height(6).borderRadius(3).backgroundColor(this.accentFor(THEME_STYLES[2]))
            }
          }
        }.width(40).height(40).backgroundColor(this.accentTint).borderRadius(12)
        Column({ space: 4 }) {
          Text(label).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          Text(summary).fontSize(13).fontColor($r('app.color.pigo_muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
      }.width('100%').padding(14)
    }.id(`mine-${page}`).width('100%').padding(0).backgroundColor($r('app.color.pigo_panel'))
      .border({ width: 1, radius: 16, color: $r('app.color.pigo_line') })
      .onClick(() => { this.minePage = page; })
  }
  @Builder
  themeSettings() {
    Column({ space: 10 }) {
      Text('显示模式').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
      Row({ space: 4 }) {
        ForEach(APPEARANCE_MODES, (mode: AppearanceMode) => {
          Button(mode.label, { type: ButtonType.Normal }).chatAction().layoutWeight(1).height(38).padding(4).borderRadius(10)
            .id(`appearance-${mode.id}`).accessibilitySelected(this.modeId === mode.id)
            .backgroundColor(this.modeId === mode.id ? this.accent : Color.Transparent)
            .fontColor(this.modeId === mode.id ? this.accentForeground : $r('app.color.pigo_muted'))
            .onClick(() => { this.selectAppearanceMode(mode); })
        }, (mode: AppearanceMode) => mode.id)
      }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
    }.width('100%').padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
    Column({ space: 6 }) {
      Text('主题配色').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
      ForEach(THEME_STYLES, (style: ThemeStyle) => {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            Blank().width(22).height(22).borderRadius(11).backgroundColor(this.accentFor(style))
            Text(style.label).fontSize(15).fontColor($r('app.color.pigo_text')).layoutWeight(1)
            if (this.themeId === style.id) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17).fontColor([this.accent])
            }
          }.width('100%').padding({ left: 12, right: 12 })
        }.id(`theme-${style.id}`).width('100%').height(44).padding(0).borderRadius(12)
          .accessibilitySelected(this.themeId === style.id)
          .backgroundColor(this.themeId === style.id ? this.accentTint : Color.Transparent)
          .onClick(() => { this.selectTheme(style.id); })
      }, (style: ThemeStyle) => style.id)
    }.width('100%').padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
    if (this.appearanceNotice) Text(this.appearanceNotice).fontSize(13).fontColor($r('app.color.pigo_warning'))
  }
  @Builder
  runNoticeSettings() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('运行结束通知').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        Text('任务结束时在应用顶部显示横幅').fontSize(13).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.runNoticesEnabled })
        .id('run-notice-setting').selectedColor(this.accent).accessibilityText('运行结束通知')
        .onChange((enabled: boolean) => { void this.setRunNoticesEnabled(enabled); })
    }.width('100%').padding(14).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }
  @Builder
  liveViewSettings() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('任务实况窗').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        Text(this.liveViewSummary()).fontSize(13).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.liveViewsEnabled })
        .id('live-view-setting').selectedColor(this.accent).accessibilityText('任务实况窗')
        .enabled(this.liveViewStatus !== 'rights')
        .onChange((enabled: boolean) => { void this.setLiveViewsEnabled(enabled); })
    }.width('100%').padding(14).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }
  private accentFor(style: ThemeStyle): string {
    return this.darkMode ? style.dark : style.light;
  }
  private cloudOnlyComputers(): CloudComputer[] {
    return this.cloudComputers.filter((row: CloudComputer): boolean =>
      !this.computers.some((local: Companion): boolean => local.address === row.address));
  }
  private pairingComputerTitle(): string {
    const group = computerGroups(this.computers).find((item: ComputerGroup): boolean => item.id === this.pairingComputerId);
    return group ? computerGroupTitle(group) : '';
  }
  private computerTitle(): string {
    const record = this.computers.find((item: Companion): boolean => item.address === this.base);
    return record?.computerName || (validUsb(this.base) ? 'USB 电脑' : (this.base.split('://')[1] || '我的电脑'));
  }
  private liveViewSummary(): string {
    if (this.liveViewStatus === 'rights') return '当前版本暂不支持系统实况窗';
    if (this.liveViewStatus === 'disabled') return '系统实况窗开关未开启，请在系统应用设置中开启';
    if (this.liveViewStatus === 'error') return '实况窗暂时不可用，将在运行期间自动重试';
    return '在状态栏、锁屏和通知中心显示当前任务状态';
  }
}
