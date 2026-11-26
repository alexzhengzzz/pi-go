import { PiGoPageStore } from '../model/PiGoPageStore';
import { workspaceName } from '../model/SessionStore';
import { immersiveSurface, themedCardSurface } from '../Immersive';
import { Companion } from '../CredentialVault';
import { ScheduleJob, RunMessage, scheduleTime, scheduleRunStatus, scheduleRunReason, isCurrentScheduleComputer } from '../ScheduledRuns';
import { InboxRun, runStatus } from '../RunResults';
import { WorkspaceRow } from '../model/PiGoTypes';
import { headerSymbol } from './HeaderSymbol';
import { runStatusInk, runStatusMark } from './RunStatusMark';
import { canvasFadeStops } from '../Appearance';
import { pagePushTransition, subPageTransition } from './PageTransitions';

@Extend(Button)
function chatAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@Extend(Button)
function headerAction() {
  .width(44).height(44).padding(0).borderRadius(22).backgroundColor(Color.Transparent)
}

@ComponentV2
export struct ScheduleOverlay {
  @Param @Require store: PiGoPageStore;
  @Local private selectingRuns: boolean = false;
  @Local private selectedRunKeys: string[] = [];

  private recentRuns(): InboxRun[] {
    return this.store.runCenter.displayedInboxRuns().filter((row: InboxRun): boolean => row.run.status !== 'waiting');
  }

  private historyRuns(): RunMessage[] {
    return this.store.scheduleController.state.scheduleMessages.filter((message: RunMessage): boolean =>
      isCurrentScheduleComputer(this.store.computers, this.store.base, message));
  }

  private selectableRunKeys(): string[] {
    return this.store.scheduleController.state.schedulePage === 'inbox' ? this.recentRuns().map((row: InboxRun): string => row.run.id) :
      this.historyRuns().map((message: RunMessage): string => message.key);
  }

  private selectedKeys(): string[] {
    return this.selectableRunKeys().filter((key: string): boolean => this.selectedRunKeys.includes(key));
  }

  private allRunsSelected(): boolean {
    const keys = this.selectableRunKeys();
    return keys.length > 0 && keys.every((key: string): boolean => this.selectedRunKeys.includes(key));
  }

  @Monitor('schedulePage')
  private resetRunSelection(): void {
    this.selectingRuns = false;
    this.selectedRunKeys = [];
  }

  @Monitor('base')
  private onHistoryComputerChanged(): void {
    if (this.store.scheduleController.state.schedulePage === 'history') this.resetRunSelection();
  }

  private toggleRunSelection(key: string): void {
    const current = this.selectedKeys();
    this.selectedRunKeys = current.includes(key) ?
      current.filter((id: string): boolean => id !== key) : current.concat([key]);
  }

  private async deleteSelectedRuns(): Promise<void> {
    const keys = this.selectedKeys();
    if (!keys.length || (this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning)) return;
    if (this.store.scheduleController.state.schedulePage === 'inbox') {
      if (await this.store.runCenter.dismissInboxRuns(keys)) this.resetRunSelection();
      return;
    }
    const messages = this.historyRuns().filter((message: RunMessage): boolean => keys.includes(message.key));
    const computer = this.store.base;
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: '删除运行记录',
        message: `从当前电脑删除选中的 ${messages.length} 条运行记录？`,
        buttons: [{ text: '取消', color: $r('app.color.pigo_text') }, { text: '删除', color: $r('app.color.pigo_error') }]
      });
      if (result.index === 1 && this.store.scheduleController.state.schedulePage === 'history' && this.store.base === computer &&
        await this.store.scheduleController.deleteScheduleRuns(messages)) this.resetRunSelection();
    } catch { /* Closing the dialog cancels deletion. */ }
  }

  @Builder
  overlayHeader() {
    Row({ space: 12 }) {
      Button({ type: ButtonType.Normal }) {
        headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
      }.headerAction().attributeModifier(immersiveSurface(this.store.darkMode)).accessibilityText('返回').enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning))
        .onClick(() => { this.store.scheduleController.backFromSchedule(); })
      Text(this.store.scheduleController.state.schedulePage === 'inbox' ? '收件箱' : this.store.scheduleController.state.schedulePage === 'detail' ? '运行详情' :
        this.store.scheduleController.state.schedulePage === 'editor' ? (this.store.scheduleController.state.scheduleEditing ? '编辑定时任务' : '新建定时任务') : '运行历史')
        .layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
    }.width('100%').padding({ left: 16, right: 16, top: this.store.statusBarHeight + 8, bottom: 12 })
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: canvasFadeStops(this.store.themeCanvas())
      })
  }

  build() {
    Navigation() {
      Column({ space: 10 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          if (this.store.scheduleController.state.schedulePage === 'inbox') {
            Column() {
              this.scheduleInboxList()
            }.width('100%').height('100%').transition(subPageTransition())
          } else if (this.store.scheduleController.state.schedulePage === 'history') {
            Column() {
              this.scheduleHistoryList()
            }.width('100%').height('100%').transition(subPageTransition())
          } else if (this.store.scheduleController.state.schedulePage === 'detail') {
            Scroll() {
              Column({ space: 12 }) {
                if (this.store.scheduleController.state.scheduleError) Text(this.store.scheduleController.state.scheduleError).fontSize(14).fontColor($r('app.color.pigo_error'))
                if (this.store.scheduleController.state.scheduleDetail) {
                  this.scheduledRunDetail(this.store.scheduleController.state.scheduleDetail)
                }
              }.width('100%').alignItems(HorizontalAlign.Start)
                .padding({ left: 16, right: 16, top: this.store.statusBarHeight + this.store.headerHeight() + 14, bottom: 16 })
            }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
              .transition(subPageTransition())
          } else if (this.store.scheduleController.state.schedulePage === 'editor') {
            Scroll() {
              Column({ space: 12 }) {
                if (this.store.scheduleController.state.scheduleError) Text(this.store.scheduleController.state.scheduleError).fontSize(14).fontColor($r('app.color.pigo_error'))
                this.scheduleEditor()
              }.width('100%').alignItems(HorizontalAlign.Start)
                .padding({ left: 16, right: 16, top: this.store.statusBarHeight + this.store.headerHeight() + 14, bottom: 16 })
            }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
              .transition(subPageTransition())
          }
        }.layoutWeight(1).width('100%')
        if (this.selectingRuns && (this.store.scheduleController.state.schedulePage === 'inbox' || this.store.scheduleController.state.schedulePage === 'history')) {
          this.runSelectionActions()
        } else if (this.store.scheduleController.state.schedulePage === 'detail' && this.store.scheduleController.state.scheduleDetail?.run.sessionId) {
          Column({ space: 8 }) {
            if (this.store.isPaired && !isCurrentScheduleComputer(this.store.computers, this.store.base, this.store.scheduleController.state.scheduleDetail)) {
              Text(`当前聊天在 ${this.store.computerTitle()}`).fontSize(13).fontColor($r('app.color.pigo_muted'))
            }
            Button(`在 ${this.store.scheduleController.state.scheduleDetail.computer} 打开会话`).chatAction().width('100%').height(46)
              .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground())
              .enabled(!this.store.session.busy && !this.store.session.openingSession).onClick(() => {
                if (this.store.scheduleController.state.scheduleDetail) void this.store.openScheduledSession(this.store.scheduleController.state.scheduleDetail);
              })
          }.width('100%').padding({ left: 16, right: 16, bottom: this.store.bottomPad() + 8 })
        }
      }.width('100%').height('100%')
    }.id('schedule-overlay').width('100%').height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .title({ builder: this.overlayHeader, height: this.store.headerHeight() + this.store.statusBarHeight + 20 }, {
        backgroundColor: Color.Transparent,
        barStyle: BarStyle.STACK
      })
      .backgroundColor(this.store.themeCanvas()).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
      .transition(pagePushTransition())
  }
  @Builder
  scheduleInboxList() {
    List({ space: 8 }) {
      ListItem() {
        Row({ space: 12 }) {
          Stack() {
            headerSymbol($r('sys.symbol.bell'), this.store.accent(), 17)
          }.width(36).height(36).borderRadius(11).backgroundColor(this.store.accentTint())
          Column({ space: 3 }) {
            Text('后台通知').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            if (this.store.runCenter.state.pushStatus) {
              Text(this.store.runCenter.state.pushStatus).fontSize(12).fontColor($r('app.color.pigo_muted'))
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          if (this.store.runCenter.state.pushSaving) LoadingProgress().width(16).height(16).color(this.store.accent())
          Toggle({ type: ToggleType.Switch, isOn: this.store.runCenter.state.pushEnabled }).id('inbox-push-toggle')
            .accessibilityText('后台通知').enabled(!this.store.runCenter.state.pushSaving)
            .selectedColor(this.store.accent()).onChange((enabled: boolean) => { void this.store.runCenter.setPushEnabled(enabled); })
        }.width('100%').padding(12).borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
          .border({ width: 1, color: $r('app.color.pigo_line') })
      }
      if (this.store.scheduleController.state.scheduleError || this.store.scheduleController.state.scheduleOffline.length) {
        ListItem() {
          Row({ space: 8 }) {
            headerSymbol($r('sys.symbol.exclamationmark_circle'), $r('app.color.pigo_warning'), 15)
            Text(this.store.scheduleController.state.scheduleError || '部分电脑离线，重新连接后会补收结果。').layoutWeight(1)
              .fontSize(12).fontColor($r('app.color.pigo_muted'))
          }.padding({ left: 4, top: 4, bottom: 4 })
        }
      }
      if (this.store.runCenter.displayedInboxRuns().some((row: InboxRun): boolean => row.run.status === 'waiting')) {
        ListItem() { this.inboxSection('待处理') }
        ForEach(this.store.runCenter.displayedInboxRuns().filter((row: InboxRun): boolean => row.run.status === 'waiting'), (row: InboxRun) => {
          ListItem() { this.inboxRunRow(row) }
        }, (row: InboxRun) => `${row.run.id}:${row.address}`)
      }
      if (this.recentRuns().length) {
        ListItem() { this.selectableRunSection('最近会话') }
        ForEach(this.recentRuns(), (row: InboxRun) => {
          ListItem() { this.inboxRunRow(row) }
        }, (row: InboxRun) => `${row.run.id}:${row.address}:${row.unread}`)
      }
      if (this.store.scheduleController.state.scheduleMessages.some((message: RunMessage): boolean => !message.dismissed)) {
        ListItem() { this.inboxSection('定时任务') }
        ForEach(this.store.scheduleController.state.scheduleMessages.filter((message: RunMessage): boolean => !message.dismissed), (message: RunMessage) => {
          ListItem() {
            this.scheduledMessageRow(message)
          }.swipeAction({ end: this.scheduleInboxDelete.bind(this, message), edgeEffect: SwipeEdgeEffect.None })
        }, (message: RunMessage) => `${message.key}:${message.unread}`)
      }
      if (!this.store.runCenter.displayedInboxRuns().length && !this.store.scheduleController.state.scheduleMessages.some((message: RunMessage): boolean => !message.dismissed)) {
        ListItem() {
          Column({ space: 9 }) {
            Stack() {
              headerSymbol($r('sys.symbol.inbox'), this.store.accent(), 24)
            }.width(48).height(48).borderRadius(15).backgroundColor(this.store.accentTint())
            Text('暂无任务消息').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          }.width('100%').padding({ top: 44, bottom: 36 })
        }
      }
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(this.store.statusBarHeight + this.store.headerHeight() + 14)
      .contentEndOffset(this.store.bottomPad() + 16)
      .padding({ left: 16, right: 16 })
  }

  @Builder
  inboxSection(title: string) {
    Text(title).fontSize(13).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_muted'))
      .padding({ left: 4, top: 10, bottom: 1 }).accessibilityGroup(true)
  }

  @Builder
  selectableRunSection(title: string) {
    Row({ space: 6 }) {
      Text(title).fontSize(13).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_muted'))
        .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (!this.selectingRuns && this.selectableRunKeys().length) {
        Button('选择').chatAction().height(44).padding({ left: 12, right: 12 })
          .enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning)).onClick(() => { this.selectingRuns = true; })
      }
    }.width('100%').padding({ left: 4, top: 4 })
  }

  @Builder
  runSelectionActions() {
    Row({ space: 8 }) {
      Button('取消').chatAction().height(44).enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning))
        .onClick(() => { this.resetRunSelection(); })
      Button(this.allRunsSelected() ? '取消全选' : '全选').chatAction().height(44)
        .enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) && this.selectableRunKeys().length > 0)
        .onClick(() => { this.selectedRunKeys = this.allRunsSelected() ? [] : this.selectableRunKeys(); })
      Blank()
      Button((this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) ? '删除中…' : `删除（${this.selectedKeys().length}）`).chatAction()
        .height(44).fontColor($r('app.color.pigo_error'))
        .enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) && this.selectedKeys().length > 0)
        .onClick(() => { void this.deleteSelectedRuns(); })
    }.width('100%').padding({ left: 16, right: 16, bottom: this.store.bottomPad() + 8 })
  }

  @Builder
  runSelectionMark(key: string) {
    SymbolGlyph(this.selectedRunKeys.includes(key) ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
      .fontSize(21).fontColor([this.selectedRunKeys.includes(key) ? this.store.accent() : $r('app.color.pigo_muted')])
      .accessibilityLevel('no')
  }

  @Builder
  inboxRunRow(row: InboxRun) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 11 }) {
        if (this.selectingRuns && row.run.status !== 'waiting') {
          this.runSelectionMark(row.run.id)
        }
        runStatusMark(row.run.status, this.store.accent(), this.store.accentTint(), 36)
        Column({ space: 5 }) {
          Row({ space: 6 }) {
            Text(row.run.title || 'Pi 会话').fontSize(15).fontWeight(row.unread ? FontWeight.Bold : FontWeight.Medium)
              .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            if (row.unread) Blank().width(6).height(6).borderRadius(3).backgroundColor(this.store.accent())
          }.width('100%')
          Text(`${row.computer} · ${scheduleTime(row.run.finishedAt)}`)
            .fontSize(11).fontColor($r('app.color.pigo_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(runStatus(row.run.status)).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor(runStatusInk(row.run.status, this.store.accent()))
          .backgroundColor(row.run.status === 'waiting' ? $r('app.color.pigo_warning_panel') : $r('app.color.pigo_control'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(9)
      }.width('100%').padding(12)
    }.id(`inbox-run-${row.run.id}`).width('100%').padding(0).borderRadius(16)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
      .accessibilitySelected(this.selectingRuns && row.run.status !== 'waiting' && this.selectedRunKeys.includes(row.run.id))
      .enabled(this.selectingRuns && row.run.status !== 'waiting' ? !(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) : !this.store.session.busy && !this.store.session.openingSession)
      .onClick(() => {
        if (this.selectingRuns && row.run.status !== 'waiting') this.toggleRunSelection(row.run.id);
        else void this.store.runCenter.openInboxRun(row);
      })
  }

  @Builder
  scheduleInboxDelete(message: RunMessage) {
    Button('删除').id(`schedule-dismiss-${message.run.id}`).width(72).height('100%').padding(0)
      .fontColor(Color.White).backgroundColor($r('app.color.pigo_error')).borderRadius(14)
      .accessibilityText(`删除收件箱消息 ${message.run.name}`)
      .onClick(() => { this.store.scheduleController.dismissScheduleMessage(message); })
  }
  @Builder
  scheduleHistoryList() {
    List({ space: 12 }) {
      if (this.store.scheduleController.state.scheduleError) {
        ListItem() {
          Text(this.store.scheduleController.state.scheduleError).fontSize(14).fontColor($r('app.color.pigo_error'))
        }
      }
      ListItem() {
        this.selectableRunSection(this.store.computerTitle())
      }
      if (!this.historyRuns().length) {
        ListItem() {
          Text('暂无运行记录').fontSize(14).fontColor($r('app.color.pigo_muted'))
        }
      }
      ForEach(this.historyRuns(),
        (message: RunMessage) => {
          ListItem() {
            this.scheduledMessageRow(message)
          }.swipeAction({ end: this.selectingRuns ? undefined : this.scheduleHistoryDelete.bind(this, message),
            edgeEffect: SwipeEdgeEffect.None })
        }, (message: RunMessage) => `${message.key}:${message.unread}`)
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(this.store.statusBarHeight + this.store.headerHeight() + 14)
      .contentEndOffset(this.store.bottomPad() + 16)
      .padding({ left: 16, right: 16 })
  }
  @Builder
  scheduleHistoryDelete(message: RunMessage) {
    Button('删除').id(`schedule-delete-run-${message.run.id}`).width(72).height('100%').padding(0)
      .fontColor(Color.White).backgroundColor($r('app.color.pigo_error')).borderRadius(14)
      .accessibilityText(`删除运行记录 ${message.run.name}`)
      .enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning))
      .onClick(() => { void this.store.scheduleController.deleteScheduleRuns([message]); })
  }
  @Builder
  scheduleEditor() {
    Column({ space: 12 }) {
      Text('工作区').fontSize(13).fontColor($r('app.color.pigo_muted'))
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.folder')).fontSize(17).fontColor([this.store.accent()])
          Text(this.store.scheduleController.state.scheduleCwd ? workspaceName(this.store.workspaces, this.store.scheduleController.state.scheduleCwd) : '选择已共享工作区')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('app.color.pigo_muted')])
        }.width('100%').padding({ left: 14, right: 14 })
      }.width('100%').height(44).padding(0).borderRadius(12)
        .backgroundColor($r('app.color.pigo_control'))
        .enabled(!this.store.scheduleController.state.scheduleEditing && this.store.projects.length > 0)
        .bindMenu(this.store.projects.map((cwd: string): MenuElement => ({
          value: workspaceName(this.store.workspaces, cwd), action: () => { this.store.scheduleController.state.scheduleCwd = cwd; }
        })))
      Text('名称').fontSize(13).fontColor($r('app.color.pigo_muted'))
      TextInput({ text: this.store.scheduleController.state.scheduleName, placeholder: '例如 每日汇总' }).id('schedule-name').maxLength(80)
        .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
        .placeholderColor($r('app.color.pigo_muted'))
        .onChange((value: string) => { this.store.scheduleController.state.scheduleName = value; })
      Text('让 Pi 执行什么').fontSize(13).fontColor($r('app.color.pigo_muted'))
      TextArea({ text: this.store.scheduleController.state.schedulePrompt, placeholder: '汇总今天的工作区变更' }).id('schedule-prompt').maxLength(1600).height(112)
        .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
        .placeholderColor($r('app.color.pigo_muted'))
        .onChange((value: string) => { this.store.scheduleController.state.schedulePrompt = value; })
      Row({ space: 4 }) {
        ForEach(['once', 'daily', 'interval'], (kind: string) => {
          Button(kind === 'once' ? '指定时间' : kind === 'daily' ? '每天' : '固定间隔', { type: ButtonType.Normal }).chatAction()
            .id(`schedule-kind-${kind}`).layoutWeight(1).height(38).borderRadius(10)
            .accessibilitySelected(this.store.scheduleController.state.scheduleKind === kind)
            .backgroundColor(this.store.scheduleController.state.scheduleKind === kind ? this.store.accent() : Color.Transparent)
            .fontColor(this.store.scheduleController.state.scheduleKind === kind ? this.store.accentForeground() : $r('app.color.pigo_muted'))
            .onClick(() => {
              if (this.store.scheduleController.state.scheduleKind === kind) return;
              this.store.scheduleController.state.scheduleKind = kind;
              this.store.scheduleController.state.scheduleWhen = kind === 'once' ? scheduleTime(Date.now() + 120_000) : kind === 'daily' ? '18:00' : '60';
            })
        }, (kind: string) => kind)
      }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
      Text(this.store.scheduleController.state.scheduleKind === 'once' ? '执行时间（手机时区）' : this.store.scheduleController.state.scheduleKind === 'daily' ?
        `每天执行时间（${this.store.scheduleController.state.scheduleZone || '电脑时区'}）` : '每隔多少分钟执行')
        .fontSize(13).fontColor($r('app.color.pigo_muted'))
      Row({ space: 8 }) {
        TextInput({ text: this.store.scheduleController.state.scheduleWhen, placeholder: this.store.scheduleController.state.scheduleKind === 'once' ? 'YYYY-MM-DD HH:mm' :
          this.store.scheduleController.state.scheduleKind === 'daily' ? 'HH:mm' : '分钟' }).maxLength(16).layoutWeight(1)
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.store.scheduleController.state.scheduleWhen = value; })
        if (this.store.scheduleController.state.scheduleKind !== 'interval') {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph(this.store.scheduleController.state.scheduleKind === 'once' ? $r('sys.symbol.calendar') : $r('sys.symbol.clock'))
              .fontSize(19).fontColor([this.store.accent()])
          }.width(44).height(40).padding(0).borderRadius(12)
            .backgroundColor(this.store.accentTint())
            .accessibilityText(this.store.scheduleController.state.scheduleKind === 'once' ? '选择日期与时间' : '选择时间')
            .onClick(() => { this.store.openScheduleTimePicker(); })
        }
      }.width('100%')
      Text('错过后可补跑的分钟数，0 表示跳过').fontSize(13).fontColor($r('app.color.pigo_muted'))
      TextInput({ text: this.store.scheduleController.state.scheduleCatchUp, placeholder: '0' }).type(InputType.Number).maxLength(4)
        .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
        .placeholderColor($r('app.color.pigo_muted'))
        .onChange((value: string) => { this.store.scheduleController.state.scheduleCatchUp = value; })
      Button((this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) ? '等待电脑确认…' : '保存到电脑').chatAction().id('schedule-save')
        .width('100%').height(46)
        .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground())
        .enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning)).onClick(() => {
          void this.store.scheduleController.updateSchedule(this.store.scheduleController.state.scheduleEditing ? 'edit' : 'create', this.store.scheduleController.state.scheduleEditing);
        })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  scheduledMessageRow(message: RunMessage) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        if (this.store.scheduleController.state.schedulePage === 'history' && this.selectingRuns) {
          this.runSelectionMark(message.key)
        }
        Stack() {
          SymbolGlyph(this.scheduleStatusSymbol(message.run.status)).fontSize(19)
            .fontColor([this.scheduleStatusColor(message.run.status)])
        }.width(36).height(36).borderRadius(10).backgroundColor(this.scheduleStatusPanel(message.run.status))
        Column({ space: 3 }) {
          Text(message.run.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${message.computer} · ${scheduleRunStatus(message.run.status)}`).fontSize(13)
            .fontColor($r('app.color.pigo_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(scheduleTime(message.run.finishedAt ?? message.run.scheduledAt)).fontSize(12).fontColor($r('app.color.pigo_muted'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (message.unread) Blank().width(7).height(7).borderRadius(4).backgroundColor(this.store.accent())
        if (this.store.scheduleController.state.schedulePage !== 'history' || !this.selectingRuns) {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.pigo_muted')])
        }
      }.width('100%').padding(12)
    }.id(`schedule-message-${message.run.id}`).width('100%').padding(0)
      .attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      .accessibilitySelected(this.store.scheduleController.state.schedulePage === 'history' && this.selectingRuns && this.selectedRunKeys.includes(message.key))
      .enabled(this.store.scheduleController.state.schedulePage !== 'history' || !this.selectingRuns || !(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning))
      .onClick(() => {
        if (this.store.scheduleController.state.schedulePage === 'history' && this.selectingRuns) this.toggleRunSelection(message.key);
        else this.store.scheduleController.showScheduleDetail(message);
      })
  }
  @Builder
  scheduledRunDetail(message: RunMessage) {
    Column({ space: 12 }) {
      Text(message.run.name).fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
      Text(`${message.computer} · ${scheduleRunStatus(message.run.status)}`).fontSize(15)
        .fontColor(this.scheduleStatusColor(message.run.status))
      Column({ space: 8 }) {
        Text(`工作区 · ${message.run.cwd.split('/').pop() || message.run.cwd}`).fontSize(14).fontColor($r('app.color.pigo_text'))
        Text(`计划 · ${scheduleTime(message.run.scheduledAt)}`).fontSize(14).fontColor($r('app.color.pigo_text'))
        if (message.run.startedAt) Text(`开始 · ${scheduleTime(message.run.startedAt)}`).fontSize(14).fontColor($r('app.color.pigo_text'))
        if (message.run.finishedAt) Text(`结束 · ${scheduleTime(message.run.finishedAt)}`).fontSize(14).fontColor($r('app.color.pigo_text'))
      }.width('100%').alignItems(HorizontalAlign.Start).padding(14).borderRadius(16)
        .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
      if (message.run.reason) Text(scheduleRunReason(message.run.reason)).fontSize(14).fontColor($r('app.color.pigo_muted'))
      if ((message.run.coalesced ?? 0) > 0) {
        Text(`此前还有 ${message.run.coalesced} 次到期，已合并处理。`).fontSize(14).fontColor($r('app.color.pigo_muted'))
      }
      if (message.run.summary) {
        Text('运行结果').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        Text(message.run.summary).fontSize(15).copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.pigo_text'))
          .width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
          .border({ width: 1, color: $r('app.color.pigo_line') })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  private scheduleStatusSymbol(status: string): Resource {
    if (status === 'succeeded') return $r('sys.symbol.checkmark_circle');
    if (status === 'failed' || status === 'interrupted') return $r('sys.symbol.exclamationmark_circle');
    return $r('sys.symbol.clock');
  }
  private scheduleStatusColor(status: string): Resource {
    if (status === 'succeeded') return $r('app.color.pigo_success');
    if (status === 'failed' || status === 'interrupted') return $r('app.color.pigo_error');
    return $r('app.color.pigo_warning');
  }
  private scheduleStatusPanel(status: string): Resource {
    if (status === 'succeeded') return $r('app.color.pigo_control');
    if (status === 'failed' || status === 'interrupted') return $r('app.color.pigo_error_panel');
    return $r('app.color.pigo_warning_panel');
  }
}
