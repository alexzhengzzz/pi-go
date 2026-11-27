import { themedCardSurface } from '../Immersive';
import { PiGoPageStore } from '../model/PiGoPageStore';
import { AlertSourceSummary } from '../model/RunCenterController';
import { workspaceName } from '../model/SessionStore';
import { ScheduleJob, scheduleTime } from '../ScheduledRuns';
import { headerSymbol } from './HeaderSymbol';

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
  @Param @Require store: PiGoPageStore;

  private agentLabel(agent: string): string {
    if (!agent) return '';
    if (agent === 'pi') return 'Pi';
    if (agent === 'codex') return 'Codex';
    if (agent === 'agy') return 'AGY';
    return agent.toUpperCase();
  }

  private sourceMenu(item: AlertSourceSummary): MenuElement[] {
    const menus: MenuElement[] = [
      {
        value: '查看历史与规则',
        action: () => { this.store.scheduleController.showAlertSourceHistory(item.source); }
      },
      {
        value: item.muted ? '取消静音' : '静音此来源',
        action: () => { this.store.runCenter.setAlertSourceMuted(item.source, !item.muted); }
      },
      {
        value: '默认 Agent：自动',
        action: () => { this.store.runCenter.setAlertSourceAgent(item.source, ''); }
      }
    ];
    const known = this.store.agents.length ? this.store.agents.map((agent) => agent.id) : ['pi', 'codex', 'agy'];
    for (const id of known) {
      menus.push({
        value: `默认 Agent：${this.agentLabel(id)}`,
        action: () => { this.store.runCenter.setAlertSourceAgent(item.source, id); }
      });
    }
    return menus;
  }

  build() {
    Scroll() {
      Column({ space: 24 }) {
        this.scheduledTasksSection()
        this.alertSourcesSection()
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: this.store.topContentClearance() + 4, bottom: this.store.bottomContentClearance() })
    }.scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off).width('100%').layoutWeight(1)
      .align(Alignment.TopStart).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  scheduledTasksSection() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('定时任务').layoutWeight(1).fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.pigo_text'))
        Button('运行历史').chatAction().id('schedule-history').height(34).padding({ left: 12, right: 12 })
          .onClick(() => {
            this.store.scheduleController.state.scheduleError = '';
            this.store.scheduleController.state.schedulePage = 'history';
          })
        Button('新建').chatAction().id('schedule-create').height(34).padding({ left: 14, right: 14 })
          .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground())
          .enabled(this.store.session.reachable && this.store.projects.length > 0 &&
            !this.store.scheduleController.state.scheduleSaving && !this.store.scheduleController.state.scheduleListError)
          .onClick(() => { this.store.scheduleController.editSchedule(); })
      }.width('100%').alignItems(VerticalAlign.Center)
      if (this.store.scheduleController.state.scheduleListError) {
        Text(this.store.scheduleController.state.scheduleListError).fontSize(14).fontColor($r('app.color.pigo_error'))
      } else if (!this.store.session.reachable && this.store.scheduleController.state.scheduleJobs.length) {
        Text('显示上次连接时的定时计划').fontSize(13).fontColor($r('app.color.pigo_muted'))
      } else if (this.store.session.reachable && this.store.scheduleController.state.scheduleLoaded &&
        !this.store.scheduleController.state.scheduleJobs.length) {
        Text(this.store.projects.length ? '还没有定时任务，点右上角「新建」创建自动计划。' : '共享工作区后可创建定时任务。')
          .fontSize(13).fontColor($r('app.color.pigo_muted')).padding({ left: 2 })
      }
      ForEach(this.store.scheduleController.state.scheduleJobs, (job: ScheduleJob) => {
        Row({ space: 10 }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.clock')).fontSize(18)
              .fontColor([job.enabled ? this.store.accent() : $r('app.color.pigo_muted')])
          }.width(36).height(36).borderRadius(10)
            .backgroundColor(job.enabled ? this.store.accentTint() : $r('app.color.pigo_control'))
          Column({ space: 4 }) {
            Text(job.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${workspaceName(this.store.workspaces, job.cwd)} · ${!job.enabled ? '已暂停' :
              job.nextAt === null ? '已结束' : `下次 ${scheduleTime(job.nextAt)}`}`)
              .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_more')).width(18).height(18).fillColor($r('app.color.pigo_muted'))
          }.id(`schedule-operations-${job.id}`).width(40).height(40).padding(0).borderRadius(10)
            .backgroundColor(Color.Transparent).accessibilityText('定时任务操作')
            .enabled(this.store.session.reachable && !this.store.scheduleController.state.scheduleSaving)
            .bindMenu(this.store.scheduleJobMenu(job))
        }.width('100%').padding({ left: 13, right: 6, top: 12, bottom: 12 })
          .attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      }, (job: ScheduleJob) => `${job.id}:${job.version}:${job.nextAt}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  alertSourcesSection() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('本机提醒源').fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
          Text('按 pigo-notify 的 --source 自动聚合，支持静音与默认 Agent').fontSize(12).fontColor($r('app.color.pigo_muted'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (!this.store.runCenter.alertSources().length) {
        Row({ space: 12 }) {
          Stack() {
            headerSymbol($r('sys.symbol.bell'), this.store.accent(), 18)
          }.width(38).height(38).borderRadius(11).backgroundColor(this.store.accentTint())
          Column({ space: 3 }) {
            Text('暂无本机提醒源').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            Text('电脑脚本通过 pigo-notify --source 推送后会自动出现在这里。')
              .fontSize(12).fontColor($r('app.color.pigo_muted')).lineHeight(18)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding(13).attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      }
      ForEach(this.store.runCenter.alertSources(), (item: AlertSourceSummary) => {
        Row({ space: 10 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 11 }) {
              Stack() {
                headerSymbol($r('sys.symbol.bell'), item.muted ? $r('app.color.pigo_muted') : this.store.accent(), 17)
              }.width(36).height(36).borderRadius(10)
                .backgroundColor(item.muted ? $r('app.color.pigo_control') : this.store.accentTint())
              Column({ space: 4 }) {
                Row({ space: 6 }) {
                  Text(item.source).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (item.muted) {
                    Text('已静音').fontSize(10).fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.pigo_warning')).backgroundColor($r('app.color.pigo_warning_panel'))
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6)
                  }
                  if (item.defaultAgent) {
                    Text(this.agentLabel(item.defaultAgent)).fontSize(10).fontWeight(FontWeight.Medium)
                      .fontColor(this.store.accent()).backgroundColor(this.store.accentTint())
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6)
                  }
                }.width('100%').alignItems(VerticalAlign.Center)
                Text(item.count > 0 ?
                  `共 ${item.count} 条${item.latestAt ? ' · 最近 ' + scheduleTime(item.latestAt) : ''}` :
                  '暂无历史记录')
                  .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                if (item.latestTitle) {
                  Text(item.latestTitle).fontSize(12).fontColor($r('app.color.pigo_text')).opacity(0.72)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').padding({ left: 13, right: 4, top: 12, bottom: 12 })
          }.id(`alert-source-${item.source}`).layoutWeight(1).padding(0).backgroundColor(Color.Transparent)
            .onClick(() => { this.store.scheduleController.showAlertSourceHistory(item.source); })
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_more')).width(18).height(18).fillColor($r('app.color.pigo_muted'))
          }.id(`alert-source-menu-${item.source}`).width(40).height(40).padding(0).borderRadius(10)
            .backgroundColor(Color.Transparent).accessibilityText(`${item.source} 操作`)
            .bindMenu(this.sourceMenu(item))
        }.width('100%').padding({ right: 6 })
          .attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      }, (item: AlertSourceSummary) => `${item.source}:${item.count}:${item.muted}:${item.defaultAgent}:${item.latestAt}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
