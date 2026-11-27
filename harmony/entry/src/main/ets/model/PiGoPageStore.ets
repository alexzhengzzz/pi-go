import { SessionActions, SessionActionsHost } from './SessionActions';
import { SessionViewState, StreamSyncController, StreamSyncHost } from './StreamSyncController';
import { ShareAttachmentController, ShareAttachmentHost } from './ShareAttachmentController';
import { VoiceComposerController, VoiceComposerHost } from './VoiceComposerController';
import { ScheduleController, ScheduleHost } from './ScheduleController';
import { RunCenterController, RunCenterHost } from './RunCenterController';
import { WorkspaceFileController, WorkspaceFileHost } from './WorkspaceFileController';
import { SplitPaneController, SplitPaneHost } from './SplitPaneController';
import { ToolCommandController, ToolCommandHost } from './ToolCommandController';
import { AccountSyncController, AccountSyncHost } from './AccountSyncController';
import { RunningSessionPill } from '../components/SessionOverlays';
import { replySpeechText } from '../ChatContent';
import { AppUiState, appUiState, windowAppUiState } from '../AppUiState';
import { entryInstances } from '../EntryInstanceRegistry';
import { CommandList, CommandState, commandDraft, skillDraft } from './CommandState';
import { ConnectionManager, PairingRequest } from './ConnectionManager';
import { ChatState } from './ChatState';
import type { TranscriptCacheBook } from './ChatState';
import { SessionCatalog, SessionStore, SIDEBAR_VIEWS, WorkspacePage, workspaceName } from './SessionStore';
import { PiGoClient } from './PiGoClient';
import { DiffLine, InboxRun, RunEvent, RunFile, RunScreenshot } from '../RunResults';
import { KeyboardAvoidMode, UIContext } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { util } from '@kit.ArkTS';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { AbilityConstant, common } from '@kit.AbilityKit';
import { closeConversationWindows, findConversationWindow, prepareConversationWindow, takeConversationWindow } from '../ConversationWindowLaunch';
import { panePath, paneQuery, WindowConversation } from './WindowConversation';
import { preferences } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { Companion, ComputerBook, CredentialVault, subscribeComputerBook } from '../CredentialVault';
import { AppearanceMode, THEME_MOTION_SETTING, ThemePalette, appearanceMode, canvasFadeStops, openSettings, themePalette, themeStyle } from '../Appearance';
import { HuaweiProfile } from '../HuaweiProfile';
import { CloudComputer, SYNC_MODE, SYNC_THEME } from '../AccountSync';
import { markdownWorkspacePath, normalizeWorkspacePath } from '../ChatPaths';
import { decodePairingBundle, validUsb } from '../PairingCode';
import { connectionLabel, validCompanion } from '../CompanionCheck';
import { ComputerGroup, computerGroupId, computerGroups, computerGroupTitle, moveComputerConnection, renameComputerGroup } from '../ComputerGroups';
import { LiveActivitySnapshot, liveActivity } from '../LiveActivity';
import { ScheduleJob, RunMessage, scheduleTime, parseScheduleTime, isCurrentScheduleComputer } from '../ScheduledRuns';
import { ModelOption, BridgeEndpoint, SessionState, SessionRow, ChatMessage, DraftAttachment,
  UploadedAttachment, LiveTool, ToolDetails, CommandRow, ReceivedFilePreview,
  PendingInteraction, RunningRow, WorkspaceRow, BridgeReply,
  AgentInfo, OptimisticMessage, Payload, QueuedSteering, BridgeFailure } from './PiGoTypes';
import { USB_ADDRESS, SPLIT_WINDOW_WIDTH, SHORT_WINDOW_HEIGHT, LIVE_VIEW_SETTING } from './PiGoConstants';
import { SidebarRows } from './SidebarRows';
import { buildWidgetSnapshot, InboxWidget } from '../InboxWidget';
const PANE_ACTIONS: string[] = ['/prompt', '/abort', '/answer', '/receipt'];
const PANE_ROUTES: string[] = [
  '/session/snapshot', '/chat', '/history', '/tool-detail',
  '/message-image', '/message-text', '/prompt', '/abort',
  '/answer', '/receipt', '/regenerate'
];

@ObservedV2
export class PiGoPageStore {
  @Trace appState: AppUiState;
  private uiContextGetter?: () => UIContext = undefined;
  readonly runCenter: RunCenterController;
  readonly scheduleController: ScheduleController;
  readonly shareController: ShareAttachmentController;
  @Trace session: SessionViewState = new SessionViewState();
  readonly streamSync: StreamSyncController;
  readonly split: SplitPaneController;
  readonly toolCmd: ToolCommandController;
  readonly sessionActions: SessionActions;
  readonly inboxWidget: InboxWidget = new InboxWidget();
  readonly chatState: ChatState = new ChatState();
  readonly previewScroller: Scroller = new Scroller();
  readonly fileController: WorkspaceFileController;
  readonly client: PiGoClient = new PiGoClient();
  readonly accountSync: AccountSyncController;
  readonly voiceComposer: VoiceComposerController;
  readonly connection: ConnectionManager = new ConnectionManager();
  readonly sessionStore: SessionStore = new SessionStore();
  readonly transcript: Scroller = new Scroller();
  readonly library: Scroller = new Scroller();
  readonly sidebarRows: SidebarRows = new SidebarRows();

  constructor(appState: AppUiState) {
    this.appState = appState;
    this.runCenter = new RunCenterController(this.runCenterHost());
    this.scheduleController = new ScheduleController(this.scheduleHost());
    this.shareController = new ShareAttachmentController(this.shareAttachmentHost());
    this.streamSync = new StreamSyncController(this.streamSyncHost());
    this.sessionActions = new SessionActions(this.sessionActionsHost());
    this.fileController = new WorkspaceFileController(this.workspaceFileHost());
    this.accountSync = new AccountSyncController(this.accountSyncHost());
    this.voiceComposer = new VoiceComposerController(this.voiceComposerHost());
    this.split = new SplitPaneController(this.splitPaneHost());
    this.toolCmd = new ToolCommandController(this.toolCommandHost());
  }

  attachUIContext(getter: () => UIContext): void {
    this.uiContextGetter = getter;
  }

  getUIContext(): UIContext {
    return this.uiContextGetter!();
  }
  get darkMode(): boolean { return this.appState.darkMode; }
  get address(): string { return this.appState.address; }
  set address(value: string) { this.appState.address = value; }
  get launchTicket(): string { return this.appState.launchTicket; }
  set launchTicket(value: string) { this.appState.launchTicket = value; }
  get liveLaunchSession(): string { return this.appState.liveLaunchSession; }
  set liveLaunchSession(value: string) { this.appState.liveLaunchSession = value; }
  get liveLaunchAddress(): string { return this.appState.liveLaunchAddress; }
  set liveLaunchAddress(value: string) { this.appState.liveLaunchAddress = value; }
  networkTimer: number = -1;
  switchingNetwork: boolean = false;
  lastNetworkFailover: number = 0;
  restoreChain: Promise<void> = Promise.resolve();
  get statusBarHeight(): number { return this.appState.statusBarHeight; }
  get navBarHeight(): number { return this.appState.navBarHeight; }
  get leftInset(): number { return this.appState.leftInset; }
  get rightInset(): number { return this.appState.rightInset; }
  get windowWidth(): number { return this.appState.windowWidth; }
  get windowHeight(): number { return this.appState.windowHeight; }
  get keyboardHeight(): number { return this.appState.keyboardHeight; }
  @Trace ticket: string = '';
  @Trace pairingMode: string = 'usb';
  @Trace pairingBundle: string = '';
  @Trace lanCandidates: string[] = [];
  @Trace isPaired: boolean = false;
  @Trace loading: boolean = true;
  @Trace computers: Companion[] = [];
  @Trace removeTarget: string = '';
  @Trace renameComputerId: string = '';
  @Trace computerNameDraft: string = '';
  @Trace moveConnectionAddress: string = '';
  @Trace pairingComputerId: string = '';
  @Trace showFiles: boolean = false;
  @Trace sessions: SessionRow[] = [];
  @Trace runningSessionIds: string[] = [];
  @Trace runningSessions: RunningRow[] = [];

  sessionStatusAt: number = 0;
  sessionStatusLoading: boolean = false;
  @Trace showSessions: boolean = false;
  @Trace preferredSessionPaneWidth?: number = undefined;
  @Trace sessionPaneDragging: boolean = false;
  sessionPaneDragStart: number = 0;
  @Trace expandedSpaces: string[] = [];
  @Trace offlineDismissed: boolean = false;
  @Trace activeTab: string = 'inbox';
  @Trace inboxSelecting: boolean = false;
  @Trace minePage: string = '';
  @Trace addingComputer: boolean = false;
  @Trace themeId: string = 'sakura';
  @Trace themeMotionEnabled: boolean = true;
  @Trace modeId: string = 'system';
  @Trace liveViewsEnabled: boolean = true;
  @Trace liveViewStatus: string = '';
  @Trace appearanceNotice: string = '';
  @Trace avatarUnavailable: boolean = false;
  settings?: preferences.Preferences;
  settingsWrite: Promise<void> = Promise.resolve();
  @Trace restoringComputer?: CloudComputer = undefined;

  @Trace sessionView: string = 'all';
  @Trace loadedView: string = 'all';
  @Trace hostAvailable: boolean = false;
  @Trace canCreateWorkspace: boolean = false;
  @Trace agents: AgentInfo[] = [];
  @Trace projects: string[] = [];
  @Trace workspaces: WorkspaceRow[] = [];
  @Trace workspacePages: WorkspacePage[] = [];
  @Trace sessionNextCursor?: number = undefined;
  @Trace base: string = '';
  visible: boolean = false;
  @Trace sessionLoading: boolean = false;
  @Trace sessionCatalogFailed: boolean = false;
  sessionCatalogLoaded: boolean = false;
  sessionCatalogUpdatedAt: number = 0;

  sessionCatalogVersion: number = 0;
  catalogConnection: number = 0;
  workspacePageRequestId: number = 0;
  vault?: CredentialVault;
  transcriptContentHeight: number = 0;
  transcriptViewport: number = 0;
  pendingLibraryReveal: boolean = false;
  disposed: boolean = false;
  unsubscribeVault?: () => void = undefined;

  onBackPress(): boolean {
    if (this.fileController.state.markdownTableReader) { this.fileController.closeMarkdownTableReader(); return true; }
    if (this.runCenter.state.reviewedRun) { this.runCenter.backFromRunResult(); return true; }
    if (this.fileController.state.textFilePreview) {
      if (!this.fileController.state.savingPreview) this.fileController.state.textFilePreview = undefined;
      return true;
    }
    if (this.fileController.state.editingPath) {
      this.fileController.returnToFilePreview();
      return true;
    }
    if (this.voiceComposer.state.recording || this.voiceComposer.state.voicePreparing || this.voiceComposer.state.voiceFinishing) { this.voiceComposer.resetVoice(); return true; }
    if (this.scheduleController.state.schedulePage) { this.scheduleController.backFromSchedule(); return true; }
    if (this.activeTab === 'inbox' && this.inboxSelecting) { this.inboxSelecting = false; return true; }
    if (this.toolCmd.state.showToolDetails) { this.toolCmd.closeToolDetails(); return true; }
    if (this.toolCmd.state.showModelMenu) { this.toolCmd.state.showModelMenu = false; return true; }
    if (this.sessionActions.creation.showNewSpace) { this.closeNewSpace(); return true; }
    if (this.sessionActions.creation.showNewSession) { this.closeNewSession(); return true; }
    if (this.showSessions) { this.setDrawer(false); return true; }
    if (this.session.showSettings) { this.session.showSettings = false; return true; }
    if (this.showFiles) { this.fileBack(); return true; }
    if (this.split.state.splitOpen && this.activeTab === 'tasks') {
      if (this.keyboardHeight) this.dismissKeyboard();
      else if (!this.split.state.splitNavigating) this.split.clearSplit();
      return true;
    }
    if (this.activeTab === 'mine' && this.minePage) {
      if (!this.session.busy) this.mineBack();
      return true;
    }
    return false;
  }

  aboutToAppear(): void {
    this.disposed = false;
    this.unsubscribeVault = subscribeComputerBook((book: ComputerBook, source: CredentialVault): void => {
      if (this.disposed || source === this.vault) return;
      this.computers = this.connection.restoreComputers(book.computers, (): string => util.generateRandomUUID());
    });
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const context = this.getUIContext().getHostContext();
    if (context) {
      liveActivity.attach(context as common.UIAbilityContext, (status: string): void => {
        this.liveViewStatus = status;
      });
    }
    this.restoreSettings();
    if (context) this.runCenter.attachWatch(context as common.UIAbilityContext);
    this.restoreChain = this.restore();
    void this.restoreChain.then(() => {
      if (!this.isPaired && (this.activeTab === 'inbox' || this.activeTab === 'tasks')) this.openComputers();
      void this.consumeLaunchTicket();
    });
  }
  onPageShow(): void {
    this.visible = true;
    const context = this.getUIContext().getHostContext();
    if (context) {
      liveActivity.attach(context as common.UIAbilityContext, (status: string): void => {
        this.liveViewStatus = status;
      });
    }
    this.runCenter.resume();
    this.connection.watchNetwork((): void => { this.onNetworkChange(); });
    void this.restoreChain.then(() => {
      this.scheduleController.queueScheduleSync(true);
      this.runCenter.queueRunSync(450);
      void this.runCenter.consumePushLaunch();
      this.onInboxFormLaunch();
    });
    this.streamSync.schedule(0);
    this.streamSync.startStream();
    this.streamSync.syncLiveActivity();
    this.split.resumeOtherPane();
    void this.consumeLiveActivityLaunch();
    void this.accountSync.checkHuaweiProfile().then(() => { this.accountSync.scheduleCloudSync(0); });
  }
  onPageHide(): void {
    this.visible = false;
    this.split.suspendOtherPane();
    this.voiceComposer.stopReplySpeech();
    this.stopNetworkMonitor();
    this.runCenter.startBackgroundRunNotices();
    this.runCenter.queueRunSync(0);
    this.scheduleController.stopScheduleSync();
    this.runCenter.clearRunNotices();
    if (this.streamSync.backgroundLiveActivity()) {
      // Best effort only: HarmonyOS may still freeze the process without a continuous-task grant.
      this.streamSync.schedule(0);
      this.streamSync.startStream();
    } else {
      this.streamSync.cancelSchedule();
      this.streamSync.stopStream();
    }
    this.voiceComposer.resetVoice();
  }
  aboutToDisappear(): void {
    this.disposed = true;
    this.unsubscribeVault?.();
    this.unsubscribeVault = undefined;
    this.accountSync.dispose();
    this.voiceComposer.disposeReplySpeech();
    if (this.fileController.state.markdownTableReader) this.fileController.closeMarkdownTableReader();
    this.visible = false;
    this.split.clearSplit();
    this.runCenter.close();
    this.stopNetworkMonitor();
    this.scheduleController.stopScheduleSync();
    this.streamSync.cancelSchedule();
    this.streamSync.stopStream();
    if (entryInstances.count() <= 1) {
      liveActivity.sync(undefined);
    } else {
      const context = this.getUIContext().getHostContext();
      if (context) liveActivity.detach(context as common.UIAbilityContext);
    }
    this.voiceComposer.resetVoice();
  }

  async restore(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context) { this.loading = false; return; }
    const epoch = this.session.epoch;
    try {
      this.vault = await CredentialVault.open(context);
      const cachedBook = await this.vault.loadTranscriptCache();
      this.chatState.restoreTranscriptCache(cachedBook);
      this.chatState.setCachePersister((book: TranscriptCacheBook): void => {
        void this.vault?.saveTranscriptCache(book);
      });
      const saved = await this.vault.load();
      if (!saved || epoch !== this.session.epoch) return;
      this.computers = this.connection.restoreComputers(saved.computers, (): string => util.generateRandomUUID());
      const active = this.computers.find((record: Companion): boolean => record.address === saved.active);
      if (active) this.activateComputer(active, true);
    } catch { this.session.status = '无法读取已有配对，请重新连接。'; }
    finally { this.loading = false; }
  }

  async persistComputers(): Promise<void> {
    if (!this.vault) throw new Error('vault_unavailable');
    await this.vault.save({ version: 2, active: this.isPaired ? this.base : '', computers: this.computers });
  }

  onLaunchTicket(): void { void this.consumeLaunchTicket(); }

  async consumeLaunchTicket(): Promise<void> {
    const ticket = this.launchTicket;
    if (!ticket || !/^(\d{8}|[a-f0-9]{64})$/.test(ticket)) return;
    const address = this.address.trim();
    if (!validUsb(address)) return;
    await this.restoreChain;
    for (let attempt = 0; attempt < 40; attempt++) {
      if (this.disposed || this.launchTicket !== ticket) return;
      if (!this.session.busy && !this.session.openingSession) {
        this.launchTicket = '';
        if (!this.addingComputer) this.pairingComputerId = '';
        this.pairingMode = 'usb';
        this.pairingBundle = '';
        this.ticket = ticket;
        await this.pair();
        return;
      }
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 300); });
    }
    this.launchTicket = '';
  }

  onLiveActivityLaunch(): void { void this.consumeLiveActivityLaunch(); }

  async consumeLiveActivityLaunch(): Promise<void> {
    const id = this.liveLaunchSession;
    if (!id) return;
    if (!/^[a-zA-Z0-9._-]{1,200}$/.test(id)) {
      this.liveLaunchSession = '';
      this.liveLaunchAddress = '';
      return;
    }
    await this.restoreChain;
    for (let attempt = 0; attempt < 40; attempt++) {
      if (this.disposed || this.liveLaunchSession !== id) return;
      if (this.visible && !this.loading && !this.session.busy && !this.session.openingSession) {
        const address = this.liveLaunchAddress;
        if (address && address !== this.base) {
          const target = this.computers.find((record: Companion): boolean =>
            validCompanion(record) && record.address === address);
          if (!target) {
            this.liveLaunchSession = '';
            this.liveLaunchAddress = '';
            this.session.status = '实况窗对应的电脑未配对，请重新连接。';
            return;
          }
          this.leaveComputer(false, target);
        }
        if (!this.isPaired) return;
        this.liveLaunchSession = '';
        this.liveLaunchAddress = '';
        this.activeTab = 'tasks';
        this.showFiles = false;
        this.session.showSettings = false;
        this.showSessions = false;
        if (id !== this.session.currentId) await this.sessionActions.requestAction('/open', { id: id });
        else {
          this.streamSync.schedule(0);
          this.streamSync.syncLiveActivity();
        }
        return;
      }
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 300); });
    }
  }

  activateComputer(record: Companion, initialRestore: boolean = false): void {
    const usb = validUsb(record.address);
    this.scheduleController.resetScheduleJobs();
    this.session.epoch += 1;
    this.lastNetworkFailover = 0;
    this.session.syncMode = 'probe';
    this.session.historyStream = '';
    this.session.historyLeaf = undefined;
    this.base = record.address;
    this.connection.activate(record);
    this.pairingMode = usb ? 'usb' : connectionLabel(record) === '公网' ? 'remote' : 'lan';
    if (usb) this.address = record.address;
    this.ticket = '';
    this.pairingBundle = '';
    this.removeTarget = '';
    this.closeComputerEditors();
    this.pairingComputerId = '';
    this.addingComputer = false;
    this.restoringComputer = undefined;
    this.activeTab = initialRestore ? 'inbox' : 'tasks';
    this.minePage = '';
    this.session.status = '';
    this.session.noSession = '正在加载该电脑的会话…';
    this.showSessions = initialRestore ? false : this.windowWidth < SPLIT_WINDOW_WIDTH;
    this.resetCatalog();
    this.session.reachable = false;
    this.isPaired = true;
    this.scheduleController.queueScheduleSync(true);
    if (initialRestore) this.runCenter.queueRunSync(0);
    this.streamSync.schedule(0);
    this.streamSync.stopStream();
  }

  chooseComputer(record: Companion): void {
    if (this.session.busy || this.session.openingSession || this.removeTarget || (this.isPaired && this.base === record.address)) return;
    if (this.isPaired) {
      this.leaveComputer(false, record);
      return;
    }
    this.activateComputer(record);
    void this.persistComputers().catch(() => { this.session.status = '已连接；未能保存本次选择。'; });
  }

  scheduleHost(): ScheduleHost {
    return {
      visible: (): boolean => this.visible,
      base: (): string => this.base,
      activeTab: (): string => this.activeTab,
      computers: (): Companion[] => this.computers,
      projects: (): string[] => this.projects,
      workspaceCwd: (): string => this.session.workspaceCwd,
      settings: (): preferences.Preferences | undefined => this.settings,
      saveSetting: (key: string, value: string | boolean): Promise<void> => this.saveSetting(key, value),
      request: (path: string, input?: Payload, endpoint?: BridgeEndpoint): Promise<BridgeReply> => this.request(path, input, endpoint),
      publishWidgets: (): void => this.publishWidgets(),
      scheduleEndpoint: (computer: Companion): BridgeEndpoint => this.scheduleEndpoint(computer),
      scheduleComputerName: (computer: Companion): string => this.scheduleComputerName(computer),
      getUIContext: (): UIContext => this.getUIContext(),
      dismissKeyboard: (): void => this.dismissKeyboard(),
      queueWatchReminder: (id: string, status: string, computer: string, title: string, finishedAt: number): void =>
        this.runCenter.queueWatchReminder(id, status, computer, title, finishedAt),
      runNoticesEnabled: (): boolean => this.runCenter.state.runNoticesEnabled,
      inboxCleaning: (): boolean => this.runCenter.state.inboxCleaning,
      loading: (): boolean => this.loading,
      isPaired: (): boolean => this.isPaired,
      closeReviewOverlays: (): void => {
        this.runCenter.state.reviewedRun = undefined;
        if (this.fileController.state.markdownTableReader) this.fileController.closeMarkdownTableReader();
      },
      openComputers: (): void => this.openComputers(),
      openNotifiedSession: (target: Companion, id: string, pendingId: string, eventId: string): Promise<boolean> =>
        this.openNotifiedSession(target, id, pendingId, eventId),
      markRunRead: (id: string): void => this.runCenter.markRunRead(id),
      showScheduleInbox: (): void => this.showScheduleInbox(),
      selectRootTab: (tab: string): boolean => this.selectRootTab(tab),
      openWorkspaceFiles: (): boolean => this.openWorkspaceFiles(),
      openNewSession: (): void => this.openNewSession()
    };
  }

  scheduleComputerName(computer: Companion): string {
    const group = computerGroups(this.computers).find((item: ComputerGroup): boolean => item.id === computerGroupId(computer));
    return group ? computerGroupTitle(group) : connectionLabel(computer);
  }

  runCenterHost(): RunCenterHost {
    return {
      appState: this.appState,
      computers: (): Companion[] => this.computers,
      epoch: (): number => this.session.epoch,
      workspaceCwd: (): string => this.session.workspaceCwd,
      currentId: (): string => this.session.currentId,
      visible: (): boolean => this.visible,
      isPaired: (): boolean => this.isPaired,
      reachable: (): boolean => this.session.reachable,
      idle: (): boolean => this.session.idle,
      queued: (): boolean => this.session.queued,
      base: (): string => this.base,
      loading: (): boolean => this.loading,
      busy: (): boolean => this.session.busy,
      openingSession: (): boolean => this.session.openingSession,
      endpoint: (): BridgeEndpoint => this.connection.endpoint(),
      whenRestored: (): Promise<void> => this.restoreChain,
      draftKey: (id: string): string => this.streamSync.draftKey(id),
      request: (path: string, input?: Payload, endpoint?: BridgeEndpoint): Promise<BridgeReply> => this.request(path, input, endpoint),
      publishWidgets: (): void => this.publishWidgets(),
      scheduleEndpoint: (computer: Companion): BridgeEndpoint => this.scheduleEndpoint(computer),
      scheduleComputerName: (computer: Companion): string => this.scheduleComputerName(computer),
      saveSetting: (key: string, value: string | boolean): Promise<void> => this.saveSetting(key, value),
      openNotifiedSession: (target: Companion, id: string, pendingId: string, eventId: string): Promise<boolean> =>
        this.openNotifiedSession(target, id, pendingId, eventId),
      openAlertForAi: (target: Companion, run: RunEvent): Promise<boolean> =>
        this.openAlertForAi(target, run),
      showScheduleInbox: (): void => this.showScheduleInbox(),
      dismissKeyboard: (): void => this.dismissKeyboard(),
      getUIContext: (): UIContext => this.getUIContext(),
      openReferencedFile: (cwd: string, path: string, lookupName: boolean): Promise<void> =>
        this.fileController.openReferencedFile(cwd, path, lookupName),
      celebrate: (): void => {
        this.toolCmd.state.sakuraBurstKind = 'celebrate';
        this.toolCmd.state.sakuraBurstSeq += 1;
        if (this.themeId === 'sakura') this.toolCmd.state.sakuraCelebrateSeq += 1;
      }
    };
  }

  onRunSessionChanged(): void {
    this.voiceComposer.stopReplySpeech();
    this.runCenter.sessionChanged();
  }

  onPushLaunch(): void { void this.runCenter.consumePushLaunch(); }

  async openNotifiedSession(target: Companion, id: string, pendingId: string, eventId: string): Promise<boolean> {
    if (this.session.busy || this.session.openingSession) return false;
    if (target.address !== this.base) this.chooseComputer(target);
    if (!this.isPaired || this.base !== target.address) return false;
    if (this.session.currentId !== id || !this.session.reachable) {
      if (!await this.sessionActions.requestAction('/open', { id: id, history: true })) {
        this.scheduleController.state.scheduleError = this.session.status || '暂时无法打开会话，请检查来源电脑。';
        return false;
      }
    }
    this.activeTab = 'tasks';
    this.showFiles = false;
    this.session.showSettings = false;
    this.inboxSelecting = false;
    this.showSessions = false;
    const key = this.streamSync.draftKey(id);
    if (pendingId) {
      this.scheduleController.state.schedulePage = '';
      try {
        const result = await this.request('/session/snapshot');
        if (key !== this.streamSync.draftKey(this.session.currentId)) return false;
        if (result.session?.id === id) {
          this.setInteraction(result.interaction);
          if (result.interaction?.id !== pendingId) {
            this.getUIContext().getPromptAction().showToast({ message: '这条待处理请求已结束或在其他设备上处理。' });
          }
        }
      } catch { this.streamSync.schedule(0); }
    }
    await this.runCenter.syncRunResults(this.connection.endpoint(), id, key);
    let openedRun: RunEvent | undefined = undefined;
    if (!pendingId && key === this.streamSync.draftKey(this.session.currentId) && this.runCenter.state.sessionRunKey === key) {
      openedRun = this.runCenter.state.sessionRuns.find((row: RunEvent): boolean => row.id === eventId);
      if (openedRun) this.runCenter.openRunResult(openedRun);
    }
    if (this.scheduleController.state.schedulePage) {
      if (openedRun) {
        const openedId = openedRun.id;
        setTimeout(() => {
          if (this.runCenter.state.reviewedRun?.id === openedId) {
            this.scheduleController.state.schedulePage = '';
          }
        }, 260);
      } else {
        this.scheduleController.state.schedulePage = '';
      }
    }
    return true;
  }

  async openAlertForAi(target: Companion, run: RunEvent): Promise<boolean> {
    if (this.session.busy || this.session.openingSession || !run.cwd) return false;
    if (target.address !== this.base) this.chooseComputer(target);
    if (!this.isPaired || this.base !== target.address) return false;
    const preferredAgent = this.runCenter.alertSourceDefaultAgent(run.source ?? '');
    const newPayload: Payload = preferredAgent ? { cwd: run.cwd, agent: preferredAgent } : { cwd: run.cwd };
    if (!await this.sessionActions.requestAction('/new', newPayload)) {
      this.scheduleController.state.scheduleError = this.session.status || '暂时无法在该工作区创建会话，请检查来源电脑。';
      return false;
    }
    this.activeTab = 'tasks';
    this.showFiles = false;
    this.session.showSettings = false;
    this.inboxSelecting = false;
    this.showSessions = false;
    this.scheduleController.state.schedulePage = '';
    const prompt = run.suggestedPrompt?.trim() ||
      `请结合当前工作区，分析这条提醒：\n${run.title ?? '工作区提醒'}${run.body ? '\n' + run.body : ''}`;
    this.session.draft = prompt;
    this.streamSync.rememberDraft(this.session.currentId);
    return true;
  }

  citeRunLine(line: DiffLine): void {
    const file = this.runCenter.state.reviewedFile;
    if (!file || this.runCenter.state.reviewedRun?.sessionId !== this.session.currentId || line.line < 1) return;
    const reference = `请检查 ${file.path}:${line.line}（本轮 Diff）：\n${line.text.slice(1, 501)}`;
    this.session.draft = this.session.draft ? this.session.draft + '\n\n' + reference : reference;
    this.streamSync.rememberDraft(this.session.currentId);
    this.runCenter.backFromRunResult();
    this.runCenter.backFromRunResult();
  }

  scheduleEndpoint(computer: Companion): BridgeEndpoint {
    return { address: computer.address, token: computer.token, ca: computer.ca, pin: computer.pin };
  }

  publishWidgets(): void {
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    const computer = this.computerTitle();
    const snapshot = buildWidgetSnapshot({
      inbox: this.runCenter.displayedInboxRuns(),
      scheduleMessages: this.scheduleController.state.scheduleMessages,
      jobs: this.scheduleController.state.scheduleJobs,
      runningRows: this.taskPanelRows(),
      activeSchedules: this.standaloneScheduleRuns(),
      running: this.runningTaskCount(),
      syncedAt: this.computers.length ? Date.now() : 0,
      paired: this.isPaired || this.computers.length > 0,
      reachable: this.session.reachable,
      address: this.base,
      computer: computer,
      pairedComputer: this.computers.length ? computer : '',
      workspace: this.session.project || (this.session.workspaceCwd ? this.workspaceName(this.session.workspaceCwd) : ''),
      currentSessionId: this.session.currentId,
      currentSessionTitle: this.session.currentId && !this.session.noSession ? this.chatTitle() : '',
      sessionState: (id: string): string => this.sessionState(id),
      stateLabel: (state: string): string => this.stateLabel(state),
      workspaceName: (cwd: string): string => this.workspaceName(cwd)
    });
    void this.inboxWidget.publish(context, snapshot);
  }

  onInboxFormLaunch(): void {
    this.scheduleController.consumeFormLaunch(this.appState);
  }

  showScheduleInbox(): void {
    this.dismissKeyboard();
    this.scheduleController.state.scheduleBanner = undefined;
    this.scheduleController.state.schedulePage = '';
    this.scheduleController.state.scheduleAlert = undefined;
    this.selectRootTab('inbox');
    this.scheduleController.queueScheduleSync(true);
    this.runCenter.queueRunSync(0);
    void this.loadSessionStatus();
  }

  async openScheduledSession(message: RunMessage): Promise<void> {
    if (!message.run.sessionId || this.session.busy || this.session.openingSession) return;
    const computer = this.computers.find((item: Companion): boolean => item.address === message.address);
    if (!computer) { this.scheduleController.state.scheduleError = '请先配对来源电脑。'; return; }
    this.scheduleController.state.scheduleError = '';
    if (this.base !== computer.address) this.chooseComputer(computer);
    if (this.base !== computer.address) { this.scheduleController.state.scheduleError = '无法切换到来源电脑。'; return; }
    if (await this.sessionActions.requestAction('/open', { id: message.run.sessionId })) {
      this.activeTab = 'tasks';
      this.scheduleController.state.schedulePage = '';
    } else this.scheduleController.state.scheduleError = this.session.status || '暂时无法打开会话，请检查来源电脑的连接。';
  }

  stopNetworkMonitor(): void {
    this.connection.stopWatchingNetwork();
    if (this.networkTimer !== -1) clearTimeout(this.networkTimer);
    this.networkTimer = -1;
  }

  onNetworkChange(): void {
    if (!this.visible) return;
    if (this.networkTimer !== -1) clearTimeout(this.networkTimer);
    this.networkTimer = setTimeout((): void => {
      this.networkTimer = -1;
      this.lastNetworkFailover = 0;
      if (this.isPaired && !validUsb(this.base)) {
        this.streamSync.stopStream();
        this.streamSync.startStream();
        this.streamSync.schedule(0);
      }
      this.runCenter.queueRunSync(500);
      this.scheduleController.queueScheduleSync(true);
    }, 400);
  }

  canSwitchNetwork(): boolean {
    return this.visible && this.isPaired && !this.session.reachable && !this.session.busy && !this.session.openingSession &&
      !this.session.pendingSend && !this.fileController.state.editingPath && !this.removeTarget && !this.scheduleController.state.scheduleSaving &&
      !this.sessionActions.creation.showNewSession && !this.sessionActions.creation.showNewSpace && !this.session.showSettings && this.scheduleController.state.schedulePage !== 'editor' &&
      !this.fileController.state.textFilePreview && !this.fileController.state.markdownTableReader && !this.runCenter.state.reviewedRun &&
      this.activeTab === 'tasks' && !this.voiceComposer.state.recording && !this.voiceComposer.state.voicePreparing && !this.voiceComposer.state.voiceFinishing;
  }

  async tryPublicConnection(): Promise<void> {
    if (!this.canSwitchNetwork() || this.switchingNetwork || Date.now() - this.lastNetworkFailover < 15000) return;
    const active = this.computers.find((item: Companion): boolean => item.address === this.base);
    if (!active || connectionLabel(active) !== 'Wi-Fi') return;
    const alternatives = this.computers.filter((item: Companion): boolean =>
      computerGroupId(item) === computerGroupId(active) && connectionLabel(item) === '公网' && validCompanion(item));
    if (!alternatives.length) return;
    this.switchingNetwork = true;
    this.lastNetworkFailover = Date.now();
    const epoch = this.session.epoch;
    const session = this.session.currentId;
    const oldKey = this.streamSync.draftKey(session);
    try {
      for (const target of alternatives) {
        const newKey = `${target.address}|${session}`;
        let remote: BridgeReply;
        try {
          remote = await this.request('/session', undefined, this.scheduleEndpoint(target));
        } catch { continue; }
        if (epoch !== this.session.epoch || !this.canSwitchNetwork() || session !== this.session.currentId) return;
        if (!this.computers.some((item: Companion): boolean =>
          item.address === target.address && item.token === target.token &&
          computerGroupId(item) === computerGroupId(active))) continue;
        const targetDraft = this.chatState.drafts.get(newKey);
        const targetAttachments = this.chatState.draftAttachments.get(newKey);
        // Leave independent drafts and an unconfirmed send accessible at their original endpoints.
        if (this.chatState.unconfirmed.has(newKey) || (this.session.draft && targetDraft) ||
            (this.session.attachments.length && targetAttachments?.length)) continue;
        const text = this.session.draft;
        const attachments = this.session.attachments;
        this.leaveComputer(false, target);
        if (session && text) {
          this.chatState.drafts.set(newKey, text);
          this.chatState.drafts.delete(oldKey);
        }
        if (session && attachments.length) {
          this.chatState.draftAttachments.set(newKey, attachments);
          this.chatState.draftAttachments.delete(oldKey);
        }
        if (session && remote.session?.id !== session) await this.sessionActions.requestAction('/open', { id: session });
        else if (session) this.showSessions = false;
        return;
      }
    } finally { this.switchingNetwork = false; }
  }

  streamSyncHost(): StreamSyncHost {
    return {
      session: this.session,
      connection: (): ConnectionManager => this.connection,
      chatState: (): ChatState => this.chatState,
      client: (): PiGoClient => this.client,
      isPaired: (): boolean => this.isPaired,
      visible: (): boolean => this.visible,
      base: (): string => this.base,
      streamPath: (path: string): string =>
        this.session.currentId && this.session.workspaceCwd
          ? panePath(path, this.session.currentId, this.session.workspaceCwd)
          : path,
      liveViewsEnabled: (): boolean => this.liveViewsEnabled,
      selectedTool: (): LiveTool | undefined => this.toolCmd.state.selectedTool,
      selectedToolMessageId: (): string => this.toolCmd.selectedToolMessageId,
      request: (path: string, input?: Payload): Promise<BridgeReply> => this.request(path, input),
      leaveComputer: (forget: boolean): void => this.leaveComputer(forget),
      refreshSelectedTool: (tool: LiveTool, message: string = ''): void => this.toolCmd.refreshSelectedTool(tool, message),
      chatTitle: (): string => this.chatTitle(),
      closeToolDetails: (): void => this.toolCmd.closeToolDetails(),
      resetVoice: (): void => this.voiceComposer.resetVoice(),
      updateCachedSessionTitle: (id: string, name?: string): void => this.updateCachedSessionTitle(id, name),
      workspaceChanged: (): void => {
        this.fileController.resetFileTree();
        if (this.showFiles) { this.showFiles = false; this.activeTab = 'tasks'; }
      },
      showChat: (): void => {
        this.showFiles = false;
        this.activeTab = 'tasks';
      },
      resetCommands: (): void => this.toolCmd.resetCommands(),
      observeSessionRun: (session: SessionState): void => this.observeSessionRun(session),
      syncCommandPalette: (): void => this.toolCmd.syncCommandPalette(),
      setInteraction: (interaction?: PendingInteraction): void => this.setInteraction(interaction),
      reconcileSteering: (settled: boolean): void => this.sessionActions.reconcileSteering(settled),
      tryPublicConnection: (): Promise<void> => this.tryPublicConnection(),
      getUIContext: (): UIContext => this.getUIContext(),
      restoreOnlineNotice: (): void => { this.offlineDismissed = false; },
      refreshVisibleCatalog: (connected: boolean): void => this.refreshVisibleCatalog(connected),
      hasBackgroundTasks: (): boolean => this.backgroundActive() || this.activeTab === 'pending',
      sessionDeleted: (id: string): void => this.sessionDeleted(id),
      showTextPreview: (cwd: string, path: string, text: string): void => this.fileController.showTextPreview(cwd, path, text),
      observeRun: (id: string, title: string, active: boolean, stopped: boolean = false): void => {
        if (!active) this.clearFinishedRunningSession(id);
        this.runCenter.observeRun(id, title, active, stopped);
      },
      requestPermissionAfterDispatch: (): void => this.runCenter.requestPermissionAfterDispatch(),
      publishLiveActivity: (snapshot?: LiveActivitySnapshot): void =>
        liveActivity.sync(snapshot, this.getUIContext?.()?.getHostContext?.() as common.UIAbilityContext | undefined)
    };
  }

  splitPaneHost(): SplitPaneHost {
    return {
      session: this.session,
      transcript: this.transcript,
      client: this.client,
      chatState: this.chatState,
      connection: this.connection,
      sessionActions: this.sessionActions,
      fileController: this.fileController,
      base: (): string => this.base,
      isPaired: (): boolean => this.isPaired,
      windowWidth: (): number => this.windowWidth,
      windowHeight: (): number => this.windowHeight,
      keyboardHeight: (): number => this.keyboardHeight,
      chatTitle: (): string => this.chatTitle(),
      createBaseStreamHost: (): StreamSyncHost => this.streamSyncHost(),
      request: (path: string, input?: Payload, endpoint?: BridgeEndpoint): Promise<BridgeReply> => this.request(path, input, endpoint),
      getUIContext: (): UIContext => this.getUIContext(),
      dismissKeyboard: (): void => this.dismissKeyboard(),
      setDrawer: (open: boolean): void => this.setDrawer(open),
      showTasksTab: (): void => {
        this.activeTab = 'tasks';
        this.minePage = '';
        this.session.showSettings = false;
        this.showFiles = false;
      },
      leaveComputer: (revoked?: boolean): void => this.leaveComputer(revoked)
    };
  }

  toolCommandHost(): ToolCommandHost {
    return {
      session: this.session,
      voiceState: this.voiceComposer.state,
      sessionActions: this.sessionActions,
      request: (path: string, input?: Payload): Promise<BridgeReply> => this.request(path, input),
      dismissKeyboard: (): void => this.dismissKeyboard(),
      leaveComputer: (revoked?: boolean): void => this.leaveComputer(revoked),
      themeId: (): string => this.themeId,
      themeMotionEnabled: (): boolean => this.themeMotionEnabled,
      canObserveSakuraTap: (): boolean => !this.voiceComposer.state.recording && !this.voiceComposer.holding() && !this.sessionPaneDragging && !this.drawerOpen()
    };
  }

  refreshVisibleCatalog(connected: boolean): void {
    const libraryVisible = this.showSessions || this.dockedSessions();
    const catalogStale = Date.now() - this.sessionCatalogUpdatedAt >= 30000;
    const probingAgents = this.sessionActions.creation.showNewSession && this.agents.some((agent: AgentInfo): boolean => agent.installed === undefined);
    if ((libraryVisible || this.sessionActions.creation.showNewSession) && (connected || (!this.sessionCatalogFailed &&
      (!this.sessionCatalogLoaded || probingAgents || (catalogStale && (this.sessionView === 'all' || this.sessionActions.creation.showNewSession))))) && !this.session.busy) {
      void this.loadSessions();
    }
    if (libraryVisible) {
      this.sessionStatusAt = Date.now();
      void this.loadSessionStatus();
    } else if (this.backgroundActive() || Date.now() - this.sessionStatusAt >= 5000) {
      // Keep every running task visible on the chat header even with the drawer closed;
      // slow probing detects tasks started on the computer.
      this.sessionStatusAt = Date.now();
      void this.loadSessionStatus();
    }
  }

  sessionDeleted(id: string): void {
    this.clearFinishedRunningSession(id);
    this.sessions = this.sessions.filter((row: SessionRow): boolean => row.id !== id);
    this.chatState.deleteTranscriptCache(this.streamSync.draftKey(id));
    if (this.session.currentId === id) {
      this.showSessions = !this.dockedSessions();
      void this.loadSessions();
    }
  }

  paneRouteTarget(path: string, input?: Payload): string {
    if (path.includes('pane=') || !this.session.currentId || !this.session.workspaceCwd) return path;
    const basePath = path.split('?')[0];
    if (!PANE_ROUTES.includes(basePath)) return path;
    if (PANE_ACTIONS.includes(basePath) && input?.id && input.id !== this.session.currentId) return path;
    return panePath(path, this.session.currentId, this.session.workspaceCwd);
  }

  async request(path: string, input?: Payload, endpoint?: BridgeEndpoint): Promise<BridgeReply> {
    if (!endpoint) path = this.paneRouteTarget(path, input);
    return this.client.request(endpoint ?? this.connection.endpoint(), path, input);
  }

  async pair(): Promise<void> {
    if (this.session.busy || this.session.openingSession) return;
    const profile = this.accountSync.state.huaweiProfile;
    let pairing: PairingRequest;
    try {
      pairing = this.connection.pairingRequest(this.pairingMode, this.address, this.ticket, this.pairingBundle, this.computers);
    } catch (error) {
      this.session.status = (error as Error).message;
      return;
    }
    const base = pairing.endpoint.address;
    this.session.busy = true;
    this.session.status = '';
    try {
      const credentials = await this.connection.pair(pairing,
        (path: string, input: Payload, endpoint: BridgeEndpoint): Promise<BridgeReply> => this.request(path, input, endpoint));
      const record = this.connection.pairedComputer(pairing.endpoint, credentials, this.computers, this.pairingComputerId,
        (): string => util.generateRandomUUID());
      if (!this.isPaired || this.base !== base) this.forgetDrafts(base);
      this.computers = [record, ...this.computers.filter((item: Companion): boolean => item.address !== base)];
      if (this.isPaired) this.leaveComputer(false, record);
      else {
        this.activateComputer(record);
        try { await this.persistComputers(); }
        catch { this.session.status = '已连接；凭证未能保存。'; }
      }
      if (profile && this.accountSync.state.huaweiProfile === profile) {
        this.accountSync.updateCloudComputer(base, validUsb(base) ? 'usb' : connectionLabel(record) === '公网' ? 'remote' : 'lan');
      }
    } catch (error) {
      this.session.status = error instanceof BridgeFailure && error.status === 401 ? '配对码已经失效，请在电脑上重新生成。' :
        this.pairingMode !== 'usb' ? '无法建立安全连接。请检查网络、电脑地址和配对码。' : '无法连接电脑，请确认 USB 转发和 Pi Go 桥接服务。';
    } finally { this.session.busy = false; }
  }

  selectPairingMode(mode: string): void {
    if (mode === this.pairingMode) return;
    this.pairingMode = mode;
    if (mode === 'usb') {
      if (!validUsb(this.address)) this.address = USB_ADDRESS;
    } else if (validUsb(this.address)) {
      this.address = '';
    }
    this.session.status = '';
    this.pairingBundle = '';
    this.lanCandidates = [];
    this.ticket = '';
    if (mode === 'lan') void this.findLanCompanions();
  }

  async scanPairingBundle(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context || this.session.busy) return;
    this.session.busy = true;
    this.session.status = '';
    let scanned = false;
    try {
      const result = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: true
      });
      const bundle = decodePairingBundle(result.originalValue, this.pairingMode === 'remote');
      this.pairingBundle = result.originalValue;
      this.address = bundle.url;
      this.ticket = /^\d{6}$/.test(bundle.ticket) ? bundle.ticket : '';
      scanned = true;
    } catch {
      this.session.status = this.pairingMode === 'remote' ? '未识别公网配对码，请扫描 Pi Go.app「公网」二维码。' :
        '未识别局域网配对码，请扫描 Pi Go.app「局域网」二维码。';
    }
    finally { this.session.busy = false; }
    if (scanned) await this.pair();
  }

  async findLanCompanions(): Promise<void> {
    if (this.session.busy || this.session.openingSession) return;
    this.session.busy = true;
    this.lanCandidates = [];
    this.session.status = '';
    try {
      this.lanCandidates = await this.connection.discover();
      if (this.lanCandidates.length === 1 && (!this.address || validUsb(this.address))) {
        this.address = this.lanCandidates[0];
      }
      if (!this.lanCandidates.length) this.session.status = '未发现电脑，请确认在同一 Wi-Fi，或手动输入电脑地址。';
    } catch { this.session.status = '自动发现不可用，可手动输入电脑地址或扫码。'; }
    finally { this.session.busy = false; }
  }

  leaveComputer(revoked: boolean = false, next?: Companion): void {
    if (this.split.launchedNativeWindow || this.split.openingNativeWindow) closeConversationWindows(this.base);
    if (this.split.state.splitOpen) this.split.clearSplit();
    if (this.fileController.state.markdownTableReader) this.fileController.closeMarkdownTableReader();
    this.fileController.state.textFilePreview = undefined;
    this.toolCmd.closeToolDetails();
    const address = this.base;
    if (this.session.currentId) this.streamSync.rememberDraft(this.session.currentId);
    this.session.epoch += 1;
    if (!next) this.scheduleController.resetScheduleJobs();
    this.streamSync.cancelSchedule();
    this.streamSync.stopStream();
    this.base = '';
    this.connection.disconnect();
    this.pairingBundle = '';
    this.session.currentId = '';
    this.toolCmd.resetCommands();
    this.session.pendingSessionReveal = '';
    this.session.noSession = '';
    this.session.project = '';
    this.session.workspaceCwd = '';
    this.showFiles = false;
    if (!next && this.activeTab !== 'mine') {
      this.activeTab = 'mine';
      this.minePage = 'computers';
    }
    this.addingComputer = false;
    this.pairingComputerId = '';
    this.offlineDismissed = false;
    this.fileController.closeFileEditor();
    this.fileController.resetFileTree();
    this.session.sessionName = '';
    this.session.liveText = '';
    this.session.liveThinking = '';
    this.session.liveThinkSeq = 0;
    this.session.liveThinkingOpen = false;
    this.session.thinkingOpenIds = [];
    this.session.liveTools = [];
    this.session.liveSeq = 0;
    this.session.messages = [];
    this.sessions = [];
    this.chatState.forgetTranscriptCache();
    this.runningSessionIds = [];
    this.runningSessions = [];
    this.runCenter.clearObservedRuns();
    this.runCenter.clearRunNotices();
    this.session.draft = '';
    this.showSessions = false;
    this.session.showSettings = false;
    this.session.models = [];
    this.session.modelLabel = '';
    this.setInteraction();
    this.session.pendingSend = undefined;
    this.hostAvailable = false;
    this.canCreateWorkspace = false;
    this.sessionActions.creation.showNewSpace = false;
    this.sessionActions.creation.newSpaceName = '';
    this.sessionActions.creation.newSpaceError = '';
    this.projects = [];
    this.workspaces = [];
    this.resetCatalog();
    this.isPaired = false;
    this.session.idle = true;
    this.session.runId = '';
    this.session.queued = false;
    this.session.acceptsImage = false;
    this.session.attachments = [];
    this.voiceComposer.resetVoice();
    this.voiceComposer.state.voiceMode = false;
    this.session.reachable = false;
    if (revoked) {
      this.computers = this.computers.filter((record: Companion): boolean => record.address !== address);
      this.forgetDrafts(address);
      this.runCenter.queueRunSync(0);
    }
    this.session.status = revoked ? '该电脑的配对已撤销，请重新连接。' : '';
    if (next) this.activateComputer(next);
    this.streamSync.syncLiveActivity();
    void this.persistComputers().catch(() => { this.session.status = '无法保存电脑列表的本次更改。'; });
  }

  removeComputer(address: string): void {
    if (this.removeTarget !== address || this.session.busy || this.session.openingSession) return;
    this.removeTarget = '';
    if (this.accountSync.state.huaweiProfile) this.accountSync.updateCloudComputer(address, '');
    const removed = this.computers.find((item: Companion): boolean => item.address === address);
    if (removed) {
      void this.request('/runs/push', { enabled: false }, this.scheduleEndpoint(removed)).catch(() => {});
      this.runCenter.forgetPushRegistration(address);
    }
    this.computers = this.computers.filter((record: Companion): boolean => record.address !== address);
    this.runCenter.queueRunSync(0);
    if (this.isPaired && this.base === address) {
      this.leaveComputer();
      this.forgetDrafts(address);
      return;
    }
    this.forgetDrafts(address);
    void this.persistComputers().catch(() => { this.session.status = '无法保存电脑列表的本次更改。'; });
  }

  forgetDrafts(address: string): void {
    this.session.queuedSteering = this.session.queuedSteering.filter((item: QueuedSteering): boolean => !item.sessionKey.startsWith(`${address}|`));
    this.session.optimisticMessages = this.session.optimisticMessages.filter((item: OptimisticMessage): boolean => !item.sessionKey.startsWith(`${address}|`));
    this.chatState.forgetDrafts(address);
  }

  clearFinishedRunningSession(id: string): void {
    if (!id) return;
    if (this.runningSessionIds.includes(id)) {
      this.runningSessionIds = this.runningSessionIds.filter((item: string): boolean => item !== id);
    }
    if (this.runningSessions.some((row: RunningRow): boolean => row.id === id)) {
      this.runningSessions = this.runningSessions.filter((row: RunningRow): boolean => row.id !== id);
    }
  }

  async loadSessionStatus(): Promise<void> {
    if (!this.session.reachable || this.sessionStatusLoading) return;
    const epoch = this.session.epoch;
    const selected = this.session.currentId;
    const liveRevision = this.session.liveRevision;
    this.sessionStatusLoading = true;
    try {
      const result = await this.request('/sessions/status');
      if (epoch === this.session.epoch) this.applyRunningStatus(result, selected, liveRevision);
    } catch {
      if (epoch === this.session.epoch) this.applyRunningStatus(undefined);
    } finally { this.sessionStatusLoading = false; }
  }

  applyRunningStatus(result?: BridgeReply, selected: string = this.session.currentId, liveRevision?: number): void {
    const settledCurrent = !!selected && selected === this.session.currentId &&
      liveRevision !== undefined && liveRevision !== this.session.liveRevision &&
      this.session.idle && !this.session.queued;
    const rows = (result?.runningSessions ?? []).filter((row: RunningRow): boolean => !!row?.id && (!settledCurrent || row.id !== selected));
    this.runningSessions = rows;
    for (const row of rows) {
      if (row.id !== this.session.currentId) this.updateCachedSessionTitle(row.id, row.name);
    }
    const ids = rows.map((row: RunningRow): string => row.id)
      .concat((result?.runningSessionIds ?? []).filter((id: string): boolean => !settledCurrent || id !== selected));
    this.runningSessionIds = ids.filter((id: string, index: number): boolean => ids.indexOf(id) === index);
    if (result?.idleSessionIds) {
      for (const row of this.backgroundRunning()) {
        if (row.id !== selected && row.started !== false) this.runCenter.observeRun(row.id, row.name || '后台任务', true);
      }
      this.runCenter.reconcileObservedRuns(result.idleSessionIds, this.runningSessionIds, selected);
    }
  }

  observeSessionRun(session: SessionState): void {
    // A dispatched prompt can make the session busy before Pi starts a run.
    if (!session.idle && !session.runId && !session.queued) return;
    if (session.idle && !session.queued) this.clearFinishedRunningSession(session.id);
    const title = session.name || this.sessions.find((row: SessionRow): boolean => row.id === session.id)?.name ||
      (session.id === this.session.currentId ? this.chatTitle() : '任务');
    this.runCenter.observeRun(session.id, title, !session.idle || session.queued === true);
  }

  backgroundActive(): boolean {
    return this.runningSessionIds.some((id: string): boolean => id !== this.session.currentId);
  }

  backgroundRunning(): RunningRow[] {
    // Prefer named rows from new bridges; legacy bridges only send ids, so synthesize rows
    // and fall back to the cached catalog name for the pill label.
    const rows = this.runningSessions.filter((row: RunningRow): boolean => row.id !== this.session.currentId);
    const known = new Set<string>(rows.map((row: RunningRow): string => row.id));
    const extras: RunningRow[] = this.runningSessionIds
      .filter((id: string): boolean => id !== this.session.currentId && !known.has(id))
      .map((id: string): RunningRow => ({ id: id }));
    return rows.concat(extras).map((row: RunningRow): RunningRow => ({
      id: row.id,
      name: row.name || this.sessions.find((session: SessionRow): boolean => session.id === row.id)?.name,
      cwd: row.cwd,
      started: row.started
    }));
  }

  sessionRunning(id: string): boolean {
    return this.session.reachable && (id === this.session.currentId ? !this.session.idle || this.session.queued : this.runningSessionIds.includes(id));
  }

  // Keep the current session first, followed by background sessions.
  allRunningRows(): RunningRow[] {
    const current: RunningRow[] = [];
    if (this.session.currentId && this.sessionRunning(this.session.currentId)) {
      current.push({
        id: this.session.currentId,
        name: this.chatTitle(),
        cwd: this.session.workspaceCwd || undefined
      });
    }
    return current.concat(this.backgroundRunning());
  }

  taskPanelRows(): RunningRow[] {
    const rows = this.allRunningRows();
    for (const row of rows) row.state = this.sessionState(row.id);
    return rows;
  }

  standaloneScheduleRuns(): RunMessage[] {
    if (!this.session.reachable) return [];
    const sessions = this.allRunningRows();
    return this.scheduleController.state.scheduleActive.filter((row: RunMessage): boolean => isCurrentScheduleComputer(this.computers, this.base, row) &&
      !sessions.some((session: RunningRow): boolean => session.id === row.run.sessionId));
  }

  runningTaskCount(): number {
    return this.session.reachable ? this.allRunningRows().length + this.standaloneScheduleRuns().length : 0;
  }

  inboxBadgeCount(): number {
    const unreadRuns = this.runCenter.displayedInboxRuns().filter((item: InboxRun): boolean =>
      item.unread || item.run.status === 'waiting').length;
    const unreadSchedules = this.scheduleController.state.scheduleMessages.filter((item: RunMessage): boolean =>
      !item.dismissed && item.unread).length;
    return unreadRuns + unreadSchedules;
  }

  markAllInboxRead(): void {
    for (const row of this.runCenter.displayedInboxRuns()) {
      if (row.unread) this.runCenter.markRunRead(row.run.id);
    }
    const sources = new Map<string, string[]>();
    for (const message of this.scheduleController.state.scheduleMessages) {
      if (!message.unread) continue;
      const list = sources.get(message.source) ?? [];
      list.push(message.run.id);
      sources.set(message.source, list);
    }
    if (sources.size > 0) {
      this.scheduleController.state.scheduleMessages = this.scheduleController.state.scheduleMessages.map((item: RunMessage): RunMessage =>
        item.unread ? { key: item.key, source: item.source, address: item.address, computer: item.computer, run: item.run, unread: false, dismissed: item.dismissed } : item);
      sources.forEach((ids: string[], source: string) => {
        void this.saveSetting(`schedule_read_${source}`, JSON.stringify(ids.slice(0, 80))).catch(() => {});
      });
    }
    this.publishWidgets();
  }

  inboxHeaderMenu(): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: '刷新动态',
        action: () => {
          this.scheduleController.queueScheduleSync(true);
          this.runCenter.queueRunSync(0);
          void this.loadSessionStatus();
        }
      }
    ];
    if (this.inboxBadgeCount() > 0) {
      items.push({
        value: '全部标为已读',
        action: () => { this.markAllInboxRead(); }
      });
    }
    items.push({
      value: this.inboxSelecting ? '退出批量管理' : '批量管理',
      action: () => { this.inboxSelecting = !this.inboxSelecting; }
    });
    return items;
  }

  // Fine-grained state for pills and badges: streaming / waiting / queued.
  sessionState(id: string): string {
    if (!this.session.reachable) return '';
    if (id === this.session.currentId) {
      if (this.session.interaction) return 'waiting';
      if (this.session.queued) return 'queued';
      return this.session.idle ? '' : 'streaming';
    }
    const row = this.runningSessions.find((item: RunningRow): boolean => item.id === id);
    if (row?.state) return row.state;
    return this.runningSessionIds.includes(id) ? 'streaming' : '';
  }

  runningSessionPills(): RunningSessionPill[] {
    return this.backgroundRunning().map((row: RunningRow): RunningSessionPill => {
      const state = this.sessionState(row.id);
      return { id: row.id, name: row.name, label: this.stateLabel(state), color: this.stateColor(state) };
    });
  }

  stateColor(state: string): Resource {
    if (state === 'waiting') return $r('app.color.pigo_warning');
    if (state === 'queued') return $r('app.color.pigo_queued');
    return $r('app.color.pigo_success');
  }

  stateLabel(state: string): string {
    if (state === 'waiting') return '待处理';
    if (state === 'queued') return '排队中';
    return '运行中';
  }

  async loadSessions(more: boolean = false, refresh: boolean = false): Promise<void> {
    if (this.session.busy || this.session.openingSession || this.sessionLoading || (more && this.sessionNextCursor === undefined)) return;
    const connection = this.catalogConnection;
    const version = this.sessionCatalogVersion;
    const view = this.sessionView;
    const current = (): boolean => connection === this.catalogConnection && version === this.sessionCatalogVersion;
    this.sessionLoading = true;
    this.sessionCatalogFailed = false;
    try {
      const catalog = await this.sessionStore.loadCatalog(view, (path: string): Promise<BridgeReply> => this.request(path),
        more ? this.sessionNextCursor : 0, '', refresh);
      if (!current()) return;
      this.sessionCatalogUpdatedAt = Date.now();
      this.applyCatalog(catalog, view, more);
      if (refresh && view === 'all') {
        const spaces = this.expandedSpaces.filter((path: string): boolean => this.projects.includes(path));
        await Promise.all(spaces.map((path: string): Promise<void> => this.loadWorkspacePage(path, false, true)));
      }
    } catch (error) {
      if (!current()) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else this.sessionCatalogFailed = true;
    } finally {
      if (connection === this.catalogConnection) this.sessionLoading = false;
    }
  }

  applyCatalog(catalog: SessionCatalog, view: string, more: boolean): void {
    const result = catalog.reply;
    this.sessions = more ? this.appendSessionPage(this.sessions, catalog.sessions) : catalog.sessions;
    this.sessionNextCursor = result.nextCursor;
    this.loadedView = view;
    this.workspaces = result.workspaces ?? [];
    this.projects = this.workspaces.map((workspace: WorkspaceRow): string => workspace.cwd);
    this.workspacePages = this.workspacePages.filter((page: WorkspacePage): boolean => this.projects.includes(page.path));
    this.hostAvailable = result.desktopHandoff ?? false;
    this.canCreateWorkspace = result.canCreateWorkspace ?? false;
    this.agents = this.hostAvailable ? result.agents ?? [{ id: 'pi', label: 'Pi', installed: true }] : [];
    if (this.sessionActions.creation.showNewSession) {
      if (!this.sessionActions.creation.newSessionFixedWorkspace && !this.projects.includes(this.sessionActions.creation.newSessionCwd)) {
        this.sessionActions.creation.newSessionCwd = this.projects.includes(this.session.workspaceCwd) ? this.session.workspaceCwd : this.projects[0] ?? '';
      }
      if (!this.sessionActions.creation.newSessionAgent) this.sessionActions.creation.newSessionAgent = this.defaultNewSessionAgent(this.sessionActions.creation.newSessionPreferredAgent);
    }
    this.sessionCatalogLoaded = true;
  }

  appendSessionPage(rows: SessionRow[], page: SessionRow[]): SessionRow[] {
    const ids = new Set<string>(rows.map((row: SessionRow): string => row.id));
    return rows.concat(page.filter((row: SessionRow): boolean => !ids.has(row.id)));
  }

  setWorkspacePage(page: WorkspacePage): void {
    this.workspacePages = this.workspacePages.filter((item: WorkspacePage): boolean => item.path !== page.path).concat([page]);
  }

  loadMoreSidebarSessions(path: string): void {
    if (!path) void this.loadSessions(true);
    else {
      const page = this.workspacePages.find((item: WorkspacePage): boolean => item.path === path);
      const retryRefresh = page?.retryRefresh === true;
      void this.loadWorkspacePage(path, !retryRefresh && page?.nextCursor !== undefined, retryRefresh);
    }
  }

  async loadWorkspacePage(path: string, more: boolean = false, refresh: boolean = false): Promise<void> {
    const previous = this.workspacePages.find((page: WorkspacePage): boolean => page.path === path);
    if (!this.session.reachable || (previous?.loading && !refresh) || (more && previous?.nextCursor === undefined)) return;
    const connection = this.catalogConnection;
    const requestId = ++this.workspacePageRequestId;
    const current = (): boolean => connection === this.catalogConnection && this.projects.includes(path) &&
      this.workspacePages.some((item: WorkspacePage): boolean => item.path === path && item.requestId === requestId);
    const page: WorkspacePage = {
      path: path, sessions: previous?.sessions ?? [], nextCursor: previous?.nextCursor,
      loading: true, failed: false, requestId: requestId
    };
    this.setWorkspacePage(page);
    try {
      const catalog = await this.sessionStore.loadCatalog('all', (address: string): Promise<BridgeReply> => this.request(address),
        more ? page.nextCursor : 0, path, refresh);
      if (!current()) return;
      this.setWorkspacePage({
        path: path, sessions: more ? this.appendSessionPage(page.sessions, catalog.sessions) : catalog.sessions,
        nextCursor: catalog.reply.nextCursor, loading: false, failed: false
      });
    } catch (error) {
      if (!current()) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else this.setWorkspacePage({
        path: path, sessions: page.sessions, nextCursor: page.nextCursor,
        loading: false, failed: true, retryRefresh: refresh
      });
    }
  }

  workspaceFileHost(): WorkspaceFileHost {
    return {
      busy: (): boolean => this.session.busy,
      setBusy: (value: boolean): void => { this.session.busy = value; },
      openingSession: (): boolean => this.session.openingSession,
      reachable: (): boolean => this.session.reachable,
      epoch: (): number => this.session.epoch,
      currentId: (): string => this.session.currentId,
      workspaceCwd: (): string => this.session.workspaceCwd,
      base: (): string => this.base,
      endpoint: (): BridgeEndpoint => this.connection.endpoint(),
      setStatus: (status: string): void => { this.session.status = status; },
      getUIContext: (): UIContext => this.getUIContext(),
      request: (path: string, input?: Payload): Promise<BridgeReply> => this.request(path, input),
      leaveComputer: (forget: boolean): void => this.leaveComputer(forget),
      downloadFile: (endpoint: BridgeEndpoint, cwd: string, path: string, local: string, lookupName: boolean,
        limit: number): Promise<void> => this.client.downloadFile(endpoint, cwd, path, local, lookupName, limit),
      dismissKeyboard: (): void => this.dismissKeyboard(),
      closeToolDetails: (): void => this.toolCmd.closeToolDetails(),
      scrollPreviewToTop: (): void => this.previewScroller.scrollEdge(Edge.Top)
    };
  }

  openWorkspaceFiles(): boolean {
    this.dismissKeyboard();
    if (this.session.busy) return false;
    if (!this.session.reachable || !this.session.workspaceCwd) {
      this.session.status = '请先连接电脑并打开一个会话。';
      return false;
    }
    this.activeTab = 'tasks';
    this.session.showSettings = false;
    this.showFiles = true;
    this.session.status = '';
    this.fileController.showDirectory(this.session.workspaceCwd);
    return true;
  }

  fileBack(): void {
    if (this.session.busy || this.session.openingSession) return;
    this.showFiles = false;
    this.activeTab = 'tasks';
  }

  async copyText(value: string): Promise<void> {
    let message = '已复制';
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value));
    } catch {
      message = '复制失败';
    }
    this.getUIContext().getPromptAction().showToast({ message });
  }

  voiceComposerHost(): VoiceComposerHost {
    return {
      currentId: (): string => this.session.currentId,
      epoch: (): number => this.session.epoch,
      busy: (): boolean => this.session.busy,
      openingSession: (): boolean => this.session.openingSession,
      reachable: (): boolean => this.session.reachable,
      idle: (): boolean => this.session.idle,
      visible: (): boolean => this.visible,
      hasPendingSend: (): boolean => !!this.session.pendingSend,
      draft: (): string => this.session.draft,
      setDraft: (draft: string): void => { this.session.draft = draft; },
      getUIContext: (): UIContext => this.getUIContext(),
      fetchFullMessageText: (sessionId: string, messageId: string, epoch: number, current?: () => boolean): Promise<string | undefined> =>
        this.streamSync.fetchFullMessageText(sessionId, messageId, epoch, current),
      replySpeechText: (source: string): string => replySpeechText(source),
      syncCommandPalette: (): void => this.toolCmd.syncCommandPalette(),
      send: (): Promise<void> => this.sessionActions.send()
    };
  }

  chatHeaderMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    if (this.session.currentId && !this.session.noSession && this.activeTab === 'tasks') {
      if (this.session.workspaceCwd) {
        items.push({
          value: '工作区文件',
          action: () => { this.openWorkspaceFiles(); }
        });
      }
      items.push({
        value: '分享会话',
        action: () => { void this.shareController.shareCurrentSession('session-settings'); }
      });
    }
    items.push({
      value: '模型与会话设置', action: () => {
        if (this.session.reachable && this.session.currentId) void this.sessionActions.requestAction('/models');
      }
    });
    return items;
  }

  async toggleSessionArchive(session: SessionRow): Promise<void> {
    const payload: Payload = { id: session.id, cwd: session.cwd, revision: session.revision ?? 0, archived: !session.archived };
    if (await this.sessionActions.requestAction('/session-meta', payload)) {
      if (this.sessionView === 'all' && session.cwd) await this.loadWorkspacePage(session.cwd);
      else await this.loadSessions();
    }
  }

  sessionActionsHost(): SessionActionsHost {
    return {
      session: this.session,
      streamSync: this.streamSync,
      chatState: (): ChatState => this.chatState,
      request: (path: string, input?: Payload): Promise<BridgeReply> => this.request(path, input),
      leaveComputer: (forget: boolean): void => this.leaveComputer(forget),
      observeSessionRun: (session: SessionState): void => this.observeSessionRun(session),
      setInteraction: (interaction?: PendingInteraction): void => this.setInteraction(interaction),
      syncCommandPalette: (): void => this.toolCmd.syncCommandPalette(),
      getUIContext: (): UIContext => this.getUIContext(),
      accent: (): string => this.accent(),
      resetVoice: (): void => this.voiceComposer.resetVoice(),
      revealSessionDrawer: (): void => { this.showSessions = !this.dockedSessions(); },
      showSessions: (): boolean => this.showSessions,
      invalidateCatalog: (): void => {
        this.sessionCatalogLoaded = false;
        this.sessionCatalogVersion += 1;
      },
      refreshExpandedSpace: (cwd: string): void => { if (this.expandedSpaces.includes(cwd)) void this.loadWorkspacePage(cwd); },
      catalogConnection: (): number => this.catalogConnection,
      canCreateWorkspace: (): boolean => this.canCreateWorkspace,
      canCreateSession: (): boolean => this.canCreateSession(),
      closeNewSession: (): void => this.closeNewSession(),
      closeNewSpace: (): void => this.closeNewSpace(),
      openNewSession: (cwd: string): void => this.openNewSession(cwd),
      loadSessions: (): Promise<void> => this.loadSessions(),
      addWorkspace: (cwd: string, name: string): void => {
        if (this.projects.includes(cwd)) return;
        this.projects = this.projects.concat([cwd]).sort();
        this.workspaces = this.workspaces.concat([{ cwd: cwd, name: name }]);
      },
      showTasks: (): void => { this.activeTab = 'tasks'; },
      animateSend: (): void => {
        this.toolCmd.state.sakuraBurstKind = 'send';
        this.toolCmd.state.sakuraBurstSeq += 1;
      },
      uploadAttachment: (kind: string, name: string, bytes: Uint8Array): Promise<UploadedAttachment> =>
        this.client.uploadAttachment(this.connection.endpoint(), kind, name, bytes,
          this.session.currentId && this.session.workspaceCwd
            ? '&' + paneQuery(this.session.currentId, this.session.workspaceCwd) : '')
    };
  }

  defaultNewSessionAgent(preferred: string = 'pi'): string {
    return this.agents.find((agent: AgentInfo): boolean => agent.id === preferred && agent.installed === true)?.id ??
      this.agents.find((agent: AgentInfo): boolean => agent.id === 'pi' && agent.installed === true)?.id ??
      this.agents.find((agent: AgentInfo): boolean => agent.installed === true)?.id ?? '';
  }

  openNewSession(path: string = '', preferred: string = 'pi'): void {
    if (this.session.busy || this.session.openingSession || (path && !this.projects.includes(path))) return;
    this.dismissKeyboard();
    this.sessionActions.creation.newSessionFixedWorkspace = !!path;
    this.sessionActions.creation.newSessionCwd = path || (this.projects.includes(this.session.workspaceCwd) ? this.session.workspaceCwd : this.projects[0] ?? '');
    this.sessionActions.creation.newSessionPreferredAgent = preferred;
    this.sessionActions.creation.newSessionAgent = this.defaultNewSessionAgent(preferred);
    this.sessionActions.creation.newSessionError = '';
    this.sessionActions.creation.showNewSession = true;
    if (this.session.reachable && (!this.sessionCatalogLoaded || this.sessionCatalogFailed ||
      this.agents.some((agent: AgentInfo): boolean => agent.installed === undefined) ||
      Date.now() - this.sessionCatalogUpdatedAt >= 30000)) {
      void this.loadSessions();
    }
  }

  closeNewSession(): void {
    if (this.session.openingSession) return;
    this.sessionActions.creation.showNewSession = false;
  }

  canCreateSession(): boolean {
    return this.session.reachable && this.hostAvailable && !this.session.busy && !this.session.openingSession &&
      this.projects.includes(this.sessionActions.creation.newSessionCwd) &&
      this.agents.some((agent: AgentInfo): boolean => agent.id === this.sessionActions.creation.newSessionAgent && agent.installed === true);
  }

  workspaceName(path: string): string {
    return workspaceName(this.workspaces, path);
  }

  openNewSpace(): void {
    if (!this.session.reachable || this.session.busy || this.session.openingSession || !this.canCreateWorkspace) return;
    this.sessionActions.creation.newSpaceName = '';
    this.sessionActions.creation.newSpaceError = '';
    this.sessionActions.creation.showNewSpace = true;
  }

  closeNewSpace(): void {
    if (this.session.busy) return;
    this.dismissKeyboard();
    this.sessionActions.creation.showNewSpace = false;
  }

  confirmCloseSpace(path: string, epoch: number): void {
    if (epoch !== this.session.epoch || !this.projects.includes(path)) return;
    const name = this.workspaceName(path);
    const prompt = this.getUIContext().getPromptAction();
    if (!this.isPaired || !this.session.reachable) { prompt.showToast({ message: '请先连接电脑再移除空间。' }); return; }
    if (this.session.busy || this.session.openingSession) { prompt.showToast({ message: '请等待当前操作结束后再移除空间。' }); return; }
    this.getUIContext().showAlertDialog({
      title: '移除空间',
      message: `「${name}」将从电脑的 Pi Go 工作区列表移除，进行中的任务会停止。文件和会话历史会保留。`,
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.pigo_muted'),
        action: () => {}
      },
      secondaryButton: {
        value: '移除空间',
        fontColor: $r('app.color.pigo_error'),
        action: () => {
          if (epoch === this.session.epoch && this.projects.includes(path)) void this.closeWorkspace(path);
        }
      }
    });
  }

  async closeWorkspace(path: string): Promise<void> {
    const epoch = this.session.epoch;
    if (!(await this.sessionActions.requestAction('/close-workspace', { cwd: path }))) {
      if (epoch === this.session.epoch && this.session.status) this.getUIContext().getPromptAction().showToast({ message: this.session.status });
      return;
    }
    const name = this.workspaceName(path);
    // 移除成功后立刻更新本地列表。
    this.projects = this.projects.filter((item: string): boolean => item !== path);
    this.expandedSpaces = this.expandedSpaces.filter((item: string): boolean => item !== path);
    this.workspacePages = this.workspacePages.filter((page: WorkspacePage): boolean => page.path !== path);
    this.workspaces = this.workspaces?.filter((row: WorkspaceRow): boolean => row.cwd !== path) ?? [];
    this.getUIContext().getPromptAction().showToast({ message: `已移除空间「${name}」` });
    if (this.session.workspaceCwd === path) {
      // 当前会话所在的电脑端工作区已关闭，回到任务列表等桥接状态刷新。
      this.showSessions = !this.dockedSessions();
      this.streamSync.schedule(0);
    } else void this.loadSessions();
  }

  setInteraction(request?: PendingInteraction): void {
    if (request?.id === this.session.interaction?.id) return;
    this.session.interactionDraft = request?.prefill ?? '';
    this.session.interaction = request;
    this.streamSync.syncLiveActivity();
  }

  async answerInteraction(pendingId: string, answer: boolean | string): Promise<void> {
    if (pendingId !== this.session.interaction?.id || !this.session.currentId) return;
    if (await this.sessionActions.requestAction('/answer', { id: this.session.currentId, pendingId: pendingId, answer: answer })) {
      this.session.epoch += 1;
      if (this.session.interaction?.id === pendingId) this.setInteraction();
      this.streamSync.schedule(0);
    }
  }

  toggleThinking(id: string, open: boolean, state: SessionViewState = this.session): void {
    if (open && !state.thinkingOpenIds.includes(id)) state.thinkingOpenIds = state.thinkingOpenIds.concat([id]);
    else if (!open) state.thinkingOpenIds = state.thinkingOpenIds.filter((item: string): boolean => item !== id);
  }

  shareAttachmentHost(): ShareAttachmentHost {
    return {
      appState: this.appState,
      messages: (): ChatMessage[] => this.session.messages,
      historyCursor: (): string | undefined => this.session.historyCursor,
      reachable: (): boolean => this.session.reachable,
      syncMode: (): string => this.session.syncMode,
      epoch: (): number => this.session.epoch,
      currentId: (): string => this.session.currentId,
      openingSession: (): boolean => this.session.openingSession,
      project: (): string => this.session.project,
      liveText: (): string => this.session.liveText,
      activeTab: (): string => this.activeTab,
      minePage: (): string => this.minePage,
      busy: (): boolean => this.session.busy,
      setBusy: (value: boolean): void => { this.session.busy = value; },
      setStatus: (status: string): void => { this.session.status = status; },
      draft: (): string => this.session.draft,
      setDraft: (draft: string): void => { this.session.draft = draft; },
      attachments: (): DraftAttachment[] => this.session.attachments,
      setAttachments: (attachments: DraftAttachment[]): void => { this.session.attachments = attachments; },
      draftAttachments: (): Map<string, DraftAttachment[]> => this.chatState.draftAttachments,
      acceptsImage: (): boolean => this.session.acceptsImage,
      hasPendingSend: (): boolean => !!this.session.pendingSend,
      request: (path: string): Promise<BridgeReply> => this.request(path),
      fetchFullMessageText: (sessionId: string, messageId: string, epoch: number): Promise<string | undefined> =>
        this.streamSync.fetchFullMessageText(sessionId, messageId, epoch),
      getUIContext: (): UIContext => this.getUIContext(),
      dismissKeyboard: (): void => this.dismissKeyboard(),
      chatTitle: (): string => this.chatTitle(),
      computerTitle: (): string => this.computerTitle(),
      drawerOpen: (): boolean => this.drawerOpen(),
      setDrawer: (open: boolean): void => this.setDrawer(open),
      requestAction: (path: string, input: Payload): Promise<boolean> => this.sessionActions.requestAction(path, input),
      prepareShareTarget: (): boolean => this.prepareShareTarget(),
      canAddShareToCurrent: (): boolean => this.canAddShareToCurrent(),
      openComputers: (): void => this.openComputers(),
      showChat: (): void => {
        this.activeTab = 'tasks';
        this.session.showSettings = false;
        this.showFiles = false;
      },
      showSessionPicker: (): void => {
        if (!this.dockedSessions()) this.setDrawer(true);
        else void this.loadSessions();
      },
      draftKey: (id: string): string => this.streamSync.draftKey(id),
      rememberDraft: (id: string): void => this.streamSync.rememberDraft(id)
    };
  }

  onIncomingShare(): void { this.shareController.onIncomingShare(); }

  shareTargetLocked(): boolean {
    return !!this.fileController.state.editingPath || this.fileController.state.savingPreview || this.scheduleController.state.schedulePage === 'editor' ||
      this.scheduleController.state.scheduleSaving || this.sessionActions.creation.showNewSession || this.sessionActions.creation.showNewSpace || this.addingComputer;
  }

  prepareShareTarget(): boolean {
    if (this.shareTargetLocked()) return false;
    this.scheduleController.state.schedulePage = '';
    this.runCenter.state.reviewedRun = undefined;
    this.fileController.state.textFilePreview = undefined;
    if (this.fileController.state.markdownTableReader) this.fileController.closeMarkdownTableReader();
    return true;
  }

  canAddShareToCurrent(): boolean {
    return this.isPaired && !!this.session.currentId && this.activeTab === 'tasks' && !this.showFiles && !this.session.showSettings &&
      !this.scheduleController.state.schedulePage && !this.runCenter.state.reviewedRun && !this.fileController.state.markdownTableReader && !this.fileController.state.textFilePreview &&
      !this.shareTargetLocked() && !this.drawerOpen();
  }

  bottomPad(): number {
    return this.keyboardHeight > 0 ? 0 : this.navBarHeight;
  }

  headerHeight(): number {
    return this.windowHeight < SHORT_WINDOW_HEIGHT ? 52 : 60;
  }

  dismissKeyboard(): void {
    // 焦点转移到页面根节点，软键盘随输入框失焦一并收起；
    // 再结束输入会话兑底，避免个别输入法在失焦后仍驻留。
    try {
      this.getUIContext().getFocusController().clearFocus();
      inputMethod.getController().stopInputSession().catch((): void => {});
    } catch { /* 键盘本就收起或输入法服务暂不可用时忽略。 */ }
  }

  armTranscriptFollow(): void {
    // 键盘弹起时：原本就贴底则保持贴底（跟随压缩重贴），在翻历史则不打扰。
    const offset = this.transcript.currentOffset();
    if (!offset) return;
    const gap = this.transcriptContentHeight - this.transcriptViewport - offset.yOffset;
    this.session.transcriptFollow = gap <= 120;
    if (this.session.transcriptFollow) this.transcript.scrollEdge(Edge.Bottom);
  }

  onKeyboardChange(): void {
    if (this.keyboardHeight <= 0 || this.activeTab !== 'tasks' || this.showFiles || this.session.showSettings ||
      this.showSessions || this.fileController.state.editingPath || this.fileController.state.textFilePreview) return;
    this.armTranscriptFollow();
  }

  restoreSettings(): void {
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    try {
      const settings = openSettings(context);
      this.settings = settings;
      this.runCenter.restoreSettings(settings);
      this.themeId = themeStyle(settings.getSync('theme_style', 'sakura') as string).id;
      appUiState().themeId = this.themeId;
      this.themeMotionEnabled = settings.getSync(THEME_MOTION_SETTING, true) !== false;
      this.modeId = appearanceMode(settings.getSync('appearance_mode', 'system') as string).id;
      this.liveViewsEnabled = settings.getSync(LIVE_VIEW_SETTING, true) !== false;
      this.scheduleController.restoreSettings(settings);
      const raw = settings.getSync('huawei_profile', '') as string;
      if (!raw) return;
      const profile = JSON.parse(raw) as HuaweiProfile;
      if (typeof profile?.openId === 'string' && profile.openId &&
        typeof profile.name === 'string' && typeof profile.avatar === 'string') {
        this.accountSync.state.huaweiProfile = profile;
      }
    } catch { /* An unavailable preferences store leaves the defaults in place. */ }
  }

  async saveSetting(key: string, value: string | boolean): Promise<void> {
    const settings = this.settings;
    if (!settings) throw new Error('settings_unavailable');
    const write = this.settingsWrite.then(async () => {
      settings.putSync(key, value);
      await settings.flush();
    });
    this.settingsWrite = write.catch(() => {});
    return write;
  }

  async setLiveViewsEnabled(enabled: boolean): Promise<void> {
    this.liveViewsEnabled = enabled;
    if (!enabled) {
      this.session.liveViewSessionKey = '';
      this.session.liveViewRunId = '';
      this.session.liveViewPendingUntil = 0;
      this.liveViewStatus = '';
    }
    this.streamSync.syncLiveActivity();
    if (this.visible && this.streamSync.backgroundLiveActivity()) {
      this.streamSync.schedule(0);
      this.streamSync.startStream();
    }
    try {
      await this.saveSetting(LIVE_VIEW_SETTING, enabled);
    } catch {
      if (this.liveViewsEnabled === enabled) {
        this.getUIContext().getPromptAction().showToast({ message: '未能保存实况窗设置' });
      }
    }
  }

  accountSyncHost(): AccountSyncHost {
    return {
      context: (): common.UIAbilityContext | undefined => this.getUIContext().getHostContext() as common.UIAbilityContext | undefined,
      whenRestored: (): Promise<void> => this.restoreChain,
      settings: (): preferences.Preferences | undefined => this.settings,
      saveSetting: (key: string, value: string): Promise<void> => this.saveSetting(key, value),
      computers: (): Companion[] => this.computers,
      resetAvatar: (): void => { this.avatarUnavailable = false; },
      cancelComputerRestore: (): void => { this.restoringComputer = undefined; },
      applyTheme: (theme: string): void => {
        if (theme === this.themeId) return;
        this.themeId = theme;
        appUiState().themeId = theme;
        void this.saveSetting(SYNC_THEME, theme).catch(() => { this.appearanceNotice = '未能保存主题配色。'; });
      },
      applyMode: (mode: string): void => {
        if (mode !== this.modeId) this.applyAppearanceMode(appearanceMode(mode));
      }
    };
  }

  restoreCloudComputer(computer: CloudComputer): void {
    this.pairingComputerId = '';
    this.selectPairingMode(computer.mode);
    if (computer.mode === 'usb') this.address = computer.address;
    this.ticket = '';
    this.pairingBundle = '';
    this.lanCandidates = [];
    this.session.status = '';
    this.restoringComputer = computer;
    this.addingComputer = true;
  }

  removeCloudComputer(computer: CloudComputer): void {
    if (this.removeTarget !== computer.address || this.session.busy || !this.accountSync.state.huaweiProfile) return;
    this.removeTarget = '';
    this.accountSync.updateCloudComputer(computer.address, '');
  }

  palette(): ThemePalette { return themePalette(this.themeId, this.darkMode); }

  accent(): string { return this.palette().accent; }

  accentTint(): string { return this.palette().accentTint; }

  accentForeground(): string { return this.palette().accentForeground; }

  themeCanvas(): string { return this.palette().canvas; }

  selectTheme(id: string): void {
    this.appearanceNotice = '';
    this.themeId = id;
    appUiState().themeId = id;
    void this.saveSetting(SYNC_THEME, id).catch(() => { this.appearanceNotice = '未能保存主题配色。'; });
    this.accountSync.writeCloudRow({ key: SYNC_THEME, payload: id });
  }

  async setThemeMotionEnabled(enabled: boolean): Promise<void> {
    this.themeMotionEnabled = enabled;
    await this.saveSetting(THEME_MOTION_SETTING, enabled).catch(() => { this.appearanceNotice = '未能保存动态效果设置。'; });
  }

  applyAppearanceMode(mode: AppearanceMode): boolean {
    const context = this.getUIContext().getHostContext();
    if (!context) return false;
    this.appearanceNotice = '';
    try {
      context.getApplicationContext().setColorMode(mode.colorMode);
      this.modeId = mode.id;
      void this.saveSetting(SYNC_MODE, mode.id).catch(() => { this.appearanceNotice = '未能保存显示模式。'; });
      return true;
    } catch { this.appearanceNotice = '无法切换显示模式。'; }
    return false;
  }

  selectAppearanceMode(mode: AppearanceMode): void {
    if (this.applyAppearanceMode(mode)) this.accountSync.writeCloudRow({ key: SYNC_MODE, payload: mode.id });
  }

  openComputers(): void {
    if (this.fileController.state.editingPath && this.fileController.state.fileText !== this.fileController.state.fileOriginal) {
      this.session.status = '请先保存或放弃文件修改。';
      return;
    }
    if (this.showSessions) this.setDrawer(false);
    this.session.showSettings = false;
    this.showFiles = false;
    this.activeTab = 'mine';
    this.minePage = 'computers';
  }

  mineBack(): void {
    this.dismissKeyboard();
    this.closeComputerEditors();
    if (this.addingComputer) {
      this.addingComputer = false;
      this.pairingComputerId = '';
      this.restoringComputer = undefined;
      this.ticket = '';
      this.pairingBundle = '';
    } else {
      this.minePage = '';
    }
    this.removeTarget = '';
    this.session.status = '';
  }

  closeComputerEditors(): void {
    this.renameComputerId = '';
    this.computerNameDraft = '';
    this.moveConnectionAddress = '';
  }

  addComputerConnection(id: string = ''): void {
    this.closeComputerEditors();
    this.session.status = '';
    this.ticket = '';
    this.pairingBundle = '';
    this.lanCandidates = [];
    this.restoringComputer = undefined;
    this.pairingComputerId = id;
    this.addingComputer = true;
    if (this.pairingMode === 'lan') void this.findLanCompanions();
  }

  saveComputerName(id: string): void {
    if (this.renameComputerId !== id || this.session.busy) return;
    this.computers = renameComputerGroup(this.computers, id, this.computerNameDraft);
    this.closeComputerEditors();
    this.dismissKeyboard();
    void this.persistComputers().catch(() => { this.session.status = '未能保存电脑备注。'; });
  }

  assignComputerConnection(address: string, group?: ComputerGroup): void {
    if (this.moveConnectionAddress !== address || this.session.busy) return;
    this.computers = moveComputerConnection(this.computers, address, group?.id ?? util.generateRandomUUID(), group?.name ?? '');
    this.closeComputerEditors();
    void this.persistComputers().catch(() => { this.session.status = '未能保存连接归属。'; });
  }

  computerConnectionMenu(record: Companion): MenuElement[] {
    const items: MenuElement[] = [];
    if (this.computers.length > 1) {
      items.push({
        value: '更改归组',
        action: () => {
          this.closeComputerEditors();
          this.moveConnectionAddress = record.address;
        }
      });
    }
    items.push({
      value: '移除连接',
      action: () => {
        this.closeComputerEditors();
        this.removeTarget = record.address;
      }
    });
    return items;
  }

  topContentClearance(): number {
    return this.statusBarHeight + this.headerHeight() + 14;
  }

  bottomContentClearance(): number {
    return (this.showRootBottomTabs() ? this.bottomTabsHeight() + 18 : 0) + this.bottomPad() + 14;
  }

  chatHasTopCards(): boolean {
    return (this.backgroundRunning().length > 0 && this.activeTab === 'tasks' && !this.showFiles &&
      !this.session.showSettings && !this.session.noSession && !!this.session.currentId) ||
      (!this.session.reachable && !this.offlineDismissed) || !!this.session.interaction || (!!this.session.pendingSend && !this.session.busy);
  }

  composerBottomMargin(): number {
    return (this.showRootBottomTabs() ? this.bottomTabsHeight() + 10 : 0) + this.bottomPad() + 8;
  }

  chatScrollBottomOffset(): number {
    return this.composerBottomMargin() + (this.session.attachments.length ? 186 : 114);
  }

  chatBottomClearance(): number {
    return this.composerBottomMargin() + (this.session.attachments.length ? 194 : 122);
  }

  splitHorizontal(): boolean {
    return this.split.splitHorizontal(this.dockedSessions(), this.sessionPaneWidth());
  }

  splitKeyboardCompact(): boolean {
    return this.split.splitKeyboardCompact(this.dockedSessions(), this.sessionPaneWidth());
  }

  positionTranscript(id: string, contentHeight: number): void {
    if (id !== this.session.currentId || contentHeight <= 0) return;
    this.transcriptContentHeight = contentHeight;
    if (this.split.pendingFocusedPosition === id) {
      this.split.pendingFocusedPosition = '';
      if (this.split.restoreSplitPosition(id, this.transcript)) {
        this.session.transcriptFollow = false;
        this.session.pendingBottom = false;
        this.session.pendingSessionReveal = '';
        return;
      }
    }
    if (this.session.pendingSessionReveal === id) this.session.transcriptFollow = true;
    if (!this.session.transcriptFollow) { this.session.pendingBottom = false; return; }
    if (!this.session.pendingBottom) return;
    this.session.pendingBottom = false;
    // The content height exceeds the maximum offset; Scroll clamps it to the bottom.
    this.transcript.scrollTo({ xOffset: 0, yOffset: contentHeight, animation: false });
    if (this.session.pendingSessionReveal === id) {
      this.session.pendingSessionReveal = '';
      this.showSessions = false;
    }
  }

  swipeDrawer(event: GestureEvent): void {
    if (Math.abs(event.offsetX) <= 45 || Math.abs(event.offsetX) <= Math.abs(event.offsetY) * 1.3) return;
    if (this.showSessions) {
      if (event.offsetX < 0) this.setDrawer(false);
    } else if (event.offsetX > 0 && !this.session.busy) {
      if (!this.session.showSettings && !(this.activeTab === 'mine' && this.minePage)) this.setDrawer(true);
    }
  }

  setDrawer(open: boolean): void {
    if (open && this.dockedSessions()) return;
    if (open) {
      this.dismissKeyboard();
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.showSessions = open; });
    if (open) void this.loadSessionStatus();
    // Reuse the catalog for quick drawer toggles; stale data stays usable during refresh.
    if (open && this.session.reachable && (!this.sessionCatalogLoaded ||
      (this.sessionView === 'all' && Date.now() - this.sessionCatalogUpdatedAt >= 30000) ||
      this.loadedView !== this.sessionView)) {
      void this.loadSessions();
    }
  }

  dockedSessions(): boolean {
    return this.isPaired && this.windowWidth >= SPLIT_WINDOW_WIDTH &&
      (!this.split.state.splitOpen || this.split.mainPaneWidth(this.sessionPaneWidth()) >= 640);
  }

  drawerOpen(): boolean {
    return this.showSessions && this.isPaired && !this.dockedSessions();
  }

  drawerWidth(): number {
    return Math.min(420, this.windowWidth * 0.82);
  }

  sessionPaneWidth(preferred: number | undefined = this.preferredSessionPaneWidth): number {
    const width = preferred ?? Math.max(224, Math.min(288, Math.floor(this.windowWidth * 0.34)));
    return Math.max(160, Math.min(width, 420, this.windowWidth - 360));
  }

  compactSessionPane(): boolean {
    if (this.dockedSessions()) return this.sessionPaneWidth() < 208;
    return this.windowWidth > 0 && this.drawerWidth() < 208;
  }

  onWindowWidthChange(): void {
    // Once the list is docked, folding back should leave the conversation visible.
    if (this.dockedSessions()) this.showSessions = false;
  }

  onSplitViewportChange(): void {
    if (!this.split.state.splitOpen) return;
    const compact = this.splitKeyboardCompact();
    if (compact === this.split.wasSplitKeyboardCompact) return;
    this.split.saveSplitPosition(this.session, this.transcript);
    this.split.pendingFocusedPosition = this.session.currentId;
    if (compact) this.split.saveSplitPosition(this.split.state.otherSession, this.split.otherTranscript);
    else this.split.pendingOtherPosition = this.split.state.otherId;
    this.split.wasSplitKeyboardCompact = compact;
  }

  onFocusedSessionChange(): void {
    if (this.split.launchedNativeWindow) {
      findConversationWindow(this.base, this.session.currentId)?.close();
    }
    if (this.split.state.splitOpen && !this.split.state.splitNavigating && this.split.state.otherId && this.session.currentId === this.split.state.otherId) {
      this.split.clearSplit();
    }
  }

  updateSidebarRows(): void {
    this.sidebarRows.replace(this.sessionStore.rows({
      view: this.sessionView, loadedView: this.loadedView, sessions: this.sessions, projects: this.projects,
      workspaces: this.workspaces, expandedSpaces: this.expandedSpaces,
      workspacePages: this.workspacePages, nextCursor: this.sessionNextCursor
    }));
    if (this.pendingLibraryReveal) setTimeout(() => { this.revealLibraryAnchor(); }, 0);
  }

  onSidebarAppear(): void {
    this.pendingLibraryReveal = !!this.session.currentId;
    this.updateSidebarRows();
  }

  revealLibraryAnchor(): void {
    if (!this.pendingLibraryReveal || (!this.showSessions && !this.dockedSessions())) return;
    if (this.library.currentOffset().yOffset > 2) { this.pendingLibraryReveal = false; return; }
    const anchor = this.sidebarRows.anchor(this.session.currentId, this.session.workspaceCwd);
    if (anchor < 0) return;
    this.pendingLibraryReveal = false;
    if (anchor > 0) this.library.scrollToIndex(anchor, false, ScrollAlign.START);
  }

  chatTitle(): string {
    const listed = this.sessions.find((session: SessionRow): boolean => session.id === this.session.currentId);
    const listedName = listed?.name === '(no messages)' ? '' : listed?.name;
    if (this.session.sessionName || listedName) return this.session.sessionName || listedName || '新任务';
    const firstPrompt = this.session.messages.find((message: ChatMessage): boolean => message.role === 'user');
    if (!firstPrompt) return '新任务';
    const attachmentStart = firstPrompt.text.lastIndexOf('\n\n[Pi Go 附件] 手机上传了 ');
    const text = (attachmentStart < 0 ? firstPrompt.text : firstPrompt.text.slice(0, attachmentStart)).replace(/\s+/g, ' ').trim();
    const characters = Array.from(text);
    if (characters.length > 48) return characters.slice(0, 47).join('').trimEnd() + '…';
    return text || (attachmentStart >= 0 || (firstPrompt.imageCount ?? 0) > 0 ? '附件会话' : '新任务');
  }

  updateCachedSessionTitle(id: string, name?: string): void {
    if (!name) return;
    const index = this.sessions.findIndex((row: SessionRow): boolean => row.id === id && row.name !== name);
    if (index < 0) return;
    const rows = this.sessions.slice();
    rows[index].name = name;
    this.sessions = rows;
  }

  computerTitle(): string {
    const record = this.computers.find((item: Companion): boolean => item.address === this.base);
    return record?.computerName || (validUsb(this.base) ? 'USB 电脑' : (this.base.split('://')[1] || '我的电脑'));
  }

  toggleSpace(path: string): void {
    this.pendingLibraryReveal = false;
    this.expandedSpaces = this.sessionStore.toggleSpace(this.expandedSpaces, path);
    if (this.expandedSpaces.includes(path)) void this.loadWorkspacePage(path);
  }

  sessionViewLabel(view: string): string {
    return view === 'all' ? '工作区' : view === 'recent' ? '最近' : '归档';
  }

  selectSessionView(view: string): void {
    if (this.session.busy || this.sessionLoading || !this.session.reachable) return;
    this.sessionView = view;
    this.sessionNextCursor = undefined;
    void this.loadSessions();
  }

  sessionViewOptions(): MenuElement[] {
    return SIDEBAR_VIEWS.map((view: string): MenuElement => ({
      value: this.sessionViewLabel(view), action: (): void => { this.selectSessionView(view); }
    }));
  }

  resetCatalog(): void {
    this.catalogConnection += 1;
    this.agents = [];
    this.sessionActions.creation.showNewSession = false;
    this.sessionLoading = false;
    this.sessionCatalogLoaded = false;
    this.sessionCatalogFailed = false;
    this.sessionCatalogUpdatedAt = 0;
    this.workspacePages = [];
    this.sessionNextCursor = undefined;
    this.expandedSpaces = [];
    this.sessionView = 'all';
    this.loadedView = 'all';
  }

  tabSymbol(tab: string, selected: boolean): Resource {
    if (tab === 'inbox') return $r('sys.symbol.bell');
    if (tab === 'tasks') return selected ? $r('sys.symbol.message_fill') : $r('sys.symbol.message');
    if (tab === 'pending') return selected ? $r('sys.symbol.play_circle_fill') : $r('sys.symbol.play_circle');
    return selected ? $r('sys.symbol.person_fill') : $r('sys.symbol.person');
  }

  bottomTabsHeight(): number {
    return this.windowHeight < SHORT_WINDOW_HEIGHT ? 48 : 60;
  }

  rootTabs(): string[] {
    return this.isPaired ? ['inbox', 'tasks', 'pending', 'mine'] : ['inbox', 'mine'];
  }

  activeTabIndex(): number {
    const index = this.rootTabs().indexOf(this.activeTab);
    return index >= 0 ? index : 0;
  }

  selectRootTab(tab: string): boolean {
    this.dismissKeyboard();
    if (this.session.busy) return false;
    if (this.fileController.state.editingPath && this.fileController.state.fileText !== this.fileController.state.fileOriginal) {
      this.session.status = '请先保存或放弃文件修改。';
      return false;
    }
    this.showFiles = false;
    this.session.showSettings = false;
    if (tab !== 'inbox') this.inboxSelecting = false;
    if (tab === 'mine' && this.minePage) {
      this.mineBack();
      this.minePage = '';
    }
    if (tab !== this.activeTab) {
      this.session.status = '';
      this.minePage = '';
      this.addingComputer = false;
      this.pairingComputerId = '';
      this.closeComputerEditors();
      this.restoringComputer = undefined;
      this.removeTarget = '';
    }
    this.activeTab = tab;
    if (tab === 'inbox') {
      this.scheduleController.queueScheduleSync(true);
      this.runCenter.queueRunSync(0);
      void this.loadSessionStatus();
    } else if (tab === 'pending') {
      void this.loadSessionStatus();
      void this.scheduleController.loadScheduleJobs();
    }
    return true;
  }

  showRootBottomTabs(): boolean {
    if (this.loading) return false;
    if (this.activeTab === 'mine' && this.minePage) return false;
    if (this.session.showSettings || this.showFiles) return false;
    if (!this.keyboardHeight) return true;
    return this.isPaired && this.activeTab !== 'mine' && this.activeTab !== 'tasks';
  }

  confirmDeleteSchedule(job: ScheduleJob): void {
    this.getUIContext().showAlertDialog({
      title: '删除定时任务',
      message: `删除「${job.name}」？已生成的运行记录和会话会保留。`,
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      primaryButton: { value: '取消', fontColor: $r('app.color.pigo_muted'), action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.pigo_error'),
        action: () => { void this.scheduleController.updateSchedule('delete', job); }
      }
    });
  }

  scheduleJobMenu(job: ScheduleJob): MenuElement[] {
    const options: MenuElement[] = [
      { value: '编辑', action: () => { this.scheduleController.editSchedule(job); } },
      { value: '立即运行', action: () => { void this.scheduleController.updateSchedule('run', job); } },
      { value: '删除', action: () => { this.confirmDeleteSchedule(job); } }
    ];
    if (job.nextAt !== null || !job.enabled) options.splice(1, 0, {
      value: job.enabled ? '暂停' : '启用',
      action: () => { void this.scheduleController.updateSchedule(job.enabled ? 'pause' : 'resume', job); }
    });
    return options;
  }

  openScheduleTimePicker(): void {
    this.dismissKeyboard();
    if (this.scheduleController.state.scheduleKind === 'once') {
      const parsed = parseScheduleTime(this.scheduleController.state.scheduleWhen.trim());
      const selected = parsed > 0 ? new Date(parsed) : new Date(Date.now() + 120_000);
      this.getUIContext().showDatePickerDialog({
        start: new Date(Date.now() - 86_400_000),
        end: new Date(Date.now() + 5 * 365 * 86_400_000),
        selected: selected,
        showTime: true,
        useMilitaryTime: true,
        onDateAccept: (value: Date) => {
          this.scheduleController.state.scheduleWhen = scheduleTime(value.getTime());
        }
      });
    } else if (this.scheduleController.state.scheduleKind === 'daily') {
      const selected = new Date();
      const match = /^(\d{1,2}):(\d{2})$/.exec(this.scheduleController.state.scheduleWhen.trim());
      if (match) {
        selected.setHours(Math.min(23, Number(match[1])), Math.min(59, Number(match[2])), 0, 0);
      } else {
        selected.setHours(18, 0, 0, 0);
      }
      this.getUIContext().showTimePickerDialog({
        selected: selected,
        useMilitaryTime: true,
        onAccept: (value: TimePickerResult) => {
          const hh = String(value.hour).padStart(2, '0');
          const mm = String(value.minute).padStart(2, '0');
          this.scheduleController.state.scheduleWhen = `${hh}:${mm}`;
        }
      });
    }
  }

  sakuraConversationFocus(): boolean {
    return this.activeTab !== 'mine' &&
      (this.session.messages.length > 0 || this.session.optimisticMessages.length > 0 ||
        !!this.session.liveText || !!this.session.liveThinking || this.session.liveTools.length > 0);
  }

  sakuraGirlInteractive(): boolean {
    return this.themeId === 'sakura' && this.activeTab === 'tasks' && !this.showFiles && !this.session.showSettings &&
      !this.sakuraConversationFocus() && !this.drawerOpen() && this.keyboardHeight <= 0;
  }

}
