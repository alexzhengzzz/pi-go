import { CommandList, CommandState, commandDraft, skillDraft } from '../model/CommandState';
import { ConnectionManager, PairingRequest } from '../model/ConnectionManager';
import { ChatState } from '../model/ChatState';
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
import { toolActionTitle } from '../TranscriptTurns';
import { SakuraScene } from '../components/SakuraPetals';
import { InkScene } from '../components/InkScene';
import { SunsetScene } from '../components/SunsetScene';
import { RunResultView } from '../components/RunResultView';
import { DiffLine, InboxRun, pushDeviceId, RunEvent, RunFile, RunScreenshot, runStatus } from '../RunResults';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { ChatContent, replySpeechText } from '../ChatContent';
import { ChatImage } from '../ChatImage';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { common } from '@kit.AbilityKit';
import { preferences, relationalStore } from '@kit.ArkData';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { filePreview } from '@kit.PreviewKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { Companion, CredentialVault } from '../CredentialVault';
import { choosePromptImage, capturePromptImage, PromptImage } from '../PromptImage';
import { choosePromptFiles, MAX_FILES } from '../PromptFile';
import { ensureMicrophone, VoiceInputSession, voiceInputSupported } from '../VoiceInput';
import { ReplySpeech, replySpeechSupported } from '../ReplySpeech';
import { AppearanceMode, THEME_MOTION_SETTING, ThemePalette, ThemeStyle, appearanceMode, canvasFadeStops, openSettings, themePalette, themeStyle } from '../Appearance';
import { HuaweiProfile, authorizeHuaweiProfile, isHuaweiProfileCurrent } from '../HuaweiProfile';
import { AccountSync, CloudComputer, SyncRow, SyncSnapshot, SYNC_MODE, SYNC_THEME, computerSyncRow } from '../AccountSync';
import { immersiveSurface, glassButtonSurface, glassComposerSurface, glassCardSurface, immersiveFloatingTabs, hasImmersiveMaterial, immersiveSheetMaterial } from '../Immersive';
import { HISTORY_IMAGE_EXTENSIONS, isImageFile, markdownWorkspacePath, normalizeWorkspacePath, safeLocalFileName,
  textPreviewFormat } from '../ChatPaths';
import { decodePairingBundle, validUsb } from '../PairingCode';
import { connectionLabel, validCompanion } from '../CompanionCheck';
import { ComputerGroup, computerGroupId, computerGroups, computerGroupTitle, moveComputerConnection, renameComputerGroup } from '../ComputerGroups';
import { liveActivity } from '../LiveActivity';
import { SessionShareMeta, formatSessionMarkdown, shareSessionViaSystem } from '../SessionShare';
import { ScheduleJob, ScheduleRun, ScheduleWatch, RunMessage, scheduleTime, parseScheduleTime, scheduleRunStatus, isCurrentScheduleComputer } from '../ScheduledRuns';

import { ModelOption, BridgeEndpoint, SessionState, SessionRow, ChatMessage, DraftAttachment, AttachmentRef,
  UploadedAttachment, LiveTool, ToolDetails, CommandRow, ReceivedFilePreview, MarkdownTableReader, StreamFrame,
  PendingInteraction, FileEntry, FileDirectory, FileTreeRow, RunningRow, RunNotice, WorkspaceRow, BridgeReply,
  AgentInfo, Payload, PendingSend, QueuedSteering, BridgeFailure } from '../model/PiGoTypes';
import { MAX_IMAGE_ATTACHMENTS, MAX_TOTAL_IMAGE_DRAFTS, MAX_TOTAL_FILE_DRAFTS, USB_ADDRESS, MAX_VOICE_MS, MIN_HOLD_MS,
  RECEIVED_FILE_DIR, RECEIVED_FILE_TTL_S, MAX_DOWNLOAD_BYTES, MAX_INLINE_IMAGE_BYTES, SPLIT_WINDOW_WIDTH,
  SHORT_WINDOW_HEIGHT, MAX_TEXT_PREVIEW_BYTES, RUN_NOTICE_SETTING, LIVE_VIEW_SETTING } from '../model/PiGoConstants';
import { SidebarRows } from '../model/SidebarRows';
import { IncomingShare, MAX_SHARED_DRAFT_BYTES, releaseIncomingShare, sharedDraftSize } from '../IncomingShare';
import { InboxWidget, WidgetItem, WidgetSnapshot } from '../InboxWidget';

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

@Entry
@Component
struct Index {
  @StorageProp('pigoDark') private darkMode: boolean = false;
  @StorageLink('pigoAddress') address: string = 'http://127.0.0.1:18977';
  @StorageLink('pigoTicket') @Watch('onLaunchTicket') launchTicket: string = '';
  @StorageLink('pigoLiveSession') @Watch('onLiveActivityLaunch') private liveLaunchSession: string = '';
  @StorageLink('pigoLiveAddress') private liveLaunchAddress: string = '';
  @StorageLink('pigoPushEvent') @Watch('onPushLaunch') private pushLaunchEvent: string = '';
  @StorageLink('pigoPushDevice') private pushLaunchDevice: string = '';
  @StorageLink('pigoPushSession') private pushLaunchSession: string = '';
  @StorageLink('pigoPushPending') private pushLaunchPending: string = '';
  @StorageLink('pigoIncomingShare') @Watch('onIncomingShare') private incomingShare: IncomingShare =
    { text: '', attachments: [], skipped: false };
  @StorageLink('pigoInboxFormLaunch') @Watch('onInboxFormLaunch') private inboxFormLaunch: boolean = false;
  @StorageLink('pigoFormDestination') private formDestination: string = '';
  @StorageLink('pigoFormSessionId') private formSessionId: string = '';
  @StorageLink('pigoFormAddress') private formAddress: string = '';
  @StorageLink('pigoFormPendingId') private formPendingId: string = '';
  @StorageLink('pigoFormEventId') private formEventId: string = '';
  @State private shareError: string = '';
  @State private shareTargetPicker: string = '';
  private readonly inboxWidget: InboxWidget = new InboxWidget();
  private networkTimer: number = -1;
  private switchingNetwork: boolean = false;
  private lastNetworkFailover: number = 0;
  private openingPush: boolean = false;
  private restoreChain: Promise<void> = Promise.resolve();
  @StorageLink('pigoStatusBar') statusBarHeight: number = 38;
  @StorageLink('pigoNavBar') navBarHeight: number = 28;
  @StorageProp('pigoLeftInset') private leftInset: number = 0;
  @StorageProp('pigoRightInset') private rightInset: number = 0;
  @StorageProp('pigoWindowWidth') @Watch('onWindowWidthChange') private windowWidth: number = 0;
  @StorageProp('pigoWindowHeight') private windowHeight: number = 800;
  @StorageLink('pigoKeyboard') @Watch('onKeyboardChange') keyboardHeight: number = 0;
  @State private showModelMenu: boolean = false;
  @State private currentModel?: ModelOption = undefined;
  @State private currentLevel: string = 'off';
  private pendingBottom: boolean = false;
  @State private openingSession: boolean = false;
  @State private openingSessionId: string = '';
  private pendingSessionReveal: string = '';
  @State private ticket: string = '';
  @State private pairingMode: string = 'usb';
  @State private pairingBundle: string = '';
  @State private lanCandidates: string[] = [];
  @State private isPaired: boolean = false;
  @State private loading: boolean = true;
  @State private computers: Companion[] = [];
  @State private schedulePage: string = '';
  @State private scheduleMessages: RunMessage[] = [];
  @State private inboxRuns: InboxRun[] = [];
  @State private inboxCleaning: boolean = false;
  @State private pushEnabled: boolean = false;
  @State private pushSaving: boolean = false;
  @State private pushStatus: string = '';
  private pushToken: string = '';
  private pushTokenRequest?: Promise<string>;
  private nextPushTokenAttempt: number = 0;
  private runRead: string[] = [];
  private dismissedInboxRuns: Set<string> = new Set<string>();
  private runSyncTimer: number = -1;
  private runSyncing: boolean = false;
  private pushRegistrations: Map<string, string> = new Map<string, string>();
  @State private sessionRuns: RunEvent[] = [];
  @State private sessionRunKey: string = '';
  @State private reviewedRun?: RunEvent = undefined;
  @State private reviewedFile?: RunFile = undefined;
  @State private reviewPatch: string = '';
  @State private reviewLoading: boolean = false;
  @State private reviewError: string = '';
  private reviewRequest: number = 0;
  @State private scheduleActive: RunMessage[] = [];
  @State private scheduleOffline: string[] = [];
  @State private scheduleDetail?: RunMessage = undefined;
  @State private scheduleBanner?: RunMessage = undefined;
  @State private scheduleJobs: ScheduleJob[] = [];
  @State private scheduleZone: string = '';
  @State private scheduleError: string = '';
  @State private scheduleListError: string = '';
  @State private scheduleSaving: boolean = false;
  @State private scheduleLoading: boolean = false;
  @State private scheduleEditing?: ScheduleJob = undefined;
  @State private scheduleName: string = '';
  @State private schedulePrompt: string = '';
  @State private scheduleCwd: string = '';
  @State private scheduleKind: string = 'once';
  @State private scheduleWhen: string = '';
  @State private scheduleCatchUp: string = '0';
  private schedulePrevious: string = '';
  private scheduleRead: Map<string, string[]> = new Map<string, string[]>();
  private scheduleDismissed: Map<string, string[]> = new Map<string, string[]>();
  private scheduleWatches: ScheduleWatch[] = [];
  private scheduleRetries: Map<string, number> = new Map<string, number>();
  private scheduleDue: Map<string, number> = new Map<string, number>();
  private scheduleTimer: number = -1;
  private scheduleBannerTimer: number = -1;
  private schedulePolling: boolean = false;
  private scheduleDiscovery: boolean = false;
  private scheduleMutation: number = 0;
  private scheduleComputerGeneration: number = 0;
  @State private removeTarget: string = '';
  @State private renameComputerId: string = '';
  @State private computerNameDraft: string = '';
  @State private moveConnectionAddress: string = '';
  @State private pairingComputerId: string = '';
  @State private busy: boolean = false;
  @State private reachable: boolean = false;
  @State private idle: boolean = true;
  @State private runId: string = '';
  @State private queued: boolean = false;
  @State private acceptsImage: boolean = false;
  @State private attachments: DraftAttachment[] = [];
  @State private showComposerMenu: boolean = false;
  @State private showSkillPicker: boolean = false;
  @State private project: string = '';
  @State private workspaceCwd: string = '';
  @State private currentAgent: string = 'pi';
  @State private currentPermission: string = '';
  private imageQueue: Promise<void> = Promise.resolve();
  private lastImageCachePrune: number = 0;
  @State private showFiles: boolean = false;
  @State private fileRoot: string = '';
  @State private fileTreeRows: FileTreeRow[] = [];
  private readonly fileDirectories: Map<string, FileDirectory> = new Map();
  private fileTreeIndex: number = 0;
  @State private openingFile: boolean = false;
  @State private editingPath: string = '';
  private editingRoot: string = '';
  @State private fileText: string = '';
  @State private fileOriginal: string = '';
  @State private editorNotice: string = '';
  private fileVersion: string = '';
  @State private sessionName: string = '';
  @State private showSettings: boolean = false;
  @State private sharingSession: boolean = false;
  @State private renameDraft: string = '';
  @State private models: ModelOption[] = [];
  @State private selectedModel: number = -1;
  @State private selectedLevel: string = 'off';
  @State private modelLabel: string = '';
  @State @Watch('onRunSessionChanged') private currentId: string = '';
  @State private noSession: string = '';
  @State private status: string = '';
  @State private draft: string = '';
  @State private liveText: string = '';
  @State private liveThinking: string = '';
  @State private liveThinkingOpen: boolean = false;
  @State private thinkingOpenIds: string[] = [];
  @State private liveTools: LiveTool[] = [];
  @State private showToolDetails: boolean = false;
  @State private markdownTableReader?: MarkdownTableReader = undefined;
  @State private markdownRotationUnavailable: boolean = false;
  private markdownRotation: Promise<void> = Promise.resolve();
  private markdownRotationRevision: number = 0;
  private markdownWindow?: window.Window;
  private markdownPreviousOrientation?: window.Orientation;
  @State private textFilePreview?: ReceivedFilePreview = undefined;
  @State private savingPreview: boolean = false;
  @State private previewNotice: string = '';
  private previewOffsets: number[] = [];
  private readonly previewScroller: Scroller = new Scroller();
  @State private selectedTool?: LiveTool = undefined;
  @State private selectedToolDetails?: ToolDetails = undefined;
  @State private toolDetailError: string = '';
  private selectedToolMessageId: string = '';
  private toolDetailRevision: number = 0;
  private liveSeq: number = 0;
  private liveThinkSeq: number = 0;
  private liveRevision: number = 0;
  private readonly chatState: ChatState = new ChatState();
  private syncMode: string = 'probe';
  private historyStream: string = '';
  private historyLeaf?: string | null;
  private historyLoadingEpoch?: number;
  private historyRequest: number = 0;
  @State private streamAlive: boolean = false;
  private readonly client: PiGoClient = new PiGoClient();
  private streamReq?: http.HttpRequest = undefined;
  private streamGen: number = 0;
  @State private historyCursor?: string = undefined;
  @State @Watch('updateSidebarRows') private sessions: SessionRow[] = [];
  @State private runningSessionIds: string[] = [];
  @State private runningSessions: RunningRow[] = [];
  private readonly observedRuns: Map<string, string> = new Map<string, string>();
  @State private sakuraBurstSeq: number = 0;
  @State private sakuraBurstKind: string = 'send';
  @State private sakuraBloomSeq: number = 0;
  @State private sakuraBloomX: number = 0;
  @State private sakuraBloomY: number = 0;
  @State private sakuraGirlTapSeq: number = 0;
  @State private sakuraCelebrateSeq: number = 0;
  private themeTapDownX: number = 0;
  private themeTapDownY: number = 0;
  private themeTapDownAt: number = 0;
  private themeTapMoved: boolean = false;
  @State private runNotice?: RunNotice = undefined;
  private pendingRunNotices: RunNotice[] = [];
  private runNoticeTimer: number = -1;
  private sessionStatusAt: number = 0;
  private sessionStatusLoading: boolean = false;
  @State private messages: ChatMessage[] = [];
  @State private loadingMessageText: string = '';
  @State private queuedSteering: QueuedSteering[] = [];
  @State private showSessions: boolean = false;
  @State private preferredSessionPaneWidth?: number = undefined;
  @State private sessionPaneDragging: boolean = false;
  private sessionPaneDragStart: number = 0;
  @State @Watch('updateSidebarRows') private expandedSpaces: string[] = [];
  @State private offlineDismissed: boolean = false;
  @State private activeTab: string = 'tasks';
  @State private minePage: string = '';
  @State private addingComputer: boolean = false;
  @State private themeId: string = 'sakura';
  @State private themeMotionEnabled: boolean = true;
  @State private modeId: string = 'system';
  @State private runNoticesEnabled: boolean = true;
  @State private liveViewsEnabled: boolean = true;
  @State private liveViewStatus: string = '';
  private liveViewSessionKey: string = '';
  private liveViewRunId: string = '';
  @State private appearanceNotice: string = '';
  @State private huaweiProfile?: HuaweiProfile = undefined;
  @State private avatarUnavailable: boolean = false;
  @State private accountBusy: boolean = false;
  @State private accountNotice: string = '';
  private settings?: preferences.Preferences;
  private settingsWrite: Promise<void> = Promise.resolve();
  @State private cloudComputers: CloudComputer[] = [];
  @State private restoringComputer?: CloudComputer = undefined;
  @State private cloudSyncStatus: string = '';
  @State private cloudSyncBusy: boolean = false;
  private cloudStore?: Promise<AccountSync>;
  private cloudWork: Promise<void> = Promise.resolve();
  private cloudWrites: Promise<void> = Promise.resolve();
  private cloudTimer: number = -1;
  private cloudRevision: number = 0;
  private readonly pendingCloudRows: Map<string, SyncRow> = new Map<string, SyncRow>();

  @State @Watch('updateSidebarRows') private sessionView: string = 'all';
  @State @Watch('updateSidebarRows') private loadedView: string = 'all';
  @State private interaction?: PendingInteraction = undefined;
  @State private interactionDraft: string = '';
  @State private pendingSend?: PendingSend = undefined;
  @State private hostAvailable: boolean = false;
  @State private canCreateWorkspace: boolean = false;
  @State private agents: AgentInfo[] = [];
  @State private showNewSession: boolean = false;
  @State private newSessionCwd: string = '';
  @State private newSessionAgent: string = '';
  @State private newSessionFixedWorkspace: boolean = false;
  @State private newSessionError: string = '';
  private newSessionPreferredAgent: string = 'pi';
  @State private showNewSpace: boolean = false;
  @State private newSpaceName: string = '';
  @State private newSpaceError: string = '';
  @State private voiceMode: boolean = false;
  @State private recording: boolean = false;
  @State private recordSeconds: number = 0;
  @State private liveVoiceText: string = '';
  @State private holdCancel: boolean = false;
  @State private voicePreparing: boolean = false;
  @State private voiceFinishing: boolean = false;
  @State private voiceCancelling: boolean = false;
  @State private voiceHint: string = '';
  private voiceHintTimer: number = -1;
  private voiceAttempt: number = 0;
  private holdTouchId: number = -1;
  private holdActive: boolean = false;
  private holdStartY: number = 0;
  private holdStart: number = 0;
  private recordTimer: number = -1;
  private voiceSession?: VoiceInputSession = undefined;
  private readonly replySpeech: ReplySpeech = new ReplySpeech();
  private replySpeechAttempt: number = 0;
  @State private speakingReply: string = '';
  @State @Watch('updateSidebarRows') private projects: string[] = [];
  @State @Watch('updateSidebarRows') private workspaces: WorkspaceRow[] = [];
  @State @Watch('updateSidebarRows') private workspacePages: WorkspacePage[] = [];
  @State @Watch('updateSidebarRows') private sessionNextCursor?: number = undefined;
  @State private base: string = '';
  private readonly connection: ConnectionManager = new ConnectionManager();
  private epoch: number = 0;
  private visible: boolean = false;
  private polling: boolean = false;
  @State private sessionLoading: boolean = false;
  @State private sessionCatalogFailed: boolean = false;
  private sessionCatalogLoaded: boolean = false;
  private sessionCatalogUpdatedAt: number = 0;
  @State private commandRows: CommandRow[] = [];
  @State private commandPalette: boolean = false;
  @State private commandsLoading: boolean = false;
  @State private commandError: string = '';
  private readonly commandState: CommandState = new CommandState();
  private sessionCatalogVersion: number = 0;
  private catalogConnection: number = 0;
  private workspacePageRequestId: number = 0;
  private readonly sessionStore: SessionStore = new SessionStore();
  private vault?: CredentialVault;
  private readonly transcript: Scroller = new Scroller();
  private transcriptContentHeight: number = 0;
  private transcriptViewport: number = 0;
  @State private transcriptFollow: boolean = true;
  private readonly library: Scroller = new Scroller();
  private readonly sidebarRows: SidebarRows = new SidebarRows();
  private pendingLibraryReveal: boolean = false;

  onBackPress(): boolean {
    if (this.markdownTableReader) { this.closeMarkdownTableReader(); return true; }
    if (this.reviewedRun) { this.backFromRunResult(); return true; }
    if (this.textFilePreview) {
      if (!this.savingPreview) this.textFilePreview = undefined;
      return true;
    }
    if (this.editingPath) {
      this.returnToFilePreview();
      return true;
    }
    if (this.recording || this.voicePreparing || this.voiceFinishing) { this.resetVoice(); return true; }
    if (this.schedulePage) { this.backFromSchedule(); return true; }
    if (this.showToolDetails) { this.closeToolDetails(); return true; }
    if (this.showModelMenu) { this.showModelMenu = false; return true; }
    if (this.showNewSpace) { this.closeNewSpace(); return true; }
    if (this.showNewSession) { this.closeNewSession(); return true; }
    if (this.showSessions) { this.setDrawer(false); return true; }
    if (this.showSettings) { this.showSettings = false; return true; }
    if (this.showFiles) { this.fileBack(); return true; }
    if (this.activeTab === 'mine' && this.minePage) {
      if (!this.busy) this.mineBack();
      return true;
    }
    return false;
  }

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const context = this.getUIContext().getHostContext();
    if (context) {
      liveActivity.attach(context as common.UIAbilityContext, (status: string): void => {
        this.liveViewStatus = status;
      });
    }
    this.restoreSettings();
    this.restoreChain = this.restore();
    void this.restoreChain.then(() => {
      if (!this.isPaired && this.activeTab === 'tasks') this.openComputers();
      void this.consumeLaunchTicket();
    });
  }
  onPageShow(): void {
    this.visible = true;
    this.connection.watchNetwork((): void => { this.onNetworkChange(); });
    void this.restoreChain.then(() => {
      this.queueScheduleSync(true);
      this.queueRunSync(0);
      void this.consumePushLaunch();
      this.onInboxFormLaunch();
    });
    this.schedule(0);
    this.startStream();
    this.syncLiveActivity();
    void this.consumeLiveActivityLaunch();
    void this.checkHuaweiProfile().then(() => { this.scheduleCloudSync(0); });
  }
  onPageHide(): void {
    this.visible = false;
    this.stopReplySpeech();
    this.stopNetworkMonitor();
    this.stopRunSync();
    this.stopScheduleSync();
    this.clearRunNotices();
    if (this.backgroundLiveActivity()) {
      // Best effort only: HarmonyOS may still freeze the process without a continuous-task grant.
      this.schedule(0);
      this.startStream();
    } else {
      this.cancelSchedule();
      this.stopStream();
    }
    this.resetVoice();
  }
  aboutToDisappear(): void {
    this.stopReplySpeech();
    this.replySpeech.dispose();
    if (this.markdownTableReader) this.closeMarkdownTableReader();
    this.visible = false;
    this.stopNetworkMonitor();
    this.stopRunSync();
    this.stopScheduleSync();
    this.clearRunNotices();
    this.cancelSchedule();
    this.stopStream();
    liveActivity.sync(undefined);
    this.stopRecordClock();
    this.resetVoice();
  }

  private async restore(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context) { this.loading = false; return; }
    const epoch = this.epoch;
    try {
      this.vault = await CredentialVault.open(context);
      const saved = await this.vault.load();
      if (!saved || epoch !== this.epoch) return;
      this.computers = this.connection.restoreComputers(saved.computers, (): string => util.generateRandomUUID());
      const active = this.computers.find((record: Companion): boolean => record.address === saved.active);
      if (active) this.activateComputer(active);
    } catch { this.status = '无法读取已有配对，请重新连接。'; }
    finally { this.loading = false; }
  }

  private async persistComputers(): Promise<void> {
    if (!this.vault) throw new Error('vault_unavailable');
    await this.vault.save({ version: 2, active: this.isPaired ? this.base : '', computers: this.computers });
  }

  private onLaunchTicket(): void { void this.consumeLaunchTicket(); }

  private async consumeLaunchTicket(): Promise<void> {
    const ticket = this.launchTicket;
    if (!ticket || !/^(\d{8}|[a-f0-9]{64})$/.test(ticket)) return;
    const address = this.address.trim();
    if (!validUsb(address)) return;
    await this.restoreChain;
    for (let attempt = 0; attempt < 40; attempt++) {
      if (this.launchTicket !== ticket) return;
      if (!this.busy && !this.openingSession) {
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
      if (this.liveLaunchSession !== id) return;
      if (this.visible && !this.loading && !this.busy && !this.openingSession) {
        const address = this.liveLaunchAddress;
        if (address && address !== this.base) {
          const target = this.computers.find((record: Companion): boolean =>
            validCompanion(record) && record.address === address);
          if (!target) {
            this.liveLaunchSession = '';
            this.liveLaunchAddress = '';
            this.status = '实况窗对应的电脑未配对，请重新连接。';
            return;
          }
          this.leaveComputer(false, target);
        }
        if (!this.isPaired) return;
        this.liveLaunchSession = '';
        this.liveLaunchAddress = '';
        this.activeTab = 'tasks';
        this.showFiles = false;
        this.showSettings = false;
        this.showSessions = false;
        if (id !== this.currentId) await this.requestAction('/open', { id: id });
        else {
          this.schedule(0);
          this.syncLiveActivity();
        }
        return;
      }
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 300); });
    }
  }

  private activateComputer(record: Companion): void {
    const usb = validUsb(record.address);
    this.resetScheduleJobs();
    this.epoch += 1;
    this.lastNetworkFailover = 0;
    this.syncMode = 'probe';
    this.historyStream = '';
    this.historyLeaf = undefined;
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
    this.status = '';
    this.noSession = '正在加载该电脑的会话…';
    this.showSessions = this.windowWidth < SPLIT_WINDOW_WIDTH;
    this.resetCatalog();
    this.reachable = false;
    this.isPaired = true;
    this.queueScheduleSync(true);
    this.schedule(0);
    this.stopStream();
  }

  private chooseComputer(record: Companion): void {
    if (this.busy || this.openingSession || this.removeTarget || (this.isPaired && this.base === record.address)) return;
    if (this.isPaired) {
      this.leaveComputer(false, record);
      return;
    }
    this.activateComputer(record);
    void this.persistComputers().catch(() => { this.status = '已连接；未能保存本次选择。'; });
  }

  private cancelSchedule(): void {
    this.connection.cancelPoll();
  }

  private stopScheduleSync(): void {
    if (this.scheduleTimer !== -1) clearTimeout(this.scheduleTimer);
    if (this.scheduleBannerTimer !== -1) clearTimeout(this.scheduleBannerTimer);
    this.scheduleTimer = -1;
    this.scheduleBannerTimer = -1;
    this.scheduleBanner = undefined;
  }

  private queueScheduleSync(discover: boolean = false, delay: number = 0): void {
    if (discover) {
      this.scheduleDiscovery = true;
      this.scheduleDue.clear();
    }
    if (!this.visible || this.schedulePolling) return;
    if (this.scheduleTimer !== -1) clearTimeout(this.scheduleTimer);
    this.scheduleTimer = setTimeout(() => { void this.syncSchedules(); }, delay);
  }

  private setScheduleWatch(address: string, source: string, watching: boolean): void {
    const current = this.scheduleWatches.find((watch: ScheduleWatch): boolean => watch.address === address);
    if (watching && current?.source === source) return;
    if (!watching && !current) return;
    this.scheduleWatches = this.scheduleWatches.filter((watch: ScheduleWatch): boolean => watch.address !== address);
    if (watching) {
      const watch: ScheduleWatch = { address: address, source: source };
      this.scheduleWatches = this.scheduleWatches.concat([watch]);
    }
    void this.saveSetting('schedule_watches', JSON.stringify(this.scheduleWatches)).catch(() => {});
  }

  private async syncSchedules(): Promise<void> {
    if (!this.visible || this.schedulePolling) return;
    this.scheduleTimer = -1;
    const discover = this.scheduleDiscovery;
    this.scheduleDiscovery = false;
    const now = Date.now();
    const computers = this.computers.slice();
    this.scheduleMessages = this.scheduleMessages.filter((message: RunMessage): boolean =>
      computers.some((computer: Companion): boolean => computer.address === message.address));
    this.scheduleActive = this.scheduleActive.filter((message: RunMessage): boolean =>
      computers.some((computer: Companion): boolean => computer.address === message.address));
    this.scheduleOffline = this.scheduleOffline.filter((address: string): boolean =>
      computers.some((computer: Companion): boolean => computer.address === address));
    const targets = computers.filter((computer: Companion): boolean => discover ||
      (this.scheduleWatches.some((watch: ScheduleWatch): boolean => watch.address === computer.address) &&
        now >= (this.scheduleDue.get(computer.address) ?? 0)));
    this.schedulePolling = true;
    try {
      await Promise.all(targets.map((computer: Companion): Promise<void> => this.syncScheduleComputer(computer)));
    } finally {
      this.schedulePolling = false;
      if (this.scheduleDiscovery) this.queueScheduleSync();
      else {
        const due = this.scheduleWatches.filter((watch: ScheduleWatch): boolean =>
          this.computers.some((computer: Companion): boolean => computer.address === watch.address))
          .map((watch: ScheduleWatch): number => this.scheduleDue.get(watch.address) ?? Date.now());
        if (due.length) this.queueScheduleSync(false, Math.max(0, Math.min(...due) - Date.now()));
      }
    }
  }

  private scheduleComputerName(computer: Companion): string {
    const group = computerGroups(this.computers).find((item: ComputerGroup): boolean => item.id === computerGroupId(computer));
    return group ? computerGroupTitle(group) : connectionLabel(computer);
  }

  private onRunSessionChanged(): void {
    this.stopReplySpeech();
    this.reviewedRun = undefined;
    this.reviewedFile = undefined;
    this.reviewRequest += 1;
    this.queueRunSync(0);
  }

  private queueRunSync(delay: number): void {
    this.stopRunSync();
    if (!this.visible) return;
    this.runSyncTimer = setTimeout(() => { void this.syncRunCenter(); }, delay);
  }

  private stopRunSync(): void {
    if (this.runSyncTimer !== -1) clearTimeout(this.runSyncTimer);
    this.runSyncTimer = -1;
  }

  private async syncRunCenter(): Promise<void> {
    if (!this.visible || this.runSyncing) return;
    this.runSyncing = true;
    const computers = this.computers.filter((item: Companion): boolean => validCompanion(item));
    const session = this.currentId;
    const key = this.draftKey(session);
    const endpoint = this.connection.endpoint();
    try {
      const inbox = Promise.all(computers.map((computer: Companion): Promise<boolean> => this.syncRunInbox(computer)));
      const results = session && this.isPaired && this.reachable ? this.syncRunResults(endpoint, session, key) : undefined;
      const synced = await inbox;
      await results;
      if (this.visible) {
        this.inboxRuns = this.inboxRuns.filter((row: InboxRun): boolean =>
          this.computers.some((computer: Companion): boolean => computer.address === row.address));
        if (synced.some((ready: boolean): boolean => ready) || !this.computers.length) {
          this.publishWidgets();
        }
      }
    } finally {
      this.runSyncing = false;
      this.queueRunSync(9000);
    }
  }

  private async syncRunInbox(computer: Companion): Promise<boolean> {
    const endpoint = this.scheduleEndpoint(computer);
    try {
      const result = await this.request('/runs/inbox', undefined, endpoint);
      if (!this.visible || !this.computers.some((item: Companion): boolean =>
        item.address === computer.address && item.token === computer.token)) return false;
      const rows = (result.runEvents ?? []).filter((run: RunEvent): boolean =>
        run.status === 'waiting' || !this.dismissedInboxRuns.has(run.id)).map((run: RunEvent): InboxRun => ({
        run: run, address: computer.address, computer: this.scheduleComputerName(computer),
        unread: run.status === 'waiting' || !this.runRead.includes(run.id)
      }));
      this.inboxRuns = this.inboxRuns.filter((row: InboxRun): boolean => row.address !== computer.address).concat(rows);
      await this.syncPushRegistration(computer, result.pushAvailable === true).catch((): void => {});
      return true;
    } catch { return false; }
  }

  private async syncRunResults(endpoint: BridgeEndpoint, session: string, key: string): Promise<void> {
    try {
      const result = await this.request('/runs/results?session=' + encodeURIComponent(session), undefined, endpoint);
      if (key !== this.draftKey(this.currentId) || endpoint.token !== this.connection.endpoint().token) return;
      const rows = (result.runEvents ?? []).filter((row: RunEvent): boolean => row.cwd === this.workspaceCwd);
      if (key !== this.sessionRunKey || rows.length !== this.sessionRuns.length ||
          rows.some((row: RunEvent, index: number): boolean => row.id !== this.sessionRuns[index].id)) {
        this.sessionRunKey = key;
        this.sessionRuns = rows;
      }
    } catch { /* Old bridges can still display the session transcript. */ }
  }

  private displayedInboxRuns(): InboxRun[] {
    const records = new Map<string, InboxRun>();
    for (const row of this.inboxRuns) {
      if (!records.has(row.run.id) || row.address === this.base) records.set(row.run.id, row);
    }
    return Array.from(records.values()).sort((a: InboxRun, b: InboxRun): number =>
      Number(b.run.status === 'waiting') - Number(a.run.status === 'waiting') || b.run.finishedAt - a.run.finishedAt);
  }

  private async dismissInboxRuns(ids: string[]): Promise<boolean> {
    if (this.inboxCleaning) return false;
    const selected = new Set<string>(ids);
    const dismissed = new Set<string>(this.dismissedInboxRuns);
    for (const row of this.inboxRuns) {
      if (row.run.status !== 'waiting' && selected.has(row.run.id)) dismissed.add(row.run.id);
    }
    this.inboxCleaning = true;
    try {
      await this.saveSetting('run_inbox_dismissed', JSON.stringify(Array.from(dismissed)));
      this.dismissedInboxRuns = dismissed;
      this.inboxRuns = this.inboxRuns.filter((row: InboxRun): boolean =>
        row.run.status === 'waiting' || !dismissed.has(row.run.id));
      return true;
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: '暂时无法保存删除记录，请重试。' });
      return false;
    } finally {
      this.inboxCleaning = false;
    }
  }

  private async syncPushRegistration(computer: Companion, available: boolean): Promise<void> {
    const endpoint = this.scheduleEndpoint(computer);
    if (!available) {
      this.pushRegistrations.delete(computer.address);
      if (this.pushEnabled && computer.address === this.base) this.pushStatus = '这台电脑尚未配置 Push Kit';
      return;
    }
    const registered = this.pushEnabled ? computer.token + ':' + this.pushToken : computer.token;
    if (this.pushRegistrations.get(computer.address) === registered) return;
    if (this.pushEnabled && !this.pushToken) {
      if (!this.pushTokenRequest && Date.now() >= this.nextPushTokenAttempt) {
        this.nextPushTokenAttempt = Date.now() + 60_000;
        this.pushTokenRequest = pushService.getToken().finally(() => { this.pushTokenRequest = undefined; });
      }
      try { this.pushToken = await this.pushTokenRequest ?? ''; }
      catch {
        if (computer.address === this.base) this.pushStatus = '未能获取推送令牌，请检查应用的 Push Kit 权益';
        return;
      }
      if (!this.pushToken) return;
    }
    const enabled = this.pushEnabled;
    const response = await this.request('/runs/push', enabled ?
      { enabled: true, token: this.pushToken, device: pushDeviceId(computer.token) } : { enabled: false }, endpoint);
    if (enabled !== this.pushEnabled) return;
    if (!enabled || response.pushAvailable === true) {
      this.pushRegistrations.set(computer.address, enabled ? computer.token + ':' + this.pushToken : computer.token);
    }
    if (computer.address === this.base && enabled) this.pushStatus = response.pushAvailable ? '当前电脑已注册后台通知' : '这台电脑尚未配置 Push Kit';
  }

  private async setPushEnabled(enabled: boolean): Promise<void> {
    if (this.pushSaving) return;
    this.pushSaving = true;
    try {
      if (enabled && !(await notificationManager.isNotificationEnabled())) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await notificationManager.requestEnableNotification(context);
        if (!(await notificationManager.isNotificationEnabled())) throw new Error('notifications_disabled');
      }
      await this.saveSetting('run_push_enabled', enabled);
      this.pushEnabled = enabled;
      this.nextPushTokenAttempt = 0;
      this.pushStatus = enabled ? '正在连接电脑以启用后台通知…' : '';
      this.pushRegistrations.clear();
      this.queueRunSync(0);
    } catch {
      this.pushStatus = enabled ? '请在系统设置中允许 Pi Go 通知后重试' : '未能保存通知设置';
    } finally { this.pushSaving = false; }
  }

  private markRunRead(id: string): void {
    this.runRead = [id].concat(this.runRead.filter((value: string): boolean => value !== id)).slice(0, 240);
    this.inboxRuns = this.inboxRuns.map((row: InboxRun): InboxRun => row.run.id === id ? {
      run: row.run, address: row.address, computer: row.computer, unread: false
    } : row);
    void this.saveSetting('run_inbox_read', JSON.stringify(this.runRead)).catch(() => {});
    this.publishWidgets();
  }

  private async openInboxRun(row: InboxRun): Promise<void> {
    const target = this.computers.find((item: Companion): boolean => item.address === row.address && validCompanion(item));
    if (!target || !await this.openNotifiedSession(target, row.run.sessionId, row.run.pendingId ?? '', row.run.id)) return;
    this.markRunRead(row.run.id);
  }

  private onPushLaunch(): void { void this.consumePushLaunch(); }

  private async consumePushLaunch(): Promise<void> {
    if (!this.pushLaunchEvent || this.openingPush) return;
    this.openingPush = true;
    try {
      await this.restoreChain;
      for (let attempt = 0; attempt < 40 && this.pushLaunchEvent; attempt++) {
        if (this.visible && !this.loading && !this.busy && !this.openingSession) {
          const event = this.pushLaunchEvent;
          const device = this.pushLaunchDevice;
          const session = this.pushLaunchSession;
          const pending = this.pushLaunchPending;
          this.pushLaunchEvent = '';
          const target = this.computers.find((item: Companion): boolean =>
            validCompanion(item) && pushDeviceId(item.token) === device);
          let opened = false;
          if (target && session) {
            const alternatives = this.computers.filter((item: Companion): boolean =>
              item.address !== target.address && computerGroupId(item) === computerGroupId(target) && validCompanion(item));
            for (const connection of [target].concat(alternatives)) {
              if (await this.openNotifiedSession(connection, session, pending, event)) {
                opened = true;
                break;
              }
            }
          }
          if (opened) this.markRunRead(event);
          else this.showScheduleInbox();
          if (!this.pushLaunchEvent) return;
        }
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 300); });
      }
    } finally { this.openingPush = false; }
  }

  private async openNotifiedSession(target: Companion, id: string, pendingId: string, eventId: string): Promise<boolean> {
    if (this.busy || this.openingSession) return false;
    if (target.address !== this.base) this.chooseComputer(target);
    if (!this.isPaired || this.base !== target.address) return false;
    if (this.currentId !== id || !this.reachable) {
      if (!await this.requestAction('/open', { id: id, history: true })) {
        this.scheduleError = this.status || '暂时无法打开会话，请检查来源电脑。';
        return false;
      }
    }
    this.activeTab = 'tasks';
    this.showFiles = false;
    this.showSettings = false;
    this.showSessions = false;
    this.schedulePage = '';
    const key = this.draftKey(id);
    if (pendingId) {
      try {
        const result = await this.request('/session/snapshot');
        if (key !== this.draftKey(this.currentId)) return false;
        if (result.session?.id === id) {
          this.setInteraction(result.interaction);
          if (result.interaction?.id !== pendingId) {
            this.getUIContext().getPromptAction().showToast({ message: '这条待处理请求已结束或在其他设备上处理。' });
          }
        }
      } catch { this.schedule(0); }
    }
    await this.syncRunResults(this.connection.endpoint(), id, key);
    if (!pendingId && key === this.draftKey(this.currentId) && this.sessionRunKey === key) {
      const run = this.sessionRuns.find((row: RunEvent): boolean => row.id === eventId);
      if (run) this.openRunResult(run);
    }
    return true;
  }

  private openRunResult(run: RunEvent): void {
    if (run.sessionId !== this.currentId) return;
    this.dismissKeyboard();
    this.reviewedRun = run;
    this.reviewedFile = undefined;
    this.reviewError = '';
  }

  private backFromRunResult(): void {
    this.reviewRequest += 1;
    if (this.reviewedFile) this.reviewedFile = undefined;
    else this.reviewedRun = undefined;
    this.reviewPatch = '';
    this.reviewLoading = false;
    this.reviewError = '';
  }

  private async openRunDiff(file: RunFile): Promise<void> {
    const run = this.reviewedRun;
    if (!run || run.sessionId !== this.currentId) return;
    const request = ++this.reviewRequest;
    const epoch = this.epoch;
    this.reviewedFile = file;
    this.reviewPatch = '';
    this.reviewError = '';
    this.reviewLoading = true;
    try {
      const response = await this.request('/runs/diff?session=' + encodeURIComponent(run.sessionId) +
        '&run=' + encodeURIComponent(run.id) + '&path=' + encodeURIComponent(file.path));
      if (request !== this.reviewRequest || epoch !== this.epoch) return;
      if (!response.text) throw new Error('diff_unavailable');
      this.reviewPatch = response.text;
    } catch {
      if (request === this.reviewRequest && epoch === this.epoch) this.reviewError = '暂时无法读取本轮 Diff。';
    } finally {
      if (request === this.reviewRequest) this.reviewLoading = false;
    }
  }

  private citeRunLine(line: DiffLine): void {
    const file = this.reviewedFile;
    if (!file || this.reviewedRun?.sessionId !== this.currentId || line.line < 1) return;
    const reference = `请检查 ${file.path}:${line.line}（本轮 Diff）：\n${line.text.slice(1, 501)}`;
    this.draft = this.draft ? this.draft + '\n\n' + reference : reference;
    this.rememberDraft(this.currentId);
    this.backFromRunResult();
    this.backFromRunResult();
  }

  private async openRunArtifact(file: RunFile): Promise<void> {
    const run = this.reviewedRun;
    if (!run || run.sessionId !== this.currentId) return;
    this.reviewedRun = undefined;
    await this.openReferencedFile(run.cwd, file.path, false);
  }

  private scheduleEndpoint(computer: Companion): BridgeEndpoint {
    return { address: computer.address, token: computer.token, ca: computer.ca, pin: computer.pin };
  }

  private async syncScheduleComputer(computer: Companion): Promise<void> {
    const mutation = this.scheduleMutation;
    const generation = this.scheduleComputerGeneration;
    const watch = this.scheduleWatches.find((item: ScheduleWatch): boolean => item.address === computer.address);
    const knownRuns = this.scheduleMessages.filter((message: RunMessage): boolean =>
      message.address === computer.address || (!!watch?.source && message.source === watch.source))
      .map((message: RunMessage): string => message.run.id).slice(0, 80);
    try {
      const includeJobs = this.activeTab === 'pending' && this.base === computer.address;
      const result = await this.request('/schedules/sync', { knownRuns: knownRuns, includeJobs: includeJobs },
        this.scheduleEndpoint(computer));
      if (!this.visible || mutation !== this.scheduleMutation || !this.computers.some((item: Companion): boolean =>
        item.address === computer.address && item.token === computer.token)) return;
      this.acceptScheduleSync(computer, result);
      this.setScheduleOffline(computer.address, false);
      if (includeJobs && generation === this.scheduleComputerGeneration && this.activeTab === 'pending' &&
        !this.scheduleSaving && !this.scheduleLoading) this.applyScheduleJobs(result);
      this.scheduleRetries.delete(computer.address);
      this.scheduleDue.set(computer.address, Date.now() + 12_000);
    } catch (error) {
      if (mutation !== this.scheduleMutation || !this.computers.some((item: Companion): boolean =>
        item.address === computer.address && item.token === computer.token)) return;
      if (error instanceof BridgeFailure && (error.status === 401 || error.status === 404)) {
        this.setScheduleWatch(computer.address, '', false);
        this.setScheduleOffline(computer.address, false);
        this.scheduleMessages = this.scheduleMessages.filter((message: RunMessage): boolean => message.address !== computer.address);
        this.scheduleActive = this.scheduleActive.filter((message: RunMessage): boolean => message.address !== computer.address);
        return;
      }
      const retries = Math.min(5, (this.scheduleRetries.get(computer.address) ?? 0) + 1);
      this.scheduleRetries.set(computer.address, retries);
      this.scheduleDue.set(computer.address, Date.now() + 6000 * Math.pow(2, retries));
      this.setScheduleOffline(computer.address, true);
      if (watch?.source) {
        const alternatives = this.computers.filter((item: Companion): boolean =>
          item.address !== computer.address && computerGroupId(item) === computerGroupId(computer));
        for (const alternate of alternatives) {
          try {
            const result = await this.request('/schedules/sync', { knownRuns: knownRuns }, this.scheduleEndpoint(alternate));
            if (result.source !== watch.source || !this.visible || mutation !== this.scheduleMutation ||
              !this.computers.some((item: Companion): boolean =>
              item.address === alternate.address && item.token === alternate.token)) continue;
            this.acceptScheduleSync(alternate, result);
            this.setScheduleOffline(computer.address, false);
            this.setScheduleOffline(alternate.address, false);
            // Keep the original connection under backoff so either transport can recover.
            break;
          } catch { }
        }
      }
    }
  }

  private setScheduleOffline(address: string, offline: boolean): void {
    if (this.scheduleOffline.includes(address) === offline) return;
    this.scheduleOffline = offline ? this.scheduleOffline.concat([address]) :
      this.scheduleOffline.filter((item: string): boolean => item !== address);
  }

  private acceptScheduleSync(computer: Companion, result: BridgeReply): void {
    const source = result.source;
    if (!source) return;
    this.setScheduleWatch(computer.address, source, result.watching === true);
    const name = this.scheduleComputerName(computer);
    const readRuns = this.readScheduleRuns(source);
    const dismissedRuns = this.readScheduleRuns(source, true);
    const incoming = (result.runs ?? []).map((run: ScheduleRun): RunMessage => {
      const dismissed = dismissedRuns.includes(run.id);
      return { key: `${source}:${run.id}`, source: source, address: computer.address, computer: name, run: run,
        unread: !dismissed && !readRuns.includes(run.id), dismissed: dismissed };
    });
    const old = this.scheduleMessages;
    const newMessage = incoming.find((message: RunMessage): boolean => message.unread &&
      !old.some((previous: RunMessage): boolean => previous.key === message.key));
    this.scheduleMessages = old.filter((message: RunMessage): boolean => message.address !== computer.address &&
      !incoming.some((item: RunMessage): boolean => item.key === message.key)).concat(incoming)
      .sort((left: RunMessage, right: RunMessage): number => (right.run.finishedAt ?? 0) - (left.run.finishedAt ?? 0));
    const active = (result.activeRuns ?? []).map((run: ScheduleRun): RunMessage => ({
      key: `${source}:${run.id}`, source: source, address: computer.address, computer: name, run: run, unread: false
    }));
    this.scheduleActive = this.scheduleActive.filter((message: RunMessage): boolean => message.address !== computer.address &&
      !active.some((item: RunMessage): boolean => item.key === message.key) &&
      !incoming.some((item: RunMessage): boolean => item.key === message.key)).concat(active);
    if (newMessage && !this.schedulePage && this.runNoticesEnabled) {
      this.scheduleBanner = newMessage;
      if (this.scheduleBannerTimer !== -1) clearTimeout(this.scheduleBannerTimer);
      this.scheduleBannerTimer = setTimeout(() => { this.scheduleBanner = undefined; }, 6500);
    }
    this.publishWidgets();
  }

  private readScheduleRuns(source: string, dismissed: boolean = false): string[] {
    const cache = dismissed ? this.scheduleDismissed : this.scheduleRead;
    const key = dismissed ? `schedule_dismissed_${source}` : `schedule_read_${source}`;
    const cached = cache.get(source);
    if (cached) return cached;
    let read: string[] = [];
    try {
      const raw = this.settings?.getSync(key, '[]') as string;
      if (raw) {
        const ids = JSON.parse(raw) as string[];
        if (Array.isArray(ids)) read = ids.filter((id: string): boolean => typeof id === 'string').slice(0, 80);
      }
    } catch { }
    cache.set(source, read);
    return read;
  }

  private dismissScheduleMessage(message: RunMessage): void {
    const previous = this.readScheduleRuns(message.source, true);
    if (previous.includes(message.run.id)) return;
    const dismissed = [message.run.id].concat(previous).slice(0, 80);
    this.scheduleDismissed.set(message.source, dismissed);
    this.scheduleMessages = this.scheduleMessages.map((item: RunMessage): RunMessage => item.key === message.key
      ? { key: item.key, source: item.source, address: item.address, computer: item.computer, run: item.run,
        unread: false, dismissed: true } : item);
    void this.saveSetting(`schedule_dismissed_${message.source}`, JSON.stringify(dismissed)).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '暂时无法保存删除记录。' });
    });
  }

  private removeScheduleMessage(message: RunMessage): void {
    this.scheduleMessages = this.scheduleMessages.filter((item: RunMessage): boolean => item.key !== message.key);
    if (this.scheduleBanner?.key === message.key) this.scheduleBanner = undefined;
    if (this.scheduleDetail?.key === message.key) this.scheduleDetail = undefined;
    const read = this.readScheduleRuns(message.source);
    if (read.includes(message.run.id)) {
      const nextRead = read.filter((id: string): boolean => id !== message.run.id);
      this.scheduleRead.set(message.source, nextRead);
      void this.saveSetting(`schedule_read_${message.source}`, JSON.stringify(nextRead)).catch(() => {});
    }
    const dismissed = this.readScheduleRuns(message.source, true);
    if (dismissed.includes(message.run.id)) {
      const nextDismissed = dismissed.filter((id: string): boolean => id !== message.run.id);
      this.scheduleDismissed.set(message.source, nextDismissed);
      void this.saveSetting(`schedule_dismissed_${message.source}`, JSON.stringify(nextDismissed)).catch(() => {});
    }
  }

  private async deleteScheduleRuns(messages: RunMessage[]): Promise<boolean> {
    if (this.scheduleSaving || !messages.length) return false;
    const computer = this.computers.find((item: Companion): boolean => item.address === this.base);
    if (!computer) {
      this.getUIContext().getPromptAction().showToast({ message: '请先连接电脑。' });
      return false;
    }
    const generation = this.scheduleComputerGeneration;
    this.scheduleSaving = true;
    this.scheduleError = '';
    let deleted = 0;
    let failureText = '';
    try {
      for (const message of messages) {
        if (generation !== this.scheduleComputerGeneration) return false;
        try {
          const payload: Payload = { operation: 'delete-run', cwd: message.run.cwd, id: message.run.id };
          await this.request('/schedules/update', payload, this.scheduleEndpoint(computer));
          this.scheduleMutation += 1;
          this.removeScheduleMessage(message);
          deleted += 1;
        } catch (error) {
          const failure = error as Error;
          if (!failureText) failureText = failure.message === 'schedule_missing' ?
            '请先更新电脑端 Pi Go。' : this.scheduleFailure(failure);
          if (!(error instanceof BridgeFailure) || error.status === 401 || error.status === 404 ||
            error.status >= 500 || failure.message === 'desktop_handoff_required' ||
            failure.message === 'desktop_handoff_unconfirmed') break;
        }
      }
      if (generation !== this.scheduleComputerGeneration) return false;
      if (failureText) {
        const message = deleted ? `已删除 ${deleted} 条。${failureText}` : failureText;
        this.getUIContext().getPromptAction().showToast({ message: message });
      }
      return deleted === messages.length;
    } finally {
      this.queueScheduleSync(true);
      if (generation === this.scheduleComputerGeneration) this.scheduleSaving = false;
    }
  }

  private publishWidgets(): void {
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    const pendingSet = new Set<string>();
    const unreadSet = new Set<string>();
    for (const row of this.inboxRuns) {
      if (row.run.status === 'waiting') pendingSet.add(row.run.id);
      if (row.unread) unreadSet.add(row.run.id);
    }
    for (const msg of this.scheduleMessages) {
      if (!msg.dismissed && msg.unread) unreadSet.add(msg.key);
    }
    const displayedInbox = this.displayedInboxRuns();
    const runningRows = this.taskPanelRows();
    const activeSchedules = this.standaloneScheduleRuns();

    const runningItems: WidgetItem[] = runningRows.slice(0, 4).map((row: RunningRow): WidgetItem => {
      const state = row.state ?? this.sessionState(row.id);
      return {
        id: row.id,
        sessionId: row.id,
        address: this.base,
        computer: this.computerTitle(),
        title: row.name || '后台任务',
        subtitle: row.cwd ? this.workspaceName(row.cwd) : this.computerTitle(),
        status: state || 'streaming',
        statusText: this.stateLabel(state || 'streaming'),
        timeText: '进行中',
        unread: state === 'waiting'
      };
    }).concat(activeSchedules.slice(0, 2).map((row: RunMessage): WidgetItem => ({
      id: row.run.id,
      sessionId: row.run.sessionId ?? '',
      address: row.address,
      computer: row.computer,
      title: row.run.name || '定时任务',
      subtitle: `${row.computer} · 定时运行中`,
      status: 'running',
      statusText: '运行中',
      timeText: '进行中',
      unread: false
    }))).slice(0, 5);

    const inboxItems: WidgetItem[] = displayedInbox.slice(0, 6).map((row: InboxRun): WidgetItem => ({
      id: row.run.id,
      sessionId: row.run.sessionId,
      pendingId: row.run.pendingId ?? '',
      address: row.address,
      computer: row.computer,
      title: row.run.title || 'Pi 会话',
      subtitle: `${row.computer} · ${scheduleTime(row.run.finishedAt).slice(5)}`,
      status: row.run.status,
      statusText: runStatus(row.run.status),
      timeText: scheduleTime(row.run.finishedAt).slice(5),
      unread: row.unread
    }));

    const scheduleItems: WidgetItem[] = this.scheduleMessages
      .filter((msg: RunMessage): boolean => !msg.dismissed)
      .slice(0, 5)
      .map((msg: RunMessage): WidgetItem => ({
        id: msg.run.id,
        sessionId: msg.run.sessionId ?? '',
        address: msg.address,
        computer: msg.computer,
        title: msg.run.name || '定时任务',
        subtitle: msg.run.summary || `${msg.computer} · ${scheduleTime(msg.run.finishedAt ?? msg.run.scheduledAt).slice(5)}`,
        status: msg.run.status,
        statusText: scheduleRunStatus(msg.run.status),
        timeText: scheduleTime(msg.run.finishedAt ?? msg.run.scheduledAt).slice(5),
        unread: msg.unread
      }));

    const combinedItems: WidgetItem[] = inboxItems
      .filter((item: WidgetItem): boolean => item.status === 'waiting')
      .concat(runningItems.filter((runItem: WidgetItem): boolean =>
        !inboxItems.some((inItem: WidgetItem): boolean => inItem.status === 'waiting' && inItem.sessionId === runItem.sessionId)))
      .concat(inboxItems.filter((item: WidgetItem): boolean => item.status !== 'waiting'))
      .concat(scheduleItems)
      .slice(0, 6);

    const nextJob = this.scheduleJobs.find((job: ScheduleJob): boolean => job.enabled && job.nextAt !== null);
    const snapshot: WidgetSnapshot = {
      pending: pendingSet.size,
      unread: unreadSet.size,
      running: this.runningTaskCount(),
      scheduleCount: this.scheduleJobs.filter((job: ScheduleJob): boolean => job.enabled).length,
      syncedAt: this.computers.length ? Date.now() : 0,
      paired: this.isPaired || this.computers.length > 0,
      reachable: this.reachable,
      computer: this.computers.length ? this.computerTitle() : '',
      workspace: this.project || (this.workspaceCwd ? this.workspaceName(this.workspaceCwd) : ''),
      currentSessionId: this.currentId,
      currentSessionTitle: this.currentId && !this.noSession ? this.chatTitle() : '',
      nextScheduleName: nextJob?.name ?? '',
      nextScheduleTime: nextJob?.nextAt ? scheduleTime(nextJob.nextAt).slice(5) : '',
      items: combinedItems,
      runningItems: runningItems,
      scheduleItems: scheduleItems
    };
    void this.inboxWidget.publish(context, snapshot);
  }

  private onInboxFormLaunch(): void {
    if (!this.inboxFormLaunch || !this.visible || this.loading) return;
    this.inboxFormLaunch = false;
    const destination = this.formDestination || 'inbox';
    const sessionId = this.formSessionId;
    const address = this.formAddress;
    const pendingId = this.formPendingId;
    const eventId = this.formEventId;
    this.formDestination = '';
    this.formSessionId = '';
    this.formAddress = '';
    this.formPendingId = '';
    this.formEventId = '';
    this.reviewedRun = undefined;
    if (this.markdownTableReader) this.closeMarkdownTableReader();
    if (destination === 'computers' || (!this.isPaired && destination !== 'inbox')) {
      this.schedulePage = '';
      this.openComputers();
      return;
    }
    if (destination === 'session' && sessionId) {
      const target = (address ? this.computers.find((item: Companion): boolean =>
        item.address === address && validCompanion(item)) : undefined) ??
        this.computers.find((item: Companion): boolean => item.address === this.base && validCompanion(item));
      if (target) {
        void this.openNotifiedSession(target, sessionId, pendingId, eventId).then((opened: boolean) => {
          if (opened && eventId) this.markRunRead(eventId);
          else if (!opened) this.showScheduleInbox();
        });
        return;
      }
    }
    if (destination === 'new_task') {
      this.schedulePage = '';
      this.selectRootTab('tasks');
      this.openNewSession();
      return;
    }
    if (destination === 'pending') {
      this.schedulePage = '';
      this.selectRootTab('pending');
      return;
    }
    if (destination === 'new_schedule') {
      this.selectRootTab('pending');
      this.editSchedule();
      return;
    }
    if (destination === 'schedule_history') {
      this.selectRootTab('pending');
      this.scheduleError = '';
      this.schedulePage = 'history';
      return;
    }
    if (destination === 'files') {
      this.schedulePage = '';
      if (!this.selectRootTab('files')) this.selectRootTab('tasks');
      return;
    }
    if (destination === 'tasks') {
      this.schedulePage = '';
      this.selectRootTab('tasks');
      return;
    }
    this.showScheduleInbox();
  }

  private showScheduleInbox(): void {
    this.dismissKeyboard();
    this.scheduleBanner = undefined;
    this.schedulePage = 'inbox';
    this.queueScheduleSync(true);
    this.queueRunSync(0);
  }

  private showScheduleDetail(message: RunMessage): void {
    this.dismissKeyboard();
    this.schedulePrevious = this.schedulePage;
    this.scheduleDetail = message;
    this.schedulePage = 'detail';
    this.scheduleBanner = undefined;
    if (!message.unread) return;
    const read = [message.run.id].concat(this.readScheduleRuns(message.source)
      .filter((id: string): boolean => id !== message.run.id)).slice(0, 80);
    this.scheduleRead.set(message.source, read);
    this.scheduleMessages = this.scheduleMessages.map((item: RunMessage): RunMessage => item.key === message.key
      ? { key: item.key, source: item.source, address: item.address, computer: item.computer, run: item.run, unread: false } : item);
    void this.saveSetting(`schedule_read_${message.source}`, JSON.stringify(read)).catch(() => {});
  }

  private backFromSchedule(): void {
    if (this.scheduleSaving || this.inboxCleaning) return;
    if (this.schedulePage === 'detail') this.schedulePage = this.schedulePrevious;
    else this.schedulePage = '';
    this.scheduleError = '';
  }

  private async openScheduledSession(message: RunMessage): Promise<void> {
    if (!message.run.sessionId || this.busy || this.openingSession) return;
    const computer = this.computers.find((item: Companion): boolean => item.address === message.address);
    if (!computer) { this.scheduleError = '请先配对来源电脑。'; return; }
    this.scheduleError = '';
    if (this.base !== computer.address) this.chooseComputer(computer);
    if (this.base !== computer.address) { this.scheduleError = '无法切换到来源电脑。'; return; }
    if (await this.requestAction('/open', { id: message.run.sessionId })) {
      this.activeTab = 'tasks';
      this.schedulePage = '';
    } else this.scheduleError = this.status || '暂时无法打开会话，请检查来源电脑的连接。';
  }

  private async loadScheduleJobs(): Promise<void> {
    const computer = this.computers.find((item: Companion): boolean => item.address === this.base);
    if (!computer || this.scheduleLoading) return;
    const generation = this.scheduleComputerGeneration;
    this.scheduleLoading = true;
    this.scheduleListError = '';
    try {
      const result = await this.request('/schedules/sync', { includeJobs: true }, this.scheduleEndpoint(computer));
      if (generation !== this.scheduleComputerGeneration) return;
      this.applyScheduleJobs(result);
      this.acceptScheduleSync(computer, result);
    } catch (error) {
      if (generation === this.scheduleComputerGeneration) this.scheduleListError = this.scheduleFailure(error as Error);
    } finally {
      if (generation === this.scheduleComputerGeneration) this.scheduleLoading = false;
    }
  }

  private applyScheduleJobs(result: BridgeReply): void {
    this.scheduleJobs = (result.jobs ?? []).sort((left: ScheduleJob, right: ScheduleJob): number =>
      (left.nextAt ?? Number.MAX_SAFE_INTEGER) - (right.nextAt ?? Number.MAX_SAFE_INTEGER));
    this.scheduleZone = result.timezone ?? '';
    this.scheduleListError = '';
    this.publishWidgets();
  }

  private resetScheduleJobs(): void {
    this.scheduleComputerGeneration += 1;
    this.scheduleJobs = [];
    this.scheduleZone = '';
    this.scheduleListError = '';
    this.scheduleLoading = false;
    this.scheduleSaving = false;
    if (this.schedulePage === 'editor' || this.schedulePage === 'history') this.schedulePage = '';
    if (this.schedulePrevious === 'history') this.schedulePrevious = '';
  }

  private editSchedule(job?: ScheduleJob): void {
    this.scheduleEditing = job;
    this.scheduleName = job?.name ?? '';
    this.schedulePrompt = job?.prompt ?? '';
    this.scheduleCwd = job?.cwd ?? (this.projects.includes(this.workspaceCwd) ? this.workspaceCwd : this.projects[0] ?? '');
    this.scheduleKind = job?.kind ?? 'once';
    this.scheduleWhen = job?.kind === 'daily' ? job.time ?? '' : job?.kind === 'interval' ? String(job.interval ?? 60) :
      scheduleTime(job?.at ?? Date.now() + 120_000);
    this.scheduleCatchUp = String(job?.catchUp ?? 0);
    this.scheduleError = '';
    this.schedulePage = 'editor';
  }

  private scheduleFailure(error: Error): string {
    const code = error.message;
    if (code === 'not_found' || code === 'schedules_unsupported') return '请先更新电脑端 Pi Go。';
    if (code === 'desktop_workspace_unshared') return '请先在电脑端共享所选工作区。';
    if (code === 'schedule_changed') return '定时任务已被修改，请返回列表刷新。';
    if (code === 'schedule_busy') return '任务已在运行，或电脑已达并发上限。';
    if (code === 'schedule_expired') return '请编辑并选择新的执行时间。';
    if (code === 'invalid_schedule') return '请检查时间、补跑窗口和提示词。';
    return '电脑端未确认操作结果，请检查连接后刷新。';
  }

  private async updateSchedule(operation: string, job?: ScheduleJob): Promise<void> {
    if (this.scheduleSaving || this.scheduleLoading) return;
    const computer = this.computers.find((item: Companion): boolean => item.address === this.base);
    if (!computer) { this.scheduleError = '请先连接电脑。'; return; }
    const payload: Payload = { operation: operation, cwd: job?.cwd ?? this.scheduleCwd, id: job?.id,
      scheduleVersion: job?.version, requestId: util.generateRandomUUID() };
    if (operation === 'create' || operation === 'edit') {
      const when = this.scheduleWhen.trim();
      const catchUp = this.scheduleCatchUp.trim();
      if (!payload.cwd || !this.scheduleName.trim() || !this.schedulePrompt.trim() ||
        this.schedulePrompt.trim().startsWith('/') || !/^\d{1,4}$/.test(catchUp) || Number(catchUp) > 1440) {
        this.scheduleError = '请选择工作区并填写名称、提示词和有效的补跑分钟数。';
        return;
      }
      payload.name = this.scheduleName;
      payload.prompt = this.schedulePrompt;
      payload.kind = this.scheduleKind;
      payload.catchUp = Number(catchUp);
      if (this.scheduleKind === 'once') {
        payload.at = parseScheduleTime(when);
        if (payload.at <= Date.now()) { this.scheduleError = '请输入未来时间，格式为 YYYY-MM-DD HH:mm。'; return; }
      } else if (this.scheduleKind === 'daily') {
        if (!/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(when)) { this.scheduleError = '请输入 24 小时时间，格式为 HH:mm。'; return; }
        payload.time = when;
      } else {
        if (!/^\d{1,5}$/.test(when) || Number(when) < 1 || Number(when) > 10080) {
          this.scheduleError = '间隔须为 1 至 10080 分钟。'; return;
        }
        payload.interval = Number(when);
      }
    }
    const generation = this.scheduleComputerGeneration;
    const editing = operation === 'create' || operation === 'edit';
    this.scheduleSaving = true;
    this.scheduleError = '';
    try {
      await this.request('/schedules/update', payload, this.scheduleEndpoint(computer));
      this.scheduleMutation += 1;
      const current = this.scheduleWatches.find((watch: ScheduleWatch): boolean => watch.address === computer.address);
      this.setScheduleWatch(computer.address, current?.source ?? '', true);
      this.queueScheduleSync(true);
      if (generation !== this.scheduleComputerGeneration) return;
      if (editing) this.schedulePage = '';
      if (operation === 'run') this.getUIContext().getPromptAction().showToast({ message: '已提交到电脑运行' });
      await this.loadScheduleJobs();
    } catch (error) {
      if (generation === this.scheduleComputerGeneration) {
        const message = this.scheduleFailure(error as Error);
        if (editing) this.scheduleError = message;
        else this.getUIContext().getPromptAction().showToast({ message: message });
      }
    } finally {
      if (generation === this.scheduleComputerGeneration) this.scheduleSaving = false;
    }
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
        this.stopStream();
        this.startStream();
        this.schedule(0);
      }
      this.queueRunSync(0);
      this.queueScheduleSync(true);
    }, 400);
  }

  private canSwitchNetwork(): boolean {
    return this.visible && this.isPaired && !this.reachable && !this.busy && !this.openingSession &&
      !this.pendingSend && !this.editingPath && !this.removeTarget && !this.scheduleSaving &&
      !this.showNewSession && !this.showNewSpace && !this.showSettings && this.schedulePage !== 'editor' &&
      !this.textFilePreview && !this.markdownTableReader && !this.reviewedRun &&
      this.activeTab === 'tasks' && !this.recording && !this.voicePreparing && !this.voiceFinishing;
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
    const epoch = this.epoch;
    const session = this.currentId;
    const oldKey = this.draftKey(session);
    try {
      for (const target of alternatives) {
        const newKey = `${target.address}|${session}`;
        let remote: BridgeReply;
        try {
          remote = await this.request('/session', undefined, this.scheduleEndpoint(target));
        } catch { continue; }
        if (epoch !== this.epoch || !this.canSwitchNetwork() || session !== this.currentId) return;
        if (!this.computers.some((item: Companion): boolean =>
          item.address === target.address && item.token === target.token &&
          computerGroupId(item) === computerGroupId(active))) continue;
        const targetDraft = this.chatState.drafts.get(newKey);
        const targetAttachments = this.chatState.draftAttachments.get(newKey);
        // Leave independent drafts and an unconfirmed send accessible at their original endpoints.
        if (this.chatState.unconfirmed.has(newKey) || (this.draft && targetDraft) ||
            (this.attachments.length && targetAttachments?.length)) continue;
        const text = this.draft;
        const attachments = this.attachments;
        this.leaveComputer(false, target);
        if (session && text) {
          this.chatState.drafts.set(newKey, text);
          this.chatState.drafts.delete(oldKey);
        }
        if (session && attachments.length) {
          this.chatState.draftAttachments.set(newKey, attachments);
          this.chatState.draftAttachments.delete(oldKey);
        }
        if (session && remote.session?.id !== session) await this.requestAction('/open', { id: session });
        else if (session) this.showSessions = false;
        return;
      }
    } finally { this.switchingNetwork = false; }
  }

  private schedule(delay: number): void {
    this.cancelSchedule();
    if (!this.isPaired || (!this.visible && !this.backgroundLiveActivity())) return;
    this.connection.schedulePoll(delay, (): void => { void this.poll(); });
  }

  private async request(path: string, input?: Payload, endpoint?: BridgeEndpoint): Promise<BridgeReply> {
    return this.client.request(endpoint ?? this.connection.endpoint(), path, input);
  }

  private stopStream(): void {
    this.chatState.sync.disconnect();
    this.historyRequest += 1;
    this.historyLoadingEpoch = undefined;
    this.streamGen += 1;
    this.flushStreamDeltas();
    this.connection.cancelRetry();
    const req = this.streamReq;
    this.streamReq = undefined;
    this.streamAlive = false;
    if (req) req.destroy();
  }

  private scheduleStream(delay: number): void {
    this.connection.cancelRetry();
    if (!this.isPaired || (!this.visible && !this.backgroundLiveActivity()) || !this.base || !this.connection.endpoint().token) return;
    this.connection.scheduleRetry(delay, (): void => { this.startStream(); });
  }

  private streamDown(gen: number, delay: number): void {
    if (gen !== this.streamGen) return;
    this.chatState.sync.disconnect();
    this.historyRequest += 1;
    this.historyLoadingEpoch = undefined;
    if (this.syncMode === 'sequenced') this.schedule(0);
    this.streamGen += 1;
    this.flushStreamDeltas();
    const req = this.streamReq;
    this.streamReq = undefined;
    this.streamAlive = false;
    if (req) req.destroy();
    this.scheduleStream(delay);
  }

  private startStream(): void {
    if (!this.isPaired || (!this.visible && !this.backgroundLiveActivity()) || !this.base || !this.connection.endpoint().token || this.streamReq ||
        this.syncMode === 'probe' || (this.syncMode === 'sequenced' && this.openingSession)) return;
    const gen = ++this.streamGen;
    const path = this.syncMode === 'sequenced' ? '/events?sync=2' : '/events';
    this.streamReq = this.client.openEvents(this.connection.endpoint(), path, {
      current: (): boolean => gen === this.streamGen,
      ready: (): void => { this.streamAlive = true; },
      frame: (payload: string): void => { this.handleFrame(payload); },
      closed: (delay: number): void => { this.streamDown(gen, delay); },
      revoked: (): void => { this.leaveComputer(true); }
    });
  }

  private queueStreamPaint(): void {
    this.chatState.queueStreamPaint((): void => { this.flushStreamDeltas(); });
  }

  private flushStreamDeltas(paint: boolean = true): void {
    const delta = this.chatState.flushStreamDeltas(this.liveText, this.liveThinking, paint);
    if (!delta) return;
    this.pendingBottom = true;
    this.liveText = delta.text;
    this.liveThinking = delta.thinking;
  }

  private handleFrame(raw: string): void {
    if (this.chatState.receiveFrame(raw, this.syncMode === 'sequenced', (event: StreamFrame): void => this.applyStreamFrame(event))) {
      this.schedule(0);
    }
  }

  private applyStreamFrame(frame: StreamFrame): void {
    if (frame.sessionId && frame.sessionId !== this.currentId) {
      if (frame.type === 'session/changed' || frame.type === 'ready') this.schedule(150);
      return;
    }
    if (frame.type === 'message/delta') {
      if (typeof frame.text === 'string' && frame.text && (frame.cursor !== undefined || frame.seq === undefined || frame.seq > this.liveSeq)) {
        this.chatState.appendDelta(frame.text, false);
        if (frame.seq !== undefined) this.liveSeq = frame.seq;
        this.queueStreamPaint();
      }
      return;
    }
    if (frame.type === 'message/thinking') {
      if (typeof frame.text === 'string' && frame.text && (frame.cursor !== undefined || frame.seq === undefined || frame.seq > this.liveThinkSeq)) {
        this.chatState.appendDelta(frame.text, true);
        if (frame.seq !== undefined) this.liveThinkSeq = frame.seq;
        this.queueStreamPaint();
      }
      return;
    }
    if (frame.type === 'tool/start' || frame.type === 'tool/end') {
      const tool = frame.tool;
      if (tool && tool.id) {
        const index = this.liveTools.findIndex((item: LiveTool): boolean => item.id === tool.id);
        if (index >= 0) {
          const merged = this.liveTools.slice(0);
          merged[index] = tool;
          this.liveTools = merged;
        } else {
          this.liveTools = this.liveTools.concat([tool]);
        }
        if (frame.type === 'tool/end') {
          this.refreshSelectedTool(tool);
          this.schedule(150);
        }
        this.pendingBottom = true;
      }
      return;
    }
    const eventRun = frame.cursor ? frame.cursor.runId : frame.runId;
    if (frame.type === 'queue/status') {
      // steering 排队状态即时回传：不重置流式内容，只更新 runId 与 queued。
      if (eventRun) this.runId = eventRun;
      if (frame.queued !== undefined) this.queued = frame.queued;
      this.syncLiveActivity();
      return;
    }
    if (frame.type === 'session/status') {
      this.liveRevision += 1;
      if (frame.idle === true) {
        this.idle = true;
        this.queued = frame.queued ?? false;
        this.observeRun(this.currentId, this.chatTitle(), this.queued, frame.aborted === true);
        this.runId = '';
        if (frame.cursor) {
          this.flushStreamDeltas(false);
          this.liveText = '';
          this.liveThinking = '';
          this.liveThinkingOpen = false;
          this.liveTools = [];
        }
        this.schedule(150);
      } else if (frame.idle === false) {
        this.observeRun(this.currentId, this.chatTitle(), true);
        this.flushStreamDeltas(false);
        this.idle = false;
        // 运行开始即携带 runId，手机可立即引导，无需等 /chat 轮询。
        if (eventRun) this.runId = eventRun;
        if (frame.queued !== undefined) this.queued = frame.queued;
        this.liveText = '';
        this.liveThinking = '';
        this.liveThinkSeq = 0;
        this.liveThinkingOpen = false;
        this.liveTools = [];
        this.liveSeq = 0;
      }
      this.syncLiveActivity();
      return;
    }
    if (frame.type === 'message/final') {
      this.liveRevision += 1;
      if (frame.cursor || (frame.seq !== undefined && frame.seq >= this.liveSeq)) {
        this.chatState.clearDelta(false);
        this.liveText = '';
        this.liveSeq = frame.seq ?? 0;
      }
      if (frame.cursor || (frame.thinkingSeq !== undefined && frame.thinkingSeq >= this.liveThinkSeq)) {
        this.chatState.clearDelta(true);
        this.liveThinking = '';
        this.liveThinkSeq = frame.thinkingSeq ?? 0;
        this.liveThinkingOpen = false;
      }
      if (frame.reason === 'error') this.status = 'Pi 模型运行失败，请在电脑上查看当前会话或 Pi Go 日志。';
      this.schedule(200);
      return;
    }
    if (frame.type === 'prompt/unconfirmed') {
      this.status = 'Pi 未确认这次发送。请在电脑上核对会话，应用不会自动重发。';
      return;
    }
    if (frame.type === 'session/changed') {
      this.schedule(150);
      return;
    }
  }

  private async pair(): Promise<void> {
    if (this.busy || this.openingSession) return;
    const profile = this.huaweiProfile;
    let pairing: PairingRequest;
    try {
      pairing = this.connection.pairingRequest(this.pairingMode, this.address, this.ticket, this.pairingBundle, this.computers);
    } catch (error) {
      this.status = (error as Error).message;
      return;
    }
    const base = pairing.endpoint.address;
    this.busy = true;
    this.status = '';
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
        catch { this.status = '已连接；凭证未能保存。'; }
      }
      if (profile && this.huaweiProfile === profile) {
        this.updateCloudComputer(base, validUsb(base) ? 'usb' : connectionLabel(record) === '公网' ? 'remote' : 'lan');
      }
    } catch (error) {
      this.status = error instanceof BridgeFailure && error.status === 401 ? '票据已经失效，请在电脑上重新生成。' :
        this.pairingMode !== 'usb' ? '无法建立安全连接。请检查网络、Pi Go 服务和配对包。' : '无法连接电脑，请确认 USB 转发和 Pi Go 桥接服务。';
    } finally { this.busy = false; }
  }

  private selectPairingMode(mode: string): void {
    if (mode === this.pairingMode) return;
    this.pairingMode = mode;
    if (mode === 'usb' && !validUsb(this.address)) this.address = USB_ADDRESS;
    this.status = '';
    this.pairingBundle = '';
    this.lanCandidates = [];
    this.ticket = '';
  }

  private async scanPairingBundle(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context || this.busy) return;
    this.busy = true;
    this.status = '';
    try {
      const result = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: true
      });
      const bundle = decodePairingBundle(result.originalValue, this.pairingMode === 'remote');
      this.pairingBundle = result.originalValue;
      this.status = `已导入 ${bundle.url}。确认是自己的电脑后，点「配对并连接」。`;
    } catch {
      this.status = this.pairingMode === 'remote' ? '未导入公网配对包，请扫描 Pi Go.app「公网」二维码。' :
        '未导入局域网配对包，请扫描 Pi Go.app「局域网扫码」二维码。';
    }
    finally { this.busy = false; }
  }

  private async findLanCompanions(): Promise<void> {
    if (this.busy || this.openingSession) return;
    this.busy = true;
    this.lanCandidates = [];
    this.status = '';
    try {
      this.lanCandidates = await this.connection.discover();
      if (!this.lanCandidates.length) this.status = '未发现 Pi Go。可直接扫码或粘贴配对包。';
    } catch { this.status = '发现不可用，可直接导入配对包。'; }
    finally { this.busy = false; }
  }

  private leaveComputer(revoked: boolean = false, next?: Companion): void {
    if (this.markdownTableReader) this.closeMarkdownTableReader();
    this.textFilePreview = undefined;
    this.closeToolDetails();
    const address = this.base;
    if (this.currentId) this.rememberDraft(this.currentId);
    this.epoch += 1;
    if (!next) this.resetScheduleJobs();
    this.cancelSchedule();
    this.stopStream();
    this.base = '';
    this.connection.disconnect();
    this.pairingBundle = '';
    this.currentId = '';
    this.resetCommands();
    this.pendingSessionReveal = '';
    this.noSession = '';
    this.project = '';
    this.workspaceCwd = '';
    this.showFiles = false;
    if (!next && this.activeTab !== 'mine') {
      this.activeTab = 'mine';
      this.minePage = 'computers';
    }
    this.addingComputer = false;
    this.pairingComputerId = '';
    this.offlineDismissed = false;
    this.closeFileEditor();
    this.resetFileTree();
    this.sessionName = '';
    this.liveText = '';
    this.liveThinking = '';
    this.liveThinkSeq = 0;
    this.liveThinkingOpen = false;
    this.thinkingOpenIds = [];
    this.liveTools = [];
    this.liveSeq = 0;
    this.messages = [];
    this.sessions = [];
    this.chatState.chatCache.clear();
    this.runningSessionIds = [];
    this.runningSessions = [];
    this.observedRuns.clear();
    this.clearRunNotices();
    this.draft = '';
    this.showSessions = false;
    this.showSettings = false;
    this.models = [];
    this.modelLabel = '';
    this.setInteraction();
    this.pendingSend = undefined;
    this.hostAvailable = false;
    this.canCreateWorkspace = false;
    this.showNewSpace = false;
    this.newSpaceName = '';
    this.newSpaceError = '';
    this.projects = [];
    this.workspaces = [];
    this.resetCatalog();
    this.isPaired = false;
    this.runId = '';
    this.queued = false;
    this.acceptsImage = false;
    this.attachments = [];
    this.resetVoice();
    this.recording = false;
    this.holdActive = false;
    this.holdCancel = false;
    this.liveVoiceText = '';
    this.voiceMode = false;
    this.reachable = false;
    if (revoked) {
      this.computers = this.computers.filter((record: Companion): boolean => record.address !== address);
      this.forgetDrafts(address);
      this.queueRunSync(0);
    }
    this.status = revoked ? '该电脑的配对已撤销，请重新连接。' : '';
    if (next) this.activateComputer(next);
    this.syncLiveActivity();
    void this.persistComputers().catch(() => { this.status = '无法保存电脑列表的本次更改。'; });
  }

  private removeComputer(address: string): void {
    if (this.removeTarget !== address || this.busy || this.openingSession) return;
    this.removeTarget = '';
    if (this.huaweiProfile) this.updateCloudComputer(address, '');
    const removed = this.computers.find((item: Companion): boolean => item.address === address);
    if (removed) {
      void this.request('/runs/push', { enabled: false }, this.scheduleEndpoint(removed)).catch(() => {});
      this.pushRegistrations.delete(address);
    }
    this.computers = this.computers.filter((record: Companion): boolean => record.address !== address);
    this.queueRunSync(0);
    if (this.isPaired && this.base === address) {
      this.leaveComputer();
      this.forgetDrafts(address);
      return;
    }
    this.forgetDrafts(address);
    void this.persistComputers().catch(() => { this.status = '无法保存电脑列表的本次更改。'; });
  }

  private draftKey(id: string): string {
    return `${this.base}|${id}`;
  }

  private rememberDraft(id: string): void {
    this.chatState.rememberDraft(this.draftKey(id), this.draft);
  }

  private forgetDrafts(address: string): void {
    this.queuedSteering = this.queuedSteering.filter((item: QueuedSteering): boolean => !item.sessionKey.startsWith(`${address}|`));
    this.chatState.forgetDrafts(address);
  }

  private applySession(session: SessionState): void {
    if (session.id !== this.currentId) {
      this.flushStreamDeltas(false);
      this.closeToolDetails();
      this.resetVoice();
      if (this.currentId) this.rememberDraft(this.currentId);
      this.draft = this.chatState.drafts.get(this.draftKey(session.id)) ?? '';
      this.pendingSend = this.chatState.unconfirmed.get(this.draftKey(session.id));
      this.attachments = this.chatState.draftAttachments.get(this.draftKey(session.id)) ?? [];
      this.showSettings = false;
      this.models = [];
      this.currentId = session.id;
      this.messages = [];
      this.historyCursor = undefined;
      this.liveText = '';
      this.liveThinking = '';
      this.liveThinkSeq = 0;
      this.liveThinkingOpen = false;
      this.thinkingOpenIds = [];
      this.liveTools = [];
      this.liveSeq = 0;
      this.setInteraction();
      this.resetCommands();
      this.syncCommandPalette();
      this.pendingBottom = true;
      this.transcriptFollow = true;
    }
    this.noSession = '';
    if (this.workspaceCwd !== session.cwd) {
      this.resetFileTree();
      if (this.showFiles) { this.showFiles = false; this.activeTab = 'tasks'; }
    }
    this.workspaceCwd = session.cwd;
    this.currentAgent = session.agent ?? 'pi';
    this.currentPermission = session.permission ?? '';
    this.project = session.cwd.split('/').pop() ?? session.cwd;
    this.sessionName = session.name ?? '';
    this.updateCachedSessionTitle(session.id, session.name);
    this.modelLabel = session.model ? `${session.model.name} · ${session.thinkingLevel ?? 'off'}` : '';
    this.currentModel = session.model;
    this.currentLevel = session.thinkingLevel ?? 'off';
    this.idle = session.idle;
    this.runId = session.runId ?? '';
    this.queued = session.queued ?? false;
    this.acceptsImage = session.acceptsImage ?? false;
    this.syncLiveActivity();
  }

  private async poll(): Promise<void> {
    if (this.polling || this.openingSession) { this.schedule(350); return; }
    this.polling = true;
    const streamGen = this.streamGen;
    const epoch = this.epoch;
    const liveRevision = this.liveRevision;
    try {
      const result = await this.requestSessionSnapshot(epoch);
      if (epoch !== this.epoch) return;
      if (result.cursor && streamGen !== this.streamGen) return;
      const connected = !this.reachable;
      this.reachable = true;
      this.offlineDismissed = false;
      const libraryVisible = this.showSessions || this.dockedSessions();
      const catalogStale = Date.now() - this.sessionCatalogUpdatedAt >= 30000;
      const probingAgents = this.showNewSession && this.agents.some((agent: AgentInfo): boolean => agent.installed === undefined);
      if ((libraryVisible || this.showNewSession) && (connected || (!this.sessionCatalogFailed &&
        (!this.sessionCatalogLoaded || probingAgents || (catalogStale && (this.sessionView === 'all' || this.showNewSession))))) && !this.busy) {
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
      if (!result.session) {
        if (this.syncMode === 'sequenced') {
          this.chatState.sync.disconnect();
          this.historyStream = '';
          this.historyLeaf = undefined;
        }
        this.flushStreamDeltas(false);
        this.closeToolDetails();
        if (result.state === 'session_deleted' && result.deletedSessionId) {
          this.sessions = this.sessions.filter((row: SessionRow): boolean => row.id !== result.deletedSessionId);
          this.chatState.chatCache.delete(this.draftKey(result.deletedSessionId));
          if (this.currentId === result.deletedSessionId) {
            this.showSessions = !this.dockedSessions();
            void this.loadSessions();
          }
        }
        this.noSession = result.state === 'session_deleted' ? '会话已在电脑端删除。' :
          result.state === 'session_closed' ? '原会话已关闭，请在会话列表选择历史记录或其他会话。' :
          result.state === 'no_shared_sessions' ? '电脑已连接，请在任务列表选择一条对话。' : '请在任务列表选择一个会话。';
        if (this.currentId) {
          this.rememberDraft(this.currentId);
          this.resetCommands();
        }
        this.currentId = '';
        this.project = '';
        this.sessionName = '';
        this.draft = '';
        this.idle = true;
        this.runId = '';
        this.queued = false;
        this.acceptsImage = false;
        this.attachments = [];
        this.messages = [];
        this.liveText = '';
        this.liveThinking = '';
        this.liveThinkSeq = 0;
        this.liveThinkingOpen = false;
        this.thinkingOpenIds = [];
        this.liveTools = [];
        this.liveSeq = 0;
        this.setInteraction();
        this.pendingSend = undefined;
        return;
      }
      const moved = result.session.id !== this.currentId;
      if (result.cursor) {
        const applied = this.applySessionSnapshot(result);
        if (applied || this.chatState.sync.matches(result.cursor)) {
          this.setInteraction(result.interaction);
          if (connected && !moved) this.syncCommandPalette();
          if (this.historyStream === result.cursor.streamId && this.historyLeaf === result.historyLeaf) {
            this.reconcileSteering(this.idle && !this.queued);
          } else {
            void this.refreshSessionHistory(result);
          }
        }
        return;
      }
      const incoming = result.messages ?? [];
      const currentSnapshot = moved || liveRevision === this.liveRevision;
      if (currentSnapshot) {
        this.observeSessionRun(result.session);
        this.applySession(result.session);
      }
      if (connected && !moved) this.syncCommandPalette();
      if (moved || incoming[incoming.length - 1]?.id !== this.messages[this.messages.length - 1]?.id) {
        this.pendingBottom = true;
      }
      this.mergeTranscript(incoming, result.historyCursor);
      this.reconcileSteering(currentSnapshot && result.session.idle);
      if (currentSnapshot) this.applyLiveSnapshot(result, moved || !this.streamAlive);
      if (this.selectedTool?.state === 'run' || this.selectedTool?.state === 'unknown') {
        const selectedId = this.selectedTool.id;
        for (let index = incoming.length - 1; index >= 0; index--) {
          const message = incoming[index];
          if (this.selectedToolMessageId && this.selectedToolMessageId !== message.id) continue;
          const tool = message.tools?.find((item: LiveTool): boolean => item.id === selectedId);
          if (tool) {
            this.refreshSelectedTool(tool, message.id);
            break;
          }
        }
        const live = this.liveTools.find((item: LiveTool): boolean => item.id === selectedId);
        if (live) this.refreshSelectedTool(live);
      }
      this.setInteraction(result.interaction);
      this.reachable = true;
      if (result.promptError === 'unconfirmed') this.status = 'Pi 未确认这次发送。请在电脑上核对会话，应用不会自动重发。';
      else if (result.promptError === 'model_error') this.status = 'Pi 模型运行失败，请在电脑上查看当前会话或 Pi Go 日志。';
      this.cacheChat(result.session);
    } catch (error) {
      if (epoch !== this.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) {
        this.leaveComputer(true);
        return;
      }
      this.reachable = false;
      if (!this.currentId) this.noSession = '暂时无法加载会话，请检查电脑服务和网络，正在重试…';
      void this.tryPublicConnection();
    } finally {
      this.polling = false;
      if (epoch === this.epoch) {
        this.syncLiveActivity();
        const delay = !this.reachable ? 1500 :
          this.syncMode === 'sequenced' && this.chatState.sync.needsSnapshot() ? 150 :
          this.streamAlive ? (this.idle ? 3000 : 1200) :
          this.idle ? 1500 : 650;
        this.schedule(delay);
      }
    }
  }

  private async requestSessionSnapshot(epoch: number, includeHistory: boolean = false): Promise<BridgeReply> {
    if (this.syncMode === 'legacy') return await this.request('/chat');
    try {
      const result = await this.request(includeHistory ? '/session/snapshot?history=1' : '/session/snapshot');
      if (epoch === this.epoch && this.syncMode === 'probe') {
        this.syncMode = 'sequenced';
        this.startStream();
      }
      return result;
    } catch (error) {
      if (epoch !== this.epoch || !(error instanceof BridgeFailure) || error.status !== 404) throw error as Error;
      this.syncMode = 'legacy';
      this.stopStream();
      this.startStream();
      return await this.request('/chat');
    }
  }

  private applySessionSnapshot(snapshot: BridgeReply): boolean {
    const cursor = snapshot.cursor;
    const session = snapshot.session;
    if (!cursor || !session || cursor.sessionId !== session.id) return false;
    const applied = this.chatState.sync.snapshot(cursor, (): void => {
      this.observeSessionRun(session);
      this.applySession(session);
      this.runId = cursor.runId ?? '';
      this.flushStreamDeltas(false);
      this.liveSeq = 0;
      this.liveThinkSeq = 0;
      this.applyLiveSnapshot(snapshot, true);
      if (this.selectedTool?.state === 'run' || this.selectedTool?.state === 'unknown') {
        const selectedId = this.selectedTool.id;
        const live = this.liveTools.find((tool: LiveTool): boolean => tool.id === selectedId);
        if (live) this.refreshSelectedTool(live);
      }
      if (snapshot.promptError === 'unconfirmed') this.status = 'Pi 未确认这次发送。请在电脑上核对会话，应用不会自动重发。';
      else if (snapshot.promptError === 'model_error') this.status = 'Pi 模型运行失败，请在电脑上查看当前会话或 Pi Go 日志。';
    }, (frame: StreamFrame): void => this.applyStreamFrame(frame));
    if (applied) this.cacheChat(session);
    return applied;
  }

  private async refreshSessionHistory(snapshot: BridgeReply, initial: boolean = false): Promise<BridgeReply | undefined> {
    const epoch = this.epoch;
    const cursor = snapshot.cursor;
    const session = snapshot.session;
    if (!cursor || !session || (!initial && this.historyLoadingEpoch === epoch) ||
        (!initial && this.historyStream === cursor.streamId && this.historyLeaf === snapshot.historyLeaf)) return undefined;
    const revision = ++this.historyRequest;
    this.historyLoadingEpoch = epoch;
    try {
      const page = await this.request(`/history?id=${encodeURIComponent(session.id)}&sync=2`);
      if (epoch !== this.epoch || revision !== this.historyRequest ||
          page.session?.id !== session.id || page.session?.cwd !== session.cwd ||
          page.cursor?.streamId !== cursor.streamId) return undefined;
      if (initial) return page;
      if (this.currentId !== session.id || !this.chatState.sync.matches(cursor)) return undefined;
      this.applySessionHistory(page);
      return page;
    } catch (error) {
      if (initial) throw error as Error;
      if (epoch === this.epoch && error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      return undefined;
    } finally {
      if (revision === this.historyRequest) this.historyLoadingEpoch = undefined;
    }
  }

  private applySessionHistory(page: BridgeReply): void {
    const incoming = page.messages ?? [];
    if (incoming[incoming.length - 1]?.id !== this.messages[this.messages.length - 1]?.id) this.pendingBottom = true;
    this.mergeTranscript(incoming, page.historyCursor);
    this.historyStream = page.cursor?.streamId ?? '';
    this.historyLeaf = page.historyLeaf;
    this.reconcileSteering(this.idle && !this.queued);
    if (this.selectedTool?.state === 'run' || this.selectedTool?.state === 'unknown') {
      const selectedId = this.selectedTool.id;
      for (let index = incoming.length - 1; index >= 0; index--) {
        const message = incoming[index];
        if (this.selectedToolMessageId && this.selectedToolMessageId !== message.id) continue;
        const tool = message.tools?.find((item: LiveTool): boolean => item.id === selectedId);
        if (tool) {
          this.refreshSelectedTool(tool, message.id);
          break;
        }
      }
    }
    if (page.session) this.cacheChat(page.session);
  }

  private applyLiveSnapshot(snapshot: BridgeReply, replaceTools: boolean): void {
    const textSeq = snapshot.liveSeq ?? 0;
    if (this.idle || textSeq >= this.liveSeq) {
      this.chatState.clearDelta(false);
      const text = snapshot.liveText ?? '';
      if (text !== this.liveText) this.pendingBottom = true;
      this.liveText = text;
      this.liveSeq = textSeq;
    }
    const thinkingSeq = snapshot.liveThinkSeq ?? 0;
    if (this.idle || thinkingSeq >= this.liveThinkSeq) {
      this.chatState.clearDelta(true);
      const thinking = snapshot.liveThinking ?? '';
      if (thinking !== this.liveThinking) this.pendingBottom = true;
      this.liveThinking = thinking;
      this.liveThinkSeq = thinkingSeq;
    }
    if (this.idle) {
      if (this.liveTools.length) this.liveTools = [];
    } else if (replaceTools && (snapshot.tools?.length || this.liveTools.length)) {
      this.liveTools = snapshot.tools ?? [];
    }
  }

  private mergeTranscript(incoming: ChatMessage[], cursor?: string): void {
    const transcript = this.chatState.mergeTranscript(this.messages, this.historyCursor, incoming, cursor);
    if (this.messages !== transcript.messages) this.messages = transcript.messages;
    this.historyCursor = transcript.cursor;
  }

  private async loadHistory(): Promise<void> {
    if (this.busy || this.openingSession || !this.historyCursor || !this.currentId) return;
    const epoch = this.epoch;
    const id = this.currentId;
    const before = this.historyCursor;
    this.busy = true;
    try {
      const sync = this.syncMode === 'sequenced' ? '&sync=2' : '';
      const result = await this.request(`/history?id=${encodeURIComponent(id)}&before=${encodeURIComponent(before)}${sync}`);
      if (epoch !== this.epoch || this.currentId !== id || result.session?.id !== id || this.historyCursor !== before) return;
      if (this.syncMode === 'sequenced' && (!result.cursor || !this.chatState.sync.matches(result.cursor))) return;
      const known = new Set<string>(this.messages.map((message: ChatMessage): string => message.id));
      this.messages = (result.messages ?? []).filter((message: ChatMessage): boolean => !known.has(message.id)).concat(this.messages);
      this.historyCursor = result.historyCursor;
    } catch (error) {
      if (epoch !== this.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else this.status = '历史加载失败，会话可能已变化，请重新打开会话。';
    } finally { this.busy = false; }
  }

  private async loadSessionStatus(): Promise<void> {
    if (!this.reachable || this.sessionStatusLoading) return;
    const epoch = this.epoch;
    const selected = this.currentId;
    this.sessionStatusLoading = true;
    try {
      const result = await this.request('/sessions/status');
      if (epoch === this.epoch) this.applyRunningStatus(result, selected);
    } catch {
      if (epoch === this.epoch) this.applyRunningStatus(undefined);
    } finally { this.sessionStatusLoading = false; }
  }

  private applyRunningStatus(result?: BridgeReply, selected: string = this.currentId): void {
    const rows = (result?.runningSessions ?? []).filter((row: RunningRow): boolean => !!row?.id);
    this.runningSessions = rows;
    for (const row of rows) {
      if (row.id !== this.currentId) this.updateCachedSessionTitle(row.id, row.name);
    }
    const ids = rows.map((row: RunningRow): string => row.id).concat(result?.runningSessionIds ?? []);
    this.runningSessionIds = ids.filter((id: string, index: number): boolean => ids.indexOf(id) === index);
    if (result?.idleSessionIds) {
      for (const row of this.backgroundRunning()) {
        if (row.id !== selected && row.started !== false) this.observeRun(row.id, row.name || '后台任务', true);
      }
      const idle = new Set<string>(result.idleSessionIds);
      for (const id of this.observedRuns.keys()) {
        if (id === this.currentId || id === selected || this.runningSessionIds.includes(id)) continue;
        if (idle.has(id)) this.observeRun(id, '', false);
        else this.observedRuns.delete(id);
      }
    }
  }

  private observeSessionRun(session: SessionState): void {
    // A dispatched prompt can make the session busy before Pi starts a run.
    if (!session.idle && !session.runId && !session.queued) return;
    const title = session.name || this.sessions.find((row: SessionRow): boolean => row.id === session.id)?.name ||
      (session.id === this.currentId ? this.chatTitle() : '任务');
    this.observeRun(session.id, title, !session.idle || session.queued === true);
  }

  private observeRun(id: string, title: string, active: boolean, stopped: boolean = false): void {
    if (!id) return;
    if (active) {
      if (this.visible) this.observedRuns.set(id, title);
      return;
    }
    const previousTitle = this.observedRuns.get(id);
    if (!this.observedRuns.delete(id) || !this.visible) return;
    if (!stopped) {
      this.sakuraBurstKind = 'celebrate';
      this.sakuraBurstSeq += 1;
      if (this.themeId === 'sakura') this.sakuraCelebrateSeq += 1;
    }
    if (!this.runNoticesEnabled) return;
    this.pendingRunNotices.push({ title: title || previousTitle || '任务', stopped: stopped });
    if (!this.runNotice) this.advanceRunNotice();
  }

  private advanceRunNotice(): void {
    if (this.runNoticeTimer !== -1) clearTimeout(this.runNoticeTimer);
    this.runNoticeTimer = -1;
    this.runNotice = this.pendingRunNotices.shift();
    if (this.runNotice) this.runNoticeTimer = setTimeout(() => { this.advanceRunNotice(); }, 4500);
  }

  private clearRunNotices(): void {
    this.pendingRunNotices = [];
    this.advanceRunNotice();
  }

  private backgroundLiveActivity(): boolean {
    return this.liveViewsEnabled && this.isPaired && !!this.currentId &&
      this.liveViewSessionKey === this.draftKey(this.currentId) && (!this.idle || this.queued);
  }

  private syncLiveActivity(): void {
    if (this.liveViewSessionKey && (!this.isPaired || this.liveViewSessionKey !== this.draftKey(this.currentId) ||
      (this.idle && !this.queued) || (this.liveViewRunId && this.runId && this.liveViewRunId !== this.runId))) {
      this.liveViewSessionKey = '';
      this.liveViewRunId = '';
    }
    const active = this.backgroundLiveActivity();
    if (active) {
      if (this.runId) this.liveViewRunId = this.runId;
      const state = !this.reachable ? '重新连接中' : this.interaction ? '等待处理' : this.queued ? '排队中' : '运行中';
      liveActivity.sync({
        sessionId: this.currentId,
        address: this.base,
        state: state,
        foreground: this.visible
      });
    } else liveActivity.sync(undefined);
    if (!this.visible && !active) {
      this.cancelSchedule();
      this.stopStream();
    }
  }

  private backgroundActive(): boolean {
    return this.runningSessionIds.some((id: string): boolean => id !== this.currentId);
  }

  private backgroundRunning(): RunningRow[] {
    // Prefer named rows from new bridges; legacy bridges only send ids, so synthesize rows
    // and fall back to the cached catalog name for the pill label.
    const rows = this.runningSessions.filter((row: RunningRow): boolean => row.id !== this.currentId);
    const known = new Set<string>(rows.map((row: RunningRow): string => row.id));
    const extras: RunningRow[] = this.runningSessionIds
      .filter((id: string): boolean => id !== this.currentId && !known.has(id))
      .map((id: string): RunningRow => ({ id: id }));
    return rows.concat(extras).map((row: RunningRow): RunningRow => ({
      id: row.id,
      name: row.name || this.sessions.find((session: SessionRow): boolean => session.id === row.id)?.name,
      cwd: row.cwd,
      started: row.started
    }));
  }

  private sessionRunning(id: string): boolean {
    return this.reachable && (id === this.currentId ? !this.idle || this.queued : this.runningSessionIds.includes(id));
  }

  // Keep the current session first, followed by background sessions.
  private allRunningRows(): RunningRow[] {
    const current: RunningRow[] = [];
    if (this.currentId && this.sessionRunning(this.currentId)) {
      current.push({
        id: this.currentId,
        name: this.chatTitle(),
        cwd: this.workspaceCwd || undefined
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
    if (!this.reachable) return [];
    const sessions = this.allRunningRows();
    return this.scheduleActive.filter((row: RunMessage): boolean => isCurrentScheduleComputer(this.computers, this.base, row) &&
      !sessions.some((session: RunningRow): boolean => session.id === row.run.sessionId));
  }

  private runningTaskCount(): number {
    return this.reachable ? this.allRunningRows().length + this.standaloneScheduleRuns().length : 0;
  }

  // Fine-grained state for pills and badges: streaming / waiting / queued.
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
    if (this.busy || this.openingSession || this.sessionLoading || (more && this.sessionNextCursor === undefined)) return;
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
    if (this.showNewSession) {
      if (!this.newSessionFixedWorkspace && !this.projects.includes(this.newSessionCwd)) {
        this.newSessionCwd = this.projects.includes(this.workspaceCwd) ? this.workspaceCwd : this.projects[0] ?? '';
      }
      if (!this.newSessionAgent) this.newSessionAgent = this.defaultNewSessionAgent(this.newSessionPreferredAgent);
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
    if (!this.reachable || (previous?.loading && !refresh) || (more && previous?.nextCursor === undefined)) return;
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

  private closeFileEditor(): void {
    this.editingPath = '';
    this.editingRoot = '';
    this.fileText = '';
    this.fileOriginal = '';
    this.fileVersion = '';
    this.editorNotice = '';
  }

  private returnToFilePreview(discard: boolean = false): void {
    if (this.busy) return;
    if (!discard && this.fileText !== this.fileOriginal) {
      this.editorNotice = '请先保存或放弃文件修改。';
      return;
    }
    this.showTextPreview(this.editingRoot, this.editingPath, this.fileOriginal, this.fileVersion);
    this.closeFileEditor();
  }

  private fileBack(): void {
    if (this.busy || this.openingSession) return;
    this.showFiles = false;
    this.activeTab = 'tasks';
  }

  private resetFileTree(): void {
    this.fileRoot = '';
    this.fileDirectories.clear();
    this.fileTreeRows = [];
    this.fileTreeIndex = 0;
  }

  private appendFileTreeRows(rows: FileTreeRow[], path: string, depth: number): void {
    const directory = this.fileDirectories.get(path);
    if (!directory?.expanded) return;
    for (const entry of directory.entries) {
      const expanded = entry.kind === 'directory' && (this.fileDirectories.get(entry.path)?.expanded ?? false);
      rows.push({ path: entry.path, name: entry.name, kind: entry.kind, depth: depth, expanded: expanded });
      if (expanded) this.appendFileTreeRows(rows, entry.path, depth + 1);
    }
    if (!directory.entries.length) rows.push({ path: path, name: '空目录', kind: 'empty', depth: depth });
    if (directory.nextCursor !== undefined) {
      rows.push({ path: path, name: '加载更多', kind: 'more', depth: depth });
    }
  }

  private updateFileTree(): void {
    const rows: FileTreeRow[] = [];
    this.appendFileTreeRows(rows, '', 0);
    this.fileTreeRows = rows;
  }

  private async toggleFileDirectory(path: string): Promise<void> {
    if (this.busy || this.openingSession) return;
    const directory = this.fileDirectories.get(path);
    if (!directory) {
      await this.loadFileDirectory(path);
      return;
    }
    directory.expanded = !directory.expanded;
    this.updateFileTree();
  }

  private async loadFileDirectory(path: string, more: boolean = false): Promise<void> {
    if (this.busy || this.openingSession || !this.fileRoot) return;
    const directory = this.fileDirectories.get(path);
    if (more && directory?.nextCursor === undefined) return;
    const epoch = this.epoch;
    const root = this.fileRoot;
    this.busy = true;
    try {
      const result = await this.request('/files/list', { cwd: root, path: path, cursor: more ? directory?.nextCursor : 0 });
      if (epoch !== this.epoch || root !== this.fileRoot) return;
      const page = result.entries ?? [];
      const previous = more ? directory?.entries ?? [] : [];
      const loadedPaths = new Set(previous.map((entry: FileEntry): string => entry.path));
      const entries = previous.concat(page.filter((entry: FileEntry): boolean => !loadedPaths.has(entry.path)));
      if (!path && !more) this.fileDirectories.clear();
      this.fileDirectories.set(path, { entries: entries, nextCursor: result.nextCursor, expanded: true });
      this.updateFileTree();
      this.status = '';
    } catch (error) {
      if (epoch === this.epoch && root === this.fileRoot) this.fileFailure(error);
    } finally { this.busy = false; }
  }

  private fileFailure(error: Error, editing: boolean = false): void {
    if (error instanceof BridgeFailure && error.status === 401) { this.leaveComputer(true); return; }
    const notice = error.message === 'file_conflict' ? '电脑上的文件已变化，未覆盖。请复制手机修改后重新打开文件。' :
      error.message === 'file_too_large' ? '文本文件上限为 64 KiB，修改已保留。' :
      error.message === 'not_text_file' ? '此文件不是可编辑的 UTF-8 文本。' :
      error.message === 'file_not_found' ? '当前工作区找不到该文件。' :
      error.message === 'ambiguous_file_name' ? '工作区有多个同名文件，请使用完整的相对路径。' :
      error.message === 'file_lookup_limit' ? '工作区过大，无法按文件名查找。请使用完整的相对路径。' :
      error.message === 'path_forbidden' ? '此路径不可访问（不支持符号链接）。' :
      '文件操作未确认。请检查连接和项目授权；修改不会自动重发。';
    if (editing) this.editorNotice = notice;
    else if (this.textFilePreview) this.previewNotice = notice;
    else this.status = notice;
  }

  private showTextPreview(cwd: string, path: string, text: string, version?: string): void {
    this.dismissKeyboard();
    this.closeToolDetails();
    this.previewOffsets = [];
    this.previewNotice = '';
    this.status = '';
    const name = path.split('/').pop() ?? path;
    this.textFilePreview = { name: name, text: text, markdown: textPreviewFormat(name) === 'markdown',
      workspaceRoot: cwd, workspacePath: path, version: version };
  }

  private async openFile(cwd: string, path: string, lookupName: boolean = false): Promise<void> {
    if (this.busy || this.openingSession || this.openingFile || !cwd) return;
    if (!this.reachable) { this.status = '电脑离线，稍后再试。'; return; }
    const epoch = this.epoch;
    this.busy = true;
    try {
      const lookup = lookupName && !path.includes('/') ? 'name' : undefined;
      const result = await this.request('/files/read', { cwd: cwd, path: path, lookup: lookup });
      if (epoch !== this.epoch) return;
      if (result.text === undefined || !result.path || !result.version) throw new Error('invalid_file');
      this.showTextPreview(cwd, result.path, result.text, result.version);
    } catch (error) {
      if (epoch !== this.epoch) return;
      const message = (error as Error).message;
      if (message === 'not_text_file' || message === 'file_too_large' || message === 'not_found' ||
        (message === 'file_not_found' && lookupName && !path.includes('/'))) {
        await this.openWorkspaceFile(cwd, path, lookupName);
        return;
      }
      this.fileFailure(error);
    } finally { this.busy = false; }
  }

  private async openReferencedFile(cwd: string, path: string, lookupName: boolean): Promise<void> {
    if (this.busy || this.openingSession) return;
    const name = path.split('/').pop() ?? path;
    if (textPreviewFormat(name)) await this.openFile(cwd, path, lookupName);
    else await this.openWorkspaceFile(cwd, path, lookupName);
  }

  private editPreview(preview: ReceivedFilePreview): void {
    if (this.busy || this.savingPreview || this.editingPath || preview.text === undefined ||
      !preview.version || !preview.workspaceRoot || !preview.workspacePath) return;
    this.editingRoot = preview.workspaceRoot;
    this.editingPath = preview.workspacePath;
    this.fileText = preview.text;
    this.fileOriginal = preview.text;
    this.fileVersion = preview.version;
    this.editorNotice = '';
    this.textFilePreview = undefined;
  }

  private async saveFile(): Promise<void> {
    if (this.busy || this.openingSession || !this.reachable || !this.editingPath || this.fileText === this.fileOriginal) return;
    const epoch = this.epoch;
    const text = this.fileText;
    this.busy = true;
    this.editorNotice = '';
    try {
      const result = await this.request('/files/save', { cwd: this.editingRoot, path: this.editingPath, text: text, version: this.fileVersion });
      if (epoch !== this.epoch) return;
      if (!result.version) throw new Error('invalid_file');
      this.fileVersion = result.version;
      this.fileOriginal = text;
      this.editorNotice = '已保存到电脑。';
    } catch (error) { if (epoch === this.epoch) this.fileFailure(error, true); }
    finally { this.busy = false; }
  }

  // —— 电脑 → 手机：接收文件并点击打开 ——

  private downloadFailure(error: Error): void {
    if (error instanceof BridgeFailure && error.status === 401) { this.leaveComputer(true); return; }
    this.status = error.message === 'not_found' ? '当前 Pi Go 服务缺少文件下载接口。请更新电脑端 Pi Go 后重新连接。' :
      error.message === 'file_not_found' ? '当前工作区找不到该文件。请检查卡片里的路径。' :
      error.message === 'ambiguous_file_name' ? '工作区有多个同名文件，请使用完整的相对路径。' :
      error.message === 'file_lookup_limit' ? '工作区过大，无法按文件名查找。请使用完整的相对路径。' :
      error.message === 'not_file' ? '这是一个目录，不是文件。' :
      error.message === 'file_too_large' ? '文件超过 64 MiB，暂不能传到手机。' :
      error.message === 'desktop_workspace_unshared' ? '该工作区尚未共享给手机。' :
      error.message === 'path_forbidden' ? '此路径不可访问（不在共享工作区内）。' :
      error.message === 'invalid_path' ? '文件路径无效。' :
      error.message === 'no_context' ? '未能获取应用上下文。' :
      error.message === 'incomplete_download' ? '收到的文件字节数与预期不符，请重试。' :
      error.message === 'write_failed' ? '无法写入手机缓存，请检查可用存储空间。' :
      '接收文件未完成，请检查连接后重试。';
  }

  private localFilePrefix(cwd: string, path: string): string {
    const hash = cryptoFramework.createMd('SHA256');
    const key = JSON.stringify([this.base, this.connection.endpoint().token, cwd, path]);
    hash.updateSync({ data: new util.TextEncoder().encodeInto(key) });
    return Array.from(hash.digestSync().data, (byte: number): string => byte.toString(16).padStart(2, '0')).join('');
  }

  private async downloadFile(cwd: string, path: string, temporary: string, lookupName: boolean, limit: number = MAX_DOWNLOAD_BYTES): Promise<void> {
    return this.client.downloadFile(this.connection.endpoint(), cwd, path, temporary, lookupName, limit);
  }

  private pruneReceivedFiles(directory: string): void {
    try {
      const now = Math.floor(Date.now() / 1000);
      for (const name of fileIo.listFileSync(directory)) {
        try {
          const entry = `${directory}/${name}`;
          if (fileIo.statSync(entry).mtime < now - RECEIVED_FILE_TTL_S) fileIo.unlinkSync(entry);
        } catch {
          // 单个残留项清理失败不影响打开文件。
        }
      }
    } catch {
      // 目录不存在或占用时跳过清理。
    }
  }

  private readTextFilePreview(path: string, name: string, start: number = 0, cwd?: string, workspacePath?: string): ReceivedFilePreview | undefined {
    const format = textPreviewFormat(name);
    if (!format) return undefined;
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const size = fileIo.statSync(file.fd).size;
      const length = Math.min(size - start, MAX_TEXT_PREVIEW_BYTES + 1);
      if (length < 0) throw new Error('preview_read_failed');
      if (start) fileIo.lseek(file.fd, start);
      const bytes = new Uint8Array(length);
      let offset = 0;
      while (offset < length) {
        const chunk = new ArrayBuffer(Math.min(16384, length - offset));
        const count = fileIo.readSync(file.fd, chunk);
        if (!count) throw new Error('preview_read_failed');
        bytes.set(new Uint8Array(chunk, 0, count), offset);
        offset += count;
      }
      let end = Math.min(length, MAX_TEXT_PREVIEW_BYTES);
      if (length > end) {
        while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
        if (end === 0) return undefined;
        const newline = bytes.lastIndexOf(10, end - 1);
        if (newline >= end - 4096) end = newline + 1;
      }
      let text: string;
      try {
        text = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes.subarray(0, end));
      } catch { return undefined; }
      if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(text)) return undefined;
      return { name: name, text: text, markdown: format === 'markdown', localPath: path, offset: start,
        workspaceRoot: cwd, workspacePath: workspacePath,
        nextOffset: start + end < size ? start + end : undefined };
    } finally { fileIo.closeSync(file); }
  }

  private async openWorkspaceFile(cwd: string, path: string, lookupName: boolean = false): Promise<void> {
    if (this.openingFile) { this.status = '正在接收上一个文件…'; return; }
    if (!this.reachable) { this.status = '电脑离线，稍后再试。'; return; }
    const epoch = this.epoch;
    const name = path.split('/').pop() ?? path;
    this.openingFile = true;
    this.status = `正在接收 ${name}…`;
    let temporary = '';
    try {
      const host = this.getUIContext().getHostContext();
      if (!host) throw new Error('no_context');
      const context = host as common.UIAbilityContext;
      const directory = `${context.cacheDir}/${RECEIVED_FILE_DIR}`;
      if (!fileIo.accessSync(directory)) fileIo.mkdirSync(directory, true);
      this.pruneReceivedFiles(directory);
      const local = `${directory}/${this.localFilePrefix(cwd, path)}-${safeLocalFileName(name)}`;
      temporary = `${directory}/.download-${util.generateRandomUUID()}`;
      await this.downloadFile(cwd, path, temporary, lookupName);
      if (epoch !== this.epoch) return;
      fileIo.renameSync(temporary, local);
      temporary = '';
      this.dismissKeyboard();
      this.closeToolDetails();
      this.previewOffsets = [];
      this.previewNotice = '';
      this.status = '';
      this.textFilePreview = { name: name, localPath: local };
      try {
        const textPreview = this.readTextFilePreview(local, name, 0, cwd, path);
        if (textPreview) { this.textFilePreview = textPreview; return; }
        const uri = fileUri.getUriFromPath(local);
        if (isImageFile(name)) {
          this.textFilePreview = { name: name, localPath: local, imageUri: uri };
          return;
        }
        const previewable = await filePreview.canPreview(context, uri);
        if (epoch !== this.epoch || this.textFilePreview?.localPath !== local || !previewable) return;
        this.textFilePreview = { name: name, localPath: local, systemUri: uri };
        await filePreview.openPreview(context, { title: name, uri: uri, mimeType: '' });
      } catch {
        if (epoch === this.epoch && this.textFilePreview?.localPath === local) this.previewNotice = '无法打开预览，仍可保存文件。';
      }
    } catch (error) {
      if (epoch === this.epoch) this.downloadFailure(error as Error);
    } finally {
      if (temporary) {
        try { fileIo.unlinkSync(temporary); } catch {}
      }
      this.openingFile = false;
    }
  }

  private changePreviewPage(forward: boolean): void {
    const preview = this.textFilePreview;
    const offset = forward ? preview?.nextOffset : this.previewOffsets[this.previewOffsets.length - 1];
    if (!preview?.localPath || offset === undefined) return;
    try {
      const page = this.readTextFilePreview(preview.localPath, preview.name, offset, preview.workspaceRoot, preview.workspacePath);
      if (!page) throw new Error('preview_read_failed');
      if (forward) this.previewOffsets.push(preview.offset ?? 0);
      else this.previewOffsets.pop();
      this.previewNotice = '';
      this.textFilePreview = page;
      this.previewScroller.scrollEdge(Edge.Top);
    } catch { this.previewNotice = '无法读取这一页，仍可保存完整文件。'; }
  }

  private async savePreviewLocally(preview: ReceivedFilePreview): Promise<void> {
    if (this.savingPreview) return;
    this.savingPreview = true;
    this.previewNotice = '';
    const epoch = this.epoch;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [preview.name];
      const uris = await new picker.DocumentViewPicker(context).save(options);
      if (!uris.length || epoch !== this.epoch) return;
      const mode = preview.localPath ? fileIo.OpenMode.READ_WRITE : fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC;
      const destination = await fileIo.open(uris[0], mode);
      try {
        if (preview.localPath) {
          await fileIo.copyFile(preview.localPath, destination.fd);
        } else {
          const bytes = new util.TextEncoder().encodeInto(preview.text ?? '');
          let start = 0;
          while (start < bytes.length) {
            const count = await fileIo.write(destination.fd, bytes.slice(start).buffer);
            if (count <= 0) throw new Error('write_failed');
            start += count;
          }
        }
      } finally { await fileIo.close(destination); }
      if (epoch === this.epoch) this.previewNotice = '已保存到本机。';
    } catch {
      if (epoch === this.epoch) this.previewNotice = '保存未完成，请检查所选位置和可用空间。';
    } finally { this.savingPreview = false; }
  }

  private async imagePreviewError(preview: ReceivedFilePreview): Promise<void> {
    if (this.textFilePreview?.imageUri !== preview.imageUri) return;
    this.previewNotice = '图片无法解码';
    if (!preview.localPath || !preview.imageUri || preview.systemUri) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (await filePreview.canPreview(context, preview.imageUri) && this.textFilePreview?.imageUri === preview.imageUri) {
        this.textFilePreview = { name: preview.name, localPath: preview.localPath, imageUri: preview.imageUri,
          systemUri: preview.imageUri };
        this.previewNotice = '应用内无法显示这张图片，可尝试系统预览。';
      }
    } catch {}
  }

  private async reopenSystemPreview(preview: ReceivedFilePreview): Promise<void> {
    if (!preview.systemUri) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await filePreview.openPreview(context, { title: preview.name, uri: preview.systemUri, mimeType: '' });
    } catch { this.previewNotice = '无法打开系统预览，仍可保存文件。'; }
  }

  private cacheChatImage(cwd: string, key: string, extensions: string[], write: (path: string) => Promise<string>): Promise<string> {
    const epoch = this.epoch;
    const sessionId = this.currentId;
    const checkContext = (): void => {
      if (epoch !== this.epoch || sessionId !== this.currentId) throw new Error('session_changed');
    };
    const load = this.imageQueue.then(async (): Promise<string> => {
      checkContext();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const directory = `${context.cacheDir}/${RECEIVED_FILE_DIR}`;
      if (!fileIo.accessSync(directory)) fileIo.mkdirSync(directory, true);
      if (Date.now() - this.lastImageCachePrune >= 3600000) {
        this.pruneReceivedFiles(directory);
        this.lastImageCachePrune = Date.now();
      }
      const local = `${directory}/image-${this.localFilePrefix(cwd, key)}`;
      const cached = extensions.find((extension: string): boolean => fileIo.accessSync(local + extension));
      if (cached !== undefined) return local + cached;
      if (!this.reachable) throw new Error('disconnected');
      const temporary = `${directory}/.download-${util.generateRandomUUID()}`;
      try {
        const extension = await write(temporary);
        checkContext();
        fileIo.renameSync(temporary, local + extension);
        return local + extension;
      } finally {
        if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary);
      }
    });
    this.imageQueue = load.then((): void => {}, (): void => {});
    return load;
  }

  private loadHistoryImage(sessionId: string, messageId: string, index: number, toolId: string): Promise<string> {
    if (!sessionId || sessionId !== this.currentId) return Promise.reject(new Error('session_changed'));
    const identity = JSON.stringify([sessionId, messageId, index, toolId]);
    return this.cacheChatImage(this.workspaceCwd, identity, HISTORY_IMAGE_EXTENSIONS, async (local: string): Promise<string> => {
      const tool = toolId ? `&tool=${encodeURIComponent(toolId)}` : '';
      const reply = await this.request(`/message-image?id=${encodeURIComponent(sessionId)}&message=${encodeURIComponent(messageId)}&index=${index}${tool}`);
      if (!reply.image?.data) throw new Error('image_not_found');
      const extension = `.${reply.image.mimeType.slice('image/'.length)}`;
      if (!HISTORY_IMAGE_EXTENSIONS.includes(extension)) throw new Error('unsupported_image');
      const bytes = new util.Base64Helper().decodeSync(reply.image.data);
      if (bytes.length > MAX_INLINE_IMAGE_BYTES) throw new Error('image_too_large');
      const fd = fileIo.openSync(local, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      try {
        let offset = 0;
        while (offset < bytes.length) {
          const count = fileIo.writeSync(fd.fd, offset === 0 ? bytes.buffer : bytes.slice(offset).buffer);
          if (count <= 0) throw new Error('write_failed');
          offset += count;
        }
      } finally { fileIo.closeSync(fd); }
      return extension;
    });
  }

  private loadMarkdownImage(target: string, cwd: string, documentPath: string): Promise<string> {
    const path = markdownWorkspacePath(target, cwd, documentPath);
    if (!path) return Promise.reject(new Error('image_not_found'));
    const extension = path.match(/\.[a-z0-9]{1,10}$/i)?.[0] ?? '';
    return this.cacheChatImage(cwd, JSON.stringify([path, this.currentId]), [extension], async (local: string): Promise<string> => {
      await this.downloadFile(cwd, path, local, false, MAX_INLINE_IMAGE_BYTES);
      return extension;
    });
  }

  private showChatImage(source: string, label: string): void {
    this.dismissKeyboard();
    this.closeToolDetails();
    this.previewNotice = '';
    this.previewOffsets = [];
    const remote = /^https?:\/\//i.test(source);
    const extension = remote ? '' : source.match(/\.[a-z0-9]{1,10}$/i)?.[0] ?? '';
    const name = label.toLowerCase().endsWith(extension.toLowerCase()) ? label : label + extension;
    this.textFilePreview = { name: name, localPath: remote ? undefined : source,
      imageUri: remote ? source : fileUri.getUriFromPath(source) };
  }

  private async showFullReply(messageId: string): Promise<void> {
    if (this.loadingMessageText || !this.reachable || !this.currentId) return;
    const epoch = this.epoch;
    const id = this.currentId;
    const path = `/message-text?id=${encodeURIComponent(id)}&message=${encodeURIComponent(messageId)}`;
    this.loadingMessageText = messageId;
    try {
      const pages: string[] = [];
      let offset = 0;
      while (true) {
        const reply = await this.request(`${path}&offset=${offset}`);
        if (epoch !== this.epoch || id !== this.currentId) return;
        if (reply.text === undefined) throw new Error('invalid_message_text');
        pages.push(reply.text);
        if (reply.nextTextOffset === undefined) break;
        if (reply.nextTextOffset <= offset) throw new Error('invalid_message_text');
        offset = reply.nextTextOffset;
      }
      this.showTextPreview(this.workspaceCwd, '回复.md', pages.join(''));
    } catch {
      if (epoch === this.epoch && id === this.currentId) {
        this.getUIContext().getPromptAction().showToast({ message: '暂时无法加载完整回复，请重试' });
      }
    } finally {
      this.loadingMessageText = '';
    }
  }

  private async openMarkdownLink(target: string, cwd: string, documentPath: string): Promise<void> {
    if (/^https?:\/\/[^\s]+$/i.test(target)) {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await context.openLink(target);
      } catch {
        this.getUIContext().getPromptAction().showToast({ message: '无法打开链接' });
      }
      return;
    }
    const path = markdownWorkspacePath(target, cwd, documentPath);
    if (path) await this.openReferencedFile(cwd, path, !documentPath);
  }

  private openMarkdownTableReader(source: string, cwd: string, documentPath: string): void {
    if (this.markdownTableReader) return;
    this.dismissKeyboard();
    const revision = ++this.markdownRotationRevision;
    this.markdownRotationUnavailable = false;
    this.markdownTableReader = { source: source, cwd: cwd, documentPath: documentPath };
    this.markdownRotation = this.markdownRotation.then(async (): Promise<void> => {
      if (revision !== this.markdownRotationRevision) return;
      const context = this.getUIContext().getHostContext();
      if (!context) throw new Error('no_window_context');
      const mainWindow = await window.getLastWindow(context);
      if (revision !== this.markdownRotationRevision) return;
      this.markdownPreviousOrientation = mainWindow.getPreferredOrientation();
      this.markdownWindow = mainWindow;
      await mainWindow.setPreferredOrientation(window.Orientation.LANDSCAPE);
    }).catch((): void => {
      if (revision === this.markdownRotationRevision) this.markdownRotationUnavailable = true;
    });
  }

  private closeMarkdownTableReader(): void {
    this.markdownRotationRevision++;
    this.markdownTableReader = undefined;
    this.markdownRotation = this.markdownRotation.then(async (): Promise<void> => {
      const mainWindow = this.markdownWindow;
      const previous = this.markdownPreviousOrientation;
      this.markdownWindow = undefined;
      this.markdownPreviousOrientation = undefined;
      if (mainWindow && previous !== undefined) await mainWindow.setPreferredOrientation(previous);
    }).catch((): void => {});
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
      loadImage: (target: string): Promise<string> => this.loadMarkdownImage(target, cwd, documentPath),
      openImage: (source: string, label: string): void => { this.showChatImage(source, label); },
      openLink: (target: string): void => {
        if (!allowLandscape && markdownWorkspacePath(target, cwd, documentPath)) this.closeMarkdownTableReader();
        void this.openMarkdownLink(target, cwd, documentPath);
      },
      openLandscape: (source: string): void => { this.openMarkdownTableReader(source, cwd, documentPath); },
      copyCode: (value: string): void => { void this.copyText(value); }
    })
  }

  @Builder
  historyImages(count: number, sessionId: string, messageId: string, toolId: string = '') {
    ForEach(Array.from({ length: count }, (_: Object, index: number): number => index), (index: number) => {
      ChatImage({
        label: count === 1 ? '图片' : `图片 ${index + 1}`,
        load: (): Promise<string> => this.loadHistoryImage(sessionId, messageId, index, toolId),
        open: (source: string, label: string): void => { this.showChatImage(source, label); }
      })
    }, (index: number): string => `${sessionId}-${messageId}-${toolId}-${index}`)
  }

  private toolFile(tool: LiveTool): string {
    if (tool.state === 'run' || !['write', 'edit', 'read'].includes(tool.name)) return '';
    return normalizeWorkspacePath(this.workspaceCwd, this.selectedToolDetails?.path ?? tool.detail);
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
    if (!tool || !this.currentId) return;
    const revision = ++this.toolDetailRevision;
    this.toolDetailError = '';
    const message = this.selectedToolMessageId ? `&message=${encodeURIComponent(this.selectedToolMessageId)}` : '';
    try {
      const reply = await this.request(`/tool-detail?id=${encodeURIComponent(this.currentId)}&tool=${encodeURIComponent(tool.id)}${message}&images=1`);
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

  private stopReplySpeech(): void {
    if (!this.speakingReply) return;
    this.replySpeechAttempt += 1;
    this.speakingReply = '';
    this.replySpeech.stop();
  }

  private async toggleReplySpeech(message: ChatMessage): Promise<void> {
    const wasSpeaking = this.speakingReply === message.id;
    this.stopReplySpeech();
    if (wasSpeaking || !this.currentId) return;
    const prompt = this.getUIContext().getPromptAction();
    if (!replySpeechSupported()) {
      prompt.showToast({ message: '此设备不支持本地朗读' });
      return;
    }
    const attempt = ++this.replySpeechAttempt;
    this.speakingReply = message.id;
    const current = (): boolean => attempt === this.replySpeechAttempt;
    const finish = (notice: string): void => {
      if (!current()) return;
      this.speakingReply = '';
      if (notice) prompt.showToast({ message: notice });
    };
    try {
      const source = message.textTruncated
        ? await this.fetchFullMessageText(this.currentId, message.id, this.epoch, current) : message.text;
      if (!current()) return;
      if (source === undefined) { finish('暂时无法加载完整回复，请重试'); return; }
      const text = replySpeechText(source);
      if (!text) { finish('这条回复没有可朗读的文字'); return; }
      await this.replySpeech.play(text, (failed: boolean): void => { finish(failed ? '暂时无法朗读，请重试' : ''); });
    } catch {
      finish('暂时无法朗读，请重试');
    }
  }

  private async fetchFullMessageText(sessionId: string, messageId: string, epoch: number,
    current?: () => boolean): Promise<string | undefined> {
    const path = `/message-text?id=${encodeURIComponent(sessionId)}&message=${encodeURIComponent(messageId)}`;
    const pages: string[] = [];
    let offset = 0;
    for (let page = 0; page < 40; page++) {
      const reply = await this.request(`${path}&offset=${offset}`);
      if (epoch !== this.epoch || sessionId !== this.currentId || (current && !current())) return undefined;
      if (reply.text === undefined) return undefined;
      pages.push(reply.text);
      if (reply.nextTextOffset === undefined) break;
      if (reply.nextTextOffset <= offset) return undefined;
      offset = reply.nextTextOffset;
    }
    return pages.join('');
  }

  private async collectCurrentSessionMessages(sessionId: string, epoch: number): Promise<ChatMessage[]> {
    let collected: ChatMessage[] = this.messages.slice();
    let cursor: string | undefined = this.historyCursor;
    const seenCursors = new Set<string>();
    if (this.reachable && cursor) {
      const sync = this.syncMode === 'sequenced' ? '&sync=2' : '';
      for (let page = 0; page < 50 && cursor; page++) {
        if (seenCursors.has(cursor)) break;
        seenCursors.add(cursor);
        try {
          const result: BridgeReply = await this.request(`/history?id=${encodeURIComponent(sessionId)}&before=${encodeURIComponent(cursor)}${sync}`);
          if (epoch !== this.epoch || this.currentId !== sessionId || result.session?.id !== sessionId) break;
          const known = new Set<string>(collected.map((item: ChatMessage): string => item.id));
          const older: ChatMessage[] = (result.messages ?? []).filter((item: ChatMessage): boolean => !known.has(item.id));
          collected = older.concat(collected);
          cursor = result.historyCursor;
        } catch {
          break;
        }
      }
    }
    if (!this.reachable) return collected;
    const expanded: ChatMessage[] = [];
    for (const message of collected) {
      if (epoch !== this.epoch || this.currentId !== sessionId) break;
      if (message.textTruncated) {
        try {
          const full = await this.fetchFullMessageText(sessionId, message.id, epoch);
          if (full !== undefined) {
            expanded.push({
              id: message.id,
              role: message.role,
              text: full,
              textTruncated: false,
              imageCount: message.imageCount,
              thinking: message.thinking,
              thinkingMs: message.thinkingMs,
              tools: message.tools
            });
            continue;
          }
        } catch {}
      }
      expanded.push(message);
    }
    return expanded;
  }

  private async shareCurrentSession(anchor: string = 'session-settings'): Promise<void> {
    if (this.sharingSession || this.openingSession) return;
    if (!this.currentId) {
      this.getUIContext().getPromptAction().showToast({ message: '请先打开一个会话' });
      return;
    }
    this.dismissKeyboard();
    const epoch = this.epoch;
    const id = this.currentId;
    this.sharingSession = true;
    try {
      const fullMessages = await this.collectCurrentSessionMessages(id, epoch);
      if (epoch !== this.epoch || id !== this.currentId) return;
      const meta: SessionShareMeta = {
        title: this.chatTitle(),
        workspace: this.project,
        computer: this.computerTitle()
      };
      const markdown = formatSessionMarkdown(fullMessages, meta, { liveText: this.liveText });
      if (!markdown) {
        this.getUIContext().getPromptAction().showToast({ message: '当前会话暂无可分享的内容' });
        return;
      }
      const host = this.getUIContext().getHostContext();
      if (!host) throw new Error('no_context');
      await shareSessionViaSystem(
        host as common.UIAbilityContext,
        markdown,
        meta,
        fullMessages.length,
        'markdown',
        anchor
      );
    } catch {
      if (epoch === this.epoch) {
        this.getUIContext().getPromptAction().showToast({ message: '暂时无法调起系统分享，请重试' });
      }
    } finally {
      this.sharingSession = false;
    }
  }

  private async shareSidebarSession(session: SessionRow): Promise<void> {
    if (this.sharingSession || this.openingSession) return;
    if (session.id === this.currentId) {
      this.setDrawer(false);
      await this.shareCurrentSession('session-settings');
      return;
    }
    if (!this.reachable) {
      this.getUIContext().getPromptAction().showToast({ message: '请先连接电脑再分享该会话' });
      return;
    }
    this.activeTab = 'tasks';
    this.showSettings = false;
    this.showFiles = false;
    const opened = await this.requestAction('/open', { id: session.id });
    if (opened && this.currentId === session.id) {
      await this.shareCurrentSession('session-settings');
    }
  }

  private chatHeaderMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    if (this.currentId && !this.noSession && this.activeTab === 'tasks') {
      items.push({
        value: '分享会话',
        action: () => { void this.shareCurrentSession('session-settings'); }
      });
    }
    items.push(
      { value: '模型与会话设置', action: () => {
        if (this.reachable && this.currentId) void this.requestAction('/models');
      } },
      { value: '切换电脑', action: () => { if (!this.busy) this.openComputers(); } }
    );
    return items;
  }

  private async updateSessionMeta(session: SessionRow, pin: boolean): Promise<void> {
    const payload: Payload = { id: session.id, cwd: session.cwd, revision: session.revision ?? 0 };
    if (pin) payload.pinned = !session.pinned;
    else payload.archived = !session.archived;
    if (await this.requestAction('/session-meta', payload)) {
      if (this.sessionView === 'all' && session.cwd) await this.loadWorkspacePage(session.cwd);
      else await this.loadSessions();
    }
  }

  private defaultNewSessionAgent(preferred: string = 'pi'): string {
    return this.agents.find((agent: AgentInfo): boolean => agent.id === preferred && agent.installed === true)?.id ??
      this.agents.find((agent: AgentInfo): boolean => agent.id === 'pi' && agent.installed === true)?.id ??
      this.agents.find((agent: AgentInfo): boolean => agent.installed === true)?.id ?? '';
  }

  private openNewSession(path: string = '', preferred: string = 'pi'): void {
    if (this.busy || this.openingSession || (path && !this.projects.includes(path))) return;
    this.dismissKeyboard();
    this.newSessionFixedWorkspace = !!path;
    this.newSessionCwd = path || (this.projects.includes(this.workspaceCwd) ? this.workspaceCwd : this.projects[0] ?? '');
    this.newSessionPreferredAgent = preferred;
    this.newSessionAgent = this.defaultNewSessionAgent(preferred);
    this.newSessionError = '';
    this.showNewSession = true;
    if (this.reachable && (!this.sessionCatalogLoaded || this.sessionCatalogFailed ||
      this.agents.some((agent: AgentInfo): boolean => agent.installed === undefined) ||
      Date.now() - this.sessionCatalogUpdatedAt >= 30000)) {
      void this.loadSessions();
    }
  }

  private closeNewSession(): void {
    if (this.openingSession) return;
    this.showNewSession = false;
  }

  private canCreateSession(): boolean {
    return this.reachable && this.hostAvailable && !this.busy && !this.openingSession &&
      this.projects.includes(this.newSessionCwd) &&
      this.agents.some((agent: AgentInfo): boolean => agent.id === this.newSessionAgent && agent.installed === true);
  }

  private async createSession(): Promise<void> {
    if (!this.showNewSession || !this.canCreateSession()) return;
    const connection = this.catalogConnection;
    const payload: Payload = { cwd: this.newSessionCwd, agent: this.newSessionAgent };
    this.newSessionError = '';
    this.activeTab = 'tasks';
    const created = await this.requestAction('/new', payload);
    if (connection !== this.catalogConnection || !this.showNewSession) return;
    if (created) this.closeNewSession();
    else this.newSessionError = this.status || '暂时无法创建会话。';
  }

  private workspaceName(path: string): string {
    return workspaceName(this.workspaces, path);
  }

  private openNewSpace(): void {
    if (!this.reachable || this.busy || this.openingSession || !this.canCreateWorkspace) return;
    this.newSpaceName = '';
    this.newSpaceError = '';
    this.showNewSpace = true;
  }

  private closeNewSpace(): void {
    if (this.busy) return;
    this.dismissKeyboard();
    this.showNewSpace = false;
  }

  private async createWorkspaceTask(): Promise<void> {
    if (!this.showNewSpace || !this.reachable || !this.canCreateWorkspace || this.busy || this.openingSession) return;
    const rawName = this.newSpaceName;
    const name = rawName.trim();
    if (!name || name.length > 80 || name === '.' || name === '..' || /[\x00-\x1f\x7f/\\]/.test(rawName)) {
      this.newSpaceError = '请输入 1–80 个字符，名称不能是「.」「..」或包含路径分隔符和控制字符。';
      return;
    }
    const epoch = this.epoch;
    this.newSpaceError = '';
    this.busy = true;
    let cwd = '';
    let refresh = false;
    try {
      const result = await this.request('/create-workspace', { name: name });
      if (epoch !== this.epoch) return;
      if (!result.cwd) throw new Error('workspace_not_confirmed');
      cwd = result.cwd;
    } catch (error) {
      if (epoch !== this.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) {
        this.leaveComputer(true);
        return;
      }
      const code = error instanceof BridgeFailure ? error.message : '';
      if (code === 'workspace_exists') this.newSpaceError = '已有同名文件夹，请换一个名称。';
      else if (code === 'desktop_busy') this.newSpaceError = '电脑端正在处理其他操作，请稍后再试。';
      else if (code === 'desktop_workspace_creation_unsupported' || code === 'not_found') this.newSpaceError = '请更新电脑端 Pi Go 后再创建空间。';
      else if (code === 'computer_access_required') this.newSpaceError = '此连接需要启用整机访问才能创建空间。';
      else if (code === 'desktop_create_workspace_failed') this.newSpaceError = '电脑端创建空间失败，请检查默认目录。';
      else {
        refresh = true;
        this.newSpaceError = '电脑端未确认结果，请先查看空间列表。';
      }
    } finally {
      this.busy = false;
    }
    if (refresh) {
      this.sessionCatalogLoaded = false;
      this.sessionCatalogVersion += 1;
      void this.loadSessions();
      return;
    }
    if (!cwd) return;
    this.closeNewSpace();
    if (!this.projects.includes(cwd)) {
      this.projects = this.projects.concat([cwd]).sort();
      this.workspaces = this.workspaces.concat([{ cwd: cwd, name: name }]);
    }
    this.sessionCatalogLoaded = false;
    this.sessionCatalogVersion += 1;
    this.activeTab = 'tasks';
    this.openNewSession(cwd);
  }

  private confirmCloseSpace(path: string, epoch: number): void {
    if (epoch !== this.epoch || !this.projects.includes(path)) return;
    const name = this.workspaceName(path);
    const prompt = this.getUIContext().getPromptAction();
    if (!this.isPaired || !this.reachable) { prompt.showToast({ message: '请先连接电脑再移除空间。' }); return; }
    if (this.busy || this.openingSession) { prompt.showToast({ message: '请等待当前操作结束后再移除空间。' }); return; }
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
          if (epoch === this.epoch && this.projects.includes(path)) void this.closeWorkspace(path);
        }
      }
    });
  }

  private async closeWorkspace(path: string): Promise<void> {
    const epoch = this.epoch;
    if (!(await this.requestAction('/close-workspace', { cwd: path }))) {
      if (epoch === this.epoch && this.status) this.getUIContext().getPromptAction().showToast({ message: this.status });
      return;
    }
    const name = this.workspaceName(path);
    // 移除成功后立刻更新本地列表。
    this.projects = this.projects.filter((item: string): boolean => item !== path);
    this.expandedSpaces = this.expandedSpaces.filter((item: string): boolean => item !== path);
    this.workspacePages = this.workspacePages.filter((page: WorkspacePage): boolean => page.path !== path);
    this.workspaces = this.workspaces?.filter((row: WorkspaceRow): boolean => row.cwd !== path) ?? [];
    this.getUIContext().getPromptAction().showToast({ message: `已移除空间「${name}」` });
    if (this.workspaceCwd === path) {
      // 当前会话所在的电脑端工作区已关闭，回到任务列表等桥接状态刷新。
      this.showSessions = !this.dockedSessions();
      this.schedule(0);
    } else void this.loadSessions();
  }

  private async requestAction(path: string, input?: Payload): Promise<boolean> {
    if (this.busy || this.openingSession) return false;
    const navigation = path === '/open' || path === '/new' || path === '/fork';
    const previous = navigation ? this.chatState.chatCache.get(this.draftKey(this.currentId)) : undefined;
    if (previous?.session) this.cacheChat(previous.session);
    const cached = path === '/open' && input?.id ? this.chatState.chatCache.get(this.draftKey(input.id)) : undefined;
    let navigationConfirmed = false;
    let refreshSpace = '';
    const epoch = navigation ? ++this.epoch : this.epoch;
    const liveRevision = this.liveRevision;
    if (navigation) {
      this.resetVoice();
      this.openingSession = true;
      this.openingSessionId = path === '/open' ? input?.id ?? '' : '';
      this.pendingSessionReveal = '';
      this.cancelSchedule();
      if (this.syncMode === 'sequenced') {
        this.stopStream();
        this.historyStream = '';
        this.historyLeaf = undefined;
      }
      if (cached) this.presentChat(cached, true);
    } else this.busy = true;
    this.status = '';
    try {
      let payload: Payload | undefined = input;
      if (path === '/open' && this.syncMode !== 'legacy') {
        payload = { id: input?.id, history: true };
        if (input?.agent) payload.agent = input.agent;
      }
      const result = await this.request(path, payload);
      if (epoch !== this.epoch) return false;
      if (path === '/new') {
        if (!result.session) throw new BridgeFailure(409, 'desktop_handoff_unconfirmed');
        if ((result.session.agent ?? 'pi') !== (input?.agent ?? 'pi')) throw new BridgeFailure(409, 'desktop_agent_mismatch');
      }
      if (path === '/new' || path === '/fork' || path === '/rename' || path === '/session-meta' || path === '/close-workspace') {
        this.sessionCatalogLoaded = false;
        this.sessionCatalogVersion += 1;
      }
      if (path === '/new' || path === '/fork' || path === '/rename') refreshSpace = result.session?.cwd ?? '';
      if (path === '/models' && result.session?.id === this.currentId) {
        this.models = result.models ?? [];
        this.selectedModel = this.models.findIndex((model: ModelOption): boolean =>
          model.provider === result.current?.provider && model.id === result.current?.id);
        if (this.selectedModel < 0 && this.models.length) this.selectedModel = 0;
        const levels = this.models[this.selectedModel]?.levels ?? [];
        const currentLevel = result.current?.thinkingLevel ?? 'off';
        this.selectedLevel = levels.includes(currentLevel) ? currentLevel : levels[0] ?? 'off';
        this.renameDraft = this.sessionName;
        this.showSettings = true;
      }
      if ((path === '/rename' || path === '/model') && result.session?.id === this.currentId) {
        this.applySession(result.session);
        this.status = path === '/rename' ? '会话名称已更新。' : `已切换到 ${this.modelLabel}`;
        this.showSettings = false;
      }
      if (navigation && result.session) {
        if (path === '/open' && result.session.id !== input?.id) throw new Error('session_changed');
        navigationConfirmed = true;
        // A cached transcript is already visible; refresh it after confirming the remote selection.
        const liveRevision = this.liveRevision;
        let chat = result;
        if (!chat.cursor || chat.messages === undefined) {
          chat = await this.requestSessionSnapshot(epoch, true);
        } else if (this.syncMode === 'probe') {
          this.syncMode = 'sequenced';
        }
        if (epoch !== this.epoch) return false;
        if (chat.session?.id !== result.session.id || chat.session.cwd !== result.session.cwd) throw new Error('session_changed');
        if (path === '/new' && (chat.session.agent ?? 'pi') !== (result.session.agent ?? 'pi')) {
          throw new BridgeFailure(409, 'desktop_agent_mismatch');
        }
        if (chat.cursor) {
          const page = chat.messages !== undefined ? chat : await this.refreshSessionHistory(chat, true);
          if (epoch !== this.epoch) return false;
          if (!page) throw new Error('session_changed');
          if (!this.applySessionSnapshot(chat)) throw new Error('session_changed');
          this.setInteraction(chat.interaction);
          this.applySessionHistory(page);
          this.revealChat(!cached);
        } else {
          if (liveRevision === this.liveRevision) this.observeSessionRun(chat.session);
          this.presentChat(chat, !cached, liveRevision === this.liveRevision);
          this.reconcileSteering(liveRevision === this.liveRevision && chat.session.idle);
          this.cacheChat(chat.session);
        }
      }
      if (path === '/regenerate') {
        if (result.dispatched === true && input?.id === this.currentId) this.trackDispatchedLiveRun(liveRevision);
        this.transcriptFollow = true;
        this.pendingBottom = true;
        this.schedule(0);
      }
      return true;
    } catch (error) {
      if (epoch !== this.epoch) return false;
      if (cached && !navigationConfirmed && !(error instanceof BridgeFailure && error.status === 401)) {
        this.pendingSessionReveal = '';
        if (previous) this.presentChat(previous, false);
        this.showSessions = !this.dockedSessions();
      }
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_required' && path === '/close-workspace') this.status = '电脑端 Pi Go 宿主未运行，暂时无法关闭工作区。';
      else if (error instanceof BridgeFailure && error.message === 'not_found' && path === '/close-workspace') this.status = '当前电脑端 Pi Go 宿主不支持远程关闭工作区，请更新电脑端。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_required') this.status = '电脑端 Pi Go 宿主未运行。启动宿主后重试，或在电脑上打开并共享该会话。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_agent_unavailable') this.status = '所选 Agent 在电脑端不可用，请检查安装后刷新。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_agent_mismatch') this.status = '电脑端返回的会话与所选 Agent 不一致，请刷新会话列表。';
      else if (path === '/new' && error instanceof BridgeFailure &&
        (error.message === 'desktop_session_not_ready' || error.message === 'desktop_handoff_failed')) {
        this.status = '所选 Agent 启动失败，请在电脑上检查登录和配置。';
      }
      else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_unshared') this.status = '该工作区尚未共享给手机。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_not_registered') this.status = '该工作区未在电脑端 Pi Go 的工作区列表中登记。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_close_failed') this.status = '电脑端关闭工作区失败，请稍后重试。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_untrusted') this.status = '该工作区未在电脑端 Pi Go 中登记或授权。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_unconfirmed' && path === '/close-workspace') this.status = '电脑端尚未确认，请刷新列表查看工作区是否已移除。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_unconfirmed') this.status = '电脑端尚未确认操作，请刷新会话列表查看结果。';
      else if (error instanceof BridgeFailure && error.message === 'session_occupied') this.status = '同一会话由多个 Pi 进程打开。请在电脑上关闭重复会话后重试。';
      else if (error instanceof BridgeFailure && error.message === 'interaction_unavailable') {
        this.setInteraction();
        this.status = '此请求已处理或已失效。';
        this.schedule(0);
      }
      else if (error instanceof BridgeFailure && error.message === 'metadata_conflict') this.status = '会话标记已变化，请重新搜索后再操作。';
      else if (error instanceof BridgeFailure && error.message === 'model_not_found') this.status = '模型已不可用，请重新打开设置。';
      else if (error instanceof BridgeFailure && error.message === 'session_busy') {
        this.status = path === '/model' ? '等待当前任务和队列结束后，再应用模型设置。' : '请等待当前任务和队列结束。';
      }
      else if (error instanceof BridgeFailure && error.message === 'reply_not_latest') this.status = '只有最近一轮回复可以重新生成。';
      else if (error instanceof BridgeFailure && error.message === 'image_not_supported') this.status = '当前模型不支持原消息中的图片。';
      else if (error instanceof BridgeFailure && error.message === 'not_found' && (path === '/fork' || path === '/regenerate')) {
        this.status = '请更新电脑端 Pi Go 后重试。';
      }
      else if (error instanceof BridgeFailure && error.message === 'model_not_applied') this.status = 'Pi 未应用所选模型，请在电脑上检查模型的登录状态或 API 配置。';
      else if (error instanceof BridgeFailure && error.message === 'invalid_name') this.status = '名称须为 1–200 字且不含换行。';
      else if (error instanceof BridgeFailure && error.status === 409) this.status = 'Pi 正在处理任务或会话已变化，请刷新后再试。';
      else this.status = '电脑端尚未确认操作，请刷新查看结果。';
      if (((path === '/open' && this.showSessions) || path === '/fork' || path === '/regenerate') && this.status) {
        this.getUIContext().getPromptAction().showToast({ message: this.status });
      }
      return false;
    } finally {
      if (navigation) {
        this.openingSession = false;
        this.openingSessionId = '';
        if (epoch === this.epoch) {
          this.syncCommandPalette();
          if (this.syncMode === 'sequenced') this.startStream();
          this.schedule(this.reachable && !this.idle ? 650 : 1500);
        }
      } else this.busy = false;
      if (epoch === this.epoch && refreshSpace && this.expandedSpaces.includes(refreshSpace)) {
        void this.loadWorkspacePage(refreshSpace);
      }
    }
  }

  private setInteraction(request?: PendingInteraction): void {
    if (request?.id === this.interaction?.id) return;
    this.interactionDraft = request?.prefill ?? '';
    this.interaction = request;
    this.syncLiveActivity();
  }

  private async answerInteraction(pendingId: string, answer: boolean | string): Promise<void> {
    if (pendingId !== this.interaction?.id || !this.currentId) return;
    if (await this.requestAction('/answer', { id: this.currentId, pendingId: pendingId, answer: answer })) {
      this.epoch += 1;
      if (this.interaction?.id === pendingId) this.setInteraction();
      this.schedule(0);
    }
  }

  private toggleThinking(id: string, open: boolean): void {
    if (open && !this.thinkingOpenIds.includes(id)) this.thinkingOpenIds = this.thinkingOpenIds.concat([id]);
    else if (!open) this.thinkingOpenIds = this.thinkingOpenIds.filter((item: string): boolean => item !== id);
  }

  @Builder
  fileChip(path: string, lookupName: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.doc')).fontSize(14).fontColor([this.accent()])
        Text(path.split('/').pop() ?? path).fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.pigo_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 196 })
        if (this.openingFile) {
          LoadingProgress().width(12).height(12).color($r('app.color.pigo_muted'))
        }
      }
    }.id(`file-chip-${path}`).backgroundColor($r('app.color.pigo_panel'))
      .border({ width: 1, radius: 10, color: $r('app.color.pigo_line') })
      .padding({ left: 10, right: 10, top: 7, bottom: 7 }).enabled(!this.openingFile)
      .onClick(() => { void this.openReferencedFile(this.workspaceCwd, path, lookupName); })
  }

  @Builder
  copyButton(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(17).fontColor([$r('app.color.pigo_muted')])
    }.width(36).height(36).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
      .accessibilityText(label).onClick(() => { void this.copyText(value); })
  }

  @Builder
  toolDetailBlock(label: string, value: string) {
    Column({ space: 4 }) {
      Row() {
        Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.accent()).layoutWeight(1)
        if (value) this.copyButton(`复制${label}`, value)
      }.width('100%')
      if (value) {
        Text(value).width('100%').fontFamily('monospace').fontSize(14).lineHeight(22).fontColor($r('app.color.pigo_text'))
          .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
      .padding({ left: 12, right: 8, top: 4, bottom: 12 })
      .backgroundColor($r('app.color.launch_background')).borderRadius(12).border({ width: 1, color: $r('app.color.pigo_line') })
  }

  @Builder
  toolDetailsSheet() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.selectedTool) {
          Row({ space: 10 }) {
            SymbolGlyph(this.toolIcon(this.selectedTool)).fontSize(20).fontColor([this.accent()])
            Text(toolActionTitle(this.selectedTool.name)).fontSize(21).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          }.width('100%').padding({ right: 40 })
          if (this.toolFile(this.selectedTool)) this.fileChip(this.toolFile(this.selectedTool), false)
          if (this.selectedToolDetails) {
            if (this.selectedToolDetails.input) {
              this.toolDetailBlock(this.selectedToolDetails.command ? '命令' : '输入', this.selectedToolDetails.input)
            }
            if (this.selectedToolDetails.output) {
              this.toolDetailBlock(this.selectedToolDetails.state === 'fail' ? '错误输出' : '输出', this.selectedToolDetails.output)
            } else if (!this.selectedToolDetails.imageCount) {
              Text(this.selectedTool.state === 'run' && !this.idle ? '正在运行…' : '没有文本输出')
                .fontSize(14).fontColor($r('app.color.pigo_muted'))
            }
            if (this.selectedToolDetails.imageCount) {
              this.historyImages(this.selectedToolDetails.imageCount, this.currentId, this.selectedToolMessageId, this.selectedTool.id)
            }
            if (this.selectedToolDetails.truncated) {
              Text('较长的输入或输出仅显示前 64K 字符').fontSize(12).fontColor($r('app.color.pigo_muted'))
            }
          } else if (this.selectedTool.detail) {
            this.toolDetailBlock('摘要', this.selectedTool.detail)
          }
          if (this.toolDetailError) {
            Text(this.toolDetailError).fontSize(14).fontColor($r('app.color.pigo_muted'))
            Button('重试').chatAction().onClick(() => { void this.loadToolDetails(); })
          } else if (!this.selectedToolDetails) {
            LoadingProgress().width(22).height(22).color($r('app.color.pigo_muted')).accessibilityText('正在加载工具详情')
          }
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 18, right: 18, top: 22, bottom: 24 })
    }.width('100%').height('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder
  pendingCard(request: PendingInteraction) {
    Scroll() {
      Column({ space: 8 }) {
        Text(request.title || 'Pi 等待应答').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.pigo_warning')).width('100%')
        if (request.message) Text(request.message).fontSize(14).fontColor($r('app.color.pigo_text')).width('100%')
        if (request.method === 'confirm') {
          Row({ space: 10 }) {
            Button('拒绝').chatAction().id('interaction-deny').enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => { void this.answerInteraction(request.id, false); })
            Button('确认').chatAction().id('interaction-confirm').enabled(this.reachable && !this.busy && !this.openingSession)
              .backgroundColor(this.accent()).fontColor(this.accentForeground())
              .onClick(() => { void this.answerInteraction(request.id, true); })
          }.width('100%')
        } else if (request.method === 'input' || request.method === 'editor') {
          if (request.method === 'editor') {
            TextArea({ text: this.interactionDraft, placeholder: '编辑内容' }).id('interaction-editor').height(92).maxLength(1024)
              .backgroundColor($r('app.color.pigo_panel')).fontColor($r('app.color.pigo_text')).placeholderColor($r('app.color.pigo_muted'))
              .onChange((value: string) => { if (request.id === this.interaction?.id) this.interactionDraft = value; })
          } else {
            TextInput({ text: this.interactionDraft, placeholder: request.placeholder ?? '输入答复' }).id('interaction-input').maxLength(1024)
              .backgroundColor($r('app.color.pigo_panel')).fontColor($r('app.color.pigo_text')).placeholderColor($r('app.color.pigo_muted'))
              .onChange((value: string) => { if (request.id === this.interaction?.id) this.interactionDraft = value; })
          }
          Row({ space: 10 }) {
            Button('取消').chatAction().id('interaction-cancel').enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => { void this.answerInteraction(request.id, false); })
            Button('提交').chatAction().id('interaction-submit').enabled(this.reachable && !this.busy && !this.openingSession)
              .backgroundColor(this.accent()).fontColor(this.accentForeground())
              .onClick(() => { void this.answerInteraction(request.id, this.interactionDraft); })
          }.width('100%')
        } else {
          ForEach(request.options ?? [], (option: string, index: number) => {
            Button(option).chatAction().id(`interaction-option-${index}`).width('100%').enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => { void this.answerInteraction(request.id, option); })
          }, (option: string, index: number) => `${index}-${option}`)
          Button('取消').chatAction().id('interaction-cancel').enabled(this.reachable && !this.busy && !this.openingSession)
            .onClick(() => { void this.answerInteraction(request.id, false); })
        }
      }.padding(12).width('100%').backgroundColor($r('app.color.pigo_warning_panel')).borderRadius(14)
    }.constraintSize({ maxHeight: 240 }).width('100%').scrollBar(BarState.Off)
  }

  private commandPaletteActive(): boolean {
    if (this.voiceMode || !this.draft) return false;
    const text = this.draft.trimStart();
    return text.startsWith('/') && !/\s/.test(text);
  }

  private commandMatches(): CommandRow[] {
    const text = this.draft.trimStart();
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
    if (!this.reachable || !this.currentId || this.openingSession) return;
    await this.commandState.load(this.currentId, (): Promise<BridgeReply> => this.request('/commands'), (list: CommandList): void => {
      this.commandError = list.error;
      if (list.rows) this.commandRows = list.rows;
      this.commandsLoading = list.loading;
    });
  }

  private pickCommand(row: CommandRow, prompt: string = ''): void {
    this.draft = commandDraft(row, prompt);
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
    this.draft = skillDraft(row, this.draft);
    this.commandPalette = false;
    this.voiceMode = false;
    this.showComposerMenu = false;
  }

  private commandSourceLabel(source: string): string {
    if (source === 'skill') return '技能';
    if (source === 'prompt') return '模板';
    if (source === 'extension') return '扩展';
    return source;
  }

  private async send(): Promise<void> {
    const text = this.draft.trim();
    const id = this.currentId;
    const mode = this.idle ? 'send' : 'steer';
    const runId = this.idle ? undefined : this.runId;
    const attachments = this.attachments ?? [];
    if (!id || (!text && !attachments.length) || this.busy || this.openingSession || !this.reachable || this.pendingSend) return;
    if (attachments.some((item: DraftAttachment): boolean => item.kind === 'image') && !this.acceptsImage) {
      this.status = '此模型不支持图片，请先移除图片附件或换模型。';
      return;
    }
    if (text.startsWith('/') && attachments.length) {
      this.status = '命令发送不支持附件，请先移除附件。';
      return;
    }
    if (mode === 'steer' && !runId) return;
    if (this.chatState.unconfirmed.size >= 128) { this.status = '请先核对未确认的发送。'; return; }
    const epoch = this.epoch;
    const key = this.draftKey(id);
    const pending: PendingSend = { requestId: util.generateRandomUUID(), text: text, attachments: attachments,
      steeringAfter: mode === 'steer' && !text.startsWith('/') ? (this.messages[this.messages.length - 1]?.id ?? '') : undefined };
    this.chatState.unconfirmed.set(key, pending);
    this.pendingSend = pending;
    this.busy = true;
    this.status = '';
    this.sakuraBurstKind = 'send';
    this.sakuraBurstSeq += 1;
    try {
      const refs: AttachmentRef[] = [];
      for (let index = 0; index < pending.attachments.length; index += 1) {
        const item = pending.attachments[index];
        this.status = `正在上传附件（${index + 1}/${pending.attachments.length}）…`;
        const bytes = item.kind === 'image' && item.image
          ? new util.Base64Helper().decodeSync(item.image.jpeg)
          : item.file ? item.file.bytes : new Uint8Array(0);
        const uploaded = await this.uploadAttachment(item.kind, item.name, bytes);
        if (epoch !== this.epoch) return;
        refs.push({ token: uploaded.token, kind: item.kind });
      }
      if (refs.length) this.status = '附件已上传，正在发送…';
      const liveRevision = this.liveRevision;
      const result = await this.request('/prompt', { id: id, text: text, requestId: pending.requestId, mode: mode,
        runId: runId, attachments: refs.length ? refs : undefined });
      if (epoch !== this.epoch) return;
      if (result.dispatched !== true) throw new Error('dispatch_unconfirmed');
      this.finishSend(key, pending);
      if (mode === 'send') {
        if (result.handled !== true) this.trackDispatchedLiveRun(liveRevision);
      } else this.status = '引导请求已交给 Pi。';
    } catch (error) {
      if (epoch !== this.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else if (error instanceof BridgeFailure && ['session_busy', 'session_not_streaming', 'session_changed',
        'session_occupied', 'invalid_prompt', 'invalid_request_id', 'probe_request_limit', 'invalid_image', 'image_not_supported', 'payload_too_large',
        'invalid_attachment', 'unknown_attachment', 'invalid_content_type', 'not_found',
        'unknown_command', 'command_attachments'].includes(error.message)) {
        this.chatState.unconfirmed.delete(key);
        this.pendingSend = undefined;
        if (error.message === 'session_occupied') {
          this.status = '该会话正被电脑 Codex 桌面端占用，可一键创建分支接力。';
          this.promptForkAndContinue(id, text, attachments);
        } else {
          this.status = error.message === 'image_not_supported' ? '此模型不支持图片；草稿已保留。' :
            ['invalid_image', 'payload_too_large'].includes(error.message) ? '发送内容过大（单文件 8MB 内）或图片格式无效；草稿已保留。' :
              ['invalid_attachment', 'unknown_attachment', 'invalid_content_type'].includes(error.message) ? '附件无效或已过期；草稿已保留。' :
                error.message === 'not_found' ? '电脑端扩展版本过旧，不支持附件上传；草稿已保留。' :
                  error.message === 'unknown_command' ? '电脑未找到该命令；输入 / 可查看可用命令，草稿已保留。' :
                    error.message === 'command_attachments' ? '命令发送不支持附件；草稿已保留。' :
                      '电脑未接收此次发送。请检查会话是否仍在运行；草稿已保留。';
        }
      } else this.status = '发送结果未知。草稿已保留，不会自动重发。';
    } finally {
      this.busy = false;
      this.schedule(0);
    }
  }

  private promptForkAndContinue(sessionId: string, text: string, attachments: DraftAttachment[]): void {
    const ui = this.getUIContext();
    if (!ui.showAlertDialog) return;
    let lastAssistantId: string | undefined = undefined;
    for (let index = this.messages.length - 1; index >= 0; index -= 1) {
      if (this.messages[index].role === 'assistant') {
        lastAssistantId = this.messages[index].id;
        break;
      }
    }
    const epoch = this.epoch;
    ui.showAlertDialog({
      title: '会话正被电脑 Codex 占用',
      message: '电脑上的 Codex 桌面端正停在该会话上（持有独占写入锁）。是否一键创建分支会话并立即发送这条消息？',
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      primaryButton: {
        value: '稍后',
        fontColor: $r('app.color.pigo_muted'),
        action: () => {}
      },
      secondaryButton: {
        value: '一键分支接力',
        fontColor: this.accent(),
        action: () => {
          if (epoch !== this.epoch || this.currentId !== sessionId) return;
          void this.forkAndContinue(sessionId, lastAssistantId, text, attachments);
        }
      }
    });
  }

  private async forkAndContinue(sessionId: string, messageId: string | undefined,
    text: string, attachments: DraftAttachment[]): Promise<void> {
    const forked = await this.requestAction('/fork', {
      id: sessionId,
      messageId: messageId,
      history: this.syncMode !== 'legacy'
    });
    if (!forked || !this.currentId || this.currentId === sessionId) return;
    const oldKey = this.draftKey(sessionId);
    this.chatState.drafts.delete(oldKey);
    this.chatState.draftAttachments.delete(oldKey);
    this.draft = text;
    this.attachments = attachments;
    await this.send();
  }

  private trackDispatchedLiveRun(revision: number): void {
    if (this.liveRevision === revision && this.idle) this.idle = false;
    if (!this.visible || !this.liveViewsEnabled || (this.idle && !this.queued)) return;
    this.liveViewSessionKey = this.draftKey(this.currentId);
    this.liveViewRunId = this.runId;
    this.syncLiveActivity();
  }

  private async uploadAttachment(kind: string, name: string, bytes: Uint8Array): Promise<UploadedAttachment> {
    return this.client.uploadAttachment(this.connection.endpoint(), kind, name, bytes);
  }

  private finishSend(key: string, pending: PendingSend): void {
    this.chatState.unconfirmed.delete(key);
    this.chatState.draftAttachments.delete(key);
    for (const item of pending.attachments) {
      if (item.image) item.image.preview.release().catch((): void => {});
    }
    if (key !== this.draftKey(this.currentId)) return;
    if (pending.steeringAfter !== undefined) {
      const message: QueuedSteering = { id: pending.requestId, sessionKey: key, afterId: pending.steeringAfter, text: pending.text,
        imageCount: pending.attachments.filter((item: DraftAttachment): boolean => item.kind === 'image').length,
        files: pending.attachments.filter((item: DraftAttachment): boolean => item.kind === 'file')
          .map((item: DraftAttachment): string => item.name) };
      this.liveRevision += 1;
      this.queuedSteering = this.queuedSteering.concat([message]).slice(-128);
      this.reconcileSteering(this.idle);
    }
    this.pendingSend = undefined;
    // 自己刚发出的消息必须立刻滚到可见位置，即使之前在翻历史。
    this.transcriptFollow = true;
    this.pendingBottom = true;
    if (this.draft.trim() === pending.text) this.draft = '';
    this.attachments = [];
    this.syncCommandPalette();
  }

  private reconcileSteering(settled: boolean): void {
    const remaining = this.chatState.reconcileSteering(this.queuedSteering, this.messages, this.draftKey(this.currentId),
      settled, this.pendingSend);
    if (remaining !== this.queuedSteering) this.queuedSteering = remaining;
  }

  private onIncomingShare(): void {
    this.shareError = '';
    this.shareTargetPicker = '';
    if (this.showIncomingShare() && this.drawerOpen()) this.setDrawer(false);
  }

  private showIncomingShare(): boolean {
    if (!this.incomingShare.text && !this.incomingShare.attachments.length && !this.incomingShare.skipped) return false;
    if (this.shareTargetPicker === 'session' && this.drawerOpen()) return false;
    if (this.shareTargetPicker === 'computer' && this.activeTab === 'mine' && this.minePage === 'computers') return false;
    return true;
  }

  private shareTargetLocked(): boolean {
    return !!this.editingPath || this.savingPreview || this.schedulePage === 'editor' ||
      this.scheduleSaving || this.showNewSession || this.showNewSpace || this.addingComputer;
  }

  private prepareShareTarget(): boolean {
    if (this.shareTargetLocked()) return false;
    this.schedulePage = '';
    this.reviewedRun = undefined;
    this.textFilePreview = undefined;
    if (this.markdownTableReader) this.closeMarkdownTableReader();
    return true;
  }

  private canAddShareToCurrent(): boolean {
    return this.isPaired && !!this.currentId && this.activeTab === 'tasks' && !this.showFiles && !this.showSettings &&
      !this.schedulePage && !this.reviewedRun && !this.markdownTableReader && !this.textFilePreview &&
      !this.shareTargetLocked() && !this.drawerOpen();
  }

  private clearIncomingShare(): void {
    releaseIncomingShare(this.incomingShare);
    this.incomingShare = { text: '', attachments: [], skipped: false };
  }

  private chooseShareSession(): void {
    if (!this.prepareShareTarget()) return;
    this.shareTargetPicker = 'session';
    this.activeTab = 'tasks';
    this.showSettings = false;
    this.showFiles = false;
    if (!this.dockedSessions()) this.setDrawer(true);
    else void this.loadSessions();
  }

  private addShareToDraft(): void {
    const incoming = this.incomingShare;
    if (!this.canAddShareToCurrent() || this.busy || this.openingSession || this.pendingSend) return;
    const list = this.attachments.concat(incoming.attachments);
    const images = list.filter((item: DraftAttachment): boolean => item.kind === 'image').length;
    const addedImages = incoming.attachments.filter((item: DraftAttachment): boolean => item.kind === 'image').length;
    const addedFiles = incoming.attachments.length - addedImages;
    const stored = this.storedDraftAttachments();
    if (addedImages && !this.acceptsImage) {
      this.shareError = '当前模型不支持图片，请换会话或切换模型。';
      return;
    }
    if (images > MAX_IMAGE_ATTACHMENTS || list.length - images > MAX_FILES ||
        stored[0] + addedImages > MAX_TOTAL_IMAGE_DRAFTS || stored[1] + addedFiles > MAX_TOTAL_FILE_DRAFTS) {
      this.shareError = '附件草稿已满，请移除部分附件或换个会话。';
      return;
    }
    const sharedText = incoming.text.startsWith('/') && !this.draft.trim() ? '> ' + incoming.text : incoming.text;
    const draft = [this.draft, sharedText].filter((part: string): boolean => !!part).join('\n\n');
    if (sharedDraftSize(draft) > MAX_SHARED_DRAFT_BYTES) {
      this.shareError = '合并后超过消息长度上限，请缩短现有草稿或换个会话。';
      return;
    }
    const key = this.draftKey(this.currentId);
    this.draft = draft;
    this.rememberDraft(this.currentId);
    this.commitDraftAttachments(key, list);
    this.incomingShare = { text: '', attachments: [], skipped: false };
    this.getUIContext().getPromptAction().showToast({ message: '已加入当前会话草稿' });
  }

  @Builder
  private incomingShareBanner() {
    Column({ space: 6 }) {
      Row() {
        Text(this.incomingShare.text || this.incomingShare.attachments.length ? '分享至 Pi Go' : '无法读取分享内容')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).layoutWeight(1)
        Button('关闭').chatAction().height(32).onClick((): void => { this.clearIncomingShare(); })
      }.width('100%')
      if (this.incomingShare.text) {
        Text(this.incomingShare.text).fontSize(13).fontColor($r('app.color.pigo_text')).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      if (this.incomingShare.attachments.length) {
        Text(`${this.incomingShare.attachments.length} 个附件`).fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
      }
      if (this.shareError || (this.incomingShare.skipped && (this.incomingShare.text || this.incomingShare.attachments.length))) {
        Text(this.shareError || '部分内容无法读取或超出限制。')
          .fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
      }
      if (this.incomingShare.text || this.incomingShare.attachments.length) {
        if (!this.isPaired) {
          Text('配对电脑并打开会话后，可加入草稿。')
            .fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
        } else if (this.canAddShareToCurrent()) {
          Text(`当前会话 · ${this.sessionName || this.project || '未命名会话'}`)
            .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
      }
      if ((this.incomingShare.text || this.incomingShare.attachments.length) && this.isPaired) {
        Row({ space: 8 }) {
          Button('选电脑').chatAction().height(36).enabled(!this.shareTargetLocked()).onClick((): void => {
            if (!this.prepareShareTarget()) return;
            this.shareTargetPicker = 'computer';
            this.openComputers();
          })
          Button('选会话').chatAction().height(36).enabled(!this.shareTargetLocked())
            .onClick((): void => { this.chooseShareSession(); })
          if (this.canAddShareToCurrent()) {
            Button('加入当前草稿').chatAction().height(36).backgroundColor(this.accent()).fontColor(this.accentForeground())
              .enabled(!this.busy && !this.openingSession && !this.pendingSend)
              .onClick((): void => { this.addShareToDraft(); })
          }
        }.width('100%')
      }
    }.id('incoming-share').width('93%').constraintSize({ maxWidth: 420 }).padding(14).borderRadius(18)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
  }

  private storedDraftAttachments(): number[] {
    let images = 0;
    let files = 0;
    for (const list of this.chatState.draftAttachments.values()) {
      for (const item of list) {
        if (item.kind === 'image') images += 1;
        else files += 1;
      }
    }
    return [images, files];
  }

  private commitDraftAttachments(key: string, list: DraftAttachment[]): void {
    if (list.length) this.chatState.draftAttachments.set(key, list);
    else this.chatState.draftAttachments.delete(key);
    this.attachments = list;
  }

  private removeAttachment(index: number): void {
    const key = this.draftKey(this.currentId);
    const list = this.attachments.slice();
    const removed = list.splice(index, 1)[0];
    if (removed && removed.image) removed.image.preview.release().catch((): void => {});
    this.commitDraftAttachments(key, list);
  }

  private async attachImage(source: string): Promise<void> {
    if (this.busy || this.openingSession || !this.currentId || this.pendingSend) return;
    if (!this.acceptsImage) { this.status = '当前模型不支持图片输入，可改发文件。'; return; }
    const key = this.draftKey(this.currentId);
    const slots = MAX_IMAGE_ATTACHMENTS - this.attachments.filter((item: DraftAttachment): boolean => item.kind === 'image').length;
    if (slots <= 0) { this.status = `一条消息最多 ${MAX_IMAGE_ATTACHMENTS} 张图片。`; return; }
    const stored = this.storedDraftAttachments();
    if (stored[0] >= MAX_TOTAL_IMAGE_DRAFTS || stored[1] >= MAX_TOTAL_FILE_DRAFTS) {
      this.status = '附件草稿过多，请先发送或移除部分附件。';
      return;
    }
    const epoch = this.epoch;
    this.busy = true;
    this.status = '';
    try {
      let picked: PromptImage[] = [];
      if (source === 'camera') {
        const context = this.getUIContext().getHostContext();
        const image = context ? await capturePromptImage(context) : undefined;
        if (image) picked = [image];
      } else picked = await choosePromptImage(slots);
      if (picked.length && epoch === this.epoch && key === this.draftKey(this.currentId)) {
        const addition: DraftAttachment[] = [];
        for (const image of picked) {
          if (addition.length < slots) {
            addition.push({ kind: 'image', name: 'photo.jpg', size: image.jpeg.length, image: image });
          } else image.preview.release().catch((): void => {});
        }
        this.commitDraftAttachments(key, this.attachments.concat(addition));
      } else {
        for (const image of picked) image.preview.release().catch((): void => {});
      }
    } catch {
      if (epoch === this.epoch) this.status = '未能读取或缩小图片，可尝试更小的图片。';
    } finally { this.busy = false; }
  }

  private async attachFile(): Promise<void> {
    if (this.busy || this.openingSession || !this.currentId || this.pendingSend) return;
    const key = this.draftKey(this.currentId);
    const slots = MAX_FILES - this.attachments.filter((item: DraftAttachment): boolean => item.kind === 'file').length;
    if (slots <= 0) { this.status = `一条消息最多 ${MAX_FILES} 个文件（单个 8MB 内）。`; return; }
    const stored = this.storedDraftAttachments();
    if (stored[0] >= MAX_TOTAL_IMAGE_DRAFTS || stored[1] >= MAX_TOTAL_FILE_DRAFTS) {
      this.status = '附件草稿过多，请先发送或移除部分附件。';
      return;
    }
    const epoch = this.epoch;
    this.busy = true;
    this.status = '';
    try {
      const picked = await choosePromptFiles(slots);
      if (picked.length && epoch === this.epoch && key === this.draftKey(this.currentId)) {
        const addition: DraftAttachment[] = [];
        for (const file of picked) {
          if (addition.length < slots) addition.push({ kind: 'file', name: file.name, size: file.size, file: file });
        }
        this.commitDraftAttachments(key, this.attachments.concat(addition));
      }
    } catch {
      if (epoch === this.epoch) this.status = '未能读取所选文件；单个文件不超过 8MB。';
    } finally { this.busy = false; }
  }

  private stopRecordClock(): void {
    if (this.recordTimer !== -1) {
      clearInterval(this.recordTimer);
      this.recordTimer = -1;
    }
  }

  private showVoiceHint(message: string): void {
    if (this.voiceHintTimer !== -1) clearTimeout(this.voiceHintTimer);
    this.voiceHint = message;
    this.voiceHintTimer = setTimeout(() => {
      this.voiceHint = '';
      this.voiceHintTimer = -1;
    }, 2200);
  }

  private resetVoice(): void {
    this.voiceAttempt += 1;
    this.holdActive = false;
    this.holdTouchId = -1;
    this.recording = false;
    this.voicePreparing = false;
    this.voiceFinishing = false;
    this.voiceCancelling = false;
    this.holdCancel = false;
    this.liveVoiceText = '';
    this.voiceHint = '';
    if (this.voiceHintTimer !== -1) clearTimeout(this.voiceHintTimer);
    this.voiceHintTimer = -1;
    this.stopRecordClock();
    const session = this.voiceSession;
    this.voiceSession = undefined;
    if (session) void session.cancel();
  }

  private holdTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (this.holdActive || this.voicePreparing || this.voiceFinishing || this.recording ||
        this.busy || this.openingSession || !this.reachable || this.pendingSend) return;
      const touch = event.changedTouches[0];
      if (!touch) return;
      this.holdActive = true;
      this.holdTouchId = touch.id;
      this.holdStartY = touch.windowY;
      this.holdCancel = false;
      void this.beginRecording();
      return;
    }
    if (!this.holdActive) return;
    if (event.type === TouchType.Cancel) {
      this.holdActive = false;
      void this.endRecording(true);
      return;
    }
    const touch = event.changedTouches.find((item: TouchObject): boolean => item.id === this.holdTouchId);
    if (!touch) return;
    if (event.type === TouchType.Up) {
      this.holdActive = false;
      void this.endRecording(false);
    } else if (event.type === TouchType.Move) {
      const rise = this.holdStartY - touch.windowY;
      if (rise > 80) this.holdCancel = true;
      else if (rise < 40) this.holdCancel = false;
    }
  }

  private async beginRecording(): Promise<void> {
    if (!this.currentId) return;
    if (!voiceInputSupported()) { this.showVoiceHint('此设备不支持本地语音识别'); return; }
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    this.stopReplySpeech();
    const attempt = ++this.voiceAttempt;
    const epoch = this.epoch;
    const id = this.currentId;
    this.voicePreparing = true;
    this.voiceHint = '';
    const allowed = await ensureMicrophone(context);
    if (attempt !== this.voiceAttempt || epoch !== this.epoch || id !== this.currentId) return;
    if (!allowed || !this.holdActive) {
      this.voicePreparing = false;
      if (!allowed) this.showVoiceHint('请在系统设置中允许麦克风权限');
      return;
    }
    const session = new VoiceInputSession();
    this.voiceSession = session;
    this.liveVoiceText = '';
    this.recordSeconds = 0;
    try {
      await session.begin((partial: string): void => {
        if (this.voiceSession === session) this.liveVoiceText = partial;
      });
      if (attempt !== this.voiceAttempt || this.voiceSession !== session) return;
      this.voicePreparing = false;
      this.recording = true;
      this.holdStart = Date.now();
      this.recordTimer = setInterval(() => {
        if (this.voiceSession !== session) return;
        this.recordSeconds = Math.floor((Date.now() - this.holdStart) / 1000);
        if (Date.now() - this.holdStart >= MAX_VOICE_MS) {
          this.holdActive = false;
          void this.endRecording(false);
        }
      }, 200);
    } catch {
      if (attempt === this.voiceAttempt) {
        this.resetVoice();
        this.showVoiceHint('无法启动语音识别，请重试');
      }
    }
  }

  private async endRecording(cancelled: boolean): Promise<void> {
    if (this.voiceFinishing) return;
    const session = this.voiceSession;
    const attempt = ++this.voiceAttempt;
    const epoch = this.epoch;
    const id = this.currentId;
    const cancel = cancelled || this.holdCancel;
    const tooShort = !this.recording || Date.now() - this.holdStart < MIN_HOLD_MS;
    this.recording = false;
    this.voicePreparing = false;
    this.holdCancel = false;
    this.stopRecordClock();
    if (!session) {
      this.voiceAttempt += 1;
      if (!cancel) this.showVoiceHint('说话时间太短');
      return;
    }
    this.voiceFinishing = true;
    this.voiceCancelling = cancel || tooShort;
    if (tooShort && !cancel) this.showVoiceHint('说话时间太短');
    try {
      if (cancel || tooShort) {
        await session.cancel();
        if (attempt === this.voiceAttempt && !cancel) this.showVoiceHint('说话时间太短');
        return;
      }
      const text = await session.finish();
      if (attempt !== this.voiceAttempt || epoch !== this.epoch || id !== this.currentId || !this.visible) return;
      if (!text.trim()) {
        this.showVoiceHint(session.lastError === 'microphone_permission' ? '请在系统设置中允许麦克风权限' :
          session.lastError ? '语音识别失败，请重试' : '没有听清，请再说一次');
        return;
      }
      this.draft = this.draft.trim() ? `${this.draft.trim()}\n${text.trim()}` : text.trim();
      this.syncCommandPalette();
      if (session.hasFinalTranscript && this.idle && this.reachable && !this.busy && !this.openingSession &&
        !this.pendingSend) {
        await this.send();
        if (attempt === this.voiceAttempt && this.draft.trim()) this.voiceMode = false;
      } else {
        this.voiceMode = false;
        this.showVoiceHint(session.hasFinalTranscript ? '已转为文字，可编辑后发送' : '识别未完成，请检查文字后发送');
      }
    } catch {
      if (attempt === this.voiceAttempt) this.showVoiceHint('语音识别失败，请重试');
    } finally {
      if (attempt === this.voiceAttempt) {
        this.voiceSession = undefined;
        this.voiceFinishing = false;
        this.voiceCancelling = false;
        this.liveVoiceText = '';
      }
    }
  }

  private async checkSend(): Promise<void> {
    const pending = this.pendingSend;
    const id = this.currentId;
    if (!pending || !id || this.busy || this.openingSession || !this.reachable) return;
    const epoch = this.epoch;
    const key = this.draftKey(id);
    this.busy = true;
    try {
      const result = await this.request('/receipt', { id: id, requestId: pending.requestId });
      if (epoch !== this.epoch) return;
      if (result.dispatched) {
        this.finishSend(key, pending);
        this.status = '电脑已记录此次发送。';
      } else this.status = '未找到发送记录。请先在电脑上核对会话，再决定是否重发。';
    } catch (error) {
      if (epoch !== this.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else this.status = '仍无法核对发送；草稿已保留。';
    } finally { this.busy = false; }
  }

  private async openModelMenu(): Promise<void> {
    if (!this.reachable || !this.currentId || this.busy || this.openingSession) return;
    if (!this.idle || this.queued) { this.status = '等待当前任务和队列结束后可切换模型。'; return; }
    const epoch = this.epoch;
    this.busy = true;
    this.status = '';
    this.dismissKeyboard();
    try {
      const result = await this.request('/models');
      if (epoch !== this.epoch || result.session?.id !== this.currentId) return;
      this.models = result.models ?? [];
      if (!this.models.length) { this.status = '没有可用模型，请在电脑上检查 Pi CLI 的模型配置。'; return; }
      this.showModelMenu = true;
    } catch (error) {
      if (epoch !== this.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else if (error instanceof BridgeFailure && error.message === 'session_busy') this.status = '等待当前任务和队列结束后可切换模型。';
      else if (error instanceof BridgeFailure && error.message === 'model_not_found') this.status = '模型已不可用，请重新打开。';
      else this.status = '模型列表加载失败，请重试。';
    } finally { this.busy = false; }
  }

  private async applyModelFromMenu(index: number): Promise<void> {
    const model = this.models[index];
    if (!model) return;
    const level = model.levels.includes(this.currentLevel) ? this.currentLevel : model.levels[0] ?? 'off';
    await this.requestAction('/model', { id: this.currentId, provider: model.provider,
      modelId: model.id, thinkingLevel: level });
  }

  private async applyThinkingLevelFromMenu(level: string): Promise<void> {
    const model = this.currentModel ?? this.models.find((item: ModelOption): boolean => this.isCurrentModel(item));
    if (!model || level === this.currentLevel) return;
    await this.requestAction('/model', { id: this.currentId, provider: model.provider,
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
    return this.currentModel?.provider === model.provider && this.currentModel?.id === model.id;
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
    this.transcriptFollow = gap <= 120;
    if (this.transcriptFollow) this.transcript.scrollEdge(Edge.Bottom);
  }

  private onKeyboardChange(): void {
    if (this.keyboardHeight <= 0 || this.activeTab !== 'tasks' || this.showFiles || this.showSettings ||
      this.showSessions || this.editingPath || this.textFilePreview) return;
    this.armTranscriptFollow();
  }

  private restoreSettings(): void {
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    try {
      const settings = openSettings(context);
      this.settings = settings;
      this.pushEnabled = settings.getSync('run_push_enabled', false) === true;
      const runRead = JSON.parse(settings.getSync('run_inbox_read', '[]') as string) as string[];
      if (Array.isArray(runRead)) this.runRead = runRead.slice(0, 240);
      try {
        const dismissed = JSON.parse(settings.getSync('run_inbox_dismissed', '[]') as string) as string[];
        if (Array.isArray(dismissed)) {
          this.dismissedInboxRuns = new Set<string>(dismissed.filter((id: string): boolean => typeof id === 'string'));
        }
      } catch { /* Ignore an invalid dismissal list. */ }
      this.themeId = themeStyle(settings.getSync('theme_style', 'sakura') as string).id;
      this.themeMotionEnabled = settings.getSync(THEME_MOTION_SETTING, true) !== false;
      this.modeId = appearanceMode(settings.getSync('appearance_mode', 'system') as string).id;
      this.runNoticesEnabled = settings.getSync(RUN_NOTICE_SETTING, true) !== false;
      this.liveViewsEnabled = settings.getSync(LIVE_VIEW_SETTING, true) !== false;
      const scheduleWatches = settings.getSync('schedule_watches', '[]') as string;
      this.scheduleWatches = JSON.parse(scheduleWatches) as ScheduleWatch[];
      const raw = settings.getSync('huawei_profile', '') as string;
      if (!raw) return;
      const profile = JSON.parse(raw) as HuaweiProfile;
      if (typeof profile?.openId === 'string' && profile.openId &&
        typeof profile.name === 'string' && typeof profile.avatar === 'string') {
        this.huaweiProfile = profile;
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

  private async setRunNoticesEnabled(enabled: boolean): Promise<void> {
    this.runNoticesEnabled = enabled;
    if (!enabled) this.clearRunNotices();
    try {
      await this.saveSetting(RUN_NOTICE_SETTING, enabled);
    } catch {
      if (this.runNoticesEnabled === enabled) {
        this.getUIContext().getPromptAction().showToast({ message: '未能保存通知设置' });
      }
    }
  }

  private async setLiveViewsEnabled(enabled: boolean): Promise<void> {
    this.liveViewsEnabled = enabled;
    if (!enabled) {
      this.liveViewSessionKey = '';
      this.liveViewRunId = '';
      this.liveViewStatus = '';
    }
    this.syncLiveActivity();
    if (this.visible && this.backgroundLiveActivity()) {
      this.schedule(0);
      this.startStream();
    }
    try {
      await this.saveSetting(LIVE_VIEW_SETTING, enabled);
    } catch {
      if (this.liveViewsEnabled === enabled) {
        this.getUIContext().getPromptAction().showToast({ message: '未能保存实况窗设置' });
      }
    }
  }

  private async checkHuaweiProfile(): Promise<void> {
    const profile = this.huaweiProfile;
    if (!profile || this.accountBusy) return;
    try {
      if (!await isHuaweiProfileCurrent(profile) && this.huaweiProfile === profile && !this.accountBusy) {
        await this.signOutHuawei();
      }
    } catch { /* A temporary Account Kit failure leaves the local profile available. */ }
  }

  private async signInHuawei(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context || this.accountBusy) return;
    this.accountBusy = true;
    this.accountNotice = '';
    try {
      this.huaweiProfile = await authorizeHuaweiProfile(context);
      this.scheduleCloudSync(0);
      this.avatarUnavailable = false;
      try { await this.saveSetting('huawei_profile', JSON.stringify(this.huaweiProfile)); }
      catch { this.accountNotice = '已登录，本次登录状态无法保存。'; }
    } catch (error) {
      const code = (error as BusinessError).code;
      if (code !== 1001502012) {
        this.accountNotice = code === 1001500001 ? '华为账号登录需要配置应用签名指纹和 Client ID。' :
          '华为账号登录未完成，请检查系统账号后重试。';
      }
    } finally { this.accountBusy = false; }
  }

  private async signOutHuawei(): Promise<void> {
    if (this.accountBusy) return;
    this.accountBusy = true;
    this.accountNotice = '';
    try {
      await this.saveSetting('huawei_profile', '');
      this.huaweiProfile = undefined;
      this.avatarUnavailable = false;
      this.cloudStore = undefined;
      this.cloudComputers = [];
      this.pendingCloudRows.clear();
      this.cloudSyncStatus = '';
      this.cloudSyncBusy = false;
      this.restoringComputer = undefined;
      if (this.cloudTimer !== -1) clearTimeout(this.cloudTimer);
      this.cloudTimer = -1;
    }
    catch { this.accountNotice = '未能清除本地登录记录，请重试退出。'; }
    finally { this.accountBusy = false; }
  }

  private queueCloudWork(work: () => Promise<void>): void {
    this.cloudWork = this.cloudWork.then(work).catch(() => {});
  }

  private async accountCloudStore(profile: HuaweiProfile): Promise<AccountSync> {
    if (this.huaweiProfile !== profile) throw new Error('account_changed');
    if (!this.cloudStore) {
      const context = this.getUIContext().getHostContext();
      if (!context) throw new Error('context_unavailable');
      this.cloudStore = AccountSync.open(context, profile.openId).catch((error: Error) => {
        if (this.huaweiProfile === profile) this.cloudStore = undefined;
        throw error;
      });
    }
    return this.cloudStore;
  }

  private scheduleCloudSync(delay: number = 650): void {
    const profile = this.huaweiProfile;
    if (!profile) return;
    if (this.cloudTimer !== -1) clearTimeout(this.cloudTimer);
    this.cloudTimer = setTimeout(() => {
      this.cloudTimer = -1;
      const revision = this.cloudRevision;
      this.queueCloudWork(async () => { await this.syncAccountSettings(profile, revision); });
    }, delay);
  }

  private async syncAccountSettings(profile: HuaweiProfile, revision: number): Promise<void> {
    await this.restoreChain;
    if (this.huaweiProfile !== profile) return;
    this.cloudSyncBusy = true;
    this.cloudSyncStatus = '正在与华为云空间同步…';
    let step = 'account';
    try {
      if (!await isHuaweiProfileCurrent(profile) || this.huaweiProfile !== profile) {
        if (this.huaweiProfile === profile) this.cloudSyncStatus = '请重新登录华为账号。';
        return;
      }
      if (this.settings && !this.settings.getSync('cloud_migration_owner', '')) {
        await this.saveSetting('cloud_migration_owner', profile.openId);
      }
      step = 'local';
      const store = await this.accountCloudStore(profile);
      await this.persistCloudRows(profile);
      const cached = await store.read();
      if (this.huaweiProfile === profile && revision === this.cloudRevision) this.cloudComputers = cached.computers;
      if (!await isHuaweiProfileCurrent(profile) || this.huaweiProfile !== profile) return;
      step = 'cloud';
      let result = await store.synchronize();
      if (this.huaweiProfile !== profile) return;
      if (result === relationalStore.ProgressCode.SUCCESS && revision === this.cloudRevision) {
        step = 'migration';
        if (await store.seed(this.legacyCloudSettings(profile))) {
          if (!await isHuaweiProfileCurrent(profile) || this.huaweiProfile !== profile) return;
          step = 'upload';
          result = await store.synchronize();
        }
      }
      step = 'restore';
      const snapshot = await store.read();
      if (this.huaweiProfile !== profile) return;
      if (revision === this.cloudRevision) this.applyCloudSettings(snapshot);
      this.cloudSyncStatus = result === relationalStore.ProgressCode.SUCCESS ? '电脑列表和主题偏好已同步' :
        result === relationalStore.ProgressCode.CLOUD_DISABLED ? '请在「设置 → 云空间」开启 Pi Go 同步。' :
        result === relationalStore.ProgressCode.NETWORK_ERROR ? '云空间连接失败，请检查网络后重试。' :
        '云空间同步暂未完成，请稍后重试。';
    } catch (error) {
      console.warn(`[PiGoCloud] ${step} failed, code=${(error as BusinessError).code ?? 'unknown'}`);
      if (this.huaweiProfile === profile) this.cloudSyncStatus = '云空间暂不可用，请检查同步设置后重试。';
    } finally {
      if (this.huaweiProfile === profile) this.cloudSyncBusy = false;
    }
  }

  private legacyCloudSettings(profile: HuaweiProfile): SyncRow[] {
    const settings = this.settings;
    if (!settings) return [];
    if (settings.getSync('cloud_migration_owner', '') !== profile.openId) return [];
    const rows = this.computers.map((computer: Companion): SyncRow =>
      computerSyncRow(computer.address, validUsb(computer.address) ? 'usb' :
        connectionLabel(computer) === '公网' ? 'remote' : 'lan'));
    const theme = settings.getSync(SYNC_THEME, '') as string;
    const mode = settings.getSync(SYNC_MODE, '') as string;
    if (theme && themeStyle(theme).id === theme) rows.push({ key: SYNC_THEME, payload: theme });
    if (mode && appearanceMode(mode).id === mode) rows.push({ key: SYNC_MODE, payload: mode });
    return rows;
  }

  private applyCloudSettings(snapshot: SyncSnapshot): void {
    this.cloudComputers = snapshot.computers;
    if (snapshot.theme !== this.themeId && themeStyle(snapshot.theme).id === snapshot.theme) {
      this.themeId = snapshot.theme;
      void this.saveSetting(SYNC_THEME, snapshot.theme).catch(() => { this.appearanceNotice = '未能保存主题配色。'; });
    }
    if (snapshot.mode !== this.modeId && appearanceMode(snapshot.mode).id === snapshot.mode) {
      this.applyAppearanceMode(appearanceMode(snapshot.mode));
    }
  }

  private writeCloudRow(row: SyncRow): void {
    const profile = this.huaweiProfile;
    if (!profile) return;
    this.cloudRevision += 1;
    this.pendingCloudRows.set(row.key, row);
    void this.persistCloudRows(profile).then(() => {
      if (this.huaweiProfile === profile) this.scheduleCloudSync();
    }).catch(() => {
      if (this.huaweiProfile === profile) this.cloudSyncStatus = '本次修改无法保存到同步库，请稍后重试。';
    });
  }

  private persistCloudRows(profile: HuaweiProfile): Promise<void> {
    const write = this.cloudWrites.then(async () => {
      if (this.huaweiProfile !== profile || !this.pendingCloudRows.size) return;
      const store = await this.accountCloudStore(profile);
      for (const row of Array.from(this.pendingCloudRows.values())) {
        if (this.huaweiProfile !== profile) return;
        await store.save(row);
        if (this.huaweiProfile === profile && this.pendingCloudRows.get(row.key) === row) {
          this.pendingCloudRows.delete(row.key);
        }
      }
    });
    this.cloudWrites = write.catch(() => {});
    return write;
  }

  private updateCloudComputer(address: string, mode: string): void {
    try {
      this.writeCloudRow(computerSyncRow(address, mode));
    } catch {
      this.cloudSyncStatus = '未能同步电脑列表。';
    }
  }

  private restoreCloudComputer(computer: CloudComputer): void {
    this.pairingComputerId = '';
    this.selectPairingMode(computer.mode);
    if (computer.mode === 'usb') this.address = computer.address;
    this.ticket = '';
    this.pairingBundle = '';
    this.lanCandidates = [];
    this.status = '';
    this.restoringComputer = computer;
    this.addingComputer = true;
  }

  private removeCloudComputer(computer: CloudComputer): void {
    if (this.removeTarget !== computer.address || this.busy || !this.huaweiProfile) return;
    this.removeTarget = '';
    this.updateCloudComputer(computer.address, '');
  }

  private palette(): ThemePalette { return themePalette(this.themeId, this.darkMode); }

  private accent(): string { return this.palette().accent; }

  private accentTint(): string { return this.palette().accentTint; }

  private accentForeground(): string { return this.palette().accentForeground; }

  private themeCanvas(): string { return this.palette().canvas; }

  private selectTheme(id: string): void {
    this.appearanceNotice = '';
    this.themeId = id;
    void this.saveSetting(SYNC_THEME, id).catch(() => { this.appearanceNotice = '未能保存主题配色。'; });
    this.writeCloudRow({ key: SYNC_THEME, payload: id });
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
    if (this.applyAppearanceMode(mode)) this.writeCloudRow({ key: SYNC_MODE, payload: mode.id });
  }

  private openComputers(): void {
    if (this.editingPath && this.fileText !== this.fileOriginal) {
      this.status = '请先保存或放弃文件修改。';
      return;
    }
    if (this.showSessions) this.setDrawer(false);
    this.showSettings = false;
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
    this.status = '';
  }

  private closeComputerEditors(): void {
    this.renameComputerId = '';
    this.computerNameDraft = '';
    this.moveConnectionAddress = '';
  }

  private addComputerConnection(id: string = ''): void {
    this.closeComputerEditors();
    this.status = '';
    this.ticket = '';
    this.pairingBundle = '';
    this.lanCandidates = [];
    this.restoringComputer = undefined;
    this.pairingComputerId = id;
    this.addingComputer = true;
  }

  private saveComputerName(id: string): void {
    if (this.renameComputerId !== id || this.busy) return;
    this.computers = renameComputerGroup(this.computers, id, this.computerNameDraft);
    this.closeComputerEditors();
    this.dismissKeyboard();
    void this.persistComputers().catch(() => { this.status = '未能保存电脑备注。'; });
  }

  private assignComputerConnection(address: string, group?: ComputerGroup): void {
    if (this.moveConnectionAddress !== address || this.busy) return;
    this.computers = moveComputerConnection(this.computers, address, group?.id ?? util.generateRandomUUID(), group?.name ?? '');
    this.closeComputerEditors();
    void this.persistComputers().catch(() => { this.status = '未能保存连接归属。'; });
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
      !this.showSettings && !this.noSession && !!this.currentId) ||
      (!this.reachable && !this.offlineDismissed) || !!this.interaction || (!!this.pendingSend && !this.busy);
  }

  @Builder
  mineHeader() {
    Row({ space: 12 }) {
      if (this.minePage) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().attributeModifier(immersiveSurface(this.darkMode))
          .accessibilityText('返回').enabled(!this.busy).onClick(() => { this.mineBack(); })
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
      accountBusy: this.accountBusy,
      accountNotice: this.accountNotice,
      addComputerConnection: (id?: string): void => this.addComputerConnection(id),
      addingComputer: this.addingComputer,
      address: this.$address,
      appearanceNotice: this.appearanceNotice,
      assignComputerConnection: (address: string, group?: ComputerGroup): void => this.assignComputerConnection(address, group),
      avatarUnavailable: this.$avatarUnavailable,
      base: this.base,
      bottomContentClearance: this.bottomContentClearance(),
      busy: this.busy,
      chooseComputer: (record: Companion): void => this.chooseComputer(record),
      closeComputerEditors: (): void => this.closeComputerEditors(),
      cloudComputers: this.$cloudComputers,
      cloudSyncBusy: this.cloudSyncBusy,
      cloudSyncStatus: this.cloudSyncStatus,
      computerConnectionMenu: (record: Companion): MenuElement[] => this.computerConnectionMenu(record),
      computerNameDraft: this.$computerNameDraft,
      computers: this.$computers,
      darkMode: this.darkMode,
      dismissKeyboard: (): void => this.dismissKeyboard(),
      findLanCompanions: (): Promise<void> => this.findLanCompanions(),
      huaweiProfile: this.huaweiProfile,
      isPaired: this.isPaired,
      lanCandidates: this.$lanCandidates,
      liveViewStatus: this.liveViewStatus,
      liveViewsEnabled: this.liveViewsEnabled,
      minePage: this.$minePage,
      modeId: this.modeId,
      moveConnectionAddress: this.moveConnectionAddress,
      openingSession: this.openingSession,
      pair: (): Promise<void> => this.pair(),
      pairingBundle: this.$pairingBundle,
      pairingComputerId: this.pairingComputerId,
      pairingMode: this.pairingMode,
      reachable: this.reachable,
      removeCloudComputer: (computer: CloudComputer): void => this.removeCloudComputer(computer),
      removeComputer: (address: string): void => this.removeComputer(address),
      removeTarget: this.$removeTarget,
      renameComputerId: this.$renameComputerId,
      restoreCloudComputer: (computer: CloudComputer): void => this.restoreCloudComputer(computer),
      restoringComputer: this.restoringComputer,
      runNoticesEnabled: this.runNoticesEnabled,
      saveComputerName: (id: string): void => this.saveComputerName(id),
      scanPairingBundle: (): Promise<void> => this.scanPairingBundle(),
      scheduleCloudSync: (delay?: number): void => this.scheduleCloudSync(delay),
      selectAppearanceMode: (mode: AppearanceMode): void => this.selectAppearanceMode(mode),
      selectPairingMode: (mode: string): void => this.selectPairingMode(mode),
      selectTheme: (id: string): void => this.selectTheme(id),
      setThemeMotionEnabled: (enabled: boolean): Promise<void> => this.setThemeMotionEnabled(enabled),
      themeMotionEnabled: this.themeMotionEnabled,
      setLiveViewsEnabled: (enabled: boolean): Promise<void> => this.setLiveViewsEnabled(enabled),
      setRunNoticesEnabled: (enabled: boolean): Promise<void> => this.setRunNoticesEnabled(enabled),
      signInHuawei: (): Promise<void> => this.signInHuawei(),
      signOutHuawei: (): Promise<void> => this.signOutHuawei(),
      themeId: this.themeId,
      ticket: this.$ticket,
      topContentClearance: this.topContentClearance(),
      accent: this.accent(),
      accentForeground: this.accentForeground(),
      accentTint: this.accentTint()
    })
  }

  @Builder
  fileEditorPage() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.id('file-back').headerAction().attributeModifier(glassButtonSurface(this.darkMode)).accessibilityText(this.fileText !== this.fileOriginal ? '放弃修改' : '返回')
          .enabled(!this.busy).onClick(() => { this.returnToFilePreview(true); })
        Text(this.editingPath.split('/').pop() || this.editingPath)
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('预览').chatAction().id('file-editor-preview').height(38).enabled(!this.busy).onClick(() => {
          this.showTextPreview(this.editingRoot, this.editingPath, this.fileText);
        })
      }.width('100%').height(this.headerHeight())
        .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
      Text(this.editingPath).fontSize(12).fontColor($r('app.color.pigo_muted'))
        .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      TextArea({ text: this.fileText }).id('file-editor').layoutWeight(1).width('100%').maxLength(65536)
        .fontFamily('monospace').fontSize(14).backgroundColor($r('app.color.pigo_panel'))
        .fontColor($r('app.color.pigo_text')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.pigo_line') })
        .enabled(!this.busy).onChange((value: string) => { this.fileText = value; })
      if (this.editorNotice) {
        Text(this.editorNotice).id('file-editor-notice').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      Button(this.busy ? '正在保存…' : '保存到电脑').chatAction().id('file-save').width('100%').height(46)
        .backgroundColor(this.accent()).fontColor(this.accentForeground())
        .enabled(this.reachable && !this.busy && this.fileText !== this.fileOriginal)
        .onClick(() => { void this.saveFile(); })
    }.width('100%').constraintSize({ maxWidth: 840 }).height('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: this.statusBarHeight + 8, bottom: this.bottomPad() + 8 })
  }

  @Builder
  workspaceFiles() {
    WorkspaceFiles({
      bottomContentClearance: this.bottomContentClearance(),
      busy: this.busy,
      fileRoot: this.fileRoot,
      fileTreeIndex: this.fileTreeIndex,
      fileTreeRows: this.$fileTreeRows,
      loadFileDirectory: (path: string, more?: boolean): Promise<void> => this.loadFileDirectory(path, more),
      openFile: (cwd: string, path: string, lookupName?: boolean): Promise<void> => this.openFile(cwd, path, lookupName),
      openingSession: this.openingSession,
      project: this.project,
      toggleFileDirectory: (path: string): Promise<void> => this.toggleFileDirectory(path),
      topContentClearance: this.topContentClearance(),
      accent: this.accent(),
      setFileTreeIndex: (index: number): void => { this.fileTreeIndex = index; }
    })
  }

  @Builder
  sessionSettings() {
    Scroll() {
      Column({ space: 14 }) {
        Column({ space: 10 }) {
          Text('会话名称').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
          TextInput({ text: this.renameDraft, placeholder: '输入会话名称' }).id('rename-draft').maxLength(200)
            .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
            .placeholderColor($r('app.color.pigo_muted'))
            .onChange((value: string) => { this.renameDraft = value; })
          Button('保存名称').chatAction().id('rename-save').width('100%').height(42)
            .backgroundColor(this.accent()).fontColor(this.accentForeground())
            .enabled(!this.busy && this.reachable && !!this.renameDraft.trim())
            .onClick(() => { void this.requestAction('/rename', { id: this.currentId, name: this.renameDraft.trim() }); })
        }.width('100%').padding(14).attributeModifier(glassCardSurface(this.darkMode, 16))
        Column({ space: 10 }) {
          Row() {
            Text('模型与思考').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).layoutWeight(1)
            Text(this.modelLabel).fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '60%' })
          }.width('100%')
          if (this.models.length) {
            Select(this.models.map((model: ModelOption): SelectOption => ({
              value: `${model.name} · ${model.provider}${model.image ? ' · 图片' : ''}`
            })))
              .id('model-select').width('100%').selected(this.selectedModel)
              .value(this.models[this.selectedModel] ? `${this.models[this.selectedModel].name} · ${this.models[this.selectedModel].provider}` : '选择模型')
              .fontColor($r('app.color.pigo_text')).backgroundColor($r('app.color.pigo_control'))
              .enabled(!this.busy)
              .onSelect((index: number) => {
                this.selectedModel = index;
                const model = this.models[index];
                if (model && !model.levels.includes(this.selectedLevel)) this.selectedLevel = model.levels[0] ?? 'off';
              })
          }
          if (this.selectedModel >= 0 && this.models[this.selectedModel]) {
            Text('思考级别').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_muted')).width('100%')
            if (this.models[this.selectedModel].levels.length > 1) {
              Row({ space: 4 }) {
                ForEach(this.models[this.selectedModel].levels, (level: string) => {
                  Button(this.thinkingLevelLabel(level), { type: ButtonType.Normal }).chatAction()
                    .layoutWeight(1).height(36).padding(2).borderRadius(10).fontSize(13)
                    .backgroundColor(this.selectedLevel === level ? this.accent() : Color.Transparent)
                    .fontColor(this.selectedLevel === level ? this.accentForeground() : $r('app.color.pigo_muted'))
                    .enabled(!this.busy)
                    .onClick(() => { this.selectedLevel = level; })
                }, (level: string) => level)
              }.id('thinking-select').width('100%').padding(4).borderRadius(14)
                .backgroundColor($r('app.color.pigo_control'))
            } else {
              Text('此模型不支持调整思考级别。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
            }
            Button('应用模型与思考级别').chatAction().id('model-apply').width('100%').height(44)
              .backgroundColor(this.accent()).fontColor(this.accentForeground())
              .enabled(this.reachable && !this.busy && this.idle && !this.queued)
              .onClick(() => {
                const model = this.models[this.selectedModel];
                if (model) void this.requestAction('/model', { id: this.currentId, provider: model.provider,
                  modelId: model.id, thinkingLevel: this.selectedLevel });
              })
          }
          if (!this.idle || this.queued) {
            Text('等待当前任务和队列结束后可切换模型。').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
          }
          if (!this.models.length) {
            Text('没有可用模型，请在电脑上检查 Pi CLI 的模型配置。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
          }
        }.width('100%').padding(14).attributeModifier(glassCardSurface(this.darkMode, 16))
        Column({ space: 10 }) {
          Text('会话分享').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
          Text('将当前会话整理为 Markdown 文件，通过系统分享发送给其他应用。')
            .fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
          Button(this.sharingSession ? '正在准备分享…' : '分享会话').chatAction().id('session-share')
            .width('100%').height(42).backgroundColor(this.accent()).fontColor(this.accentForeground())
            .enabled(!this.sharingSession && !!this.currentId)
            .onClick(() => { void this.shareCurrentSession('session-share'); })
        }.width('100%').padding(14).attributeModifier(glassCardSurface(this.darkMode, 16))
      }.width('100%').padding({ left: 16, right: 16, top: this.topContentClearance(), bottom: this.bottomPad() + 16 })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder
  chatHeader() {
    Row({ space: 10 }) {
      if (this.showSettings) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().attributeModifier(immersiveSurface(this.darkMode)).accessibilityText('返回会话').onClick(() => { this.showSettings = false; })
      } else if (!this.dockedSessions() && !this.showFiles) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.line_2_horizontal'), $r('app.color.pigo_text'), 20)
        }.id('history').headerAction().attributeModifier(immersiveSurface(this.darkMode))
          .accessibilityText('打开会话抽屉').enabled(!this.busy)
          .onClick(() => { this.setDrawer(true); })
      }
      Column({ space: 3 }) {
        Text(this.showFiles ? '工作区文件' : this.showSettings ? '会话设置' : this.activeTab === 'pending' ? '任务' : this.chatTitle())
          .fontSize(this.showFiles || this.showSettings ? 20 : 18).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (!this.showSettings) {
          Row({ space: 6 }) {
            Blank().width(7).height(7).borderRadius(4)
              .backgroundColor(this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
              .accessibilityText(this.reachable ? '电脑已连接' : '电脑离线')
            if (this.currentAgent && this.currentAgent !== 'pi') {
              Text(this.currentAgent === 'codex' ? 'Codex' : this.currentAgent === 'agy' ? 'AGY' : this.currentAgent.toUpperCase())
                .fontSize(10).fontWeight(FontWeight.Medium).fontColor(this.accent())
                .padding({ left: 5, right: 5, top: 1, bottom: 1 }).borderRadius(5)
                .backgroundColor(this.accentTint())
            }
            Text(this.reachable ? (this.project ? `${this.project} · ${this.computerTitle()}` : this.computerTitle()) :
              `离线 · ${this.computerTitle()}`)
              .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').onClick(() => { if (!this.dockedSessions() && !this.showFiles) this.setDrawer(true); })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.showFiles) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.arrow_clockwise'), $r('app.color.pigo_text'), 19)
        }.id('file-refresh').headerAction().attributeModifier(immersiveSurface(this.darkMode)).accessibilityText('刷新工作区')
          .enabled(!this.busy && !this.openingSession && this.reachable)
          .onClick(() => { void this.loadFileDirectory(''); })
      } else if (!this.showSettings) {
        Row({ space: 6 }) {
          this.scheduleInboxButton()
          Button({ type: ButtonType.Normal }) {
            headerSymbol($r('sys.symbol.square_and_pencil'), this.accent(), 19)
          }.id('new-task').headerAction().attributeModifier(immersiveSurface(this.darkMode)).accessibilityText('新建会话')
            .enabled(this.reachable && !this.busy && !this.openingSession && this.hostAvailable &&
              !!this.workspaceCwd && this.projects.includes(this.workspaceCwd))
            .onClick(() => { this.openNewSession('', this.currentAgent); })
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
  chatTranscript() {
    ChatTranscript({
      base: this.base,
      busy: this.busy,
      closeMarkdownTableReader: (): void => this.closeMarkdownTableReader(),
      copyText: (value: string): Promise<void> => this.copyText(value),
      replyActionsEnabled: this.reachable && this.idle && !this.queued && !this.busy && !this.openingSession && !this.pendingSend,
      forkReply: (messageId: string): void => {
        void this.requestAction('/fork', { id: this.currentId, messageId: messageId, history: this.syncMode !== 'legacy' });
      },
      regenerateReply: (messageId: string): void => {
        if (this.speakingReply === messageId) this.stopReplySpeech();
        void this.requestAction('/regenerate', { id: this.currentId, messageId: messageId });
      },
      speakingReply: this.speakingReply,
      toggleReplySpeech: (message: ChatMessage): void => { void this.toggleReplySpeech(message); },
      currentId: this.currentId,
      darkMode: this.darkMode,
      dismissKeyboard: (): void => this.dismissKeyboard(),
      historyCursor: this.historyCursor,
      idle: this.idle,
      keyboardHeight: this.keyboardHeight,
      liveText: this.liveText,
      liveThinking: this.liveThinking,
      liveThinkingOpen: this.$liveThinkingOpen,
      liveTools: this.$liveTools,
      loadHistory: (): Promise<void> => this.loadHistory(),
      loadHistoryImage: (sessionId: string, messageId: string, index: number, toolId: string): Promise<string> => this.loadHistoryImage(sessionId, messageId, index, toolId),
      loadMarkdownImage: (target: string, cwd: string, documentPath: string): Promise<string> => this.loadMarkdownImage(target, cwd, documentPath),
      loadingMessageText: this.loadingMessageText,
      messages: this.$messages,
      runResults: this.sessionRunKey === this.draftKey(this.currentId) ? this.sessionRuns : [],
      openRunResult: (run: RunEvent): void => this.openRunResult(run),
      openMarkdownLink: (target: string, cwd: string, documentPath: string): Promise<void> => this.openMarkdownLink(target, cwd, documentPath),
      openMarkdownTableReader: (source: string, cwd: string, documentPath: string): void => this.openMarkdownTableReader(source, cwd, documentPath),
      openReferencedFile: (cwd: string, path: string, lookupName: boolean): Promise<void> => this.openReferencedFile(cwd, path, lookupName),
      openToolDetails: (tool: LiveTool, messageId: string): void => this.openToolDetails(tool, messageId),
      openingFile: this.openingFile,
      positionTranscript: (id: string, contentHeight: number): void => this.positionTranscript(id, contentHeight),
      queuedSteering: this.$queuedSteering,
      reachable: this.reachable,
      showChatImage: (source: string, label: string): void => this.showChatImage(source, label),
      showFullReply: (messageId: string): Promise<void> => this.showFullReply(messageId),
      thinkingOpenIds: this.$thinkingOpenIds,
      toggleThinking: (id: string, open: boolean): void => this.toggleThinking(id, open),
      transcript: this.transcript,
      transcriptFollow: this.$transcriptFollow,
      workspaceCwd: this.workspaceCwd,
      emptyTranscript: this.emptyTranscript.bind(this),
      accent: this.accent(),
      accentTint: this.accentTint(),
      themeId: this.themeId,
      topPadding: this.chatHasTopCards() ? 10 : this.topContentClearance(),
      bottomPadding: this.chatBottomClearance(),
      scrollBottomOffset: this.chatScrollBottomOffset(),
      readTranscriptHeight: () => this.transcriptContentHeight,
      setTranscriptViewport: (height: number): void => { this.transcriptViewport = height; }
    })
  }

  private composerBottomMargin(): number {
    return (this.showRootBottomTabs() ? this.bottomTabsHeight() + 10 : 0) + this.bottomPad() + 8;
  }

  private chatScrollBottomOffset(): number {
    return this.composerBottomMargin() + (this.attachments.length ? 186 : 114);
  }

  private chatBottomClearance(): number {
    return this.composerBottomMargin() + (this.attachments.length ? 194 : 122);
  }

  @Builder
  emptyTranscript() {
    this.welcome(true)
  }

  @Builder
  chat() {
    if (this.showFiles) {
      this.workspaceFiles()
    } else if (this.showSettings) {
      this.sessionSettings()
    } else if (this.activeTab === 'pending') {
      this.taskView()
    } else if (this.noSession) {
      this.welcome()
    } else {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          if (this.chatHasTopCards()) {
            Column({ space: 8 }) {
              this.runningStrip()
              if (!this.reachable && !this.offlineDismissed) this.offlineNotice(false)
              if (this.interaction) this.pendingCard(this.interaction)
              if (this.pendingSend && !this.busy) {
                Row({ space: 8 }) {
                  Button('核对发送').chatAction().id('check-send').enabled(this.reachable).onClick(() => { void this.checkSend(); })
                  Button('保留草稿').chatAction().id('keep-draft').onClick(() => {
                    this.chatState.unconfirmed.delete(this.draftKey(this.currentId));
                    this.pendingSend = undefined;
                    this.status = '已保留草稿，未重发。';
                  })
                }.width('100%')
              }
            }.width('100%').padding({ left: 16, right: 16, top: this.topContentClearance() })
          }
          this.chatTranscript()
        }.width('100%').height('100%')
        Column({ space: 6 }) {
          if (this.commandPalette && this.commandPaletteActive()) {
            Column({ space: 2 }) {
              if (!this.commandMatches().length) {
                Text(this.commandsLoading ? '正在加载命令…' : !this.reachable ? '电脑离线，等待重连' :
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
        })
      }.width('100%').layoutWeight(1)
    }
  }

  @Builder
  composer() {
    ChatComposer({
      acceptsImage: this.acceptsImage,
      applyModelFromMenu: (index: number): Promise<void> => this.applyModelFromMenu(index),
      applyThinkingLevelFromMenu: (level: string): Promise<void> => this.applyThinkingLevelFromMenu(level),
      armTranscriptFollow: (): void => this.armTranscriptFollow(),
      attachFile: (): Promise<void> => this.attachFile(),
      attachImage: (source: string): Promise<void> => this.attachImage(source),
      attachments: this.$attachments,
      busy: this.busy,
      commandError: this.commandError,
      commandRows: this.$commandRows,
      commandsLoading: this.commandsLoading,
      currentId: this.currentId,
      currentLevel: this.currentLevel,
      currentModel: this.currentModel,
      dismissKeyboard: (): void => this.dismissKeyboard(),
      draft: this.$draft,
      holdCancel: this.holdCancel,
      holdTouch: (event: TouchEvent): void => this.holdTouch(event),
      idle: this.idle,
      liveVoiceText: this.$liveVoiceText,
      loadCommands: (): Promise<void> => this.loadCommands(),
      modelLabel: this.modelLabel,
      models: this.$models,
      openComposerMenu: (): void => this.openComposerMenu(),
      openModelMenu: (): Promise<void> => this.openModelMenu(),
      openSkillPicker: (): void => this.openSkillPicker(),
      openingSession: this.openingSession,
      hasPendingSend: this.pendingSend !== undefined,
      pickSkill: (row: CommandRow): void => this.pickSkill(row),
      queued: this.queued,
      reachable: this.reachable,
      recording: this.recording,
      removeAttachment: (index: number): void => this.removeAttachment(index),
      requestAction: (path: string, input?: Payload): Promise<boolean> => this.requestAction(path, input),
      runId: this.runId,
      send: (): Promise<void> => this.send(),
      showComposerMenu: this.$showComposerMenu,
      showModelMenu: this.$showModelMenu,
      showSkillPicker: this.$showSkillPicker,
      status: this.$status,
      syncCommandPalette: (): void => this.syncCommandPalette(),
      voiceCancelling: this.voiceCancelling,
      voiceFinishing: this.voiceFinishing,
      voiceMode: this.$voiceMode,
      voicePreparing: this.voicePreparing,
      windowHeight: this.windowHeight,
      windowWidth: this.windowWidth,
      accent: this.accent(),
      accentForeground: this.accentForeground(),
      accentTint: this.accentTint()
    })
  }

  private cacheChat(session: SessionState): void {
    const key = this.draftKey(session.id);
    const start = Math.max(0, this.messages.length - 60);
    const current: SessionState = this.syncMode === 'sequenced'
      ? { id: session.id, cwd: session.cwd, name: this.sessionName, idle: this.idle, runId: this.runId || null,
        queued: this.queued, acceptsImage: this.acceptsImage, model: this.currentModel, thinkingLevel: this.currentLevel }
      : session;
    this.chatState.cacheTranscript(key, {
      session: current, messages: this.messages.slice(start), liveText: this.liveText,
      liveSeq: this.liveSeq, liveThinking: this.liveThinking, liveThinkSeq: this.liveThinkSeq,
      tools: this.liveTools.slice(0),
      historyCursor: start > 0 ? this.messages[start].id : this.historyCursor,
      interaction: this.interaction
    });
  }

  private presentChat(chat: BridgeReply, reveal: boolean, currentSnapshot: boolean = true): void {
    if (!chat.session) return;
    const moved = chat.session.id !== this.currentId;
    if (currentSnapshot || moved) this.applySession(chat.session);
    this.mergeTranscript(chat.messages ?? [], chat.historyCursor);
    if (currentSnapshot || moved) this.applyLiveSnapshot(chat, true);
    this.setInteraction(chat.interaction);
    this.revealChat(reveal);
  }

  private revealChat(reveal: boolean): void {
    if (reveal) {
      this.pendingBottom = true;
      this.transcriptFollow = true;
      this.pendingSessionReveal = this.currentId;
    }
    this.showFiles = false;
    this.showSettings = false;
    this.activeTab = 'tasks';
  }

  private positionTranscript(id: string, contentHeight: number): void {
    if (id !== this.currentId || contentHeight <= 0) return;
    this.transcriptContentHeight = contentHeight;
    if (this.pendingSessionReveal === id) this.transcriptFollow = true;
    if (!this.transcriptFollow) { this.pendingBottom = false; return; }
    if (!this.pendingBottom) return;
    this.pendingBottom = false;
    // The content height exceeds the maximum offset; Scroll clamps it to the bottom.
    this.transcript.scrollTo({ xOffset: 0, yOffset: contentHeight, animation: false });
    if (this.pendingSessionReveal === id) {
      this.pendingSessionReveal = '';
      this.showSessions = false;
    }
  }

  private swipeDrawer(event: GestureEvent): void {
    if (Math.abs(event.offsetX) <= 45 || Math.abs(event.offsetX) <= Math.abs(event.offsetY) * 1.3) return;
    if (this.showSessions) {
      if (event.offsetX < 0) this.setDrawer(false);
    } else if (event.offsetX > 0 && !this.busy) {
      if (this.showFiles) this.fileBack();
      else if (!this.showSettings) this.setDrawer(true);
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
    if (open && this.reachable && (!this.sessionCatalogLoaded ||
      (this.sessionView === 'all' && Date.now() - this.sessionCatalogUpdatedAt >= 30000) ||
      this.loadedView !== this.sessionView)) {
      void this.loadSessions();
    }
  }

  private dockedSessions(): boolean {
    return this.isPaired && this.activeTab !== 'mine' && this.windowWidth >= SPLIT_WINDOW_WIDTH;
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

  private onWindowWidthChange(): void {
    // Once the list is docked, folding back should leave the conversation visible.
    if (this.dockedSessions()) this.showSessions = false;
  }

  private updateSidebarRows(): void {
    this.sidebarRows.replace(this.sessionStore.rows({
      view: this.sessionView, loadedView: this.loadedView, sessions: this.sessions, projects: this.projects,
      workspaces: this.workspaces, expandedSpaces: this.expandedSpaces,
      workspacePages: this.workspacePages, nextCursor: this.sessionNextCursor
    }));
    if (this.pendingLibraryReveal) setTimeout(() => { this.revealLibraryAnchor(); }, 0);
  }

  private onSidebarAppear(): void {
    this.pendingLibraryReveal = !!this.currentId;
    this.updateSidebarRows();
  }

  private revealLibraryAnchor(): void {
    if (!this.pendingLibraryReveal || (!this.showSessions && !this.dockedSessions())) return;
    if (this.library.currentOffset().yOffset > 2) { this.pendingLibraryReveal = false; return; }
    const anchor = this.sidebarRows.anchor(this.currentId, this.workspaceCwd);
    if (anchor < 0) return;
    this.pendingLibraryReveal = false;
    if (anchor > 0) this.library.scrollToIndex(anchor, false, ScrollAlign.START);
  }

  private chatTitle(): string {
    const listed = this.sessions.find((session: SessionRow): boolean => session.id === this.currentId);
    const listedName = listed?.name === '(no messages)' ? '' : listed?.name;
    if (this.sessionName || listedName) return this.sessionName || listedName || '新任务';
    const firstPrompt = this.messages.find((message: ChatMessage): boolean => message.role === 'user');
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
    if (this.busy || this.sessionLoading || !this.reachable) return;
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
    this.showNewSession = false;
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
          .onClick(() => { this.offlineDismissed = false; this.schedule(0); })
      } else {
        Button('重试').chatAction().id('offline-retry')
          .height(34).fontSize(13).enabled(!this.busy)
          .accessibilityText('重试连接')
          .onClick(() => { this.offlineDismissed = false; this.schedule(0); })
      }
      if (!compact) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
        }.width(34).height(34).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
          .accessibilityText('关闭离线提示').onClick(() => { this.offlineDismissed = true; })
      }
    }.width('100%').padding(narrow ? 8 : compact ? 10 : 14).borderRadius(compact ? 12 : 16)
      .backgroundColor(compact ? $r('app.color.pigo_warning_panel') : $r('app.color.pigo_panel'))
      .border({ width: compact ? 0 : 1, color: $r('app.color.pigo_line') })
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
    if (this.busy) return false;
    if (this.editingPath && this.fileText !== this.fileOriginal) {
      this.status = '请先保存或放弃文件修改。';
      return false;
    }
    if (tab === 'files') {
      if (!this.reachable || !this.workspaceCwd) {
        this.status = '请先连接电脑并打开一个任务。';
        return false;
      }
      if (this.activeTab === 'files' && this.showFiles) return true;
      if (this.fileRoot !== this.workspaceCwd) {
        this.resetFileTree();
        this.fileRoot = this.workspaceCwd;
      }
      this.showFiles = true;
      this.status = '';
      if (!this.fileDirectories.has('')) void this.loadFileDirectory('');
    } else {
      this.showFiles = false;
      this.showSettings = false;
    }
    if (tab === 'mine' && this.minePage) {
      this.mineBack();
      this.minePage = '';
    }
    if (tab !== this.activeTab) {
      this.status = '';
      this.minePage = '';
      this.addingComputer = false;
      this.pairingComputerId = '';
      this.closeComputerEditors();
      this.restoringComputer = undefined;
      this.removeTarget = '';
    }
    this.activeTab = tab;
    if (tab === 'pending') void this.loadScheduleJobs();
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
        this.noSession || (this.reachable ? '输入你的目标，或添加文件作为上下文。' : '电脑重新连接后即可发送消息。'))
        .fontSize(15).fontColor($r('app.color.pigo_muted')).textAlign(TextAlign.Center).lineHeight(23)
        .constraintSize({ maxWidth: 320 })
      if (!this.loading && !this.isPaired) {
        Button('连接电脑').chatAction().height(46).padding({ left: 24, right: 24 })
          .backgroundColor(this.accent()).fontColor(this.accentForeground()).onClick(() => { this.openComputers(); })
      } else if (!this.loading && this.noSession && !this.dockedSessions()) {
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
      topClearance: this.topContentClearance(),
      bottomClearance: this.bottomContentClearance(),
      runningRows: this.taskPanelRows(),
      scheduleRuns: this.standaloneScheduleRuns(),
      currentId: this.currentId,
      busy: this.busy,
      openingSession: this.openingSession,
      accentTint: this.accentTint(),
      openRunningTask: (id: string): void => {
        if (id !== this.currentId) void this.requestAction('/open', { id: id });
        this.activeTab = 'tasks';
      },
      editSchedule: (job?: ScheduleJob): void => this.editSchedule(job),
      loadScheduleJobs: (): Promise<void> => this.loadScheduleJobs(),
      projects: this.$projects,
      reachable: this.reachable,
      scheduleError: this.$scheduleError,
      scheduleJobMenu: (job: ScheduleJob): MenuElement[] => this.scheduleJobMenu(job),
      scheduleJobs: this.$scheduleJobs,
      scheduleListError: this.scheduleListError,
      scheduleLoading: this.scheduleLoading,
      schedulePage: this.$schedulePage,
      scheduleSaving: this.scheduleSaving,
      workspaces: this.$workspaces,
      accent: this.accent(),
      accentForeground: this.accentForeground()
    })
  }

  @Builder
  runningStrip() {
    if (this.backgroundRunning().length && this.activeTab === 'tasks' && !this.showFiles &&
      !this.showSettings && !this.noSession && this.currentId) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.backgroundRunning(), (row: RunningRow) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                Text('').width(6).height(6).borderRadius(3)
                  .backgroundColor(this.stateColor(this.sessionState(row.id)))
                Text(row.name || '后台任务').fontSize(13).fontColor($r('app.color.pigo_text')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 152 })
                Text(this.stateLabel(this.sessionState(row.id))).fontSize(11)
                  .fontColor(this.stateColor(this.sessionState(row.id)))
              }
            }.id(`running-${row.id}`).height(34).padding({ left: 12, right: 12 }).borderRadius(17)
              .backgroundColor($r('app.color.pigo_panel')).accessibilityText(`${row.name || '后台任务'}${this.stateLabel(this.sessionState(row.id))}，点击切换查看`)
              .enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => {
                if (row.id !== this.currentId && !this.openingSession) {
                  this.activeTab = 'tasks';
                  void this.requestAction('/open', { id: row.id });
                }
              })
          }, (row: RunningRow) => row.id)
        }.padding({ left: 2, right: 6 })
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
        .edgeEffect(EdgeEffect.Spring).friction(0.5)
    }
  }

  @Builder
  sessionDrawer() {
    SessionSidebar({
      activeTab: this.$activeTab,
      base: this.base,
      busy: this.busy,
      canCreateWorkspace: this.canCreateWorkspace,
      confirmCloseSpace: (path: string, epoch: number): void => this.confirmCloseSpace(path, epoch),
      openNewSession: (path?: string): void => this.openNewSession(path),
      currentId: this.currentId,
      expandedSpaces: this.$expandedSpaces,
      hostAvailable: this.hostAvailable,
      idle: this.idle,
      interaction: this.interaction,
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
      offlineDismissed: this.$offlineDismissed,
      openComputers: (): void => this.openComputers(),
      openingSession: this.openingSession,
      openingSessionId: this.openingSessionId,
      projects: this.$projects,
      queued: this.queued,
      reachable: this.reachable,
      refreshSessions: (): Promise<void> => this.reachable ? this.loadSessions(false, true) : Promise.resolve(),
      requestAction: (path: string, input?: Payload): Promise<boolean> => this.requestAction(path, input),
      revealLibraryAnchor: (): void => this.revealLibraryAnchor(),
      runningSessionIds: this.$runningSessionIds,
      runningSessions: this.$runningSessions,
      schedule: (delay: number): void => this.schedule(delay),
      selectSessionView: (view: string): void => this.selectSessionView(view),
      sessionCatalogFailed: this.sessionCatalogFailed,
      sessionCatalogLoaded: this.sessionCatalogLoaded,
      sessionLoading: this.sessionLoading,
      sessionView: this.sessionView,
      sessions: this.$sessions,
      setDrawer: (open: boolean): void => this.setDrawer(open),
      showFiles: this.$showFiles,
      showSettings: this.$showSettings,
      sidebarRows: this.sidebarRows,
      statusBarHeight: this.statusBarHeight,
      swipeDrawer: (event: GestureEvent): void => this.swipeDrawer(event),
      toggleSpace: (path: string): void => this.toggleSpace(path),
      updateSessionMeta: (session: SessionRow, pin: boolean): Promise<void> => this.updateSessionMeta(session, pin),
      shareSession: (session: SessionRow): Promise<void> => this.shareSidebarSession(session),
      windowHeight: this.windowHeight,
      workspaces: this.$workspaces,
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
      connectionEpoch: (): number => this.epoch
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
    if (this.showSettings) return false;
    if (!this.keyboardHeight) return true;
    return this.isPaired && this.activeTab !== 'mine' && (this.activeTab !== 'tasks' || this.showFiles);
  }

  @Builder
  statusNotice() {
    Row({ space: 8 }) {
      Text(this.status).fontColor($r('app.color.pigo_warning')).fontSize(13).layoutWeight(1)
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([$r('app.color.pigo_warning')])
      }.width(30).height(30).padding(0).borderRadius(8).backgroundColor(Color.Transparent)
        .accessibilityText('关闭提示').onClick(() => { this.status = ''; })
    }.width('100%').padding({ left: 12, right: 6, top: 8, bottom: 8 })
      .attributeModifier(glassCardSurface(this.darkMode, 14, true))
  }

  @Builder
  textPreviewPage(preview: ReceivedFilePreview) {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.id('text-preview-close').headerAction().attributeModifier(glassButtonSurface(this.darkMode)).accessibilityText('返回').enabled(!this.savingPreview)
          .onClick(() => { this.textFilePreview = undefined; })
        Text(preview.name).id('text-preview-title').layoutWeight(1)
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').height(this.headerHeight())
        .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
      if ((preview.version && !this.editingPath) || preview.localPath || preview.text !== undefined || preview.systemUri) {
        Row({ space: 8 }) {
          if (preview.version && !this.editingPath) {
            Button('编辑').chatAction().id('preview-edit').height(38).enabled(!this.busy && !this.savingPreview)
              .backgroundColor(this.accent()).fontColor(this.accentForeground())
              .onClick(() => { this.editPreview(preview); })
          }
          if (preview.localPath || preview.text !== undefined) {
            Button(this.savingPreview ? '正在保存…' : '保存到本机').chatAction().id('preview-save-local').height(38)
              .enabled(!this.savingPreview).onClick(() => { void this.savePreviewLocally(preview); })
          }
          if (preview.systemUri) {
            Button('系统预览').chatAction().height(38).enabled(!this.savingPreview)
              .onClick(() => { void this.reopenSystemPreview(preview); })
          }
        }.width('100%')
      }
      if (this.previewNotice) {
        Text(this.previewNotice).id('preview-notice').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      if (preview.imageUri) {
        Image(preview.imageUri).id('image-preview').width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
          .accessibilityText(preview.name).onError(() => { void this.imagePreviewError(preview); })
      } else {
        Scroll(this.previewScroller) {
          Column() {
            if (preview.text === undefined) {
              Text(preview.systemUri ? '点击「系统预览」打开文件。' : '已接收文件，可保存到本机。')
                .fontSize(15).fontColor($r('app.color.pigo_muted'))
            } else if (!preview.text.length) {
              Text('空文件').fontSize(15).fontColor($r('app.color.pigo_muted'))
            } else if (preview.markdown) {
              this.richChatText(preview.text, preview.workspaceRoot ?? '', preview.workspacePath ?? '')
            } else {
              Text(preview.text).fontSize(15).lineHeight(24).fontFamily('monospace').fontColor($r('app.color.pigo_text'))
                .width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 16 })
        }.id('text-preview-body').scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off)
          .layoutWeight(1).width('100%').align(Alignment.TopStart)
      }
      if (preview.nextOffset !== undefined || (preview.offset ?? 0) > 0) {
        Row({ space: 8 }) {
          Button('上一页').chatAction().enabled((preview.offset ?? 0) > 0 && !this.savingPreview)
            .onClick(() => { this.changePreviewPage(false); })
          Text(`第 ${this.previewOffsets.length + 1} 页`).fontSize(13).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
            .textAlign(TextAlign.Center)
          Button('下一页').chatAction().enabled(preview.nextOffset !== undefined && !this.savingPreview)
            .onClick(() => { this.changePreviewPage(true); })
        }.width('100%')
      }
    }.id('text-file-preview').width('100%').constraintSize({ maxWidth: preview.imageUri ? 1024 : 840 })
      .height('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: this.statusBarHeight + 8, bottom: this.bottomPad() + 8 })
  }

  @Builder
  markdownTableReaderPage(reader: MarkdownTableReader) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.id('markdown-exit-landscape').headerAction().attributeModifier(glassButtonSurface(this.darkMode)).accessibilityText('退出横屏')
          .onClick(() => { this.closeMarkdownTableReader(); })
        Text('表格').fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).layoutWeight(1)
      }.width('100%').height(this.headerHeight())
        .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
      if (this.markdownRotationUnavailable) {
        Text('当前窗口无法自动横屏，可左右滑动表格。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
      }
      Scroll() {
        Column() {
          this.richChatText(reader.source, reader.cwd, reader.documentPath, false)
        }.width('100%')
      }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
    }.width('100%').height('100%').padding({
      left: 16, right: 16, top: this.statusBarHeight + 8, bottom: this.bottomPad() + 4
    }).backgroundColor(this.themeCanvas()).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
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
        if (!this.loading && this.status) {
          Column() {
            this.statusNotice()
          }.width('100%').padding({
            left: 16,
            right: 16,
            bottom: (this.showRootBottomTabs() ? this.bottomTabsHeight() + 14 : 0) + this.bottomPad() + 8
          }).hitTestBehavior(HitTestMode.Transparent)
        }
      }.width('100%').height('100%')
    }.width('100%').height('100%').constraintSize({ maxWidth: this.activeTab === 'mine' || this.showSettings ? 600 : 840 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .title({ builder: this.pageHeader, height: this.headerHeight() + this.statusBarHeight + 20 }, {
        backgroundColor: Color.Transparent,
        barStyle: BarStyle.STACK
      })
      .hideTitleBar(this.loading || (!this.isPaired && this.activeTab !== 'mine'))
  }

  @Builder
  newSessionDialog() {
    Stack() {
      Button({ type: ButtonType.Normal }).width('100%').height('100%').borderRadius(0).backgroundColor('#66000000')
        .accessibilityText('取消新建会话').enabled(!this.openingSession).onClick(() => { this.closeNewSession(); })
      Scroll() {
        Column({ space: 12 }) {
          Text('新建会话').fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          Row({ space: 8 }) {
            Text('工作区').fontSize(14).fontColor($r('app.color.pigo_muted'))
            if (!this.newSessionFixedWorkspace && this.projects.length > 0) {
              Select(this.projects.map((path: string): SelectOption => ({ value: this.workspaceName(path) })))
                .id('new-session-workspace').layoutWeight(1).selected(this.projects.indexOf(this.newSessionCwd))
                .value(this.newSessionCwd ? this.workspaceName(this.newSessionCwd) : '选择工作区')
                .fontColor($r('app.color.pigo_text')).backgroundColor($r('app.color.pigo_control'))
                .enabled(!this.busy && !this.openingSession)
                .onSelect((index: number) => {
                  this.newSessionCwd = this.projects[index] ?? '';
                  this.newSessionError = '';
                })
            } else {
              Text(this.newSessionCwd ? this.workspaceName(this.newSessionCwd) : '暂无工作区')
                .fontSize(14).fontColor($r('app.color.pigo_text')).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (!this.newSessionFixedWorkspace && this.canCreateWorkspace) {
              Button('新空间').chatAction().height(36).padding({ left: 10, right: 10 })
                .enabled(this.reachable && !this.busy && !this.openingSession)
                .onClick(() => { this.closeNewSession(); this.openNewSpace(); })
            }
          }.width('100%')
          Row({ space: 8 }) {
            Text('Agent').fontSize(14).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
            Button({ type: ButtonType.Normal }) {
              SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(16).fontColor([this.accent()])
            }.id('new-session-refresh').width(44).height(32).padding(0).backgroundColor(Color.Transparent)
              .accessibilityText('刷新 Agent 列表')
              .enabled(this.reachable && !this.busy && !this.openingSession && !this.sessionLoading)
              .onClick(() => { void this.loadSessions(); })
          }.width('100%')
          ForEach(this.agents, (agent: AgentInfo) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                Text(agent.label).fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.pigo_text')).layoutWeight(1)
                if (agent.installed !== true || agent.authed === false) {
                  Text(agent.installed === undefined ? '检测中' : agent.installed ? '请检查登录或配置' : '未安装')
                    .fontSize(12).fontColor($r('app.color.pigo_muted'))
                }
                if (this.newSessionAgent === agent.id) {
                  SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(18).fontColor([this.accent()])
                    .accessibilityLevel('no')
                }
              }.width('100%').padding({ left: 12, right: 12 })
            }.id(`new-session-agent-${agent.id}`).width('100%').height(44).padding(0).borderRadius(12)
              .backgroundColor(this.newSessionAgent === agent.id ? this.accentTint() : $r('app.color.pigo_control'))
              .accessibilitySelected(this.newSessionAgent === agent.id)
              .enabled(agent.installed === true && !this.busy && !this.openingSession)
              .onClick(() => { this.newSessionAgent = agent.id; this.newSessionError = ''; })
          }, (agent: AgentInfo) => `${agent.id}:${agent.label}:${agent.installed}:${agent.authed}`)
          if (this.newSessionError || !this.reachable || this.sessionCatalogFailed || !this.hostAvailable ||
            (this.newSessionFixedWorkspace && !this.projects.includes(this.newSessionCwd))) {
            Text(this.newSessionError || (!this.reachable ? '正在等待电脑连接…' :
              this.sessionCatalogFailed ? '加载失败，请刷新 Agent 列表。' :
              this.sessionLoading ? '正在加载电脑端配置…' : !this.hostAvailable ? '请在电脑上启动 Pi Go 后台服务。' :
              '该工作区已不可用。'))
              .fontSize(13).fontColor($r('app.color.pigo_error')).width('100%')
          }
          Row({ space: 8 }) {
            Button('取消').chatAction().layoutWeight(1)
              .enabled(!this.openingSession).onClick(() => { this.closeNewSession(); })
            Button(this.openingSession ? '正在创建…' : '创建会话').id('new-session-submit').layoutWeight(2)
              .backgroundColor(this.accent()).fontColor(this.accentForeground())
              .enabled(this.canCreateSession()).onClick(() => { void this.createSession(); })
          }.width('100%')
        }.width('100%').padding(18)
      }.width('90%').constraintSize({ maxWidth: 380, maxHeight: this.windowHeight * 0.85 })
        .scrollBar(BarState.Auto).attributeModifier(glassCardSurface(this.darkMode, 20, true))
    }.id('new-session-dialog').width('100%').height('100%')
  }

  @Builder
  newSpaceDialog() {
    Stack() {
      Button({ type: ButtonType.Normal }).width('100%').height('100%').borderRadius(0).backgroundColor('#66000000')
        .accessibilityText('取消新建空间').enabled(!this.busy).onClick(() => { this.closeNewSpace(); })
      Column({ space: 12 }) {
        Text('新空间').fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        TextInput({ text: this.newSpaceName, placeholder: '空间名称' }).id('new-space-name').width('100%')
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .maxLength(80).enterKeyType(EnterKeyType.Done).enabled(!this.busy)
          .onChange((value: string) => { this.newSpaceName = value; this.newSpaceError = ''; })
          .onSubmit(() => { if (this.newSpaceName.trim()) void this.createWorkspaceTask(); })
        if (this.newSpaceError) {
          Text(this.newSpaceError).fontSize(13).fontColor($r('app.color.pigo_error')).width('100%')
        }
        Row({ space: 8 }) {
          Button('取消').layoutWeight(1).backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
            .enabled(!this.busy).onClick(() => { this.closeNewSpace(); })
          Button(this.busy ? '正在创建…' : '创建空间').id('new-space-submit').layoutWeight(2)
            .backgroundColor(this.accent()).fontColor(this.accentForeground())
            .enabled(!this.busy && this.reachable && !!this.newSpaceName.trim())
            .onClick(() => { void this.createWorkspaceTask(); })
        }.width('100%')
      }.width('90%').constraintSize({ maxWidth: 360 }).padding(18)
        .attributeModifier(glassCardSurface(this.darkMode, 20, true))
    }.id('new-space-dialog').width('100%').height('100%')
  }

  @Builder
  runCompletionBanner(notice: RunNotice) {
    Row() {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph(notice.stopped ? $r('sys.symbol.minus_circle') : $r('sys.symbol.checkmark_circle'))
            .fontSize(20).fontColor([this.stateColor(notice.stopped ? 'waiting' : 'streaming')])
        }.width(32).height(32).borderRadius(16).backgroundColor($r('app.color.pigo_control'))
          .accessibilityLevel('no')
        Column({ space: 2 }) {
          Text(notice.stopped ? '运行已停止' : '运行已结束')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          Text(notice.title).fontSize(13).fontColor($r('app.color.pigo_muted'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
        }.id('run-completion-dismiss').width(44).height(44).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('关闭运行通知').onClick(() => { this.advanceRunNotice(); })
      }.id('run-completion-banner').width('100%').constraintSize({ maxWidth: 440 })
        .padding({ left: 14, right: 4, top: 6, bottom: 6 })
        .attributeModifier(glassCardSurface(this.darkMode, 16, true))
    }.width('100%').justifyContent(FlexAlign.Center).padding({ left: 16, right: 16 })
      .margin({ top: this.statusBarHeight + 8 }).hitTestBehavior(HitTestMode.Transparent)
      .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
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
        action: () => { void this.updateSchedule('delete', job); }
      }
    });
  }

  private scheduleJobMenu(job: ScheduleJob): MenuElement[] {
    const options: MenuElement[] = [
      { value: '编辑', action: () => { this.editSchedule(job); } },
      { value: '立即运行', action: () => { void this.updateSchedule('run', job); } },
      { value: '删除', action: () => { this.confirmDeleteSchedule(job); } }
    ];
    if (job.nextAt !== null || !job.enabled) options.splice(1, 0, {
      value: job.enabled ? '暂停' : '启用',
      action: () => { void this.updateSchedule(job.enabled ? 'pause' : 'resume', job); }
    });
    return options;
  }

  private openScheduleTimePicker(): void {
    this.dismissKeyboard();
    if (this.scheduleKind === 'once') {
      const parsed = parseScheduleTime(this.scheduleWhen.trim());
      const selected = parsed > 0 ? new Date(parsed) : new Date(Date.now() + 120_000);
      this.getUIContext().showDatePickerDialog({
        start: new Date(Date.now() - 86_400_000),
        end: new Date(Date.now() + 5 * 365 * 86_400_000),
        selected: selected,
        showTime: true,
        useMilitaryTime: true,
        onDateAccept: (value: Date) => {
          this.scheduleWhen = scheduleTime(value.getTime());
        }
      });
    } else if (this.scheduleKind === 'daily') {
      const selected = new Date();
      const match = /^(\d{1,2}):(\d{2})$/.exec(this.scheduleWhen.trim());
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
          this.scheduleWhen = `${hh}:${mm}`;
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
        if (this.scheduleMessages.some((item: RunMessage): boolean => item.unread) || this.inboxRuns.some((item: InboxRun): boolean => item.unread)) {
          Blank().width(8).height(8).borderRadius(4).backgroundColor(this.accent())
            .margin({ top: 9, right: 9 })
        }
      }.width('100%').height('100%')
    }.id('schedule-inbox').headerAction().attributeModifier(immersiveSurface(this.darkMode)).accessibilityText(this.scheduleMessages.some((item: RunMessage): boolean =>
      item.unread) || this.inboxRuns.some((item: InboxRun): boolean => item.unread) ? '收件箱，有未读消息' : '收件箱')
      .onClick(() => { this.showScheduleInbox(); })
  }

  @Builder
  scheduleOverlay() {
    ScheduleOverlay({
      backFromSchedule: (): void => this.backFromSchedule(),
      base: this.base,
      busy: this.busy,
      computers: this.$computers,
      deleteScheduleRuns: (messages: RunMessage[]): Promise<boolean> => this.deleteScheduleRuns(messages),
      dismissInboxRuns: (ids: string[]): Promise<boolean> => this.dismissInboxRuns(ids),
      dismissScheduleMessage: (message: RunMessage): void => this.dismissScheduleMessage(message),
      isPaired: this.isPaired,
      openScheduleTimePicker: (): void => this.openScheduleTimePicker(),
      openScheduledSession: (message: RunMessage): Promise<void> => this.openScheduledSession(message),
      openingSession: this.openingSession,
      inboxRuns: this.displayedInboxRuns(),
      openInboxRun: (row: InboxRun): Promise<void> => this.openInboxRun(row),
      pushEnabled: this.pushEnabled,
      pushSaving: this.pushSaving,
      pushStatus: this.pushStatus,
      setPushEnabled: (enabled: boolean): Promise<void> => this.setPushEnabled(enabled),
      projects: this.$projects,
      scheduleCatchUp: this.$scheduleCatchUp,
      scheduleCwd: this.$scheduleCwd,
      scheduleDetail: this.scheduleDetail,
      scheduleEditing: this.scheduleEditing,
      scheduleError: this.scheduleError,
      scheduleKind: this.$scheduleKind,
      scheduleMessages: this.$scheduleMessages,
      scheduleName: this.$scheduleName,
      scheduleOffline: this.$scheduleOffline,
      schedulePage: this.schedulePage,
      schedulePrompt: this.$schedulePrompt,
      scheduleSaving: this.scheduleSaving || this.inboxCleaning,
      scheduleWhen: this.$scheduleWhen,
      scheduleZone: this.scheduleZone,
      showScheduleDetail: (message: RunMessage): void => this.showScheduleDetail(message),
      statusBarHeight: this.statusBarHeight,
      updateSchedule: (operation: string, job?: ScheduleJob): Promise<void> => this.updateSchedule(operation, job),
      workspaces: this.$workspaces,
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

  @Builder
  scheduledRunBanner(message: RunMessage) {
    Row({ space: 6 }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 2 }) {
          Text(`${message.run.name} · ${scheduleRunStatus(message.run.status)}`).fontSize(15)
            .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(message.computer).fontSize(13).fontColor($r('app.color.pigo_muted'))
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).height(48).padding({ left: 12 }).backgroundColor(Color.Transparent)
        .onClick(() => { this.showScheduleDetail(message); })
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
      }.width(40).height(40).padding(0).borderRadius(10).backgroundColor(Color.Transparent)
        .accessibilityText('关闭定时任务通知').onClick(() => { this.scheduleBanner = undefined; })
    }.id('schedule-completion-banner').width('92%').constraintSize({ maxWidth: 440 }).padding(6)
      .attributeModifier(glassCardSurface(this.darkMode, 16, true))
  }

  private sakuraConversationFocus(): boolean {
    return this.activeTab !== 'mine' &&
      (this.messages.length > 0 || !!this.liveText || !!this.liveThinking || this.liveTools.length > 0);
  }

  private sakuraGirlInteractive(): boolean {
    return this.themeId === 'sakura' && this.activeTab === 'tasks' && !this.showFiles && !this.showSettings &&
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
    if (!this.themeMotionEnabled || this.recording || this.holdActive || this.sessionPaneDragging || this.drawerOpen()) return;
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

  @Builder
  sakuraGirlHitZone() {
    Blank()
      .width(175)
      .height(210)
      .margin({ right: 6, bottom: this.noSession ? this.bottomContentClearance() : this.chatBottomClearance() })
      .onClick(() => { this.tapSakuraGirl(); })
  }

  private staticThemeWallpaper(): Resource {
    if (this.themeId === 'graphite') return $rawfile(this.darkMode ? 'ink_dark.jpg' : 'ink_light.jpg');
    if (this.themeId === 'sunset') return $rawfile(this.darkMode ? 'sunset_dark.jpg' : 'sunset_light.jpg');
    return $rawfile(this.darkMode ? 'sakura_dark.jpg' : 'sakura_light.jpg');
  }

  @Builder
  themeBackdrop() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .radialGradient({
          center: ['16%', '10%'],
          radius: '78%',
          colors: [[this.palette().auraTop, 0], ['#00000000', 1]]
        })
      Column()
        .width('100%').height('100%')
        .radialGradient({
          center: ['86%', '86%'],
          radius: '74%',
          colors: [[this.palette().auraBottom, 0], ['#00000000', 1]]
        })
      if (!this.themeMotionEnabled) {
        Image(this.staticThemeWallpaper())
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.sakuraConversationFocus()
            ? (this.darkMode ? 0.56 : 0.60)
            : (this.darkMode ? 0.90 : 0.94))
        if (this.sakuraConversationFocus()) {
          Column()
            .width('100%').height('100%')
            .linearGradient({
              angle: 90,
              colors: this.themeId === 'graphite'
                ? (this.darkMode ? [['#B8111317', 0], ['#8A111317', 0.62], ['#24111317', 1]] : [['#C4F6F5F0', 0], ['#96F6F5F0', 0.62], ['#26F6F5F0', 1]])
                : this.themeId === 'sunset'
                  ? (this.darkMode ? [['#B81A1210', 0], ['#8A1A1210', 0.62], ['#241A1210', 1]] : [['#C4FDF6F2', 0], ['#96FDF6F2', 0.62], ['#26FDF6F2', 1]])
                  : (this.darkMode ? [['#B81C1217', 0], ['#8A1C1217', 0.62], ['#261C1217', 1]] : [['#C4FFF6F9', 0], ['#96FFF6F9', 0.62], ['#28FFF6F9', 1]])
            })
        }
      } else if (this.themeId === 'sakura') {
        SakuraScene({
          darkMode: this.darkMode,
          dimmed: this.sakuraConversationFocus(),
          active: this.visible,
          girlTapSeq: this.sakuraGirlTapSeq,
          celebrateSeq: this.sakuraCelebrateSeq,
          burstSeq: this.sakuraBurstSeq,
          burstKind: this.sakuraBurstKind,
          bloomSeq: this.sakuraBloomSeq,
          bloomX: this.sakuraBloomX,
          bloomY: this.sakuraBloomY,
          sceneOpacity: this.sakuraConversationFocus()
            ? (this.darkMode ? 0.56 : 0.60)
            : (this.darkMode ? 0.88 : 0.92)
        })
        if (this.sakuraConversationFocus()) {
          Column()
            .width('100%').height('100%')
            .linearGradient({
              angle: 90,
              colors: this.darkMode
                ? [['#B81C1217', 0], ['#8A1C1217', 0.62], ['#261C1217', 1]]
                : [['#C4FFF6F9', 0], ['#96FFF6F9', 0.62], ['#28FFF6F9', 1]]
            })
        }
      } else if (this.themeId === 'graphite') {
        InkScene({
          darkMode: this.darkMode,
          dimmed: this.sakuraConversationFocus(),
          active: this.visible,
          burstSeq: this.sakuraBurstSeq,
          burstKind: this.sakuraBurstKind,
          tapSeq: this.sakuraBloomSeq,
          tapX: this.sakuraBloomX,
          tapY: this.sakuraBloomY,
          sceneOpacity: this.sakuraConversationFocus()
            ? (this.darkMode ? 0.56 : 0.60)
            : (this.darkMode ? 0.90 : 0.94)
        })
        if (this.sakuraConversationFocus()) {
          Column()
            .width('100%').height('100%')
            .linearGradient({
              angle: 90,
              colors: this.darkMode
                ? [['#B8111317', 0], ['#8A111317', 0.62], ['#24111317', 1]]
                : [['#C4F6F5F0', 0], ['#96F6F5F0', 0.62], ['#26F6F5F0', 1]]
            })
        }
      } else if (this.themeId === 'sunset') {
        SunsetScene({
          darkMode: this.darkMode,
          dimmed: this.sakuraConversationFocus(),
          active: this.visible,
          burstSeq: this.sakuraBurstSeq,
          burstKind: this.sakuraBurstKind,
          tapSeq: this.sakuraBloomSeq,
          tapX: this.sakuraBloomX,
          tapY: this.sakuraBloomY,
          sceneOpacity: this.sakuraConversationFocus()
            ? (this.darkMode ? 0.56 : 0.60)
            : (this.darkMode ? 0.90 : 0.94)
        })
        if (this.sakuraConversationFocus()) {
          Column()
            .width('100%').height('100%')
            .linearGradient({
              angle: 90,
              colors: this.darkMode
                ? [['#B81A1210', 0], ['#8A1A1210', 0.62], ['#241A1210', 1]]
                : [['#C4FDF6F2', 0], ['#96FDF6F2', 0.62], ['#26FDF6F2', 1]]
            })
        }
      }
    }.width('100%').height(this.windowHeight).position({ x: 0, y: 0 }).hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        // Reserve the sidebar's space without rebuilding the conversation or moving the session list.
        Blank().width(this.dockedSessions() ? this.sessionPaneWidth() : 0)
        Stack({ alignContent: Alignment.Bottom }) {
          // Keep the wallpaper at window height while the keyboard resizes the conversation.
          this.themeBackdrop()
          this.mainNavigation()
          if (this.sakuraGirlInteractive()) {
            Row() {
              this.sakuraGirlHitZone()
            }.width('100%').justifyContent(FlexAlign.End).hitTestBehavior(HitTestMode.Transparent)
          }
        }.height('100%').layoutWeight(1)
          .onTouch((event: TouchEvent) => { this.observeThemeTap(event); })
          .onGestureJudgeBegin(() => this.dockedSessions() || this.showSessions || this.holdActive || this.recording ||
            this.voicePreparing || this.voiceFinishing || !this.isPaired || this.activeTab === 'mine'
            ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
          .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
      }.width('100%').height('100%').backgroundColor(this.themeCanvas())
        .borderRadius({ topLeft: this.drawerOpen() ? 24 : 0, bottomLeft: this.drawerOpen() ? 24 : 0 })
        .clip(true).translate({ x: this.drawerOpen() ? 36 : 0 })
        .accessibilityLevel(this.drawerOpen() || this.schedulePage ? 'no-hide-descendants' : 'auto')
      if (this.drawerOpen()) {
        Button({ type: ButtonType.Normal }).width('100%').height('100%').padding(0)
          .backgroundColor(this.darkMode ? '#52000000' : '#2E0F1722').borderRadius(0)
          .accessibilityText('关闭会话列表').onClick(() => { this.setDrawer(false); })
          .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
      }
      if (this.dockedSessions() || this.drawerOpen()) {
        this.sessionDrawer()
      }
      if (this.dockedSessions()) this.sessionPaneHandle()
      if (this.recording || this.voicePreparing || (this.voiceFinishing && !this.voiceCancelling) || this.voiceHint) {
        Column() {
          Column({ space: 16 }) {
            if (this.recording) {
              SymbolGlyph(this.holdCancel ? $r('sys.symbol.xmark') : $r('sys.symbol.mic'))
                .fontSize(38).fontColor([this.holdCancel ? '#FFFFFF' : $r('app.color.pigo_text')])
              Text(this.holdCancel ? '松开手指，取消发送' : '手指上滑，取消发送')
                .fontSize(15).fontColor(this.holdCancel ? '#FFFFFF' : $r('app.color.pigo_text'))
              Text(this.recordSeconds >= 50 ? `还可说 ${60 - this.recordSeconds} 秒` : `${this.recordSeconds}″`)
                .fontSize(13).fontColor(this.holdCancel ? '#FFFFFF' : $r('app.color.pigo_muted'))
              if (this.liveVoiceText && !this.holdCancel) {
                Text(this.liveVoiceText).fontSize(14).fontColor($r('app.color.pigo_text')).maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
              }
            } else if (this.voicePreparing || (this.voiceFinishing && !this.voiceCancelling && !this.voiceHint)) {
              LoadingProgress().width(36).height(36).color($r('app.color.pigo_text'))
              Text(this.voicePreparing ? '正在准备麦克风…' : '正在转为文字…').fontSize(15).fontColor($r('app.color.pigo_text'))
            } else {
              Text(this.voiceHint).fontSize(15).fontColor($r('app.color.pigo_text')).textAlign(TextAlign.Center)
            }
          }.id('voice-feedback').width(250).padding(26).alignItems(HorizontalAlign.Center)
            .borderRadius(20).backgroundColor(this.holdCancel ? '#B74747' : $r('app.color.pigo_control'))
            .attributeModifier(this.holdCancel ? undefined : glassCardSurface(this.darkMode, 20, true))
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.editingPath || this.textFilePreview) {
        Stack({ alignContent: Alignment.Top }) {
          if (this.editingPath) this.fileEditorPage()
          if (this.textFilePreview) {
            Stack({ alignContent: Alignment.Top }) {
              this.textPreviewPage(this.textFilePreview)
            }.width('100%').height('100%').backgroundColor(this.themeCanvas())
              .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
          }
        }.width('100%').height('100%').backgroundColor(this.themeCanvas())
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
      }
      if (this.markdownTableReader) this.markdownTableReaderPage(this.markdownTableReader)
      if (this.showNewSession) this.newSessionDialog()
      if (this.showNewSpace) this.newSpaceDialog()
      if (this.runNotice) this.runCompletionBanner(this.runNotice)
      if (this.scheduleBanner && !this.schedulePage && !this.runNotice) {
        Row() {
          this.scheduledRunBanner(this.scheduleBanner)
        }.width('100%').justifyContent(FlexAlign.Center)
          .margin({ top: this.statusBarHeight + this.headerHeight() + 10 }).hitTestBehavior(HitTestMode.Transparent)
      }
      if (this.schedulePage) this.scheduleOverlay()
      if (this.reviewedRun) {
        RunResultView({
          result: this.reviewedRun, file: this.reviewedFile, patch: this.reviewPatch,
          loading: this.reviewLoading, error: this.reviewError,
          themeId: this.themeId, darkMode: this.darkMode, top: this.statusBarHeight, bottom: this.bottomPad(),
          back: (): void => this.backFromRunResult(),
          openDiff: (file: RunFile): void => { void this.openRunDiff(file); },
          openArtifact: (file: RunFile): void => { void this.openRunArtifact(file); },
          loadScreenshot: (image: RunScreenshot): Promise<string> =>
            this.loadHistoryImage(this.reviewedRun?.sessionId ?? '', image.messageId, 0, image.toolId),
          openScreenshot: (source: string, label: string): void => {
            this.reviewedRun = undefined;
            this.showChatImage(source, label);
          },
          citeLine: (line: DiffLine): void => this.citeRunLine(line)
        })
      }
      if (this.showIncomingShare()) {
        Row() {
          this.incomingShareBanner()
        }.width('100%').justifyContent(FlexAlign.Center)
          .margin({ top: this.statusBarHeight + this.headerHeight() + 8 }).hitTestBehavior(HitTestMode.Transparent)
      }
    }.width('100%').height('100%').padding({ left: this.leftInset, right: this.rightInset })
      .backgroundColor(this.drawerOpen() ? $r('app.color.pigo_sidebar') : this.themeCanvas())
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
