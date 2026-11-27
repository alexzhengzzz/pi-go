import { PiGoPageStore } from '../model/PiGoPageStore';
import { glassCardSurface, glassDrawerSurface, immersiveSurface } from '../Immersive';
import { headerSymbol } from './HeaderSymbol';
import { SIDEBAR_VIEWS, workspaceName } from '../model/SessionStore';
import { SessionRow, SidebarRow, PendingInteraction, RunningRow, WorkspaceRow } from '../model/PiGoTypes';
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
  @Param @Require store: PiGoPageStore;
  @Local private refreshing: boolean = false;

  @Builder
  sidebarHeader() {
    Row({ space: this.store.compactSessionPane() ? 6 : 10 }) {
      if (this.store.dockedSessions()) {
        Stack() {
          SymbolGlyph($r('sys.symbol.computer')).fontSize(19).fontColor([this.store.accent()])
        }.width(34).height(34).borderRadius(10).backgroundColor(this.store.accentTint())
      }
      Row({ space: 8 }) {
        if (!this.store.dockedSessions()) {
          SymbolGlyph($r('sys.symbol.computer')).fontSize(21).fontColor([this.store.accent()])
        }
        Text(this.store.computerTitle()).fontSize(this.store.compactSessionPane() ? 14 : this.store.dockedSessions() ? 17 : 19)
          .fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.layoutWeight(1).height(44)
      if (!this.store.dockedSessions()) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.xmark'), $r('app.color.pigo_text'), 17)
        }.width(40).height(40).padding(0).borderRadius(20).backgroundColor(Color.Transparent)
          .attributeModifier(immersiveSurface(this.store.darkMode))
          .accessibilityText('关闭会话抽屉')
          .onClick(() => { this.store.setDrawer(false); })
      }
    }.width('100%').padding({
      left: this.store.compactSessionPane() ? 10 : 18,
      right: 12,
      top: this.store.statusBarHeight + (this.store.compactSessionPane() ? 8 : 10),
      bottom: 8
    })
  }

  build() {
    Navigation() {
      Column({ space: !this.store.dockedSessions() || this.store.compactSessionPane() || this.store.windowHeight < SHORT_WINDOW_HEIGHT ? 8 : 12 }) {
        if (this.store.dockedSessions()) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: this.store.compactSessionPane() ? 6 : 8 }) {
              SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18).fontColor([this.store.accentForeground()])
              Text('新建会话').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.store.accentForeground()).maxLines(1)
            }.justifyContent(FlexAlign.Center).width('100%')
          }.id('drawer-new-task').width('100%').height(44).padding(0).borderRadius(14)
            .backgroundColor(this.store.accent())
            .enabled(this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession && this.store.hostAvailable &&
              (this.store.projects.length > 0 || this.store.canCreateWorkspace))
            .onClick(() => { this.store.openNewSession(); })
        } else {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18).fontColor([this.store.accent()])
              Text('新建会话').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).maxLines(1)
            }.justifyContent(FlexAlign.Center).width('100%')
          }.id('drawer-new-task').width('100%').height(44).padding(0)
            .attributeModifier(glassCardSurface(this.store.darkMode, 14))
            .enabled(this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession && this.store.hostAvailable &&
              (this.store.projects.length > 0 || this.store.canCreateWorkspace))
            .onClick(() => { this.store.openNewSession(); })
        }
        if (!this.store.session.reachable) this.offlineNotice(true, this.store.compactSessionPane())
        Row({ space: 4 }) {
          ForEach(SIDEBAR_VIEWS, (view: string) => {
            Button({ type: ButtonType.Normal }) {
              Text(this.store.sessionViewLabel(view))
                .fontSize(13).fontColor(this.store.sessionView === view ? this.store.accentForeground() : $r('app.color.pigo_muted')).maxLines(1)
                .fontWeight(this.store.sessionView === view ? FontWeight.Medium : FontWeight.Regular)
            }.id(`session-view-${view}`).layoutWeight(1)
              .height(34).padding(0).borderRadius(10)
              .backgroundColor(this.store.sessionView === view ? this.store.accent() : Color.Transparent)
              .accessibilitySelected(this.store.sessionView === view).enabled(!this.store.session.busy && !this.store.sessionLoading && this.store.session.reachable)
              .onClick(() => { this.store.selectSessionView(view); })
          }, (view: string) => view)
        }.width('100%').padding(4).attributeModifier(glassCardSurface(this.store.darkMode, 14))
        if (this.store.sessionLoading && (!this.store.sessionCatalogLoaded || this.store.loadedView !== this.store.sessionView)) {
          Text('正在加载任务…').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
        } else if (this.store.sessionCatalogFailed) {
          Button('任务加载失败，重试').chatAction().id('session-retry').width('100%').height(38)
            .enabled(this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession).onClick(() => { void (() => this.store.session.reachable ? this.store.loadSessions(false, true) : Promise.resolve())(); })
        }
        this.sessionLibrary()
        Row({ space: 6 }) {
          Blank().width(6).height(6).borderRadius(3)
            .backgroundColor(this.store.session.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
          Text(this.store.base.split('://')[1] || '').id('active-computer').fontSize(11).fontColor($r('app.color.pigo_muted'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').padding({ left: this.store.compactSessionPane() ? 4 : 10 })
      }.width('100%').height('100%')
        .padding({
          left: this.store.compactSessionPane() ? 8 : 12,
          right: 12,
          top: this.store.statusBarHeight + (this.store.compactSessionPane() ? 58 : 64),
          bottom: this.store.bottomPad() + 18
        })
    }.id('session-sidebar').width(this.store.dockedSessions() ? this.store.sessionPaneWidth() : this.store.drawerWidth()).height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .title({ builder: this.sidebarHeader, height: 52 + this.store.statusBarHeight + 12 }, {
        backgroundColor: Color.Transparent,
        barStyle: BarStyle.STACK
      })
      .attributeModifier(glassDrawerSurface(this.store.darkMode, this.store.dockedSessions()))
      .transition(TransitionEffect.move(TransitionEdge.START))
      .onGestureJudgeBegin(() => this.store.dockedSessions() ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
      .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.store.swipeDrawer(event); }))
      .onAppear(() => { this.store.onSidebarAppear(); })
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
      if (compact) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16).fontColor([$r('app.color.pigo_warning')])
        }.id('drawer-retry').width(36).height(34).padding(0).borderRadius(10)
          .backgroundColor(Color.Transparent).enabled(!this.store.session.busy)
          .accessibilityText('重试连接')
          .onClick(() => { this.store.offlineDismissed = false; this.store.streamSync.schedule(0); })
      } else {
        Button('重试').chatAction().id('offline-retry')
          .height(34).fontSize(13).enabled(!this.store.session.busy)
          .accessibilityText('重试连接')
          .onClick(() => { this.store.offlineDismissed = false; this.store.streamSync.schedule(0); })
      }
      if (!compact) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
        }.width(34).height(34).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
          .accessibilityText('关闭离线提示').onClick(() => { this.store.offlineDismissed = true; })
      }
    }.width('100%').padding(narrow ? 8 : compact ? 10 : 14).borderRadius(compact ? 12 : 16)
      .backgroundColor(compact ? $r('app.color.pigo_warning_panel') : $r('app.color.pigo_panel'))
      .border({ width: compact ? 0 : 1, color: $r('app.color.pigo_line') })
  }
  @Builder
  taskRow(session: SessionRow, nested: boolean) {
    Row({ space: 0 }) {
      Button({ type: ButtonType.Normal }) {
        Flex({ direction: this.store.compactSessionPane() ? FlexDirection.Column : FlexDirection.Row,
          justifyContent: this.store.compactSessionPane() ? FlexAlign.Center : FlexAlign.Start,
          alignItems: this.store.compactSessionPane() ? ItemAlign.Start : ItemAlign.Center }) {
          if (this.store.compactSessionPane()) {
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
              .fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.store.accent())
              .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6)
              .backgroundColor(this.store.accentTint())
              .margin({ left: this.store.compactSessionPane() ? 0 : 6, top: this.store.compactSessionPane() ? 2 : 0 })
          }
          if (session.id === this.store.session.openingSessionId) {
            Text('正在打开…').id('session-opening').fontSize(11).fontColor(this.store.accent()).maxLines(1)
              .margin({ left: this.store.compactSessionPane() ? 0 : 8, top: this.store.compactSessionPane() ? 2 : 0 })
          } else if (session.id === this.store.split.state.otherId) {
            Text('分屏').fontSize(11).fontColor(this.store.accent())
              .margin({ left: this.store.compactSessionPane() ? 0 : 8, top: this.store.compactSessionPane() ? 2 : 0 })
          } else if (this.sessionRunning(session.id)) {
            Row({ space: 4 }) {
              Text('').width(6).height(6).borderRadius(3)
                .backgroundColor(this.stateColor(this.sessionState(session.id)))
              Text(this.stateLabel(this.sessionState(session.id))).fontSize(11)
                .fontColor(this.stateColor(this.sessionState(session.id)))
            }.margin({ left: this.store.compactSessionPane() ? 0 : 8, top: this.store.compactSessionPane() ? 2 : 0 })
              .accessibilityText(this.stateLabel(this.sessionState(session.id)))
          }
        }.width('100%').height('100%')
      }.id(`session-${session.id}`).layoutWeight(1)
        .height(this.store.compactSessionPane() && (session.id === this.store.session.openingSessionId || session.id === this.store.split.state.otherId || this.sessionRunning(session.id)) ? 54 : 46)
        .padding({ left: this.store.compactSessionPane() ? (nested ? 16 : 6) : (nested ? 40 : 12), right: 2 })
        .backgroundColor(Color.Transparent).enabled(!this.store.session.busy && (this.store.session.reachable || session.id === this.store.session.currentId))
        .accessibilitySelected(session.id === this.store.session.currentId)
        .onClick(() => {
          if (this.store.session.openingSession) return;
          ((row: SessionRow): void => this.store.split.openSidebarSession(row, false))(session);
        })
        .bindContextMenu(this.sessionContextMenu(session), ResponseType.LongPress, { placement: Placement.BottomLeft })
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ic_more')).width(16).height(16).fillColor($r('app.color.pigo_muted'))
      }.id(`session-more-${session.id}`).width(this.store.compactSessionPane() ? 36 : 32).height(40).padding(0)
        .backgroundColor(Color.Transparent)
        .accessibilityText('任务操作').enabled((this.store.session.reachable || session.id === this.store.session.currentId) && !this.store.session.busy)
        .bindMenu(this.sessionMoreOptions(session))
    }.width('100%').borderRadius(this.store.dockedSessions() ? 9 : 12)
      .backgroundColor(session.id === this.store.session.openingSessionId || (session.id === this.store.session.currentId && this.store.dockedSessions()) ?
        this.store.accentTint() : session.id === this.store.session.currentId ? $r('app.color.pigo_selected') : Color.Transparent)
  }
  @Builder
  spaceMenu(path: string, epoch: number) {
    Menu() {
      if (this.store.projects.includes(path)) {
        MenuItem({ content: '移除空间' }).id('space-remove').contentFontColor($r('app.color.pigo_error'))
          .onClick(() => { this.store.confirmCloseSpace(path, epoch); })
      }
    }
  }
  @Builder
  librarySpace(path: string) {
    Row({ space: 4 }) {
      Row({ space: this.store.compactSessionPane() ? 4 : 9 }) {
        SymbolGlyph($r('sys.symbol.folder')).fontSize(18).fontColor([this.store.accent()])
        Text(workspaceName(this.store.workspaces, path)).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(this.store.compactSessionPane() ? 12 : 14).fontColor([$r('app.color.pigo_muted')])
          .rotate({ angle: this.store.expandedSpaces.includes(path) ? 0 : -90 })
      }.id(`space-${path}`).layoutWeight(1).height(44).onClick(() => { this.store.toggleSpace(path); })
        .bindContextMenu(this.spaceMenu(path, (() => this.store.session.epoch)()), ResponseType.LongPress, { placement: Placement.BottomLeft })
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(16).fontColor([$r('app.color.pigo_muted')])
      }.id(`space-new-task-${path}`).width(40).height(44).padding(0).borderRadius(10)
        .backgroundColor(Color.Transparent)
        .accessibilityText(`在${workspaceName(this.store.workspaces, path)}空间新建任务`)
        .visibility(this.store.projects.includes(path) ? Visibility.Visible : Visibility.Hidden)
        .enabled(this.store.session.reachable && this.store.hostAvailable && !this.store.session.busy && !this.store.session.openingSession && this.store.projects.includes(path))
        .onClick(() => { this.store.openNewSession(path); })
    }.width('100%').padding({ left: this.store.compactSessionPane() ? 4 : 8 })
  }
  @Builder
  sessionLibrary() {
    Refresh({ refreshing: this.refreshing!! }) {
      List({ scroller: this.store.library, space: 5 }) {
        if (!this.store.sessionLoading && !this.store.sessionCatalogFailed && this.store.loadedView === this.store.sessionView &&
          (this.store.sessionView === 'all' ? this.store.projects.length === 0 : this.store.sessions.length === 0)) {
          ListItem() {
            Text(this.store.session.reachable ? (this.store.sessionView === 'all' ? '暂无空间' : '暂无任务') : '连接电脑后加载任务')
              .fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%').padding(this.store.compactSessionPane() ? 6 : 16)
          }
        }
        LazyForEach(this.store.sidebarRows, (row: SidebarRow) => {
          ListItem() {
            if (row.path !== undefined) {
              this.librarySpace(row.path)
            } else if (row.session !== undefined) {
              this.taskRow(row.session, row.nested)
            } else if (row.more !== undefined) {
              Button(row.label ?? '加载更多').fontSize(13).width('100%')
                .backgroundColor(Color.Transparent).fontColor(this.store.accent())
                .enabled(this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession && !this.store.sessionLoading)
                .onClick(() => { this.store.loadMoreSidebarSessions(row.more ?? ''); })
            } else if (row.label !== undefined) {
              Text(row.label).fontSize(13).fontColor($r('app.color.pigo_muted')).padding({ left: 18, top: 6, bottom: 6 })
            }
          }
        }, (row: SidebarRow): string => row.key)
      }.cachedCount(4).width('100%').height('100%').scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .padding({ bottom: 20 })
        .onAreaChange(() => { this.store.revealLibraryAnchor(); })
    }
    .layoutWeight(1).width('100%')
    .pullToRefresh(this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession && !this.store.sessionLoading)
    .onRefreshing(() => { void this.refreshLibrary(); })
  }

  private async refreshLibrary(): Promise<void> {
    try {
      await (() => this.store.session.reachable ? this.store.loadSessions(false, true) : Promise.resolve())();
    } finally {
      this.refreshing = false;
    }
  }
  @Builder
  sessionContextMenu(session: SessionRow) {
    Menu() {
      MenuItem({ content: '在分屏中打开' }).id('open-session-split')
        .enabled(this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession)
        .onClick(() => { ((row: SessionRow): void => this.store.split.openSidebarSession(row, true))(session); })
      MenuItem({ content: '在系统分屏中打开' }).id('open-session-system-split')
        .enabled(this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession)
        .onClick(() => { ((row: SessionRow): void => { void this.store.split.openInSystemSplit(row); })(session); })
    }
  }

  private sessionMoreOptions(session: SessionRow): MenuElement[] {
    const options: MenuElement[] = [
      { value: '在分屏中打开', enabled: this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession,
        action: () => { ((row: SessionRow): void => this.store.split.openSidebarSession(row, true))(session); } },
      { value: '在系统分屏中打开', enabled: this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession,
        action: () => { ((row: SessionRow): void => { void this.store.split.openInSystemSplit(row); })(session); } },
      { value: '分享会话', action: () => { void this.store.shareController.shareSidebarSession(session); } }
    ];
    if (this.store.session.reachable && !session.nativeArchived) {
      options.push({ value: session.archived ? '取消归档' : '归档', action: () => { void this.store.toggleSessionArchive(session); } });
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
    if (!this.store.session.reachable) return '';
    if (id === this.store.session.currentId) {
      if (this.store.session.interaction) return 'waiting';
      if (this.store.session.queued) return 'queued';
      return this.store.session.idle ? '' : 'streaming';
    }
    const row = this.store.runningSessions.find((item: RunningRow): boolean => item.id === id);
    if (row?.state) return row.state;
    return this.store.runningSessionIds.includes(id) ? 'streaming' : '';
  }
  private sessionRunning(id: string): boolean {
    return this.store.session.reachable && (id === this.store.session.currentId ? !this.store.session.idle || this.store.session.queued : this.store.runningSessionIds.includes(id));
  }
}
