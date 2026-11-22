import { unboundAction } from './ComponentAction';
import { workspaceName } from '../model/SessionStore';
import { glassButtonSurface } from '../Immersive';
import { Companion } from '../CredentialVault';
import { ScheduleJob, RunMessage, scheduleTime, scheduleRunStatus, scheduleRunReason, isCurrentScheduleComputer } from '../ScheduledRuns';
import { WorkspaceRow } from '../model/PiGoTypes';
import { headerSymbol } from './HeaderSymbol';

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

@Component
export struct ScheduleOverlay {
  @StorageProp('pigoDark') private darkMode: boolean = false;
  @Require backFromSchedule: () => void = unboundAction;
  @Prop base: string;
  @Prop busy: boolean;
  @Link computers: Companion[];
  @Require dismissScheduleMessage: (message: RunMessage) => void = unboundAction;
  @Prop isPaired: boolean;
  @Require openScheduleTimePicker: () => void = unboundAction;
  @Require openScheduledSession: (message: RunMessage) => Promise<void> = unboundAction;
  @Prop openingSession: boolean;
  @Link projects: string[];
  @Link scheduleCatchUp: string;
  @Link scheduleCwd: string;
  @Prop scheduleDetail?: RunMessage;
  @Prop scheduleEditing?: ScheduleJob;
  @Prop scheduleError: string;
  @Link scheduleKind: string;
  @Link scheduleMessages: RunMessage[];
  @Link scheduleName: string;
  @Link scheduleOffline: string[];
  @Prop schedulePage: string;
  @Link schedulePrompt: string;
  @Prop scheduleSaving: boolean;
  @Link scheduleWhen: string;
  @Prop scheduleZone: string;
  @Require showScheduleDetail: (message: RunMessage) => void = unboundAction;
  @Prop statusBarHeight: number;
  @Require updateSchedule: (operation: string, job?: ScheduleJob) => Promise<void> = unboundAction;
  @Link workspaces: WorkspaceRow[];
  @Prop accent: string;
  @Prop accentForeground: string;
  @Prop accentTint: string;
  @Prop headerHeight: number;
  @Prop bottomPad: number;
  @Prop computerTitle: string;

  build() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().attributeModifier(glassButtonSurface(this.darkMode)).accessibilityText('返回').enabled(!this.scheduleSaving)
          .onClick(() => { this.backFromSchedule(); })
        Text(this.schedulePage === 'inbox' ? '收件箱' : this.schedulePage === 'detail' ? '运行详情' :
          this.schedulePage === 'editor' ? (this.scheduleEditing ? '编辑定时任务' : '新建定时任务') : '运行历史')
          .layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
      }.width('100%').height(this.headerHeight)
        .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
      if (this.schedulePage === 'inbox') {
        this.scheduleInboxList()
      } else {
        Scroll() {
          Column({ space: 12 }) {
            if (this.scheduleError) Text(this.scheduleError).fontSize(14).fontColor($r('app.color.pigo_error'))
            if (this.schedulePage === 'detail' && this.scheduleDetail) {
              this.scheduledRunDetail(this.scheduleDetail)
            } else if (this.schedulePage === 'editor') {
              this.scheduleEditor()
            } else if (this.schedulePage === 'history') {
              Text(this.computerTitle).fontSize(13).fontColor($r('app.color.pigo_muted'))
              if (!this.scheduleMessages.some((item: RunMessage): boolean => isCurrentScheduleComputer(this.computers, this.base, item))) {
                Text('暂无运行记录').fontSize(14).fontColor($r('app.color.pigo_muted'))
              }
              ForEach(this.scheduleMessages.filter((item: RunMessage): boolean => isCurrentScheduleComputer(this.computers, this.base, item)),
                (message: RunMessage) => { this.scheduledMessageRow(message) },
                (message: RunMessage) => `${message.key}:${message.unread}`)
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 6, bottom: 12 })
        }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
      }
      if (this.schedulePage === 'detail' && this.scheduleDetail?.run.sessionId) {
        if (this.isPaired && !isCurrentScheduleComputer(this.computers, this.base, this.scheduleDetail)) {
          Text(`当前聊天在 ${this.computerTitle}`).fontSize(13).fontColor($r('app.color.pigo_muted'))
        }
        Button(`在 ${this.scheduleDetail.computer} 打开会话`).chatAction().width('100%').height(46)
          .backgroundColor(this.accent).fontColor(this.accentForeground)
          .enabled(!this.busy && !this.openingSession).onClick(() => {
            if (this.scheduleDetail) void this.openScheduledSession(this.scheduleDetail);
          })
      }
    }.id('schedule-overlay').width('100%').height('100%').padding({
      left: 16, right: 16, top: this.statusBarHeight + 8, bottom: this.bottomPad + 8
    }).backgroundColor($r('app.color.launch_background')).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }
  @Builder
  scheduleInboxList() {
    List({ space: 12 }) {
      ListItem() {
        Text('所有电脑').fontSize(13).fontColor($r('app.color.pigo_muted'))
      }
      if (this.scheduleOffline.length) {
        ListItem() {
          Text('部分电脑暂时无法连接，恢复连接后可补收结果。').fontSize(13).fontColor($r('app.color.pigo_muted'))
        }
      } else if (!this.scheduleMessages.some((message: RunMessage): boolean => !message.dismissed)) {
        ListItem() {
          Text('暂无定时任务消息').fontSize(14).fontColor($r('app.color.pigo_muted'))
        }
      }
      ForEach(this.scheduleMessages.filter((message: RunMessage): boolean => !message.dismissed), (message: RunMessage) => {
        ListItem() {
          this.scheduledMessageRow(message)
        }.swipeAction({ end: this.scheduleInboxDelete.bind(this, message), edgeEffect: SwipeEdgeEffect.None })
      }, (message: RunMessage) => `${message.key}:${message.unread}`)
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).padding({ top: 6, bottom: 12 })
  }
  @Builder
  scheduleInboxDelete(message: RunMessage) {
    Button('删除').id(`schedule-dismiss-${message.run.id}`).width(72).height('100%').padding(0)
      .fontColor(Color.White).backgroundColor($r('app.color.pigo_error')).borderRadius(14)
      .accessibilityText(`删除收件箱消息 ${message.run.name}`)
      .onClick(() => { this.dismissScheduleMessage(message); })
  }
  @Builder
  scheduleEditor() {
    Column({ space: 12 }) {
      Text('工作区').fontSize(13).fontColor($r('app.color.pigo_muted'))
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.folder')).fontSize(17).fontColor([this.accent])
          Text(this.scheduleCwd ? workspaceName(this.workspaces, this.scheduleCwd) : '选择已共享工作区')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('app.color.pigo_muted')])
        }.width('100%').padding({ left: 14, right: 14 })
      }.width('100%').height(44).padding(0).borderRadius(12)
        .backgroundColor($r('app.color.pigo_control'))
        .enabled(!this.scheduleEditing && this.projects.length > 0)
        .bindMenu(this.projects.map((cwd: string): MenuElement => ({
          value: workspaceName(this.workspaces, cwd), action: () => { this.scheduleCwd = cwd; }
        })))
      Text('名称').fontSize(13).fontColor($r('app.color.pigo_muted'))
      TextInput({ text: this.scheduleName, placeholder: '例如 每日汇总' }).id('schedule-name').maxLength(80)
        .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
        .placeholderColor($r('app.color.pigo_muted'))
        .onChange((value: string) => { this.scheduleName = value; })
      Text('让 Pi 执行什么').fontSize(13).fontColor($r('app.color.pigo_muted'))
      TextArea({ text: this.schedulePrompt, placeholder: '汇总今天的工作区变更' }).id('schedule-prompt').maxLength(1600).height(112)
        .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
        .placeholderColor($r('app.color.pigo_muted'))
        .onChange((value: string) => { this.schedulePrompt = value; })
      Row({ space: 4 }) {
        ForEach(['once', 'daily', 'interval'], (kind: string) => {
          Button(kind === 'once' ? '指定时间' : kind === 'daily' ? '每天' : '固定间隔', { type: ButtonType.Normal }).chatAction()
            .id(`schedule-kind-${kind}`).layoutWeight(1).height(38).borderRadius(10)
            .accessibilitySelected(this.scheduleKind === kind)
            .backgroundColor(this.scheduleKind === kind ? this.accent : Color.Transparent)
            .fontColor(this.scheduleKind === kind ? this.accentForeground : $r('app.color.pigo_muted'))
            .onClick(() => {
              if (this.scheduleKind === kind) return;
              this.scheduleKind = kind;
              this.scheduleWhen = kind === 'once' ? scheduleTime(Date.now() + 120_000) : kind === 'daily' ? '18:00' : '60';
            })
        }, (kind: string) => kind)
      }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
      Text(this.scheduleKind === 'once' ? '执行时间（手机时区）' : this.scheduleKind === 'daily' ?
        `每天执行时间（${this.scheduleZone || '电脑时区'}）` : '每隔多少分钟执行')
        .fontSize(13).fontColor($r('app.color.pigo_muted'))
      Row({ space: 8 }) {
        TextInput({ text: this.scheduleWhen, placeholder: this.scheduleKind === 'once' ? 'YYYY-MM-DD HH:mm' :
          this.scheduleKind === 'daily' ? 'HH:mm' : '分钟' }).maxLength(16).layoutWeight(1)
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.scheduleWhen = value; })
        if (this.scheduleKind !== 'interval') {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph(this.scheduleKind === 'once' ? $r('sys.symbol.calendar') : $r('sys.symbol.clock'))
              .fontSize(19).fontColor([this.accent])
          }.width(44).height(40).padding(0).borderRadius(12)
            .backgroundColor(this.accentTint)
            .accessibilityText(this.scheduleKind === 'once' ? '选择日期与时间' : '选择时间')
            .onClick(() => { this.openScheduleTimePicker(); })
        }
      }.width('100%')
      Text('错过后可补跑的分钟数，0 表示跳过').fontSize(13).fontColor($r('app.color.pigo_muted'))
      TextInput({ text: this.scheduleCatchUp, placeholder: '0' }).type(InputType.Number).maxLength(4)
        .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
        .placeholderColor($r('app.color.pigo_muted'))
        .onChange((value: string) => { this.scheduleCatchUp = value; })
      Button(this.scheduleSaving ? '等待电脑确认…' : '保存到电脑').chatAction().id('schedule-save')
        .width('100%').height(46)
        .backgroundColor(this.accent).fontColor(this.accentForeground)
        .enabled(!this.scheduleSaving).onClick(() => {
          void this.updateSchedule(this.scheduleEditing ? 'edit' : 'create', this.scheduleEditing);
        })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  scheduledMessageRow(message: RunMessage) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
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
        if (message.unread) Blank().width(7).height(7).borderRadius(4).backgroundColor(this.accent)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.pigo_muted')])
      }.width('100%').padding(12)
    }.id(`schedule-message-${message.run.id}`).width('100%').padding(0)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, radius: 16, color: $r('app.color.pigo_line') })
      .onClick(() => { this.showScheduleDetail(message); })
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
