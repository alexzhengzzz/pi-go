import { UIContext } from '@kit.ArkUI';
import { windowAppUiState } from '../AppUiState';
import { canvasFadeStops, themeStyle } from '../Appearance';
import { ChatContent } from '../ChatContent';
import { ChatImage } from '../ChatImage';
import { markdownWorkspacePath } from '../ChatPaths';
import { glassCardSurface, hasImmersiveMaterial, immersiveFloatingTabs, immersiveSheetMaterial, immersiveSurface } from '../Immersive';
import { DiffLine, RunEvent, RunFile, RunScreenshot } from '../RunResults';
import { RunMessage, ScheduleJob } from '../ScheduledRuns';
import { ChatComposer } from '../components/ChatComposer';
import { IncomingShareBanner, NewSessionDialog, NewSpaceDialog, PendingInteractionCard, ToolDetailsSheet } from '../components/ChatDialogs';
import { CommandPaletteCard, VoiceFeedbackOverlay } from '../components/ChatSubViews';
import { ChatTranscript } from '../components/ChatTranscript';
import { MarkdownTableReaderPage, TextFilePreviewPage, WorkspaceFileEditor } from '../components/FilePreviewPages';
import { headerSymbol } from '../components/HeaderSymbol';
import { InboxFeedPanel } from '../components/InboxFeedPanel';
import { bannerTransition, drawerSlideTransition, modalFadeTransition, pagePushTransition, subPageTransition } from '../components/PageTransitions';
import { RunResultView } from '../components/RunResultView';
import { ScheduleOverlay } from '../components/ScheduleOverlay';
import { OfflineNotice, RunCompletionBanner, RunningSessionStrip, ScheduledRunBanner, SessionSettings } from '../components/SessionOverlays';
import { SessionSidebar } from '../components/SessionSidebar';
import { SettingsView } from '../components/SettingsView';
import { TaskPanel } from '../components/TaskPanel';
import { SakuraGirlHitZone, ThemeBackdrop } from '../components/ThemeBackdrop';
import { WorkspaceFiles } from '../components/WorkspaceFiles';
import { SHORT_WINDOW_HEIGHT } from '../model/PiGoConstants';
import { PiGoPageStore } from '../model/PiGoPageStore';
import { BridgeReply, ChatMessage, CommandRow, LiveTool, Payload, ReceivedFilePreview } from '../model/PiGoTypes';
import { SessionViewState } from '../model/StreamSyncController';
import { panePath } from '../model/WindowConversation';

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
struct RootTabBarItem {
  @Param @Require store: PiGoPageStore;
  @Param @Require tab: string;

  @Computed
  get badgeCount(): number {
    if (this.tab === 'inbox') return this.store.inboxBadgeCount();
    return 0;
  }

  build() {
    Column({ space: 3 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Row() {
          SymbolGlyph(this.store.tabSymbol(this.tab, this.store.activeTab === this.tab)).fontSize(23)
            .fontColor([this.store.activeTab === this.tab ? this.store.accent() : $r('app.color.pigo_muted')])
            .accessibilityLevel('no')
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
        if (this.badgeCount > 0) {
          Text(this.badgeCount > 9 ? '9+' : `${this.badgeCount}`)
            .fontSize(9).fontWeight(FontWeight.Medium).fontColor(this.store.accentForeground())
            .textAlign(TextAlign.Center).constraintSize({ minWidth: 14 }).height(14)
            .padding({ left: 2, right: 2 }).backgroundColor(this.store.accent()).borderRadius(7)
        }
      }.width(48).height(25)
      Text(this.tab === 'inbox' ? '动态' : this.tab === 'tasks' ? '会话' : this.tab === 'pending' ? '自动化' : '我的')
        .fontSize(11).fontWeight(this.store.activeTab === this.tab ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.store.activeTab === this.tab ? this.store.accent() : $r('app.color.pigo_muted'))
    }.id(`tab-${this.tab}`).width('100%').height('100%').justifyContent(FlexAlign.Center)
      .accessibilitySelected(this.store.activeTab === this.tab)
  }
}

@Entry
@ComponentV2
struct Index {
  @Local private store: PiGoPageStore = new PiGoPageStore(windowAppUiState());

  onBackPress(): boolean { return this.store.onBackPress(); }

  aboutToAppear(): void {
    this.store.attachUIContext((): UIContext => this.getUIContext());
    this.store.aboutToAppear();
  }

  onPageShow(): void { this.store.onPageShow(); }
  onPageHide(): void { this.store.onPageHide(); }
  aboutToDisappear(): void { this.store.aboutToDisappear(); }

  @SyncMonitor('store.appState.launchTicket')
  private onLaunchTicket(): void { this.store.onLaunchTicket(); }

  @SyncMonitor('store.appState.liveLaunchSession')
  private onLiveActivityLaunch(): void { this.store.onLiveActivityLaunch(); }

  @SyncMonitor('store.session.currentId')
  private onRunSessionChanged(): void { this.store.onRunSessionChanged(); }

  @SyncMonitor('store.appState.pushLaunchEvent')
  private onPushLaunch(): void { this.store.onPushLaunch(); }

  @SyncMonitor('store.appState.inboxFormLaunch')
  private onInboxFormLaunch(): void { this.store.onInboxFormLaunch(); }

  @SyncMonitor('store.appState.incomingShare')
  private onIncomingShare(): void { this.store.onIncomingShare(); }

  @SyncMonitor('store.appState.keyboardHeight')
  private onKeyboardChange(): void { this.store.onKeyboardChange(); }

  @SyncMonitor('store.appState.windowWidth')
  private onWindowWidthChange(): void { this.store.onWindowWidthChange(); }

  @SyncMonitor('store.appState.keyboardHeight', 'store.appState.windowWidth', 'store.appState.windowHeight')
  private onSplitViewportChange(): void { this.store.onSplitViewportChange(); }

  @SyncMonitor('store.session.currentId')
  private onFocusedSessionChange(): void { this.store.onFocusedSessionChange(); }

  @SyncMonitor('store.sessions', 'store.expandedSpaces', 'store.sessionView', 'store.loadedView', 'store.projects', 'store.workspaces', 'store.workspacePages', 'store.sessionNextCursor')
  private updateSidebarRows(): void { this.store.updateSidebarRows(); }

  @Builder
  richChatText(text: string, cwd: string, documentPath: string = '', allowLandscape: boolean = true) {
    ChatContent({
      text: text,
      accent: this.store.accent(),
      codeBg: this.store.palette().codeBg,
      codeBorder: this.store.palette().codeBorder,
      codeHeaderBg: this.store.palette().codeHeaderBg,
      codeRadius: themeStyle(this.store.themeId).codeRadius,
      allowLandscape: allowLandscape,
      loadImage: (target: string): Promise<string> => this.store.fileController.loadMarkdownImage(target, cwd, documentPath),
      openImage: (source: string, label: string): void => { this.store.fileController.showChatImage(source, label); },
      openLink: (target: string): void => {
        if (!allowLandscape && markdownWorkspacePath(target, cwd, documentPath)) this.store.fileController.closeMarkdownTableReader();
        void this.store.fileController.openMarkdownLink(target, cwd, documentPath);
      },
      openLandscape: (source: string): void => { this.store.fileController.openMarkdownTableReader(source, cwd, documentPath); },
      copyCode: (value: string): void => { void this.store.copyText(value); }
    })
  }

  @Builder
  historyImages(count: number, sessionId: string, messageId: string, toolId: string = '') {
    ForEach(Array.from({ length: count }, (_: Object, index: number): number => index), (index: number) => {
      ChatImage({
        label: count === 1 ? '图片' : `图片 ${index + 1}`,
        load: (): Promise<string> => this.store.fileController.loadHistoryImage(sessionId, messageId, index, toolId),
        open: (source: string, label: string): void => { this.store.fileController.showChatImage(source, label); }
      })
    }, (index: number): string => `${sessionId}-${messageId}-${toolId}-${index}`)
  }

  @Builder
  mineHeader() {
    Row({ space: 12 }) {
      if (this.store.minePage) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().attributeModifier(immersiveSurface(this.store.darkMode))
          .accessibilityText('返回').enabled(!this.store.session.busy).onClick(() => { this.store.mineBack(); })
      } else if (this.store.isPaired && !this.store.dockedSessions()) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.line_2_horizontal'), $r('app.color.pigo_text'), 20)
        }.id('mine-history').headerAction().attributeModifier(immersiveSurface(this.store.darkMode))
          .accessibilityText('打开会话抽屉').enabled(!this.store.session.busy)
          .onClick(() => { this.store.setDrawer(true); })
      }
      Text(this.store.minePage === 'theme' ? '系统主题' : this.store.minePage === 'computers' ?
        (this.store.addingComputer ? (this.store.pairingComputerId ? '添加连接' : '添加电脑') : '电脑管理') :
        this.store.minePage === 'notifications' ? '通知' : '我的')
        .fontSize(this.store.minePage ? 20 : 26).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).layoutWeight(1)
    }.width('100%').height(this.store.headerHeight())
  }

  @Builder
  inboxHeader() {
    Row({ space: 12 }) {
      if (this.store.isPaired && !this.store.dockedSessions()) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.line_2_horizontal'), $r('app.color.pigo_text'), 20)
        }.id('inbox-history').headerAction().attributeModifier(immersiveSurface(this.store.darkMode))
          .accessibilityText('打开会话抽屉').enabled(!this.store.session.busy)
          .onClick(() => { this.store.setDrawer(true); })
      }
      Column({ space: 2 }) {
        Text('动态').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
        if (this.store.isPaired) {
          Text(this.store.inboxBadgeCount() > 0 ? `${this.store.inboxBadgeCount()} 条未读 · 下拉可刷新` : '全部已读 · 下拉可刷新')
            .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.store.isPaired) {
        Button({ type: ButtonType.Normal }) {
          Stack() {
            Image($r('app.media.ic_more')).width(20).height(20).fillColor($r('app.color.pigo_text'))
          }.width('100%').height('100%').accessibilityLevel('no-hide-descendants')
        }.id('inbox-more').headerAction().attributeModifier(immersiveSurface(this.store.darkMode))
          .accessibilityText('动态操作菜单').enabled(!this.store.session.busy)
          .bindMenu(this.store.inboxHeaderMenu())
      }
    }.width('100%').height(this.store.headerHeight())
  }

  @Builder
  inboxView() {
    InboxFeedPanel({ store: this.store })
  }

  @Builder
  automationHeader() {
    Row({ space: 12 }) {
      if (this.store.isPaired && !this.store.dockedSessions()) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.line_2_horizontal'), $r('app.color.pigo_text'), 20)
        }.id('automation-history').headerAction().attributeModifier(immersiveSurface(this.store.darkMode))
          .accessibilityText('打开会话抽屉').enabled(!this.store.session.busy)
          .onClick(() => { this.store.setDrawer(true); })
      }
      Column({ space: 2 }) {
        Text('自动化').fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
        Text('定时任务与本机提醒源').fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.store.isPaired) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.arrow_clockwise'), $r('app.color.pigo_text'), 19)
        }.id('schedule-refresh').headerAction().attributeModifier(immersiveSurface(this.store.darkMode))
          .accessibilityText('刷新自动化').enabled(!this.store.scheduleController.state.scheduleSaving)
          .onClick(() => {
            void this.store.scheduleController.loadScheduleJobs();
            this.store.runCenter.queueRunSync(0);
          })
      }
    }.width('100%').height(this.store.headerHeight())
  }

  @Builder
  mineView() {
    SettingsView({ store: this.store, active: this.store.visible && this.store.activeTab === 'mine' })
  }

  @Builder
  workspaceFiles() {
    WorkspaceFiles({
      bottomContentClearance: this.store.bottomContentClearance(),
      busy: this.store.session.busy,
      fileRoot: this.store.fileController.state.fileRoot,
      fileTreeIndex: this.store.fileController.state.fileTreeIndex,
      fileTreeRows: this.store.fileController.state.fileTreeRows,
      loadFileDirectory: (path: string, more?: boolean): Promise<void> => this.store.fileController.loadFileDirectory(path, more),
      openFile: (cwd: string, path: string, lookupName?: boolean): Promise<void> => this.store.fileController.openFile(cwd, path, lookupName),
      openingSession: this.store.session.openingSession,
      project: this.store.session.project,
      toggleFileDirectory: (path: string): Promise<void> => this.store.fileController.toggleFileDirectory(path),
      topContentClearance: this.store.topContentClearance(),
      accent: this.store.accent(),
      setFileTreeIndex: (index: number): void => { this.store.fileController.state.fileTreeIndex = index; }
    })
  }

  @Builder
  toolDetailImages() {
    if (this.store.toolCmd.state.selectedTool && this.store.toolCmd.state.selectedToolDetails?.imageCount) {
      this.historyImages(this.store.toolCmd.state.selectedToolDetails.imageCount, this.store.session.currentId, this.store.toolCmd.selectedToolMessageId, this.store.toolCmd.state.selectedTool.id)
    }
  }

  @Builder
  toolDetailsSheet() {
    ToolDetailsSheet({
      selectedTool: this.store.toolCmd.state.selectedTool,
      selectedToolDetails: this.store.toolCmd.state.selectedToolDetails,
      idle: this.store.session.idle,
      toolDetailError: this.store.toolCmd.state.toolDetailError,
      accent: this.store.accent(),
      icon: this.store.toolCmd.state.selectedTool ? this.store.toolCmd.toolIcon(this.store.toolCmd.state.selectedTool) : $r('sys.symbol.doc'),
      path: this.store.toolCmd.state.selectedTool ? this.store.toolCmd.toolFile(this.store.toolCmd.state.selectedTool) : '',
      openingFile: this.store.fileController.state.openingFile,
      openFile: (path: string): Promise<void> => this.store.fileController.openReferencedFile(this.store.session.workspaceCwd, path, false),
      copyText: (value: string): Promise<void> => this.store.copyText(value),
      loadToolDetails: (): Promise<void> => this.store.toolCmd.loadToolDetails(),
      images: (): void => this.toolDetailImages()
    })
  }

  @Builder
  chatHeader() {
    Row({ space: 10 }) {
      if (this.store.showFiles) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().attributeModifier(immersiveSurface(this.store.darkMode)).accessibilityText('返回会话')
          .enabled(!this.store.session.busy && !this.store.session.openingSession)
          .onClick(() => { this.store.fileBack(); })
      } else if (this.store.session.showSettings) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().attributeModifier(immersiveSurface(this.store.darkMode)).accessibilityText('返回会话').onClick(() => { this.store.session.showSettings = false; })
      } else if (!this.store.dockedSessions()) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.line_2_horizontal'), $r('app.color.pigo_text'), 20)
        }.id('history').headerAction().attributeModifier(immersiveSurface(this.store.darkMode))
          .accessibilityText('打开会话抽屉').enabled(!this.store.session.busy)
          .onClick(() => { this.store.setDrawer(true); })
      }
      Column({ space: 3 }) {
        Text(this.store.showFiles ? '工作区文件' : this.store.session.showSettings ? '会话设置' : this.store.activeTab === 'pending' ? '任务' : this.store.split.state.splitOpen ? '分屏会话' : this.store.chatTitle())
          .fontSize(this.store.showFiles || this.store.session.showSettings ? 20 : 18).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (!this.store.session.showSettings) {
          Row({ space: 6 }) {
            Blank().width(7).height(7).borderRadius(4)
              .backgroundColor(this.store.session.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
              .accessibilityText(this.store.session.reachable ? '电脑已连接' : '电脑离线')
            if (this.store.session.currentAgent && (this.store.agents.length > 1 || this.store.session.currentAgent !== 'pi')) {
              Text(this.store.session.currentAgent === 'pi' ? 'Pi' : this.store.session.currentAgent === 'codex' ? 'Codex' : this.store.session.currentAgent === 'agy' ? 'AGY' : this.store.session.currentAgent.toUpperCase())
                .fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.store.accent())
                .padding({ left: 5, right: 5, top: 1, bottom: 1 }).borderRadius(5)
                .backgroundColor(this.store.accentTint())
            }
            Text(this.store.session.reachable ? (this.store.session.project ? `${this.store.session.project} · ${this.store.computerTitle()}` : this.store.computerTitle()) :
              `离线 · ${this.store.computerTitle()}`)
              .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').onClick(() => { if (!this.store.dockedSessions()) this.store.setDrawer(true); })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.store.showFiles) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.arrow_clockwise'), $r('app.color.pigo_text'), 19)
        }.id('file-refresh').headerAction().attributeModifier(immersiveSurface(this.store.darkMode)).accessibilityText('刷新工作区')
          .enabled(!this.store.session.busy && !this.store.session.openingSession && this.store.session.reachable)
          .onClick(() => { void this.store.fileController.loadFileDirectory(''); })
      } else if (!this.store.session.showSettings) {
        Row({ space: 6 }) {
          Button({ type: ButtonType.Normal }) {
            headerSymbol($r('sys.symbol.square_and_pencil'), this.store.accent(), 19)
          }.id('new-task').headerAction().attributeModifier(immersiveSurface(this.store.darkMode)).accessibilityText('新建会话')
            .enabled(this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession && this.store.hostAvailable &&
              !!this.store.session.workspaceCwd && this.store.projects.includes(this.store.session.workspaceCwd))
            .onClick(() => { this.store.openNewSession('', this.store.session.currentAgent); })
          Button({ type: ButtonType.Normal }) {
            Stack() {
              Image($r('app.media.ic_more')).width(20).height(20).fillColor($r('app.color.pigo_text'))
            }.width('100%').height('100%').accessibilityLevel('no-hide-descendants')
          }.id('session-settings').headerAction().attributeModifier(immersiveSurface(this.store.darkMode)).accessibilityText('更多操作')
            .bindMenu(this.store.chatHeaderMenu())
        }
      }
    }.width('100%').height(this.store.headerHeight())
  }

  @Builder
  pageHeader() {
    Column() {
      if (this.store.activeTab === 'mine') {
        this.mineHeader()
      } else if (this.store.activeTab === 'inbox') {
        this.inboxHeader()
      } else if (this.store.activeTab === 'pending') {
        this.automationHeader()
      } else {
        this.chatHeader()
      }
    }.width('100%').padding({ left: 16, right: 16, top: this.store.statusBarHeight + 8, bottom: 12 })
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: canvasFadeStops(this.store.themeCanvas())
      })
  }

  @Builder
  chatTranscript(state: SessionViewState, focused: boolean, inSplit: boolean) {
    ChatTranscript({
      base: this.store.base,
      busy: state.busy,
      closeMarkdownTableReader: (): void => this.store.fileController.closeMarkdownTableReader(),
      copyText: (value: string): Promise<void> => this.store.copyText(value),
      replyActionsEnabled: focused && state.reachable && state.idle && !state.queued && !state.busy && !state.openingSession && !state.pendingSend,
      forkReply: (messageId: string): void => {
        void this.store.sessionActions.requestAction('/fork', { id: state.currentId, messageId: messageId, history: state.syncMode !== 'legacy' });
      },
      regenerateReply: (messageId: string): void => {
        if (this.store.voiceComposer.state.speakingReply === messageId) this.store.voiceComposer.stopReplySpeech();
        void this.store.sessionActions.requestAction('/regenerate', { id: state.currentId, messageId: messageId });
      },
      speakingReply: focused ? this.store.voiceComposer.state.speakingReply : '',
      toggleReplySpeech: (message: ChatMessage): void => {
        if (focused) void this.store.voiceComposer.toggleReplySpeech(message);
        else void this.store.split.focusOtherPane().then((ready: boolean): void => {
          if (ready) void this.store.voiceComposer.toggleReplySpeech(message);
        });
      },
      currentId: state.currentId,
      darkMode: this.store.darkMode,
      dismissKeyboard: (): void => this.store.dismissKeyboard(),
      historyCursor: state.historyCursor,
      idle: state.idle,
      keyboardHeight: this.store.keyboardHeight,
      $liveThinkingOpen: (open: boolean): void => { state.liveThinkingOpen = open; },
      liveText: state.liveText,
      liveThinking: state.liveThinking,
      liveThinkingOpen: state.liveThinkingOpen,
      liveTools: state.liveTools,
      loadHistory: (): Promise<void> => (focused ? this.store.streamSync : this.store.split.otherStream).loadHistory(),
      loadHistoryImage: (sessionId: string, messageId: string, index: number, toolId: string): Promise<string> => focused ? this.store.fileController.loadHistoryImage(sessionId, messageId, index, toolId) :
        this.store.fileController.loadHistoryImage(sessionId, messageId, index, toolId, state.workspaceCwd,
          (path: string): Promise<BridgeReply> => this.store.request(panePath(path, sessionId, state.workspaceCwd))),
      loadMarkdownImage: (target: string, cwd: string, documentPath: string): Promise<string> => this.store.fileController.loadMarkdownImage(target, cwd, documentPath),
      loadingMessageText: state.loadingMessageText,
      messages: state.messages,
      runResults: focused && this.store.runCenter.state.sessionRunKey === this.store.streamSync.draftKey(state.currentId) ? this.store.runCenter.state.sessionRuns : [],
      openRunResult: (run: RunEvent): void => this.store.runCenter.openRunResult(run),
      openMarkdownLink: (target: string, cwd: string, documentPath: string): Promise<void> => this.store.fileController.openMarkdownLink(target, cwd, documentPath),
      openMarkdownTableReader: (source: string, cwd: string, documentPath: string): void => this.store.fileController.openMarkdownTableReader(source, cwd, documentPath),
      openReferencedFile: (cwd: string, path: string, lookupName: boolean): Promise<void> => this.store.fileController.openReferencedFile(cwd, path, lookupName),
      openToolDetails: (tool: LiveTool, messageId: string): void => {
        if (focused) this.store.toolCmd.openToolDetails(tool, messageId);
        else void this.store.split.focusOtherPane().then((ready: boolean): void => {
          if (ready) this.store.toolCmd.openToolDetails(tool, messageId);
        });
      },
      openingFile: this.store.fileController.state.openingFile,
      positionTranscript: (id: string, contentHeight: number): void => {
        if (focused) this.store.positionTranscript(id, contentHeight);
        else this.store.split.positionOtherTranscript(id, contentHeight);
      },
      queuedSteering: state.queuedSteering,
      optimisticMessages: state.optimisticMessages,
      reachable: state.reachable,
      showChatImage: (source: string, label: string): void => this.store.fileController.showChatImage(source, label),
      showFullReply: (messageId: string): Promise<void> => (focused ? this.store.streamSync : this.store.split.otherStream).showFullReply(messageId),
      thinkingOpenIds: state.thinkingOpenIds,
      toggleThinking: (id: string, open: boolean): void => this.store.toggleThinking(id, open, state),
      transcript: focused ? this.store.transcript : this.store.split.otherTranscript,
      transcriptFollow: state.transcriptFollow,
      $transcriptFollow: (follow: boolean): void => { state.transcriptFollow = follow; },
      workspaceCwd: state.workspaceCwd,
      emptyTranscript: inSplit ? this.emptySplitTranscript.bind(this) : this.emptyTranscript.bind(this),
      accent: this.store.accent(),
      accentTint: this.store.accentTint(),
      themeId: this.store.themeId,
      topPadding: inSplit || this.store.chatHasTopCards() ? 10 : this.store.topContentClearance(),
      bottomPadding: inSplit ? 10 : this.store.chatBottomClearance(),
      scrollBottomOffset: inSplit ? 8 : this.store.chatScrollBottomOffset(),
      readTranscriptHeight: (): number => focused ? this.store.transcriptContentHeight : this.store.split.otherTranscriptHeight,
      setTranscriptViewport: (height: number): void => { if (focused) this.store.transcriptViewport = height; }
    })
  }

  @Builder
  emptyTranscript() {
    this.welcome(true)
  }

  @Builder
  emptySplitTranscript() {
    Text('还没有消息').fontSize(13).fontColor($r('app.color.pigo_muted'))
      .width('100%').textAlign(TextAlign.Center).padding({ top: 16, bottom: 16 })
  }

  @Builder
  splitPane(state: SessionViewState, focused: boolean) {
    Column() {
      Row({ space: 4 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text(focused ? this.store.chatTitle() : this.store.split.state.otherId ? this.store.split.otherPaneTitle() : '选择第二个会话')
              .fontSize(14).fontWeight(FontWeight.Medium).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(focused ? this.store.accent() : $r('app.color.pigo_text')).layoutWeight(1)
            if ((focused || this.store.split.state.otherId) && this.store.split.splitPaneStatus(state)) {
              Text(this.store.split.splitPaneStatus(state)).fontSize(11).maxLines(1)
                .fontColor(state.interaction || !state.reachable ? $r('app.color.pigo_warning') : this.store.accent())
            }
          }.width('100%')
        }.id(focused ? 'split-focused-title' : 'split-other-title').height(44).layoutWeight(1)
          .padding({ left: 12, right: 3 }).backgroundColor(Color.Transparent)
          .accessibilitySelected(focused)
          .enabled(!this.store.split.state.splitNavigating && !this.store.session.openingSession && !this.store.session.busy)
          .onClick(() => {
            if (focused) return;
            if (this.store.split.state.otherId) void this.store.split.focusOtherPane();
            else this.store.setDrawer(true);
          })
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.xmark'), $r('app.color.pigo_muted'), 17)
        }.id(focused ? 'split-close-focused' : 'split-close-other').width(44).height(44)
          .padding(0).backgroundColor(Color.Transparent).accessibilityText(focused ? '关闭当前会话面板' : '关闭另一会话面板')
          .enabled(!this.store.split.state.splitNavigating && !this.store.session.openingSession && !this.store.session.busy)
          .onClick(() => { void this.store.split.closeSplitPane(focused); })
      }.width('100%').backgroundColor(focused ? this.store.accentTint() : $r('app.color.pigo_control'))
      if ((focused && state.currentId) || (!focused && this.store.split.state.otherId && state.currentId)) {
        if (focused && state.interaction) {
          Scroll() {
            PendingInteractionCard({
              request: state.interaction,
              interactionDraft: state.interactionDraft,
              reachable: state.reachable,
              busy: state.busy,
              openingSession: state.openingSession,
              accent: this.store.accent(),
              accentForeground: this.store.accentForeground(),
              answerInteraction: (id: string, answer: string | boolean): Promise<void> => this.store.answerInteraction(id, answer),
              changeDraft: (id: string, value: string): void => { if (id === state.interaction?.id) state.interactionDraft = value; }
            })
          }.constraintSize({ maxHeight: 150 }).width('100%')
        }
        if (focused && state.pendingSend && !state.busy) {
          Row({ space: 8 }) {
            Button('核对发送').chatAction().enabled(state.reachable).onClick(() => { void this.store.sessionActions.checkSend(); })
            Button('保留草稿').chatAction().onClick(() => {
              this.store.chatState.unconfirmed.delete(this.store.streamSync.draftKey(state.currentId));
              state.pendingSend = undefined;
              state.status = '已保留草稿，未重发。';
            })
          }.width('100%').padding(6)
        }
        this.chatTranscript(state, focused, true)
      } else {
        Column() {
          if (focused || this.store.split.state.otherId) {
            Text(state.noSession || '等待会话连接').fontSize(13).fontColor($r('app.color.pigo_muted'))
              .textAlign(TextAlign.Center)
          } else {
            Button('从会话列表选择').chatAction().id('choose-split-session')
              .onClick(() => { this.store.setDrawer(true); })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(12)
      }
    }.id(focused ? 'split-focused-pane' : 'split-other-pane').layoutWeight(1)
      .width(this.store.splitHorizontal() && !this.store.splitKeyboardCompact() ? undefined : '100%')
      .height(this.store.splitHorizontal() && !this.store.splitKeyboardCompact() ? '100%' : undefined)
      .borderRadius(12).border({ width: 1, color: focused ? this.store.accent() : $r('app.color.pigo_line') }).clip(true)
  }

  @Builder
  splitConversation() {
    Flex({ direction: this.store.splitHorizontal() && !this.store.splitKeyboardCompact() ? FlexDirection.Row : FlexDirection.Column }) {
      if (this.store.splitKeyboardCompact()) {
        this.splitPane(this.store.session, true)
      } else if (this.store.split.state.focusedPaneFirst) {
        this.splitPane(this.store.session, true)
        Blank().width(this.store.splitHorizontal() ? 8 : '100%').height(this.store.splitHorizontal() ? '100%' : 8)
        this.splitPane(this.store.split.state.otherSession, false)
      } else {
        this.splitPane(this.store.split.state.otherSession, false)
        Blank().width(this.store.splitHorizontal() ? 8 : '100%').height(this.store.splitHorizontal() ? '100%' : 8)
        this.splitPane(this.store.session, true)
      }
    }.id('split-conversation').width('100%').height('100%')
      .padding({ left: 8, right: 8, top: this.store.topContentClearance(), bottom: this.store.chatBottomClearance() })
  }

  @Builder
  singleConversation() {
    Column() {
      if (this.store.chatHasTopCards()) {
        Column({ space: 8 }) {
          if (this.store.backgroundRunning().length && this.store.activeTab === 'tasks' && !this.store.showFiles &&
            !this.store.session.showSettings && !this.store.session.noSession && this.store.session.currentId) {
            RunningSessionStrip({
              rows: this.store.runningSessionPills(),
              canOpen: this.store.session.reachable && !this.store.session.busy && !this.store.session.openingSession,
              openSession: (id: string): void => {
                if (id === this.store.session.currentId || this.store.session.openingSession) return;
                this.store.activeTab = 'tasks';
                void this.store.sessionActions.requestAction('/open', { id: id });
              }
            })
          }
          if (!this.store.session.reachable && !this.store.offlineDismissed) {
            OfflineNotice({
              compact: false,
              narrow: false,
              busy: this.store.session.busy,
              retry: (): void => { this.store.offlineDismissed = false; this.store.streamSync.schedule(0); },
              dismiss: (): void => { this.store.offlineDismissed = true; }
            })
          }
          if (this.store.session.interaction) {
            PendingInteractionCard({
              request: this.store.session.interaction,
              interactionDraft: this.store.session.interactionDraft,
              reachable: this.store.session.reachable,
              busy: this.store.session.busy,
              openingSession: this.store.session.openingSession,
              accent: this.store.accent(),
              accentForeground: this.store.accentForeground(),
              answerInteraction: (id: string, answer: string | boolean): Promise<void> => this.store.answerInteraction(id, answer),
              changeDraft: (id: string, value: string): void => { if (id === this.store.session.interaction?.id) this.store.session.interactionDraft = value; }
            })
          }
          if (this.store.session.pendingSend && !this.store.session.busy) {
            Row({ space: 8 }) {
              Button('核对发送').chatAction().id('check-send').enabled(this.store.session.reachable).onClick(() => { void this.store.sessionActions.checkSend(); })
              Button('保留草稿').chatAction().id('keep-draft').onClick(() => {
                this.store.chatState.unconfirmed.delete(this.store.streamSync.draftKey(this.store.session.currentId));
                this.store.session.pendingSend = undefined;
                this.store.session.status = '已保留草稿，未重发。';
              })
            }.width('100%')
          }
        }.width('100%').padding({ left: 16, right: 16, top: this.store.topContentClearance() })
      }
      this.chatTranscript(this.store.session, true, false)
    }.width('100%').height('100%')
  }

  @Builder
  chat() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.store.showFiles) {
        Column() {
          this.workspaceFiles()
        }.width('100%').height('100%').transition(subPageTransition())
      } else if (this.store.session.showSettings) {
        SessionSettings({
        renameDraft: this.store.session.renameDraft,
        busy: this.store.session.busy,
        reachable: this.store.session.reachable,
        modelLabel: this.store.session.modelLabel,
        models: this.store.session.models,
        selectedModel: this.store.session.selectedModel,
        selectedLevel: this.store.session.selectedLevel,
        idle: this.store.session.idle,
        queued: this.store.session.queued,
        sharingSession: this.store.shareController.state.sharingSession,
        darkMode: this.store.darkMode,
        hasSession: !!this.store.session.currentId,
        accent: this.store.accent(),
        accentForeground: this.store.accentForeground(),
        topContentClearance: this.store.topContentClearance(),
        bottomPad: this.store.bottomPad(),
        changeName: (value: string): void => { this.store.session.renameDraft = value; },
        rename: (): void => { void this.store.sessionActions.requestAction('/rename', { id: this.store.session.currentId, name: this.store.session.renameDraft.trim() }); },
        selectModel: (index: number): void => {
          this.store.session.selectedModel = index;
          const model = this.store.session.models[index];
          if (model && !model.levels.includes(this.store.session.selectedLevel)) this.store.session.selectedLevel = model.levels[0] ?? 'off';
        },
        selectLevel: (level: string): void => { this.store.session.selectedLevel = level; },
        applyModel: (): void => {
          const model = this.store.session.models[this.store.session.selectedModel];
          if (model) void this.store.sessionActions.requestAction('/model', { id: this.store.session.currentId, provider: model.provider,
            modelId: model.id, thinkingLevel: this.store.session.selectedLevel });
        },
        share: (): void => { void this.store.shareController.shareCurrentSession('session-share'); },
        thinkingLevelLabel: (level: string): string => this.store.toolCmd.thinkingLevelLabel(level)
      })
      } else if (this.store.session.noSession && !this.store.split.state.splitOpen) {
        Column() {
          this.welcome()
        }.width('100%').height('100%').transition(modalFadeTransition())
      } else {
        Stack({ alignContent: Alignment.Bottom }) {
        if (this.store.split.state.splitOpen) {
          this.splitConversation()
        } else {
          this.singleConversation()
        }
        Column({ space: 6 }) {
          if (this.store.toolCmd.state.commandPalette && this.store.toolCmd.commandPaletteActive()) {
            CommandPaletteCard({
              darkMode: this.store.darkMode,
              reachable: this.store.session.reachable,
              commandsLoading: this.store.toolCmd.state.commandsLoading,
              commandError: this.store.toolCmd.state.commandError,
              hasCommands: this.store.toolCmd.state.commandRows.length > 0,
              matches: this.store.toolCmd.commandMatches(),
              maxHeight: this.store.keyboardHeight || this.store.windowHeight < SHORT_WINDOW_HEIGHT ? 132 : 216,
              commandSourceLabel: (source: string): string => this.store.toolCmd.commandSourceLabel(source),
              reloadCommands: (): Promise<void> => this.store.toolCmd.loadCommands(),
              pickCommand: (row: CommandRow): void => this.store.toolCmd.pickCommand(row)
            })
          }
          this.composer()
        }.width('100%').padding({
          left: 16,
          right: 16,
          bottom: this.store.composerBottomMargin()
        }).animation({ duration: 240, curve: Curve.FastOutSlowIn })
        }.width('100%').height('100%')
      }
    }.width('100%').layoutWeight(1)
  }

  @Builder
  composer() {
    ChatComposer({ store: this.store })
  }

  @LocalBuilder
  rootTabBar(tab: string) {
    RootTabBarItem({ store: this.store, tab: tab })
  }

  @Builder
  welcome(inTranscript: boolean = false) {
    Column({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.code_square')).fontSize(31).fontColor([this.store.accent()])
      }.width(60).height(60).borderRadius(18).backgroundColor(this.store.accentTint()).accessibilityLevel('no')
      Text(!this.store.isPaired || this.store.loading ? 'Pi Go' : inTranscript ? '开始新会话' : '选择一个会话')
        .fontSize(this.store.isPaired && !this.store.loading ? 24 : 36).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.pigo_text')).textAlign(TextAlign.Center)
      Text(this.store.loading ? '正在读取已配对的电脑…' : !this.store.isPaired ? '连接电脑，随时查看 AI 后台动态与对话。' :
        this.store.session.noSession || (this.store.session.reachable ? '输入你的目标，或添加文件作为上下文。' : '电脑重新连接后即可发送消息。'))
        .fontSize(15).fontColor($r('app.color.pigo_muted')).textAlign(TextAlign.Center).lineHeight(23)
        .constraintSize({ maxWidth: 320 })
      if (!this.store.loading && !this.store.isPaired) {
        Button('连接电脑').chatAction().height(46).padding({ left: 24, right: 24 })
          .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground()).onClick(() => { this.store.openComputers(); })
      } else if (!this.store.loading && this.store.session.noSession && !this.store.dockedSessions()) {
        Button('打开会话列表').chatAction().height(44).padding({ left: 18, right: 18 })
          .backgroundColor(this.store.accent()).fontColor(this.store.accentForeground()).onClick(() => { this.store.setDrawer(true); })
      }
    }.width('100%').padding({ top: inTranscript && this.store.windowHeight >= SHORT_WINDOW_HEIGHT ? 36 : 8,
      bottom: inTranscript && this.store.windowHeight >= SHORT_WINDOW_HEIGHT ? 24 : 8, left: 16, right: 16 })
      .layoutWeight(inTranscript ? 0 : 1).justifyContent(FlexAlign.Center)
  }

  @Builder
  taskView() {
    TaskPanel({ store: this.store })
  }

  @Builder
  sessionDrawer() {
    SessionSidebar({ store: this.store })
  }

  @Builder
  sessionPaneHandle() {
    Stack() {
      Rect().width(4).height(44).radius(2)
        .fill(this.store.sessionPaneDragging ? this.store.accent() : $r('app.color.pigo_muted'))
    }.id('session-pane-resize').width(20).height('100%').offset({ x: this.store.sessionPaneWidth() - 10 })
      .accessibilityText('左右拖动调整任务侧边栏宽度')
      .gesture(PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart(() => {
          this.store.sessionPaneDragStart = this.store.sessionPaneWidth();
          this.store.sessionPaneDragging = true;
        })
        .onActionUpdate((event: GestureEvent) => {
          this.store.preferredSessionPaneWidth = this.store.sessionPaneWidth(this.store.sessionPaneDragStart + event.offsetX);
        })
        .onActionEnd(() => { this.store.sessionPaneDragging = false; })
        .onActionCancel(() => { this.store.sessionPaneDragging = false; }))
      .onDisAppear(() => { this.store.sessionPaneDragging = false; })
  }

  @Builder
  statusNotice() {
    Row({ space: 8 }) {
      Text(this.store.session.status).fontColor($r('app.color.pigo_warning')).fontSize(13).layoutWeight(1)
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([$r('app.color.pigo_warning')])
      }.width(30).height(30).padding(0).borderRadius(8).backgroundColor(Color.Transparent)
        .accessibilityText('关闭提示').onClick(() => { this.store.session.status = ''; })
    }.width('100%').padding({ left: 12, right: 6, top: 8, bottom: 8 })
      .attributeModifier(glassCardSurface(this.store.darkMode, 14, true))
  }

  @Builder
  textPreviewMarkdown() {
    if (this.store.fileController.state.textFilePreview?.text !== undefined) {
      this.richChatText(this.store.fileController.state.textFilePreview.text, this.store.fileController.state.textFilePreview.workspaceRoot ?? '',
        this.store.fileController.state.textFilePreview.workspacePath ?? '')
    }
  }

  @Builder
  tableReaderMarkdown() {
    if (this.store.fileController.state.markdownTableReader) {
      this.richChatText(this.store.fileController.state.markdownTableReader.source, this.store.fileController.state.markdownTableReader.cwd,
        this.store.fileController.state.markdownTableReader.documentPath, false)
    }
  }

  @Builder
  mainNavigation() {
    Navigation() {
      Stack({ alignContent: Alignment.Bottom }) {
        Tabs({ barPosition: BarPosition.End, index: this.store.activeTabIndex() }) {
          ForEach(this.store.rootTabs(), (tab: string) => {
            TabContent() {
              Column() {
                if (this.store.loading) {
                  this.welcome()
                } else if (tab === 'mine') {
                  this.mineView()
                } else if (!this.store.isPaired) {
                  this.welcome()
                } else if (tab === 'inbox') {
                  this.inboxView()
                } else if (tab === 'pending') {
                  this.taskView()
                } else {
                  this.chat()
                }
              }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
            }.tabBar(this.rootTabBar(tab))
          }, (tab: string) => tab)
        }
        .width('100%').height('100%')
        .vertical(false).scrollable(false).animationDuration(0)
        .barOverlap(true)
        .barHeight(this.store.showRootBottomTabs() ? this.store.bottomTabsHeight() : 0)
        .barBackgroundColor(Color.Transparent)
        .attributeModifier(immersiveFloatingTabs(this.store.showRootBottomTabs(), this.store.bottomPad() + 8, this.store.darkMode))
        .onContentWillChange((_from: number, to: number): boolean => {
          const tab = this.store.rootTabs()[to];
          return !!tab && this.store.selectRootTab(tab);
        })
        .onTabBarClick((index: number) => {
          const tab = this.store.rootTabs()[index];
          if (tab && tab === this.store.activeTab) this.store.selectRootTab(tab);
        })
        if (!this.store.loading && this.store.session.status) {
          Column() {
            this.statusNotice()
          }.width('100%').padding({
            left: 16,
            right: 16,
            bottom: (this.store.showRootBottomTabs() ? this.store.bottomTabsHeight() + 14 : 0) + this.store.bottomPad() + 8
          }).hitTestBehavior(HitTestMode.Transparent)
        }
      }.width('100%').height('100%')
    }.width('100%').height('100%').constraintSize({ maxWidth: this.store.activeTab === 'mine' || this.store.session.showSettings ? 600 : 840 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .title({ builder: this.pageHeader, height: this.store.headerHeight() + this.store.statusBarHeight + 20 }, {
        backgroundColor: Color.Transparent,
        barStyle: BarStyle.STACK
      })
      .hideTitleBar(this.store.loading || (!this.store.isPaired && this.store.activeTab !== 'mine'))
  }

  @Builder
  scheduleOverlay() {
    ScheduleOverlay({
      store: this.store,
      resultMarkdown: (text: string, cwd: string): void => {
        this.richChatText(text, cwd)
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        // Reserve the sidebar's space without rebuilding the conversation or moving the session list.
        Blank().width(this.store.dockedSessions() ? this.store.sessionPaneWidth() : 0)
        Stack({ alignContent: Alignment.Bottom }) {
          // Keep the wallpaper at window height while the keyboard resizes the conversation.
          ThemeBackdrop({
            themeId: this.store.themeId,
            darkMode: this.store.darkMode,
            dimmed: this.store.sakuraConversationFocus(),
            visible: this.store.visible,
            motionEnabled: this.store.themeMotionEnabled,
            windowHeight: this.store.windowHeight,
            girlTapSeq: this.store.toolCmd.state.sakuraGirlTapSeq,
            celebrateSeq: this.store.toolCmd.state.sakuraCelebrateSeq,
            burstSeq: this.store.toolCmd.state.sakuraBurstSeq,
            burstKind: this.store.toolCmd.state.sakuraBurstKind,
            bloomSeq: this.store.toolCmd.state.sakuraBloomSeq,
            bloomX: this.store.toolCmd.state.sakuraBloomX,
            bloomY: this.store.toolCmd.state.sakuraBloomY
          })
          this.mainNavigation()
          if (this.store.sakuraGirlInteractive()) {
            Row() {
              SakuraGirlHitZone({
                bottomInset: this.store.session.noSession ? this.store.bottomContentClearance() : this.store.chatBottomClearance(),
                tap: (): void => this.store.toolCmd.tapSakuraGirl()
              })
            }.width('100%').justifyContent(FlexAlign.End).hitTestBehavior(HitTestMode.Transparent)
          }
        }.height('100%').layoutWeight(1)
          .onTouch((event: TouchEvent) => { this.store.toolCmd.observeThemeTap(event); })
          .onGestureJudgeBegin(() => this.store.dockedSessions() || this.store.showSessions || this.store.voiceComposer.holding() || this.store.voiceComposer.state.recording ||
            this.store.voiceComposer.state.voicePreparing || this.store.voiceComposer.state.voiceFinishing || !this.store.isPaired ||
            this.store.session.showSettings || (this.store.activeTab === 'mine' && !!this.store.minePage)
            ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
          .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.store.swipeDrawer(event); }))
      }.width('100%').height('100%').backgroundColor(this.store.themeCanvas())
        .clip(true)
        .accessibilityLevel(this.store.drawerOpen() || this.store.scheduleController.state.schedulePage ? 'no-hide-descendants' : 'auto')
      if (this.store.drawerOpen()) {
        Button({ type: ButtonType.Normal }).width('100%').height('100%').padding(0)
          .backgroundColor(this.store.darkMode ? '#52000000' : '#2E0F1722').borderRadius(0)
          .accessibilityText('关闭会话列表').onClick(() => { this.store.setDrawer(false); })
          .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.store.swipeDrawer(event); }))
          .transition(modalFadeTransition())
      }
      if (this.store.dockedSessions()) {
        this.sessionDrawer()
      } else if (this.store.drawerOpen()) {
        Column() {
          this.sessionDrawer()
        }.height('100%').transition(drawerSlideTransition())
      }
      if (this.store.dockedSessions()) this.sessionPaneHandle()
      if (this.store.voiceComposer.state.recording || this.store.voiceComposer.state.voicePreparing || (this.store.voiceComposer.state.voiceFinishing && !this.store.voiceComposer.state.voiceCancelling) || this.store.voiceComposer.state.voiceHint) {
        VoiceFeedbackOverlay({ state: this.store.voiceComposer.state, darkMode: this.store.darkMode })
      }
      if (this.store.scheduleController.state.schedulePage) this.scheduleOverlay()
      if (this.store.fileController.state.editingPath) {
        Stack({ alignContent: Alignment.Top }) {
          WorkspaceFileEditor({
            editingPath: this.store.fileController.state.editingPath,
            fileText: this.store.fileController.state.fileText,
            fileOriginal: this.store.fileController.state.fileOriginal,
            busy: this.store.session.busy,
            reachable: this.store.session.reachable,
            editorNotice: this.store.fileController.state.editorNotice,
            darkMode: this.store.darkMode,
            headerHeight: this.store.headerHeight(),
            statusBarHeight: this.store.statusBarHeight,
            bottomPad: this.store.bottomPad(),
            accent: this.store.accent(),
            accentForeground: this.store.accentForeground(),
            back: (): void => this.store.fileController.returnToFilePreview(true),
            showPreview: (): void => this.store.fileController.previewDraft(),
            changeText: (text: string): void => { this.store.fileController.state.fileText = text; },
            saveFile: (): Promise<void> => this.store.fileController.saveFile()
          })
        }.width('100%').height('100%').backgroundColor(this.store.themeCanvas())
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
          .transition(pagePushTransition())
      }
      if (this.store.fileController.state.textFilePreview) {
        Stack({ alignContent: Alignment.Top }) {
          TextFilePreviewPage({
            preview: this.store.fileController.state.textFilePreview,
            busy: this.store.session.busy,
            savingPreview: this.store.fileController.state.savingPreview,
            canEdit: !this.store.fileController.state.editingPath,
            previewNotice: this.store.fileController.state.previewNotice,
            previewScroller: this.store.previewScroller,
            pageNumber: this.store.fileController.previewPageNumber(),
            darkMode: this.store.darkMode,
            headerHeight: this.store.headerHeight(),
            statusBarHeight: this.store.statusBarHeight,
            bottomPad: this.store.bottomPad(),
            accent: this.store.accent(),
            accentForeground: this.store.accentForeground(),
            close: (): void => { this.store.fileController.state.textFilePreview = undefined; },
            editPreview: (preview: ReceivedFilePreview): void => this.store.fileController.editPreview(preview),
            savePreviewLocally: (preview: ReceivedFilePreview): Promise<void> => this.store.fileController.savePreviewLocally(preview),
            reopenSystemPreview: (preview: ReceivedFilePreview): Promise<void> => this.store.fileController.reopenSystemPreview(preview),
            imagePreviewError: (preview: ReceivedFilePreview): Promise<void> => this.store.fileController.imagePreviewError(preview),
            changePreviewPage: (forward: boolean): void => this.store.fileController.changePreviewPage(forward),
            markdownBody: (): void => this.textPreviewMarkdown()
          })
        }.width('100%').height('100%').backgroundColor(this.store.themeCanvas())
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
          .transition(pagePushTransition())
      }
      if (this.store.fileController.state.markdownTableReader) {
        MarkdownTableReaderPage({
          markdownRotationUnavailable: this.store.fileController.state.markdownRotationUnavailable,
          darkMode: this.store.darkMode,
          headerHeight: this.store.headerHeight(),
          statusBarHeight: this.store.statusBarHeight,
          bottomPad: this.store.bottomPad(),
          canvas: this.store.themeCanvas(),
          close: (): void => this.store.fileController.closeMarkdownTableReader(),
          markdownBody: (): void => this.tableReaderMarkdown()
        })
      }
      if (this.store.sessionActions.creation.showNewSession) {
        NewSessionDialog({
          openingSession: this.store.session.openingSession,
          busy: this.store.session.busy,
          reachable: this.store.session.reachable,
          newSessionFixedWorkspace: this.store.sessionActions.creation.newSessionFixedWorkspace,
          projects: this.store.projects,
          workspaces: this.store.workspaces,
          newSessionCwd: this.store.sessionActions.creation.newSessionCwd,
          canCreateWorkspace: this.store.canCreateWorkspace,
          sessionLoading: this.store.sessionLoading,
          agents: this.store.agents,
          newSessionAgent: this.store.sessionActions.creation.newSessionAgent,
          newSessionError: this.store.sessionActions.creation.newSessionError,
          sessionCatalogFailed: this.store.sessionCatalogFailed,
          hostAvailable: this.store.hostAvailable,
          windowHeight: this.store.windowHeight,
          darkMode: this.store.darkMode,
          accent: this.store.accent(),
          accentForeground: this.store.accentForeground(),
          accentTint: this.store.accentTint(),
          canCreateSession: this.store.canCreateSession(),
          closeNewSession: (): void => this.store.closeNewSession(),
          selectWorkspace: (cwd: string): void => { this.store.sessionActions.creation.newSessionCwd = cwd; this.store.sessionActions.creation.newSessionError = ''; },
          openSpace: (): void => { this.store.closeNewSession(); this.store.openNewSpace(); },
          refreshAgents: (): Promise<void> => this.store.loadSessions(),
          selectAgent: (agent: string): void => { this.store.sessionActions.creation.newSessionAgent = agent; this.store.sessionActions.creation.newSessionError = ''; },
          createSession: (): Promise<void> => this.store.sessionActions.createSession()
        })
      }
      if (this.store.sessionActions.creation.showNewSpace) {
        NewSpaceDialog({
          busy: this.store.session.busy,
          reachable: this.store.session.reachable,
          newSpaceName: this.store.sessionActions.creation.newSpaceName,
          newSpaceError: this.store.sessionActions.creation.newSpaceError,
          darkMode: this.store.darkMode,
          accent: this.store.accent(),
          accentForeground: this.store.accentForeground(),
          closeNewSpace: (): void => this.store.closeNewSpace(),
          changeName: (value: string): void => { this.store.sessionActions.creation.newSpaceName = value; this.store.sessionActions.creation.newSpaceError = ''; },
          createWorkspaceTask: (): Promise<void> => this.store.sessionActions.createWorkspaceTask()
        })
      }
      if (this.store.runCenter.state.runNotice) {
        RunCompletionBanner({
          notice: this.store.runCenter.state.runNotice,
          iconColor: this.store.stateColor(this.store.runCenter.state.runNotice.stopped ? 'waiting' : 'streaming'),
          darkMode: this.store.darkMode,
          statusBarHeight: this.store.statusBarHeight,
          dismiss: (): void => this.store.runCenter.advanceRunNotice()
        })
      }
      if (this.store.scheduleController.state.scheduleBanner && !this.store.scheduleController.state.schedulePage && !this.store.runCenter.state.runNotice) {
        Row() {
          ScheduledRunBanner({
            message: this.store.scheduleController.state.scheduleBanner,
            darkMode: this.store.darkMode,
            open: (message: RunMessage): void => this.store.scheduleController.showScheduleDetail(message, true),
            dismiss: (): void => { this.store.scheduleController.state.scheduleBanner = undefined; }
          })
        }.width('100%').justifyContent(FlexAlign.Center)
          .margin({ top: this.store.statusBarHeight + this.store.headerHeight() + 10 }).hitTestBehavior(HitTestMode.Transparent)
          .transition(bannerTransition())
      }
      if (this.store.runCenter.state.reviewedRun) {
        RunResultView({
          result: this.store.runCenter.state.reviewedRun, file: this.store.runCenter.state.reviewedFile, patch: this.store.runCenter.state.reviewPatch,
          loading: this.store.runCenter.state.reviewLoading, error: this.store.runCenter.state.reviewError,
          themeId: this.store.themeId, darkMode: this.store.darkMode, top: this.store.statusBarHeight, bottom: this.store.bottomPad(),
          back: (): void => this.store.runCenter.backFromRunResult(),
          openDiff: (file: RunFile): void => { void this.store.runCenter.openRunDiff(file); },
          openArtifact: (file: RunFile): void => { void this.store.runCenter.openRunArtifact(file); },
          loadScreenshot: (image: RunScreenshot): Promise<string> =>
            this.store.fileController.loadHistoryImage(this.store.runCenter.state.reviewedRun?.sessionId ?? '', image.messageId, 0, image.toolId),
          openScreenshot: (source: string, label: string): void => {
            this.store.runCenter.state.reviewedRun = undefined;
            this.store.fileController.showChatImage(source, label);
          },
          citeLine: (line: DiffLine): void => this.store.citeRunLine(line)
        })
      }
      if (this.store.shareController.showIncomingShare()) {
        Row() {
          IncomingShareBanner({
            incomingShare: this.store.appState.incomingShare,
            shareError: this.store.shareController.state.shareError,
            isPaired: this.store.isPaired,
            canAddShareToCurrent: this.store.canAddShareToCurrent(),
            sessionName: this.store.session.sessionName,
            project: this.store.session.project,
            shareTargetLocked: this.store.shareTargetLocked(),
            busy: this.store.session.busy,
            openingSession: this.store.session.openingSession,
            hasPendingSend: !!this.store.session.pendingSend,
            accent: this.store.accent(),
            accentForeground: this.store.accentForeground(),
            clearIncomingShare: (): void => this.store.shareController.clearIncomingShare(),
            chooseShareComputer: (): void => this.store.shareController.chooseShareComputer(),
            chooseShareSession: (): void => this.store.shareController.chooseShareSession(),
            addShareToDraft: (): void => this.store.shareController.addShareToDraft()
          })
        }.width('100%').justifyContent(FlexAlign.Center)
          .margin({ top: this.store.statusBarHeight + this.store.headerHeight() + 8 }).hitTestBehavior(HitTestMode.Transparent)
          .transition(bannerTransition())
      }
    }.width('100%').height('100%').padding({ left: this.store.leftInset, right: this.store.rightInset })
      .backgroundColor(this.store.themeCanvas())
      .clip(true)
      .bindSheet(this.store.toolCmd.state.showToolDetails, this.toolDetailsSheet(), {
        detents: ['65%', SheetSize.LARGE], dragBar: true, showClose: true,
        backgroundColor: hasImmersiveMaterial() ? undefined : $r('app.color.pigo_panel'),
        systemMaterial: immersiveSheetMaterial(),
        maskColor: '#52000000',
        onDisappear: () => { this.store.toolCmd.closeToolDetails(); }
      })
  }
}
