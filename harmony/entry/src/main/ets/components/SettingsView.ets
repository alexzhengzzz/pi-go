import { PiGoPageStore } from '../model/PiGoPageStore';
import { glassCardSurface, themedCardSurface } from '../Immersive';
import { SakuraPetals } from './SakuraPetals';
import { DeepSeaScene } from './DeepSeaScene';
import { InkScene } from './InkScene';
import { SaharaScene } from './SaharaScene';
import { SunsetScene } from './SunsetScene';
import { Companion } from '../CredentialVault';
import { APPEARANCE_MODES, AppearanceMode, THEME_STYLES, ThemePalette, ThemeStyle, appearanceMode, themePalette, themeStyle } from '../Appearance';
import { HuaweiProfile } from '../HuaweiProfile';
import { CloudComputer } from '../AccountSync';
import { validUsb } from '../PairingCode';
import { connectionLabel } from '../CompanionCheck';
import { ComputerGroup, computerGroups, computerGroupTitle } from '../ComputerGroups';
import { parentPageTransition, subPageTransition } from './PageTransitions';

@Extend(Button)
function chatAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@ComponentV2
export struct SettingsView {
  @Param @Require store: PiGoPageStore;
  @Param active: boolean = true;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.store.minePage === 'computers') {
        Scroll() {
          Column({ space: 12 }) {
            if (!this.store.addingComputer) {
              this.computerList()
              this.cloudComputerList()
            }
            if (this.store.addingComputer || !this.store.computers.length) {
              this.pairingForm()
            } else {
              Button('添加电脑').chatAction().id('add-computer').width('100%').height(46)
                .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground())
                .enabled(!this.store.session.busy && !this.store.session.openingSession && !this.store.removeTarget)
                .onClick(() => { this.store.addComputerConnection(); })
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: this.store.topContentClearance(), bottom: this.store.bottomContentClearance() })
        }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring).transition(subPageTransition())
      } else if (this.store.minePage === 'theme') {
        Scroll() {
          Column({ space: 12 }) {
            this.themeSettings()
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: this.store.topContentClearance(), bottom: this.store.bottomContentClearance() })
        }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring).transition(subPageTransition())
      } else {
        Scroll() {
          Column({ space: 12 }) {
            this.profileCard()
            this.mineEntry('computers', '电脑管理', this.store.isPaired ?
              `${this.computerTitle()} · ${this.store.session.reachable ? '已连接' : '离线'}` :
              (this.store.computers.length ? `${computerGroups(this.store.computers).length} 台电脑` : '配对并连接电脑'))
            this.mineEntry('theme', '系统主题', `${themeStyle(this.store.themeId).label} · ${appearanceMode(this.store.modeId).label}`)
            this.runNoticeSettings()
            this.liveViewSettings()
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: this.store.topContentClearance(), bottom: this.store.bottomContentClearance() })
        }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring).transition(parentPageTransition())
      }
    }.layoutWeight(1).width('100%')
  }
  @Builder
  computerConnection(record: Companion, group: ComputerGroup) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Row({ space: 6 }) {
                if (this.store.isPaired && this.store.base === record.address) {
                  Blank().width(7).height(7).borderRadius(4)
                    .backgroundColor(this.store.session.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
                }
                Text(connectionLabel(record))
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
                if (this.store.isPaired && this.store.base === record.address) {
                  Text(this.store.session.reachable ? '当前 · 已连接' : '当前 · 离线')
                    .fontSize(11).fontWeight(FontWeight.Medium)
                    .fontColor(this.store.session.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
                }
              }
              Text(record.address.split('://')[1]).fontSize(12).fontColor($r('app.color.pigo_muted'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            if (this.store.isPaired && this.store.base === record.address) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.store.accent()])
            }
          }.width('100%')
        }.id(`computer-${record.address}`).accessibilityText(`${connectionLabel(record)} ${record.address.split('://')[1]}`)
          .layoutWeight(1).padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(this.store.isPaired && this.store.base === record.address ? this.store.accentTint() : $r('app.color.pigo_control'))
          .border({ width: this.store.isPaired && this.store.base === record.address ? 1 : 0, radius: 12, color: this.store.accent() })
          .enabled(!this.store.session.busy && !this.store.session.openingSession && !this.store.removeTarget)
          .onClick(() => {
            if (!this.store.isPaired || this.store.base !== record.address) this.store.chooseComputer(record);
          })
        if (this.store.removeTarget === record.address) {
          Button('确认移除').chatAction().id('confirm-remove').height(40).enabled(!this.store.session.busy)
            .backgroundColor($r('app.color.pigo_error_panel')).fontColor($r('app.color.pigo_error'))
            .onClick(() => { this.store.removeComputer(record.address); })
          Button('取消').chatAction().height(40).enabled(!this.store.session.busy).onClick(() => { this.store.removeTarget = ''; })
        } else {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_more')).width(18).height(18).fillColor($r('app.color.pigo_muted'))
          }.id(`remove-${record.address}`).width(40).height(44).padding(0).borderRadius(12)
            .backgroundColor(Color.Transparent)
            .accessibilityText('连接操作')
            .enabled(!this.store.session.busy && !this.store.session.openingSession && !this.store.removeTarget)
            .bindMenu(this.store.computerConnectionMenu(record))
        }
      }.width('100%')
      if (this.store.moveConnectionAddress === record.address) {
        Column({ space: 6 }) {
          Text('将此连接归到哪台电脑？').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
          ForEach(computerGroups(this.store.computers).filter((other: ComputerGroup): boolean => other.id !== group.id),
            (other: ComputerGroup) => {
              Button(computerGroupTitle(other)).chatAction().id(`move-to-${other.id}`).width('100%').height(40)
                .onClick(() => { this.store.assignComputerConnection(record.address, other); })
            }, (other: ComputerGroup) => `${other.id}|${other.name}`)
          if (group.connections.length > 1) {
            Button('设为独立电脑').chatAction().id('separate-connection').width('100%').height(40)
              .onClick(() => { this.store.assignComputerConnection(record.address); })
          }
          Button('取消').chatAction().width('100%').height(38).onClick(() => { this.store.closeComputerEditors(); })
        }.width('100%').padding(10).borderRadius(12).backgroundColor($r('app.color.launch_background'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  computerList() {
    ForEach(computerGroups(this.store.computers), (group: ComputerGroup) => {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.computer')).fontSize(20).fontColor([this.store.accent()])
          Text(computerGroupTitle(group)).fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(18).fontColor([$r('app.color.pigo_text')])
          }.id(`add-connection-${group.id}`).width(36).height(36).padding(0).borderRadius(10)
            .backgroundColor($r('app.color.pigo_control'))
            .accessibilityText(`为${computerGroupTitle(group)}添加连接`)
            .enabled(!this.store.session.busy && !this.store.session.openingSession && !this.store.removeTarget)
            .onClick(() => { this.store.addComputerConnection(group.id); })
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.pencil_line')).fontSize(17).fontColor([$r('app.color.pigo_muted')])
          }.id(`rename-computer-${group.id}`).width(36).height(36).padding(0).borderRadius(10)
            .backgroundColor(Color.Transparent)
            .accessibilityText(`修改${computerGroupTitle(group)}备注`)
            .enabled(!this.store.session.busy && !this.store.removeTarget)
            .onClick(() => {
              this.store.closeComputerEditors();
              this.store.computerNameDraft = group.name;
              this.store.renameComputerId = group.id;
            })
        }.width('100%')
        if (this.store.renameComputerId === group.id) {
          TextInput({ placeholder: '电脑备注名', text: this.store.computerNameDraft }).id('computer-name-input')
            .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
            .placeholderColor($r('app.color.pigo_muted'))
            .maxLength(40).onChange((value: string) => { this.store.computerNameDraft = value; }).width('100%')
          Row({ space: 8 }) {
            Button('保存').chatAction().id('save-computer-name').height(38)
              .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground())
              .onClick(() => { this.store.saveComputerName(group.id); })
            Button('取消').chatAction().height(38).onClick(() => { this.store.closeComputerEditors(); this.store.dismissKeyboard(); })
          }.width('100%')
        }
        ForEach(group.connections, (record: Companion) => {
          this.computerConnection(record, group)
        }, (record: Companion) => record.address)
      }.width('100%').padding(14).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
    }, (group: ComputerGroup) => `${group.id}|${group.name}|${group.connections.map((record: Companion): string => record.address).join('|')}`)
    if (this.store.removeTarget) {
      Text(this.store.accountSync.state.huaweiProfile ? '移除手机上的配对和账号列表中的连接记录。' : '移除手机上的这条配对记录。')
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
            if (this.store.removeTarget === computer.address) {
              Button('从账号移除').chatAction().enabled(!this.store.session.busy)
                .backgroundColor($r('app.color.pigo_error_panel')).fontColor($r('app.color.pigo_error'))
                .onClick(() => { this.store.removeCloudComputer(computer); })
              Button('取消').chatAction().onClick(() => { this.store.removeTarget = ''; })
            } else {
              Button('在本机配对').chatAction().backgroundColor(this.store.accent()).fontColor(this.store.accentForeground())
                .enabled(!this.store.session.busy && !this.store.session.openingSession && !this.store.removeTarget)
                .onClick(() => { this.store.restoreCloudComputer(computer); })
              Button('移除').chatAction().enabled(!this.store.session.busy && !this.store.removeTarget)
                .onClick(() => { this.store.removeTarget = computer.address; })
            }
          }.width('100%')
        }.width('100%').padding(14).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      }, (computer: CloudComputer) => computer.address)
    }
  }
  @Builder
  pairingForm() {
    Column({ space: 14 }) {
      if (this.store.pairingComputerId) {
        Text(this.pairingComputerTitle()).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.pigo_text')).width('100%')
      }
      if (this.store.restoringComputer) {
        Text('请从这台电脑获取新的配对码或配对包。')
          .fontSize(14).fontColor($r('app.color.pigo_text')).width('100%')
      }
      Row({ space: 4 }) {
        Button('USB', { type: ButtonType.Normal }).chatAction().id('usb-transport').layoutWeight(1).height(38).borderRadius(10)
          .accessibilitySelected(this.store.pairingMode === 'usb')
          .backgroundColor(this.store.pairingMode === 'usb' ? this.store.accent() : Color.Transparent)
          .fontColor(this.store.pairingMode === 'usb' ? this.store.accentForeground() : $r('app.color.pigo_muted'))
          .onClick(() => { this.store.selectPairingMode('usb'); })
        Button('局域网', { type: ButtonType.Normal }).chatAction().id('transport').layoutWeight(1).height(38).borderRadius(10)
          .accessibilitySelected(this.store.pairingMode === 'lan')
          .backgroundColor(this.store.pairingMode === 'lan' ? this.store.accent() : Color.Transparent)
          .fontColor(this.store.pairingMode === 'lan' ? this.store.accentForeground() : $r('app.color.pigo_muted'))
          .onClick(() => { this.store.selectPairingMode('lan'); })
        Button('公网', { type: ButtonType.Normal }).chatAction().id('remote-transport').layoutWeight(1).height(38).borderRadius(10)
          .accessibilitySelected(this.store.pairingMode === 'remote')
          .backgroundColor(this.store.pairingMode === 'remote' ? this.store.accent() : Color.Transparent)
          .fontColor(this.store.pairingMode === 'remote' ? this.store.accentForeground() : $r('app.color.pigo_muted'))
          .onClick(() => { this.store.selectPairingMode('remote'); })
      }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
        .enabled(!this.store.session.busy && !this.store.removeTarget)
      if (this.store.pairingMode !== 'usb') {
        Text(this.store.pairingMode === 'remote' ? '扫描或粘贴 Pi Go.app「公网」生成的配对包。' :
          '扫描或粘贴 Pi Go.app「局域网扫码」生成的配对包。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
        Row({ space: 8 }) {
          if (this.store.pairingMode === 'lan') {
            Button('发现电脑').chatAction().id('lan-discover').enabled(!this.store.session.busy && !this.store.removeTarget).onClick(() => { void this.store.findLanCompanions(); })
          }
          Button('扫码导入').chatAction().id(this.store.pairingMode === 'remote' ? 'remote-scan' : 'lan-scan')
            .enabled(!this.store.session.busy && !this.store.removeTarget).onClick(() => { void this.store.scanPairingBundle(); })
        }.width('100%')
        if (this.store.lanCandidates.length) {
          Text('附近地址（未验证）').fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
          Scroll() {
            Column({ space: 4 }) {
              ForEach(this.store.lanCandidates, (candidate: string) => {
                Text(candidate).width('100%').fontSize(14).fontColor($r('app.color.pigo_text'))
              }, (candidate: string) => candidate)
            }.width('100%')
          }.constraintSize({ maxHeight: 100 }).width('100%').scrollBar(BarState.Off)
        }
        TextInput({ placeholder: this.store.pairingMode === 'remote' ? '公网配对包' : '局域网配对包', text: this.store.pairingBundle })
          .id(this.store.pairingMode === 'remote' ? 'remote-bundle' : 'lan-bundle').type(InputType.Password).maxLength(4096)
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.store.pairingBundle = value; }).width('100%')
      } else {
        Text('用 USB 连接电脑并允许调试，再在 Pi Go.app 选择「USB」并点「连接手机」。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
        TextInput({ placeholder: 'USB 地址', text: this.store.appState.address }).id('address')
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.store.appState.address = value; }).width('100%')
        TextInput({ placeholder: '8 位配对码或一次性票据', text: this.store.ticket }).id('ticket').type(InputType.Password)
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.store.ticket = value; }).width('100%')
      }
      Button('配对并连接').chatAction().id('pair').enabled(!this.store.session.busy && !this.store.session.openingSession && !this.store.removeTarget)
        .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground()).width('100%').height(46)
        .onClick(() => { void this.store.pair(); })
    }.padding(16).width('100%').attributeModifier(glassCardSurface(this.store.darkMode, 16))
  }
  @Builder
  profileCard() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        Stack() {
          if (this.store.accountSync.state.huaweiProfile?.avatar && !this.store.avatarUnavailable) {
            Image(this.store.accountSync.state.huaweiProfile.avatar).width(50).height(50).objectFit(ImageFit.Cover)
              .onError(() => { this.store.avatarUnavailable = true; })
          } else {
            SymbolGlyph($r('sys.symbol.person')).fontSize(24).fontColor([this.store.accent()])
          }
        }.width(50).height(50).backgroundColor(this.store.accentTint()).borderRadius(25).clip(true)
        Column({ space: 4 }) {
          Text(this.store.accountSync.state.huaweiProfile?.name || '个人资料').fontSize(19).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.store.accountSync.state.huaweiProfile ? '华为账号已登录' : '华为账号未登录').fontSize(13).fontColor($r('app.color.pigo_muted'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.store.accountSync.state.huaweiProfile) {
          Button(this.store.accountSync.state.accountBusy ? '请稍候…' : '退出', { type: ButtonType.Normal })
            .id('huawei-signout').height(34).padding({ left: 12, right: 12 }).borderRadius(10)
            .fontSize(13).fontWeight(FontWeight.Medium)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.pigo_muted'))
            .enabled(!this.store.accountSync.state.accountBusy)
            .onClick(() => { void this.store.accountSync.signOutHuawei(); })
        }
      }.width('100%')
      if (!this.store.accountSync.state.huaweiProfile) {
        Button(this.store.accountSync.state.accountBusy ? '请稍候…' : '使用华为账号登录')
          .chatAction().id('huawei-account').width('100%').height(44).enabled(!this.store.accountSync.state.accountBusy)
          .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground())
          .onClick(() => { void this.store.accountSync.signInHuawei(); })
      }
      if (this.store.accountSync.state.accountNotice) {
        Text(this.store.accountSync.state.accountNotice).fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      if (this.store.accountSync.state.huaweiProfile) {
        Divider().color($r('app.color.pigo_line'))
        Row({ space: 10 }) {
          Text(this.store.accountSync.state.cloudSyncStatus || '通过华为云空间同步电脑列表和主题偏好。')
            .fontSize(13).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button(this.store.accountSync.state.cloudSyncBusy ? '同步中…' : '立即同步').chatAction().id('sync-account-settings')
            .height(34).fontSize(13).padding({ left: 12, right: 12 })
            .enabled(!this.store.accountSync.state.cloudSyncBusy && !this.store.accountSync.state.accountBusy)
            .onClick(() => { this.store.accountSync.scheduleCloudSync(0); })
        }.width('100%')
      }
    }.width('100%').padding(16).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
  }
  @Builder
  mineEntry(page: string, label: string, summary: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Stack() {
          if (page === 'computers') {
            SymbolGlyph($r('sys.symbol.computer')).fontSize(21).fontColor([this.store.accent()])
          } else {
            Row({ space: 3 }) {
              Blank().width(6).height(6).borderRadius(3).backgroundColor(this.paletteFor(themeStyle('sakura')).accent)
              Blank().width(6).height(6).borderRadius(3).backgroundColor(this.paletteFor(themeStyle('sunset')).accent)
              Blank().width(6).height(6).borderRadius(3).backgroundColor(this.paletteFor(themeStyle('graphite')).accent)
            }
          }
        }.width(40).height(40).backgroundColor(this.store.accentTint()).borderRadius(12)
        Column({ space: 4 }) {
          Text(label).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          Text(summary).fontSize(13).fontColor($r('app.color.pigo_muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
      }.width('100%').padding(14)
    }.id(`mine-${page}`).width('100%').padding(0)
      .attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      .onClick(() => { this.store.minePage = page; })
  }
  @Builder
  themePreviewCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('效果预览').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
        Text(`${themeStyle(this.store.themeId).label} · ${themeStyle(this.store.themeId).styleTag}`)
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.store.accent())
      }.width('100%')
      Stack() {
        Column()
          .width('100%').height('100%')
          .radialGradient({
            center: ['15%', '12%'],
            radius: '82%',
            colors: [[this.activePalette().auraTop, 0], ['#00000000', 1]]
          })
        Column()
          .width('100%').height('100%')
          .radialGradient({
            center: ['88%', '88%'],
            radius: '78%',
            colors: [[this.activePalette().auraBottom, 0], ['#00000000', 1]]
          })
        if (this.store.themeId === 'graphite') {
          if (this.store.themeMotionEnabled) {
            InkScene({ darkMode: this.store.darkMode, compact: true, active: this.active && this.store.minePage === 'theme' })
          } else {
            Image($rawfile(this.store.darkMode ? 'ink_dark.jpg' : 'ink_light.jpg'))
              .width('100%').height('100%').objectFit(ImageFit.Cover).opacity(this.store.darkMode ? 0.78 : 0.85)
          }
        } else if (this.store.themeId === 'sunset') {
          if (this.store.themeMotionEnabled) {
            SunsetScene({ darkMode: this.store.darkMode, compact: true, active: this.active && this.store.minePage === 'theme' })
          } else {
            Image($rawfile(this.store.darkMode ? 'sunset_dark.jpg' : 'sunset_light.jpg'))
              .width('100%').height('100%').objectFit(ImageFit.Cover).opacity(this.store.darkMode ? 0.78 : 0.85)
          }
        } else if (this.store.themeId === 'jellyfish') {
          if (this.store.themeMotionEnabled) {
            DeepSeaScene({ darkMode: this.store.darkMode, compact: true, active: this.active && this.store.minePage === 'theme' })
          } else {
            Image($rawfile(this.store.darkMode ? 'jellyfish_dark.jpg' : 'jellyfish_light.jpg'))
              .width('100%').height('100%').objectFit(ImageFit.Cover).opacity(this.store.darkMode ? 0.78 : 0.85)
          }
        } else if (this.store.themeId === 'sahara') {
          if (this.store.themeMotionEnabled) {
            SaharaScene({ darkMode: this.store.darkMode, compact: true, active: this.active && this.store.minePage === 'theme' })
          } else {
            Image($rawfile(this.store.darkMode ? 'sahara_dark.jpg' : 'sahara_light.jpg'))
              .width('100%').height('100%').objectFit(ImageFit.Cover).opacity(this.store.darkMode ? 0.78 : 0.85)
          }
        } else {
          Image($rawfile(this.store.darkMode ? 'sakura_dark.jpg' : 'sakura_light.jpg'))
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .opacity(this.store.darkMode ? 0.72 : 0.78)
          if (this.store.themeMotionEnabled && this.active && this.store.minePage === 'theme') SakuraPetals({ darkMode: this.store.darkMode, compact: true })
        }
        Column({ space: 8 }) {
          Row() {
            Text(this.store.themeId === 'sakura' ? '今天也要像樱花一样元气满满 ✿' : '帮我切换到一个更有氛围的主题')
              .fontSize(13).fontColor($r('app.color.pigo_text'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .backgroundColor(themeStyle(this.store.themeId).bubble === 'gradient' ? Color.Transparent : this.activePalette().bubbleStart)
              .linearGradient(themeStyle(this.store.themeId).bubble === 'gradient' ? {
                angle: 135,
                colors: [[this.activePalette().bubbleStart, 0], [this.activePalette().bubbleEnd, 1]]
              } : undefined)
              .borderRadius({
                topLeft: themeStyle(this.store.themeId).bubbleRadius,
                topRight: Math.max(4, Math.round(themeStyle(this.store.themeId).bubbleRadius * 0.35)),
                bottomLeft: themeStyle(this.store.themeId).bubbleRadius,
                bottomRight: themeStyle(this.store.themeId).bubbleRadius
              })
              .border({
                width: themeStyle(this.store.themeId).bubble === 'outline' ? 1.2 : (this.store.themeId === 'sakura' ? 1 : 0.6),
                radius: {
                  topLeft: themeStyle(this.store.themeId).bubbleRadius,
                  topRight: Math.max(4, Math.round(themeStyle(this.store.themeId).bubbleRadius * 0.35)),
                  bottomLeft: themeStyle(this.store.themeId).bubbleRadius,
                  bottomRight: themeStyle(this.store.themeId).bubbleRadius
                },
                color: this.activePalette().bubbleBorder
              })
              .shadow(this.store.themeId === 'sakura'
                ? { radius: 10, offsetY: 2, color: this.store.darkMode ? '#33FF7EB3' : '#2CE86A98' }
                : undefined)
          }.width('100%').justifyContent(FlexAlign.End)
          Column() {
            Row() {
              Text('ts').fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.store.accent()).layoutWeight(1)
              Text(themeStyle(this.store.themeId).subtitle).fontSize(10).fontColor($r('app.color.pigo_muted'))
            }.width('100%').padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor(this.activePalette().codeHeaderBg)
              .border({ width: { bottom: 0.5 }, color: this.activePalette().codeBorder })
            Row({ space: 8 }) {
              Text(`const theme = "${themeStyle(this.store.themeId).id}";`)
                .fontSize(12).fontFamily('monospace').fontColor($r('app.color.pigo_text')).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('发送').fontSize(11).fontWeight(FontWeight.Medium).fontColor(this.store.accentForeground())
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .backgroundColor(this.store.accent()).borderRadius(Math.min(10, themeStyle(this.store.themeId).codeRadius))
            }.width('100%').alignItems(VerticalAlign.Center).padding({ left: 10, right: 8, top: 7, bottom: 7 })
          }.width('100%').clip(true)
            .backgroundColor(this.activePalette().codeBg)
            .borderRadius(themeStyle(this.store.themeId).codeRadius)
            .border({ width: 1, radius: themeStyle(this.store.themeId).codeRadius, color: this.activePalette().codeBorder })
        }.width('100%').padding(12)
      }.width('100%').clip(true)
        .backgroundColor(this.activePalette().canvas)
        .borderRadius(themeStyle(this.store.themeId).cardRadius)
        .border({ width: 1, radius: themeStyle(this.store.themeId).cardRadius, color: this.activePalette().cardBorder })
    }.width('100%').padding(16).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
  }
  @Builder
  themeOption(style: ThemeStyle) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 0 }) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Column()
            .width('100%').height('100%')
            .radialGradient({
              center: ['18%', '15%'],
              radius: '90%',
              colors: [[this.paletteFor(style).auraTop, 0], ['#00000000', 1]]
            })
          Column()
            .width('100%').height('100%')
            .radialGradient({
              center: ['86%', '88%'],
              radius: '85%',
              colors: [[this.paletteFor(style).auraBottom, 0], ['#00000000', 1]]
            })
          if (style.id === 'sakura') {
            Image($rawfile(this.store.darkMode ? 'sakura_dark.jpg' : 'sakura_light.jpg'))
              .width('100%').height('100%')
              .objectFit(ImageFit.Cover)
              .opacity(this.store.darkMode ? 0.78 : 0.85)
          } else if (style.id === 'graphite') {
            Image($rawfile(this.store.darkMode ? 'ink_dark.jpg' : 'ink_light.jpg'))
              .width('100%').height('100%')
              .objectFit(ImageFit.Cover)
              .opacity(this.store.darkMode ? 0.80 : 0.88)
          } else if (style.id === 'sunset') {
            Image($rawfile(this.store.darkMode ? 'sunset_dark.jpg' : 'sunset_light.jpg'))
              .width('100%').height('100%')
              .objectFit(ImageFit.Cover)
              .opacity(this.store.darkMode ? 0.82 : 0.90)
          } else {
            Image($rawfile(`${style.id}_${this.store.darkMode ? 'dark' : 'light'}.jpg`))
              .width('100%').height('100%')
              .objectFit(ImageFit.Cover)
              .opacity(this.store.darkMode ? 0.82 : 0.90)
          }
          Column({ space: 5 }) {
            Row() {
              Blank().width(44).height(13)
                .backgroundColor(style.bubble === 'gradient' ? Color.Transparent : this.paletteFor(style).bubbleStart)
                .linearGradient(style.bubble === 'gradient' ? {
                  angle: 135,
                  colors: [[this.paletteFor(style).bubbleStart, 0], [this.paletteFor(style).bubbleEnd, 1]]
                } : undefined)
                .borderRadius(Math.min(7, Math.round(style.bubbleRadius * 0.45)))
                .border({
                  width: style.bubble === 'outline' ? 1 : 0.5,
                  radius: Math.min(7, Math.round(style.bubbleRadius * 0.45)),
                  color: this.paletteFor(style).bubbleBorder
                })
            }.width('100%').justifyContent(FlexAlign.End)
            Row({ space: 5 }) {
              Blank().width(14).height(14).borderRadius(7).backgroundColor(this.paletteFor(style).accent)
              Column({ space: 3 }) {
                Blank().width('72%').height(4).borderRadius(2).backgroundColor(this.paletteFor(style).codeBorder)
                Blank().width('48%').height(4).borderRadius(2).backgroundColor(this.paletteFor(style).codeHeaderBg)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').padding({ left: 6, right: 6, top: 4, bottom: 4 })
              .backgroundColor(this.paletteFor(style).codeBg)
              .borderRadius(Math.min(8, style.codeRadius))
              .border({ width: 0.6, radius: Math.min(8, style.codeRadius), color: this.paletteFor(style).codeBorder })
          }.width('100%').height('100%').padding(8).justifyContent(FlexAlign.SpaceBetween)
          if (this.store.themeId === style.id) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(17)
              .fontColor([this.paletteFor(style).accent])
              .margin({ top: 6, right: 6 })
          }
        }.width('100%').height(62).clip(true)
          .backgroundColor(this.paletteFor(style).canvas)
          .border({ width: { bottom: 0.5 }, color: this.paletteFor(style).cardBorder })
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(style.label).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            Text(style.styleTag).fontSize(10).fontWeight(FontWeight.Medium)
              .fontColor(this.paletteFor(style).accent)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(this.paletteFor(style).accentTint)
              .borderRadius(6)
          }.width('100%').alignItems(VerticalAlign.Center)
          Text(style.subtitle).fontSize(11).fontColor($r('app.color.pigo_muted'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 9 }).alignItems(HorizontalAlign.Start)
      }.width('100%')
    }.id(`theme-${style.id}`).width('100%').padding(0).clip(true).borderRadius(16)
      .accessibilitySelected(this.store.themeId === style.id)
      .backgroundColor(this.store.themeId === style.id ? this.paletteFor(style).accentTint : this.paletteFor(style).cardBg)
      .border({
        width: this.store.themeId === style.id ? 1.8 : 1,
        radius: 14,
        color: this.store.themeId === style.id ? this.paletteFor(style).accent : this.paletteFor(style).cardBorder
      })
      .onClick(() => { this.store.selectTheme(style.id); })
  }
  @Builder
  themeSettings() {
    Column({ space: 10 }) {
      Text('显示模式').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
      Row({ space: 4 }) {
        ForEach(APPEARANCE_MODES, (mode: AppearanceMode) => {
          Button(mode.label, { type: ButtonType.Normal }).chatAction().layoutWeight(1).height(38).padding(4).borderRadius(10)
            .id(`appearance-${mode.id}`).accessibilitySelected(this.store.modeId === mode.id)
            .backgroundColor(this.store.modeId === mode.id ? this.store.accent() : Color.Transparent)
            .fontColor(this.store.modeId === mode.id ? this.store.accentForeground() : $r('app.color.pigo_muted'))
            .onClick(() => { this.store.selectAppearanceMode(mode); })
        }, (mode: AppearanceMode) => mode.id)
      }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
    }.width('100%').padding(16).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('动态主题效果').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        Text('开启微风动效与轻点互动，关闭后切换为省电静态壁纸').fontSize(13).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.store.themeMotionEnabled })
        .id('theme-motion-setting').selectedColor(this.store.accent()).accessibilityText('动态主题效果')
        .onChange((enabled: boolean) => { void this.store.setThemeMotionEnabled(enabled); })
    }.width('100%').padding(14).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
    this.themePreviewCard()
    Column({ space: 10 }) {
      Row() {
        Text('精选风格主题').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).layoutWeight(1)
        Text(`${THEME_STYLES.length} 款`).fontSize(13).fontColor($r('app.color.pigo_muted'))
      }.width('100%')
      ForEach(THEME_STYLES, (style: ThemeStyle) => {
        this.themeOption(style)
      }, (style: ThemeStyle) => style.id)
    }.width('100%').padding(16).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
    if (this.store.appearanceNotice) Text(this.store.appearanceNotice).fontSize(13).fontColor($r('app.color.pigo_warning'))
  }
  @Builder
  runNoticeSettings() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('运行结束通知').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        Text('应用内显示横幅，退到后台后显示手机通知').fontSize(13).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.store.runCenter.state.runNoticesEnabled })
        .id('run-notice-setting').selectedColor(this.store.accent()).accessibilityText('运行结束通知')
        .onChange((enabled: boolean) => { void this.store.runCenter.setRunNoticesEnabled(enabled); })
    }.width('100%').padding(14).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
  }
  @Builder
  liveViewSettings() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('任务实况窗').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        Text(this.liveViewSummary()).fontSize(13).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.store.liveViewsEnabled })
        .id('live-view-setting').selectedColor(this.store.accent()).accessibilityText('任务实况窗')
        .onChange((enabled: boolean) => { void this.store.setLiveViewsEnabled(enabled); })
    }.width('100%').padding(14).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
  }
  private paletteFor(style: ThemeStyle): ThemePalette {
    return this.store.darkMode ? style.dark : style.light;
  }
  private activePalette(): ThemePalette {
    return themePalette(this.store.themeId, this.store.darkMode);
  }
  private cloudOnlyComputers(): CloudComputer[] {
    return this.store.accountSync.state.cloudComputers.filter((row: CloudComputer): boolean =>
      !this.store.computers.some((local: Companion): boolean => local.address === row.address));
  }
  private pairingComputerTitle(): string {
    const group = computerGroups(this.store.computers).find((item: ComputerGroup): boolean => item.id === this.store.pairingComputerId);
    return group ? computerGroupTitle(group) : '';
  }
  private computerTitle(): string {
    const record = this.store.computers.find((item: Companion): boolean => item.address === this.store.base);
    return record?.computerName || (validUsb(this.store.base) ? 'USB 电脑' : (this.store.base.split('://')[1] || '我的电脑'));
  }
  private liveViewSummary(): string {
    if (this.store.liveViewStatus === 'rights') return '当前设备或应用版本暂无实况窗权益';
    if (this.store.liveViewStatus === 'disabled') return '系统实况窗开关未开启，请在系统应用设置中开启';
    if (this.store.liveViewStatus === 'error') return '实况窗暂时不可用，将在运行期间自动重试';
    return '在状态栏、锁屏和通知中心显示从手机发起的任务状态';
  }
}
