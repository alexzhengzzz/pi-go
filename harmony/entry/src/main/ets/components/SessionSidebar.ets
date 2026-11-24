import { glassCardSurface, glassDrawerSurface, immersiveSurface } from '../Immersive';
import { headerSymbol } from './HeaderSymbol';
import { unboundAction } from './ComponentAction';
import { SIDEBAR_VIEWS, workspaceName } from '../model/SessionStore';
import { SessionRow, SidebarRow, PendingInteraction, RunningRow, WorkspaceRow, Payload } from '../model/PiGoTypes';
import { SHORT_WINDOW_HEIGHT } from '../model/PiGoConstants';
import { SidebarRows } from '../model/SidebarRows';

@Extend(Button)
function chatAction() {
  .backgroundColor($r('app.color.pigo_control'))
  .fontColor($r('app.color.pigo_text'))
  .fontSize(14)
  .fontWeight(FontWeight.Medium)
  .borderRadius(12)
}

@ComponentV2
export struct SessionSidebar {
  @Param @Require darkMode: boolean;
  @Local private refreshing: boolean = false;
  @Param @Require activeTab: string;
  @Event $activeTab: (value: string) => void = unboundAction;
  @Param @Require base: string;
  @Param @Require busy: boolean;
  @Param @Require canCreateWorkspace: boolean;
  @Event confirmCloseSpace: (path: string, epoch: number) => void = unboundAction;
  @Event openNewSession: (path?: string) => void = unboundAction;
  @Param @Require currentId: string;
  @Param @Require expandedSpaces: string[];
  @Param @Require hostAvailable: boolean;
  @Param @Require idle: boolean;
  @Param @Require interaction?: PendingInteraction;
  @Param @Require library: Scroller = new Scroller();
  @Event loadMoreSessions: (path: string) => void = unboundAction;
  @Param @Require loadedView: string;
  @Param @Require offlineDismissed: boolean;
  @Event $offlineDismissed: (value: boolean) => void = unboundAction;
  @Event openComputers: () => void = unboundAction;
  @Param @Require openingSession: boolean;
  @Param @Require openingSessionId: string;
  @Param @Require projects: string[];
  @Param @Require queued: boolean;
  @Param @Require reachable: boolean;
  @Event refreshSessions: () => Promise<void> = unboundAction;
  @Event requestAction: (path: string, input?: Payload) => Promise<boolean> = unboundAction;
  @Event revealLibraryAnchor: () => void = unboundAction;
  @Param @Require runningSessionIds: string[];
  @Param @Require runningSessions: RunningRow[];
  @Event schedule: (delay: number) => void = unboundAction;
  @Event selectSessionView: (view: string) => void = unboundAction;
  @Param @Require sessionCatalogFailed: boolean;
  @Param @Require sessionCatalogLoaded: boolean;
  @Param @Require sessionLoading: boolean;
  @Param @Require sessionView: string;
  @Param @Require sessions: SessionRow[];
  @Event setDrawer: (open: boolean) => void = unboundAction;
  @Param @Require showFiles: boolean;
  @Event $showFiles: (value: boolean) => void = unboundAction;
  @Param @Require showSettings: boolean;
  @Event $showSettings: (value: boolean) => void = unboundAction;
  @Param @Require sidebarRows: SidebarRows = new SidebarRows();
  @Param @Require statusBarHeight: number;
  @Event swipeDrawer: (event: GestureEvent) => void = unboundAction;
  @Event toggleSpace: (path: string) => void = unboundAction;
  @Event updateSessionMeta: (session: SessionRow, pin: boolean) => Promise<void> = unboundAction;
  @Event shareSession: (session: SessionRow) => Promise<void> = unboundAction;
  @Param @Require windowHeight: number;
  @Param @Require workspaces: WorkspaceRow[];
  @Param @Require accent: string;
  @Param @Require accentForeground: string;
  @Param @Require accentTint: string;
  @Param @Require bottomPad: number;
  @Param @Require compactSessionPane: boolean;
  @Param @Require computerTitle: string;
  @Param @Require dockedSessions: boolean;
  @Param @Require drawerWidth: number;
  @Param @Require sessionPaneWidth: number;
  @Event onDrawerAppear: () => void = unboundAction;
  @Event connectionEpoch: () => number = unboundAction;

  @Builder
  sidebarHeader() {
    Row({ space: this.compactSessionPane ? 6 : 10 }) {
      if (this.dockedSessions) {
        Stack() {
          SymbolGlyph($r('sys.symbol.computer')).fontSize(19).fontColor([this.accent])
        }.width(34).height(34).borderRadius(10).backgroundColor(this.accentTint)
      }
      Button({ type: ButtonType.Normal }) {
        Row({ space: this.dockedSessions ? 6 : 8 }) {
          if (!this.dockedSessions) {
            SymbolGlyph($r('sys.symbol.computer')).fontSize(21).fontColor([this.accent])
          }
          Text(this.computerTitle).fontSize(this.compactSessionPane ? 14 : this.dockedSessions ? 17 : 19)
            .fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(this.dockedSessions ? 1 : 0)
            .constraintSize({ maxWidth: this.dockedSessions ? '100%' : '65%' })
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(13).fontColor([$r('app.color.pigo_muted')])
        }.width('100%')
      }.id('computers').layoutWeight(1).height(44).padding(0).backgroundColor(Color.Transparent)
        .accessibilityText('切换电脑').enabled(!this.busy).onClick(() => { this.openComputers(); })
      if (!this.dockedSessions) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.xmark'), $r('app.color.pigo_text'), 17)
        }.width(40).height(40).padding(0).borderRadius(20).backgroundColor(Color.Transparent)
          .attributeModifier(immersiveSurface(this.darkMode))
          .accessibilityText('关闭会话抽屉')
          .onClick(() => { this.setDrawer(false); })
      }
    }.width('100%').padding({
      left: this.compactSessionPane ? 10 : 18,
      right: 12,
      top: this.statusBarHeight + (this.compactSessionPane ? 8 : 10),
      bottom: 8
    })
  }

  build() {
    Navigation() {
      Column({ space: !this.dockedSessions || this.compactSessionPane || this.windowHeight < SHORT_WINDOW_HEIGHT ? 8 : 12 }) {
        if (this.dockedSessions) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: this.compactSessionPane ? 6 : 8 }) {
              SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18).fontColor([this.accentForeground])
              Text('新建会话').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.accentForeground).maxLines(1)
            }.justifyContent(FlexAlign.Center).width('100%')
          }.id('drawer-new-task').width('100%').height(44).padding(0).borderRadius(14)
            .backgroundColor(this.accent)
            .enabled(this.reachable && !this.busy && !this.openingSession && this.hostAvailable &&
              (this.projects.length > 0 || this.canCreateWorkspace))
            .onClick(() => { this.openNewSession(); })
        } else {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18).fontColor([this.accent])
              Text('新建会话').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).maxLines(1)
            }.justifyContent(FlexAlign.Center).width('100%')
          }.id('drawer-new-task').width('100%').height(44).padding(0)
            .attributeModifier(glassCardSurface(this.darkMode, 14))
            .enabled(this.reachable && !this.busy && !this.openingSession && this.hostAvailable &&
              (this.projects.length > 0 || this.canCreateWorkspace))
            .onClick(() => { this.openNewSession(); })
        }
        if (!this.reachable) this.offlineNotice(true, this.compactSessionPane)
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignContent: FlexAlign.SpaceBetween }) {
          ForEach(SIDEBAR_VIEWS, (view: string) => {
            Button({ type: ButtonType.Normal }) {
              Text(this.sessionViewLabel(view))
                .fontSize(13).fontColor(this.sessionView === view ? this.accentForeground : $r('app.color.pigo_muted')).maxLines(1)
                .fontWeight(this.sessionView === view ? FontWeight.Medium : FontWeight.Regular)
            }.id(`session-view-${view}`).width(this.compactSessionPane ? '49%' : '24%')
              .height(34).padding(0).borderRadius(10)
              .backgroundColor(this.sessionView === view ? this.accent : Color.Transparent)
              .accessibilitySelected(this.sessionView === view).enabled(!this.busy && !this.sessionLoading && this.reachable)
              .onClick(() => { this.selectSessionView(view); })
          }, (view: string) => view)
        }.width('100%').padding(4).attributeModifier(glassCardSurface(this.darkMode, 14))
        if (this.sessionLoading && (!this.sessionCatalogLoaded || this.loadedView !== this.sessionView)) {
          Text('正在加载任务…').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
        } else if (this.sessionCatalogFailed) {
          Button('任务加载失败，重试').chatAction().id('session-retry').width('100%').height(38)
            .enabled(this.reachable && !this.busy && !this.openingSession).onClick(() => { void this.refreshSessions(); })
        }
        this.sessionLibrary()
        Row({ space: 6 }) {
          Blank().width(6).height(6).borderRadius(3)
            .backgroundColor(this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
          Text(this.base.split('://')[1] || '').id('active-computer').fontSize(11).fontColor($r('app.color.pigo_muted'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').padding({ left: this.compactSessionPane ? 4 : 10 })
      }.width('100%').height('100%')
        .padding({
          left: this.compactSessionPane ? 8 : 12,
          right: 12,
          top: this.statusBarHeight + (this.compactSessionPane ? 58 : 64),
          bottom: this.bottomPad + 18
        })
    }.id('session-sidebar').width(this.dockedSessions ? this.sessionPaneWidth : this.drawerWidth).height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .title({ builder: this.sidebarHeader, height: 52 + this.statusBarHeight + 12 }, {
        backgroundColor: Color.Transparent,
        barStyle: BarStyle.STACK
      })
      .attributeModifier(glassDrawerSurface(this.darkMode, this.dockedSessions))
      .transition(TransitionEffect.move(TransitionEdge.START))
      .onGestureJudgeBegin(() => this.dockedSessions ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
      .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
      .onAppear(() => { this.onDrawerAppear(); })
  }
  @Builder
  offlineNotice(compact: boolean, narrow: boolean = false) {
    Row({ space: narrow ? 6 : 10 }) {
      if (!narrow) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(20)
          .fontColor([$r('app.color.pigo_warning')])
      }
      Column({ space: 4 }) {
        Text(narrow ? '电脑离线' : compact ? '设备已离线，当前为缓存内容' : '电脑设备已离线')
          .fontSize(compact ? 13 : 16).fontWeight(FontWeight.Medium).fontColor(compact ? $r('app.color.pigo_warning') : $r('app.color.pigo_text'))
        if (!compact) Text('请检查电脑与网络连接').fontSize(12).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (!compact) Button('切换').chatAction().height(34).fontSize(13)
        .onClick(() => { if (!this.busy) this.openComputers(); })
      if (compact) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16).fontColor([$r('app.color.pigo_warning')])
        }.id('drawer-retry').width(36).height(34).padding(0).borderRadius(10)
          .backgroundColor(Color.Transparent).enabled(!this.busy)
          .accessibilityText('重试连接')
          .onClick(() => { this.$offlineDismissed(false); this.schedule(0); })
      } else {
        Button('重试').chatAction().id('offline-retry')
          .height(34).fontSize(13).enabled(!this.busy)
          .accessibilityText('重试连接')
          .onClick(() => { this.$offlineDismissed(false); this.schedule(0); })
      }
      if (!compact) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
        }.width(34).height(34).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
          .accessibilityText('关闭离线提示').onClick(() => { this.$offlineDismissed(true); })
      }
    }.width('100%').padding(narrow ? 8 : compact ? 10 : 14).borderRadius(compact ? 12 : 16)
      .backgroundColor(compact ? $r('app.color.pigo_warning_panel') : $r('app.color.pigo_panel'))
      .border({ width: compact ? 0 : 1, color: $r('app.color.pigo_line') })
  }
  @Builder
  taskRow(session: SessionRow, nested: boolean) {
    Row({ space: 0 }) {
      Button({ type: ButtonType.Normal }) {
        Flex({ direction: this.compactSessionPane ? FlexDirection.Column : FlexDirection.Row,
          justifyContent: this.compactSessionPane ? FlexAlign.Center : FlexAlign.Start,
          alignItems: this.compactSessionPane ? ItemAlign.Start : ItemAlign.Center }) {
          if (this.compactSessionPane) {
            Text(session.name === '(no messages)' ? '新任务' : session.name || '未命名任务')
              .fontSize(14).fontColor($r('app.color.pigo_text')).width('100%').maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          } else {
            Text(session.name === '(no messages)' ? '新任务' : session.name || '未命名任务')
              .fontSize(16).fontColor($r('app.color.pigo_text')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }
          if (session.agent && session.agent !== 'pi') {
            Text(session.agent === 'codex' ? 'Codex' : session.agent === 'agy' ? 'AGY' : session.agent.toUpperCase())
              .fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.accent)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6)
              .backgroundColor(this.accentTint)
              .margin({ left: this.compactSessionPane ? 0 : 6, top: this.compactSessionPane ? 2 : 0 })
          }
          if (session.id === this.openingSessionId) {
            Text('正在打开…').id('session-opening').fontSize(11).fontColor(this.accent).maxLines(1)
              .margin({ left: this.compactSessionPane ? 0 : 8, top: this.compactSessionPane ? 2 : 0 })
          } else if (this.sessionRunning(session.id)) {
            Row({ space: 4 }) {
              Text('').width(6).height(6).borderRadius(3)
                .backgroundColor(this.stateColor(this.sessionState(session.id)))
              Text(this.stateLabel(this.sessionState(session.id))).fontSize(11)
                .fontColor(this.stateColor(this.sessionState(session.id)))
            }.margin({ left: this.compactSessionPane ? 0 : 8, top: this.compactSessionPane ? 2 : 0 })
              .accessibilityText(this.stateLabel(this.sessionState(session.id)))
          }
        }.width('100%').height('100%')
      }.id(`session-${session.id}`).layoutWeight(1)
        .height(this.compactSessionPane && (session.id === this.openingSessionId || this.sessionRunning(session.id)) ? 54 : 46)
        .padding({ left: this.compactSessionPane ? (nested ? 16 : 6) : (nested ? 40 : 12), right: 2 })
        .backgroundColor(Color.Transparent).enabled(!this.busy && (this.reachable || session.id === this.currentId))
        .accessibilitySelected(session.id === this.currentId)
        .onClick(() => {
          if (this.openingSession) return;
          this.$activeTab('tasks'); this.$showSettings(false); this.$showFiles(false);
          if (session.id === this.currentId) this.setDrawer(false);
          else void this.requestAction('/open', { id: session.id, agent: session.agent });
        })
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ic_more')).width(16).height(16).fillColor($r('app.color.pigo_muted'))
      }.id(`session-more-${session.id}`).width(this.compactSessionPane ? 36 : 32).height(40).padding(0)
        .backgroundColor(Color.Transparent)
        .accessibilityText('任务操作').enabled((this.reachable || session.id === this.currentId) && !this.busy)
        .bindMenu(this.sessionMoreOptions(session))
    }.width('100%').borderRadius(this.dockedSessions ? 9 : 12)
      .backgroundColor(session.id === this.openingSessionId || (session.id === this.currentId && this.dockedSessions) ?
        this.accentTint : session.id === this.currentId ? $r('app.color.pigo_selected') : Color.Transparent)
  }
  @Builder
  spaceMenu(path: string, epoch: number) {
    Menu() {
      if (this.projects.includes(path)) {
        MenuItem({ content: '移除空间' }).id('space-remove').contentFontColor($r('app.color.pigo_error'))
          .onClick(() => { this.confirmCloseSpace(path, epoch); })
      }
    }
  }
  @Builder
  librarySpace(path: string) {
    Row({ space: 4 }) {
      Row({ space: this.compactSessionPane ? 4 : 9 }) {
        SymbolGlyph($r('sys.symbol.folder')).fontSize(18).fontColor([this.accent])
        Text(workspaceName(this.workspaces, path)).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(this.compactSessionPane ? 12 : 14).fontColor([$r('app.color.pigo_muted')])
          .rotate({ angle: this.expandedSpaces.includes(path) ? 0 : -90 })
      }.id(`space-${path}`).layoutWeight(1).height(44).onClick(() => { this.toggleSpace(path); })
        .bindContextMenu(this.spaceMenu(path, this.connectionEpoch()), ResponseType.LongPress, { placement: Placement.BottomLeft })
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(16).fontColor([$r('app.color.pigo_muted')])
      }.id(`space-new-task-${path}`).width(40).height(44).padding(0).borderRadius(10)
        .backgroundColor(Color.Transparent)
        .accessibilityText(`在${workspaceName(this.workspaces, path)}空间新建任务`)
        .visibility(this.projects.includes(path) ? Visibility.Visible : Visibility.Hidden)
        .enabled(this.reachable && this.hostAvailable && !this.busy && !this.openingSession && this.projects.includes(path))
        .onClick(() => { this.openNewSession(path); })
    }.width('100%').padding({ left: this.compactSessionPane ? 4 : 8 })
  }
  @Builder
  sessionLibrary() {
    Refresh({ refreshing: this.refreshing!! }) {
      List({ scroller: this.library, space: 5 }) {
        if (!this.sessionLoading && !this.sessionCatalogFailed && this.loadedView === this.sessionView &&
          (this.sessionView === 'all' ? this.projects.length === 0 : this.sessions.length === 0)) {
          ListItem() {
            Text(this.reachable ? (this.sessionView === 'all' ? '暂无空间' : '暂无任务') : '连接电脑后加载任务')
              .fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%').padding(this.compactSessionPane ? 6 : 16)
          }
        }
        LazyForEach(this.sidebarRows, (row: SidebarRow) => {
          ListItem() {
            if (row.path !== undefined) {
              this.librarySpace(row.path)
            } else if (row.session !== undefined) {
              this.taskRow(row.session, row.nested)
            } else if (row.more !== undefined) {
              Button(row.label ?? '加载更多').fontSize(13).width('100%')
                .backgroundColor(Color.Transparent).fontColor(this.accent)
                .enabled(this.reachable && !this.busy && !this.openingSession && !this.sessionLoading)
                .onClick(() => { this.loadMoreSessions(row.more ?? ''); })
            } else if (row.label !== undefined) {
              Text(row.label).fontSize(13).fontColor($r('app.color.pigo_muted')).padding({ left: 18, top: 6, bottom: 6 })
            }
          }
        }, (row: SidebarRow): string => row.key)
      }.cachedCount(4).width('100%').height('100%').scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .padding({ bottom: 20 })
        .onAreaChange(() => { this.revealLibraryAnchor(); })
    }
    .layoutWeight(1).width('100%')
    .pullToRefresh(this.reachable && !this.busy && !this.openingSession && !this.sessionLoading)
    .onRefreshing(() => { void this.refreshLibrary(); })
  }

  private async refreshLibrary(): Promise<void> {
    try {
      await this.refreshSessions();
    } finally {
      this.refreshing = false;
    }
  }
  private sessionMoreOptions(session: SessionRow): MenuElement[] {
    const options: MenuElement[] = [
      { value: '分享会话', action: () => { void this.shareSession(session); } }
    ];
    if (this.reachable) {
      options.push({ value: session.pinned ? '取消置顶' : '置顶', action: () => { void this.updateSessionMeta(session, true); } });
      if (!session.nativeArchived) {
        options.push({ value: session.archived ? '取消归档' : '归档', action: () => { void this.updateSessionMeta(session, false); } });
      }
    }
    return options;
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
  private sessionState(id: string): string {
    if (!this.reachable) return '';
    if (id === this.currentId) {
      if (this.interaction) return 'waiting';
      if (this.queued) return 'queued';
      return this.idle ? '' : 'streaming';
    }
    const row = this.runningSessions.find((item: RunningRow): boolean => item.id === id);
    if (row?.state) return row.state;
    return this.runningSessionIds.includes(id) ? 'streaming' : '';
  }
  private sessionRunning(id: string): boolean {
    return this.reachable && (id === this.currentId ? !this.idle || this.queued : this.runningSessionIds.includes(id));
  }

  private sessionViewLabel(view: string): string {
    return view === 'all' ? '工作区' : view === 'pinned' ? '置顶' : view === 'recent' ? '最近' : '归档';
  }
}
