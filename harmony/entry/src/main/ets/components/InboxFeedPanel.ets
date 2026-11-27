import { PiGoPageStore } from '../model/PiGoPageStore';
import { glassCardSurface, themedCardSurface } from '../Immersive';
import { RunMessage, scheduleRunStatus } from '../ScheduledRuns';
import { InboxRun, runStatus } from '../RunResults';
import { RunningRow } from '../model/PiGoTypes';
import { headerSymbol } from './HeaderSymbol';
import { runStatusInk, runStatusMark } from './RunStatusMark';

interface FeedEntry {
  key: string;
  kind: string;
  timestamp: number;
  unread: boolean;
  inboxRun?: InboxRun;
  scheduleMessage?: RunMessage;
}

interface FeedFilterTab {
  id: string;
  label: string;
}

const FEED_FILTERS: FeedFilterTab[] = [
  { id: 'all', label: '全部' },
  { id: 'schedule', label: '定时' },
  { id: 'alert', label: '提醒' },
  { id: 'run', label: '会话' }
];

function padTwo(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

function relativeFeedTime(ms?: number): string {
  if (!ms || ms <= 0) return '';
  const now = Date.now();
  const diff = now - ms;
  if (diff < 60_000 && diff >= -60_000) return '刚刚';
  if (diff >= 60_000 && diff < 3_600_000) return `${Math.floor(diff / 60_000)}分钟前`;
  const date = new Date(ms);
  const current = new Date(now);
  const hm = `${padTwo(date.getHours())}:${padTwo(date.getMinutes())}`;
  const sameDay = date.getFullYear() === current.getFullYear() &&
    date.getMonth() === current.getMonth() && date.getDate() === current.getDate();
  if (sameDay) return hm;
  const yesterday = new Date(current.getFullYear(), current.getMonth(), current.getDate() - 1);
  if (date.getFullYear() === yesterday.getFullYear() &&
    date.getMonth() === yesterday.getMonth() && date.getDate() === yesterday.getDate()) {
    return `昨天 ${hm}`;
  }
  if (date.getFullYear() === current.getFullYear()) {
    return `${padTwo(date.getMonth() + 1)}-${padTwo(date.getDate())} ${hm}`;
  }
  return `${date.getFullYear()}-${padTwo(date.getMonth() + 1)}-${padTwo(date.getDate())}`;
}

@Extend(Button)
function feedAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@ComponentV2
export struct InboxFeedPanel {
  @Param @Require store: PiGoPageStore;
  @Local private activeFilter: string = 'all';
  @Local private selectedRunKeys: string[] = [];
  @Local private refreshing: boolean = false;
  @Local private filterVisible: boolean = true;
  private scrollDelta: number = 0;
  private refreshTimer: number = -1;

  aboutToDisappear(): void {
    if (this.refreshTimer !== -1) clearTimeout(this.refreshTimer);
    this.refreshTimer = -1;
  }

  private waitingRuns(): InboxRun[] {
    return this.store.runCenter.displayedInboxRuns().filter((row: InboxRun): boolean => row.run.status === 'waiting');
  }

  private alertRuns(): InboxRun[] {
    return this.store.runCenter.displayedInboxRuns().filter((row: InboxRun): boolean => row.run.status === 'alert');
  }

  private recentRuns(): InboxRun[] {
    return this.store.runCenter.displayedInboxRuns().filter((row: InboxRun): boolean =>
      row.run.status !== 'waiting' && row.run.status !== 'alert');
  }

  private scheduleMessages(): RunMessage[] {
    return this.store.scheduleController.state.scheduleMessages.filter((message: RunMessage): boolean => !message.dismissed);
  }

  private allFeedEntries(): FeedEntry[] {
    const entries: FeedEntry[] = [];
    for (const row of this.alertRuns()) {
      entries.push({
        key: `alert:${row.run.id}:${row.address}`,
        kind: 'alert',
        timestamp: row.run.finishedAt || 0,
        unread: row.unread,
        inboxRun: row
      });
    }
    for (const row of this.recentRuns()) {
      entries.push({
        key: `run:${row.run.id}:${row.address}`,
        kind: 'run',
        timestamp: row.run.finishedAt || 0,
        unread: row.unread,
        inboxRun: row
      });
    }
    for (const message of this.scheduleMessages()) {
      entries.push({
        key: `schedule:${message.key}`,
        kind: 'schedule',
        timestamp: message.run.finishedAt ?? message.run.scheduledAt ?? 0,
        unread: message.unread,
        scheduleMessage: message
      });
    }
    entries.sort((a: FeedEntry, b: FeedEntry): number => b.timestamp - a.timestamp);
    return entries;
  }

  private filteredFeed(): FeedEntry[] {
    const all = this.allFeedEntries();
    if (this.activeFilter === 'all') return all;
    return all.filter((entry: FeedEntry): boolean => entry.kind === this.activeFilter);
  }

  private filterHasUnread(id: string): boolean {
    if (id === 'schedule') return this.scheduleMessages().some((item: RunMessage): boolean => item.unread);
    if (id === 'alert') return this.alertRuns().some((item: InboxRun): boolean => item.unread);
    if (id === 'run') return this.recentRuns().some((item: InboxRun): boolean => item.unread);
    return false;
  }

  private selectableRunKeys(): string[] {
    const keys: string[] = [];
    for (const entry of this.filteredFeed()) {
      if (entry.inboxRun && (entry.kind === 'alert' || entry.kind === 'run')) {
        keys.push(entry.inboxRun.run.id);
      }
    }
    return keys;
  }

  private selectedKeys(): string[] {
    return this.selectableRunKeys().filter((key: string): boolean => this.selectedRunKeys.includes(key));
  }

  private allRunsSelected(): boolean {
    const keys = this.selectableRunKeys();
    return keys.length > 0 && keys.every((key: string): boolean => this.selectedRunKeys.includes(key));
  }

  private resetRunSelection(): void {
    this.store.inboxSelecting = false;
    this.selectedRunKeys = [];
  }

  private selectFilter(id: string): void {
    if (this.activeFilter === id) return;
    this.activeFilter = id;
    this.selectedRunKeys = [];
    this.filterVisible = true;
  }

  private toggleRunSelection(key: string): void {
    const current = this.selectedKeys();
    this.selectedRunKeys = current.includes(key) ?
      current.filter((id: string): boolean => id !== key) : current.concat([key]);
  }

  private async deleteSelectedRuns(): Promise<void> {
    const keys = this.selectedKeys();
    if (!keys.length || (this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning)) return;
    if (await this.store.runCenter.dismissInboxRuns(keys)) this.resetRunSelection();
  }

  private triggerRefresh(): void {
    this.refreshing = true;
    this.filterVisible = true;
    this.store.scheduleController.queueScheduleSync(true);
    this.store.runCenter.queueRunSync(0);
    void this.store.loadSessionStatus();
    if (this.refreshTimer !== -1) clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => {
      this.refreshing = false;
      this.refreshTimer = -1;
    }, 650);
  }

  private hasLiveSection(): boolean {
    return this.waitingRuns().length > 0 ||
      (this.store.session.reachable && (this.store.taskPanelRows().length > 0 || this.store.standaloneScheduleRuns().length > 0));
  }

  private showComputerLabel(): boolean {
    return this.store.computers.length > 1;
  }

  private emptyTitle(): string {
    if (this.activeFilter === 'schedule') return '暂无定时任务汇报';
    if (this.activeFilter === 'alert') return '暂无工作区提醒';
    if (this.activeFilter === 'run') return '暂无最近会话动态';
    return '暂无新动态';
  }

  private emptySubtitle(): string {
    if (this.activeFilter === 'schedule') return '定时任务执行完成后，结果会第一时间出现在这里。';
    if (this.activeFilter === 'alert') return '通过 pigo-notify 推送的本机监控与提醒会显示在这里。';
    if (this.activeFilter === 'run') return '最近完成的 Agent 会话运行记录会显示在这里。';
    return 'Agent 运行结果、定时任务汇报与本机提醒会按时间汇聚在这里。';
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Refresh({ refreshing: $$this.refreshing }) {
        List({ space: 10 }) {
          if (this.store.scheduleController.state.scheduleError || this.store.scheduleController.state.scheduleOffline.length) {
            ListItem() {
              Row({ space: 8 }) {
                headerSymbol($r('sys.symbol.exclamationmark_circle'), $r('app.color.pigo_warning'), 15)
                Text(this.store.scheduleController.state.scheduleError || '部分电脑离线，重新连接后会补收结果。').layoutWeight(1)
                  .fontSize(12).fontColor($r('app.color.pigo_muted'))
              }.padding({ left: 6, right: 6, top: 2, bottom: 2 })
            }
          }
          if (this.hasLiveSection()) {
            ListItem() {
              this.liveStatusStrip()
            }
          }
          ForEach(this.filteredFeed(), (entry: FeedEntry) => {
            if (entry.kind === 'schedule' && entry.scheduleMessage) {
              ListItem() {
                this.scheduledMessageRow(entry.scheduleMessage)
              }.swipeAction({ end: this.store.inboxSelecting ? undefined : this.scheduleInboxDelete.bind(this, entry.scheduleMessage), edgeEffect: SwipeEdgeEffect.None })
            } else if (entry.kind === 'alert' && entry.inboxRun) {
              ListItem() {
                this.inboxAlertRow(entry.inboxRun)
              }.swipeAction({ end: this.store.inboxSelecting ? undefined : this.inboxRunDelete.bind(this, entry.inboxRun), edgeEffect: SwipeEdgeEffect.None })
            } else if (entry.inboxRun) {
              ListItem() {
                this.inboxRunRow(entry.inboxRun)
              }.swipeAction({ end: this.store.inboxSelecting ? undefined : this.inboxRunDelete.bind(this, entry.inboxRun), edgeEffect: SwipeEdgeEffect.None })
            }
          }, (entry: FeedEntry) => `${entry.key}:${entry.unread}:${entry.timestamp}`)
          if (!this.filteredFeed().length && !(this.activeFilter === 'all' && this.hasLiveSection())) {
            ListItem() {
              Column({ space: 10 }) {
                Stack() {
                  headerSymbol($r('sys.symbol.inbox'), this.store.accent(), 24)
                }.width(52).height(52).borderRadius(16).backgroundColor(this.store.accentTint())
                Text(this.emptyTitle()).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
                Text(this.emptySubtitle())
                  .fontSize(13).fontColor($r('app.color.pigo_muted')).textAlign(TextAlign.Center)
                  .constraintSize({ maxWidth: 260 })
              }.width('100%').padding({ top: 72, bottom: 48 })
            }
          }
        }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
          .contentStartOffset(this.store.topContentClearance() + 6)
          .contentEndOffset(this.store.bottomContentClearance() + 56)
          .padding({ left: 16, right: 16 })
          .onDidScroll((_xOffset: number, yOffset: number) => {
            if (this.store.inboxSelecting || Math.abs(yOffset) < 0.5) return;
            if ((yOffset > 0 && this.scrollDelta < 0) || (yOffset < 0 && this.scrollDelta > 0)) {
              this.scrollDelta = 0;
            }
            this.scrollDelta += yOffset;
            if (this.scrollDelta > 28 && this.filterVisible) {
              this.filterVisible = false;
              this.scrollDelta = 0;
            } else if (this.scrollDelta < -20 && !this.filterVisible) {
              this.filterVisible = true;
              this.scrollDelta = 0;
            }
          })
          .onReachStart(() => {
            this.scrollDelta = 0;
            this.filterVisible = true;
          })
      }.width('100%').height('100%')
        .onRefreshing(() => { this.triggerRefresh(); })

      if (this.store.inboxSelecting) {
        this.runSelectionActions()
      } else {
        this.floatingFilterPill()
      }
    }.width('100%').height('100%')
  }

  @Builder
  liveStatusStrip() {
    Column({ space: 8 }) {
      ForEach(this.waitingRuns(), (row: InboxRun) => {
        this.inboxRunRow(row)
      }, (row: InboxRun) => `wait:${row.run.id}:${row.address}`)
      if (this.store.session.reachable) {
        ForEach(this.store.standaloneScheduleRuns(), (row: RunMessage) => {
          Row({ space: 8 }) {
            Blank().width(7).height(7).borderRadius(4).backgroundColor(this.store.accent())
            Text(`${row.run.name} · 定时任务运行中`).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.pigo_text')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').padding({ left: 14, right: 14, top: 11, bottom: 11 })
            .attributeModifier(glassCardSurface(this.store.darkMode, 14))
        }, (row: RunMessage) => row.key)
        ForEach(this.store.taskPanelRows(), (row: RunningRow) => {
          this.runningRowCard(row)
        }, (row: RunningRow) => row.id)
      }
    }.width('100%').padding({ bottom: 4 })
  }

  @Builder
  floatingFilterPill() {
    Row({ space: 3 }) {
      ForEach(FEED_FILTERS, (tab: FeedFilterTab) => {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 4 }) {
            Text(tab.label).fontSize(13)
              .fontWeight(this.activeFilter === tab.id ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(this.activeFilter === tab.id ? this.store.accentForeground() : $r('app.color.pigo_text'))
              .opacity(this.activeFilter === tab.id ? 1 : 0.78)
            if (this.activeFilter !== tab.id && this.filterHasUnread(tab.id)) {
              Blank().width(5).height(5).borderRadius(3).backgroundColor(this.store.accent())
            }
          }.justifyContent(FlexAlign.Center)
        }.id(`feed-filter-${tab.id}`).height(32).padding({ left: 14, right: 14 })
          .borderRadius(16)
          .backgroundColor(this.activeFilter === tab.id ? this.store.accent() : Color.Transparent)
          .accessibilitySelected(this.activeFilter === tab.id)
          .onClick(() => { this.selectFilter(tab.id); })
      }, (tab: FeedFilterTab) => tab.id)
    }.padding(3).borderRadius(20)
      .attributeModifier(glassCardSurface(this.store.darkMode, 20))
      .margin({ bottom: this.store.bottomContentClearance() + 2 })
      .opacity(this.filterVisible ? 1 : 0)
      .translate({ y: this.filterVisible ? 0 : 18 })
      .hitTestBehavior(this.filterVisible ? HitTestMode.Default : HitTestMode.None)
      .animation({ duration: 200, curve: Curve.FastOutSlowIn })
  }

  @Builder
  runSelectionActions() {
    Row({ space: 8 }) {
      Button('取消').feedAction().height(40).enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning))
        .onClick(() => { this.resetRunSelection(); })
      Button(this.allRunsSelected() ? '取消全选' : '全选').feedAction().height(40)
        .enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) && this.selectableRunKeys().length > 0)
        .onClick(() => { this.selectedRunKeys = this.allRunsSelected() ? [] : this.selectableRunKeys(); })
      Blank()
      Button((this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) ? '删除中…' : `删除（${this.selectedKeys().length}）`).feedAction()
        .height(40).fontColor($r('app.color.pigo_error'))
        .enabled(!(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) && this.selectedKeys().length > 0)
        .onClick(() => { void this.deleteSelectedRuns(); })
    }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .margin({ left: 16, right: 16, bottom: this.store.bottomContentClearance() + 2 })
      .attributeModifier(glassCardSurface(this.store.darkMode, 18))
  }

  @Builder
  runSelectionMark(key: string) {
    SymbolGlyph(this.selectedRunKeys.includes(key) ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
      .fontSize(21).fontColor([this.selectedRunKeys.includes(key) ? this.store.accent() : $r('app.color.pigo_muted')])
      .accessibilityLevel('no')
  }

  @Builder
  runningRowCard(row: RunningRow) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        Blank().width(7).height(7).borderRadius(4).backgroundColor(this.store.stateColor(row.state ?? ''))
        Text(row.name || '后台任务').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Text(`${row.id === this.store.session.currentId ? '当前 · ' : ''}${this.store.stateLabel(row.state ?? '')}`)
          .fontSize(12).fontColor(this.store.stateColor(row.state ?? ''))
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([$r('app.color.pigo_muted')])
      }.width('100%').padding({ left: 14, right: 12, top: 11, bottom: 11 })
    }.id(`feed-running-${row.id}`).width('100%').padding(0)
      .attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      .enabled(!this.store.session.busy && !this.store.session.openingSession && (this.store.session.reachable || row.id === this.store.session.currentId))
      .onClick(() => {
        if (this.store.session.openingSession) return;
        if (row.id !== this.store.session.currentId) void this.store.sessionActions.requestAction('/open', { id: row.id });
        this.store.activeTab = 'tasks';
      })
  }

  @Builder
  inboxAlertRow(row: InboxRun) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        if (this.store.inboxSelecting) {
          this.runSelectionMark(row.run.id)
        }
        runStatusMark(row.run.severity === 'error' ? 'failed' : 'alert', this.store.accent(), this.store.accentTint(), 36)
        Column({ space: 5 }) {
          Row({ space: 6 }) {
            Text(row.run.title || '工作区提醒').fontSize(15).fontWeight(row.unread ? FontWeight.Bold : FontWeight.Medium)
              .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            Text(relativeFeedTime(row.run.finishedAt)).fontSize(11).fontColor($r('app.color.pigo_muted'))
            if (row.unread) Blank().width(6).height(6).borderRadius(3).backgroundColor(this.store.accent())
          }.width('100%').alignItems(VerticalAlign.Center)
          if (row.run.body) {
            Text(row.run.body).fontSize(13).lineHeight(19).fontColor($r('app.color.pigo_text')).opacity(0.8)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Row({ space: 6 }) {
            Text(row.run.source || '提醒').fontSize(11).fontWeight(FontWeight.Medium)
              .fontColor(this.store.accent()).backgroundColor(this.store.accentTint())
              .padding({ left: 7, right: 7, top: 2, bottom: 2 }).borderRadius(6)
            if (this.showComputerLabel()) {
              Text(row.computer).fontSize(11).fontColor($r('app.color.pigo_muted')).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            } else {
              Blank().layoutWeight(1)
            }
            if (!this.store.inboxSelecting) {
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.pigo_muted')])
            }
          }.width('100%').alignItems(VerticalAlign.Center)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding(13)
    }.id(`inbox-alert-${row.run.id}`).width('100%').padding(0)
      .attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      .accessibilitySelected(this.store.inboxSelecting && this.selectedRunKeys.includes(row.run.id))
      .enabled(this.store.inboxSelecting ? !(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) : true)
      .onClick(() => {
        if (this.store.inboxSelecting) this.toggleRunSelection(row.run.id);
        else {
          this.store.runCenter.markRunRead(row.run.id);
          this.store.scheduleController.showAlertDetail(row);
        }
      })
  }

  @Builder
  inboxRunRow(row: InboxRun) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        if (this.store.inboxSelecting && row.run.status !== 'waiting') {
          this.runSelectionMark(row.run.id)
        }
        runStatusMark(row.run.status, this.store.accent(), this.store.accentTint(), 36)
        Column({ space: 5 }) {
          Row({ space: 6 }) {
            Text(row.run.title || 'Agent 会话').fontSize(15).fontWeight(row.unread ? FontWeight.Bold : FontWeight.Medium)
              .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            Text(relativeFeedTime(row.run.finishedAt)).fontSize(11).fontColor($r('app.color.pigo_muted'))
            if (row.unread) Blank().width(6).height(6).borderRadius(3).backgroundColor(this.store.accent())
          }.width('100%').alignItems(VerticalAlign.Center)
          Row({ space: 6 }) {
            Text('会话').fontSize(11).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.pigo_muted')).backgroundColor($r('app.color.pigo_control'))
              .padding({ left: 7, right: 7, top: 2, bottom: 2 }).borderRadius(6)
            if (this.showComputerLabel()) {
              Text(row.computer).fontSize(11).fontColor($r('app.color.pigo_muted')).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            } else {
              Blank().layoutWeight(1)
            }
            Text(runStatus(row.run.status)).fontSize(11).fontWeight(FontWeight.Medium)
              .fontColor(runStatusInk(row.run.status, this.store.accent()))
              .backgroundColor(row.run.status === 'waiting' ? $r('app.color.pigo_warning_panel') : $r('app.color.pigo_control'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(8)
          }.width('100%').alignItems(VerticalAlign.Center)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding(13)
    }.id(`inbox-run-${row.run.id}`).width('100%').padding(0)
      .attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      .accessibilitySelected(this.store.inboxSelecting && row.run.status !== 'waiting' && this.selectedRunKeys.includes(row.run.id))
      .enabled(this.store.inboxSelecting && row.run.status !== 'waiting' ? !(this.store.scheduleController.state.scheduleSaving || this.store.runCenter.state.inboxCleaning) : !this.store.session.busy && !this.store.session.openingSession)
      .onClick(() => {
        if (this.store.inboxSelecting && row.run.status !== 'waiting') this.toggleRunSelection(row.run.id);
        else void this.store.runCenter.openInboxRun(row);
      })
  }

  @Builder
  scheduledMessageRow(message: RunMessage) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph(this.scheduleStatusSymbol(message.run.status)).fontSize(19)
            .fontColor([this.scheduleStatusColor(message.run.status)])
        }.width(36).height(36).borderRadius(10).backgroundColor(this.scheduleStatusPanel(message.run.status))
        Column({ space: 5 }) {
          Row({ space: 6 }) {
            Text(message.run.name).fontSize(15).fontWeight(message.unread ? FontWeight.Bold : FontWeight.Medium)
              .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            Text(relativeFeedTime(message.run.finishedAt ?? message.run.scheduledAt)).fontSize(11).fontColor($r('app.color.pigo_muted'))
            if (message.unread) Blank().width(6).height(6).borderRadius(3).backgroundColor(this.store.accent())
          }.width('100%').alignItems(VerticalAlign.Center)
          if (message.run.summary) {
            Text(message.run.summary).fontSize(13).lineHeight(19).fontColor($r('app.color.pigo_text')).opacity(0.8)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Row({ space: 6 }) {
            Text('定时任务').fontSize(11).fontWeight(FontWeight.Medium)
              .fontColor(this.scheduleStatusColor(message.run.status))
              .backgroundColor(this.scheduleStatusPanel(message.run.status))
              .padding({ left: 7, right: 7, top: 2, bottom: 2 }).borderRadius(6)
            if (this.showComputerLabel()) {
              Text(message.computer).fontSize(11).fontColor($r('app.color.pigo_muted')).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            } else {
              Blank().layoutWeight(1)
            }
            Text(scheduleRunStatus(message.run.status)).fontSize(11).fontWeight(FontWeight.Medium)
              .fontColor(this.scheduleStatusColor(message.run.status))
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.pigo_muted')])
          }.width('100%').alignItems(VerticalAlign.Center)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').padding(13)
    }.id(`schedule-message-${message.run.id}`).width('100%').padding(0)
      .attributeModifier(themedCardSurface(this.store.darkMode, this.store.themeId))
      .onClick(() => {
        this.store.scheduleController.showScheduleDetail(message);
      })
  }

  @Builder
  inboxRunDelete(row: InboxRun) {
    Button('删除').id(`inbox-dismiss-${row.run.id}`).width(72).height('100%').padding(0)
      .fontColor(Color.White).backgroundColor($r('app.color.pigo_error')).borderRadius(14)
      .accessibilityText(`删除动态 ${row.run.title || '提醒'}`)
      .onClick(() => { void this.store.runCenter.dismissInboxRuns([row.run.id]); })
  }

  @Builder
  scheduleInboxDelete(message: RunMessage) {
    Button('删除').id(`schedule-dismiss-${message.run.id}`).width(72).height('100%').padding(0)
      .fontColor(Color.White).backgroundColor($r('app.color.pigo_error')).borderRadius(14)
      .accessibilityText(`删除动态消息 ${message.run.name}`)
      .onClick(() => { this.store.scheduleController.dismissScheduleMessage(message); })
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
