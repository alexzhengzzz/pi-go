import { SessionActions, SessionActionsHost } from '../model/SessionActions';
import { SessionViewState, StreamSyncController, StreamSyncHost } from '../model/StreamSyncController';
import { ShareAttachmentController, ShareAttachmentHost } from '../model/ShareAttachmentController';
import { VoiceComposerController, VoiceComposerHost } from '../model/VoiceComposerController';
import { ScheduleController, ScheduleHost } from '../model/ScheduleController';
import { RunCenterController, RunCenterHost } from '../model/RunCenterController';
import { WorkspaceFileController, WorkspaceFileHost } from '../model/WorkspaceFileController';
import { AccountSyncController, AccountSyncHost } from '../model/AccountSyncController';
import { IncomingShareBanner, NewSessionDialog, NewSpaceDialog, PendingInteractionCard, ToolDetailsSheet } from '../components/ChatDialogs';
import { SakuraGirlHitZone, ThemeBackdrop } from '../components/ThemeBackdrop';
import { MarkdownTableReaderPage, TextFilePreviewPage, WorkspaceFileEditor } from '../components/FilePreviewPages';
import { OfflineNotice, RunCompletionBanner, RunningSessionPill, RunningSessionStrip, ScheduledRunBanner,
  SessionSettings } from '../components/SessionOverlays';
import { AppUiState, appUiState, windowAppUiState } from '../AppUiState';
import { entryInstances } from '../EntryInstanceRegistry';
import { CommandList, CommandState, commandDraft, skillDraft } from '../model/CommandState';
import { ConnectionManager, PairingRequest } from '../model/ConnectionManager';
import { ChatState } from '../model/ChatState';
import type { TranscriptCacheBook } from '../model/ChatState';
import { SessionCatalog, SessionStore, SIDEBAR_VIEWS, WorkspacePage, workspaceName } from '../model/SessionStore';
import { headerSymbol } from '../components/HeaderSymbol';
import { PiGoClient } from '../model/PiGoClient';
import { ScheduleOverlay } from '../components/ScheduleOverlay';
import { TaskPanel } from '../components/TaskPanel';
import { SettingsView } from '../components/SettingsView';
import { WorkspaceFiles } from '../components/WorkspaceFiles';
import { SessionSidebar } from '../components/SessionSidebar';
import { ChatComposer } from '../components/ChatComposer';
import { ChatTranscript } from '../components/ChatTranscript';
import { RunResultView } from '../components/RunResultView';
import { bannerTransition, modalFadeTransition, pagePushTransition } from '../components/PageTransitions';
import { DiffLine, InboxRun, RunEvent, RunFile, RunScreenshot } from '../RunResults';
import { KeyboardAvoidMode, UIContext } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { ChatContent, replySpeechText } from '../ChatContent';
import { ChatImage } from '../ChatImage';
import { util } from '@kit.ArkTS';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { AbilityConstant, common } from '@kit.AbilityKit';
import { closeConversationWindows, findConversationWindow, prepareConversationWindow, takeConversationWindow } from '../ConversationWindowLaunch';
import { panePath, paneQuery, WindowConversation } from '../model/WindowConversation';
import { preferences } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { Companion, ComputerBook, CredentialVault, subscribeComputerBook } from '../CredentialVault';
import { AppearanceMode, THEME_MOTION_SETTING, ThemePalette, appearanceMode, canvasFadeStops, openSettings, themePalette, themeStyle } from '../Appearance';
import { HuaweiProfile } from '../HuaweiProfile';
import { CloudComputer, SYNC_MODE, SYNC_THEME } from '../AccountSync';
import { immersiveSurface, glassComposerSurface, glassCardSurface, immersiveFloatingTabs, hasImmersiveMaterial, immersiveSheetMaterial } from '../Immersive';
import { markdownWorkspacePath, normalizeWorkspacePath } from '../ChatPaths';
import { decodePairingBundle, validUsb } from '../PairingCode';
import { connectionLabel, validCompanion } from '../CompanionCheck';
import { ComputerGroup, computerGroupId, computerGroups, computerGroupTitle, moveComputerConnection, renameComputerGroup } from '../ComputerGroups';
import { LiveActivitySnapshot, liveActivity } from '../LiveActivity';
import { ScheduleJob, RunMessage, scheduleTime, parseScheduleTime, isCurrentScheduleComputer } from '../ScheduledRuns';

import { ModelOption, BridgeEndpoint, SessionState, SessionRow, ChatMessage, DraftAttachment,
  UploadedAttachment, LiveTool, ToolDetails, CommandRow, ReceivedFilePreview,
  PendingInteraction, RunningRow, WorkspaceRow, BridgeReply,
  AgentInfo, OptimisticMessage, Payload, QueuedSteering, BridgeFailure } from '../model/PiGoTypes';
import { USB_ADDRESS,
  SPLIT_WINDOW_WIDTH,
  SHORT_WINDOW_HEIGHT, LIVE_VIEW_SETTING } from '../model/PiGoConstants';
import { SidebarRows } from '../model/SidebarRows';
import { buildWidgetSnapshot, InboxWidget } from '../InboxWidget';

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

interface TranscriptPosition {
  follow: boolean;
  offset: number;
}

const PANE_ACTIONS: string[] = ['/prompt', '/abort', '/answer', '/receipt'];
const PANE_ROUTES: string[] = [
  '/session/snapshot', '/chat', '/history', '/tool-detail',
  '/message-image', '/message-text', '/prompt', '/abort',
  '/answer', '/receipt', '/regenerate'
];

@Entry
@ComponentV2
struct Index {
  @Local private appState: AppUiState = windowAppUiState();
  private get darkMode(): boolean { return this.appState.darkMode; }
  get address(): string { return this.appState.address; }
  set address(value: string) { this.appState.address = value; }
  get launchTicket(): string { return this.appState.launchTicket; }
  set launchTicket(value: string) { this.appState.launchTicket = value; }
  private get liveLaunchSession(): string { return this.appState.liveLaunchSession; }
  private set liveLaunchSession(value: string) { this.appState.liveLaunchSession = value; }
  private get liveLaunchAddress(): string { return this.appState.liveLaunchAddress; }
  private set liveLaunchAddress(value: string) { this.appState.liveLaunchAddress = value; }
  private readonly runCenter: RunCenterController = new RunCenterController(this.runCenterHost());
  private readonly scheduleController: ScheduleController = new ScheduleController(this.scheduleHost());
  private readonly shareController: ShareAttachmentController = new ShareAttachmentController(this.shareAttachmentHost());
  @Local private session: SessionViewState = new SessionViewState();
  private readonly streamSync: StreamSyncController = new StreamSyncController(this.streamSyncHost());
  @Local private splitOpen: boolean = false;
  @Local private splitNavigating: boolean = false;
  private openingNativeWindow: boolean = false;
  private launchedNativeWindow: boolean = false;
  @Local private focusedPaneFirst: boolean = true;
  @Local private otherId: string = '';
  @Local private otherTitle: string = '';
  private otherCwd: string = '';
  @Local private otherSession: SessionViewState = new SessionViewState();
  private readonly otherConnection: ConnectionManager = new ConnectionManager();
  private readonly otherChat: ChatState = new ChatState();
  private readonly otherStream: StreamSyncController = new StreamSyncController(this.otherStreamHost());
  private readonly otherTranscript: Scroller = new Scroller();
  private otherTranscriptHeight: number = 0;
  private readonly splitPositions: Map<string, TranscriptPosition> = new Map<string, TranscriptPosition>();
  private pendingFocusedPosition: string = '';
  private pendingOtherPosition: string = '';
  private wasSplitKeyboardCompact: boolean = false;
  private readonly sessionActions: SessionActions = new SessionActions(this.sessionActionsHost());
  private readonly inboxWidget: InboxWidget = new InboxWidget();
  private networkTimer: number = -1;
  private switchingNetwork: boolean = false;
  private lastNetworkFailover: number = 0;
  private restoreChain: Promise<void> = Promise.resolve();
  get statusBarHeight(): number { return this.appState.statusBarHeight; }
  get navBarHeight(): number { return this.appState.navBarHeight; }
  private get leftInset(): number { return this.appState.leftInset; }
  private get rightInset(): number { return this.appState.rightInset; }
  private get windowWidth(): number { return this.appState.windowWidth; }
  private get windowHeight(): number { return this.appState.windowHeight; }
  get keyboardHeight(): number { return this.appState.keyboardHeight; }
  @Local private showModelMenu: boolean = false;
  @Local private ticket: string = '';
  @Local private pairingMode: string = 'usb';
  @Local private pairingBundle: string = '';
  @Local private lanCandidates: string[] = [];
  @Local private isPaired: boolean = false;
  @Local private loading: boolean = true;
  @Local private computers: Companion[] = [];
  @Local private removeTarget: string = '';
  @Local private renameComputerId: string = '';
  @Local private computerNameDraft: string = '';
  @Local private moveConnectionAddress: string = '';
  @Local private pairingComputerId: string = '';
  @Local private showComposerMenu: boolean = false;
  @Local private showSkillPicker: boolean = false;
  @Local private showFiles: boolean = false;
  @Local private showToolDetails: boolean = false;
  @Local private selectedTool?: LiveTool = undefined;
  @Local private selectedToolDetails?: ToolDetails = undefined;
  @Local private toolDetailError: string = '';
  private selectedToolMessageId: string = '';
  private toolDetailRevision: number = 0;
  private readonly chatState: ChatState = new ChatState();
  private readonly previewScroller: Scroller = new Scroller();
  private readonly fileController: WorkspaceFileController = new WorkspaceFileController(this.workspaceFileHost());
  private readonly client: PiGoClient = new PiGoClient();
  @Local private sessions: SessionRow[] = [];
  @Local private runningSessionIds: string[] = [];
  @Local private runningSessions: RunningRow[] = [];
  @Local private sakuraBurstSeq: number = 0;
  @Local private sakuraBurstKind: string = 'send';
  @Local private sakuraBloomSeq: number = 0;
  @Local private sakuraBloomX: number = 0;
  @Local private sakuraBloomY: number = 0;
  @Local private sakuraGirlTapSeq: number = 0;
  @Local private sakuraCelebrateSeq: number = 0;
  private themeTapDownX: number = 0;
  private themeTapDownY: number = 0;
  private themeTapDownAt: number = 0;
  private themeTapMoved: boolean = false;
  private sessionStatusAt: number = 0;
  private sessionStatusLoading: boolean = false;
  @Local private showSessions: boolean = false;
  @Local private preferredSessionPaneWidth?: number = undefined;
  @Local private sessionPaneDragging: boolean = false;
  private sessionPaneDragStart: number = 0;
  @Local private expandedSpaces: string[] = [];
  @Local private offlineDismissed: boolean = false;
  @Local private activeTab: string = 'tasks';
  @Local private minePage: string = '';
  @Local private addingComputer: boolean = false;
  @Local private themeId: string = 'sakura';
  @Local private themeMotionEnabled: boolean = true;
  @Local private modeId: string = 'system';
  @Local private liveViewsEnabled: boolean = true;
  @Local private liveViewStatus: string = '';
  @Local private appearanceNotice: string = '';
  private readonly accountSync: AccountSyncController = new AccountSyncController(this.accountSyncHost());
  @Local private avatarUnavailable: boolean = false;
  private settings?: preferences.Preferences;
  private settingsWrite: Promise<void> = Promise.resolve();
  @Local private restoringComputer?: CloudComputer = undefined;

  @Local private sessionView: string = 'all';
  @Local private loadedView: string = 'all';
  @Local private hostAvailable: boolean = false;
  @Local private canCreateWorkspace: boolean = false;
  @Local private agents: AgentInfo[] = [];
  private readonly voiceComposer: VoiceComposerController = new VoiceComposerController(this.voiceComposerHost());
  @Local private projects: string[] = [];
  @Local private workspaces: WorkspaceRow[] = [];
  @Local private workspacePages: WorkspacePage[] = [];
  @Local private sessionNextCursor?: number = undefined;
  @Local private base: string = '';
  private readonly connection: ConnectionManager = new ConnectionManager();
  private visible: boolean = false;
  @Local private sessionLoading: boolean = false;
  @Local private sessionCatalogFailed: boolean = false;
  private sessionCatalogLoaded: boolean = false;
  private sessionCatalogUpdatedAt: number = 0;
  @Local private commandRows: CommandRow[] = [];
  @Local private commandPalette: boolean = false;
  @Local private commandsLoading: boolean = false;
  @Local private commandError: string = '';
  private readonly commandState: CommandState = new CommandState();
  private sessionCatalogVersion: number = 0;
  private catalogConnection: number = 0;
  private workspacePageRequestId: number = 0;
  private readonly sessionStore: SessionStore = new SessionStore();
  private vault?: CredentialVault;
  private readonly transcript: Scroller = new Scroller();
  private transcriptContentHeight: number = 0;
  private transcriptViewport: number = 0;
  private readonly library: Scroller = new Scroller();
  private readonly sidebarRows: SidebarRows = new SidebarRows();
  private pendingLibraryReveal: boolean = false;
  private disposed: boolean = false;
  private unsubscribeVault?: () => void = undefined;

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
    if (this.showToolDetails) { this.closeToolDetails(); return true; }
    if (this.showModelMenu) { this.showModelMenu = false; return true; }
    if (this.sessionActions.creation.showNewSpace) { this.closeNewSpace(); return true; }
    if (this.sessionActions.creation.showNewSession) { this.closeNewSession(); return true; }
    if (this.showSessions) { this.setDrawer(false); return true; }
    if (this.session.showSettings) { this.session.showSettings = false; return true; }
    if (this.showFiles) { this.fileBack(); return true; }
    if (this.splitOpen && this.activeTab === 'tasks') {
      if (this.keyboardHeight) this.dismissKeyboard();
      else if (!this.splitNavigating) this.clearSplit();
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
      if (!this.isPaired && this.activeTab === 'tasks') this.openComputers();
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
    this.resumeOtherPane();
    void this.consumeLiveActivityLaunch();
    void this.accountSync.checkHuaweiProfile().then(() => { this.accountSync.scheduleCloudSync(0); });
  }
  onPageHide(): void {
    this.visible = false;
    this.suspendOtherPane();
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
    this.clearSplit();
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

  private async restore(): Promise<void> {
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
      if (active) this.activateComputer(active);
    } catch { this.session.status = '无法读取已有配对，请重新连接。'; }
    finally { this.loading = false; }
  }

  private async persistComputers(): Promise<void> {
    if (!this.vault) throw new Error('vault_unavailable');
    await this.vault.save({ version: 2, active: this.isPaired ? this.base : '', computers: this.computers });
  }

  @SyncMonitor('appState.launchTicket')
  private onLaunchTicket(): void { void this.consumeLaunchTicket(); }

  private async consumeLaunchTicket(): Promise<void> {
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

  @SyncMonitor('appState.liveLaunchSession')
  private onLiveActivityLaunch(): void { void this.consumeLiveActivityLaunch(); }

  private async consumeLiveActivityLaunch(): Promise<void> {
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

  private activateComputer(record: Companion): void {
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
    this.activeTab = 'tasks';
    this.minePage = '';
    this.session.status = '';
    this.session.noSession = '正在加载该电脑的会话…';
    this.showSessions = this.windowWidth < SPLIT_WINDOW_WIDTH;
    this.resetCatalog();
    this.session.reachable = false;
    this.isPaired = true;
    this.scheduleController.queueScheduleSync(true);
    this.streamSync.schedule(0);
    this.streamSync.stopStream();
  }

  private chooseComputer(record: Companion): void {
    if (this.session.busy || this.session.openingSession || this.removeTarget || (this.isPaired && this.base === record.address)) return;
    if (this.isPaired) {
      this.leaveComputer(false, record);
      return;
    }
    this.activateComputer(record);
    void this.persistComputers().catch(() => { this.session.status = '已连接；未能保存本次选择。'; });
  }

  private scheduleHost(): ScheduleHost {
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
      openNewSession: (): void => this.openNewSession()
    };
  }

  private scheduleComputerName(computer: Companion): string {
    const group = computerGroups(this.computers).find((item: ComputerGroup): boolean => item.id === computerGroupId(computer));
    return group ? computerGroupTitle(group) : connectionLabel(computer);
  }

  private runCenterHost(): RunCenterHost {
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
      showScheduleInbox: (): void => this.showScheduleInbox(),
      dismissKeyboard: (): void => this.dismissKeyboard(),
      getUIContext: (): UIContext => this.getUIContext(),
      openReferencedFile: (cwd: string, path: string, lookupName: boolean): Promise<void> =>
        this.fileController.openReferencedFile(cwd, path, lookupName),
      celebrate: (): void => {
        this.sakuraBurstKind = 'celebrate';
        this.sakuraBurstSeq += 1;
        if (this.themeId === 'sakura') this.sakuraCelebrateSeq += 1;
      }
    };
  }

  @SyncMonitor('session.currentId')
  private onRunSessionChanged(): void {
    this.voiceComposer.stopReplySpeech();
    this.runCenter.sessionChanged();
  }

  @SyncMonitor('appState.pushLaunchEvent')
  private onPushLaunch(): void { void this.runCenter.consumePushLaunch(); }

  private async openNotifiedSession(target: Companion, id: string, pendingId: string, eventId: string): Promise<boolean> {
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

  private citeRunLine(line: DiffLine): void {
    const file = this.runCenter.state.reviewedFile;
    if (!file || this.runCenter.state.reviewedRun?.sessionId !== this.session.currentId || line.line < 1) return;
    const reference = `请检查 ${file.path}:${line.line}（本轮 Diff）：\n${line.text.slice(1, 501)}`;
    this.session.draft = this.session.draft ? this.session.draft + '\n\n' + reference : reference;
    this.streamSync.rememberDraft(this.session.currentId);
    this.runCenter.backFromRunResult();
    this.runCenter.backFromRunResult();
  }

  private scheduleEndpoint(computer: Companion): BridgeEndpoint {
    return { address: computer.address, token: computer.token, ca: computer.ca, pin: computer.pin };
  }

  private publishWidgets(): void {
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

  @SyncMonitor('appState.inboxFormLaunch')
  private onInboxFormLaunch(): void {
    this.scheduleController.consumeFormLaunch(this.appState);
  }

  private showScheduleInbox(): void {
    this.dismissKeyboard();
    this.scheduleController.state.scheduleBanner = undefined;
    this.scheduleController.state.schedulePage = 'inbox';
    this.scheduleController.queueScheduleSync(true);
    this.runCenter.queueRunSync(0);
  }

  private async openScheduledSession(message: RunMessage): Promise<void> {
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

  private stopNetworkMonitor(): void {
    this.connection.stopWatchingNetwork();
    if (this.networkTimer !== -1) clearTimeout(this.networkTimer);
    this.networkTimer = -1;
  }

  private onNetworkChange(): void {
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

  private canSwitchNetwork(): boolean {
    return this.visible && this.isPaired && !this.session.reachable && !this.session.busy && !this.session.openingSession &&
      !this.session.pendingSend && !this.fileController.state.editingPath && !this.removeTarget && !this.scheduleController.state.scheduleSaving &&
      !this.sessionActions.creation.showNewSession && !this.sessionActions.creation.showNewSpace && !this.session.showSettings && this.scheduleController.state.schedulePage !== 'editor' &&
      !this.fileController.state.textFilePreview && !this.fileController.state.markdownTableReader && !this.runCenter.state.reviewedRun &&
      this.activeTab === 'tasks' && !this.voiceComposer.state.recording && !this.voiceComposer.state.voicePreparing && !this.voiceComposer.state.voiceFinishing;
  }

  private async tryPublicConnection(): Promise<void> {
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

  private streamSyncHost(): StreamSyncHost {
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
      selectedTool: (): LiveTool | undefined => this.selectedTool,
      selectedToolMessageId: (): string => this.selectedToolMessageId,
      request: (path: string, input?: Payload): Promise<BridgeReply> => this.request(path, input),
      leaveComputer: (forget: boolean): void => this.leaveComputer(forget),
      refreshSelectedTool: (tool: LiveTool, message: string = ''): void => this.refreshSelectedTool(tool, message),
      chatTitle: (): string => this.chatTitle(),
      closeToolDetails: (): void => this.closeToolDetails(),
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
      resetCommands: (): void => this.resetCommands(),
      observeSessionRun: (session: SessionState): void => this.observeSessionRun(session),
      syncCommandPalette: (): void => this.syncCommandPalette(),
      setInteraction: (interaction?: PendingInteraction): void => this.setInteraction(interaction),
      reconcileSteering: (settled: boolean): void => this.sessionActions.reconcileSteering(settled),
      tryPublicConnection: (): Promise<void> => this.tryPublicConnection(),
      getUIContext: (): UIContext => this.getUIContext(),
      restoreOnlineNotice: (): void => { this.offlineDismissed = false; },
      refreshVisibleCatalog: (connected: boolean): void => this.refreshVisibleCatalog(connected),
      sessionDeleted: (id: string): void => this.sessionDeleted(id),
      showTextPreview: (cwd: string, path: string, text: string): void => this.fileController.showTextPreview(cwd, path, text),
      observeRun: (id: string, title: string, active: boolean, stopped: boolean = false): void =>
        this.runCenter.observeRun(id, title, active, stopped),
      requestPermissionAfterDispatch: (): void => this.runCenter.requestPermissionAfterDispatch(),
      publishLiveActivity: (snapshot?: LiveActivitySnapshot): void =>
        liveActivity.sync(snapshot, this.getUIContext?.()?.getHostContext?.() as common.UIAbilityContext | undefined)
    };
  }

  private otherStreamHost(): StreamSyncHost {
    const host = this.streamSyncHost();
    host.session = this.otherSession;
    host.connection = (): ConnectionManager => this.otherConnection;
    host.chatState = (): ChatState => this.otherChat;
    host.isPaired = (): boolean => this.isPaired && this.splitOpen && !!this.otherId;
    host.streamEndpoint = (): BridgeEndpoint => this.connection.endpoint();
    host.streamPath = (path: string): string => panePath(path, this.otherId, this.otherCwd);
    host.request = (path: string): Promise<BridgeReply> => this.requestOtherPane(path);
    host.liveViewsEnabled = (): boolean => false;
    host.selectedTool = (): LiveTool | undefined => undefined;
    host.selectedToolMessageId = (): string => '';
    host.chatTitle = (): string => this.otherPaneTitle();
    host.refreshSelectedTool = (): void => {};
    host.closeToolDetails = (): void => {};
    host.resetVoice = (): void => {};
    host.resetCommands = (): void => {};
    host.observeSessionRun = (): void => {};
    host.observeRun = (): void => {};
    host.updateCachedSessionTitle = (): void => {};
    host.workspaceChanged = (): void => {};
    host.showChat = (): void => {};
    host.syncCommandPalette = (): void => {};
    host.setInteraction = (interaction?: PendingInteraction): void => { this.otherSession.interaction = interaction; };
    host.reconcileSteering = (): void => {};
    host.tryPublicConnection = (): Promise<void> => Promise.resolve();
    host.restoreOnlineNotice = (): void => {};
    host.refreshVisibleCatalog = (): void => {};
    host.sessionDeleted = (): void => {};
    host.requestPermissionAfterDispatch = (): void => {};
    host.publishLiveActivity = (): void => {};
    return host;
  }

  private async requestOtherPane(path: string): Promise<BridgeReply> {
    const id = this.otherId;
    const cwd = this.otherCwd;
    const result = await this.request(panePath(path, id, cwd));
    if (result.session && (result.session.id !== id || result.session.cwd !== cwd)) {
      throw new Error('session_changed');
    }
    return result;
  }

  private otherPaneTitle(): string {
    return this.otherSession.sessionName || this.otherTitle || '未命名会话';
  }

  private suspendOtherPane(): void {
    this.otherSession.epoch += 1;
    this.otherStream.cancelSchedule();
    this.otherStream.stopStream();
  }

  private resumeOtherPane(): void {
    if (!this.splitOpen || !this.otherId) return;
    this.otherStream.startStream();
    this.otherStream.schedule(0);
  }

  private setOtherPane(snapshot?: BridgeReply): void {
    this.suspendOtherPane();
    this.otherId = snapshot?.session?.id ?? '';
    this.otherCwd = snapshot?.session?.cwd ?? '';
    this.otherTitle = snapshot?.session?.name ?? '';
    this.otherSession.currentId = '';
    this.otherSession.noSession = '';
    this.otherSession.loadingMessageText = '';
    this.otherSession.historyStream = '';
    this.otherSession.historyLeaf = undefined;
    this.otherSession.busy = false;
    this.otherSession.status = '';
    this.otherSession.reachable = !!snapshot?.session;
    this.otherSession.syncMode = 'probe';
    this.otherSession.interaction = undefined;
    this.pendingOtherPosition = this.otherId;
    if (!snapshot?.session) return;
    this.otherStream.presentChat(snapshot, false);
    this.otherSession.transcriptFollow = this.splitPositions.get(this.otherId)?.follow ?? true;
    this.resumeOtherPane();
  }

  private clearSplit(): void {
    if (!this.splitOpen && !this.otherId) return;
    if (this.session.currentId && !this.session.transcriptFollow) {
      this.saveSplitPosition(this.session, this.transcript);
      this.pendingFocusedPosition = this.session.currentId;
    }
    this.splitOpen = false;
    this.splitNavigating = false;
    this.setOtherPane();
    this.focusedPaneFirst = true;
    this.wasSplitKeyboardCompact = false;
    const retained = this.splitPositions.get(this.pendingFocusedPosition);
    this.splitPositions.clear();
    if (retained) this.splitPositions.set(this.pendingFocusedPosition, retained);
  }

  private saveSplitPosition(state: SessionViewState, scroller: Scroller): void {
    if (!state.currentId) return;
    if (state.transcriptFollow) {
      this.splitPositions.delete(state.currentId);
      return;
    }
    if ((scroller === this.transcript && this.pendingFocusedPosition === state.currentId) ||
      (scroller === this.otherTranscript && this.pendingOtherPosition === state.currentId)) return;
    try {
      const offset = scroller.currentOffset().yOffset;
      this.splitPositions.set(state.currentId, { follow: false, offset: offset });
    } catch { /* The transcript may be between layouts. */ }
  }

  private captureFocusedPane(): BridgeReply | undefined {
    if (!this.session.currentId) return undefined;
    return {
      session: { id: this.session.currentId, cwd: this.session.workspaceCwd, name: this.chatTitle(),
        agent: this.session.currentAgent, idle: this.session.idle, queued: this.session.queued, runId: this.session.runId },
      messages: this.session.messages,
      historyCursor: this.session.historyCursor,
      liveText: this.session.liveText,
      liveSeq: this.session.liveSeq,
      liveThinking: this.session.liveThinking,
      liveThinkSeq: this.session.liveThinkSeq,
      tools: this.session.liveTools,
      interaction: this.session.interaction
    };
  }

  private async chooseSplitSession(id: string, agent: string | undefined, keepFocused: boolean): Promise<boolean> {
    if (!id || this.splitNavigating || this.openingNativeWindow || this.session.openingSession || this.session.busy) return false;
    const existingWindow = this.launchedNativeWindow ? findConversationWindow(this.base, id) : undefined;
    if (existingWindow && id === existingWindow.id) {
      this.getUIContext().getPromptAction().showToast({ message: '此会话已在另一窗口打开。' });
      return false;
    }
    this.activeTab = 'tasks';
    this.minePage = '';
    this.session.showSettings = false;
    this.showFiles = false;
    if (id === this.session.currentId) {
      if (keepFocused && !this.splitOpen) {
        this.saveSplitPosition(this.session, this.transcript);
        this.pendingFocusedPosition = id;
        this.splitOpen = true;
      }
      this.setDrawer(false);
      return true;
    }
    if (!this.session.reachable) return false;
    if (!keepFocused && !this.splitOpen) {
      return await this.sessionActions.requestAction('/open', { id: id, agent: agent });
    }
    const wasSplit = this.splitOpen;
    const previous = this.captureFocusedPane();
    const previousOtherId = this.otherId;
    const switchPanes = id === previousOtherId;
    const placeInOtherPane = switchPanes || ((keepFocused || (wasSplit && !previousOtherId)) && !!previous?.session);
    const base = this.base;
    this.splitNavigating = true;
    this.saveSplitPosition(this.session, this.transcript);
    if (this.otherId) this.saveSplitPosition(this.otherSession, this.otherTranscript);
    if (placeInOtherPane) this.dismissKeyboard();
    try {
      if (!await this.sessionActions.requestAction('/open', { id: id, agent: agent }) ||
        this.session.currentId !== id || this.base !== base) return false;
      if (keepFocused || wasSplit) {
        this.splitOpen = true;
        if (placeInOtherPane) {
          this.focusedPaneFirst = !this.focusedPaneFirst;
          this.setOtherPane(previous);
        }
        this.splitPositions.forEach((_value: TranscriptPosition, key: string): void => {
          if (key !== id && key !== this.otherId) this.splitPositions.delete(key);
        });
        this.session.transcriptFollow = this.splitPositions.get(id)?.follow ?? true;
        this.pendingFocusedPosition = id;
      }
      this.setDrawer(false);
      return true;
    } finally {
      this.splitNavigating = false;
    }
  }

  private openSidebarSession(row: SessionRow, split: boolean): void {
    void this.chooseSplitSession(row.id, row.agent, split);
  }

  private async openInSystemSplit(row: SessionRow): Promise<void> {
    if (this.openingNativeWindow || this.splitNavigating || this.session.busy ||
      this.session.openingSession || !this.session.reachable) return;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!context) return;
    const toast = (message: string): void => { this.getUIContext().getPromptAction().showToast({ message: message }); };
    if (row.id === this.session.currentId) {
      toast('请选择另一条会话在系统分屏中打开。');
      return;
    }
    if (findConversationWindow(this.base, row.id)) return;
    const endpoint = this.connection.endpoint();
    const epoch = this.session.epoch;
    let launchKey = '';
    this.openingNativeWindow = true;
    try {
      const snapshot = await this.request('/session/open', { id: row.id, agent: row.agent, history: true }, endpoint);
      if (this.session.epoch !== epoch || endpoint.token !== this.connection.endpoint().token ||
        endpoint.address !== this.connection.endpoint().address) return;
      if (snapshot.session?.id !== row.id || !snapshot.session.cwd) throw new Error('session_changed');
      const cwd = snapshot.session.cwd;
      const model = new WindowConversation(snapshot, endpoint, this.client, this.chatState, toast,
        (): void => {
          this.clearSplit();
          this.setDrawer(false);
        },
        (message: string, index: number, tool: string): Promise<string> =>
          this.fileController.loadHistoryImage(row.id, message, index, tool, cwd,
            (path: string): Promise<BridgeReply> => this.request(panePath(path, row.id, cwd), undefined, endpoint)),
        (target: string, workspace: string, document: string): Promise<string> =>
          this.fileController.loadMarkdownImage(target, workspace, document));
      launchKey = prepareConversationWindow(model);
      this.dismissKeyboard();
      await context.startAbility({
        bundleName: context.abilityInfo.bundleName,
        moduleName: context.abilityInfo.moduleName,
        abilityName: 'ConversationAbility',
        parameters: { conversationKey: launchKey }
      }, { windowMode: AbilityConstant.WindowMode.WINDOW_MODE_SPLIT });
      this.launchedNativeWindow = true;
    } catch (error) {
      if (launchKey) takeConversationWindow(launchKey)?.dispose();
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else toast(error instanceof BridgeFailure && error.status === 404
        ? '请更新电脑端 Pi Go 后再打开系统分屏。' : '暂时无法打开系统分屏，请检查设备窗口模式和会话连接。');
    } finally {
      this.openingNativeWindow = false;
    }
  }

  private async focusOtherPane(): Promise<boolean> {
    return await this.chooseSplitSession(this.otherId, this.otherSession.currentAgent, false);
  }

  private async closeSplitPane(focused: boolean): Promise<void> {
    if (this.splitNavigating || this.session.openingSession || this.session.busy) return;
    if (focused && this.otherId && !await this.focusOtherPane()) return;
    this.clearSplit();
  }

  private restoreSplitPosition(id: string, scroller: Scroller): boolean {
    const position = this.splitPositions.get(id);
    if (!position || position.follow) return false;
    scroller.scrollTo({ xOffset: 0, yOffset: position.offset, animation: false });
    return true;
  }

  private positionOtherTranscript(id: string, contentHeight: number): void {
    if (id !== this.otherId || contentHeight <= 0) return;
    this.otherTranscriptHeight = contentHeight;
    if (this.pendingOtherPosition === id) {
      this.pendingOtherPosition = '';
      if (this.restoreSplitPosition(id, this.otherTranscript)) {
        this.otherSession.pendingBottom = false;
        return;
      }
    }
    if (this.otherSession.pendingBottom && this.otherSession.transcriptFollow) {
      this.otherTranscript.scrollTo({ xOffset: 0, yOffset: contentHeight, animation: false });
    }
    this.otherSession.pendingBottom = false;
  }

  private refreshVisibleCatalog(connected: boolean): void {
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

  private sessionDeleted(id: string): void {
    this.sessions = this.sessions.filter((row: SessionRow): boolean => row.id !== id);
    this.chatState.deleteTranscriptCache(this.streamSync.draftKey(id));
    if (this.session.currentId === id) {
      this.showSessions = !this.dockedSessions();
      void this.loadSessions();
    }
  }

  private paneRouteTarget(path: string, input?: Payload): string {
    if (path.includes('pane=') || !this.session.currentId || !this.session.workspaceCwd) return path;
    const basePath = path.split('?')[0];
    if (!PANE_ROUTES.includes(basePath)) return path;
    if (PANE_ACTIONS.includes(basePath) && input?.id && input.id !== this.session.currentId) return path;
    return panePath(path, this.session.currentId, this.session.workspaceCwd);
  }

  private async request(path: string, input?: Payload, endpoint?: BridgeEndpoint): Promise<BridgeReply> {
    if (!endpoint) path = this.paneRouteTarget(path, input);
    return this.client.request(endpoint ?? this.connection.endpoint(), path, input);
  }

  private async pair(): Promise<void> {
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
      const token = await this.connection.pair(pairing,
        (path: string, input: Payload, endpoint: BridgeEndpoint): Promise<BridgeReply> => this.request(path, input, endpoint));
      const record = this.connection.pairedComputer(pairing.endpoint, token, this.computers, this.pairingComputerId,
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
      this.session.status = error instanceof BridgeFailure && error.status === 401 ? '票据已经失效，请在电脑上重新生成。' :
        this.pairingMode !== 'usb' ? '无法建立安全连接。请检查网络、Pi Go 服务和配对包。' : '无法连接电脑，请确认 USB 转发和 Pi Go 桥接服务。';
    } finally { this.session.busy = false; }
  }

  private selectPairingMode(mode: string): void {
    if (mode === this.pairingMode) return;
    this.pairingMode = mode;
    if (mode === 'usb' && !validUsb(this.address)) this.address = USB_ADDRESS;
    this.session.status = '';
    this.pairingBundle = '';
    this.lanCandidates = [];
    this.ticket = '';
  }

  private async scanPairingBundle(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context || this.session.busy) return;
    this.session.busy = true;
    this.session.status = '';
    try {
      const result = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: true
      });
      const bundle = decodePairingBundle(result.originalValue, this.pairingMode === 'remote');
      this.pairingBundle = result.originalValue;
      this.session.status = `已导入 ${bundle.url}。确认是自己的电脑后，点「配对并连接」。`;
    } catch {
      this.session.status = this.pairingMode === 'remote' ? '未导入公网配对包，请扫描 Pi Go.app「公网」二维码。' :
        '未导入局域网配对包，请扫描 Pi Go.app「局域网扫码」二维码。';
    }
    finally { this.session.busy = false; }
  }

  private async findLanCompanions(): Promise<void> {
    if (this.session.busy || this.session.openingSession) return;
    this.session.busy = true;
    this.lanCandidates = [];
    this.session.status = '';
    try {
      this.lanCandidates = await this.connection.discover();
      if (!this.lanCandidates.length) this.session.status = '未发现 Pi Go。可直接扫码或粘贴配对包。';
    } catch { this.session.status = '发现不可用，可直接导入配对包。'; }
    finally { this.session.busy = false; }
  }

  private leaveComputer(revoked: boolean = false, next?: Companion): void {
    if (this.launchedNativeWindow || this.openingNativeWindow) closeConversationWindows(this.base);
    if (this.splitOpen) this.clearSplit();
    if (this.fileController.state.markdownTableReader) this.fileController.closeMarkdownTableReader();
    this.fileController.state.textFilePreview = undefined;
    this.closeToolDetails();
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
    this.resetCommands();
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

  private removeComputer(address: string): void {
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

  private forgetDrafts(address: string): void {
    this.session.queuedSteering = this.session.queuedSteering.filter((item: QueuedSteering): boolean => !item.sessionKey.startsWith(`${address}|`));
    this.session.optimisticMessages = this.session.optimisticMessages.filter((item: OptimisticMessage): boolean => !item.sessionKey.startsWith(`${address}|`));
    this.chatState.forgetDrafts(address);
  }

  private async loadSessionStatus(): Promise<void> {
    if (!this.session.reachable || this.sessionStatusLoading) return;
    const epoch = this.session.epoch;
    const selected = this.session.currentId;
    this.sessionStatusLoading = true;
    try {
      const result = await this.request('/sessions/status');
      if (epoch === this.session.epoch) this.applyRunningStatus(result, selected);
    } catch {
      if (epoch === this.session.epoch) this.applyRunningStatus(undefined);
    } finally { this.sessionStatusLoading = false; }
  }

  private applyRunningStatus(result?: BridgeReply, selected: string = this.session.currentId): void {
    const rows = (result?.runningSessions ?? []).filter((row: RunningRow): boolean => !!row?.id);
    this.runningSessions = rows;
    for (const row of rows) {
      if (row.id !== this.session.currentId) this.updateCachedSessionTitle(row.id, row.name);
    }
    const ids = rows.map((row: RunningRow): string => row.id).concat(result?.runningSessionIds ?? []);
    this.runningSessionIds = ids.filter((id: string, index: number): boolean => ids.indexOf(id) === index);
    if (result?.idleSessionIds) {
      for (const row of this.backgroundRunning()) {
        if (row.id !== selected && row.started !== false) this.runCenter.observeRun(row.id, row.name || '后台任务', true);
      }
      this.runCenter.reconcileObservedRuns(result.idleSessionIds, this.runningSessionIds, selected);
    }
  }

  private observeSessionRun(session: SessionState): void {
    // A dispatched prompt can make the session busy before Pi starts a run.
    if (!session.idle && !session.runId && !session.queued) return;
    const title = session.name || this.sessions.find((row: SessionRow): boolean => row.id === session.id)?.name ||
      (session.id === this.session.currentId ? this.chatTitle() : '任务');
    this.runCenter.observeRun(session.id, title, !session.idle || session.queued === true);
  }

  private backgroundActive(): boolean {
    return this.runningSessionIds.some((id: string): boolean => id !== this.session.currentId);
  }

  private backgroundRunning(): RunningRow[] {
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

  private sessionRunning(id: string): boolean {
    return this.session.reachable && (id === this.session.currentId ? !this.session.idle || this.session.queued : this.runningSessionIds.includes(id));
  }

  // Keep the current session first, followed by background sessions.
  private allRunningRows(): RunningRow[] {
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

  private taskPanelRows(): RunningRow[] {
    const rows = this.allRunningRows();
    for (const row of rows) row.state = this.sessionState(row.id);
    return rows;
  }

  private standaloneScheduleRuns(): RunMessage[] {
    if (!this.session.reachable) return [];
    const sessions = this.allRunningRows();
    return this.scheduleController.state.scheduleActive.filter((row: RunMessage): boolean => isCurrentScheduleComputer(this.computers, this.base, row) &&
      !sessions.some((session: RunningRow): boolean => session.id === row.run.sessionId));
  }

  private runningTaskCount(): number {
    return this.session.reachable ? this.allRunningRows().length + this.standaloneScheduleRuns().length : 0;
  }

  // Fine-grained state for pills and badges: streaming / waiting / queued.
  private sessionState(id: string): string {
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

  private runningSessionPills(): RunningSessionPill[] {
    return this.backgroundRunning().map((row: RunningRow): RunningSessionPill => {
      const state = this.sessionState(row.id);
      return { id: row.id, name: row.name, label: this.stateLabel(state), color: this.stateColor(state) };
    });
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

  private async loadSessions(more: boolean = false, refresh: boolean = false): Promise<void> {
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

  private applyCatalog(catalog: SessionCatalog, view: string, more: boolean): void {
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

  private appendSessionPage(rows: SessionRow[], page: SessionRow[]): SessionRow[] {
    const ids = new Set<string>(rows.map((row: SessionRow): string => row.id));
    return rows.concat(page.filter((row: SessionRow): boolean => !ids.has(row.id)));
  }

  private setWorkspacePage(page: WorkspacePage): void {
    this.workspacePages = this.workspacePages.filter((item: WorkspacePage): boolean => item.path !== page.path).concat([page]);
  }

  private async loadWorkspacePage(path: string, more: boolean = false, refresh: boolean = false): Promise<void> {
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

  private workspaceFileHost(): WorkspaceFileHost {
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
      closeToolDetails: (): void => this.closeToolDetails(),
      scrollPreviewToTop: (): void => this.previewScroller.scrollEdge(Edge.Top)
    };
  }

  private fileBack(): void {
    if (this.session.busy || this.session.openingSession) return;
    this.showFiles = false;
    this.activeTab = 'tasks';
  }

  @Builder
  richChatText(text: string, cwd: string, documentPath: string = '', allowLandscape: boolean = true) {
    ChatContent({
      text: text,
      accent: this.accent(),
      codeBg: this.palette().codeBg,
      codeBorder: this.palette().codeBorder,
      codeHeaderBg: this.palette().codeHeaderBg,
      codeRadius: themeStyle(this.themeId).codeRadius,
      allowLandscape: allowLandscape,
      loadImage: (target: string): Promise<string> => this.fileController.loadMarkdownImage(target, cwd, documentPath),
      openImage: (source: string, label: string): void => { this.fileController.showChatImage(source, label); },
      openLink: (target: string): void => {
        if (!allowLandscape && markdownWorkspacePath(target, cwd, documentPath)) this.fileController.closeMarkdownTableReader();
        void this.fileController.openMarkdownLink(target, cwd, documentPath);
      },
      openLandscape: (source: string): void => { this.fileController.openMarkdownTableReader(source, cwd, documentPath); },
      copyCode: (value: string): void => { void this.copyText(value); }
    })
  }

  @Builder
  historyImages(count: number, sessionId: string, messageId: string, toolId: string = '') {
    ForEach(Array.from({ length: count }, (_: Object, index: number): number => index), (index: number) => {
      ChatImage({
        label: count === 1 ? '图片' : `图片 ${index + 1}`,
        load: (): Promise<string> => this.fileController.loadHistoryImage(sessionId, messageId, index, toolId),
        open: (source: string, label: string): void => { this.fileController.showChatImage(source, label); }
      })
    }, (index: number): string => `${sessionId}-${messageId}-${toolId}-${index}`)
  }

  private toolFile(tool: LiveTool): string {
    if (tool.state === 'run' || !['write', 'edit', 'read'].includes(tool.name)) return '';
    return normalizeWorkspacePath(this.session.workspaceCwd, this.selectedToolDetails?.path ?? tool.detail);
  }

  private toolIcon(tool: LiveTool): Resource {
    if (tool.name === 'computer_screenshot') return $r('sys.symbol.camera');
    if (tool.name === 'bash') return $r('sys.symbol.code_square');
    if (tool.name === 'grep' || tool.name === 'find' || tool.name === 'web_search') return $r('sys.symbol.magnifyingglass');
    if (tool.name === 'write' || tool.name === 'edit') return $r('sys.symbol.square_and_pencil');
    return $r('sys.symbol.folder');
  }

  private openToolDetails(tool: LiveTool, messageId: string): void {
    this.dismissKeyboard();
    this.selectedTool = tool;
    this.selectedToolMessageId = messageId;
    this.selectedToolDetails = undefined;
    this.showToolDetails = true;
    void this.loadToolDetails();
  }

  private closeToolDetails(): void {
    this.toolDetailRevision++;
    this.showToolDetails = false;
    this.selectedTool = undefined;
    this.selectedToolDetails = undefined;
    this.selectedToolMessageId = '';
    this.toolDetailError = '';
  }

  private refreshSelectedTool(tool: LiveTool, messageId: string = ''): void {
    if (this.selectedTool?.id !== tool.id || this.selectedTool.state === 'ok' || this.selectedTool.state === 'fail' ||
      this.selectedTool.state === tool.state ||
      (messageId && this.selectedToolMessageId && messageId !== this.selectedToolMessageId)) return;
    this.selectedTool = tool;
    if (messageId) this.selectedToolMessageId = messageId;
    void this.loadToolDetails();
  }

  private async loadToolDetails(): Promise<void> {
    const tool = this.selectedTool;
    if (!tool || !this.session.currentId) return;
    const revision = ++this.toolDetailRevision;
    this.toolDetailError = '';
    const message = this.selectedToolMessageId ? `&message=${encodeURIComponent(this.selectedToolMessageId)}` : '';
    try {
      const reply = await this.request(`/tool-detail?id=${encodeURIComponent(this.session.currentId)}&tool=${encodeURIComponent(tool.id)}${message}&images=1`);
      if (revision !== this.toolDetailRevision) return;
      this.selectedToolDetails = reply.toolDetail;
      if (!reply.toolDetail) this.toolDetailError = '没有可用的工具详情';
    } catch (error) {
      if (revision !== this.toolDetailRevision) return;
      this.toolDetailError = error instanceof BridgeFailure && error.message === 'not_found'
        ? '请更新电脑端 Pi Go 以查看完整详情' : '暂时无法加载工具详情';
    }
  }

  private async copyText(value: string): Promise<void> {
    let message = '已复制';
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value));
    } catch {
      message = '复制失败';
    }
    this.getUIContext().getPromptAction().showToast({ message });
  }

  private voiceComposerHost(): VoiceComposerHost {
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
      syncCommandPalette: (): void => this.syncCommandPalette(),
      send: (): Promise<void> => this.sessionActions.send()
    };
  }

  private chatHeaderMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    if (this.session.currentId && !this.session.noSession && this.activeTab === 'tasks') {
      items.push({
        value: '分享会话',
        action: () => { void this.shareController.shareCurrentSession('session-settings'); }
      });
    }
    items.push(
      { value: '模型与会话设置', action: () => {
        if (this.session.reachable && this.session.currentId) void this.sessionActions.requestAction('/models');
      } },
      { value: '切换电脑', action: () => { if (!this.session.busy) this.openComputers(); } }
    );
    return items;
  }

  private async updateSessionMeta(session: SessionRow, pin: boolean): Promise<void> {
    const payload: Payload = { id: session.id, cwd: session.cwd, revision: session.revision ?? 0 };
    if (pin) payload.pinned = !session.pinned;
    else payload.archived = !session.archived;
    if (await this.sessionActions.requestAction('/session-meta', payload)) {
      if (this.sessionView === 'all' && session.cwd) await this.loadWorkspacePage(session.cwd);
      else await this.loadSessions();
    }
  }

  private sessionActionsHost(): SessionActionsHost {
    return {
      session: this.session,
      streamSync: this.streamSync,
      chatState: (): ChatState => this.chatState,
      request: (path: string, input?: Payload): Promise<BridgeReply> => this.request(path, input),
      leaveComputer: (forget: boolean): void => this.leaveComputer(forget),
      observeSessionRun: (session: SessionState): void => this.observeSessionRun(session),
      setInteraction: (interaction?: PendingInteraction): void => this.setInteraction(interaction),
      syncCommandPalette: (): void => this.syncCommandPalette(),
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
        this.sakuraBurstKind = 'send';
        this.sakuraBurstSeq += 1;
      },
      uploadAttachment: (kind: string, name: string, bytes: Uint8Array): Promise<UploadedAttachment> =>
        this.client.uploadAttachment(this.connection.endpoint(), kind, name, bytes,
          this.session.currentId && this.session.workspaceCwd
            ? '&' + paneQuery(this.session.currentId, this.session.workspaceCwd) : '')
    };
  }

  private defaultNewSessionAgent(preferred: string = 'pi'): string {
    return this.agents.find((agent: AgentInfo): boolean => agent.id === preferred && agent.installed === true)?.id ??
      this.agents.find((agent: AgentInfo): boolean => agent.id === 'pi' && agent.installed === true)?.id ??
      this.agents.find((agent: AgentInfo): boolean => agent.installed === true)?.id ?? '';
  }

  private openNewSession(path: string = '', preferred: string = 'pi'): void {
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

  private closeNewSession(): void {
    if (this.session.openingSession) return;
    this.sessionActions.creation.showNewSession = false;
  }

  private canCreateSession(): boolean {
    return this.session.reachable && this.hostAvailable && !this.session.busy && !this.session.openingSession &&
      this.projects.includes(this.sessionActions.creation.newSessionCwd) &&
      this.agents.some((agent: AgentInfo): boolean => agent.id === this.sessionActions.creation.newSessionAgent && agent.installed === true);
  }

  private workspaceName(path: string): string {
    return workspaceName(this.workspaces, path);
  }

  private openNewSpace(): void {
    if (!this.session.reachable || this.session.busy || this.session.openingSession || !this.canCreateWorkspace) return;
    this.sessionActions.creation.newSpaceName = '';
    this.sessionActions.creation.newSpaceError = '';
    this.sessionActions.creation.showNewSpace = true;
  }

  private closeNewSpace(): void {
    if (this.session.busy) return;
    this.dismissKeyboard();
    this.sessionActions.creation.showNewSpace = false;
  }

  private confirmCloseSpace(path: string, epoch: number): void {
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

  private async closeWorkspace(path: string): Promise<void> {
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

  private setInteraction(request?: PendingInteraction): void {
    if (request?.id === this.session.interaction?.id) return;
    this.session.interactionDraft = request?.prefill ?? '';
    this.session.interaction = request;
    this.streamSync.syncLiveActivity();
  }

  private async answerInteraction(pendingId: string, answer: boolean | string): Promise<void> {
    if (pendingId !== this.session.interaction?.id || !this.session.currentId) return;
    if (await this.sessionActions.requestAction('/answer', { id: this.session.currentId, pendingId: pendingId, answer: answer })) {
      this.session.epoch += 1;
      if (this.session.interaction?.id === pendingId) this.setInteraction();
      this.streamSync.schedule(0);
    }
  }

  private toggleThinking(id: string, open: boolean, state: SessionViewState = this.session): void {
    if (open && !state.thinkingOpenIds.includes(id)) state.thinkingOpenIds = state.thinkingOpenIds.concat([id]);
    else if (!open) state.thinkingOpenIds = state.thinkingOpenIds.filter((item: string): boolean => item !== id);
  }

  private commandPaletteActive(): boolean {
    if (this.voiceComposer.state.voiceMode || !this.session.draft) return false;
    const text = this.session.draft.trimStart();
    return text.startsWith('/') && !/\s/.test(text);
  }

  private commandMatches(): CommandRow[] {
    const text = this.session.draft.trimStart();
    const token = text.length > 1 ? text.slice(1) : '';
    const needle = token.toLowerCase();
    return this.commandRows.filter((row: CommandRow): boolean =>
      !needle || row.name.toLowerCase().includes(needle)).slice(0, 12);
  }

  private syncCommandPalette(): void {
    if (!this.commandPaletteActive()) { this.commandPalette = false; return; }
    this.commandPalette = true;
    if (this.commandState.stale()) void this.loadCommands();
  }

  private resetCommands(): void {
    this.commandState.reset();
    this.commandsLoading = false;
    this.commandError = '';
    this.commandPalette = false;
    this.commandRows = [];
    this.showComposerMenu = false;
  }

  private async loadCommands(): Promise<void> {
    if (!this.session.reachable || !this.session.currentId || this.session.openingSession) return;
    await this.commandState.load(this.session.currentId, (): Promise<BridgeReply> => this.request('/commands'), (list: CommandList): void => {
      this.commandError = list.error;
      if (list.rows) this.commandRows = list.rows;
      this.commandsLoading = list.loading;
    });
  }

  private pickCommand(row: CommandRow, prompt: string = ''): void {
    this.session.draft = commandDraft(row, prompt);
    this.commandPalette = false;
  }

  private openComposerMenu(): void {
    this.dismissKeyboard();
    this.showSkillPicker = false;
    this.showComposerMenu = true;
  }

  private openSkillPicker(): void {
    this.showSkillPicker = true;
    if (this.commandState.stale()) void this.loadCommands();
  }

  private pickSkill(row: CommandRow): void {
    this.session.draft = skillDraft(row, this.session.draft);
    this.commandPalette = false;
    this.voiceComposer.state.voiceMode = false;
    this.showComposerMenu = false;
  }

  private commandSourceLabel(source: string): string {
    if (source === 'skill') return '技能';
    if (source === 'prompt') return '模板';
    if (source === 'extension') return '扩展';
    return source;
  }

  private shareAttachmentHost(): ShareAttachmentHost {
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

  @SyncMonitor('appState.incomingShare')
  private onIncomingShare(): void { this.shareController.onIncomingShare(); }

  private shareTargetLocked(): boolean {
    return !!this.fileController.state.editingPath || this.fileController.state.savingPreview || this.scheduleController.state.schedulePage === 'editor' ||
      this.scheduleController.state.scheduleSaving || this.sessionActions.creation.showNewSession || this.sessionActions.creation.showNewSpace || this.addingComputer;
  }

  private prepareShareTarget(): boolean {
    if (this.shareTargetLocked()) return false;
    this.scheduleController.state.schedulePage = '';
    this.runCenter.state.reviewedRun = undefined;
    this.fileController.state.textFilePreview = undefined;
    if (this.fileController.state.markdownTableReader) this.fileController.closeMarkdownTableReader();
    return true;
  }

  private canAddShareToCurrent(): boolean {
    return this.isPaired && !!this.session.currentId && this.activeTab === 'tasks' && !this.showFiles && !this.session.showSettings &&
      !this.scheduleController.state.schedulePage && !this.runCenter.state.reviewedRun && !this.fileController.state.markdownTableReader && !this.fileController.state.textFilePreview &&
      !this.shareTargetLocked() && !this.drawerOpen();
  }

  private async openModelMenu(): Promise<void> {
    if (!this.session.reachable || !this.session.currentId || this.session.busy || this.session.openingSession) return;
    if (!this.session.idle || this.session.queued) { this.session.status = '等待当前任务和队列结束后可切换模型。'; return; }
    const epoch = this.session.epoch;
    this.session.busy = true;
    this.session.status = '';
    this.dismissKeyboard();
    try {
      const result = await this.request('/models');
      if (epoch !== this.session.epoch || result.session?.id !== this.session.currentId) return;
      this.session.models = result.models ?? [];
      if (!this.session.models.length) { this.session.status = '没有可用模型，请在电脑上检查 Pi CLI 的模型配置。'; return; }
      this.showModelMenu = true;
    } catch (error) {
      if (epoch !== this.session.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else if (error instanceof BridgeFailure && error.message === 'session_busy') this.session.status = '等待当前任务和队列结束后可切换模型。';
      else if (error instanceof BridgeFailure && error.message === 'model_not_found') this.session.status = '模型已不可用，请重新打开。';
      else this.session.status = '模型列表加载失败，请重试。';
    } finally { this.session.busy = false; }
  }

  private async applyModelFromMenu(index: number): Promise<void> {
    const model = this.session.models[index];
    if (!model) return;
    const level = model.levels.includes(this.session.currentLevel) ? this.session.currentLevel : model.levels[0] ?? 'off';
    await this.sessionActions.requestAction('/model', { id: this.session.currentId, provider: model.provider,
      modelId: model.id, thinkingLevel: level });
  }

  private async applyThinkingLevelFromMenu(level: string): Promise<void> {
    const model = this.session.currentModel ?? this.session.models.find((item: ModelOption): boolean => this.isCurrentModel(item));
    if (!model || level === this.session.currentLevel) return;
    await this.sessionActions.requestAction('/model', { id: this.session.currentId, provider: model.provider,
      modelId: model.id, thinkingLevel: level });
  }

  private thinkingLevelLabel(level: string): string {
    switch (level) {
      case 'off': return '关闭';
      case 'minimal': return '极简';
      case 'low': return '低';
      case 'medium': return '中';
      case 'high': return '高';
      case 'xhigh': return '极高';
      case 'max': return '最高';
      default: return level;
    }
  }

  private isCurrentModel(model: ModelOption): boolean {
    return this.session.currentModel?.provider === model.provider && this.session.currentModel?.id === model.id;
  }

  private bottomPad(): number {
    return this.keyboardHeight > 0 ? 0 : this.navBarHeight;
  }

  private headerHeight(): number {
    return this.windowHeight < SHORT_WINDOW_HEIGHT ? 52 : 60;
  }

  private dismissKeyboard(): void {
    // 焦点转移到页面根节点，软键盘随输入框失焦一并收起；
    // 再结束输入会话兑底，避免个别输入法在失焦后仍驻留。
    try {
      this.getUIContext().getFocusController().clearFocus();
      inputMethod.getController().stopInputSession().catch((): void => {});
    } catch { /* 键盘本就收起或输入法服务暂不可用时忽略。 */ }
  }

  private armTranscriptFollow(): void {
    // 键盘弹起时：原本就贴底则保持贴底（跟随压缩重贴），在翻历史则不打扰。
    const offset = this.transcript.currentOffset();
    if (!offset) return;
    const gap = this.transcriptContentHeight - this.transcriptViewport - offset.yOffset;
    this.session.transcriptFollow = gap <= 120;
    if (this.session.transcriptFollow) this.transcript.scrollEdge(Edge.Bottom);
  }

  @SyncMonitor('appState.keyboardHeight')
  private onKeyboardChange(): void {
    if (this.keyboardHeight <= 0 || this.activeTab !== 'tasks' || this.showFiles || this.session.showSettings ||
      this.showSessions || this.fileController.state.editingPath || this.fileController.state.textFilePreview) return;
    this.armTranscriptFollow();
  }

  private restoreSettings(): void {
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

  private async saveSetting(key: string, value: string | boolean): Promise<void> {
    const settings = this.settings;
    if (!settings) throw new Error('settings_unavailable');
    const write = this.settingsWrite.then(async () => {
      settings.putSync(key, value);
      await settings.flush();
    });
    this.settingsWrite = write.catch(() => {});
    return write;
  }

  private async setLiveViewsEnabled(enabled: boolean): Promise<void> {
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

  private accountSyncHost(): AccountSyncHost {
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

  private restoreCloudComputer(computer: CloudComputer): void {
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

  private removeCloudComputer(computer: CloudComputer): void {
    if (this.removeTarget !== computer.address || this.session.busy || !this.accountSync.state.huaweiProfile) return;
    this.removeTarget = '';
    this.accountSync.updateCloudComputer(computer.address, '');
  }

  private palette(): ThemePalette { return themePalette(this.themeId, this.darkMode); }

  private accent(): string { return this.palette().accent; }

  private accentTint(): string { return this.palette().accentTint; }

  private accentForeground(): string { return this.palette().accentForeground; }

  private themeCanvas(): string { return this.palette().canvas; }

  private selectTheme(id: string): void {
    this.appearanceNotice = '';
    this.themeId = id;
    appUiState().themeId = id;
    void this.saveSetting(SYNC_THEME, id).catch(() => { this.appearanceNotice = '未能保存主题配色。'; });
    this.accountSync.writeCloudRow({ key: SYNC_THEME, payload: id });
  }

  private async setThemeMotionEnabled(enabled: boolean): Promise<void> {
    this.themeMotionEnabled = enabled;
    await this.saveSetting(THEME_MOTION_SETTING, enabled).catch(() => { this.appearanceNotice = '未能保存动态效果设置。'; });
  }

  private applyAppearanceMode(mode: AppearanceMode): boolean {
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

  private selectAppearanceMode(mode: AppearanceMode): void {
    if (this.applyAppearanceMode(mode)) this.accountSync.writeCloudRow({ key: SYNC_MODE, payload: mode.id });
  }

  private openComputers(): void {
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

  private mineBack(): void {
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

  private closeComputerEditors(): void {
    this.renameComputerId = '';
    this.computerNameDraft = '';
    this.moveConnectionAddress = '';
  }

  private addComputerConnection(id: string = ''): void {
    this.closeComputerEditors();
    this.session.status = '';
    this.ticket = '';
    this.pairingBundle = '';
    this.lanCandidates = [];
    this.restoringComputer = undefined;
    this.pairingComputerId = id;
    this.addingComputer = true;
  }

  private saveComputerName(id: string): void {
    if (this.renameComputerId !== id || this.session.busy) return;
    this.computers = renameComputerGroup(this.computers, id, this.computerNameDraft);
    this.closeComputerEditors();
    this.dismissKeyboard();
    void this.persistComputers().catch(() => { this.session.status = '未能保存电脑备注。'; });
  }

  private assignComputerConnection(address: string, group?: ComputerGroup): void {
    if (this.moveConnectionAddress !== address || this.session.busy) return;
    this.computers = moveComputerConnection(this.computers, address, group?.id ?? util.generateRandomUUID(), group?.name ?? '');
    this.closeComputerEditors();
    void this.persistComputers().catch(() => { this.session.status = '未能保存连接归属。'; });
  }

  private computerConnectionMenu(record: Companion): MenuElement[] {
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

  private topContentClearance(): number {
    return this.statusBarHeight + this.headerHeight() + 14;
  }

  private bottomContentClearance(): number {
    return (this.showRootBottomTabs() ? this.bottomTabsHeight() + 18 : 0) + this.bottomPad() + 14;
  }

  private chatHasTopCards(): boolean {
    return (this.backgroundRunning().length > 0 && this.activeTab === 'tasks' && !this.showFiles &&
      !this.session.showSettings && !this.session.noSession && !!this.session.currentId) ||
      (!this.session.reachable && !this.offlineDismissed) || !!this.session.interaction || (!!this.session.pendingSend && !this.session.busy);
  }

  @Builder
  mineHeader() {
    Row({ space: 12 }) {
      if (this.minePage) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().attributeModifier(immersiveSurface(this.darkMode))
          .accessibilityText('返回').enabled(!this.session.busy).onClick(() => { this.mineBack(); })
      } else if (this.isPaired && !this.dockedSessions()) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.line_2_horizontal'), $r('app.color.pigo_text'), 20)
        }.id('history').headerAction().attributeModifier(immersiveSurface(this.darkMode))
          .accessibilityText('打开会话抽屉').enabled(!this.session.busy)
          .onClick(() => { this.setDrawer(true); })
      }
      Text(this.minePage === 'theme' ? '系统主题' : this.minePage === 'computers' ?
        (this.addingComputer ? (this.pairingComputerId ? '添加连接' : '添加电脑') : '电脑管理') : '我的')
        .fontSize(this.minePage ? 20 : 26).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).layoutWeight(1)
      if (!this.minePage && this.computers.length) this.scheduleInboxButton()
    }.width('100%').height(this.headerHeight())
  }

  @Builder
  mineView() {
    SettingsView({
      accountBusy: this.accountSync.state.accountBusy,
      active: this.visible && this.activeTab === 'mine',
      accountNotice: this.accountSync.state.accountNotice,
      addComputerConnection: (id?: string): void => this.addComputerConnection(id),
      addingComputer: this.addingComputer,
      address: this.address!!,
      appearanceNotice: this.appearanceNotice,
      assignComputerConnection: (address: string, group?: ComputerGroup): void => this.assignComputerConnection(address, group),
      avatarUnavailable: this.avatarUnavailable!!,
      base: this.base,
      bottomContentClearance: this.bottomContentClearance(),
      busy: this.session.busy,
      chooseComputer: (record: Companion): void => this.chooseComputer(record),
      closeComputerEditors: (): void => this.closeComputerEditors(),
      cloudComputers: this.accountSync.state.cloudComputers,
      cloudSyncBusy: this.accountSync.state.cloudSyncBusy,
      cloudSyncStatus: this.accountSync.state.cloudSyncStatus,
      computerConnectionMenu: (record: Companion): MenuElement[] => this.computerConnectionMenu(record),
      computerNameDraft: this.computerNameDraft!!,
      computers: this.computers,
      darkMode: this.darkMode,
      dismissKeyboard: (): void => this.dismissKeyboard(),
      findLanCompanions: (): Promise<void> => this.findLanCompanions(),
      huaweiProfile: this.accountSync.state.huaweiProfile,
      isPaired: this.isPaired,
      lanCandidates: this.lanCandidates,
      liveViewStatus: this.liveViewStatus,
      liveViewsEnabled: this.liveViewsEnabled,
      minePage: this.minePage!!,
      modeId: this.modeId,
      moveConnectionAddress: this.moveConnectionAddress,
      openingSession: this.session.openingSession,
      pair: (): Promise<void> => this.pair(),
      pairingBundle: this.pairingBundle!!,
      pairingComputerId: this.pairingComputerId,
      pairingMode: this.pairingMode,
      reachable: this.session.reachable,
      removeCloudComputer: (computer: CloudComputer): void => this.removeCloudComputer(computer),
      removeComputer: (address: string): void => this.removeComputer(address),
      removeTarget: this.removeTarget!!,
      renameComputerId: this.renameComputerId!!,
      restoreCloudComputer: (computer: CloudComputer): void => this.restoreCloudComputer(computer),
      restoringComputer: this.restoringComputer,
      runNoticesEnabled: this.runCenter.state.runNoticesEnabled,
      saveComputerName: (id: string): void => this.saveComputerName(id),
      scanPairingBundle: (): Promise<void> => this.scanPairingBundle(),
      scheduleCloudSync: (delay?: number): void => this.accountSync.scheduleCloudSync(delay),
      selectAppearanceMode: (mode: AppearanceMode): void => this.selectAppearanceMode(mode),
      selectPairingMode: (mode: string): void => this.selectPairingMode(mode),
      selectTheme: (id: string): void => this.selectTheme(id),
      setThemeMotionEnabled: (enabled: boolean): Promise<void> => this.setThemeMotionEnabled(enabled),
      themeMotionEnabled: this.themeMotionEnabled,
      setLiveViewsEnabled: (enabled: boolean): Promise<void> => this.setLiveViewsEnabled(enabled),
      setRunNoticesEnabled: (enabled: boolean): Promise<void> => this.runCenter.setRunNoticesEnabled(enabled),
      signInHuawei: (): Promise<void> => this.accountSync.signInHuawei(),
      signOutHuawei: (): Promise<void> => this.accountSync.signOutHuawei(),
      themeId: this.themeId,
      ticket: this.ticket!!,
      topContentClearance: this.topContentClearance(),
      accent: this.accent(),
      accentForeground: this.accentForeground(),
      accentTint: this.accentTint()
    })
  }

  @Builder
  workspaceFiles() {
    WorkspaceFiles({
      bottomContentClearance: this.bottomContentClearance(),
      busy: this.session.busy,
      fileRoot: this.fileController.state.fileRoot,
      fileTreeIndex: this.fileController.state.fileTreeIndex,
      fileTreeRows: this.fileController.state.fileTreeRows,
      loadFileDirectory: (path: string, more?: boolean): Promise<void> => this.fileController.loadFileDirectory(path, more),
      openFile: (cwd: string, path: string, lookupName?: boolean): Promise<void> => this.fileController.openFile(cwd, path, lookupName),
      openingSession: this.session.openingSession,
      project: this.session.project,
      toggleFileDirectory: (path: string): Promise<void> => this.fileController.toggleFileDirectory(path),
      topContentClearance: this.topContentClearance(),
      accent: this.accent(),
      setFileTreeIndex: (index: number): void => { this.fileController.state.fileTreeIndex = index; }
    })
  }

  @Builder
  toolDetailImages() {
    if (this.selectedTool && this.selectedToolDetails?.imageCount) {
      this.historyImages(this.selectedToolDetails.imageCount, this.session.currentId, this.selectedToolMessageId, this.selectedTool.id)
    }
  }

  @Builder
  toolDetailsSheet() {
    ToolDetailsSheet({
      selectedTool: this.selectedTool,
      selectedToolDetails: this.selectedToolDetails,
      idle: this.session.idle,
      toolDetailError: this.toolDetailError,
      accent: this.accent(),
      icon: this.selectedTool ? this.toolIcon(this.selectedTool) : $r('sys.symbol.doc'),
      path: this.selectedTool ? this.toolFile(this.selectedTool) : '',
      openingFile: this.fileController.state.openingFile,
      openFile: (path: string): Promise<void> => this.fileController.openReferencedFile(this.session.workspaceCwd, path, false),
      copyText: (value: string): Promise<void> => this.copyText(value),
      loadToolDetails: (): Promise<void> => this.loadToolDetails(),
      images: (): void => this.toolDetailImages()
    })
  }

  @Builder
  chatHeader() {
    Row({ space: 10 }) {
      if (this.session.showSettings) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().attributeModifier(immersiveSurface(this.darkMode)).accessibilityText('返回会话').onClick(() => { this.session.showSettings = false; })
      } else if (!this.dockedSessions()) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.line_2_horizontal'), $r('app.color.pigo_text'), 20)
        }.id('history').headerAction().attributeModifier(immersiveSurface(this.darkMode))
          .accessibilityText('打开会话抽屉').enabled(!this.session.busy)
          .onClick(() => { this.setDrawer(true); })
      }
      Column({ space: 3 }) {
        Text(this.showFiles ? '工作区文件' : this.session.showSettings ? '会话设置' : this.activeTab === 'pending' ? '任务' : this.splitOpen ? '分屏会话' : this.chatTitle())
          .fontSize(this.showFiles || this.session.showSettings ? 20 : 18).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (!this.session.showSettings) {
          Row({ space: 6 }) {
            Blank().width(7).height(7).borderRadius(4)
              .backgroundColor(this.session.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
              .accessibilityText(this.session.reachable ? '电脑已连接' : '电脑离线')
            if (this.session.currentAgent && this.session.currentAgent !== 'pi') {
              Text(this.session.currentAgent === 'codex' ? 'Codex' : this.session.currentAgent === 'agy' ? 'AGY' : this.session.currentAgent.toUpperCase())
                .fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.accent())
                .padding({ left: 5, right: 5, top: 1, bottom: 1 }).borderRadius(5)
                .backgroundColor(this.accentTint())
            }
            Text(this.session.reachable ? (this.session.project ? `${this.session.project} · ${this.computerTitle()}` : this.computerTitle()) :
              `离线 · ${this.computerTitle()}`)
              .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').onClick(() => { if (!this.dockedSessions()) this.setDrawer(true); })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.showFiles) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.arrow_clockwise'), $r('app.color.pigo_text'), 19)
        }.id('file-refresh').headerAction().attributeModifier(immersiveSurface(this.darkMode)).accessibilityText('刷新工作区')
          .enabled(!this.session.busy && !this.session.openingSession && this.session.reachable)
          .onClick(() => { void this.fileController.loadFileDirectory(''); })
      } else if (!this.session.showSettings) {
        Row({ space: 6 }) {
          this.scheduleInboxButton()
          Button({ type: ButtonType.Normal }) {
            headerSymbol($r('sys.symbol.square_and_pencil'), this.accent(), 19)
          }.id('new-task').headerAction().attributeModifier(immersiveSurface(this.darkMode)).accessibilityText('新建会话')
            .enabled(this.session.reachable && !this.session.busy && !this.session.openingSession && this.hostAvailable &&
              !!this.session.workspaceCwd && this.projects.includes(this.session.workspaceCwd))
            .onClick(() => { this.openNewSession('', this.session.currentAgent); })
          Button({ type: ButtonType.Normal }) {
            Stack() {
              Image($r('app.media.ic_more')).width(20).height(20).fillColor($r('app.color.pigo_text'))
            }.width('100%').height('100%').accessibilityLevel('no-hide-descendants')
          }.id('session-settings').headerAction().attributeModifier(immersiveSurface(this.darkMode)).accessibilityText('更多操作')
            .bindMenu(this.chatHeaderMenu())
        }
      }
    }.width('100%').height(this.headerHeight())
  }

  @Builder
  pageHeader() {
    Column() {
      if (this.activeTab === 'mine') {
        this.mineHeader()
      } else {
        this.chatHeader()
      }
    }.width('100%').padding({ left: 16, right: 16, top: this.statusBarHeight + 8, bottom: 12 })
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: canvasFadeStops(this.themeCanvas())
      })
  }

  @Builder
  chatTranscript(state: SessionViewState, focused: boolean, inSplit: boolean) {
    ChatTranscript({
      base: this.base,
      busy: state.busy,
      closeMarkdownTableReader: (): void => this.fileController.closeMarkdownTableReader(),
      copyText: (value: string): Promise<void> => this.copyText(value),
      replyActionsEnabled: focused && state.reachable && state.idle && !state.queued && !state.busy && !state.openingSession && !state.pendingSend,
      forkReply: (messageId: string): void => {
        void this.sessionActions.requestAction('/fork', { id: state.currentId, messageId: messageId, history: state.syncMode !== 'legacy' });
      },
      regenerateReply: (messageId: string): void => {
        if (this.voiceComposer.state.speakingReply === messageId) this.voiceComposer.stopReplySpeech();
        void this.sessionActions.requestAction('/regenerate', { id: state.currentId, messageId: messageId });
      },
      speakingReply: focused ? this.voiceComposer.state.speakingReply : '',
      toggleReplySpeech: (message: ChatMessage): void => {
        if (focused) void this.voiceComposer.toggleReplySpeech(message);
        else void this.focusOtherPane().then((ready: boolean): void => {
          if (ready) void this.voiceComposer.toggleReplySpeech(message);
        });
      },
      currentId: state.currentId,
      darkMode: this.darkMode,
      dismissKeyboard: (): void => this.dismissKeyboard(),
      historyCursor: state.historyCursor,
      idle: state.idle,
      keyboardHeight: this.keyboardHeight,
      $liveThinkingOpen: (open: boolean): void => { state.liveThinkingOpen = open; },
      liveText: state.liveText,
      liveThinking: state.liveThinking,
      liveThinkingOpen: state.liveThinkingOpen,
      liveTools: state.liveTools,
      loadHistory: (): Promise<void> => (focused ? this.streamSync : this.otherStream).loadHistory(),
      loadHistoryImage: (sessionId: string, messageId: string, index: number, toolId: string): Promise<string> => focused ? this.fileController.loadHistoryImage(sessionId, messageId, index, toolId) :
        this.fileController.loadHistoryImage(sessionId, messageId, index, toolId, state.workspaceCwd,
          (path: string): Promise<BridgeReply> => this.request(panePath(path, sessionId, state.workspaceCwd))),
      loadMarkdownImage: (target: string, cwd: string, documentPath: string): Promise<string> => this.fileController.loadMarkdownImage(target, cwd, documentPath),
      loadingMessageText: state.loadingMessageText,
      messages: state.messages,
      runResults: focused && this.runCenter.state.sessionRunKey === this.streamSync.draftKey(state.currentId) ? this.runCenter.state.sessionRuns : [],
      openRunResult: (run: RunEvent): void => this.runCenter.openRunResult(run),
      openMarkdownLink: (target: string, cwd: string, documentPath: string): Promise<void> => this.fileController.openMarkdownLink(target, cwd, documentPath),
      openMarkdownTableReader: (source: string, cwd: string, documentPath: string): void => this.fileController.openMarkdownTableReader(source, cwd, documentPath),
      openReferencedFile: (cwd: string, path: string, lookupName: boolean): Promise<void> => this.fileController.openReferencedFile(cwd, path, lookupName),
      openToolDetails: (tool: LiveTool, messageId: string): void => {
        if (focused) this.openToolDetails(tool, messageId);
        else void this.focusOtherPane().then((ready: boolean): void => {
          if (ready) this.openToolDetails(tool, messageId);
        });
      },
      openingFile: this.fileController.state.openingFile,
      positionTranscript: (id: string, contentHeight: number): void => {
        if (focused) this.positionTranscript(id, contentHeight);
        else this.positionOtherTranscript(id, contentHeight);
      },
      queuedSteering: state.queuedSteering,
      optimisticMessages: state.optimisticMessages,
      reachable: state.reachable,
      showChatImage: (source: string, label: string): void => this.fileController.showChatImage(source, label),
      showFullReply: (messageId: string): Promise<void> => (focused ? this.streamSync : this.otherStream).showFullReply(messageId),
      thinkingOpenIds: state.thinkingOpenIds,
      toggleThinking: (id: string, open: boolean): void => this.toggleThinking(id, open, state),
      transcript: focused ? this.transcript : this.otherTranscript,
      transcriptFollow: state.transcriptFollow,
      $transcriptFollow: (follow: boolean): void => { state.transcriptFollow = follow; },
      workspaceCwd: state.workspaceCwd,
      emptyTranscript: inSplit ? this.emptySplitTranscript.bind(this) : this.emptyTranscript.bind(this),
      accent: this.accent(),
      accentTint: this.accentTint(),
      themeId: this.themeId,
      topPadding: inSplit || this.chatHasTopCards() ? 10 : this.topContentClearance(),
      bottomPadding: inSplit ? 10 : this.chatBottomClearance(),
      scrollBottomOffset: inSplit ? 8 : this.chatScrollBottomOffset(),
      readTranscriptHeight: (): number => focused ? this.transcriptContentHeight : this.otherTranscriptHeight,
      setTranscriptViewport: (height: number): void => { if (focused) this.transcriptViewport = height; }
    })
  }

  private composerBottomMargin(): number {
    return (this.showRootBottomTabs() ? this.bottomTabsHeight() + 10 : 0) + this.bottomPad() + 8;
  }

  private chatScrollBottomOffset(): number {
    return this.composerBottomMargin() + (this.session.attachments.length ? 186 : 114);
  }

  private chatBottomClearance(): number {
    return this.composerBottomMargin() + (this.session.attachments.length ? 194 : 122);
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

  private splitPaneStatus(state: SessionViewState): string {
    if (!state.reachable) return '等待连接';
    if (state.interaction) return '待处理';
    if (state.queued) return '排队中';
    return state.idle ? '' : '运行中';
  }

  @Builder
  splitPane(state: SessionViewState, focused: boolean) {
    Column() {
      Row({ space: 4 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text(focused ? this.chatTitle() : this.otherId ? this.otherPaneTitle() : '选择第二个会话')
              .fontSize(14).fontWeight(FontWeight.Medium).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(focused ? this.accent() : $r('app.color.pigo_text')).layoutWeight(1)
            if ((focused || this.otherId) && this.splitPaneStatus(state)) {
              Text(this.splitPaneStatus(state)).fontSize(11).maxLines(1)
                .fontColor(state.interaction || !state.reachable ? $r('app.color.pigo_warning') : this.accent())
            }
          }.width('100%')
        }.id(focused ? 'split-focused-title' : 'split-other-title').height(44).layoutWeight(1)
          .padding({ left: 12, right: 3 }).backgroundColor(Color.Transparent)
          .accessibilitySelected(focused)
          .enabled(!this.splitNavigating && !this.session.openingSession && !this.session.busy)
          .onClick(() => {
            if (focused) return;
            if (this.otherId) void this.focusOtherPane();
            else this.setDrawer(true);
          })
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.xmark'), $r('app.color.pigo_muted'), 17)
        }.id(focused ? 'split-close-focused' : 'split-close-other').width(44).height(44)
          .padding(0).backgroundColor(Color.Transparent).accessibilityText(focused ? '关闭当前会话面板' : '关闭另一会话面板')
          .enabled(!this.splitNavigating && !this.session.openingSession && !this.session.busy)
          .onClick(() => { void this.closeSplitPane(focused); })
      }.width('100%').backgroundColor(focused ? this.accentTint() : $r('app.color.pigo_control'))
      if ((focused && state.currentId) || (!focused && this.otherId && state.currentId)) {
        if (focused && state.interaction) {
          Scroll() {
            PendingInteractionCard({
              request: state.interaction,
              interactionDraft: state.interactionDraft,
              reachable: state.reachable,
              busy: state.busy,
              openingSession: state.openingSession,
              accent: this.accent(),
              accentForeground: this.accentForeground(),
              answerInteraction: (id: string, answer: string | boolean): Promise<void> => this.answerInteraction(id, answer),
              changeDraft: (id: string, value: string): void => { if (id === state.interaction?.id) state.interactionDraft = value; }
            })
          }.constraintSize({ maxHeight: 150 }).width('100%')
        }
        if (focused && state.pendingSend && !state.busy) {
          Row({ space: 8 }) {
            Button('核对发送').chatAction().enabled(state.reachable).onClick(() => { void this.sessionActions.checkSend(); })
            Button('保留草稿').chatAction().onClick(() => {
              this.chatState.unconfirmed.delete(this.streamSync.draftKey(state.currentId));
              state.pendingSend = undefined;
              state.status = '已保留草稿，未重发。';
            })
          }.width('100%').padding(6)
        }
        this.chatTranscript(state, focused, true)
      } else {
        Column() {
          if (focused || this.otherId) {
            Text(state.noSession || '等待会话连接').fontSize(13).fontColor($r('app.color.pigo_muted'))
              .textAlign(TextAlign.Center)
          } else {
            Button('从会话列表选择').chatAction().id('choose-split-session')
              .onClick(() => { this.setDrawer(true); })
          }
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(12)
      }
    }.id(focused ? 'split-focused-pane' : 'split-other-pane').layoutWeight(1)
      .width(this.splitHorizontal() && !this.splitKeyboardCompact() ? undefined : '100%')
      .height(this.splitHorizontal() && !this.splitKeyboardCompact() ? '100%' : undefined)
      .borderRadius(12).border({ width: 1, color: focused ? this.accent() : $r('app.color.pigo_line') }).clip(true)
  }

  private mainPaneWidth(sidebar: number): number {
    return this.windowWidth - this.leftInset - this.rightInset - sidebar;
  }

  private splitHorizontal(): boolean {
    return this.mainPaneWidth(this.dockedSessions() ? this.sessionPaneWidth() : 0) >= 640;
  }

  private splitKeyboardCompact(): boolean {
    return !this.splitHorizontal() && this.keyboardHeight > 0 && this.windowHeight - this.keyboardHeight < 650;
  }

  @Builder
  splitConversation() {
    Flex({ direction: this.splitHorizontal() && !this.splitKeyboardCompact() ? FlexDirection.Row : FlexDirection.Column }) {
      if (this.splitKeyboardCompact()) {
        this.splitPane(this.session, true)
      } else if (this.focusedPaneFirst) {
        this.splitPane(this.session, true)
        Blank().width(this.splitHorizontal() ? 8 : '100%').height(this.splitHorizontal() ? '100%' : 8)
        this.splitPane(this.otherSession, false)
      } else {
        this.splitPane(this.otherSession, false)
        Blank().width(this.splitHorizontal() ? 8 : '100%').height(this.splitHorizontal() ? '100%' : 8)
        this.splitPane(this.session, true)
      }
    }.id('split-conversation').width('100%').height('100%')
      .padding({ left: 8, right: 8, top: this.topContentClearance(), bottom: this.chatBottomClearance() })
  }

  @Builder
  singleConversation() {
    Column() {
      if (this.chatHasTopCards()) {
        Column({ space: 8 }) {
          if (this.backgroundRunning().length && this.activeTab === 'tasks' && !this.showFiles &&
            !this.session.showSettings && !this.session.noSession && this.session.currentId) {
            RunningSessionStrip({
              rows: this.runningSessionPills(),
              canOpen: this.session.reachable && !this.session.busy && !this.session.openingSession,
              openSession: (id: string): void => {
                if (id === this.session.currentId || this.session.openingSession) return;
                this.activeTab = 'tasks';
                void this.sessionActions.requestAction('/open', { id: id });
              }
            })
          }
          if (!this.session.reachable && !this.offlineDismissed) {
            OfflineNotice({
              compact: false,
              narrow: false,
              busy: this.session.busy,
              retry: (): void => { this.offlineDismissed = false; this.streamSync.schedule(0); },
              dismiss: (): void => { this.offlineDismissed = true; },
              openComputers: (): void => this.openComputers()
            })
          }
          if (this.session.interaction) {
            PendingInteractionCard({
              request: this.session.interaction,
              interactionDraft: this.session.interactionDraft,
              reachable: this.session.reachable,
              busy: this.session.busy,
              openingSession: this.session.openingSession,
              accent: this.accent(),
              accentForeground: this.accentForeground(),
              answerInteraction: (id: string, answer: string | boolean): Promise<void> => this.answerInteraction(id, answer),
              changeDraft: (id: string, value: string): void => { if (id === this.session.interaction?.id) this.session.interactionDraft = value; }
            })
          }
          if (this.session.pendingSend && !this.session.busy) {
            Row({ space: 8 }) {
              Button('核对发送').chatAction().id('check-send').enabled(this.session.reachable).onClick(() => { void this.sessionActions.checkSend(); })
              Button('保留草稿').chatAction().id('keep-draft').onClick(() => {
                this.chatState.unconfirmed.delete(this.streamSync.draftKey(this.session.currentId));
                this.session.pendingSend = undefined;
                this.session.status = '已保留草稿，未重发。';
              })
            }.width('100%')
          }
        }.width('100%').padding({ left: 16, right: 16, top: this.topContentClearance() })
      }
      this.chatTranscript(this.session, true, false)
    }.width('100%').height('100%')
  }

  @Builder
  chat() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.showFiles) {
        Column() {
          this.workspaceFiles()
        }.width('100%').height('100%')
      } else if (this.session.showSettings) {
        SessionSettings({
        renameDraft: this.session.renameDraft,
        busy: this.session.busy,
        reachable: this.session.reachable,
        modelLabel: this.session.modelLabel,
        models: this.session.models,
        selectedModel: this.session.selectedModel,
        selectedLevel: this.session.selectedLevel,
        idle: this.session.idle,
        queued: this.session.queued,
        sharingSession: this.shareController.state.sharingSession,
        darkMode: this.darkMode,
        hasSession: !!this.session.currentId,
        accent: this.accent(),
        accentForeground: this.accentForeground(),
        topContentClearance: this.topContentClearance(),
        bottomPad: this.bottomPad(),
        changeName: (value: string): void => { this.session.renameDraft = value; },
        rename: (): void => { void this.sessionActions.requestAction('/rename', { id: this.session.currentId, name: this.session.renameDraft.trim() }); },
        selectModel: (index: number): void => {
          this.session.selectedModel = index;
          const model = this.session.models[index];
          if (model && !model.levels.includes(this.session.selectedLevel)) this.session.selectedLevel = model.levels[0] ?? 'off';
        },
        selectLevel: (level: string): void => { this.session.selectedLevel = level; },
        applyModel: (): void => {
          const model = this.session.models[this.session.selectedModel];
          if (model) void this.sessionActions.requestAction('/model', { id: this.session.currentId, provider: model.provider,
            modelId: model.id, thinkingLevel: this.session.selectedLevel });
        },
        share: (): void => { void this.shareController.shareCurrentSession('session-share'); },
        thinkingLevelLabel: (level: string): string => this.thinkingLevelLabel(level)
      })
      } else if (this.activeTab === 'pending') {
        Column() {
          this.taskView()
        }.width('100%').height('100%')
      } else if (this.session.noSession && !this.splitOpen) {
        Column() {
          this.welcome()
        }.width('100%').height('100%')
      } else {
        Stack({ alignContent: Alignment.Bottom }) {
        if (this.splitOpen) {
          this.splitConversation()
        } else {
          this.singleConversation()
        }
        Column({ space: 6 }) {
          if (this.commandPalette && this.commandPaletteActive()) {
            Column({ space: 2 }) {
              if (!this.commandMatches().length) {
                Text(this.commandsLoading ? '正在加载命令…' : !this.session.reachable ? '电脑离线，等待重连' :
                  this.commandError || (this.commandRows.length ? '没有匹配的命令' : '暂无可用命令'))
                  .fontSize(13).fontColor($r('app.color.pigo_muted')).padding({ left: 10, right: 10, top: 10, bottom: 10 }).maxLines(2)
                  .onClick(() => { if (this.commandError) void this.loadCommands(); })
              } else {
                Scroll() {
                  Column({ space: 2 }) {
                    ForEach(this.commandMatches(), (row: CommandRow) => {
                      Column({ space: 2 }) {
                        Row({ space: 8 }) {
                          Text(row.invoke ?? `/${row.name}`).fontSize(14).fontWeight(FontWeight.Medium)
                            .fontColor($r('app.color.pigo_text')).maxLines(1).layoutWeight(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                          if (row.source) {
                            Text(this.commandSourceLabel(row.source)).fontSize(10).fontColor($r('app.color.pigo_muted'))
                              .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(8)
                              .backgroundColor($r('app.color.pigo_control')).maxLines(1)
                          }
                        }.width('100%')
                        if (row.description) {
                          Text(row.description).fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                        }
                      }.alignItems(HorizontalAlign.Start).width('100%').padding({ left: 10, right: 10, top: 7, bottom: 7 })
                      .borderRadius(10).id(`command-row-${row.name}`)
                      .onClick(() => { this.pickCommand(row); })
                    }, (row: CommandRow) => row.name)
                  }.width('100%')
                }.constraintSize({ maxHeight: this.keyboardHeight || this.windowHeight < SHORT_WINDOW_HEIGHT ? 132 : 216 })
                  .width('100%').edgeEffect(EdgeEffect.Spring)
              }
            }.width('100%').padding(6)
            .attributeModifier(glassComposerSurface(this.darkMode, true))
            .id('command-palette')
          }
          this.composer()
        }.width('100%').padding({
          left: 16,
          right: 16,
          bottom: this.composerBottomMargin()
        }).animation({ duration: 240, curve: Curve.FastOutSlowIn })
        }.width('100%').height('100%')
      }
    }.width('100%').layoutWeight(1)
  }

  @Builder
  composer() {
    ChatComposer({
      darkMode: this.darkMode,
      acceptsImage: this.session.acceptsImage,
      applyModelFromMenu: (index: number): Promise<void> => this.applyModelFromMenu(index),
      applyThinkingLevelFromMenu: (level: string): Promise<void> => this.applyThinkingLevelFromMenu(level),
      armTranscriptFollow: (): void => this.armTranscriptFollow(),
      attachFile: (): Promise<void> => this.shareController.attachFile(),
      attachImage: (source: string): Promise<void> => this.shareController.attachImage(source),
      attachments: this.session.attachments,
      busy: this.session.busy,
      commandError: this.commandError,
      commandRows: this.commandRows,
      commandsLoading: this.commandsLoading,
      currentId: this.session.currentId,
      currentLevel: this.session.currentLevel,
      currentModel: this.session.currentModel,
      dismissKeyboard: (): void => this.dismissKeyboard(),
      draft: this.session.draft!!,
      sendTarget: this.splitOpen ? this.chatTitle() : '',
      holdCancel: this.voiceComposer.state.holdCancel,
      holdTouch: (event: TouchEvent): void => this.voiceComposer.holdTouch(event),
      idle: this.session.idle,
      liveVoiceText: this.voiceComposer.state.liveVoiceText!!,
      loadCommands: (): Promise<void> => this.loadCommands(),
      modelLabel: this.session.modelLabel,
      models: this.session.models,
      openComposerMenu: (): void => this.openComposerMenu(),
      openModelMenu: (): Promise<void> => this.openModelMenu(),
      openSkillPicker: (): void => this.openSkillPicker(),
      openingSession: this.session.openingSession || this.splitNavigating,
      hasPendingSend: this.session.pendingSend !== undefined,
      pickSkill: (row: CommandRow): void => this.pickSkill(row),
      queued: this.session.queued,
      reachable: this.session.reachable,
      recording: this.voiceComposer.state.recording,
      removeAttachment: (index: number): void => this.shareController.removeAttachment(index),
      requestAction: (path: string, input?: Payload): Promise<boolean> => this.sessionActions.requestAction(path, input),
      runId: this.session.runId,
      send: (): Promise<void> => this.sessionActions.send(),
      showComposerMenu: this.showComposerMenu!!,
      showModelMenu: this.showModelMenu!!,
      showSkillPicker: this.showSkillPicker!!,
      status: this.session.status!!,
      syncCommandPalette: (): void => this.syncCommandPalette(),
      voiceCancelling: this.voiceComposer.state.voiceCancelling,
      voiceFinishing: this.voiceComposer.state.voiceFinishing,
      voiceMode: this.voiceComposer.state.voiceMode!!,
      voicePreparing: this.voiceComposer.state.voicePreparing,
      windowHeight: this.windowHeight,
      windowWidth: this.windowWidth,
      accent: this.accent(),
      accentForeground: this.accentForeground(),
      accentTint: this.accentTint()
    })
  }

  private positionTranscript(id: string, contentHeight: number): void {
    if (id !== this.session.currentId || contentHeight <= 0) return;
    this.transcriptContentHeight = contentHeight;
    if (this.pendingFocusedPosition === id) {
      this.pendingFocusedPosition = '';
      if (this.restoreSplitPosition(id, this.transcript)) {
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

  private swipeDrawer(event: GestureEvent): void {
    if (Math.abs(event.offsetX) <= 45 || Math.abs(event.offsetX) <= Math.abs(event.offsetY) * 1.3) return;
    if (this.showSessions) {
      if (event.offsetX < 0) this.setDrawer(false);
    } else if (event.offsetX > 0 && !this.session.busy) {
      if (!this.session.showSettings && !(this.activeTab === 'mine' && this.minePage)) this.setDrawer(true);
    }
  }

  private setDrawer(open: boolean): void {
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

  private dockedSessions(): boolean {
    return this.isPaired && this.windowWidth >= SPLIT_WINDOW_WIDTH &&
      (!this.splitOpen || this.mainPaneWidth(this.sessionPaneWidth()) >= 640);
  }

  private drawerOpen(): boolean {
    return this.showSessions && this.isPaired && !this.dockedSessions();
  }

  private drawerWidth(): number {
    return Math.min(420, this.windowWidth * 0.82);
  }

  private sessionPaneWidth(preferred: number | undefined = this.preferredSessionPaneWidth): number {
    const width = preferred ?? Math.max(224, Math.min(288, Math.floor(this.windowWidth * 0.34)));
    return Math.max(160, Math.min(width, 420, this.windowWidth - 360));
  }

  private compactSessionPane(): boolean {
    if (this.dockedSessions()) return this.sessionPaneWidth() < 208;
    return this.windowWidth > 0 && this.drawerWidth() < 208;
  }

  @SyncMonitor('appState.windowWidth')
  private onWindowWidthChange(): void {
    // Once the list is docked, folding back should leave the conversation visible.
    if (this.dockedSessions()) this.showSessions = false;
  }

  @SyncMonitor('appState.keyboardHeight', 'appState.windowWidth', 'appState.windowHeight')
  private onSplitViewportChange(): void {
    if (!this.splitOpen) return;
    const compact = this.splitKeyboardCompact();
    if (compact === this.wasSplitKeyboardCompact) return;
    this.saveSplitPosition(this.session, this.transcript);
    this.pendingFocusedPosition = this.session.currentId;
    if (compact) this.saveSplitPosition(this.otherSession, this.otherTranscript);
    else this.pendingOtherPosition = this.otherId;
    this.wasSplitKeyboardCompact = compact;
  }

  @SyncMonitor('session.currentId')
  private onFocusedSessionChange(): void {
    if (this.launchedNativeWindow) {
      findConversationWindow(this.base, this.session.currentId)?.close();
    }
    if (this.splitOpen && !this.splitNavigating && this.otherId && this.session.currentId === this.otherId) {
      this.clearSplit();
    }
  }

  @SyncMonitor('sessions', 'expandedSpaces', 'sessionView', 'loadedView', 'projects', 'workspaces', 'workspacePages', 'sessionNextCursor')
  private updateSidebarRows(): void {
    this.sidebarRows.replace(this.sessionStore.rows({
      view: this.sessionView, loadedView: this.loadedView, sessions: this.sessions, projects: this.projects,
      workspaces: this.workspaces, expandedSpaces: this.expandedSpaces,
      workspacePages: this.workspacePages, nextCursor: this.sessionNextCursor
    }));
    if (this.pendingLibraryReveal) setTimeout(() => { this.revealLibraryAnchor(); }, 0);
  }

  private onSidebarAppear(): void {
    this.pendingLibraryReveal = !!this.session.currentId;
    this.updateSidebarRows();
  }

  private revealLibraryAnchor(): void {
    if (!this.pendingLibraryReveal || (!this.showSessions && !this.dockedSessions())) return;
    if (this.library.currentOffset().yOffset > 2) { this.pendingLibraryReveal = false; return; }
    const anchor = this.sidebarRows.anchor(this.session.currentId, this.session.workspaceCwd);
    if (anchor < 0) return;
    this.pendingLibraryReveal = false;
    if (anchor > 0) this.library.scrollToIndex(anchor, false, ScrollAlign.START);
  }

  private chatTitle(): string {
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

  private updateCachedSessionTitle(id: string, name?: string): void {
    if (!name) return;
    const index = this.sessions.findIndex((row: SessionRow): boolean => row.id === id && row.name !== name);
    if (index < 0) return;
    const rows = this.sessions.slice();
    rows[index].name = name;
    this.sessions = rows;
  }

  private computerTitle(): string {
    const record = this.computers.find((item: Companion): boolean => item.address === this.base);
    return record?.computerName || (validUsb(this.base) ? 'USB 电脑' : (this.base.split('://')[1] || '我的电脑'));
  }

  private toggleSpace(path: string): void {
    this.pendingLibraryReveal = false;
    this.expandedSpaces = this.sessionStore.toggleSpace(this.expandedSpaces, path);
    if (this.expandedSpaces.includes(path)) void this.loadWorkspacePage(path);
  }

  private sessionViewLabel(view: string): string {
    return view === 'all' ? '工作区' : view === 'pinned' ? '置顶' : view === 'recent' ? '最近' : '归档';
  }

  private selectSessionView(view: string): void {
    if (this.session.busy || this.sessionLoading || !this.session.reachable) return;
    this.sessionView = view;
    this.sessionNextCursor = undefined;
    void this.loadSessions();
  }

  private sessionViewOptions(): MenuElement[] {
    return SIDEBAR_VIEWS.map((view: string): MenuElement => ({
      value: this.sessionViewLabel(view), action: (): void => { this.selectSessionView(view); }
    }));
  }

  private resetCatalog(): void {
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

  private tabSymbol(tab: string, selected: boolean): Resource {
    if (tab === 'tasks') return selected ? $r('sys.symbol.message_fill') : $r('sys.symbol.message');
    if (tab === 'pending') return selected ? $r('sys.symbol.play_circle_fill') : $r('sys.symbol.play_circle');
    if (tab === 'files') return selected ? $r('sys.symbol.folder_fill') : $r('sys.symbol.folder');
    return selected ? $r('sys.symbol.person_fill') : $r('sys.symbol.person');
  }

  private bottomTabsHeight(): number {
    return this.windowHeight < SHORT_WINDOW_HEIGHT ? 48 : 60;
  }

  private rootTabs(): string[] {
    return this.isPaired ? ['tasks', 'pending', 'files', 'mine'] : ['tasks', 'mine'];
  }

  private activeTabIndex(): number {
    const index = this.rootTabs().indexOf(this.activeTab);
    return index >= 0 ? index : 0;
  }

  private selectRootTab(tab: string): boolean {
    this.dismissKeyboard();
    if (this.session.busy) return false;
    if (this.fileController.state.editingPath && this.fileController.state.fileText !== this.fileController.state.fileOriginal) {
      this.session.status = '请先保存或放弃文件修改。';
      return false;
    }
    if (tab === 'files') {
      if (!this.session.reachable || !this.session.workspaceCwd) {
        this.session.status = '请先连接电脑并打开一个任务。';
        return false;
      }
      if (this.activeTab === 'files' && this.showFiles) return true;
      this.showFiles = true;
      this.session.status = '';
      this.fileController.showDirectory(this.session.workspaceCwd);
    } else {
      this.showFiles = false;
      this.session.showSettings = false;
    }
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
    if (tab === 'pending') void this.scheduleController.loadScheduleJobs();
    return true;
  }

  @Builder
  rootTabBar(tab: string) {
    Column({ space: 3 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Row() {
          SymbolGlyph(this.tabSymbol(tab, this.activeTab === tab)).fontSize(23)
            .fontColor([this.activeTab === tab ? this.accent() : $r('app.color.pigo_muted')])
            .accessibilityLevel('no')
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
        if (tab === 'pending' && this.runningTaskCount()) {
          Text(this.runningTaskCount() > 9 ? '9+' : `${this.runningTaskCount()}`)
            .fontSize(9).fontWeight(FontWeight.Medium).fontColor(this.accentForeground())
            .textAlign(TextAlign.Center).constraintSize({ minWidth: 14 }).height(14)
            .padding({ left: 2, right: 2 }).backgroundColor(this.accent()).borderRadius(7)
        }
      }.width(48).height(25)
      Text(tab === 'tasks' ? '会话' : tab === 'pending' ? '任务' : tab === 'files' ? '工作区' : '我的')
        .fontSize(11).fontWeight(this.activeTab === tab ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeTab === tab ? this.accent() : $r('app.color.pigo_muted'))
    }.id(`tab-${tab}`).width('100%').height('100%').justifyContent(FlexAlign.Center)
      .accessibilitySelected(this.activeTab === tab)
  }

  @Builder
  welcome(inTranscript: boolean = false) {
    Column({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.code_square')).fontSize(31).fontColor([this.accent()])
      }.width(60).height(60).borderRadius(18).backgroundColor(this.accentTint()).accessibilityLevel('no')
      Text(!this.isPaired || this.loading ? 'Pi Go' : inTranscript ? '开始新任务' : '选择一个任务')
        .fontSize(this.isPaired && !this.loading ? 24 : 36).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.pigo_text')).textAlign(TextAlign.Center)
      Text(this.loading ? '正在读取已配对的电脑…' : !this.isPaired ? '连接电脑后查看和继续任务。' :
        this.session.noSession || (this.session.reachable ? '输入你的目标，或添加文件作为上下文。' : '电脑重新连接后即可发送消息。'))
        .fontSize(15).fontColor($r('app.color.pigo_muted')).textAlign(TextAlign.Center).lineHeight(23)
        .constraintSize({ maxWidth: 320 })
      if (!this.loading && !this.isPaired) {
        Button('连接电脑').chatAction().height(46).padding({ left: 24, right: 24 })
          .backgroundColor(this.accent()).fontColor(this.accentForeground()).onClick(() => { this.openComputers(); })
      } else if (!this.loading && this.session.noSession && !this.dockedSessions()) {
        Button('打开任务列表').chatAction().height(44).padding({ left: 18, right: 18 })
          .backgroundColor(this.accent()).fontColor(this.accentForeground()).onClick(() => { this.setDrawer(true); })
      }
    }.width('100%').padding({ top: inTranscript && this.windowHeight >= SHORT_WINDOW_HEIGHT ? 36 : 8,
      bottom: inTranscript && this.windowHeight >= SHORT_WINDOW_HEIGHT ? 24 : 8, left: 16, right: 16 })
      .layoutWeight(inTranscript ? 0 : 1).justifyContent(FlexAlign.Center)
  }

  @Builder
  taskView() {
    TaskPanel({
      darkMode: this.darkMode,
      topClearance: this.topContentClearance(),
      bottomClearance: this.bottomContentClearance(),
      runningRows: this.taskPanelRows(),
      scheduleRuns: this.standaloneScheduleRuns(),
      currentId: this.session.currentId,
      busy: this.session.busy,
      openingSession: this.session.openingSession,
      accentTint: this.accentTint(),
      openRunningTask: (id: string): void => {
        if (id !== this.session.currentId) void this.sessionActions.requestAction('/open', { id: id });
        this.activeTab = 'tasks';
      },
      editSchedule: (job?: ScheduleJob): void => this.scheduleController.editSchedule(job),
      loadScheduleJobs: (): Promise<void> => this.scheduleController.loadScheduleJobs(),
      projects: this.projects,
      reachable: this.session.reachable,
      scheduleError: this.scheduleController.state.scheduleError!!,
      scheduleJobMenu: (job: ScheduleJob): MenuElement[] => this.scheduleJobMenu(job),
      scheduleJobs: this.scheduleController.state.scheduleJobs,
      scheduleListError: this.scheduleController.state.scheduleListError,
      scheduleLoaded: this.scheduleController.state.scheduleLoaded,
      schedulePage: this.scheduleController.state.schedulePage!!,
      scheduleSaving: this.scheduleController.state.scheduleSaving,
      workspaces: this.workspaces,
      accent: this.accent(),
      accentForeground: this.accentForeground()
    })
  }

  @Builder
  sessionDrawer() {
    SessionSidebar({
      darkMode: this.darkMode,
      base: this.base,
      busy: this.session.busy,
      canCreateWorkspace: this.canCreateWorkspace,
      confirmCloseSpace: (path: string, epoch: number): void => this.confirmCloseSpace(path, epoch),
      openNewSession: (path?: string): void => this.openNewSession(path),
      currentId: this.session.currentId,
      expandedSpaces: this.expandedSpaces,
      hostAvailable: this.hostAvailable,
      idle: this.session.idle,
      interaction: this.session.interaction,
      library: this.library,
      loadMoreSessions: (path: string): void => {
        if (!path) void this.loadSessions(true);
        else {
          const page = this.workspacePages.find((item: WorkspacePage): boolean => item.path === path);
          const retryRefresh = page?.retryRefresh === true;
          void this.loadWorkspacePage(path, !retryRefresh && page?.nextCursor !== undefined, retryRefresh);
        }
      },
      loadedView: this.loadedView,
      offlineDismissed: this.offlineDismissed!!,
      openComputers: (): void => this.openComputers(),
      openingSession: this.session.openingSession,
      openingSessionId: this.session.openingSessionId,
      projects: this.projects,
      queued: this.session.queued,
      reachable: this.session.reachable,
      refreshSessions: (): Promise<void> => this.session.reachable ? this.loadSessions(false, true) : Promise.resolve(),
      splitSessionId: this.otherId,
      choosingSplitSession: this.splitOpen && !this.otherId,
      openSession: (row: SessionRow): void => this.openSidebarSession(row, false),
      openInSplit: (row: SessionRow): void => this.openSidebarSession(row, true),
      openInSystemSplit: (row: SessionRow): void => { void this.openInSystemSplit(row); },
      revealLibraryAnchor: (): void => this.revealLibraryAnchor(),
      runningSessionIds: this.runningSessionIds,
      runningSessions: this.runningSessions,
      schedule: (delay: number): void => this.streamSync.schedule(delay),
      selectSessionView: (view: string): void => this.selectSessionView(view),
      sessionCatalogFailed: this.sessionCatalogFailed,
      sessionCatalogLoaded: this.sessionCatalogLoaded,
      sessionLoading: this.sessionLoading,
      sessionView: this.sessionView,
      sessions: this.sessions,
      setDrawer: (open: boolean): void => this.setDrawer(open),
      sidebarRows: this.sidebarRows,
      statusBarHeight: this.statusBarHeight,
      swipeDrawer: (event: GestureEvent): void => this.swipeDrawer(event),
      toggleSpace: (path: string): void => this.toggleSpace(path),
      updateSessionMeta: (session: SessionRow, pin: boolean): Promise<void> => this.updateSessionMeta(session, pin),
      shareSession: (session: SessionRow): Promise<void> => this.shareController.shareSidebarSession(session),
      windowHeight: this.windowHeight,
      workspaces: this.workspaces,
      accent: this.accent(),
      accentForeground: this.accentForeground(),
      accentTint: this.accentTint(),
      bottomPad: this.bottomPad(),
      compactSessionPane: this.compactSessionPane(),
      computerTitle: this.computerTitle(),
      dockedSessions: this.dockedSessions(),
      drawerWidth: this.drawerWidth(),
      sessionPaneWidth: this.sessionPaneWidth(),
      onDrawerAppear: (): void => { this.onSidebarAppear(); },
      connectionEpoch: (): number => this.session.epoch
    })
  }

  @Builder
  sessionPaneHandle() {
    Stack() {
      Rect().width(4).height(44).radius(2)
        .fill(this.sessionPaneDragging ? this.accent() : $r('app.color.pigo_muted'))
    }.id('session-pane-resize').width(20).height('100%').offset({ x: this.sessionPaneWidth() - 10 })
      .accessibilityText('左右拖动调整任务侧边栏宽度')
      .gesture(PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart(() => {
          this.sessionPaneDragStart = this.sessionPaneWidth();
          this.sessionPaneDragging = true;
        })
        .onActionUpdate((event: GestureEvent) => {
          this.preferredSessionPaneWidth = this.sessionPaneWidth(this.sessionPaneDragStart + event.offsetX);
        })
        .onActionEnd(() => { this.sessionPaneDragging = false; })
        .onActionCancel(() => { this.sessionPaneDragging = false; }))
      .onDisAppear(() => { this.sessionPaneDragging = false; })
  }

  private showRootBottomTabs(): boolean {
    if (this.loading) return false;
    if (this.activeTab === 'mine' && this.minePage) return false;
    if (this.session.showSettings) return false;
    if (!this.keyboardHeight) return true;
    return this.isPaired && this.activeTab !== 'mine' && (this.activeTab !== 'tasks' || this.showFiles);
  }

  @Builder
  statusNotice() {
    Row({ space: 8 }) {
      Text(this.session.status).fontColor($r('app.color.pigo_warning')).fontSize(13).layoutWeight(1)
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([$r('app.color.pigo_warning')])
      }.width(30).height(30).padding(0).borderRadius(8).backgroundColor(Color.Transparent)
        .accessibilityText('关闭提示').onClick(() => { this.session.status = ''; })
    }.width('100%').padding({ left: 12, right: 6, top: 8, bottom: 8 })
      .attributeModifier(glassCardSurface(this.darkMode, 14, true))
  }

  @Builder
  textPreviewMarkdown() {
    if (this.fileController.state.textFilePreview?.text !== undefined) {
      this.richChatText(this.fileController.state.textFilePreview.text, this.fileController.state.textFilePreview.workspaceRoot ?? '',
        this.fileController.state.textFilePreview.workspacePath ?? '')
    }
  }

  @Builder
  tableReaderMarkdown() {
    if (this.fileController.state.markdownTableReader) {
      this.richChatText(this.fileController.state.markdownTableReader.source, this.fileController.state.markdownTableReader.cwd,
        this.fileController.state.markdownTableReader.documentPath, false)
    }
  }

  @Builder
  mainNavigation() {
    Navigation() {
      Stack({ alignContent: Alignment.Bottom }) {
        Tabs({ barPosition: BarPosition.End, index: this.activeTabIndex() }) {
          ForEach(this.rootTabs(), (tab: string) => {
            TabContent() {
              Column() {
                if (this.loading) {
                  this.welcome()
                } else if (tab === 'mine') {
                  this.mineView()
                } else if (!this.isPaired) {
                  this.welcome()
                } else if (tab === 'files') {
                  this.workspaceFiles()
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
        .barHeight(this.showRootBottomTabs() ? this.bottomTabsHeight() : 0)
        .barBackgroundColor(Color.Transparent)
        .attributeModifier(immersiveFloatingTabs(this.showRootBottomTabs(), this.bottomPad() + 8, this.darkMode))
        .onContentWillChange((_from: number, to: number): boolean => {
          const tab = this.rootTabs()[to];
          return !!tab && this.selectRootTab(tab);
        })
        .onTabBarClick((index: number) => {
          const tab = this.rootTabs()[index];
          if (tab && tab === this.activeTab) this.selectRootTab(tab);
        })
        if (!this.loading && this.session.status) {
          Column() {
            this.statusNotice()
          }.width('100%').padding({
            left: 16,
            right: 16,
            bottom: (this.showRootBottomTabs() ? this.bottomTabsHeight() + 14 : 0) + this.bottomPad() + 8
          }).hitTestBehavior(HitTestMode.Transparent)
        }
      }.width('100%').height('100%')
    }.width('100%').height('100%').constraintSize({ maxWidth: this.activeTab === 'mine' || this.session.showSettings ? 600 : 840 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .title({ builder: this.pageHeader, height: this.headerHeight() + this.statusBarHeight + 20 }, {
        backgroundColor: Color.Transparent,
        barStyle: BarStyle.STACK
      })
      .hideTitleBar(this.loading || (!this.isPaired && this.activeTab !== 'mine'))
  }

  private confirmDeleteSchedule(job: ScheduleJob): void {
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

  private scheduleJobMenu(job: ScheduleJob): MenuElement[] {
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

  private openScheduleTimePicker(): void {
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

  @Builder
  scheduleInboxButton() {
    Button({ type: ButtonType.Normal }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Stack() {
          headerSymbol($r('sys.symbol.inbox'), $r('app.color.pigo_text'), 19)
        }.width('100%').height('100%')
        if (this.scheduleController.state.scheduleMessages.some((item: RunMessage): boolean => item.unread) || this.runCenter.displayedInboxRuns().some((item: InboxRun): boolean => item.unread)) {
          Blank().width(8).height(8).borderRadius(4).backgroundColor(this.accent())
            .margin({ top: 9, right: 9 })
        }
      }.width('100%').height('100%')
    }.id('schedule-inbox').headerAction().attributeModifier(immersiveSurface(this.darkMode)).accessibilityText(this.scheduleController.state.scheduleMessages.some((item: RunMessage): boolean =>
      item.unread) || this.runCenter.displayedInboxRuns().some((item: InboxRun): boolean => item.unread) ? '收件箱，有未读消息' : '收件箱')
      .onClick(() => { this.showScheduleInbox(); })
  }

  @Builder
  scheduleOverlay() {
    ScheduleOverlay({
      darkMode: this.darkMode,
      backFromSchedule: (): void => this.scheduleController.backFromSchedule(),
      base: this.base,
      busy: this.session.busy,
      computers: this.computers,
      deleteScheduleRuns: (messages: RunMessage[]): Promise<boolean> => this.scheduleController.deleteScheduleRuns(messages),
      dismissInboxRuns: (ids: string[]): Promise<boolean> => this.runCenter.dismissInboxRuns(ids),
      dismissScheduleMessage: (message: RunMessage): void => this.scheduleController.dismissScheduleMessage(message),
      isPaired: this.isPaired,
      openScheduleTimePicker: (): void => this.openScheduleTimePicker(),
      openScheduledSession: (message: RunMessage): Promise<void> => this.openScheduledSession(message),
      openingSession: this.session.openingSession,
      inboxRuns: this.runCenter.displayedInboxRuns(),
      openInboxRun: (row: InboxRun): Promise<void> => this.runCenter.openInboxRun(row),
      pushEnabled: this.runCenter.state.pushEnabled,
      pushSaving: this.runCenter.state.pushSaving,
      pushStatus: this.runCenter.state.pushStatus,
      setPushEnabled: (enabled: boolean): Promise<void> => this.runCenter.setPushEnabled(enabled),
      projects: this.projects,
      scheduleCatchUp: this.scheduleController.state.scheduleCatchUp!!,
      scheduleCwd: this.scheduleController.state.scheduleCwd!!,
      scheduleDetail: this.scheduleController.state.scheduleDetail,
      scheduleEditing: this.scheduleController.state.scheduleEditing,
      scheduleError: this.scheduleController.state.scheduleError,
      scheduleKind: this.scheduleController.state.scheduleKind!!,
      scheduleMessages: this.scheduleController.state.scheduleMessages,
      scheduleName: this.scheduleController.state.scheduleName!!,
      scheduleOffline: this.scheduleController.state.scheduleOffline,
      schedulePage: this.scheduleController.state.schedulePage,
      schedulePrompt: this.scheduleController.state.schedulePrompt!!,
      scheduleSaving: this.scheduleController.state.scheduleSaving || this.runCenter.state.inboxCleaning,
      scheduleWhen: this.scheduleController.state.scheduleWhen!!,
      scheduleZone: this.scheduleController.state.scheduleZone,
      showScheduleDetail: (message: RunMessage): void => this.scheduleController.showScheduleDetail(message),
      statusBarHeight: this.statusBarHeight,
      updateSchedule: (operation: string, job?: ScheduleJob): Promise<void> => this.scheduleController.updateSchedule(operation, job),
      workspaces: this.workspaces,
      accent: this.accent(),
      accentForeground: this.accentForeground(),
      accentTint: this.accentTint(),
      canvasBg: this.themeCanvas(),
      themeId: this.themeId,
      headerHeight: this.headerHeight(),
      bottomPad: this.bottomPad(),
      computerTitle: this.computerTitle()
    })
  }

  private sakuraConversationFocus(): boolean {
    return this.activeTab !== 'mine' &&
      (this.session.messages.length > 0 || this.session.optimisticMessages.length > 0 ||
        !!this.session.liveText || !!this.session.liveThinking || this.session.liveTools.length > 0);
  }

  private sakuraGirlInteractive(): boolean {
    return this.themeId === 'sakura' && this.activeTab === 'tasks' && !this.showFiles && !this.session.showSettings &&
      !this.sakuraConversationFocus() && !this.drawerOpen() && this.keyboardHeight <= 0;
  }

  private triggerSakuraBloom(x: number, y: number): void {
    this.sakuraBloomX = x;
    this.sakuraBloomY = y;
    this.sakuraBloomSeq += 1;
  }

  private tapSakuraGirl(): void {
    this.sakuraGirlTapSeq += 1;
  }

  private observeThemeTap(event: TouchEvent): void {
    if (!this.themeMotionEnabled || this.voiceComposer.state.recording || this.voiceComposer.holding() || this.sessionPaneDragging || this.drawerOpen()) return;
    const touch = event.changedTouches.length ? event.changedTouches[0] : (event.touches.length ? event.touches[0] : undefined);
    if (!touch) return;
    if (event.type === TouchType.Down) {
      this.themeTapDownX = touch.x;
      this.themeTapDownY = touch.y;
      this.themeTapDownAt = Date.now();
      this.themeTapMoved = false;
    } else if (event.type === TouchType.Move) {
      if (Math.abs(touch.x - this.themeTapDownX) > 12 || Math.abs(touch.y - this.themeTapDownY) > 12) {
        this.themeTapMoved = true;
      }
    } else if (event.type === TouchType.Up) {
      if (!this.themeTapMoved && Date.now() - this.themeTapDownAt < 320) {
        this.triggerSakuraBloom(touch.x, touch.y);
      }
    } else if (event.type === TouchType.Cancel) {
      this.themeTapMoved = true;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        // Reserve the sidebar's space without rebuilding the conversation or moving the session list.
        Blank().width(this.dockedSessions() ? this.sessionPaneWidth() : 0)
        Stack({ alignContent: Alignment.Bottom }) {
          // Keep the wallpaper at window height while the keyboard resizes the conversation.
          ThemeBackdrop({
            themeId: this.themeId,
            darkMode: this.darkMode,
            dimmed: this.sakuraConversationFocus(),
            visible: this.visible,
            motionEnabled: this.themeMotionEnabled,
            windowHeight: this.windowHeight,
            girlTapSeq: this.sakuraGirlTapSeq,
            celebrateSeq: this.sakuraCelebrateSeq,
            burstSeq: this.sakuraBurstSeq,
            burstKind: this.sakuraBurstKind,
            bloomSeq: this.sakuraBloomSeq,
            bloomX: this.sakuraBloomX,
            bloomY: this.sakuraBloomY
          })
          this.mainNavigation()
          if (this.sakuraGirlInteractive()) {
            Row() {
              SakuraGirlHitZone({
                bottomInset: this.session.noSession ? this.bottomContentClearance() : this.chatBottomClearance(),
                tap: (): void => this.tapSakuraGirl()
              })
            }.width('100%').justifyContent(FlexAlign.End).hitTestBehavior(HitTestMode.Transparent)
          }
        }.height('100%').layoutWeight(1)
          .onTouch((event: TouchEvent) => { this.observeThemeTap(event); })
          .onGestureJudgeBegin(() => this.dockedSessions() || this.showSessions || this.voiceComposer.holding() || this.voiceComposer.state.recording ||
            this.voiceComposer.state.voicePreparing || this.voiceComposer.state.voiceFinishing || !this.isPaired ||
            this.session.showSettings || (this.activeTab === 'mine' && !!this.minePage)
            ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
          .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
      }.width('100%').height('100%').backgroundColor(this.themeCanvas())
        .clip(true)
        .accessibilityLevel(this.drawerOpen() || this.scheduleController.state.schedulePage ? 'no-hide-descendants' : 'auto')
      if (this.drawerOpen()) {
        Button({ type: ButtonType.Normal }).width('100%').height('100%').padding(0)
          .backgroundColor(this.darkMode ? '#52000000' : '#2E0F1722').borderRadius(0)
          .accessibilityText('关闭会话列表').onClick(() => { this.setDrawer(false); })
          .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
          .transition(modalFadeTransition())
      }
      if (this.dockedSessions() || this.drawerOpen()) {
        this.sessionDrawer()
      }
      if (this.dockedSessions()) this.sessionPaneHandle()
      if (this.voiceComposer.state.recording || this.voiceComposer.state.voicePreparing || (this.voiceComposer.state.voiceFinishing && !this.voiceComposer.state.voiceCancelling) || this.voiceComposer.state.voiceHint) {
        Column() {
          Column({ space: 16 }) {
            if (this.voiceComposer.state.recording) {
              SymbolGlyph(this.voiceComposer.state.holdCancel ? $r('sys.symbol.xmark') : $r('sys.symbol.mic'))
                .fontSize(38).fontColor([this.voiceComposer.state.holdCancel ? '#FFFFFF' : $r('app.color.pigo_text')])
              Text(this.voiceComposer.state.holdCancel ? '松开手指，取消发送' : '手指上滑，取消发送')
                .fontSize(15).fontColor(this.voiceComposer.state.holdCancel ? '#FFFFFF' : $r('app.color.pigo_text'))
              Text(this.voiceComposer.state.recordSeconds >= 50 ? `还可说 ${60 - this.voiceComposer.state.recordSeconds} 秒` : `${this.voiceComposer.state.recordSeconds}″`)
                .fontSize(13).fontColor(this.voiceComposer.state.holdCancel ? '#FFFFFF' : $r('app.color.pigo_muted'))
              if (this.voiceComposer.state.liveVoiceText && !this.voiceComposer.state.holdCancel) {
                Text(this.voiceComposer.state.liveVoiceText).fontSize(14).fontColor($r('app.color.pigo_text')).maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
              }
            } else if (this.voiceComposer.state.voicePreparing || (this.voiceComposer.state.voiceFinishing && !this.voiceComposer.state.voiceCancelling && !this.voiceComposer.state.voiceHint)) {
              LoadingProgress().width(36).height(36).color($r('app.color.pigo_text'))
              Text(this.voiceComposer.state.voicePreparing ? '正在准备麦克风…' : '正在转为文字…').fontSize(15).fontColor($r('app.color.pigo_text'))
            } else {
              Text(this.voiceComposer.state.voiceHint).fontSize(15).fontColor($r('app.color.pigo_text')).textAlign(TextAlign.Center)
            }
          }.id('voice-feedback').width(250).padding(26).alignItems(HorizontalAlign.Center)
            .borderRadius(20).backgroundColor(this.voiceComposer.state.holdCancel ? '#B74747' : $r('app.color.pigo_control'))
            .attributeModifier(this.voiceComposer.state.holdCancel ? undefined : glassCardSurface(this.darkMode, 20, true))
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.fileController.state.editingPath) {
        Stack({ alignContent: Alignment.Top }) {
          WorkspaceFileEditor({
            editingPath: this.fileController.state.editingPath,
            fileText: this.fileController.state.fileText,
            fileOriginal: this.fileController.state.fileOriginal,
            busy: this.session.busy,
            reachable: this.session.reachable,
            editorNotice: this.fileController.state.editorNotice,
            darkMode: this.darkMode,
            headerHeight: this.headerHeight(),
            statusBarHeight: this.statusBarHeight,
            bottomPad: this.bottomPad(),
            accent: this.accent(),
            accentForeground: this.accentForeground(),
            back: (): void => this.fileController.returnToFilePreview(true),
            showPreview: (): void => this.fileController.previewDraft(),
            changeText: (text: string): void => { this.fileController.state.fileText = text; },
            saveFile: (): Promise<void> => this.fileController.saveFile()
          })
        }.width('100%').height('100%').backgroundColor(this.themeCanvas())
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
          .transition(pagePushTransition())
      }
      if (this.fileController.state.textFilePreview) {
        Stack({ alignContent: Alignment.Top }) {
          TextFilePreviewPage({
            preview: this.fileController.state.textFilePreview,
            busy: this.session.busy,
            savingPreview: this.fileController.state.savingPreview,
            canEdit: !this.fileController.state.editingPath,
            previewNotice: this.fileController.state.previewNotice,
            previewScroller: this.previewScroller,
            pageNumber: this.fileController.previewPageNumber(),
            darkMode: this.darkMode,
            headerHeight: this.headerHeight(),
            statusBarHeight: this.statusBarHeight,
            bottomPad: this.bottomPad(),
            accent: this.accent(),
            accentForeground: this.accentForeground(),
            close: (): void => { this.fileController.state.textFilePreview = undefined; },
            editPreview: (preview: ReceivedFilePreview): void => this.fileController.editPreview(preview),
            savePreviewLocally: (preview: ReceivedFilePreview): Promise<void> => this.fileController.savePreviewLocally(preview),
            reopenSystemPreview: (preview: ReceivedFilePreview): Promise<void> => this.fileController.reopenSystemPreview(preview),
            imagePreviewError: (preview: ReceivedFilePreview): Promise<void> => this.fileController.imagePreviewError(preview),
            changePreviewPage: (forward: boolean): void => this.fileController.changePreviewPage(forward),
            markdownBody: (): void => this.textPreviewMarkdown()
          })
        }.width('100%').height('100%').backgroundColor(this.themeCanvas())
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
          .transition(pagePushTransition())
      }
      if (this.fileController.state.markdownTableReader) {
        MarkdownTableReaderPage({
          markdownRotationUnavailable: this.fileController.state.markdownRotationUnavailable,
          darkMode: this.darkMode,
          headerHeight: this.headerHeight(),
          statusBarHeight: this.statusBarHeight,
          bottomPad: this.bottomPad(),
          canvas: this.themeCanvas(),
          close: (): void => this.fileController.closeMarkdownTableReader(),
          markdownBody: (): void => this.tableReaderMarkdown()
        })
      }
      if (this.sessionActions.creation.showNewSession) {
        NewSessionDialog({
          openingSession: this.session.openingSession,
          busy: this.session.busy,
          reachable: this.session.reachable,
          newSessionFixedWorkspace: this.sessionActions.creation.newSessionFixedWorkspace,
          projects: this.projects,
          workspaces: this.workspaces,
          newSessionCwd: this.sessionActions.creation.newSessionCwd,
          canCreateWorkspace: this.canCreateWorkspace,
          sessionLoading: this.sessionLoading,
          agents: this.agents,
          newSessionAgent: this.sessionActions.creation.newSessionAgent,
          newSessionError: this.sessionActions.creation.newSessionError,
          sessionCatalogFailed: this.sessionCatalogFailed,
          hostAvailable: this.hostAvailable,
          windowHeight: this.windowHeight,
          darkMode: this.darkMode,
          accent: this.accent(),
          accentForeground: this.accentForeground(),
          accentTint: this.accentTint(),
          canCreateSession: this.canCreateSession(),
          closeNewSession: (): void => this.closeNewSession(),
          selectWorkspace: (cwd: string): void => { this.sessionActions.creation.newSessionCwd = cwd; this.sessionActions.creation.newSessionError = ''; },
          openSpace: (): void => { this.closeNewSession(); this.openNewSpace(); },
          refreshAgents: (): Promise<void> => this.loadSessions(),
          selectAgent: (agent: string): void => { this.sessionActions.creation.newSessionAgent = agent; this.sessionActions.creation.newSessionError = ''; },
          createSession: (): Promise<void> => this.sessionActions.createSession()
        })
      }
      if (this.sessionActions.creation.showNewSpace) {
        NewSpaceDialog({
          busy: this.session.busy,
          reachable: this.session.reachable,
          newSpaceName: this.sessionActions.creation.newSpaceName,
          newSpaceError: this.sessionActions.creation.newSpaceError,
          darkMode: this.darkMode,
          accent: this.accent(),
          accentForeground: this.accentForeground(),
          closeNewSpace: (): void => this.closeNewSpace(),
          changeName: (value: string): void => { this.sessionActions.creation.newSpaceName = value; this.sessionActions.creation.newSpaceError = ''; },
          createWorkspaceTask: (): Promise<void> => this.sessionActions.createWorkspaceTask()
        })
      }
      if (this.runCenter.state.runNotice) {
        RunCompletionBanner({
          notice: this.runCenter.state.runNotice,
          iconColor: this.stateColor(this.runCenter.state.runNotice.stopped ? 'waiting' : 'streaming'),
          darkMode: this.darkMode,
          statusBarHeight: this.statusBarHeight,
          dismiss: (): void => this.runCenter.advanceRunNotice()
        })
      }
      if (this.scheduleController.state.scheduleBanner && !this.scheduleController.state.schedulePage && !this.runCenter.state.runNotice) {
        Row() {
          ScheduledRunBanner({
            message: this.scheduleController.state.scheduleBanner,
            darkMode: this.darkMode,
            open: (message: RunMessage): void => this.scheduleController.showScheduleDetail(message),
            dismiss: (): void => { this.scheduleController.state.scheduleBanner = undefined; }
          })
        }.width('100%').justifyContent(FlexAlign.Center)
          .margin({ top: this.statusBarHeight + this.headerHeight() + 10 }).hitTestBehavior(HitTestMode.Transparent)
          .transition(bannerTransition())
      }
      if (this.scheduleController.state.schedulePage) this.scheduleOverlay()
      if (this.runCenter.state.reviewedRun) {
        RunResultView({
          result: this.runCenter.state.reviewedRun, file: this.runCenter.state.reviewedFile, patch: this.runCenter.state.reviewPatch,
          loading: this.runCenter.state.reviewLoading, error: this.runCenter.state.reviewError,
          themeId: this.themeId, darkMode: this.darkMode, top: this.statusBarHeight, bottom: this.bottomPad(),
          back: (): void => this.runCenter.backFromRunResult(),
          openDiff: (file: RunFile): void => { void this.runCenter.openRunDiff(file); },
          openArtifact: (file: RunFile): void => { void this.runCenter.openRunArtifact(file); },
          loadScreenshot: (image: RunScreenshot): Promise<string> =>
            this.fileController.loadHistoryImage(this.runCenter.state.reviewedRun?.sessionId ?? '', image.messageId, 0, image.toolId),
          openScreenshot: (source: string, label: string): void => {
            this.runCenter.state.reviewedRun = undefined;
            this.fileController.showChatImage(source, label);
          },
          citeLine: (line: DiffLine): void => this.citeRunLine(line)
        })
      }
      if (this.shareController.showIncomingShare()) {
        Row() {
          IncomingShareBanner({
            incomingShare: this.appState.incomingShare,
            shareError: this.shareController.state.shareError,
            isPaired: this.isPaired,
            canAddShareToCurrent: this.canAddShareToCurrent(),
            sessionName: this.session.sessionName,
            project: this.session.project,
            shareTargetLocked: this.shareTargetLocked(),
            busy: this.session.busy,
            openingSession: this.session.openingSession,
            hasPendingSend: !!this.session.pendingSend,
            accent: this.accent(),
            accentForeground: this.accentForeground(),
            clearIncomingShare: (): void => this.shareController.clearIncomingShare(),
            chooseShareComputer: (): void => this.shareController.chooseShareComputer(),
            chooseShareSession: (): void => this.shareController.chooseShareSession(),
            addShareToDraft: (): void => this.shareController.addShareToDraft()
          })
        }.width('100%').justifyContent(FlexAlign.Center)
          .margin({ top: this.statusBarHeight + this.headerHeight() + 8 }).hitTestBehavior(HitTestMode.Transparent)
          .transition(bannerTransition())
      }
    }.width('100%').height('100%').padding({ left: this.leftInset, right: this.rightInset })
      .backgroundColor(this.themeCanvas())
      .clip(true)
      .bindSheet(this.showToolDetails, this.toolDetailsSheet(), {
        detents: ['65%', SheetSize.LARGE], dragBar: true, showClose: true,
        backgroundColor: hasImmersiveMaterial() ? undefined : $r('app.color.pigo_panel'),
        systemMaterial: immersiveSheetMaterial(),
        maskColor: '#52000000',
        onDisappear: () => { this.closeToolDetails(); }
      })
  }
}
