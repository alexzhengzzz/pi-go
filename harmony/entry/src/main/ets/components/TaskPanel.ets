import { glassCardSurface } from '../Immersive';
import { unboundAction } from './ComponentAction';
import { workspaceName } from '../model/SessionStore';
import { RunMessage, ScheduleJob, scheduleTime } from '../ScheduledRuns';
import { RunningRow, WorkspaceRow } from '../model/PiGoTypes';

@Extend(Button)
function chatAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@ComponentV2
export struct TaskPanel {
  @Param @Require darkMode: boolean;
  @Param @Require topClearance: number;
  @Param @Require bottomClearance: number;
  @Param @Require runningRows: RunningRow[];
  @Param @Require scheduleRuns: RunMessage[];
  @Param @Require currentId: string;
  @Param @Require busy: boolean;
  @Param @Require openingSession: boolean;
  @Param @Require accentTint: string;
  @Event openRunningTask: (id: string) => void = unboundAction;
  @Event editSchedule: (job?: ScheduleJob) => void = unboundAction;
  @Event loadScheduleJobs: () => Promise<void> = unboundAction;
  @Param @Require projects: string[];
  @Param @Require reachable: boolean;
  @Param @Require scheduleError: string;
  @Event $scheduleError: (value: string) => void = unboundAction;
  @Event scheduleJobMenu: (job: ScheduleJob) => MenuElement[] = unboundAction;
  @Param @Require scheduleJobs: ScheduleJob[];
  @Param @Require scheduleListError: string;
  @Param @Require scheduleLoaded: boolean;
  @Param @Require schedulePage: string;
  @Event $schedulePage: (value: string) => void = unboundAction;
  @Param @Require scheduleSaving: boolean;
  @Param @Require workspaces: WorkspaceRow[];
  @Param @Require accent: string;
  @Param @Require accentForeground: string;

  build() {
    Scroll() {
      Column({ space: 24 }) {
        this.runningTasksSection()
        this.scheduledTasksSection()
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: this.topClearance, bottom: this.bottomClearance })
    }.scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off).width('100%').layoutWeight(1)
      .align(Alignment.TopStart).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  runningTasksSection() {
    Column({ space: 10 }) {
      Text('运行中').fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
      ForEach(this.scheduleRuns,
        (row: RunMessage) => {
          Text(`${row.run.name} · 定时任务运行中`).fontSize(15).fontColor($r('app.color.pigo_text'))
            .width('100%').padding(14).attributeModifier(glassCardSurface(this.darkMode, 16))
        }, (row: RunMessage) => row.key)
      if (this.reachable && this.runningRows.length) {
        ForEach(this.runningRows, (row: RunningRow) => {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 10 }) {
              Column({ space: 4 }) {
                Text(row.name || '后台任务').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (row.cwd) Text(row.cwd.split('/').pop() || row.cwd).fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Row({ space: 5 }) {
                Text('').width(6).height(6).borderRadius(3)
                  .backgroundColor(this.stateColor(row.state ?? ''))
                Text(`${row.id === this.currentId ? '当前 · ' : ''}${this.stateLabel(row.state ?? '')}`)
                  .fontSize(12).fontColor(this.stateColor(row.state ?? ''))
              }
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.pigo_muted')])
            }.width('100%').padding(14)
          }.id(`running-session-${row.id}`).width('100%').constraintSize({ minHeight: 60 }).padding(0)
            .backgroundColor(row.id === this.currentId ? this.accentTint : $r('app.color.pigo_panel'))
            .border({ width: 1, radius: 16, color: row.id === this.currentId ? this.accent : $r('app.color.pigo_line') })
            .accessibilityText(`${row.name || '后台任务'}，${this.stateLabel(row.state ?? '')}，点击切换查看`)
            .enabled(!this.busy && !this.openingSession && (this.reachable || row.id === this.currentId))
            .onClick(() => {
              if (this.openingSession) return;
              this.openRunningTask(row.id);
            })
        }, (row: RunningRow) => row.id)
      } else if (!this.scheduleRuns.length) {
        Row({ space: 12 }) {
          Stack() {
            SymbolGlyph(this.reachable ? $r('sys.symbol.clock') : $r('sys.symbol.computer'))
              .fontSize(20).fontColor([$r('app.color.pigo_muted')])
          }.width(40).height(40).borderRadius(12).backgroundColor($r('app.color.pigo_control'))
          Column({ space: 4 }) {
            Text(this.reachable ? '暂无运行中的任务' : '电脑未连接')
              .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding(14).attributeModifier(glassCardSurface(this.darkMode, 16))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  scheduledTasksSection() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('定时任务').layoutWeight(1).fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.pigo_text'))
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(17).fontColor([$r('app.color.pigo_muted')])
        }.id('schedule-refresh').width(36).height(36).padding(0).borderRadius(10)
          .backgroundColor($r('app.color.pigo_control')).accessibilityText('刷新定时任务')
          .enabled(!this.scheduleSaving)
          .onClick(() => { void this.loadScheduleJobs(); })
      }.width('100%')
      Row({ space: 8 }) {
        Button('新建定时任务').chatAction().id('schedule-create').height(42)
          .backgroundColor(this.accent).fontColor(this.accentForeground)
          .enabled(this.reachable && this.projects.length > 0 &&
            !this.scheduleSaving && !this.scheduleListError).onClick(() => { this.editSchedule(); })
        Button('运行历史').chatAction().id('schedule-history').height(42)
          .onClick(() => { this.$scheduleError(''); this.$schedulePage('history'); })
      }.width('100%')
      if (this.scheduleListError) Text(this.scheduleListError).fontSize(14).fontColor($r('app.color.pigo_error'))
      else if (!this.reachable && this.scheduleJobs.length) {
        Text('显示上次连接时的定时计划').fontSize(13).fontColor($r('app.color.pigo_muted'))
      } else if (this.reachable && this.scheduleLoaded && !this.scheduleJobs.length) {
        Text(this.projects.length ? '还没有定时任务' : '共享工作区后可创建定时任务').fontSize(14).fontColor($r('app.color.pigo_muted'))
      }
      ForEach(this.scheduleJobs, (job: ScheduleJob) => {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text(job.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            Text(`${workspaceName(this.workspaces, job.cwd)} · ${!job.enabled ? '已暂停' :
              job.nextAt === null ? '已结束' : `下次 ${scheduleTime(job.nextAt)}`}`)
              .fontSize(13).fontColor($r('app.color.pigo_muted'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_more')).width(18).height(18).fillColor($r('app.color.pigo_muted'))
          }.id(`schedule-operations-${job.id}`).width(40).height(40).padding(0).borderRadius(10)
            .backgroundColor(Color.Transparent).accessibilityText('定时任务操作')
            .enabled(this.reachable && !this.scheduleSaving).bindMenu(this.scheduleJobMenu(job))
        }.width('100%').padding({ left: 14, right: 6, top: 12, bottom: 12 })
          .attributeModifier(glassCardSurface(this.darkMode, 16))
      }, (job: ScheduleJob) => `${job.id}:${job.version}:${job.nextAt}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  private stateColor(state: string): Resource {
    if (state === 'waiting') return $r('app.color.pigo_warning');
    if (state === 'queued') return $r('app.color.pigo_queued');
    return $r('app.color.pigo_success');
  }

  private stateLabel(state: string): string {
    if (state === 'waiting') return '待处理';
    if (state === 'queued') return '排队中';
    return '运行中';
  }
}
