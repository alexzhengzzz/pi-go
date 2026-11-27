import { PiGoPageStore } from '../model/PiGoPageStore';
import { workspaceName } from '../model/SessionStore';
import { immersiveSurface, themedCardSurface } from '../Immersive';
import { RunMessage, scheduleTime, scheduleRunStatus, scheduleRunReason, isCurrentScheduleComputer } from '../ScheduledRuns';
import { InboxRun } from '../RunResults';
import { headerSymbol } from './HeaderSymbol';
import { runStatusMark } from './RunStatusMark';
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

  private historyRuns(): RunMessage[] {
    return this.store.scheduleController.state.scheduleMessages.filter((message: RunMessage): boolean =>
      isCurrentScheduleComputer(this.store.computers, this.store.base, message));
  }

  private selectableRunKeys(): string[] {
    return this.historyRuns().map((message: RunMessage): string => message.key);
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
      }.headerAction().attributeModifier(immersiveSurface(this.store.darkMode)).accessibilityText('返回')
        .enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning))
        .onClick(() => { this.store.scheduleController.backFromSchedule(); })
      Text(this.store.scheduleController.state.schedulePage === 'alert' ? '提醒详情' :
        this.store.scheduleController.state.schedulePage === 'detail' ? '运行详情' :
        this.store.scheduleController.state.schedulePage === 'editor' ?
          (this.store.scheduleController.state.scheduleEditing ? '编辑定时任务' : '新建定时任务') : '运行历史')
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
          if (this.store.scheduleController.state.schedulePage === 'alert' && this.store.scheduleController.state.scheduleAlert) {
            Scroll() {
              Column({ space: 14 }) {
                this.alertDetailView(this.store.scheduleController.state.scheduleAlert)
              }.width('100%').alignItems(HorizontalAlign.Start)
                .padding({ left: 16, right: 16, top: this.store.statusBarHeight + this.store.headerHeight() + 14, bottom: 24 })
            }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
              .transition(subPageTransition())
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
        if (this.store.scheduleController.state.schedulePage === 'alert' && this.store.scheduleController.state.scheduleAlert) {
          Column({ space: 8 }) {
            if (this.store.scheduleController.state.scheduleAlert.run.cwd) {
              Button('拉起 Agent 处理').chatAction().width('100%').height(46)
                .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground())
                .enabled(!this.store.session.busy && !this.store.session.openingSession)
                .onClick(() => {
                  const target = this.store.scheduleController.state.scheduleAlert;
                  if (!target) return;
                  this.store.scheduleController.backFromSchedule();
                  void this.store.runCenter.openInboxRun(target);
                })
            }
            Button('删除这条提醒').chatAction().width('100%').height(46).fontColor($r('app.color.pigo_error'))
              .enabled(!this.store.runCenter.state.inboxCleaning).onClick(() => {
                const target = this.store.scheduleController.state.scheduleAlert;
                if (!target) return;
                void this.store.runCenter.dismissInboxRuns([target.run.id]).then((removed: boolean) => {
                  if (removed) this.store.scheduleController.backFromSchedule();
                });
              })
          }.width('100%').padding({ left: 16, right: 16, bottom: this.store.bottomPad() + 8 })
        } else if (this.selectingRuns && this.store.scheduleController.state.schedulePage === 'history') {
          this.runSelectionActions()
        } else if (this.store.scheduleController.state.schedulePage === 'detail' && this.store.scheduleController.state.scheduleDetail?.run.sessionId) {
          Column({ space: 8 }) {
            if (this.store.isPaired && !isCurrentScheduleComputer(this.store.computers, this.store.base, this.store.scheduleController.state.scheduleDetail)) {
              Text(`当前会话在 ${this.store.computerTitle()}`).fontSize(13).fontColor($r('app.color.pigo_muted'))
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
  alertDetailView(row: InboxRun) {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        runStatusMark(row.run.severity === 'error' ? 'failed' : 'alert', this.store.accent(), this.store.accentTint(), 36)
        Column({ space: 4 }) {
          Text(row.run.title || '工作区提醒').fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.pigo_text')).copyOption(CopyOptions.LocalDevice)
          Text(`${row.computer}${row.run.source ? ' · ' + row.run.source : ''} · ${scheduleTime(row.run.finishedAt)}`)
            .fontSize(12).fontColor($r('app.color.pigo_muted'))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
      Divider().color($r('app.color.pigo_line'))
      Text(row.run.body || row.run.title || '无正文内容')
        .fontSize(15).lineHeight(23).fontColor($r('app.color.pigo_text'))
        .width('100%').copyOption(CopyOptions.LocalDevice)
    }.width('100%').padding(16).borderRadius(16)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
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
      Text('让 Agent 执行什么').fontSize(13).fontColor($r('app.color.pigo_muted'))
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
