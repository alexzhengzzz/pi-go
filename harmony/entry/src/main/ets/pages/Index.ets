import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { ChatContent } from '../ChatContent';
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
import { Companion, CredentialVault, SIDEBAR_MAX_EXPANDED, SIDEBAR_MAX_ENTRIES, SIDEBAR_VIEWS, SidebarBook, SidebarEntry, SidebarState } from '../CredentialVault';
import { discoverLan } from '../LanDiscovery';
import { choosePromptImage, capturePromptImage, PromptImage } from '../PromptImage';
import { choosePromptFiles, PromptFile, MAX_FILES } from '../PromptFile';
import { ensureMicrophone, VoiceInputSession, voiceInputSupported } from '../VoiceInput';
import { APPEARANCE_MODES, AppearanceMode, THEME_STYLES, ThemeStyle, appearanceMode, openSettings, themeStyle } from '../Appearance';
import { HuaweiProfile, authorizeHuaweiProfile, isHuaweiProfileCurrent } from '../HuaweiProfile';
import { AccountSync, CloudComputer, SyncRow, SyncSnapshot, SYNC_MODE, SYNC_THEME, computerSyncRow } from '../AccountSync';
import { immersiveSurface } from '../Immersive';
import { HISTORY_IMAGE_EXTENSIONS, isImageFile, markdownWorkspacePath, messageFileChips, normalizeWorkspacePath, safeLocalFileName, textPreviewFormat } from '../ChatPaths';
import { decodePairingBundle, validSecureAddress, validUsb } from '../PairingCode';
import { SequencedFrame, SessionSync, SyncCursor } from '../SessionSync';
import { connectionLabel, validCompanion } from '../CompanionCheck';
import { ComputerGroup, computerGroupId, computerGroups, computerGroupTitle, moveComputerConnection, renameComputerGroup, withComputerAssignment } from '../ComputerGroups';
import { liveActivity } from '../LiveActivity';
import { ScheduleJob, ScheduleRun, ScheduleWatch, RunMessage, scheduleTime, parseScheduleTime,
  scheduleRunStatus, scheduleRunReason } from '../ScheduledRuns';

interface ModelOption {
  provider: string;
  id: string;
  name: string;
  image: boolean;
  levels: string[];
  thinkingLevel?: string;
}

interface BridgeEndpoint {
  address: string;
  token: string;
  ca?: string;
  pin?: string;
}

interface SessionState {
  id: string;
  cwd: string;
  name?: string;
  idle: boolean;
  runId?: string | null;
  queued?: boolean;
  acceptsImage?: boolean;
  model?: ModelOption;
  thinkingLevel?: string;
}

interface SessionRow {
  revision: number;
  pinned?: boolean;
  archived?: boolean;
  lastVisited?: string;
  id: string;
  name?: string;
  cwd?: string;
  active?: boolean;
  occupied?: boolean;
  modified: string;
  messageCount: number;
}

interface SidebarRow {
  key: string;
  path?: string;
  session?: SessionRow;
  nested: boolean;
}

class SidebarRows implements IDataSource {
  private rows: SidebarRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.rows.length; }
  getData(index: number): SidebarRow { return this.rows[index]; }
  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener): boolean => item !== listener);
  }
  replace(rows: SidebarRow[]): void {
    if (this.rows.length === rows.length && this.rows.every((row: SidebarRow, index: number): boolean => row.key === rows[index].key)) return;
    this.rows = rows;
    for (const listener of this.listeners) listener.onDataReloaded();
  }
  anchor(sessionId: string, workspace: string): number {
    const session = this.rows.findIndex((row: SidebarRow): boolean => row.session?.id === sessionId);
    return session >= 0 ? session : this.rows.findIndex((row: SidebarRow): boolean => row.path === workspace);
  }
}

interface ChatMessage {
  id: string;
  role: string;
  text: string;
  textTruncated?: boolean;
  imageCount?: number;
  thinking?: string;
  thinkingMs?: number;
  tools?: LiveTool[];
}

interface DraftAttachment {
  kind: string;
  name: string;
  size: number;
  image?: PromptImage;
  file?: PromptFile;
}

interface AttachmentRef {
  token: string;
  kind: string;
}

interface UploadedAttachment {
  token: string;
  kind?: string;
  name?: string;
  size?: number;
  path?: string;
}

interface LiveTool {
  id: string;
  name: string;
  detail: string;
  state: string;
  ms?: number;
}

interface ToolDetails {
  input: string;
  output: string;
  command: boolean;
  imageCount?: number;
  truncated: boolean;
  state: string;
  path?: string;
}

interface CommandRow {
  name: string;
  description?: string;
  source?: string;
  invoke?: string;
}

interface ReceivedFilePreview {
  name: string;
  text?: string;
  markdown?: boolean;
  localPath?: string;
  systemUri?: string;
  imageUri?: string;
  workspaceRoot?: string;
  workspacePath?: string;
  version?: string;
  offset?: number;
  nextOffset?: number;
}

interface MarkdownTableReader {
  source: string;
  cwd: string;
  documentPath: string;
}

interface StreamFrame extends SequencedFrame {
  type: string;
  sessionId?: string;
  session?: SessionState;
  idle?: boolean;
  aborted?: boolean;
  runId?: string;
  queued?: boolean;
  text?: string;
  seq?: number;
  thinkingSeq?: number;
  reason?: string;
  requestId?: string;
  tool?: LiveTool;
  state?: string;
}

interface PendingInteraction {
  id: string;
  method: string;
  title?: string;
  message?: string;
  options?: string[];
  placeholder?: string;
  prefill?: string;
}

interface FileEntry {
  name: string;
  path: string;
  kind: string;
}

interface FileDirectory {
  entries: FileEntry[];
  nextCursor?: number;
  expanded: boolean;
}

interface FileTreeRow {
  path: string;
  name: string;
  kind: string;
  depth: number;
  expanded?: boolean;
}

interface RunningRow {
  id: string;
  name?: string;
  cwd?: string;
  state?: string;
  started?: boolean;
}

interface RunNotice {
  title: string;
  stopped: boolean;
}

interface WorkspaceRow {
  cwd: string;
  name: string;
}

interface BridgeReply {
  source?: string;
  watching?: boolean;
  jobs?: ScheduleJob[];
  runs?: ScheduleRun[];
  activeRuns?: ScheduleRun[];
  timezone?: string;
  cursor?: SyncCursor;
  historyLeaf?: string | null;
  attachment?: UploadedAttachment;
  commands?: CommandRow[];
  runningSessionIds?: string[];
  runningSessions?: RunningRow[];
  idleSessionIds?: string[];
  path?: string;
  entries?: FileEntry[];
  text?: string;
  version?: string;
  models?: ModelOption[];
  current?: ModelOption;
  dispatched?: boolean;
  interaction?: PendingInteraction;
  state?: string;
  deletedSessionId?: string;
  desktopHandoff?: boolean; // Bridge field for daemon availability.
  canCreateWorkspace?: boolean;
  cwd?: string;
  projects?: string[];
  workspaces?: WorkspaceRow[];
  token?: string;
  error?: string;
  session?: SessionState;
  sessions?: SessionRow[];
  total?: number;
  nextCursor?: number;
  messages?: ChatMessage[];
  historyCursor?: string;
  nextTextOffset?: number;
  liveText?: string;
  liveSeq?: number;
  liveThinking?: string;
  liveThinkSeq?: number;
  tools?: LiveTool[];
  toolDetail?: ToolDetails;
  image?: HistoryImage;
  promptError?: string;
}

interface HistoryImage {
  mimeType: string;
  data: string;
}

interface Payload {
  includeJobs?: boolean;
  knownRuns?: string[];
  operation?: string;
  scheduleVersion?: number;
  prompt?: string;
  kind?: string;
  time?: string;
  at?: number;
  interval?: number;
  catchUp?: number;
  history?: boolean;
  path?: string;
  lookup?: string;
  cursor?: number;
  version?: string;
  revision?: number;
  pinned?: boolean;
  archived?: boolean;
  name?: string;
  provider?: string;
  modelId?: string;
  thinkingLevel?: string;
  image?: string;
  attachments?: AttachmentRef[];
  runId?: string;
  mode?: string;
  pendingId?: string;
  answer?: boolean | string;
  ticket?: string;
  cwd?: string;
  id?: string;
  requestId?: string;
  text?: string;
}

interface PendingSend {
  requestId: string;
  text: string;
  attachments: DraftAttachment[];
  steeringAfter?: string;
}

interface QueuedSteering {
  id: string;
  sessionKey: string;
  afterId: string;
  text: string;
  imageCount: number;
  files: string[];
}

const MAX_COMPUTERS = 12;
const MAX_IMAGE_ATTACHMENTS = 4;
const MAX_TOTAL_IMAGE_DRAFTS = 8;
const MAX_TOTAL_FILE_DRAFTS = 3;
const USB_ADDRESS = 'http://127.0.0.1:18977';
const MAX_VOICE_MS = 60000;
const MIN_HOLD_MS = 400;
const RECEIVED_FILE_DIR = 'pigo-files';
const RECEIVED_FILE_TTL_S = 7 * 24 * 3600;
const STREAM_PAINT_INTERVAL_MS = 32;
const MAX_LIVE_TEXT_LENGTH = 16000;
const MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024;
const MAX_INLINE_IMAGE_BYTES = 8 * 1024 * 1024;
const SPLIT_WINDOW_WIDTH = 600;
const SHORT_WINDOW_HEIGHT = 480;
const MAX_DOWNLOAD_ERROR_BYTES = 4096;
const MAX_TEXT_PREVIEW_BYTES = 128 * 1024;
const RUN_NOTICE_SETTING = 'run_completion_notices';
const LIVE_VIEW_SETTING = 'agent_live_view';

class BridgeFailure extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

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
  private currentLevel: string = 'off';
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
  private workspaceCwd: string = '';
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
  @State private renameDraft: string = '';
  @State private models: ModelOption[] = [];
  @State private selectedModel: number = -1;
  @State private selectedLevel: string = 'off';
  @State private modelLabel: string = '';
  @State private currentId: string = '';
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
  private syncMode: string = 'probe';
  private readonly sessionSync: SessionSync<StreamFrame> = new SessionSync<StreamFrame>();
  private historyStream: string = '';
  private historyLeaf?: string | null;
  private historyLoadingEpoch?: number;
  private historyRequest: number = 0;
  private deltaPaintTimer: number = -1;
  private pendingLiveText: string = '';
  private pendingLiveThinking: string = '';
  @State private streamAlive: boolean = false;
  private streamReq?: http.HttpRequest = undefined;
  private streamTimer: number = -1;
  private streamGen: number = 0;
  @State private historyCursor?: string = undefined;
  @State @Watch('updateSidebarRows') private sessions: SessionRow[] = [];
  @State private runningSessionIds: string[] = [];
  @State private runningSessions: RunningRow[] = [];
  private readonly observedRuns: Map<string, string> = new Map<string, string>();
  @State private runNotice?: RunNotice = undefined;
  private pendingRunNotices: RunNotice[] = [];
  private runNoticeTimer: number = -1;
  private sessionStatusAt: number = 0;
  private runningCatalogAt: number = 0;
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
  @State private themeId: string = 'mint';
  @State private modeId: string = 'system';
  @State private runNoticesEnabled: boolean = true;
  @State private liveViewsEnabled: boolean = true;
  @State private liveViewStatus: string = '';
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
  @State @Watch('updateSidebarRows') private projects: string[] = [];
  @State @Watch('updateSidebarRows') private workspaces: WorkspaceRow[] = [];
  @State @Watch('updateSidebarRows') private hasWorkspaceDetails: boolean = false;
  private base: string = '';
  private token: string = '';
  private ca?: string;
  private pin?: string;
  private epoch: number = 0;
  private timer: number = -1;
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
  private commandRequest: number = 0;
  private commandsLoadedAt: number = 0;
  private sessionCatalogVersion: number = 0;
  private sidebarBook: SidebarBook = { version: 1, entries: [] };
  private sidebarSaveTimer: number = -1;
  private vault?: CredentialVault;
  private readonly drafts: Map<string, string> = new Map<string, string>();
  private readonly unconfirmed: Map<string, PendingSend> = new Map<string, PendingSend>();
  private readonly draftAttachments: Map<string, DraftAttachment[]> = new Map<string, DraftAttachment[]>();
  private readonly transcript: Scroller = new Scroller();
  private transcriptContentHeight: number = 0;
  private transcriptViewport: number = 0;
  @State private transcriptFollow: boolean = true;
  private readonly library: Scroller = new Scroller();
  private readonly sidebarRows: SidebarRows = new SidebarRows();
  private pendingLibraryReveal: boolean = false;
  private readonly chatCache: Map<string, BridgeReply> = new Map<string, BridgeReply>();

  onBackPress(): boolean {
    if (this.markdownTableReader) { this.closeMarkdownTableReader(); return true; }
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
    void this.restoreChain.then(() => { this.queueScheduleSync(true); });
    this.schedule(0);
    this.startStream();
    this.syncLiveActivity();
    void this.consumeLiveActivityLaunch();
    void this.checkHuaweiProfile().then(() => { this.scheduleCloudSync(0); });
  }
  onPageHide(): void {
    this.visible = false;
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
    this.flushSidebarSave();
  }
  aboutToDisappear(): void {
    if (this.markdownTableReader) this.closeMarkdownTableReader();
    this.visible = false;
    this.stopScheduleSync();
    this.clearRunNotices();
    this.cancelSchedule();
    this.stopStream();
    liveActivity.sync(undefined);
    this.stopRecordClock();
    this.resetVoice();
    this.flushSidebarSave();
  }

  private async restore(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context) { this.loading = false; return; }
    const epoch = this.epoch;
    try {
      this.vault = await CredentialVault.open(context);
      this.sidebarBook = await this.vault.loadSidebar();
      const saved = await this.vault.load();
      if (!saved || epoch !== this.epoch) return;
      const seen = new Set<string>();
      this.computers = saved.computers.filter((record: Companion): boolean => {
        if (!validCompanion(record) || seen.has(record.address)) return false;
        seen.add(record.address);
        return true;
      }).slice(0, MAX_COMPUTERS).map((record: Companion): Companion => record.computerId ? record :
        withComputerAssignment(record, util.generateRandomUUID(), record.computerName));
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
    this.syncMode = 'probe';
    this.historyStream = '';
    this.historyLeaf = undefined;
    this.base = record.address;
    this.token = record.token;
    this.pairingMode = usb ? 'usb' : connectionLabel(record) === '公网' ? 'remote' : 'lan';
    if (usb) this.address = record.address;
    this.ca = usb ? undefined : record.ca;
    this.pin = usb ? undefined : record.pin;
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
    this.sessionCatalogLoaded = false;
    this.applySidebar(record.address);
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
    if (this.timer !== -1) clearTimeout(this.timer);
    this.timer = -1;
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

  private showScheduleInbox(): void {
    this.dismissKeyboard();
    this.scheduleBanner = undefined;
    this.schedulePage = 'inbox';
    this.queueScheduleSync(true);
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
    if (this.scheduleSaving) return;
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

  private schedule(delay: number): void {
    this.cancelSchedule();
    if (!this.isPaired || (!this.visible && !this.backgroundLiveActivity())) return;
    this.timer = setTimeout(() => { void this.poll(); }, delay);
  }

  private async request(path: string, input?: Payload, endpoint?: BridgeEndpoint): Promise<BridgeReply> {
    const req = http.createHttp();
    const address = endpoint ? endpoint.address : this.base;
    const token = endpoint ? endpoint.token : this.token;
    const ca = endpoint ? endpoint.ca : this.ca;
    const pin = endpoint ? endpoint.pin : this.pin;
    const imageRequest = path.startsWith('/message-image?');
    const remoteCatalog = path.startsWith('/sessions?') && ca !== undefined && pin !== undefined &&
      validSecureAddress(address, ca, pin, true);
    const slowRequest = path === '/open' || path === '/new' || path === '/create-workspace' || path === '/close-workspace';
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (input) headers['Content-Type'] = 'application/json';
    try {
      const opts: http.HttpRequestOptions = {
        method: input ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        usingProxy: false,
        maxRedirects: 0,
        connectTimeout: remoteCatalog ? 6000 : 2500,
        readTimeout: remoteCatalog ? 20000 : (slowRequest ? 16000 : 6500)
      };
      if (ca && pin) {
        opts.caData = ca;
        opts.certificatePinning = { hashAlgorithm: 'SHA-256', publicKeyHash: pin };
      }
      if (input) opts.extraData = JSON.stringify(input);
      const response = await req.request(`${address}${path}`, opts);
      const reply = JSON.parse(response.result as string) as BridgeReply;
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new BridgeFailure(response.responseCode, reply.error ?? 'request_failed');
      }
      return reply;
    } finally { req.destroy(); }
  }

  private stopStream(): void {
    this.sessionSync.disconnect();
    this.historyRequest += 1;
    this.historyLoadingEpoch = undefined;
    this.streamGen += 1;
    this.flushStreamDeltas();
    if (this.streamTimer !== -1) { clearTimeout(this.streamTimer); this.streamTimer = -1; }
    const req = this.streamReq;
    this.streamReq = undefined;
    this.streamAlive = false;
    if (req) req.destroy();
  }

  private scheduleStream(delay: number): void {
    if (this.streamTimer !== -1) clearTimeout(this.streamTimer);
    this.streamTimer = -1;
    if (!this.isPaired || (!this.visible && !this.backgroundLiveActivity()) || !this.base || !this.token) return;
    this.streamTimer = setTimeout(() => { this.startStream(); }, delay);
  }

  private streamDown(gen: number, delay: number): void {
    if (gen !== this.streamGen) return;
    this.sessionSync.disconnect();
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
    if (!this.isPaired || (!this.visible && !this.backgroundLiveActivity()) || !this.base || !this.token || this.streamReq ||
        this.syncMode === 'probe' || (this.syncMode === 'sequenced' && this.openingSession)) return;
    const gen = ++this.streamGen;
    const req = http.createHttp();
    this.streamReq = req;
    const headers: Record<string, string> = { 'Authorization': `Bearer ${this.token}`, 'Accept': 'text/event-stream' };
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      usingCache: false,
      usingProxy: false,
      maxRedirects: 0,
      connectTimeout: 4000,
      readTimeout: 30000
    };
    if (this.ca && this.pin) {
      opts.caData = this.ca;
      opts.certificatePinning = { hashAlgorithm: 'SHA-256', publicKeyHash: this.pin };
    }
    let buffer = '';
    const decoder = new util.TextDecoder('utf-8');
    req.on('headersReceive', (_header: Object) => {
      if (gen !== this.streamGen) return;
      this.streamAlive = true;
    });
    req.on('dataReceive', (data: ArrayBuffer) => {
      if (gen !== this.streamGen) return;
      buffer += decoder.decodeWithStream(new Uint8Array(data), { stream: true });
      if (buffer.length > 262144) {
        this.streamDown(gen, 500);
        return;
      }
      let boundary = buffer.indexOf('\n\n');
      while (boundary >= 0) {
        const raw = buffer.substring(0, boundary);
        buffer = buffer.substring(boundary + 2);
        let payload = '';
        for (const line of raw.split('\n')) {
          if (line.startsWith('data: ')) payload += line.substring(6);
        }
        if (payload) this.handleFrame(payload);
        if (gen !== this.streamGen) return;
        boundary = buffer.indexOf('\n\n');
      }
    });
    req.on('dataEnd', () => { this.streamDown(gen, 2000); });
    const path = this.syncMode === 'sequenced' ? '/events?sync=2' : '/events';
    req.requestInStream(`${this.base}${path}`, opts).then((code: number) => {
      if (gen !== this.streamGen) return;
      if (code === 401) { this.leaveComputer(true); return; }
      if (code >= 400) this.streamDown(gen, code === 429 ? 8000 : 3000);
    }).catch(() => { this.streamDown(gen, 2000); });
  }

  private queueStreamPaint(): void {
    if (this.deltaPaintTimer !== -1) return;
    this.deltaPaintTimer = setTimeout(() => { this.flushStreamDeltas(); }, STREAM_PAINT_INTERVAL_MS);
  }

  private flushStreamDeltas(paint: boolean = true): void {
    if (this.deltaPaintTimer !== -1) clearTimeout(this.deltaPaintTimer);
    this.deltaPaintTimer = -1;
    if (paint && (this.pendingLiveText || this.pendingLiveThinking)) {
      this.pendingBottom = true;
      if (this.pendingLiveText) this.liveText = (this.liveText + this.pendingLiveText).slice(-MAX_LIVE_TEXT_LENGTH);
      if (this.pendingLiveThinking) {
        this.liveThinking = (this.liveThinking + this.pendingLiveThinking).slice(-MAX_LIVE_TEXT_LENGTH);
      }
    }
    this.pendingLiveText = '';
    this.pendingLiveThinking = '';
  }

  private handleFrame(raw: string): void {
    let frame: StreamFrame;
    try { frame = JSON.parse(raw) as StreamFrame; } catch { return; }
    if (this.syncMode === 'sequenced') {
      if (!frame.cursor) {
        if (frame.type === 'bridge/status') this.schedule(0);
        return;
      }
      if (frame.type === 'ready') {
        this.sessionSync.ready(frame.cursor);
        this.schedule(0);
      } else if (this.sessionSync.receive(frame, (event: StreamFrame): void => this.applyStreamFrame(event))) {
        this.schedule(0);
      }
      return;
    }
    this.applyStreamFrame(frame);
  }

  private applyStreamFrame(frame: StreamFrame): void {
    if (frame.sessionId && frame.sessionId !== this.currentId) {
      if (frame.type === 'session/changed' || frame.type === 'ready') this.schedule(150);
      return;
    }
    if (frame.type === 'message/delta') {
      if (typeof frame.text === 'string' && frame.text && (frame.cursor !== undefined || frame.seq === undefined || frame.seq > this.liveSeq)) {
        this.pendingLiveText = (this.pendingLiveText + frame.text).slice(-MAX_LIVE_TEXT_LENGTH);
        if (frame.seq !== undefined) this.liveSeq = frame.seq;
        this.queueStreamPaint();
      }
      return;
    }
    if (frame.type === 'message/thinking') {
      if (typeof frame.text === 'string' && frame.text && (frame.cursor !== undefined || frame.seq === undefined || frame.seq > this.liveThinkSeq)) {
        this.pendingLiveThinking = (this.pendingLiveThinking + frame.text).slice(-MAX_LIVE_TEXT_LENGTH);
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
        this.pendingLiveText = '';
        this.liveText = '';
        this.liveSeq = frame.seq ?? 0;
      }
      if (frame.cursor || (frame.thinkingSeq !== undefined && frame.thinkingSeq >= this.liveThinkSeq)) {
        this.pendingLiveThinking = '';
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
    let base = this.address.trim();
    let ticket = this.ticket.trim().toLowerCase();
    let ca: string | undefined = undefined;
    let pin: string | undefined = undefined;
    if (this.pairingMode !== 'usb') {
      try {
        const bundle = decodePairingBundle(this.pairingBundle, this.pairingMode === 'remote');
        base = bundle.url;
        ticket = bundle.ticket;
        ca = bundle.ca;
        pin = bundle.pin;
      } catch {
        this.status = this.pairingMode === 'remote' ? '请导入 Pi Go.app 生成的公网配对包。' : '请导入 Pi Go.app 生成的局域网配对包。';
        return;
      }
    } else if (!validUsb(base) || !/^(\d{8}|[a-f0-9]{64})$/.test(ticket)) {
      this.status = '请输入本机 USB 地址和有效的一次性票据。';
      return;
    }
    if (this.computers.length >= MAX_COMPUTERS && !this.computers.some((record: Companion): boolean => record.address === base)) {
      this.status = '已保存 12 条连接。请先移除不再使用的连接。';
      return;
    }
    this.busy = true;
    this.status = '';
    try {
      const result = await this.request('/pair', { ticket: ticket }, { address: base, token: '', ca: ca, pin: pin });
      if (!result.token || !/^[a-f0-9]{64}$/.test(result.token)) throw new Error('invalid_token');
      const previous = this.computers.find((item: Companion): boolean => item.address === base);
      const target = this.computers.find((item: Companion): boolean => item.computerId === this.pairingComputerId);
      const computer = previous ?? target;
      const record: Companion = { address: base, token: result.token, ca: ca, pin: pin,
        computerId: computer?.computerId ?? util.generateRandomUUID(), computerName: computer?.computerName };
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
      this.lanCandidates = await discoverLan();
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
    this.token = '';
    this.ca = undefined;
    this.pin = undefined;
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
    this.chatCache.clear();
    this.runningSessionIds = [];
    this.runningSessions = [];
    this.observedRuns.clear();
    this.clearRunNotices();
    this.sessionView = 'all';
    this.loadedView = 'all';
    this.sessionCatalogFailed = false;
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
    this.hasWorkspaceDetails = false;
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
      this.sidebarBook = { version: 1, entries: this.sidebarBook.entries.filter((kept: SidebarEntry): boolean => kept.address !== address) };
    }
    this.status = revoked ? '该电脑的配对已撤销，请重新连接。' : '';
    this.flushSidebarSave();
    if (next) this.activateComputer(next);
    this.syncLiveActivity();
    void this.persistComputers().catch(() => { this.status = '无法保存电脑列表的本次更改。'; });
  }

  private removeComputer(address: string): void {
    if (this.removeTarget !== address || this.busy || this.openingSession) return;
    this.removeTarget = '';
    if (this.huaweiProfile) this.updateCloudComputer(address, '');
    this.computers = this.computers.filter((record: Companion): boolean => record.address !== address);
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
    const key = this.draftKey(id);
    this.drafts.delete(key);
    if (this.draft) this.drafts.set(key, this.draft);
    if (this.drafts.size > 128) {
      let oldest: string = '';
      this.drafts.forEach((_text: string, item: string) => { if (!oldest) oldest = item; });
      if (oldest) this.drafts.delete(oldest);
    }
  }

  private forgetDrafts(address: string): void {
    this.queuedSteering = this.queuedSteering.filter((item: QueuedSteering): boolean => !item.sessionKey.startsWith(`${address}|`));
    for (const key of this.drafts.keys()) {
      if (key.startsWith(`${address}|`)) this.drafts.delete(key);
    }
    for (const key of this.unconfirmed.keys()) {
      if (key.startsWith(`${address}|`)) this.unconfirmed.delete(key);
    }
    for (const key of this.draftAttachments.keys()) {
      if (key.startsWith(`${address}|`)) this.draftAttachments.delete(key);
    }
  }

  private applySession(session: SessionState): void {
    if (session.id !== this.currentId) {
      this.flushStreamDeltas(false);
      this.closeToolDetails();
      this.resetVoice();
      if (this.currentId) this.rememberDraft(this.currentId);
      this.draft = this.drafts.get(this.draftKey(session.id)) ?? '';
      this.pendingSend = this.unconfirmed.get(this.draftKey(session.id));
      this.attachments = this.draftAttachments.get(this.draftKey(session.id)) ?? [];
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
      if (libraryVisible && (connected || (!this.sessionCatalogFailed && (!this.sessionCatalogLoaded || catalogStale))) && !this.busy) {
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
          this.sessionSync.disconnect();
          this.historyStream = '';
          this.historyLeaf = undefined;
        }
        this.flushStreamDeltas(false);
        this.closeToolDetails();
        if (result.state === 'session_deleted' && result.deletedSessionId) {
          this.sessions = this.sessions.filter((row: SessionRow): boolean => row.id !== result.deletedSessionId);
          this.chatCache.delete(this.draftKey(result.deletedSessionId));
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
        if (applied || this.sessionSync.matches(result.cursor)) {
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
    } finally {
      this.polling = false;
      if (epoch === this.epoch) {
        this.syncLiveActivity();
        const delay = !this.reachable ? 1500 :
          this.syncMode === 'sequenced' && this.sessionSync.needsSnapshot() ? 150 :
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
    const applied = this.sessionSync.snapshot(cursor, (): void => {
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
      if (this.currentId !== session.id || !this.sessionSync.matches(cursor)) return undefined;
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
      this.pendingLiveText = '';
      const text = snapshot.liveText ?? '';
      if (text !== this.liveText) this.pendingBottom = true;
      this.liveText = text;
      this.liveSeq = textSeq;
    }
    const thinkingSeq = snapshot.liveThinkSeq ?? 0;
    if (this.idle || thinkingSeq >= this.liveThinkSeq) {
      this.pendingLiveThinking = '';
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
    const overlap = incoming.length ? this.messages.findIndex((message: ChatMessage): boolean => message.id === incoming[0].id) : -1;
    if (overlap < 0) {
      if (incoming.length || this.messages.length) this.messages = incoming;
      this.historyCursor = cursor;
      return;
    }
    if (this.messages.length - overlap !== incoming.length ||
      incoming.some((message: ChatMessage, index: number): boolean => !this.sameMessage(this.messages[overlap + index], message))) {
      this.messages = this.messages.slice(0, overlap).concat(incoming);
    }
    if (overlap === 0) this.historyCursor = cursor;
  }

  private sameMessage(saved: ChatMessage, incoming: ChatMessage): boolean {
    if (saved.id !== incoming.id || saved.role !== incoming.role || saved.text !== incoming.text ||
      saved.textTruncated !== incoming.textTruncated || saved.thinking !== incoming.thinking || saved.thinkingMs !== incoming.thinkingMs || saved.imageCount !== incoming.imageCount) return false;
    const left = saved.tools ?? [];
    const right = incoming.tools ?? [];
    return left.length === right.length && left.every((tool: LiveTool, index: number): boolean => {
      const candidate = right[index];
      return tool.id === candidate.id && tool.state === candidate.state && tool.ms === candidate.ms &&
        tool.name === candidate.name && tool.detail === candidate.detail;
    });
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
      if (this.syncMode === 'sequenced' && (!result.cursor || !this.sessionSync.matches(result.cursor))) return;
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
    // A background task unknown to the cached catalog needs its name for the header pill.
    const unknown = this.backgroundActive() && this.runningSessionIds.some((id: string): boolean =>
      id !== this.currentId && !this.sessions.some((session: SessionRow): boolean => session.id === id));
    if (unknown && Date.now() - this.runningCatalogAt >= 30000 && !this.busy && !this.sessionLoading) {
      this.runningCatalogAt = Date.now();
      void this.loadSessions();
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
    if (!this.observedRuns.delete(id) || !this.visible || !this.runNoticesEnabled) return;
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
    return this.liveViewsEnabled && this.isPaired && !!this.currentId && (!this.idle || this.queued);
  }

  private syncLiveActivity(): void {
    if (this.backgroundLiveActivity()) {
      const listed = this.sessions.find((session: SessionRow): boolean => session.id === this.currentId);
      const state = !this.reachable ? '重新连接中' : this.interaction ? '等待处理' : this.queued ? '排队中' : '运行中';
      liveActivity.sync({
        sessionId: this.currentId,
        address: this.base,
        title: this.sessionName || listed?.name || this.project || 'Agent 任务',
        project: this.project,
        state: state,
        foreground: this.visible
      });
    } else liveActivity.sync(undefined);
    if (!this.visible && !this.backgroundLiveActivity()) {
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

  private standaloneScheduleRuns(): RunMessage[] {
    if (!this.reachable) return [];
    const sessions = this.allRunningRows();
    return this.scheduleActive.filter((row: RunMessage): boolean => this.isCurrentScheduleComputer(row) &&
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

  private async loadSessions(): Promise<void> {
    if (this.busy || this.openingSession || this.sessionLoading) return;
    const epoch = this.epoch;
    const version = this.sessionCatalogVersion;
    const view = this.sessionView;
    this.sessionLoading = true;
    this.sessionCatalogFailed = false;
    try {
      const sessions: SessionRow[] = [];
      const ids = new Set<string>();
      let cursor: number | undefined = 0;
      let result: BridgeReply;
      const showFirstPage = !this.sessions.length || this.loadedView !== view;
      do {
        result = await this.request(`/sessions?limit=100&cursor=${cursor}&view=${view}`);
        if (epoch !== this.epoch || version !== this.sessionCatalogVersion) return;
        // The live catalog can move between pages; keep one row per session.
        for (const row of result.sessions ?? []) {
          if (ids.has(row.id)) continue;
          ids.add(row.id);
          sessions.push(row);
        }
        const next = result.nextCursor;
        if (cursor === 0 && next !== undefined && showFirstPage) {
          this.sessions = sessions.slice();
          this.loadedView = view;
          this.projects = result.projects ?? [];
          this.workspaces = result.workspaces ?? [];
          this.hasWorkspaceDetails = result.workspaces !== undefined;
          this.hostAvailable = result.desktopHandoff ?? false;
          this.canCreateWorkspace = result.canCreateWorkspace ?? false;
          this.sessionCatalogLoaded = true;
        }
        cursor = next !== undefined && next > cursor ? next : undefined;
      } while (cursor !== undefined);
      this.sessionCatalogLoaded = true;
      this.sessionCatalogUpdatedAt = Date.now();
      this.sessions = sessions;
      this.loadedView = view;
      this.hostAvailable = result.desktopHandoff ?? false;
      this.canCreateWorkspace = result.canCreateWorkspace ?? false;
      this.projects = result.projects ?? [];
      this.workspaces = result.workspaces ?? [];
      this.hasWorkspaceDetails = result.workspaces !== undefined;
    } catch (error) {
      if (epoch !== this.epoch || version !== this.sessionCatalogVersion) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else this.sessionCatalogFailed = true;
    } finally { this.sessionLoading = false; }
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
    const key = JSON.stringify([this.base, this.token, cwd, path]);
    hash.updateSync({ data: new util.TextEncoder().encodeInto(key) });
    return Array.from(hash.digestSync().data, (byte: number): string => byte.toString(16).padStart(2, '0')).join('');
  }

  private async downloadFile(cwd: string, path: string, temporary: string, lookupName: boolean, limit: number = MAX_DOWNLOAD_BYTES): Promise<void> {
    const req = http.createHttp();
    let file: fileIo.File | undefined;
    try {
      const output = fileIo.openSync(temporary, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      file = output;
      const headers: Record<string, string> = { 'Authorization': `Bearer ${this.token}` };
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        usingCache: false,
        usingProxy: false,
        maxRedirects: 0,
        connectTimeout: 4000,
        readTimeout: 60000,
        maxLimit: limit
      };
      if (this.ca && this.pin) {
        opts.caData = this.ca;
        opts.certificatePinning = { hashAlgorithm: 'SHA-256', publicKeyHash: this.pin };
      }
      let expected = -1;
      let received = 0;
      let writeError = '';
      const prefix = new Uint8Array(MAX_DOWNLOAD_ERROR_BYTES);
      req.on('headersReceive', (header: Object) => {
        const fields = header as Record<string, string>;
        const key = Object.keys(fields).find((field: string): boolean => field.toLowerCase() === 'content-length');
        expected = key === undefined ? -1 : Number(fields[key]);
      });
      req.on('dataReceive', (chunk: ArrayBuffer) => {
        if (writeError) return;
        if (received + chunk.byteLength > limit) {
          writeError = 'file_too_large';
          return;
        }
        if (received < prefix.length) {
          prefix.set(new Uint8Array(chunk, 0, Math.min(chunk.byteLength, prefix.length - received)), received);
        }
        try {
          let offset = 0;
          while (offset < chunk.byteLength) {
            const written = fileIo.writeSync(output.fd, offset === 0 ? chunk : chunk.slice(offset));
            if (written <= 0) throw new Error('write_failed');
            offset += written;
          }
          received += chunk.byteLength;
        } catch {
          writeError = 'write_failed';
        }
      });
      const lookup = lookupName && !path.includes('/') ? '&lookup=name' : '';
      const status = await req.requestInStream(`${this.base}/files/download?cwd=${encodeURIComponent(cwd)}&path=${encodeURIComponent(path)}${lookup}`, opts);
      if (status !== 200) {
        let code = 'download_failed';
        if (!writeError && received <= prefix.length) {
          try {
            const reply = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(prefix.subarray(0, received))) as BridgeReply;
            if (reply.error) code = reply.error;
          } catch {
            // 错误体不是 JSON 时保留 download_failed。
          }
        }
        throw new BridgeFailure(status, code);
      }
      if (writeError) throw new Error(writeError);
      if (expected > limit) throw new Error('file_too_large');
      if (received !== expected) throw new Error('incomplete_download');
    } finally {
      req.destroy();
      if (file) fileIo.closeSync(file);
    }
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
    ChatContent({ text: text, accent: this.accent(), allowLandscape: allowLandscape,
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

  private messageFiles(message: ChatMessage): string[] {
    if (message.role !== 'user') return messageFileChips(message.text, this.workspaceCwd);
    const start = message.text.lastIndexOf('\n\n[Pi Go 附件] 手机上传了 ');
    if (start < 0) return [];
    const prefix = `：${this.workspaceCwd.replace(/\/$/, '')}/.pi-go/attachments/`;
    const paths: string[] = [];
    for (const line of message.text.slice(start).split('\n')) {
      const index = line.indexOf(prefix);
      if (index < 0) continue;
      const path = normalizeWorkspacePath(this.workspaceCwd, line.slice(index + 1));
      if (/^\.pi-go\/attachments\/[a-f0-9]{16}-[^/]+$/.test(path) && !paths.includes(path)) paths.push(path);
    }
    return paths;
  }

  private toolFile(tool: LiveTool): string {
    if (tool.state === 'run' || !['write', 'edit', 'read'].includes(tool.name)) return '';
    return normalizeWorkspacePath(this.workspaceCwd, this.selectedToolDetails?.path ?? tool.detail);
  }

  private toolTitle(tool: LiveTool): string {
    switch (tool.name) {
      case 'bash': return '执行命令';
      case 'read': return '读取文件';
      case 'write': return '写入文件';
      case 'edit': return '编辑文件';
      case 'grep':
      case 'find': return '搜索工作区';
      case 'ls': return '列出目录';
      case 'web_search': return '网页搜索';
      default: return tool.name;
    }
  }

  private toolIcon(tool: LiveTool): Resource {
    if (tool.name === 'bash') return $r('sys.symbol.code_square');
    if (tool.name === 'grep' || tool.name === 'find' || tool.name === 'web_search') return $r('sys.symbol.magnifyingglass');
    if (tool.name === 'write' || tool.name === 'edit') return $r('sys.symbol.square_and_pencil');
    return $r('sys.symbol.folder');
  }

  private toolKey(tool: LiveTool): string {
    return `${tool.id}-${tool.state}-${tool.ms ?? 0}`;
  }

  private transcriptMessageKey(message: ChatMessage): string {
    const thinking = message.thinking && this.thinkingOpenIds.includes(message.id) ? 'open' : '';
    const tools = message.tools?.map((tool: LiveTool): string => this.toolKey(tool)).join(',') ?? '';
    return `${message.id}:${thinking}:${tools}:${message.textTruncated ?? false}`;
  }

  private unlistedLiveTools(): LiveTool[] {
    if (!this.liveTools.length) return this.liveTools;
    const saved = new Set<string>();
    for (const message of this.messages) {
      for (const tool of message.tools ?? []) saved.add(tool.id);
    }
    return this.liveTools.filter((tool: LiveTool): boolean => !saved.has(tool.id));
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

  private async updateSessionMeta(session: SessionRow, pin: boolean): Promise<void> {
    const payload: Payload = { id: session.id, cwd: session.cwd, revision: session.revision ?? 0 };
    if (pin) payload.pinned = !session.pinned;
    else payload.archived = !session.archived;
    if (await this.requestAction('/session-meta', payload)) await this.loadSessions();
  }

  private createSpaceTask(path: string): void {
    if (!this.projects.includes(path)) return;
    if (!this.reachable || !this.hostAvailable) {
      this.getUIContext().getPromptAction().showToast({
        message: this.reachable ? '无法新建任务，请在电脑上启动 Pi Go 后台服务。' : '请先连接电脑再新建任务。'
      });
      return;
    }
    this.activeTab = 'tasks';
    void this.requestAction('/new', { cwd: path });
  }

  private workspaceName(path: string): string {
    return this.workspaces?.find((row: WorkspaceRow): boolean => row.cwd === path)?.name ||
      path.split('/').pop() || path;
  }

  private newTaskOptions(): MenuElement[] {
    const options = this.projects.map((path: string): MenuElement => ({
      value: this.workspaceName(path),
      action: () => { this.createSpaceTask(path); }
    }));
    if (this.canCreateWorkspace) {
      options.push({ value: '新空间', action: () => {
        if (!this.reachable || this.busy || this.openingSession || !this.canCreateWorkspace) return;
        this.newSpaceName = '';
        this.newSpaceError = '';
        this.showNewSpace = true;
      } });
    }
    return options;
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
    if (!this.projects.includes(cwd)) this.projects = this.projects.concat([cwd]).sort();
    if (!this.expandedSpaces.includes(cwd)) this.expandedSpaces = this.expandedSpaces.concat([cwd]);
    this.sessionCatalogLoaded = false;
    this.sessionCatalogVersion += 1;
    this.scheduleSidebarSave();
    this.activeTab = 'tasks';
    if (!(await this.requestAction('/new', { cwd: cwd })) && this.epoch === epoch + 1) {
      this.getUIContext().getPromptAction().showToast({
        message: `空间已创建。${this.status || '暂时无法打开任务。'}`
      });
    }
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
    this.workspaces = this.workspaces?.filter((row: WorkspaceRow): boolean => row.cwd !== path) ?? [];
    this.scheduleSidebarSave();
    this.getUIContext().getPromptAction().showToast({ message: `已移除空间「${name}」` });
    if (this.workspaceCwd === path) {
      // 当前会话所在的电脑端工作区已关闭，回到任务列表等桥接状态刷新。
      this.showSessions = !this.dockedSessions();
      this.schedule(0);
    } else void this.loadSessions();
  }

  private async requestAction(path: string, input?: Payload): Promise<boolean> {
    if (this.busy || this.openingSession) return false;
    const navigation = path === '/open' || path === '/new';
    const previous = navigation ? this.chatCache.get(this.draftKey(this.currentId)) : undefined;
    if (previous?.session) this.cacheChat(previous.session);
    const cached = path === '/open' && input?.id ? this.chatCache.get(this.draftKey(input.id)) : undefined;
    let navigationConfirmed = false;
    const epoch = navigation ? ++this.epoch : this.epoch;
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
      const payload: Payload | undefined = path === '/open' && this.syncMode !== 'legacy'
        ? { id: input?.id, history: true } : input;
      const result = await this.request(path, payload);
      if (epoch !== this.epoch) return false;
      if (path === '/new' || path === '/rename' || path === '/session-meta' || path === '/close-workspace') {
        this.sessionCatalogLoaded = false;
        this.sessionCatalogVersion += 1;
      }
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
      else if (error instanceof BridgeFailure && error.message === 'session_busy') this.status = '等待当前任务和队列结束后，再应用模型设置。';
      else if (error instanceof BridgeFailure && error.message === 'model_not_applied') this.status = 'Pi 未应用所选模型，请在电脑上检查模型的登录状态或 API 配置。';
      else if (error instanceof BridgeFailure && error.message === 'invalid_name') this.status = '名称须为 1–200 字且不含换行。';
      else if (error instanceof BridgeFailure && error.status === 409) this.status = 'Pi 正在处理任务或会话已变化，请刷新后再试。';
      else this.status = '电脑端尚未确认操作，请刷新查看结果。';
      if (path === '/open' && this.showSessions && this.status) {
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
  thinkingCard(id: string, content: string, ms: number, open: boolean) {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('✻').fontSize(13).fontColor($r('app.color.pigo_info'))
        Text(id ? (ms >= 0 ? `思考 · ${(ms / 1000).toFixed(1)}s` : '思考') : '思考中…')
          .fontSize(13).fontColor($r('app.color.pigo_info')).layoutWeight(1)
        SymbolGlyph(open ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(14).fontColor([$r('app.color.pigo_muted')])
      }.width('100%').onClick(() => {
        if (id) this.toggleThinking(id, !open);
        else this.liveThinkingOpen = !open;
      })
      if (open) {
        Scroll() {
          Text(content).fontSize(13).fontStyle(FontStyle.Italic).fontColor($r('app.color.pigo_muted')).lineHeight(21)
            .copyOption(CopyOptions.LocalDevice).width('100%')
        }.constraintSize({ maxHeight: 320 }).width('100%').scrollBar(BarState.Off)
      } else if (!id) {
        Text(content.split('\n').pop() ?? '').fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
    }.width('100%').padding(12).backgroundColor($r('app.color.pigo_control')).borderRadius(12)
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
  toolRow(tool: LiveTool, messageId: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        SymbolGlyph(this.toolIcon(tool)).fontSize(17).fontColor([this.accent()])
        Text(this.toolTitle(tool)).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '38%' })
        Text(tool.detail).fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (tool.state === 'run' && !this.idle) {
          LoadingProgress().width(13).height(13).color(this.accent())
        } else if (tool.state === 'fail') {
          Text('失败').fontSize(12).fontColor($r('app.color.pigo_error'))
        }
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([$r('app.color.pigo_muted')])
      }.width('100%')
    }.width('100%').height(44).padding({ left: 10, right: 8 }).borderRadius(8).backgroundColor(Color.Transparent)
      .onClick(() => { this.openToolDetails(tool, messageId); })
  }

  @Builder
  toolGroup(tools: LiveTool[], messageId: string) {
    if (tools.length) {
      Column() {
        ForEach(tools, (tool: LiveTool, index: number) => {
          if (index > 0) Divider().color($r('app.color.pigo_line')).margin({ left: 36, right: 8 })
          this.toolRow(tool, messageId)
        }, (tool: LiveTool) => this.toolKey(tool))
      }.width('100%').padding({ left: 2, right: 2 })
        .backgroundColor($r('app.color.pigo_panel')).borderRadius(12)
        .border({ width: 1, color: $r('app.color.pigo_line') })
    }
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
            Text(this.toolTitle(this.selectedTool)).fontSize(21).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
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
    if (!this.commandsLoadedAt || Date.now() - this.commandsLoadedAt >= 60000) void this.loadCommands();
  }

  private resetCommands(): void {
    this.commandRequest += 1;
    this.commandsLoading = false;
    this.commandError = '';
    this.commandPalette = false;
    this.commandRows = [];
    this.commandsLoadedAt = 0;
    this.showComposerMenu = false;
  }

  private async loadCommands(): Promise<void> {
    if (this.commandsLoading || !this.reachable || !this.currentId || this.openingSession) return;
    const request = ++this.commandRequest;
    const id = this.currentId;
    this.commandError = '';
    this.commandsLoading = true;
    try {
      const reply = await this.request('/commands');
      if (request !== this.commandRequest) return;
      if (reply.session?.id !== id || !reply.commands) {
        this.commandError = '加载命令失败，点此重试';
        return;
      }
      this.commandRows = reply.commands.slice(0, 200);
      this.commandsLoadedAt = Date.now();
    } catch (error) {
      if (request !== this.commandRequest) return;
      this.commandError = error instanceof BridgeFailure && error.message === 'not_found' ?
        '请更新电脑端 Pi Go，并重启桥接和当前会话后重试' : '加载命令失败，点此重试';
    } finally {
      if (request === this.commandRequest) this.commandsLoading = false;
    }
  }

  private pickCommand(row: CommandRow, prompt: string = ''): void {
    this.draft = `${row.invoke ?? `/${row.name}`} ${prompt}`;
    this.commandPalette = false;
  }

  private openComposerMenu(): void {
    this.dismissKeyboard();
    this.showSkillPicker = false;
    this.showComposerMenu = true;
  }

  private openSkillPicker(): void {
    this.showSkillPicker = true;
    if (!this.commandsLoadedAt || Date.now() - this.commandsLoadedAt >= 60000) void this.loadCommands();
  }

  private availableSkills(): CommandRow[] {
    return this.commandRows.filter((row: CommandRow): boolean => row.source === 'skill');
  }

  private pickSkill(row: CommandRow): void {
    this.pickCommand(row, this.draft.replace(/^\s*\/skill:\S*\s*/, ''));
    this.voiceMode = false;
    this.showComposerMenu = false;
  }

  private commandSourceLabel(source: string): string {
    if (source === 'skill') return '技能';
    if (source === 'prompt') return '模板';
    if (source === 'extension') return '扩展';
    return source;
  }

  private hasDraft(): boolean {
    return this.draft.trim().length > 0 || this.attachments.length > 0;
  }

  private canSend(): boolean {
    return !!this.currentId && (this.idle || !!this.runId) &&
      this.reachable && !this.busy && !this.openingSession && !this.pendingSend &&
      !this.recording && !this.voicePreparing && !this.voiceFinishing &&
      this.hasDraft() &&
      (this.acceptsImage || !this.attachments.some((item: DraftAttachment): boolean => item.kind === 'image'));
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
    if (this.unconfirmed.size >= 128) { this.status = '请先核对未确认的发送。'; return; }
    const epoch = this.epoch;
    const key = this.draftKey(id);
    const pending: PendingSend = { requestId: util.generateRandomUUID(), text: text, attachments: attachments,
      steeringAfter: mode === 'steer' && !text.startsWith('/') ? (this.messages[this.messages.length - 1]?.id ?? '') : undefined };
    this.unconfirmed.set(key, pending);
    this.pendingSend = pending;
    this.busy = true;
    this.status = '';
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
      const result = await this.request('/prompt', { id: id, text: text, requestId: pending.requestId, mode: mode,
        runId: runId, attachments: refs.length ? refs : undefined });
      if (epoch !== this.epoch) return;
      if (result.dispatched !== true) throw new Error('dispatch_unconfirmed');
      this.finishSend(key, pending);
      if (mode === 'send') this.idle = false;
      else this.status = '引导请求已交给 Pi。';
    } catch (error) {
      if (epoch !== this.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else if (error instanceof BridgeFailure && ['session_busy', 'session_not_streaming', 'session_changed',
        'invalid_prompt', 'invalid_request_id', 'probe_request_limit', 'invalid_image', 'image_not_supported', 'payload_too_large',
        'invalid_attachment', 'unknown_attachment', 'invalid_content_type', 'not_found',
        'unknown_command', 'command_attachments'].includes(error.message)) {
        this.unconfirmed.delete(key);
        this.pendingSend = undefined;
        this.status = error.message === 'image_not_supported' ? '此模型不支持图片；草稿已保留。' :
          ['invalid_image', 'payload_too_large'].includes(error.message) ? '发送内容过大（单文件 8MB 内）或图片格式无效；草稿已保留。' :
            ['invalid_attachment', 'unknown_attachment', 'invalid_content_type'].includes(error.message) ? '附件无效或已过期；草稿已保留。' :
              error.message === 'not_found' ? '电脑端扩展版本过旧，不支持附件上传；草稿已保留。' :
                error.message === 'unknown_command' ? '电脑未找到该命令；输入 / 可查看可用命令，草稿已保留。' :
                  error.message === 'command_attachments' ? '命令发送不支持附件；草稿已保留。' :
                    '电脑未接收此次发送。请检查会话是否仍在运行；草稿已保留。';
      } else this.status = '发送结果未知。草稿已保留，不会自动重发。';
    } finally {
      this.busy = false;
      this.schedule(0);
    }
  }

  private async uploadAttachment(kind: string, name: string, bytes: Uint8Array): Promise<UploadedAttachment> {
    const req = http.createHttp();
    const headers: Record<string, string> = { 'Authorization': `Bearer ${this.token}`, 'Content-Type': 'application/octet-stream' };
    try {
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        usingProxy: false,
        maxRedirects: 0,
        connectTimeout: 4000,
        readTimeout: 60000
      };
      if (this.ca && this.pin) {
        opts.caData = this.ca;
        opts.certificatePinning = { hashAlgorithm: 'SHA-256', publicKeyHash: this.pin };
      }
      opts.extraData = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      const response = await req.request(`${this.base}/upload?kind=${encodeURIComponent(kind)}&name=${encodeURIComponent(name)}`, opts);
      const reply = JSON.parse(response.result as string) as BridgeReply;
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new BridgeFailure(response.responseCode, reply.error ?? 'request_failed');
      }
      if (!reply.attachment || typeof reply.attachment.token !== 'string' || reply.attachment.kind !== kind) {
        throw new BridgeFailure(response.responseCode, 'invalid_attachment');
      }
      return reply.attachment;
    } finally { req.destroy(); }
  }

  private finishSend(key: string, pending: PendingSend): void {
    this.unconfirmed.delete(key);
    this.draftAttachments.delete(key);
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
    if (!this.queuedSteering.length) return;
    const key = this.draftKey(this.currentId);
    const tail = this.messages[this.messages.length - 1]?.id;
    const used = new Set<string>();
    const remaining: QueuedSteering[] = [];
    for (const pending of this.queuedSteering) {
      if (pending.sessionKey !== key) { remaining.push(pending); continue; }
      if (settled) continue;
      const after = pending.afterId ? this.messages.findIndex((message: ChatMessage): boolean => message.id === pending.afterId) : -1;
      if (pending.afterId && after < 0) { remaining.push(pending); continue; }
      const text = pending.files.length
        ? `${pending.text}\n\n[Pi Go 附件] 手机上传了 ${pending.files.length} 个文件：`.slice(0, 8000)
        : pending.text.slice(0, 8000);
      const match = this.messages.findIndex((message: ChatMessage, index: number): boolean =>
        index > after && message.role === 'user' && !used.has(message.id) && (message.imageCount ?? 0) === pending.imageCount &&
        (pending.files.length ? message.text.startsWith(text) : message.text === text));
      if (match < 0) {
        pending.afterId = tail ?? pending.afterId;
        remaining.push(pending);
        continue;
      }
      const id = this.messages[match].id;
      used.add(id);
      const sending = this.pendingSend;
      if (sending && sending.requestId !== pending.id && sending.steeringAfter !== undefined &&
        match > this.messages.findIndex((message: ChatMessage): boolean => message.id === sending.steeringAfter)) {
        sending.steeringAfter = id;
      }
    }
    if (remaining.length !== this.queuedSteering.length) this.queuedSteering = remaining;
  }

  private storedDraftAttachments(): number[] {
    let images = 0;
    let files = 0;
    for (const list of this.draftAttachments.values()) {
      for (const item of list) {
        if (item.kind === 'image') images += 1;
        else files += 1;
      }
    }
    return [images, files];
  }

  private commitDraftAttachments(key: string, list: DraftAttachment[]): void {
    if (list.length) this.draftAttachments.set(key, list);
    else this.draftAttachments.delete(key);
    this.attachments = list;
  }

  private removeAttachment(index: number): void {
    const key = this.draftKey(this.currentId);
    const list = this.attachments.slice();
    const removed = list.splice(index, 1)[0];
    if (removed && removed.image) removed.image.preview.release().catch((): void => {});
    this.commitDraftAttachments(key, list);
  }

  private fileIcon(name: string): string {
    const lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return 'PDF';
    if (lower.endsWith('.zip') || lower.endsWith('.rar') || lower.endsWith('.7z')) return 'ZIP';
    if (lower.endsWith('.md')) return 'MD';
    if (lower.endsWith('.txt') || lower.endsWith('.log')) return 'TXT';
    if (lower.endsWith('.csv') || lower.endsWith('.xlsx') || lower.endsWith('.xls')) return 'CSV';
    if (lower.endsWith('.json')) return 'JSON';
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') || lower.endsWith('.webp') || lower.endsWith('.heic')) return 'IMG';
    return '文件';
  }

  private fileSize(size: number): string {
    if (size >= 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
    if (size >= 1024) return `${Math.round(size / 1024)} KB`;
    return `${size} B`;
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

  private currentModelOption(): ModelOption | undefined {
    return this.models.find((item: ModelOption): boolean => this.isCurrentModel(item)) ?? this.currentModel;
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

  private currentModelIndex(): number {
    const idx = this.models.findIndex((item: ModelOption): boolean => this.isCurrentModel(item));
    return idx >= 0 ? idx : 0;
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
      this.themeId = themeStyle(settings.getSync('theme_style', 'mint') as string).id;
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

  private cloudOnlyComputers(): CloudComputer[] {
    return this.cloudComputers.filter((row: CloudComputer): boolean =>
      !this.computers.some((local: Companion): boolean => local.address === row.address));
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

  private accentFor(style: ThemeStyle): string {
    return this.darkMode ? style.dark : style.light;
  }

  private accent(): string { return this.accentFor(themeStyle(this.themeId)); }

  private accentTint(): string {
    const style = themeStyle(this.themeId);
    return this.darkMode ? style.darkTint : style.lightTint;
  }

  private accentForeground(): string { return this.darkMode ? '#15191C' : '#FFFFFF'; }

  private selectTheme(id: string): void {
    this.appearanceNotice = '';
    this.themeId = id;
    void this.saveSetting(SYNC_THEME, id).catch(() => { this.appearanceNotice = '未能保存主题配色。'; });
    this.writeCloudRow({ key: SYNC_THEME, payload: id });
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

  private pairingComputerTitle(): string {
    const group = computerGroups(this.computers).find((item: ComputerGroup): boolean => item.id === this.pairingComputerId);
    return group ? computerGroupTitle(group) : '';
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

  @Builder
  computerConnection(record: Companion, group: ComputerGroup) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Row({ space: 6 }) {
                if (this.isPaired && this.base === record.address) {
                  Blank().width(7).height(7).borderRadius(4)
                    .backgroundColor(this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
                }
                Text(connectionLabel(record))
                  .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
                if (this.isPaired && this.base === record.address) {
                  Text(this.reachable ? '当前 · 已连接' : '当前 · 离线')
                    .fontSize(11).fontWeight(FontWeight.Medium)
                    .fontColor(this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
                }
              }
              Text(record.address.split('://')[1]).fontSize(12).fontColor($r('app.color.pigo_muted'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            if (this.isPaired && this.base === record.address) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.accent()])
            }
          }.width('100%')
        }.id(`computer-${record.address}`).accessibilityText(`${connectionLabel(record)} ${record.address.split('://')[1]}`)
          .layoutWeight(1).padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(this.isPaired && this.base === record.address ? this.accentTint() : $r('app.color.pigo_control'))
          .border({ width: this.isPaired && this.base === record.address ? 1 : 0, radius: 12, color: this.accent() })
          .enabled(!this.busy && !this.openingSession && !this.removeTarget)
          .onClick(() => {
            if (!this.isPaired || this.base !== record.address) this.chooseComputer(record);
          })
        if (this.removeTarget === record.address) {
          Button('确认移除').chatAction().id('confirm-remove').height(40).enabled(!this.busy)
            .backgroundColor($r('app.color.pigo_error_panel')).fontColor($r('app.color.pigo_error'))
            .onClick(() => { this.removeComputer(record.address); })
          Button('取消').chatAction().height(40).enabled(!this.busy).onClick(() => { this.removeTarget = ''; })
        } else {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_more')).width(18).height(18).fillColor($r('app.color.pigo_muted'))
          }.id(`remove-${record.address}`).width(40).height(44).padding(0).borderRadius(12)
            .backgroundColor(Color.Transparent)
            .accessibilityText('连接操作')
            .enabled(!this.busy && !this.openingSession && !this.removeTarget)
            .bindMenu(this.computerConnectionMenu(record))
        }
      }.width('100%')
      if (this.moveConnectionAddress === record.address) {
        Column({ space: 6 }) {
          Text('将此连接归到哪台电脑？').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
          ForEach(computerGroups(this.computers).filter((other: ComputerGroup): boolean => other.id !== group.id),
            (other: ComputerGroup) => {
              Button(computerGroupTitle(other)).chatAction().id(`move-to-${other.id}`).width('100%').height(40)
                .onClick(() => { this.assignComputerConnection(record.address, other); })
            }, (other: ComputerGroup) => `${other.id}|${other.name}`)
          if (group.connections.length > 1) {
            Button('设为独立电脑').chatAction().id('separate-connection').width('100%').height(40)
              .onClick(() => { this.assignComputerConnection(record.address); })
          }
          Button('取消').chatAction().width('100%').height(38).onClick(() => { this.closeComputerEditors(); })
        }.width('100%').padding(10).borderRadius(12).backgroundColor($r('app.color.launch_background'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  computerList() {
    ForEach(computerGroups(this.computers), (group: ComputerGroup) => {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.computer')).fontSize(20).fontColor([this.accent()])
          Text(computerGroupTitle(group)).fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(18).fontColor([$r('app.color.pigo_text')])
          }.id(`add-connection-${group.id}`).width(36).height(36).padding(0).borderRadius(10)
            .backgroundColor($r('app.color.pigo_control'))
            .accessibilityText(`为${computerGroupTitle(group)}添加连接`)
            .enabled(!this.busy && !this.openingSession && !this.removeTarget)
            .onClick(() => { this.addComputerConnection(group.id); })
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.pencil_line')).fontSize(17).fontColor([$r('app.color.pigo_muted')])
          }.id(`rename-computer-${group.id}`).width(36).height(36).padding(0).borderRadius(10)
            .backgroundColor(Color.Transparent)
            .accessibilityText(`修改${computerGroupTitle(group)}备注`)
            .enabled(!this.busy && !this.removeTarget)
            .onClick(() => {
              this.closeComputerEditors();
              this.computerNameDraft = group.name;
              this.renameComputerId = group.id;
            })
        }.width('100%')
        if (this.renameComputerId === group.id) {
          TextInput({ placeholder: '电脑备注名', text: this.computerNameDraft }).id('computer-name-input')
            .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
            .placeholderColor($r('app.color.pigo_muted'))
            .maxLength(40).onChange((value: string) => { this.computerNameDraft = value; }).width('100%')
          Row({ space: 8 }) {
            Button('保存').chatAction().id('save-computer-name').height(38)
              .backgroundColor(this.accent()).fontColor(this.accentForeground())
              .onClick(() => { this.saveComputerName(group.id); })
            Button('取消').chatAction().height(38).onClick(() => { this.closeComputerEditors(); this.dismissKeyboard(); })
          }.width('100%')
        }
        ForEach(group.connections, (record: Companion) => {
          this.computerConnection(record, group)
        }, (record: Companion) => record.address)
      }.width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
        .border({ width: 1, color: $r('app.color.pigo_line') })
    }, (group: ComputerGroup) => `${group.id}|${group.name}|${group.connections.map((record: Companion): string => record.address).join('|')}`)
    if (this.removeTarget) {
      Text(this.huaweiProfile ? '移除手机上的配对和账号列表中的连接记录。' : '移除手机上的这条配对记录。')
        .fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
    }
  }

  @Builder
  cloudComputerList() {
    if (this.cloudOnlyComputers().length) {
      Text('从账号恢复的连接').fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).width('100%')
      ForEach(this.cloudOnlyComputers(), (computer: CloudComputer) => {
        Column({ space: 8 }) {
          Text(`${computer.mode === 'usb' ? 'USB' : computer.mode === 'lan' ? '局域网' : '公网'} · ${computer.address.split('://')[1]}`)
            .fontSize(15).fontColor($r('app.color.pigo_text')).width('100%')
          Row({ space: 8 }) {
            if (this.removeTarget === computer.address) {
              Button('从账号移除').chatAction().enabled(!this.busy)
                .backgroundColor($r('app.color.pigo_error_panel')).fontColor($r('app.color.pigo_error'))
                .onClick(() => { this.removeCloudComputer(computer); })
              Button('取消').chatAction().onClick(() => { this.removeTarget = ''; })
            } else {
              Button('在本机配对').chatAction().backgroundColor(this.accent()).fontColor(this.accentForeground())
                .enabled(!this.busy && !this.openingSession && !this.removeTarget)
                .onClick(() => { this.restoreCloudComputer(computer); })
              Button('移除').chatAction().enabled(!this.busy && !this.removeTarget)
                .onClick(() => { this.removeTarget = computer.address; })
            }
          }.width('100%')
        }.width('100%').padding(14).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
          .border({ width: 1, color: $r('app.color.pigo_line') })
      }, (computer: CloudComputer) => computer.address)
    }
  }

  @Builder
  pairingForm() {
    Column({ space: 14 }) {
      if (this.pairingComputerId) {
        Text(this.pairingComputerTitle()).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.pigo_text')).width('100%')
      }
      if (this.restoringComputer) {
        Text('请从这台电脑获取新的配对码或配对包。')
          .fontSize(14).fontColor($r('app.color.pigo_text')).width('100%')
      }
      Row({ space: 4 }) {
        Button('USB', { type: ButtonType.Normal }).chatAction().id('usb-transport').layoutWeight(1).height(38).borderRadius(10)
          .accessibilitySelected(this.pairingMode === 'usb')
          .backgroundColor(this.pairingMode === 'usb' ? this.accent() : Color.Transparent)
          .fontColor(this.pairingMode === 'usb' ? this.accentForeground() : $r('app.color.pigo_muted'))
          .onClick(() => { this.selectPairingMode('usb'); })
        Button('局域网', { type: ButtonType.Normal }).chatAction().id('transport').layoutWeight(1).height(38).borderRadius(10)
          .accessibilitySelected(this.pairingMode === 'lan')
          .backgroundColor(this.pairingMode === 'lan' ? this.accent() : Color.Transparent)
          .fontColor(this.pairingMode === 'lan' ? this.accentForeground() : $r('app.color.pigo_muted'))
          .onClick(() => { this.selectPairingMode('lan'); })
        Button('公网', { type: ButtonType.Normal }).chatAction().id('remote-transport').layoutWeight(1).height(38).borderRadius(10)
          .accessibilitySelected(this.pairingMode === 'remote')
          .backgroundColor(this.pairingMode === 'remote' ? this.accent() : Color.Transparent)
          .fontColor(this.pairingMode === 'remote' ? this.accentForeground() : $r('app.color.pigo_muted'))
          .onClick(() => { this.selectPairingMode('remote'); })
      }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
        .enabled(!this.busy && !this.removeTarget)
      if (this.pairingMode !== 'usb') {
        Text(this.pairingMode === 'remote' ? '扫描或粘贴 Pi Go.app「公网」生成的配对包。' :
          '扫描或粘贴 Pi Go.app「局域网扫码」生成的配对包。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
        Row({ space: 8 }) {
          if (this.pairingMode === 'lan') {
            Button('发现电脑').chatAction().id('lan-discover').enabled(!this.busy && !this.removeTarget).onClick(() => { void this.findLanCompanions(); })
          }
          Button('扫码导入').chatAction().id(this.pairingMode === 'remote' ? 'remote-scan' : 'lan-scan')
            .enabled(!this.busy && !this.removeTarget).onClick(() => { void this.scanPairingBundle(); })
        }.width('100%')
        if (this.lanCandidates.length) {
          Text('附近地址（未验证）').fontSize(12).fontColor($r('app.color.pigo_muted')).width('100%')
          Scroll() {
            Column({ space: 4 }) {
              ForEach(this.lanCandidates, (candidate: string) => {
                Text(candidate).width('100%').fontSize(14).fontColor($r('app.color.pigo_text'))
              }, (candidate: string) => candidate)
            }.width('100%')
          }.constraintSize({ maxHeight: 100 }).width('100%').scrollBar(BarState.Off)
        }
        TextInput({ placeholder: this.pairingMode === 'remote' ? '公网配对包' : '局域网配对包', text: this.pairingBundle })
          .id(this.pairingMode === 'remote' ? 'remote-bundle' : 'lan-bundle').type(InputType.Password).maxLength(4096)
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.pairingBundle = value; }).width('100%')
      } else {
        Text('用 USB 连接电脑并允许调试，再在 Pi Go.app 选择「USB」并点「连接手机」。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
        TextInput({ placeholder: 'USB 地址', text: this.address }).id('address')
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.address = value; }).width('100%')
        TextInput({ placeholder: '8 位配对码或一次性票据', text: this.ticket }).id('ticket').type(InputType.Password)
          .backgroundColor($r('app.color.pigo_control')).fontColor($r('app.color.pigo_text'))
          .placeholderColor($r('app.color.pigo_muted'))
          .onChange((value: string) => { this.ticket = value; }).width('100%')
      }
      Button('配对并连接').chatAction().id('pair').enabled(!this.busy && !this.openingSession && !this.removeTarget)
        .backgroundColor(this.accent()).fontColor(this.accentForeground()).width('100%').height(46)
        .onClick(() => { void this.pair(); })
    }.padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(16).width('100%')
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }

  @Builder
  profileCard() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        Stack() {
          if (this.huaweiProfile?.avatar && !this.avatarUnavailable) {
            Image(this.huaweiProfile.avatar).width(50).height(50).objectFit(ImageFit.Cover)
              .onError(() => { this.avatarUnavailable = true; })
          } else {
            SymbolGlyph($r('sys.symbol.person')).fontSize(24).fontColor([this.accent()])
          }
        }.width(50).height(50).backgroundColor(this.accentTint()).borderRadius(25).clip(true)
        Column({ space: 4 }) {
          Text(this.huaweiProfile?.name || '个人资料').fontSize(19).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.huaweiProfile ? '华为账号已登录' : '华为账号未登录').fontSize(13).fontColor($r('app.color.pigo_muted'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.huaweiProfile) {
          Button(this.accountBusy ? '请稍候…' : '退出', { type: ButtonType.Normal })
            .id('huawei-signout').height(34).padding({ left: 12, right: 12 }).borderRadius(10)
            .fontSize(13).fontWeight(FontWeight.Medium)
            .backgroundColor(Color.Transparent).fontColor($r('app.color.pigo_muted'))
            .enabled(!this.accountBusy)
            .onClick(() => { void this.signOutHuawei(); })
        }
      }.width('100%')
      if (!this.huaweiProfile) {
        Button(this.accountBusy ? '请稍候…' : '使用华为账号登录')
          .chatAction().id('huawei-account').width('100%').height(44).enabled(!this.accountBusy)
          .backgroundColor(this.accent()).fontColor(this.accentForeground())
          .onClick(() => { void this.signInHuawei(); })
      }
      if (this.accountNotice) {
        Text(this.accountNotice).fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      if (this.huaweiProfile) {
        Divider().color($r('app.color.pigo_line'))
        Row({ space: 10 }) {
          Text(this.cloudSyncStatus || '通过华为云空间同步电脑列表和主题偏好。')
            .fontSize(13).fontColor($r('app.color.pigo_muted')).layoutWeight(1)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button(this.cloudSyncBusy ? '同步中…' : '立即同步').chatAction().id('sync-account-settings')
            .height(34).fontSize(13).padding({ left: 12, right: 12 })
            .enabled(!this.cloudSyncBusy && !this.accountBusy)
            .onClick(() => { this.scheduleCloudSync(0); })
        }.width('100%')
      }
    }.width('100%').padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }

  @Builder
  mineEntry(page: string, label: string, summary: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Stack() {
          if (page === 'computers') {
            SymbolGlyph($r('sys.symbol.computer')).fontSize(21).fontColor([this.accent()])
          } else {
            Row({ space: 3 }) {
              Blank().width(6).height(6).borderRadius(3).backgroundColor(this.accentFor(THEME_STYLES[0]))
              Blank().width(6).height(6).borderRadius(3).backgroundColor(this.accentFor(THEME_STYLES[1]))
              Blank().width(6).height(6).borderRadius(3).backgroundColor(this.accentFor(THEME_STYLES[2]))
            }
          }
        }.width(40).height(40).backgroundColor(this.accentTint()).borderRadius(12)
        Column({ space: 4 }) {
          Text(label).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          Text(summary).fontSize(13).fontColor($r('app.color.pigo_muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
      }.width('100%').padding(14)
    }.id(`mine-${page}`).width('100%').padding(0).backgroundColor($r('app.color.pigo_panel'))
      .border({ width: 1, radius: 16, color: $r('app.color.pigo_line') })
      .onClick(() => { this.minePage = page; })
  }

  @Builder
  themeSettings() {
    Column({ space: 10 }) {
      Text('显示模式').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
      Row({ space: 4 }) {
        ForEach(APPEARANCE_MODES, (mode: AppearanceMode) => {
          Button(mode.label, { type: ButtonType.Normal }).chatAction().layoutWeight(1).height(38).padding(4).borderRadius(10)
            .id(`appearance-${mode.id}`).accessibilitySelected(this.modeId === mode.id)
            .backgroundColor(this.modeId === mode.id ? this.accent() : Color.Transparent)
            .fontColor(this.modeId === mode.id ? this.accentForeground() : $r('app.color.pigo_muted'))
            .onClick(() => { this.selectAppearanceMode(mode); })
        }, (mode: AppearanceMode) => mode.id)
      }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
    }.width('100%').padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
    Column({ space: 6 }) {
      Text('主题配色').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
      ForEach(THEME_STYLES, (style: ThemeStyle) => {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            Blank().width(22).height(22).borderRadius(11).backgroundColor(this.accentFor(style))
            Text(style.label).fontSize(15).fontColor($r('app.color.pigo_text')).layoutWeight(1)
            if (this.themeId === style.id) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17).fontColor([this.accent()])
            }
          }.width('100%').padding({ left: 12, right: 12 })
        }.id(`theme-${style.id}`).width('100%').height(44).padding(0).borderRadius(12)
          .accessibilitySelected(this.themeId === style.id)
          .backgroundColor(this.themeId === style.id ? this.accentTint() : Color.Transparent)
          .onClick(() => { this.selectTheme(style.id); })
      }, (style: ThemeStyle) => style.id)
    }.width('100%').padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
    if (this.appearanceNotice) Text(this.appearanceNotice).fontSize(13).fontColor($r('app.color.pigo_warning'))
  }

  @Builder
  runNoticeSettings() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('运行结束通知').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        Text('任务结束时在应用顶部显示横幅').fontSize(13).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.runNoticesEnabled })
        .id('run-notice-setting').selectedColor(this.accent()).accessibilityText('运行结束通知')
        .onChange((enabled: boolean) => { void this.setRunNoticesEnabled(enabled); })
    }.width('100%').padding(14).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }

  private liveViewSummary(): string {
    if (this.liveViewStatus === 'rights') return '当前版本暂不支持系统实况窗';
    if (this.liveViewStatus === 'disabled') return '系统实况窗开关未开启，请在系统应用设置中开启';
    if (this.liveViewStatus === 'error') return '实况窗暂时不可用，将在运行期间自动重试';
    return '在状态栏、锁屏和通知中心显示当前任务状态';
  }

  @Builder
  liveViewSettings() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('任务实况窗').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        Text(this.liveViewSummary()).fontSize(13).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.liveViewsEnabled })
        .id('live-view-setting').selectedColor(this.accent()).accessibilityText('任务实况窗')
        .enabled(this.liveViewStatus !== 'rights')
        .onChange((enabled: boolean) => { void this.setLiveViewsEnabled(enabled); })
    }.width('100%').padding(14).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }

  @Builder
  glassSurface(radius: number) {
    Stack() {
      Row().width('100%').height('100%').borderRadius(radius).clip(true)
        .attributeModifier(immersiveSurface(this.darkMode))
      Row().width('100%').height('100%').borderRadius(radius)
        .border({ width: 1, color: this.darkMode ? '#38D5E5F4' : '#D9DDE5ED' })
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }

  @Builder
  headerSymbol(symbol: Resource, color: ResourceColor, size: number = 20) {
    Stack() {
      this.glassSurface(22)
      SymbolGlyph(symbol).fontSize(size).fontColor([color])
    }.width('100%').height('100%').accessibilityLevel('no-hide-descendants')
  }

  @Builder
  mineHeader() {
    Row({ space: 12 }) {
      if (this.minePage) {
        Button({ type: ButtonType.Normal }) {
          this.headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction()
          .accessibilityText('返回').enabled(!this.busy).onClick(() => { this.mineBack(); })
      }
      Text(this.minePage === 'theme' ? '系统主题' : this.minePage === 'computers' ?
        (this.addingComputer ? (this.pairingComputerId ? '添加连接' : '添加电脑') : '电脑管理') : '我的')
        .fontSize(this.minePage ? 20 : 26).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).layoutWeight(1)
      if (!this.minePage && this.computers.length) this.scheduleInboxButton()
    }.width('100%').height(this.headerHeight())
      .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
  }

  @Builder
  mineView() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.minePage === 'computers') {
          if (!this.addingComputer) {
            this.computerList()
            this.cloudComputerList()
          }
          if (this.addingComputer || !this.computers.length) {
            this.pairingForm()
          } else {
            Button('添加电脑').chatAction().id('add-computer').width('100%').height(46)
              .backgroundColor(this.accent()).fontColor(this.accentForeground())
              .enabled(!this.busy && !this.openingSession && !this.removeTarget)
              .onClick(() => { this.addComputerConnection(); })
          }
        } else if (this.minePage === 'theme') {
          this.themeSettings()
        } else {
          this.profileCard()
          this.mineEntry('computers', '电脑管理', this.isPaired ?
            `${this.computerTitle()} · ${this.reachable ? '已连接' : '离线'}` :
            (this.computers.length ? `${computerGroups(this.computers).length} 台电脑` : '配对并连接电脑'))
          this.mineEntry('theme', '系统主题', `${themeStyle(this.themeId).label} · ${appearanceMode(this.modeId).label}`)
          this.runNoticeSettings()
          this.liveViewSettings()
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 4, bottom: 16 })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder
  workspaceTreeRow(row: FileTreeRow) {
    if (row.kind === 'empty') {
      Text(row.name).fontSize(13).fontColor($r('app.color.pigo_muted'))
        .width('100%').height(42).padding({ left: 36 + Math.min(row.depth, 10) * 14 })
    } else {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          SymbolGlyph(row.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(13).fontColor([$r('app.color.pigo_muted')])
            .opacity(row.kind === 'directory' ? 1 : 0)
          if (row.kind === 'directory') {
            SymbolGlyph($r('sys.symbol.folder')).fontSize(18).fontColor([this.accent()])
          } else if (row.kind !== 'more') {
            SymbolGlyph($r('sys.symbol.doc')).fontSize(18).fontColor([$r('app.color.pigo_muted')]).width(19)
          }
          Text(row.name).fontSize(14).fontWeight(row.kind === 'directory' ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(row.kind === 'more' ? this.accent() : $r('app.color.pigo_text'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (row.kind === 'blocked') {
            Text('不可访问').fontSize(11).fontColor($r('app.color.pigo_muted'))
          }
        }.width('100%').padding({ left: 12 + Math.min(row.depth, 10) * 14, right: 12 })
      }.id(row.kind === 'more' ? `workspace-more-${row.path}` : `file-${row.path}`)
        .width('100%').height(44).padding(0).borderRadius(8).backgroundColor(Color.Transparent)
        .enabled(!this.busy && !this.openingSession && row.kind !== 'blocked')
        .accessibilityText(row.kind === 'directory' ? `${row.name}，${row.expanded ? '已展开' : '已收起'}` :
          row.kind === 'more' && row.path ? `加载更多，${row.path}` :
          row.kind === 'blocked' ? `${row.name}，不可访问` : row.name)
        .onClick(() => {
          if (row.kind === 'directory') void this.toggleFileDirectory(row.path);
          else if (row.kind === 'more') void this.loadFileDirectory(row.path, true);
          else void this.openFile(this.fileRoot, row.path);
        })
    }
  }

  @Builder
  fileEditorPage() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          this.headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.id('file-back').headerAction().accessibilityText(this.fileText !== this.fileOriginal ? '放弃修改' : '返回')
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
    Column() {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.folder')).fontSize(21).fontColor([this.accent()])
        Column({ space: 2 }) {
          Text(this.project || '项目根目录').fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.fileRoot).fontSize(11).fontColor($r('app.color.pigo_muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
      Divider().color($r('app.color.pigo_line'))
      if (this.fileTreeRows.length) {
        List({ initialIndex: this.fileTreeIndex }) {
          ForEach(this.fileTreeRows, (row: FileTreeRow) => {
            ListItem() { this.workspaceTreeRow(row) }
          }, (row: FileTreeRow): string => `${row.kind}:${row.expanded ?? false}:${row.path}`)
        }.width('100%').layoutWeight(1).padding({ top: 4, bottom: 4, left: 4, right: 4 }).scrollBar(BarState.Off)
          .onScrollIndex((start: number) => { this.fileTreeIndex = Math.max(0, start); })
      } else {
        Text(this.busy ? '正在读取目录…' : '未能读取目录')
          .fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%').padding(16)
      }
    }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Start).borderRadius(16)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
      .clip(true)
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
        }.width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
          .border({ width: 1, color: $r('app.color.pigo_line') })
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
        }.width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
          .border({ width: 1, color: $r('app.color.pigo_line') })
      }.width('100%').padding({ top: 4, bottom: 16 })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder
  chatHeader() {
    Row({ space: 10 }) {
      if (this.showSettings) {
        Button({ type: ButtonType.Normal }) {
          this.headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().accessibilityText('返回会话').onClick(() => { this.showSettings = false; })
      } else if (!this.dockedSessions() && !this.showFiles) {
        Button({ type: ButtonType.Normal }) {
          this.headerSymbol($r('sys.symbol.line_2_horizontal'), $r('app.color.pigo_text'), 20)
        }.id('history').headerAction()
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
            Text(this.reachable ? (this.project ? `${this.project} · ${this.computerTitle()}` : this.computerTitle()) :
              `离线 · ${this.computerTitle()}`)
              .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').onClick(() => { if (!this.dockedSessions() && !this.showFiles) this.setDrawer(true); })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.showFiles) {
        Button({ type: ButtonType.Normal }) {
          this.headerSymbol($r('sys.symbol.arrow_clockwise'), $r('app.color.pigo_text'), 19)
        }.id('file-refresh').headerAction().accessibilityText('刷新工作区')
          .enabled(!this.busy && !this.openingSession && this.reachable)
          .onClick(() => { void this.loadFileDirectory(''); })
      } else if (!this.showSettings) {
        Row({ space: 6 }) {
          this.scheduleInboxButton()
          Button({ type: ButtonType.Normal }) {
            this.headerSymbol($r('sys.symbol.square_and_pencil'), this.accent(), 19)
          }.id('new-task').headerAction().accessibilityText('在当前工作区新建会话')
            .enabled(this.reachable && !this.busy && !this.openingSession && this.hostAvailable &&
              !!this.workspaceCwd && this.projects.includes(this.workspaceCwd))
            .onClick(() => { this.activeTab = 'tasks'; void this.requestAction('/new', { cwd: this.workspaceCwd }); })
          Button({ type: ButtonType.Normal }) {
            Stack() {
              this.glassSurface(22)
              Image($r('app.media.ic_more')).width(20).height(20).fillColor($r('app.color.pigo_text'))
            }.width('100%').height('100%').accessibilityLevel('no-hide-descendants')
          }.id('session-settings').headerAction().accessibilityText('更多操作')
            .bindMenu([
              { value: '模型与会话设置', action: () => {
                if (this.reachable && this.currentId) void this.requestAction('/models');
              } },
              { value: '切换电脑', action: () => { if (!this.busy) this.openComputers(); } }
            ])
        }
      }
    }.width('100%').height(this.headerHeight())
      .border({ width: { bottom: 1 }, color: $r('app.color.pigo_line') })
  }

  @Builder
  pageHeader() {
    if (this.activeTab === 'mine') {
      this.mineHeader()
    } else {
      this.chatHeader()
    }
  }

  @Builder
  chat() {
    this.runningStrip()
    if (this.showFiles) {
      this.workspaceFiles()
    } else if (this.showSettings) {
      this.sessionSettings()
    } else if (this.activeTab === 'pending') {
      this.taskView()
    } else if (this.noSession) {
      this.welcome()
    } else {
      if (!this.reachable && !this.offlineDismissed) this.offlineNotice(false)
      if (this.interaction) this.pendingCard(this.interaction)
      if (this.pendingSend && !this.busy) {
        Row({ space: 8 }) {
          Button('核对发送').chatAction().id('check-send').enabled(this.reachable).onClick(() => { void this.checkSend(); })
          Button('保留草稿').chatAction().id('keep-draft').onClick(() => {
            this.unconfirmed.delete(this.draftKey(this.currentId));
            this.pendingSend = undefined;
            this.status = '已保留草稿，未重发。';
          })
        }.width('100%')
      }
      Stack({ alignContent: Alignment.BottomEnd }) {
        ForEach([this.currentId], (transcriptId: string) => {
          Scroll(this.transcript) {
            Column({ space: 10 }) {
              if (this.historyCursor) {
                Button('更早的消息').chatAction().id('history-more').enabled(this.reachable && !this.busy)
                  .onClick(() => { void this.loadHistory(); })
              }
              if (!this.messages.length && !this.liveText && !this.liveTools.length && !this.liveThinking && this.idle) {
                this.welcome(true)
              }
              ForEach(this.messages, (message: ChatMessage) => {
                if (message.text || message.thinking || message.imageCount) {
                  Row() {
                    Column({ space: 8 }) {
                      if (message.thinking) this.thinkingCard(message.id, message.thinking, message.thinkingMs ?? -1,
                        this.thinkingOpenIds.includes(message.id))
                      if (message.text) {
                        if (message.role === 'user') {
                          Text(message.text).fontSize(16).lineHeight(26)
                            .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.pigo_text'))
                        } else {
                          this.richChatText(message.text, this.workspaceCwd)
                        }
                        if (this.messageFiles(message).length) {
                          Flex({ wrap: FlexWrap.Wrap }) {
                            ForEach(this.messageFiles(message), (path: string) => {
                              Column() {
                                this.fileChip(path, message.role !== 'user')
                              }.margin({ right: 8, bottom: 8 })
                            }, (path: string) => path)
                          }.width('100%')
                        }
                        if (message.textTruncated) {
                          Button(this.loadingMessageText === message.id ? '正在加载全文…' : '查看完整回复').chatAction()
                            .enabled(this.reachable && !this.loadingMessageText)
                            .onClick(() => { void this.showFullReply(message.id); })
                        } else if (message.role !== 'user') {
                          this.copyButton('复制回复', message.text)
                        }
                      }
                      if (message.imageCount) {
                        Column({ space: 6 }) {
                          this.historyImages(message.imageCount, this.currentId, message.id)
                        }.id(`image-message-${message.id}`).alignItems(HorizontalAlign.Start)
                      }
                    }.alignItems(HorizontalAlign.Start).padding(message.role === 'user' ?
                      { left: 14, right: 14, top: 10, bottom: 10 } : 0)
                      .width(message.role === 'user' ? undefined : '100%')
                      .constraintSize({ maxWidth: message.role === 'user' ? '88%' : '100%' })
                      .backgroundColor(message.role === 'user' ? this.accentTint() : Color.Transparent)
                      .borderRadius({ topLeft: 17, topRight: 6, bottomLeft: 17, bottomRight: 17 })
                  }.width('100%').justifyContent(message.role === 'user' ? FlexAlign.End : FlexAlign.Start)
                    .padding({ top: message.role === 'user' ? 14 : 8, bottom: 4 })
                }
                this.toolGroup(message.tools ?? [], message.id)
              }, (message: ChatMessage) => this.transcriptMessageKey(message))
              this.toolGroup(this.unlistedLiveTools(), '')
              if (this.liveThinking) this.thinkingCard('', this.liveThinking, -1, this.liveThinkingOpen)
              if (this.liveText) {
                Column({ space: 8 }) {
                  this.richChatText(this.liveText, this.workspaceCwd)
                  if (messageFileChips(this.liveText, this.workspaceCwd).length) {
                    Flex({ wrap: FlexWrap.Wrap }) {
                      ForEach(messageFileChips(this.liveText, this.workspaceCwd), (path: string) => {
                        Column() {
                          this.fileChip(path, true)
                        }.margin({ right: 8, bottom: 8 })
                      }, (path: string) => path)
                    }.width('100%')
                  }
                }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 10, bottom: 18 })
              }
              ForEach(this.queuedSteering.filter((message: QueuedSteering): boolean => message.sessionKey === this.draftKey(this.currentId)),
                (message: QueuedSteering) => {
                  Row() {
                    Column({ space: 6 }) {
                      if (message.text) Text(message.text).fontSize(16).lineHeight(26)
                        .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.pigo_text'))
                      if (message.imageCount) Text(`图片 × ${message.imageCount}`).fontSize(13).fontColor($r('app.color.pigo_muted'))
                      ForEach(message.files, (name: string) => {
                        Text(name).fontSize(13).fontColor($r('app.color.pigo_muted'))
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      })
                      Text('排队中').fontSize(12).fontColor($r('app.color.pigo_muted'))
                    }.alignItems(HorizontalAlign.Start).padding(13).constraintSize({ maxWidth: '88%' })
                      .backgroundColor(this.accentTint()).borderRadius({ topLeft: 17, topRight: 6, bottomLeft: 17, bottomRight: 17 })
                  }.width('100%').justifyContent(FlexAlign.End).padding({ top: 10, bottom: 4 })
                }, (message: QueuedSteering) => message.id)
            }.width('100%').padding({ top: 10, right: 6, bottom: 8 })
              .onAreaChange((_oldArea: Area, newArea: Area) => {
                this.positionTranscript(transcriptId, Number(newArea.height));
              })
          }.width('100%').height('100%').align(Alignment.TopStart)
            .scrollBar(BarState.Off)
            .onTouch((event: TouchEvent) => {
              // 点击手势会被带 copyOption 的消息文本夺走，改用触摸广播：手指一按下就收键盘。
              if (event.type === TouchType.Down && this.keyboardHeight > 0) this.dismissKeyboard();
            })
            .onWillScroll((_xOffset: number, yOffset: number, _state: ScrollState, source: ScrollSource) => {
              if (yOffset < -2 && source !== ScrollSource.SCROLLER && source !== ScrollSource.SCROLLER_ANIMATION) {
                this.transcriptFollow = false;
              }
            })
            .onScrollEdge((side: Edge) => {
              if (side === Edge.Bottom) this.transcriptFollow = true;
            })
            .onAreaChange((oldArea: Area, newArea: Area) => {
              this.transcriptViewport = Number(newArea.height);
              if (this.transcriptFollow && (oldArea.width !== newArea.width || oldArea.height !== newArea.height)) {
                // Wait for the transcript to finish wrapping at the new width before scrolling.
                setTimeout(() => {
                  if (this.currentId === transcriptId && this.transcriptFollow) {
                    this.transcript.scrollTo({ xOffset: 0, yOffset: this.transcriptContentHeight, animation: false });
                  }
                }, 0);
              }
            })
        }, (transcriptId: string) => transcriptId)
        if (!this.transcriptFollow) {
          Button({ type: ButtonType.Normal }) {
            this.headerSymbol($r('sys.symbol.chevron_down'), $r('app.color.pigo_text'), 19)
          }.id('scroll-bottom').headerAction().margin({ right: 6, bottom: 10 })
            .shadow({ radius: 10, offsetY: 2, color: this.darkMode ? '#60000000' : '#1F637587' })
            .accessibilityText('滚动到最新消息')
            .onClick(() => { this.transcriptFollow = true; this.transcript.scrollEdge(Edge.Bottom); })
        }
      }.layoutWeight(1).width('100%')
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
        }.width('100%').padding(4)
        .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') }).borderRadius(14)
        .id('command-palette')
      }
      this.composer()
    }
  }

  @Builder
  composerMenuAction(label: string, symbol: Resource, id: string, enabled: boolean, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 8 }) {
        SymbolGlyph(symbol).fontSize(26).fontColor([$r('app.color.pigo_text')])
        Text(label).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
      }.width('100%').justifyContent(FlexAlign.Center)
    }.id(id).layoutWeight(1).height(86).padding(0).borderRadius(14)
      .backgroundColor($r('app.color.pigo_control')).enabled(enabled).onClick(action)
  }

  @Builder
  skillPicker() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([$r('app.color.pigo_text')])
      }.width(44).height(44).borderRadius(12).padding(0).backgroundColor(Color.Transparent)
        .accessibilityText('返回添加菜单').onClick(() => { this.showSkillPicker = false; })
      Text('技能').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
    }.width('100%')
    if (this.attachments.length) {
      Text('使用技能前请先移除附件。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
    }
    if (this.commandsLoading) {
      Text('正在加载技能…').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
    } else if (this.commandError) {
      Button(this.commandError).chatAction().width('100%')
        .onClick(() => { void this.loadCommands(); })
    } else if (!this.availableSkills().length) {
      Text('当前会话没有可用技能。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
    } else {
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.availableSkills(), (row: CommandRow) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 4 }) {
                Text(row.name.replace(/^skill:/, '')).fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                if (row.description) {
                  Text(row.description).fontSize(13).fontColor($r('app.color.pigo_muted'))
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.id(`composer-skill-${row.name}`).width('100%').constraintSize({ minHeight: 48 })
              .padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12)
              .backgroundColor($r('app.color.pigo_control'))
              .enabled(this.reachable && !this.openingSession && !this.pendingSend)
              .onClick(() => { this.pickSkill(row); })
          }, (row: CommandRow) => row.name)
        }.width('100%')
      }.width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
        .constraintSize({ maxHeight: Math.min(320, Math.max(72, this.windowHeight - 180)) })
    }
  }

  @Builder
  composerMenu() {
    Column({ space: 12 }) {
      if (this.showSkillPicker) {
        this.skillPicker()
      } else {
        Row({ space: 8 }) {
          this.composerMenuAction('拍照', $r('sys.symbol.camera'), 'composer-camera', this.acceptsImage, () => {
            this.showComposerMenu = false;
            void this.attachImage('camera');
          })
          this.composerMenuAction('照片', $r('sys.symbol.picture'), 'composer-photos', this.acceptsImage, () => {
            this.showComposerMenu = false;
            void this.attachImage('gallery');
          })
          this.composerMenuAction('添加文件', $r('sys.symbol.paperclip'), 'composer-files', true, () => {
            this.showComposerMenu = false;
            void this.attachFile();
          })
        }.width('100%')
        if (!this.acceptsImage) {
          Text('当前模型不支持图片输入。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
        }
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(22).fontColor([$r('app.color.pigo_text')])
            Text('技能').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([$r('app.color.pigo_muted')])
          }.width('100%')
        }.id('composer-skills').width('100%').height(48).padding({ left: 10, right: 10 })
          .borderRadius(12).backgroundColor(Color.Transparent).onClick(() => { this.openSkillPicker(); })
      }
    }.id('composer-menu').width('100%').constraintSize({ maxWidth: 560 })
      .padding({ left: 16, right: 16, top: 14, bottom: 16 })
  }

  @Builder
  composer() {
    Column({ space: 2 }) {
      if (this.attachments.length) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.attachments, (item: DraftAttachment, index: number) => {
              Stack({ alignContent: Alignment.TopEnd }) {
                if (item.kind === 'image' && item.image) {
                  Image(item.image.preview).id(`attachment-${index}`).width(64).height(64).borderRadius(10)
                    .objectFit(ImageFit.Cover)
                } else if (item.kind === 'file') {
                  Column({ space: 3 }) {
                    Text(item.file ? this.fileIcon(item.file.name) : '文件').fontSize(15).fontColor($r('app.color.pigo_muted'))
                    Text(item.name).fontSize(12).fontColor($r('app.color.pigo_text')).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 150 })
                    Text(this.fileSize(item.size)).fontSize(11).fontColor($r('app.color.pigo_muted'))
                  }.justifyContent(FlexAlign.Center).width('100%').height('100%')
                }
                Button({ type: ButtonType.Circle }) {
                  SymbolGlyph($r('sys.symbol.xmark')).fontSize(11).fontColor([$r('app.color.pigo_text')])
                }.id(`remove-attachment-${index}`).width(26).height(26).backgroundColor($r('app.color.pigo_selected'))
                  .accessibilityText(`移除附件 ${item.name}`)
                  .enabled(!this.busy && !this.pendingSend)
                  .onClick(() => { this.removeAttachment(index); })
              }.width(item.kind === 'image' ? 64 : 170).height(64)
                .borderRadius(item.kind === 'image' ? 10 : 12)
                .backgroundColor(item.kind === 'image' ? Color.Transparent : $r('app.color.pigo_control'))
                .padding(item.kind === 'file' ? 6 : 0)
            }, (item: DraftAttachment, index: number) => `${index}-${item.kind}-${item.name}-${item.size}`)
          }.padding({ bottom: 2 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start)
          .width('100%').height(70).padding({ left: 6, right: 6 })
      }
      if (this.voiceMode) {
        Button({ type: ButtonType.Normal }) {
          Text(this.voicePreparing ? '正在准备…' : this.voiceFinishing ? (this.voiceCancelling ? '按住说话' : '正在转文字…') : this.recording ? (this.holdCancel ? '松开取消' : '松开发送') : '按住说话')
            .fontSize(16).fontColor(this.holdCancel ? $r('app.color.pigo_error') : $r('app.color.pigo_text')).maxLines(1)
        }.id('hold-to-talk').width('100%').height(44).borderRadius(12)
          .backgroundColor(this.recording ? (this.holdCancel ? $r('app.color.pigo_error_panel') : $r('app.color.pigo_selected')) : $r('app.color.pigo_control'))
          .enabled(!!this.currentId && this.reachable && !this.pendingSend && !this.busy && !this.openingSession)
          .onTouch((event: TouchEvent) => { this.holdTouch(event); })
      } else {
        TextArea({ placeholder: !this.reachable ? '设备离线' : this.windowWidth < 360 ? '输入消息' : '输入消息，/ 唤起命令',
          text: this.draft })
          .id('draft').width('100%').constraintSize({ minHeight: 42, maxHeight: 108 }).onFocus(() => { this.armTranscriptFollow(); })
          .fontSize(16).fontColor($r('app.color.pigo_text')).placeholderColor($r('app.color.pigo_muted')).backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6, top: 8, bottom: 8 })
          .enabled(!this.pendingSend).onChange((value: string) => { this.draft = value; this.syncCommandPalette(); })
      }
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph(this.voiceMode ? $r('sys.symbol.keyboard') : $r('sys.symbol.mic')).fontSize(21)
            .fontColor([this.voiceMode ? this.accent() : $r('app.color.pigo_muted')])
        }.id('voice-toggle').width(44).height(44).padding(0).backgroundColor(Color.Transparent).borderRadius(12)
          .accessibilityText(this.voiceMode ? '切换到文字输入' : '切换到语音输入')
          .enabled(!!this.currentId && !this.pendingSend && !this.busy && !this.recording && !this.voicePreparing && !this.voiceFinishing)
          .onClick(() => { this.voiceMode = !this.voiceMode; this.liveVoiceText = ''; this.status = ''; if (this.voiceMode) this.dismissKeyboard(); })
        Button({ type: ButtonType.Normal }) {
          Row({ space: 5 }) {
            Text(this.modelLabel || '选择模型').fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.pigo_muted')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '85%' })
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.pigo_muted')])
          }
        }.id('model-pill').height(44).padding({ left: 6, right: 6 }).borderRadius(10)
          .constraintSize({ maxWidth: '48%' }).backgroundColor(Color.Transparent)
          .accessibilityText(this.modelLabel ? `切换模型，当前为${this.modelLabel}` : '切换模型')
          .enabled(this.reachable && !this.busy && !this.openingSession && !!this.currentId && this.idle && !this.queued)
          .onClick(() => { void this.openModelMenu(); })
          .bindSheet($$this.showModelMenu, this.modelSheet(), {
            detents: ['60%', SheetSize.LARGE], preferType: SheetType.BOTTOM, dragBar: true, showClose: false,
            backgroundColor: $r('app.color.pigo_panel'), maskColor: '#66000000'
          })
        Blank()
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(21).fontColor([$r('app.color.pigo_muted')])
        }.id('attach-image').width(44).height(44).padding(0).backgroundColor(Color.Transparent).borderRadius(12)
          .accessibilityText('添加附件或技能')
          .enabled(!!this.currentId && this.reachable && !this.busy && !this.openingSession && !this.pendingSend &&
            !this.recording && !this.voicePreparing && !this.voiceFinishing)
          .onClick(() => { this.openComposerMenu(); })
          .bindSheet($$this.showComposerMenu, this.composerMenu(), {
            height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM, showClose: false,
            backgroundColor: $r('app.color.pigo_panel'), maskColor: '#66000000'
          })
        if (this.idle || this.hasDraft()) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(20)
              .fontColor([this.canSend() ? this.accentForeground() : $r('app.color.pigo_muted')])
          }.id('send').width(44).height(44).padding(0).borderRadius(13)
            .backgroundColor(this.canSend() ? this.accent() : $r('app.color.pigo_control'))
            .accessibilityText(this.idle ? '发送消息' : '发送消息以引导当前任务').enabled(this.canSend())
            .onClick(() => { void this.send(); })
        } else {
          Button({ type: ButtonType.Normal }) {
            Rect().width(12).height(12).fill(this.accentForeground()).radius(2)
          }.id('abort').width(44).height(44).borderRadius(13).backgroundColor(this.accent())
            .accessibilityText('停止生成').enabled(this.reachable && !this.busy && !this.openingSession)
            .onClick(() => { void this.requestAction('/abort', { id: this.currentId }); })
        }
      }.width('100%')
    }.width('100%').padding({ left: 7, right: 7, top: 6, bottom: 6 }).backgroundColor($r('app.color.pigo_panel'))
      .border({ width: 1, color: $r('app.color.pigo_line') }).borderRadius(18)
  }

  private cacheChat(session: SessionState): void {
    const key = this.draftKey(session.id);
    const start = Math.max(0, this.messages.length - 60);
    const current: SessionState = this.syncMode === 'sequenced'
      ? { id: session.id, cwd: session.cwd, name: this.sessionName, idle: this.idle, runId: this.runId || null,
        queued: this.queued, acceptsImage: this.acceptsImage, model: this.currentModel, thinkingLevel: this.currentLevel }
      : session;
    this.chatCache.delete(key);
    this.chatCache.set(key, {
      session: current, messages: this.messages.slice(start), liveText: this.liveText,
      liveSeq: this.liveSeq, liveThinking: this.liveThinking, liveThinkSeq: this.liveThinkSeq,
      tools: this.liveTools.slice(0),
      historyCursor: start > 0 ? this.messages[start].id : this.historyCursor,
      interaction: this.interaction
    });
    if (this.chatCache.size > 8) this.chatCache.delete(Array.from(this.chatCache.keys())[0]);
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
      this.focusActiveSpace();
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.showSessions = open; });
    if (open) void this.loadSessionStatus();
    // Reuse the catalog for quick drawer toggles; stale data stays usable during refresh.
    if (open && this.reachable && (!this.sessionCatalogLoaded ||
      Date.now() - this.sessionCatalogUpdatedAt >= 30000 ||
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

  private focusActiveSpace(): void {
    if (!this.currentId) return;
    const path = this.workspaceCwd || this.sessions.find((row: SessionRow): boolean => row.id === this.currentId)?.cwd;
    if (path && (this.expandedSpaces.length !== 1 || this.expandedSpaces[0] !== path)) this.expandedSpaces = [path];
  }

  private updateSidebarRows(): void {
    const rows: SidebarRow[] = [];
    const visibleSessions = this.sessionView === this.loadedView ? this.sessions : [];
    if (this.sessionView === 'all') {
      const bySpace = new Map<string, SessionRow[]>();
      const paths = new Set<string>(this.projects);
      const expanded = new Set<string>(this.expandedSpaces);
      for (const session of visibleSessions) {
        if (!session.cwd) continue;
        if (this.hasWorkspaceDetails) paths.add(session.cwd);
        if (!expanded.has(session.cwd)) continue;
        let group = bySpace.get(session.cwd);
        if (!group) { group = []; bySpace.set(session.cwd, group); }
        group.push(session);
      }
      for (const path of paths) {
        rows.push({ key: `space:${path}:${this.workspaceName(path)}`, path: path, nested: false });
        for (const session of bySpace.get(path) ?? []) {
          rows.push({ key: this.sidebarSessionKey(session, true), session: session, nested: true });
        }
      }
    } else {
      for (const session of visibleSessions) {
        rows.push({ key: this.sidebarSessionKey(session, false), session: session, nested: false });
      }
    }
    this.sidebarRows.replace(rows);
    if (this.pendingLibraryReveal) setTimeout(() => { this.revealLibraryAnchor(); }, 0);
  }

  private sidebarSessionKey(session: SessionRow, nested: boolean): string {
    return `session:${session.id}:${nested}:${session.revision}:${session.pinned}:${session.archived}:${session.cwd ?? ''}:${session.name ?? ''}`;
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
    this.expandedSpaces = this.expandedSpaces.includes(path) ?
      this.expandedSpaces.filter((item: string): boolean => item !== path) : this.expandedSpaces.concat([path]);
    this.scheduleSidebarSave();
  }

  private sessionViewLabel(view: string): string {
    return view === 'all' ? '空间' : view === 'pinned' ? '置顶' : view === 'recent' ? '最近' : '归档';
  }

  private selectSessionView(view: string): void {
    if (this.busy || this.sessionLoading || !this.reachable) return;
    this.sessionView = view;
    this.scheduleSidebarSave();
    void this.loadSessions();
  }

  private sessionViewOptions(): MenuElement[] {
    return SIDEBAR_VIEWS.map((view: string): MenuElement => ({
      value: this.sessionViewLabel(view), action: (): void => { this.selectSessionView(view); }
    }));
  }

  // Sidebar choices are per computer: folders stay collapsed on connect unless the user opened them.
  private applySidebar(address: string): void {
    const entry = this.sidebarBook.entries.find((kept: SidebarEntry): boolean => kept.address === address);
    this.expandedSpaces = entry ? entry.state.expandedSpaces.slice() : [];
    this.sessionView = entry && SIDEBAR_VIEWS.includes(entry.state.sessionView) ? entry.state.sessionView : 'all';
    this.loadedView = this.sessionView;
  }

  private scheduleSidebarSave(): void {
    if (!this.base) return;
    const state: SidebarState = {
      expandedSpaces: this.expandedSpaces.slice(0, SIDEBAR_MAX_EXPANDED),
      sessionView: SIDEBAR_VIEWS.includes(this.sessionView) ? this.sessionView : 'all'
    };
    const entry: SidebarEntry = { address: this.base, state: state };
    const kept: SidebarEntry[] = this.sidebarBook.entries.filter((item: SidebarEntry): boolean => item.address !== this.base);
    kept.push(entry);
    this.sidebarBook = { version: 1, entries: kept.slice(0, SIDEBAR_MAX_ENTRIES) };
    if (this.sidebarSaveTimer !== -1) clearTimeout(this.sidebarSaveTimer);
    this.sidebarSaveTimer = setTimeout(() => { this.flushSidebarSave(); }, 300);
  }

  private flushSidebarSave(): void {
    if (this.sidebarSaveTimer !== -1) {
      clearTimeout(this.sidebarSaveTimer);
      this.sidebarSaveTimer = -1;
    }
    const vault = this.vault;
    if (vault) vault.saveSidebar(this.sidebarBook).catch(() => {});
  }

  @Builder
  modelSheet() {
    Column({ space: 12 }) {
      Text('模型与思考').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).width('100%')
      if (!this.idle || this.queued) {
        Text('等待当前任务和队列结束后可切换模型。').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      if ((this.currentModelOption()?.levels.length ?? 0) > 1) {
        Column({ space: 6 }) {
          Text('思考级别').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_muted')).width('100%')
          Row({ space: 4 }) {
            ForEach(this.currentModelOption()?.levels ?? [], (level: string) => {
              Button(this.thinkingLevelLabel(level), { type: ButtonType.Normal }).chatAction()
                .layoutWeight(1).height(36).padding(2).borderRadius(10).fontSize(13)
                .backgroundColor(this.currentLevel === level ? this.accent() : Color.Transparent)
                .fontColor(this.currentLevel === level ? this.accentForeground() : $r('app.color.pigo_muted'))
                .enabled(this.reachable && this.idle && !this.queued && !this.busy)
                .onClick(() => { this.showModelMenu = false; void this.applyThinkingLevelFromMenu(level); })
            }, (level: string) => level)
          }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.pigo_control'))
        }.width('100%')
      }
      List({ initialIndex: this.currentModelIndex(), space: 8 }) {
        ForEach(this.models, (model: ModelOption, index: number) => {
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text(model.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${model.provider}${model.image ? ' · 支持图片' : ''}`)
                    .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                if (this.isCurrentModel(model)) {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17).fontColor([this.accent()])
                }
              }.width('100%')
            }.id(`model-option-${index}`).width('100%').height(54).padding({ left: 14, right: 14 })
              .backgroundColor(this.isCurrentModel(model) ? this.accentTint() : $r('app.color.pigo_control'))
              .border({ width: this.isCurrentModel(model) ? 1 : 0, radius: 12, color: this.accent() })
              .accessibilitySelected(this.isCurrentModel(model))
              .enabled(this.reachable && this.idle && !this.queued && !this.busy)
              .onClick(() => { this.showModelMenu = false; void this.applyModelFromMenu(index); })
          }
        }, (model: ModelOption) => `${model.provider}-${model.id}`)
        if (!this.models.length) {
          ListItem() {
            Text('没有可用模型，请在电脑上检查 Pi CLI 的模型配置。').fontSize(13)
              .fontColor($r('app.color.pigo_muted')).width('100%')
          }
        }
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.width('100%').height('100%').constraintSize({ maxWidth: 560 })
      .padding({ left: 16, right: 16, top: 8, bottom: 20 })
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

  @Builder
  bottomTabs() {
    Stack() {
      this.glassSurface(32)
      this.bottomTabButtons()
    }.width('100%').height(this.bottomTabsHeight())
      .constraintSize({ maxWidth: 520 }).alignSelf(ItemAlign.Center).borderRadius(32)
      .shadow({ radius: 10, offsetY: 2, color: this.darkMode ? '#40000000' : '#12637587' })
  }

  @Builder
  bottomTabButtons() {
    Row({ space: 4 }) {
      ForEach(this.isPaired ? ['tasks', 'pending', 'files', 'mine'] : ['tasks', 'mine'], (tab: string) => {
        Button({ type: ButtonType.Normal }) {
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
          }
        }.id(`tab-${tab}`).layoutWeight(1).height(this.windowHeight < SHORT_WINDOW_HEIGHT ? 44 : 54)
          .borderRadius(24)
          .padding(0)
          .accessibilitySelected(this.activeTab === tab)
          .backgroundColor(Color.Transparent)
          .enabled(!this.busy).onClick(() => {
            this.dismissKeyboard();
            if (this.editingPath && this.fileText !== this.fileOriginal) {
              this.status = '请先保存或放弃文件修改。'; return;
            }
            if (tab === 'files') {
              if (!this.reachable || !this.workspaceCwd) { this.status = '请先连接电脑并打开一个任务。'; return; }
              if (this.activeTab === 'files' && this.showFiles) return;
              if (this.fileRoot !== this.workspaceCwd) {
                this.resetFileTree();
                this.fileRoot = this.workspaceCwd;
              }
              this.showFiles = true;
              this.status = '';
              if (!this.fileDirectories.has('')) void this.loadFileDirectory('');
            } else { this.showFiles = false; this.showSettings = false; }
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
          })
      }, (tab: string) => tab)
    }.width('100%').height('100%').padding({ left: 6, right: 6 })
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
  taskRow(session: SessionRow, nested: boolean) {
    Row({ space: 0 }) {
      Button({ type: ButtonType.Normal }) {
        Flex({ direction: this.compactSessionPane() ? FlexDirection.Column : FlexDirection.Row,
          justifyContent: this.compactSessionPane() ? FlexAlign.Center : FlexAlign.Start,
          alignItems: this.compactSessionPane() ? ItemAlign.Start : ItemAlign.Center }) {
          if (this.compactSessionPane()) {
            Text(session.name === '(no messages)' ? '新任务' : session.name || '未命名任务')
              .fontSize(14).fontColor($r('app.color.pigo_text')).width('100%').maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          } else {
            Text(session.name === '(no messages)' ? '新任务' : session.name || '未命名任务')
              .fontSize(16).fontColor($r('app.color.pigo_text')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }
          if (session.id === this.openingSessionId) {
            Text('正在打开…').id('session-opening').fontSize(11).fontColor(this.accent()).maxLines(1)
              .margin({ left: this.compactSessionPane() ? 0 : 8, top: this.compactSessionPane() ? 2 : 0 })
          } else if (this.sessionRunning(session.id)) {
            Row({ space: 4 }) {
              Text('').width(6).height(6).borderRadius(3)
                .backgroundColor(this.stateColor(this.sessionState(session.id)))
              Text(this.stateLabel(this.sessionState(session.id))).fontSize(11)
                .fontColor(this.stateColor(this.sessionState(session.id)))
            }.margin({ left: this.compactSessionPane() ? 0 : 8, top: this.compactSessionPane() ? 2 : 0 })
              .accessibilityText(this.stateLabel(this.sessionState(session.id)))
          }
        }.width('100%').height('100%')
      }.id(`session-${session.id}`).layoutWeight(1)
        .height(this.compactSessionPane() && (session.id === this.openingSessionId || this.sessionRunning(session.id)) ? 54 : 46)
        .padding({ left: this.compactSessionPane() ? (nested ? 16 : 6) : (nested ? 40 : 12), right: 2 })
        .backgroundColor(Color.Transparent).enabled(!this.busy && (this.reachable || session.id === this.currentId))
        .accessibilitySelected(session.id === this.currentId)
        .onClick(() => {
          if (this.openingSession) return;
          this.activeTab = 'tasks'; this.showSettings = false; this.showFiles = false;
          if (session.id === this.currentId) this.setDrawer(false);
          else void this.requestAction('/open', { id: session.id });
        })
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ic_more')).width(16).height(16).fillColor($r('app.color.pigo_muted'))
      }.id(`session-more-${session.id}`).width(this.compactSessionPane() ? 36 : 32).height(40).padding(0)
        .backgroundColor(Color.Transparent)
        .accessibilityText('任务操作').enabled(this.reachable && !this.busy).bindMenu([
          { value: session.pinned ? '取消置顶' : '置顶', action: () => { void this.updateSessionMeta(session, true); } },
          { value: session.archived ? '取消归档' : '归档', action: () => { void this.updateSessionMeta(session, false); } }
        ])
    }.width('100%').borderRadius(this.dockedSessions() ? 9 : 12)
      .backgroundColor(session.id === this.openingSessionId || (session.id === this.currentId && this.dockedSessions()) ?
        this.accentTint() : session.id === this.currentId ? $r('app.color.pigo_selected') : Color.Transparent)
  }

  @Builder
  taskView() {
    Scroll() {
      Column({ space: 24 }) {
        this.runningTasksSection()
        this.scheduledTasksSection()
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 16 })
    }.scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off).width('100%').layoutWeight(1)
      .align(Alignment.TopStart).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  runningTasksSection() {
      Column({ space: 10 }) {
        Text('运行中').fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
        ForEach(this.standaloneScheduleRuns(),
          (row: RunMessage) => {
            Text(`${row.run.name} · 定时任务运行中`).fontSize(15).fontColor($r('app.color.pigo_text'))
              .width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
              .border({ width: 1, color: $r('app.color.pigo_line') })
          }, (row: RunMessage) => row.key)
        if (this.reachable && this.allRunningRows().length) {
          ForEach(this.allRunningRows(), (row: RunningRow) => {
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
                    .backgroundColor(this.stateColor(this.sessionState(row.id)))
                  Text(`${row.id === this.currentId ? '当前 · ' : ''}${this.stateLabel(this.sessionState(row.id))}`)
                    .fontSize(12).fontColor(this.stateColor(this.sessionState(row.id)))
                }
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.pigo_muted')])
              }.width('100%').padding(14)
            }.id(`running-session-${row.id}`).width('100%').constraintSize({ minHeight: 60 }).padding(0)
              .backgroundColor(row.id === this.currentId ? this.accentTint() : $r('app.color.pigo_panel'))
              .border({ width: 1, radius: 16, color: row.id === this.currentId ? this.accent() : $r('app.color.pigo_line') })
              .accessibilityText(`${row.name || '后台任务'}，${this.stateLabel(this.sessionState(row.id))}，点击切换查看`)
              .enabled(!this.busy && !this.openingSession && (this.reachable || row.id === this.currentId))
              .onClick(() => {
                if (this.openingSession) return;
                if (row.id !== this.currentId) void this.requestAction('/open', { id: row.id });
                this.activeTab = 'tasks';
              })
          }, (row: RunningRow) => row.id)
        } else if (!this.standaloneScheduleRuns().length) {
          Row({ space: 12 }) {
            Stack() {
              SymbolGlyph(this.reachable ? $r('sys.symbol.clock') : $r('sys.symbol.computer'))
                .fontSize(20).fontColor([$r('app.color.pigo_muted')])
            }.width(40).height(40).borderRadius(12).backgroundColor($r('app.color.pigo_control'))
            Column({ space: 4 }) {
              Text(this.reachable ? '暂无运行中的任务' : '电脑未连接')
                .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%').padding(14).borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
            .border({ width: 1, color: $r('app.color.pigo_line') })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
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
  spaceMenu(path: string, epoch: number) {
    Menu() {
      if ((!this.hasWorkspaceDetails && this.projects.includes(path)) ||
        this.workspaces.some((row: WorkspaceRow): boolean => row.cwd === path)) {
        MenuItem({ content: '移除空间' }).id('space-remove').contentFontColor($r('app.color.pigo_error'))
          .onClick(() => { this.confirmCloseSpace(path, epoch); })
      }
    }
  }

  @Builder
  librarySpace(path: string) {
    Row({ space: 4 }) {
      Row({ space: this.compactSessionPane() ? 4 : 9 }) {
        SymbolGlyph($r('sys.symbol.folder')).fontSize(18).fontColor([this.accent()])
        Text(this.workspaceName(path)).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.pigo_text'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.hasWorkspaceDetails && !this.workspaces.some((row: WorkspaceRow): boolean => row.cwd === path)) {
          Text('未登记').fontSize(10).fontColor($r('app.color.pigo_muted'))
        }
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(this.compactSessionPane() ? 12 : 14).fontColor([$r('app.color.pigo_muted')])
          .rotate({ angle: this.expandedSpaces.includes(path) ? 0 : -90 })
      }.id(`space-${path}`).layoutWeight(1).height(44).onClick(() => { this.toggleSpace(path); })
        .bindContextMenu(this.spaceMenu(path, this.epoch), ResponseType.LongPress, { placement: Placement.BottomLeft })
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(16).fontColor([$r('app.color.pigo_muted')])
      }.id(`space-new-task-${path}`).width(40).height(44).padding(0).borderRadius(10)
        .backgroundColor(Color.Transparent)
        .accessibilityText(`在${this.workspaceName(path)}空间新建任务`)
        .visibility(this.projects.includes(path) ? Visibility.Visible : Visibility.Hidden)
        .enabled(!this.busy && !this.openingSession && this.projects.includes(path))
        .onClick(() => { this.createSpaceTask(path); })
    }.width('100%').padding({ left: this.compactSessionPane() ? 4 : 8 })
  }

  @Builder
  sessionLibrary() {
    if (!this.sessionLoading && !this.sessionCatalogFailed && this.loadedView === this.sessionView &&
      (this.sessionView === 'all' ? this.sidebarRows.totalCount() === 0 : this.sessions.length === 0)) {
      Text(this.reachable ? (this.sessionView === 'all' ? '暂无空间' : '暂无任务') : '连接电脑后加载任务')
        .fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%').padding(this.compactSessionPane() ? 6 : 16)
        .layoutWeight(1).align(Alignment.TopStart)
    } else {
      List({ scroller: this.library, space: 5 }) {
        LazyForEach(this.sidebarRows, (row: SidebarRow) => {
          ListItem() {
            if (row.path !== undefined) {
              this.librarySpace(row.path)
            } else if (row.session !== undefined) {
              this.taskRow(row.session, row.nested)
            }
          }
        }, (row: SidebarRow): string => row.key)
      }.cachedCount(4).layoutWeight(1).width('100%').scrollBar(BarState.Off)
        .padding({ bottom: 20 })
        .onAreaChange(() => { this.revealLibraryAnchor(); })
    }
  }

  @Builder
  sessionDrawer() {
    Column({ space: !this.dockedSessions() || this.compactSessionPane() || this.windowHeight < SHORT_WINDOW_HEIGHT ? 8 : 12 }) {
      Row({ space: this.compactSessionPane() ? 6 : 10 }) {
        if (this.dockedSessions()) {
          Stack() {
            SymbolGlyph($r('sys.symbol.computer')).fontSize(19).fontColor([this.accent()])
          }.width(34).height(34).borderRadius(10).backgroundColor(this.accentTint())
        }
        Button({ type: ButtonType.Normal }) {
          Row({ space: this.dockedSessions() ? 6 : 8 }) {
            if (!this.dockedSessions()) {
              SymbolGlyph($r('sys.symbol.computer')).fontSize(21).fontColor([this.accent()])
            }
            Text(this.computerTitle()).fontSize(this.compactSessionPane() ? 14 : this.dockedSessions() ? 17 : 19)
              .fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(this.dockedSessions() ? 1 : 0)
              .constraintSize({ maxWidth: this.dockedSessions() ? '100%' : '65%' })
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(13).fontColor([$r('app.color.pigo_muted')])
          }.width('100%')
        }.id('computers').layoutWeight(1).height(48).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('切换电脑').enabled(!this.busy).onClick(() => { this.openComputers(); })
        if (!this.dockedSessions()) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([$r('app.color.pigo_muted')])
          }.width(44).height(44).padding(0).backgroundColor(Color.Transparent).accessibilityText('关闭会话抽屉')
            .onClick(() => { this.setDrawer(false); })
        }
      }.width('100%').padding({ left: this.dockedSessions() ? 2 : 10 })
      Button({ type: ButtonType.Normal }) {
        Row({ space: this.compactSessionPane() ? 6 : 8 }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(18)
            .fontColor([this.dockedSessions() ? this.accentForeground() : this.accent()])
          Text('新建会话').fontSize(this.dockedSessions() ? 15 : 15).fontWeight(FontWeight.Medium)
            .fontColor(this.dockedSessions() ? this.accentForeground() : $r('app.color.pigo_text')).maxLines(1)
        }.justifyContent(FlexAlign.Center).width('100%')
      }.id('drawer-new-task').width('100%').height(44).padding(0)
        .backgroundColor(this.dockedSessions() ? this.accent() : $r('app.color.pigo_panel'))
        .border({ width: this.dockedSessions() ? 0 : 1, radius: 12, color: $r('app.color.pigo_line') })
        .enabled(this.reachable && !this.busy && !this.openingSession && this.hostAvailable &&
          (this.projects.length > 0 || this.canCreateWorkspace))
        .bindMenu(this.newTaskOptions())
      if (!this.reachable) this.offlineNotice(true, this.compactSessionPane())
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignContent: FlexAlign.SpaceBetween }) {
        ForEach(SIDEBAR_VIEWS, (view: string) => {
          Button({ type: ButtonType.Normal }) {
            Text(this.sessionViewLabel(view))
              .fontSize(13).fontColor(this.sessionView === view ? this.accentForeground() : $r('app.color.pigo_muted')).maxLines(1)
              .fontWeight(this.sessionView === view ? FontWeight.Medium : FontWeight.Regular)
          }.id(`session-view-${view}`).width(this.compactSessionPane() ? '49%' : '24%')
            .height(34).padding(0).borderRadius(9)
            .backgroundColor(this.sessionView === view ? this.accent() : Color.Transparent)
            .accessibilitySelected(this.sessionView === view).enabled(!this.busy && !this.sessionLoading && this.reachable)
            .onClick(() => { this.selectSessionView(view); })
        }, (view: string) => view)
      }.width('100%').padding(4).borderRadius(12).backgroundColor($r('app.color.pigo_control'))
      if (this.sessionLoading && (!this.sessionCatalogLoaded || this.loadedView !== this.sessionView)) {
        Text('正在加载任务…').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
      } else if (this.sessionCatalogFailed) {
        Button('任务加载失败，重试').chatAction().id('session-retry').width('100%').height(38)
          .enabled(this.reachable && !this.busy && !this.openingSession).onClick(() => { void this.loadSessions(); })
      }
      this.sessionLibrary()
      Row({ space: 6 }) {
        Blank().width(6).height(6).borderRadius(3)
          .backgroundColor(this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
        Text(this.base.split('://')[1] || '').id('active-computer').fontSize(11).fontColor($r('app.color.pigo_muted'))
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').padding({ left: this.compactSessionPane() ? 4 : 10 })
    }.id('session-sidebar').width(this.dockedSessions() ? this.sessionPaneWidth() : this.drawerWidth()).height('100%')
      .padding({ left: this.compactSessionPane() ? 8 : 12, right: 12,
        top: this.statusBarHeight + (this.compactSessionPane() ? 8 : 12), bottom: this.bottomPad() + 18 })
      .border({ width: { right: this.dockedSessions() ? 1 : 0 }, color: $r('app.color.pigo_line') })
      .backgroundColor($r('app.color.pigo_sidebar'))
      .transition(TransitionEffect.move(TransitionEdge.START))
      .onGestureJudgeBegin(() => this.dockedSessions() ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
      .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
      .onAppear(() => {
        // On entry, reveal the current session or its workspace when available.
        if (!this.dockedSessions()) this.focusActiveSpace();
        this.pendingLibraryReveal = !!this.currentId;
        this.updateSidebarRows();
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
      .backgroundColor($r('app.color.pigo_warning_panel')).borderRadius(12)
  }

  @Builder
  textPreviewPage(preview: ReceivedFilePreview) {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          this.headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.id('text-preview-close').headerAction().accessibilityText('返回').enabled(!this.savingPreview)
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
          this.headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.id('markdown-exit-landscape').headerAction().accessibilityText('退出横屏')
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
    }).backgroundColor($r('app.color.launch_background')).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }

  @Builder
  mainNavigation() {
    Navigation() {
      Column({ space: this.windowHeight < SHORT_WINDOW_HEIGHT ? 4 : 8 }) {
        if (this.loading) {
          this.welcome()
        } else if (this.activeTab === 'mine') {
          this.mineView()
        } else if (this.isPaired) {
          this.chat()
        } else {
          this.welcome()
        }
        if (!this.loading) {
          if (this.status) this.statusNotice()
          if (this.showRootBottomTabs()) this.bottomTabs()
        }
      }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
        .padding({ top: this.loading || (!this.isPaired && this.activeTab !== 'mine') ? 0 : 8,
          bottom: this.bottomPad() + 6 })
    }.width('100%').height('100%').constraintSize({ maxWidth: this.activeTab === 'mine' || this.showSettings ? 600 : 840 })
      .mode(NavigationMode.Stack).hideBackButton(true).hideToolBar(true)
      .title({ builder: this.pageHeader, height: this.headerHeight() }, { backgroundColor: Color.Transparent })
      .hideTitleBar(this.loading || (!this.isPaired && this.activeTab !== 'mine'))
      .padding({ left: 16, right: 16, top: this.statusBarHeight + 8 })
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
          Button(this.busy ? '正在创建…' : '创建并打开任务').id('new-space-submit').layoutWeight(2)
            .backgroundColor(this.accent()).fontColor(this.accentForeground())
            .enabled(!this.busy && this.reachable && !!this.newSpaceName.trim())
            .onClick(() => { void this.createWorkspaceTask(); })
        }.width('100%')
      }.width('90%').constraintSize({ maxWidth: 360 }).padding(18).borderRadius(20)
        .backgroundColor($r('app.color.pigo_panel'))
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
        .padding({ left: 14, right: 4, top: 6, bottom: 6 }).borderRadius(16)
        .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
        .shadow({ radius: 16, offsetY: 5, color: this.darkMode ? '#80000000' : '#25627085' })
    }.width('100%').justifyContent(FlexAlign.Center).padding({ left: 16, right: 16 })
      .margin({ top: this.statusBarHeight + 8 }).hitTestBehavior(HitTestMode.Transparent)
      .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  private isCurrentScheduleComputer(message: RunMessage): boolean {
    const current = this.computers.find((item: Companion): boolean => item.address === this.base);
    const origin = this.computers.find((item: Companion): boolean => item.address === message.address);
    return !!current && !!origin && computerGroupId(current) === computerGroupId(origin);
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

  @Builder
  scheduleInboxButton() {
    Button({ type: ButtonType.Normal }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        this.headerSymbol($r('sys.symbol.inbox'), $r('app.color.pigo_text'), 19)
        if (this.scheduleMessages.some((item: RunMessage): boolean => item.unread)) {
          Blank().width(8).height(8).borderRadius(4).backgroundColor(this.accent())
            .margin({ top: 4, right: 4 })
        }
      }
    }.id('schedule-inbox').headerAction().accessibilityText(this.scheduleMessages.some((item: RunMessage): boolean =>
      item.unread) ? '收件箱，有未读消息' : '收件箱')
      .onClick(() => { this.showScheduleInbox(); })
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
        if (message.unread) Blank().width(7).height(7).borderRadius(4).backgroundColor(this.accent())
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.pigo_muted')])
      }.width('100%').padding(12)
    }.id(`schedule-message-${message.run.id}`).width('100%').padding(0)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, radius: 16, color: $r('app.color.pigo_line') })
      .onClick(() => { this.showScheduleDetail(message); })
  }

  @Builder
  scheduleInboxDelete(message: RunMessage) {
    Button('删除').id(`schedule-dismiss-${message.run.id}`).width(72).height('100%').padding(0)
      .fontColor(Color.White).backgroundColor($r('app.color.pigo_error')).borderRadius(14)
      .accessibilityText(`删除收件箱消息 ${message.run.name}`)
      .onClick(() => { this.dismissScheduleMessage(message); })
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
  scheduleEditor() {
    Column({ space: 12 }) {
      Text('工作区').fontSize(13).fontColor($r('app.color.pigo_muted'))
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.folder')).fontSize(17).fontColor([this.accent()])
          Text(this.scheduleCwd ? this.workspaceName(this.scheduleCwd) : '选择已共享工作区')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('app.color.pigo_muted')])
        }.width('100%').padding({ left: 14, right: 14 })
      }.width('100%').height(44).padding(0).borderRadius(12)
        .backgroundColor($r('app.color.pigo_control'))
        .enabled(!this.scheduleEditing && this.projects.length > 0)
        .bindMenu(this.projects.map((cwd: string): MenuElement => ({
          value: this.workspaceName(cwd), action: () => { this.scheduleCwd = cwd; }
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
            .backgroundColor(this.scheduleKind === kind ? this.accent() : Color.Transparent)
            .fontColor(this.scheduleKind === kind ? this.accentForeground() : $r('app.color.pigo_muted'))
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
              .fontSize(19).fontColor([this.accent()])
          }.width(44).height(40).padding(0).borderRadius(12)
            .backgroundColor(this.accentTint())
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
        .backgroundColor(this.accent()).fontColor(this.accentForeground())
        .enabled(!this.scheduleSaving).onClick(() => {
          void this.updateSchedule(this.scheduleEditing ? 'edit' : 'create', this.scheduleEditing);
        })
    }.width('100%').alignItems(HorizontalAlign.Start)
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
          .enabled(!this.scheduleSaving && !this.scheduleLoading)
          .onClick(() => { void this.loadScheduleJobs(); })
      }.width('100%')
      Row({ space: 8 }) {
        Button('新建定时任务').chatAction().id('schedule-create').height(42)
          .backgroundColor(this.accent()).fontColor(this.accentForeground())
          .enabled(this.reachable && this.projects.length > 0 && !this.scheduleLoading &&
            !this.scheduleSaving && !this.scheduleListError).onClick(() => { this.editSchedule(); })
        Button('运行历史').chatAction().id('schedule-history').height(42)
          .onClick(() => { this.scheduleError = ''; this.schedulePage = 'history'; })
      }.width('100%')
      if (this.scheduleLoading) Text('正在读取电脑上的计划…').fontSize(14).fontColor($r('app.color.pigo_muted'))
      if (this.scheduleListError) Text(this.scheduleListError).fontSize(14).fontColor($r('app.color.pigo_error'))
      else if (!this.reachable && this.scheduleJobs.length) {
        Text('显示上次连接时的定时计划').fontSize(13).fontColor($r('app.color.pigo_muted'))
      } else if (this.reachable && !this.scheduleLoading && !this.scheduleJobs.length) {
        Text(this.projects.length ? '还没有定时任务' : '共享工作区后可创建定时任务').fontSize(14).fontColor($r('app.color.pigo_muted'))
      }
      ForEach(this.scheduleJobs, (job: ScheduleJob) => {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text(job.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
            Text(`${this.workspaceName(job.cwd)} · ${!job.enabled ? '已暂停' :
              job.nextAt === null ? '已结束' : `下次 ${scheduleTime(job.nextAt)}`}`)
              .fontSize(13).fontColor($r('app.color.pigo_muted'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_more')).width(18).height(18).fillColor($r('app.color.pigo_muted'))
          }.id(`schedule-operations-${job.id}`).width(40).height(40).padding(0).borderRadius(10)
            .backgroundColor(Color.Transparent).accessibilityText('定时任务操作')
            .enabled(this.reachable && !this.scheduleSaving && !this.scheduleLoading).bindMenu(this.scheduleJobMenu(job))
        }.width('100%').padding({ left: 14, right: 6, top: 12, bottom: 12 }).borderRadius(16)
          .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
      }, (job: ScheduleJob) => `${job.id}:${job.version}:${job.nextAt}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  scheduleOverlay() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          this.headerSymbol($r('sys.symbol.chevron_left'), $r('app.color.pigo_text'), 21)
        }.headerAction().accessibilityText('返回').enabled(!this.scheduleSaving)
          .onClick(() => { this.backFromSchedule(); })
        Text(this.schedulePage === 'inbox' ? '收件箱' : this.schedulePage === 'detail' ? '运行详情' :
          this.schedulePage === 'editor' ? (this.scheduleEditing ? '编辑定时任务' : '新建定时任务') : '运行历史')
          .layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
      }.width('100%').height(this.headerHeight())
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
              Text(this.computerTitle()).fontSize(13).fontColor($r('app.color.pigo_muted'))
              if (!this.scheduleMessages.some((item: RunMessage): boolean => this.isCurrentScheduleComputer(item))) {
                Text('暂无运行记录').fontSize(14).fontColor($r('app.color.pigo_muted'))
              }
              ForEach(this.scheduleMessages.filter((item: RunMessage): boolean => this.isCurrentScheduleComputer(item)),
                (message: RunMessage) => { this.scheduledMessageRow(message) },
                (message: RunMessage) => `${message.key}:${message.unread}`)
            }
          }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 6, bottom: 12 })
        }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
      }
      if (this.schedulePage === 'detail' && this.scheduleDetail?.run.sessionId) {
        if (this.isPaired && !this.isCurrentScheduleComputer(this.scheduleDetail)) {
          Text(`当前聊天在 ${this.computerTitle()}`).fontSize(13).fontColor($r('app.color.pigo_muted'))
        }
        Button(`在 ${this.scheduleDetail.computer} 打开会话`).chatAction().width('100%').height(46)
          .backgroundColor(this.accent()).fontColor(this.accentForeground())
          .enabled(!this.busy && !this.openingSession).onClick(() => {
            if (this.scheduleDetail) void this.openScheduledSession(this.scheduleDetail);
          })
      }
    }.id('schedule-overlay').width('100%').height('100%').padding({
      left: 16, right: 16, top: this.statusBarHeight + 8, bottom: this.bottomPad() + 8
    }).backgroundColor($r('app.color.launch_background')).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
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
    }.id('schedule-completion-banner').width('92%').constraintSize({ maxWidth: 440 }).padding(6).borderRadius(16)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        // Reserve the sidebar's space without rebuilding the conversation or moving the session list.
        Blank().width(this.dockedSessions() ? this.sessionPaneWidth() : 0)
        Stack({ alignContent: Alignment.Bottom }) {
          if (!this.darkMode && this.showRootBottomTabs()) {
            Row().width('100%').height(this.bottomTabsHeight() + this.bottomPad() + 18)
              .linearGradient({ direction: GradientDirection.Bottom,
                colors: [['#00FFFFFF', 0], ['#FFFFFF', 0.20], ['#FFFFFF', 1]] })
              .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          }
          this.mainNavigation()
        }.height('100%').layoutWeight(1)
          .onGestureJudgeBegin(() => this.dockedSessions() || this.showSessions || this.holdActive || this.recording ||
            this.voicePreparing || this.voiceFinishing || !this.isPaired || this.activeTab === 'mine'
            ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
          .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
      }.width('100%').height('100%').backgroundColor($r('app.color.launch_background'))
        .borderRadius({ topLeft: this.drawerOpen() ? 24 : 0, bottomLeft: this.drawerOpen() ? 24 : 0 })
        .clip(true).translate({ x: this.drawerOpen() ? this.drawerWidth() : 0 })
        .shadow({ radius: 24, offsetX: -5,
          color: this.drawerOpen() ? (this.darkMode ? '#A0000000' : '#50627085') : Color.Transparent })
        .opacity(this.drawerOpen() ? (this.darkMode ? 0.48 : 0.38) : 1)
        .accessibilityLevel(this.drawerOpen() || this.schedulePage ? 'no-hide-descendants' : 'auto')
      if (this.drawerOpen()) {
        Button({ type: ButtonType.Normal }).width('100%').height('100%').padding(0)
          .backgroundColor(Color.Transparent).borderRadius(0)
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
          }.id('voice-feedback').width(250).padding(26).alignItems(HorizontalAlign.Center).borderRadius(20)
            .backgroundColor(this.holdCancel ? '#B74747' : $r('app.color.pigo_control'))
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.editingPath || this.textFilePreview) {
        Stack({ alignContent: Alignment.Top }) {
          if (this.editingPath) this.fileEditorPage()
          if (this.textFilePreview) {
            Stack({ alignContent: Alignment.Top }) {
              this.textPreviewPage(this.textFilePreview)
            }.width('100%').height('100%').backgroundColor($r('app.color.launch_background'))
              .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
          }
        }.width('100%').height('100%').backgroundColor($r('app.color.launch_background'))
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
      }
      if (this.markdownTableReader) this.markdownTableReaderPage(this.markdownTableReader)
      if (this.showNewSpace) this.newSpaceDialog()
      if (this.runNotice) this.runCompletionBanner(this.runNotice)
      if (this.scheduleBanner && !this.schedulePage && !this.runNotice) {
        Row() {
          this.scheduledRunBanner(this.scheduleBanner)
        }.width('100%').justifyContent(FlexAlign.Center)
          .margin({ top: this.statusBarHeight + this.headerHeight() + 10 }).hitTestBehavior(HitTestMode.Transparent)
      }
      if (this.schedulePage) this.scheduleOverlay()
    }.width('100%').height('100%').padding({ left: this.leftInset, right: this.rightInset })
      .backgroundColor(this.drawerOpen() ? $r('app.color.pigo_sidebar') : $r('app.color.launch_background'))
      .clip(true)
      .bindSheet(this.showToolDetails, this.toolDetailsSheet(), {
        detents: ['65%', SheetSize.LARGE], dragBar: true, showClose: true,
        backgroundColor: $r('app.color.pigo_panel'), maskColor: '#99000000',
        onDisappear: () => { this.closeToolDetails(); }
      })
  }
}
