import { FrameCallback, KeyboardAvoidMode, window } from '@kit.ArkUI';
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
import { connectionLabel, validCompanion } from '../CompanionCheck';

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
  runId?: string;
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

interface StreamFrame {
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
}

interface BridgeReply {
  attachment?: UploadedAttachment;
  commands?: CommandRow[];
  runningSessionIds?: string[];
  runningSessions?: RunningRow[];
  path?: string;
  entries?: FileEntry[];
  text?: string;
  version?: string;
  models?: ModelOption[];
  current?: ModelOption;
  dispatched?: boolean;
  interaction?: PendingInteraction;
  state?: string;
  desktopHandoff?: boolean;
  projects?: string[];
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

class CachePaintFrame extends FrameCallback {
  private started: number;
  constructor(started: number) { super(); this.started = started; }
  onFrame(_time: number): void {}
  onIdle(_time: number): void { console.info(`[DEBUG-chat-cache] painted ${Date.now() - this.started}ms`); }
}

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
  .borderRadius(14)
}

@Entry
@Component
struct Index {
  @StorageProp('pigoDark') private darkMode: boolean = false;
  @StorageLink('pigoAddress') address: string = 'http://127.0.0.1:18977';
  @StorageLink('pigoTicket') @Watch('onLaunchTicket') launchTicket: string = '';
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
  private pendingSessionReveal: string = '';
  private navigationStarted: number = 0;
  @State private ticket: string = '';
  @State private pairingMode: string = 'usb';
  @State private pairingBundle: string = '';
  @State private lanCandidates: string[] = [];
  @State private isPaired: boolean = false;
  @State private loading: boolean = true;
  @State private computers: Companion[] = [];
  @State private removeTarget: string = '';
  @State private busy: boolean = false;
  @State private reachable: boolean = false;
  @State private idle: boolean = true;
  @State private runId: string = '';
  @State private queued: boolean = false;
  @State private acceptsImage: boolean = false;
  @State private attachments: DraftAttachment[] = [];
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
  private deltaPaintTimer: number = -1;
  private pendingLiveText: string = '';
  private pendingLiveThinking: string = '';
  @State private streamAlive: boolean = false;
  private streamReq?: http.HttpRequest = undefined;
  private streamTimer: number = -1;
  private streamGen: number = 0;
  @State private historyCursor?: string = undefined;
  @State private sessions: SessionRow[] = [];
  @State private runningSessionIds: string[] = [];
  @State private runningSessions: RunningRow[] = [];
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
  @State private expandedSpaces: string[] = [];
  @State private tasksExpanded: boolean = true;
  @State private offlineDismissed: boolean = false;
  @State private activeTab: string = 'tasks';
  @State private minePage: string = '';
  @State private addingComputer: boolean = false;
  @State private themeId: string = 'mint';
  @State private modeId: string = 'system';
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

  @State private sessionQuery: string = '';
  @State private sessionTotal: number = 0;
  @State private sessionCursor?: number = undefined;
  private loadedQuery: string = '';
  @State private sessionView: string = 'all';
  private loadedView: string = 'all';
  @State private interaction?: PendingInteraction = undefined;
  @State private interactionDraft: string = '';
  @State private pendingSend?: PendingSend = undefined;
  @State private desktopHandoff: boolean = false;
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
  @State private projects: string[] = [];
  private base: string = '';
  private token: string = '';
  private ca?: string;
  private pin?: string;
  private epoch: number = 0;
  private timer: number = -1;
  private visible: boolean = false;
  private polling: boolean = false;
  @State private sessionLoading: boolean = false;
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
  private libraryViewportY: number = -1;
  private libraryRowY: number = -1;
  private librarySpaceY: number = -1;
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
    if (this.showToolDetails) { this.closeToolDetails(); return true; }
    if (this.showModelMenu) { this.showModelMenu = false; return true; }
    if (this.showSessions) { this.showSessions = false; return true; }
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
    this.restoreSettings();
    this.restoreChain = this.restore();
    void this.restoreChain.then(() => {
      if (!this.isPaired && this.activeTab === 'tasks') this.openComputers();
      void this.consumeLaunchTicket();
    });
  }
  onPageShow(): void {
    this.visible = true;
    this.schedule(0);
    this.startStream();
    void this.checkHuaweiProfile().then(() => { this.scheduleCloudSync(0); });
  }
  onPageHide(): void {
    this.visible = false;
    this.cancelSchedule();
    this.stopStream();
    this.resetVoice();
    this.flushSidebarSave();
  }
  aboutToDisappear(): void {
    if (this.markdownTableReader) this.closeMarkdownTableReader();
    this.visible = false;
    this.cancelSchedule();
    this.stopStream();
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
      }).slice(0, MAX_COMPUTERS);
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

  private activateComputer(record: Companion): void {
    const usb = validUsb(record.address);
    this.epoch += 1;
    this.base = record.address;
    this.token = record.token;
    this.pairingMode = usb ? 'usb' : connectionLabel(record) === '公网' ? 'remote' : 'lan';
    if (usb) this.address = record.address;
    this.ca = usb ? undefined : record.ca;
    this.pin = usb ? undefined : record.pin;
    this.ticket = '';
    this.pairingBundle = '';
    this.removeTarget = '';
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
    this.schedule(0);
    this.stopStream();
    this.startStream();
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

  private schedule(delay: number): void {
    this.cancelSchedule();
    if (!this.isPaired || !this.visible) return;
    this.timer = setTimeout(() => { void this.poll(); }, delay);
  }

  private async request(path: string, input?: Payload, endpoint?: BridgeEndpoint): Promise<BridgeReply> {
    const req = http.createHttp();
    const address = endpoint ? endpoint.address : this.base;
    const token = endpoint ? endpoint.token : this.token;
    const ca = endpoint ? endpoint.ca : this.ca;
    const pin = endpoint ? endpoint.pin : this.pin;
    const imageRequest = path.startsWith('/message-image?');
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
        connectTimeout: 2500,
        readTimeout: path === '/open' || path === '/new' || path === '/close-workspace' ? 16000 : 6500
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
    if (!this.isPaired || !this.visible || !this.base || !this.token) return;
    this.streamTimer = setTimeout(() => { this.startStream(); }, delay);
  }

  private streamDown(gen: number, delay: number): void {
    if (gen !== this.streamGen) return;
    this.streamGen += 1;
    this.flushStreamDeltas();
    const req = this.streamReq;
    this.streamReq = undefined;
    this.streamAlive = false;
    if (req) req.destroy();
    this.scheduleStream(delay);
  }

  private startStream(): void {
    if (!this.isPaired || !this.visible || !this.base || !this.token || this.streamReq) return;
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
      if (buffer.length > 262144) buffer = '';
      let boundary = buffer.indexOf('\n\n');
      while (boundary >= 0) {
        const raw = buffer.substring(0, boundary);
        buffer = buffer.substring(boundary + 2);
        let payload = '';
        for (const line of raw.split('\n')) {
          if (line.startsWith('data: ')) payload += line.substring(6);
        }
        if (payload) this.handleFrame(payload);
        boundary = buffer.indexOf('\n\n');
      }
    });
    req.on('dataEnd', () => { this.streamDown(gen, 2000); });
    req.requestInStream(`${this.base}/events`, opts).then((code: number) => {
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
    if (frame.sessionId && frame.sessionId !== this.currentId) {
      if (frame.type === 'session/changed' || frame.type === 'ready') this.schedule(150);
      return;
    }
    if (frame.type === 'message/delta') {
      if (typeof frame.text === 'string' && frame.text && (frame.seq === undefined || frame.seq > this.liveSeq)) {
        this.pendingLiveText = (this.pendingLiveText + frame.text).slice(-MAX_LIVE_TEXT_LENGTH);
        if (frame.seq !== undefined) this.liveSeq = frame.seq;
        this.queueStreamPaint();
      }
      return;
    }
    if (frame.type === 'message/thinking') {
      if (typeof frame.text === 'string' && frame.text && (frame.seq === undefined || frame.seq > this.liveThinkSeq)) {
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
    if (frame.type === 'queue/status') {
      // steering 排队状态即时回传：不重置流式内容，只更新 runId 与 queued。
      if (typeof frame.runId === 'string' && frame.runId) this.runId = frame.runId;
      if (frame.queued !== undefined) this.queued = frame.queued;
      return;
    }
    if (frame.type === 'session/status') {
      this.liveRevision += 1;
      if (frame.idle === true) {
        this.idle = true;
        this.queued = false;
        this.runId = '';
        this.schedule(150);
      } else if (frame.idle === false) {
        this.flushStreamDeltas(false);
        this.idle = false;
        // 运行开始即携带 runId，手机可立即引导，无需等 /chat 轮询。
        if (typeof frame.runId === 'string' && frame.runId) this.runId = frame.runId;
        if (frame.queued !== undefined) this.queued = frame.queued;
        this.liveText = '';
        this.liveThinking = '';
        this.liveThinkSeq = 0;
        this.liveThinkingOpen = false;
        this.liveTools = [];
        this.liveSeq = 0;
      }
      return;
    }
    if (frame.type === 'message/final') {
      this.liveRevision += 1;
      if (frame.seq !== undefined && frame.seq >= this.liveSeq) {
        this.pendingLiveText = '';
        this.liveText = '';
        this.liveSeq = frame.seq;
      }
      if (frame.thinkingSeq !== undefined && frame.thinkingSeq >= this.liveThinkSeq) {
        this.pendingLiveThinking = '';
        this.liveThinking = '';
        this.liveThinkSeq = frame.thinkingSeq;
        this.liveThinkingOpen = false;
      }
      if (frame.reason === 'error') this.status = 'Pi 模型运行失败，请查看桌面中的错误详情。';
      this.schedule(200);
      return;
    }
    if (frame.type === 'prompt/unconfirmed') {
      this.status = 'Pi 未确认这次发送。请查看桌面；不会自动重发。';
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
        this.status = this.pairingMode === 'remote' ? '请导入桌面生成的公网配对包。' : '请导入桌面生成的局域网配对包。';
        return;
      }
    } else if (!validUsb(base) || !/^(\d{8}|[a-f0-9]{64})$/.test(ticket)) {
      this.status = '请输入本机 USB 地址和有效的一次性票据。';
      return;
    }
    if (this.computers.length >= MAX_COMPUTERS && !this.computers.some((record: Companion): boolean => record.address === base)) {
      this.status = '已保存 12 台电脑。请先移除不再使用的配对。';
      return;
    }
    this.busy = true;
    this.status = '';
    try {
      const result = await this.request('/pair', { ticket: ticket }, { address: base, token: '', ca: ca, pin: pin });
      if (!result.token || !/^[a-f0-9]{64}$/.test(result.token)) throw new Error('invalid_token');
      const record: Companion = { address: base, token: result.token, ca: ca, pin: pin };
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
        this.pairingMode !== 'usb' ? '无法建立安全连接。请检查网络、桌面服务与配对包。' : '无法连接电脑，请确认 USB 转发和 Pi Go 桥接服务。';
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
      this.status = this.pairingMode === 'remote' ? '未导入公网配对包，请扫描桌面「公网」二维码。' :
        '未导入局域网配对包，请扫描桌面「局域网」二维码。';
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
    this.sessionQuery = '';
    this.loadedQuery = '';
    this.sessionView = 'all';
    this.loadedView = 'all';
    this.sessionTotal = 0;
    this.sessionCursor = undefined;
    this.draft = '';
    this.showSessions = false;
    this.showSettings = false;
    this.models = [];
    this.modelLabel = '';
    this.setInteraction();
    this.pendingSend = undefined;
    this.desktopHandoff = false;
    this.projects = [];
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
    this.modelLabel = session.model ? `${session.model.name} · ${session.thinkingLevel ?? 'off'}` : '';
    this.currentModel = session.model;
    this.currentLevel = session.thinkingLevel ?? 'off';
    this.idle = session.idle;
    this.runId = session.runId ?? '';
    this.queued = session.queued ?? false;
    this.acceptsImage = session.acceptsImage ?? false;
  }

  private async poll(): Promise<void> {
    if (this.polling || this.openingSession) { this.schedule(350); return; }
    this.polling = true;
    const epoch = this.epoch;
    const liveRevision = this.liveRevision;
    try {
      const result = await this.request('/chat');
      if (epoch !== this.epoch) return;
      const connected = !this.reachable;
      this.reachable = true;
      this.offlineDismissed = false;
      const libraryVisible = this.showSessions || this.dockedSessions();
      if (libraryVisible && (!this.sessionCatalogLoaded || connected) && !this.busy) void this.loadSessions();
      if (libraryVisible) {
        this.sessionStatusAt = Date.now();
        void this.loadSessionStatus();
      } else if (this.backgroundActive() || Date.now() - this.sessionStatusAt >= 5000) {
        // Keep every running task visible on the chat header even with the drawer closed;
        // slow probing detects tasks started from the desktop side.
        this.sessionStatusAt = Date.now();
        void this.loadSessionStatus();
      }
      if (!result.session) {
        this.flushStreamDeltas(false);
        this.closeToolDetails();
        this.noSession = result.state === 'session_closed' ? '原会话已关闭，请在会话列表选择历史记录或其他会话。' :
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
      const incoming = result.messages ?? [];
      const currentSnapshot = moved || liveRevision === this.liveRevision;
      if (currentSnapshot) this.applySession(result.session);
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
      if (result.promptError === 'unconfirmed') this.status = 'Pi 未确认这次发送。请查看桌面；不会自动重发。';
      else if (result.promptError === 'model_error') this.status = 'Pi 模型运行失败，请查看桌面中的错误详情。';
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
        const delay = !this.reachable ? 1500 :
          this.streamAlive ? (this.idle ? 3000 : 1200) :
          this.idle ? 1500 : 650;
        this.schedule(delay);
      }
    }
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
      const result = await this.request(`/history?id=${encodeURIComponent(id)}&before=${encodeURIComponent(before)}`);
      if (epoch !== this.epoch || this.currentId !== id || result.session?.id !== id) return;
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
    this.sessionStatusLoading = true;
    try {
      const result = await this.request('/sessions/status');
      if (epoch === this.epoch) this.applyRunningStatus(result);
    } catch {
      if (epoch === this.epoch) this.applyRunningStatus(undefined);
    } finally { this.sessionStatusLoading = false; }
  }

  private applyRunningStatus(result?: BridgeReply): void {
    const rows = (result?.runningSessions ?? []).filter((row: RunningRow): boolean => !!row?.id);
    this.runningSessions = rows;
    const ids = rows.map((row: RunningRow): string => row.id).concat(result?.runningSessionIds ?? []);
    this.runningSessionIds = ids.filter((id: string, index: number): boolean => ids.indexOf(id) === index);
    // A background task unknown to the cached catalog needs its name for the header pill.
    const unknown = this.backgroundActive() && this.runningSessionIds.some((id: string): boolean =>
      id !== this.currentId && !this.sessions.some((session: SessionRow): boolean => session.id === id));
    if (unknown && Date.now() - this.runningCatalogAt >= 30000 && !this.busy && !this.sessionLoading) {
      this.runningCatalogAt = Date.now();
      void this.loadSessions();
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
      cwd: row.cwd
    }));
  }

  private sessionRunning(id: string): boolean {
    return this.reachable && (id === this.currentId ? !this.idle || this.queued : this.runningSessionIds.includes(id));
  }

  // Tab 2 ("运行中") lists every running session: the current one first, then background rows.
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

  private async loadSessions(more: boolean = false): Promise<void> {
    if (this.busy || this.openingSession || this.sessionLoading || (more && this.sessionCursor === undefined)) return;
    const epoch = this.epoch;
    const version = this.sessionCatalogVersion;
    const query = more ? this.loadedQuery : this.sessionQuery.trim();
    const cursor = more ? this.sessionCursor : 0;
    const view = more ? this.loadedView : this.sessionView;
    this.sessionLoading = true;
    try {
      const result = await this.request(`/sessions?limit=30&cursor=${cursor}&view=${view}&query=${encodeURIComponent(query)}`);
      if (epoch !== this.epoch || version !== this.sessionCatalogVersion) return;
      this.sessionCatalogLoaded = true;
      this.sessionCatalogUpdatedAt = Date.now();
      const incoming = result.sessions ?? [];
      if (more) {
        // The live catalog can move between pages; keep one row per session.
        const ids = new Set<string>(this.sessions.map((row: SessionRow): string => row.id));
        this.sessions = this.sessions.concat(incoming.filter((row: SessionRow): boolean => !ids.has(row.id)));
      } else this.sessions = incoming;
      this.loadedQuery = query;
      this.loadedView = view;
      this.sessionTotal = result.total ?? this.sessions.length;
      this.sessionCursor = result.nextCursor;
      this.desktopHandoff = result.desktopHandoff ?? false;
      this.projects = result.projects ?? [];
    } catch (error) {
      if (epoch !== this.epoch || version !== this.sessionCatalogVersion) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else this.status = '会话列表加载失败，请重试。';
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
    this.status = error.message === 'not_found' ? '当前桌面桥缺少文件下载接口。请更新桌面桥并重新连接。' :
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
      openLandscape: (source: string): void => { this.openMarkdownTableReader(source, cwd, documentPath); }
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
    if (tool.name === 'bash') return $r('app.media.ic_terminal');
    if (tool.name === 'grep' || tool.name === 'find' || tool.name === 'web_search') return $r('app.media.ic_search');
    if (tool.name === 'write' || tool.name === 'edit') return $r('app.media.ic_compose');
    return $r('app.media.ic_folder');
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

  private async openSpaceActions(path: string): Promise<void> {
    const epoch = this.epoch;
    const prompt = this.getUIContext().getPromptAction();
    let selected: number;
    try {
      const result = await prompt.showActionMenu({
        title: path.split('/').pop() || path,
        buttons: [
          { text: '新建任务', color: $r('app.color.pigo_text') },
          { text: '移除空间', color: $r('app.color.pigo_error') }
        ]
      });
      selected = result.index;
    } catch { return; }
    if (epoch !== this.epoch || !this.projects.includes(path)) return;
    if (selected === 1) {
      this.confirmCloseSpace(path);
    } else if (selected === 0) {
      if (!this.reachable || !this.desktopHandoff) {
        prompt.showToast({ message: this.reachable ? '此电脑未启用 Pi Go 集成，无法新建任务。' : '请先连接电脑再新建任务。' });
        return;
      }
      this.activeTab = 'tasks';
      void this.requestAction('/new', { cwd: path });
    }
  }

  private confirmCloseSpace(path: string): void {
    const name = path.split('/').pop() || path;
    const prompt = this.getUIContext().getPromptAction();
    if (!this.isPaired || !this.reachable) { prompt.showToast({ message: '请先连接电脑再移除空间。' }); return; }
    if (this.busy || this.openingSession) { prompt.showToast({ message: '请等待当前操作结束后再移除空间。' }); return; }
    const epoch = this.epoch;
    this.getUIContext().showAlertDialog({
      title: '移除空间',
      message: `「${name}」将从 Pi Desktop 的侧边栏移除，进行中的任务会停止。文件和会话历史会保留。`,
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '移除空间',
        fontColor: $r('app.color.pigo_error'),
        action: () => { if (epoch === this.epoch) void this.closeWorkspace(path); }
      }
    });
  }

  private async closeWorkspace(path: string): Promise<void> {
    const epoch = this.epoch;
    if (!(await this.requestAction('/close-workspace', { cwd: path }))) {
      if (epoch === this.epoch && this.status) this.getUIContext().getPromptAction().showToast({ message: this.status });
      return;
    }
    // 本地立即镜像桌面端的移除，避免等待下一次网络刷新才消失。
    this.projects = this.projects.filter((item: string): boolean => item !== path);
    this.expandedSpaces = this.expandedSpaces.filter((item: string): boolean => item !== path);
    this.scheduleSidebarSave();
    this.getUIContext().getPromptAction().showToast({ message: `已移除空间「${path.split('/').pop() || path}」` });
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
      this.navigationStarted = Date.now();
      console.info(`[DEBUG-chat-cache] start cached=${!!cached}`);
      this.resetVoice();
      this.openingSession = true;
      this.pendingSessionReveal = '';
      this.cancelSchedule();
      if (cached) this.presentChat(cached, true);
    } else this.busy = true;
    this.status = '';
    try {
      const result = await this.request(path, input);
      if (navigation) console.info(`[DEBUG-chat-cache] open ${Date.now() - this.navigationStarted}ms`);
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
        const chat = await this.request('/chat');
        if (epoch !== this.epoch) return false;
        if (chat.session?.id !== result.session.id) throw new Error('session_changed');
        this.presentChat(chat, !cached, liveRevision === this.liveRevision);
        this.reconcileSteering(liveRevision === this.liveRevision && chat.session.idle);
        this.cacheChat(chat.session);
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
      else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_required' && path === '/close-workspace') this.status = '此电脑的 Desktop 未启用 Pi Go 集成，无法远程关闭工作区。';
      else if (error instanceof BridgeFailure && error.message === 'not_found' && path === '/close-workspace') this.status = '电脑端 Pi Go 版本过旧，请重新打包安装 Pi Desktop 后再远程关闭工作区。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_required') this.status = '此电脑的 Desktop 尚未启用历史恢复支持。先在 Desktop 打开该会话，手机会自动接入。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_unshared') this.status = '该工作区尚未共享给手机。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_not_registered') this.status = '该工作区不在 Pi Desktop 项目列表中，请在电脑上关闭。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_kind_unsupported') this.status = '该工作区是桌面管理的临时检出，请在电脑上关闭。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_close_failed') this.status = '电脑端关闭工作区失败，请稍后重试。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_untrusted') this.status = '该工作区未在 Pi Desktop 中登记或信任。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_unconfirmed' && path === '/close-workspace') this.status = '请在 Pi Desktop 查看空间是否已移除。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_unconfirmed') this.status = '桌面未确认操作。请确认是否已打开标签，不要重复新建。';
      else if (error instanceof BridgeFailure && error.message === 'session_occupied') this.status = '同一历史会话出现在多个桌面运行时，请关闭重复标签。';
      else if (error instanceof BridgeFailure && error.message === 'interaction_unavailable') {
        this.setInteraction();
        this.status = '此请求已处理或已失效。';
        this.schedule(0);
      }
      else if (error instanceof BridgeFailure && error.message === 'metadata_conflict') this.status = '会话标记已变化，请重新搜索后再操作。';
      else if (error instanceof BridgeFailure && error.message === 'model_not_found') this.status = '模型已不可用，请重新打开设置。';
      else if (error instanceof BridgeFailure && error.message === 'session_busy') this.status = '等待当前任务和队列结束后，再应用模型设置。';
      else if (error instanceof BridgeFailure && error.message === 'model_not_applied') this.status = '桌面未应用所选模型，请检查该模型的登录状态或 API 配置。';
      else if (error instanceof BridgeFailure && error.message === 'invalid_name') this.status = '名称须为 1–200 字且不含换行。';
      else if (error instanceof BridgeFailure && error.status === 409) this.status = 'Pi 正在处理任务或会话已变化，请刷新后再试。';
      else this.status = '操作未确认，请查看桌面；不会自动重试。';
      return false;
    } finally {
      if (navigation) {
        this.openingSession = false;
        if (epoch === this.epoch) {
          this.syncCommandPalette();
          this.schedule(this.reachable && !this.idle ? 650 : 1500);
        }
      } else this.busy = false;
    }
  }

  private setInteraction(request?: PendingInteraction): void {
    if (request?.id === this.interaction?.id) return;
    this.interactionDraft = request?.prefill ?? '';
    this.interaction = request;
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
        Image($r('app.media.ic_chevron')).width(16).height(16).fillColor($r('app.color.pigo_text'))
          .rotate({ angle: open ? 90 : 0 }).align(Alignment.End)
      }.width('100%').onClick(() => {
        if (id) this.toggleThinking(id, !open);
        else this.liveThinkingOpen = !open;
      })
      if (open) {
        Scroll() {
          Text(content).fontSize(13).fontStyle(FontStyle.Italic).fontColor($r('app.color.pigo_muted')).lineHeight(21)
            .copyOption(CopyOptions.LocalDevice).width('100%')
        }.constraintSize({ maxHeight: 320 }).width('100%')
      } else if (!id) {
        Text(content.split('\n').pop() ?? '').fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
    }.width('100%').padding(12).backgroundColor($r('app.color.pigo_panel')).borderRadius(12)
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }

  @Builder
  fileChip(path: string, lookupName: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        Text(this.fileIcon(path.split('/').pop() ?? path)).fontSize(10).fontColor($r('app.color.pigo_info'))
        Text(path.split('/').pop() ?? path).fontSize(14).fontColor($r('app.color.pigo_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 220 })
        Text(this.openingFile ? '接收中…' : '打开').fontSize(12).fontColor($r('app.color.pigo_muted'))
      }
    }.id(`file-chip-${path}`).backgroundColor($r('app.color.pigo_panel')).borderRadius(12)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(!this.openingFile)
      .onClick(() => { void this.openReferencedFile(this.workspaceCwd, path, lookupName); })
  }

  @Builder
  toolRow(tool: LiveTool, messageId: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        Image(this.toolIcon(tool)).width(18).height(18).fillColor(this.accent())
        Text(this.toolTitle(tool)).fontSize(13).fontColor($r('app.color.pigo_text'))
        Text(tool.detail).fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (tool.state === 'run' && !this.idle) {
          LoadingProgress().width(13).height(13).color(this.accent())
        } else if (tool.state === 'fail') {
          Text('失败').fontSize(12).fontColor($r('app.color.pigo_error'))
        }
        Image($r('app.media.ic_chevron')).width(14).height(14).fillColor($r('app.color.pigo_text'))
      }.width('100%')
    }.width('100%').height(44).padding({ left: 12, right: 10 }).borderRadius(10).backgroundColor($r('app.color.pigo_panel'))
      .onClick(() => { this.openToolDetails(tool, messageId); })
  }

  @Builder
  copyButton(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      Image($r('app.media.ic_copy')).width(18).height(18).fillColor($r('app.color.pigo_text'))
    }.width(38).height(38).borderRadius(10).backgroundColor(Color.Transparent)
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
            Image(this.toolIcon(this.selectedTool)).width(21).height(21).fillColor(this.accent())
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
    }.width('100%').height('100%').align(Alignment.TopStart)
  }

  @Builder
  pendingCard(request: PendingInteraction) {
    Scroll() {
      Column({ space: 8 }) {
        Text(request.title || 'Pi 等待应答').fontWeight(FontWeight.Bold).width('100%')
        if (request.message) Text(request.message).fontSize(14).width('100%')
        if (request.method === 'confirm') {
          Row({ space: 10 }) {
            Button('拒绝').chatAction().id('interaction-deny').enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => { void this.answerInteraction(request.id, false); })
            Button('确认').chatAction().id('interaction-confirm').enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => { void this.answerInteraction(request.id, true); })
          }.width('100%')
        } else if (request.method === 'input' || request.method === 'editor') {
          if (request.method === 'editor') {
            TextArea({ text: this.interactionDraft, placeholder: '编辑内容' }).id('interaction-editor').height(92).maxLength(1024)
              .onChange((value: string) => { if (request.id === this.interaction?.id) this.interactionDraft = value; })
          } else {
            TextInput({ text: this.interactionDraft, placeholder: request.placeholder ?? '输入答复' }).id('interaction-input').maxLength(1024)
              .onChange((value: string) => { if (request.id === this.interaction?.id) this.interactionDraft = value; })
          }
          Row({ space: 10 }) {
            Button('取消').chatAction().id('interaction-cancel').enabled(this.reachable && !this.busy && !this.openingSession)
              .onClick(() => { void this.answerInteraction(request.id, false); })
            Button('提交').chatAction().id('interaction-submit').enabled(this.reachable && !this.busy && !this.openingSession)
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
    }.constraintSize({ maxHeight: 240 }).width('100%')
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

  private pickCommand(row: CommandRow): void {
    this.draft = `${row.invoke ?? `/${row.name}`} `;
    this.commandPalette = false;
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
      } else this.status = '未找到发送记录。请先在桌面核对，再决定是否重发。';
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
      if (!this.models.length) { this.status = '没有可用模型，请在桌面检查配置。'; return; }
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

  private isCurrentModel(model: ModelOption): boolean {
    return this.currentModel?.provider === model.provider && this.currentModel?.id === model.id;
  }

  private bottomPad(): number {
    return this.keyboardHeight > 0 ? 0 : this.navBarHeight;
  }

  private headerHeight(): number {
    return this.windowHeight < SHORT_WINDOW_HEIGHT ? 52 : 62;
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
      const raw = settings.getSync('huawei_profile', '') as string;
      if (!raw) return;
      const profile = JSON.parse(raw) as HuaweiProfile;
      if (typeof profile?.openId === 'string' && profile.openId &&
        typeof profile.name === 'string' && typeof profile.avatar === 'string') {
        this.huaweiProfile = profile;
      }
    } catch { /* An unavailable preferences store leaves the defaults in place. */ }
  }

  private async saveSetting(key: string, value: string): Promise<void> {
    const settings = this.settings;
    if (!settings) throw new Error('settings_unavailable');
    const write = this.settingsWrite.then(async () => {
      settings.putSync(key, value);
      await settings.flush();
    });
    this.settingsWrite = write.catch(() => {});
    return write;
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
    if (this.addingComputer) {
      this.addingComputer = false;
      this.restoringComputer = undefined;
      this.ticket = '';
      this.pairingBundle = '';
    } else {
      this.minePage = '';
    }
    this.removeTarget = '';
    this.status = '';
  }

  @Builder
  computerList() {
    if (this.computers.length) {
      Text('已配对的电脑').fontSize(16).fontWeight(FontWeight.Bold).width('100%')
      Scroll() {
        Column({ space: 7 }) {
          ForEach(this.computers, (record: Companion) => {
            Row({ space: 6 }) {
              Button(`${connectionLabel(record)} · ${record.address.split('://')[1]}${this.isPaired && this.base === record.address ? ' · 当前' : ''}`).chatAction()
                .id(`computer-${record.address}`).layoutWeight(1)
                .enabled(!this.busy && !this.openingSession && !this.removeTarget && (!this.isPaired || this.base !== record.address))
                .onClick(() => { this.chooseComputer(record); })
              if (this.removeTarget === record.address) {
                Button('确认移除').chatAction().id('confirm-remove').enabled(!this.busy)
                  .onClick(() => { this.removeComputer(record.address); })
                Button('取消').chatAction().enabled(!this.busy).onClick(() => { this.removeTarget = ''; })
              } else {
                Button('移除').chatAction().id(`remove-${record.address}`).enabled(!this.busy && !this.openingSession && !this.removeTarget)
                  .onClick(() => { this.removeTarget = record.address; })
              }
            }.width('100%')
          }, (record: Companion) => record.address)
        }.width('100%')
      }.constraintSize({ maxHeight: 144 }).width('100%')
      if (this.removeTarget) Text(this.huaweiProfile ?
        '移除本机配对和账号列表中的记录。可在电脑端吊销其他手机的访问。' :
        '移除本机配对。可在电脑端吊销手机的访问。').fontSize(12).width('100%')
    }
  }

  @Builder
  cloudComputerList() {
    if (this.cloudOnlyComputers().length) {
      Text('从账号恢复的电脑').fontSize(16).fontWeight(FontWeight.Bold).width('100%')
      ForEach(this.cloudOnlyComputers(), (computer: CloudComputer) => {
        Column({ space: 8 }) {
          Text(`${computer.mode === 'usb' ? 'USB' : computer.mode === 'lan' ? '局域网' : '公网'} · ${computer.address.split('://')[1]}`)
            .fontSize(15).fontColor($r('app.color.pigo_text')).width('100%')
          Row({ space: 8 }) {
            if (this.removeTarget === computer.address) {
              Button('从账号移除').chatAction().enabled(!this.busy)
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
        }.width('100%').padding(12).backgroundColor($r('app.color.pigo_panel')).borderRadius(14)
      }, (computer: CloudComputer) => computer.address)
    }
  }

  @Builder
  pairingForm() {
    Column({ space: 14 }) {
      if (this.restoringComputer) {
        Text('请从这台电脑获取新的配对码或配对包。')
          .fontSize(14).fontColor($r('app.color.pigo_text')).width('100%')
      }
      Row({ space: 8 }) {
        Button('USB').chatAction().id('usb-transport').layoutWeight(1).height(42)
          .accessibilitySelected(this.pairingMode === 'usb')
          .backgroundColor(this.pairingMode === 'usb' ? this.accentTint() : Color.Transparent)
          .fontColor(this.pairingMode === 'usb' ? this.accent() : $r('app.color.pigo_muted'))
          .onClick(() => { this.selectPairingMode('usb'); })
        Button('局域网').chatAction().id('transport').layoutWeight(1).height(42)
          .accessibilitySelected(this.pairingMode === 'lan')
          .backgroundColor(this.pairingMode === 'lan' ? this.accentTint() : Color.Transparent)
          .fontColor(this.pairingMode === 'lan' ? this.accent() : $r('app.color.pigo_muted'))
          .onClick(() => { this.selectPairingMode('lan'); })
        Button('公网').chatAction().id('remote-transport').layoutWeight(1).height(42)
          .accessibilitySelected(this.pairingMode === 'remote')
          .backgroundColor(this.pairingMode === 'remote' ? this.accentTint() : Color.Transparent)
          .fontColor(this.pairingMode === 'remote' ? this.accent() : $r('app.color.pigo_muted'))
          .onClick(() => { this.selectPairingMode('remote'); })
      }.width('100%').padding(4).borderRadius(17).backgroundColor($r('app.color.pigo_control'))
        .enabled(!this.busy && !this.removeTarget)
      if (this.pairingMode !== 'usb') {
        Text(this.pairingMode === 'remote' ? '扫描或粘贴桌面「公网」生成的配对包。' :
          '扫描或粘贴桌面「局域网」生成的配对包。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
        Row({ space: 8 }) {
          if (this.pairingMode === 'lan') {
            Button('发现电脑').chatAction().id('lan-discover').enabled(!this.busy && !this.removeTarget).onClick(() => { void this.findLanCompanions(); })
          }
          Button('扫码导入').chatAction().id(this.pairingMode === 'remote' ? 'remote-scan' : 'lan-scan')
            .enabled(!this.busy && !this.removeTarget).onClick(() => { void this.scanPairingBundle(); })
        }.width('100%')
        if (this.lanCandidates.length) {
          Text('附近地址（未验证）').fontSize(12).width('100%')
          Scroll() {
            Column() {
              ForEach(this.lanCandidates, (candidate: string) => {
                Text(candidate).width('100%').fontSize(14)
              }, (candidate: string) => candidate)
            }.width('100%')
          }.constraintSize({ maxHeight: 100 }).width('100%')
        }
        TextInput({ placeholder: this.pairingMode === 'remote' ? '公网配对包' : '局域网配对包', text: this.pairingBundle })
          .id(this.pairingMode === 'remote' ? 'remote-bundle' : 'lan-bundle').type(InputType.Password).maxLength(4096)
          .onChange((value: string) => { this.pairingBundle = value; }).width('100%')
      } else {
        Text('先在桌面会话执行 /pi-go-bridge，再通过 USB 转发连接。').fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
        TextInput({ placeholder: 'USB 地址', text: this.address }).id('address')
          .onChange((value: string) => { this.address = value; }).width('100%')
        TextInput({ placeholder: '8 位配对码或一次性票据', text: this.ticket }).id('ticket').type(InputType.Password)
          .onChange((value: string) => { this.ticket = value; }).width('100%')
      }
      Button('配对并连接').chatAction().id('pair').enabled(!this.busy && !this.openingSession && !this.removeTarget)
        .backgroundColor(this.accent()).fontColor(this.accentForeground()).width('100%').height(46)
        .onClick(() => { void this.pair(); })
    }.padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(22).width('100%')
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }

  @Builder
  profileCard() {
    Column({ space: 14 }) {
      Row({ space: 14 }) {
        Stack() {
          if (this.huaweiProfile?.avatar && !this.avatarUnavailable) {
            Image(this.huaweiProfile.avatar).width(52).height(52).objectFit(ImageFit.Cover)
              .onError(() => { this.avatarUnavailable = true; })
          } else {
            Image($r('app.media.ic_person')).width(24).height(24).fillColor(this.accent())
          }
        }.width(52).height(52).backgroundColor(this.accentTint()).borderRadius(26).clip(true)
        Column({ space: 4 }) {
          Text(this.huaweiProfile?.name || '个人资料').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.huaweiProfile ? '华为账号已登录' : '华为账号未登录').fontSize(13).fontColor($r('app.color.pigo_muted'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Button(this.accountBusy ? '请稍候…' : this.huaweiProfile ? '退出登录' : '使用华为账号登录')
        .chatAction().id('huawei-account').width('100%').height(44).enabled(!this.accountBusy)
        .backgroundColor(this.huaweiProfile ? $r('app.color.pigo_control') : this.accent())
        .fontColor(this.huaweiProfile ? $r('app.color.pigo_text') : this.accentForeground())
        .onClick(() => {
          if (this.huaweiProfile) void this.signOutHuawei();
          else void this.signInHuawei();
        })
      if (this.accountNotice) {
        Text(this.accountNotice).fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      }
      if (this.huaweiProfile) {
        Text(this.cloudSyncStatus || '通过华为云空间同步电脑列表和主题偏好。')
          .fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
        Button('立即同步').chatAction().id('sync-account-settings').width('100%').height(40)
          .enabled(!this.cloudSyncBusy && !this.accountBusy)
          .onClick(() => { this.scheduleCloudSync(0); })
      }
    }.width('100%').padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(22)
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }

  @Builder
  mineEntry(page: string, label: string, summary: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Stack() {
          if (page === 'computers') {
            Image($r('app.media.ic_computer')).width(22).height(22).fillColor(this.accent())
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
        Image($r('app.media.ic_chevron')).width(18).height(18).rotate({ angle: -90 })
          .fillColor($r('app.color.pigo_muted'))
      }.width('100%').padding(14)
    }.id(`mine-${page}`).width('100%').padding(0).backgroundColor($r('app.color.pigo_panel')).borderRadius(16)
      .onClick(() => { this.minePage = page; })
  }

  @Builder
  themeSettings() {
    Column({ space: 10 }) {
      Text('显示模式').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
      Row({ space: 6 }) {
        ForEach(APPEARANCE_MODES, (mode: AppearanceMode) => {
          Button(mode.label, { type: ButtonType.Normal }).chatAction().layoutWeight(1).height(44).padding(4)
            .id(`appearance-${mode.id}`).accessibilitySelected(this.modeId === mode.id)
            .backgroundColor(this.modeId === mode.id ? this.accent() : $r('app.color.pigo_control'))
            .fontColor(this.modeId === mode.id ? this.accentForeground() : $r('app.color.pigo_text'))
            .onClick(() => { this.selectAppearanceMode(mode); })
        }, (mode: AppearanceMode) => mode.id)
      }.width('100%')
    }.width('100%').padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(18)
    Column({ space: 8 }) {
      Text('主题配色').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).width('100%')
      ForEach(THEME_STYLES, (style: ThemeStyle) => {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            Blank().width(22).height(22).borderRadius(11).backgroundColor(this.accentFor(style))
            Text(style.label).fontSize(15).fontColor($r('app.color.pigo_text')).layoutWeight(1)
            if (this.themeId === style.id) Text('✓').fontSize(18).fontColor(this.accent())
          }.width('100%').padding({ left: 12, right: 12 })
        }.id(`theme-${style.id}`).width('100%').height(44).padding(0).borderRadius(12)
          .accessibilitySelected(this.themeId === style.id)
          .backgroundColor(this.themeId === style.id ? this.accentTint() : Color.Transparent)
          .onClick(() => { this.selectTheme(style.id); })
      }, (style: ThemeStyle) => style.id)
    }.width('100%').padding(16).backgroundColor($r('app.color.pigo_panel')).borderRadius(18)
    if (this.appearanceNotice) Text(this.appearanceNotice).fontSize(13).fontColor($r('app.color.pigo_warning'))
  }

  @Builder
  mineHeader() {
    Row({ space: 12 }) {
      if (this.minePage) {
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_chevron')).width(20).height(20).rotate({ angle: 90 })
            .fillColor($r('app.color.pigo_text'))
        }.width(42).height(42).padding(0).borderRadius(12).backgroundColor($r('app.color.pigo_panel'))
          .accessibilityText('返回').enabled(!this.busy).onClick(() => { this.mineBack(); })
      }
      Text(this.minePage === 'theme' ? '系统主题' : this.minePage === 'computers' ?
        (this.addingComputer ? '添加电脑' : '我的电脑') : '我的')
        .fontSize(this.minePage ? 21 : 26).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
    }.width('100%').height(this.headerHeight()).padding({ left: 9, right: 9 })
    .backgroundColor($r('app.color.pigo_panel')).borderRadius(21)
    .border({ width: 1, color: $r('app.color.pigo_line') }).attributeModifier(immersiveSurface(this.darkMode))
  }

  @Builder
  mineView() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.minePage === 'computers') {
          if (!this.addingComputer) {
            if (this.isPaired) {
              Row({ space: 10 }) {
                Image($r('app.media.ic_computer')).width(28).height(28).fillColor(this.accent())
                Column({ space: 4 }) {
                  Text(this.computerTitle()).fontSize(17).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.reachable ? '已连接' : '离线，正在尝试重连').fontSize(13)
                    .fontColor(this.reachable ? $r('app.color.pigo_success') : $r('app.color.pigo_warning'))
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.width('100%').padding(16).borderRadius(16).backgroundColor($r('app.color.pigo_panel'))
            }
            this.computerList()
            this.cloudComputerList()
          }
          if (this.addingComputer || !this.isPaired) {
            this.pairingForm()
          } else {
            Button('添加电脑').chatAction().id('add-computer').width('100%').height(44)
              .backgroundColor(this.accent()).fontColor(this.accentForeground())
              .enabled(!this.busy && !this.openingSession && !this.removeTarget)
              .onClick(() => { this.status = ''; this.addingComputer = true; })
          }
        } else if (this.minePage === 'theme') {
          this.themeSettings()
        } else {
          this.profileCard()
          this.mineEntry('computers', '我的电脑', this.isPaired ?
            `${this.computerTitle()} · ${this.reachable ? '已连接' : '离线'}` :
            (this.computers.length || this.cloudComputers.length ?
              `${this.computers.length + this.cloudOnlyComputers().length} 台电脑` : '配对并连接电脑'))
          this.mineEntry('theme', '系统主题', `${themeStyle(this.themeId).label} · ${appearanceMode(this.modeId).label}`)
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 4, bottom: 12 })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart)
  }

  @Builder
  workspaceTreeRow(row: FileTreeRow) {
    if (row.kind === 'empty') {
      Text(row.name).fontSize(13).fontColor($r('app.color.pigo_muted'))
        .width('100%').height(42).padding({ left: 36 + Math.min(row.depth, 10) * 14 })
    } else {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          Image($r('app.media.ic_chevron')).width(14).height(14)
            .rotate({ angle: row.expanded ? 0 : -90 }).fillColor($r('app.color.pigo_muted'))
            .opacity(row.kind === 'directory' ? 1 : 0)
          if (row.kind === 'directory') {
            Image($r('app.media.ic_folder')).width(19).height(19).fillColor(this.accent())
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
      Text(this.editingPath).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      TextArea({ text: this.fileText }).id('file-editor').layoutWeight(1).width('100%').maxLength(65536)
        .fontFamily('monospace').enabled(!this.busy).onChange((value: string) => { this.fileText = value; })
      if (this.editorNotice) {
        Text(this.editorNotice).id('file-editor-notice').fontSize(13).fontColor($r('app.color.pigo_text')).width('100%')
      }
      Row({ space: 8 }) {
        Button('预览').chatAction().id('file-editor-preview').enabled(!this.busy).onClick(() => {
          this.showTextPreview(this.editingRoot, this.editingPath, this.fileText);
        })
        Button(this.busy ? '正在保存…' : '保存到电脑').chatAction().id('file-save')
          .enabled(this.reachable && !this.busy && this.fileText !== this.fileOriginal)
          .onClick(() => { void this.saveFile(); })
        Button(this.fileText !== this.fileOriginal ? '放弃修改' : '返回').chatAction().id('file-back').enabled(!this.busy)
          .onClick(() => { this.returnToFilePreview(true); })
      }.width('100%')
    }.width('100%').constraintSize({ maxWidth: 840 }).height('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: this.statusBarHeight + 12, bottom: this.bottomPad() + 4 })
  }

  @Builder
  workspaceFiles() {
    Column() {
      Row({ space: 10 }) {
        Image($r('app.media.ic_folder')).width(23).height(23).fillColor(this.accent())
        Column({ space: 2 }) {
          Text(this.project || '项目根目录').fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.pigo_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.fileRoot).fontSize(11).fontColor($r('app.color.pigo_muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(19).fontColor([this.accent()])
        }.id('file-refresh').width(44).height(44).padding(0).borderRadius(10)
          .backgroundColor(Color.Transparent).accessibilityText('刷新工作区')
          .enabled(!this.busy && !this.openingSession && this.reachable)
          .onClick(() => { void this.loadFileDirectory(''); })
      }.width('100%').padding({ left: 14, right: 6, top: 4, bottom: 4 })
      Divider().color($r('app.color.pigo_line'))
      if (this.fileTreeRows.length) {
        List({ initialIndex: this.fileTreeIndex }) {
          ForEach(this.fileTreeRows, (row: FileTreeRow) => {
            ListItem() { this.workspaceTreeRow(row) }
          }, (row: FileTreeRow): string => `${row.kind}:${row.expanded ?? false}:${row.path}`)
        }.width('100%').layoutWeight(1).padding({ top: 4, bottom: 4, left: 4, right: 4 })
          .onScrollIndex((start: number) => { this.fileTreeIndex = Math.max(0, start); })
      } else {
        Text(this.busy ? '正在读取目录…' : '未能读取目录')
          .fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%').padding(16)
      }
    }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Start).borderRadius(18)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
      .clip(true)
  }

  @Builder
  sessionSettings() {
    Scroll() {
      Column({ space: 12 }) {
        Text('会话设置').fontSize(20).fontWeight(FontWeight.Bold).width('100%')
        Text(this.modelLabel).fontSize(13).width('100%')
        TextInput({ text: this.renameDraft, placeholder: '会话名称' }).id('rename-draft').maxLength(200)
          .onChange((value: string) => { this.renameDraft = value; })
        Button('保存名称').chatAction().id('rename-save').enabled(!this.busy && this.reachable && !!this.renameDraft.trim())
          .onClick(() => { void this.requestAction('/rename', { id: this.currentId, name: this.renameDraft.trim() }); })
        Text('模型').fontSize(16).width('100%')
        if (this.models.length) {
          Select(this.models.map((model: ModelOption): SelectOption => ({
            value: `${model.name} · ${model.provider}${model.image ? ' · 图片' : ''}`
          })))
            .id('model-select').width('100%').selected(this.selectedModel)
            .value(this.models[this.selectedModel] ? `${this.models[this.selectedModel].name} · ${this.models[this.selectedModel].provider}` : '选择模型')
            .enabled(!this.busy)
            .onSelect((index: number) => {
              this.selectedModel = index;
              const model = this.models[index];
              if (model && !model.levels.includes(this.selectedLevel)) this.selectedLevel = model.levels[0] ?? 'off';
            })
        }
        if (this.selectedModel >= 0 && this.models[this.selectedModel]) {
          Text('思考级别').fontSize(16).width('100%')
          Select(this.models[this.selectedModel].levels.map((level: string): SelectOption => ({ value: level })))
            .id('thinking-select').width('100%').value(this.selectedLevel)
            .selected(this.models[this.selectedModel].levels.indexOf(this.selectedLevel))
            .enabled(!this.busy)
            .onSelect((index: number) => {
              this.selectedLevel = this.models[this.selectedModel].levels[index] ?? 'off';
            })
          if (this.models[this.selectedModel].levels.length === 1 && this.models[this.selectedModel].levels[0] === 'off') {
            Text('此模型不支持调整思考级别。').fontSize(13).width('100%')
          }
          Button('应用模型与思考级别').chatAction().id('model-apply').enabled(this.reachable && !this.busy && this.idle && !this.queued)
            .onClick(() => {
              const model = this.models[this.selectedModel];
              if (model) void this.requestAction('/model', { id: this.currentId, provider: model.provider,
                modelId: model.id, thinkingLevel: this.selectedLevel });
            })
        }
        if (!this.idle || this.queued) Text('等待当前任务和队列结束后可切换模型。').fontSize(13)
        if (!this.models.length) Text('没有可用模型，请在桌面检查配置。').fontSize(13)
      }.width('100%').padding(12)
    }.layoutWeight(1).width('100%')
  }

  @Builder
  chatHeader() {
    Row({ space: 10 }) {
      if (!this.dockedSessions()) {
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_menu')).width(24).height(24).fillColor(this.accent())
        }.id('history').width(44).height(44).padding(0).backgroundColor(this.accentTint()).borderRadius(14)
          .accessibilityText('打开任务抽屉').enabled(!this.busy && !this.showFiles)
          .onClick(() => { this.setDrawer(true); })
      }
      Column({ space: 4 }) {
        Text(this.showFiles ? '工作区文件' : this.showSettings ? '会话设置' : this.activeTab === 'pending' ? '运行中' : this.chatTitle())
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Row({ space: 6 }) {
          Text('').width(7).height(7).borderRadius(4).backgroundColor(this.reachable ? this.accent() : $r('app.color.pigo_warning'))
            .accessibilityText(this.reachable ? '电脑已连接' : '电脑离线')
          Text(`${this.computerTitle()}${this.project ? '  |  ' + this.project : ''}`)
            .fontSize(12).fontColor($r('app.color.pigo_muted')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').onClick(() => { if (!this.dockedSessions()) this.setDrawer(true); })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: this.dockedSessions() ? 8 : 0 })
      Row({ space: 0 }) {
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_compose')).width(25).height(25).fillColor($r('app.color.pigo_text'))
        }.id('new-task').width(40).height(44).backgroundColor(Color.Transparent).accessibilityText('在当前工作区新建会话')
          .enabled(this.reachable && !this.busy && !this.openingSession && this.desktopHandoff &&
            !!this.workspaceCwd && this.projects.includes(this.workspaceCwd))
          .onClick(() => { this.activeTab = 'tasks'; void this.requestAction('/new', { cwd: this.workspaceCwd }); })
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_more')).width(24).height(24).fillColor($r('app.color.pigo_text'))
        }.id('session-settings').width(38).height(44).backgroundColor(Color.Transparent).accessibilityText('更多操作')
          .bindMenu([
            { value: this.showSettings ? '返回聊天' : '模型与会话设置', action: () => {
              if (this.showSettings) this.showSettings = false;
              else if (this.reachable && this.currentId) void this.requestAction('/models');
            } },
            { value: '切换电脑', action: () => { if (!this.busy) this.openComputers(); } }
          ])
      }
    }.width('100%').height(this.headerHeight()).padding({ left: 8, right: 4 }).borderRadius(21)
      .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') })
      .attributeModifier(immersiveSurface(this.darkMode, `#50${this.accent().slice(1)}`))
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
      this.runningView()
    } else if (this.noSession) {
      this.welcome()
    } else {
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
      ForEach([this.currentId], (transcriptId: string) => {
        Scroll(this.transcript) {
          Column({ space: 8 }) {
            if (this.historyCursor) {
              Button('更早的消息').chatAction().id('history-more').enabled(this.reachable && !this.busy)
                .onClick(() => { void this.loadHistory(); })
            }
            if (!this.messages.length && !this.liveText && !this.liveTools.length) this.welcome()
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
                      ForEach(this.messageFiles(message), (path: string) => {
                        this.fileChip(path, message.role !== 'user')
                      }, (path: string) => path)
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
                      }.id(`image-message-${message.id}`).width('100%')
                    }
                  }.alignItems(HorizontalAlign.Start).padding(message.role === 'user' ? 13 : 0)
                    .width(message.role === 'user' ? undefined : '100%')
                    .constraintSize({ maxWidth: message.role === 'user' ? '88%' : '100%' })
                    .backgroundColor(message.role === 'user' ? this.accentTint() : Color.Transparent)
                    .borderRadius({ topLeft: 17, topRight: 6, bottomLeft: 17, bottomRight: 17 })
                }.width('100%').justifyContent(message.role === 'user' ? FlexAlign.End : FlexAlign.Start)
                  .padding({ top: 10, bottom: 4 })
              }
              ForEach(message.tools ?? [], (tool: LiveTool) => {
                this.toolRow(tool, message.id)
              }, (tool: LiveTool) => this.toolKey(tool))
            }, (message: ChatMessage) => this.transcriptMessageKey(message))
            ForEach(this.unlistedLiveTools(), (tool: LiveTool) => {
              this.toolRow(tool, '')
            }, (tool: LiveTool) => this.toolKey(tool))
            if (this.liveThinking) this.thinkingCard('', this.liveThinking, -1, this.liveThinkingOpen)
            if (this.liveText) {
              Column({ space: 8 }) {
                this.richChatText(this.liveText, this.workspaceCwd)
                ForEach(messageFileChips(this.liveText, this.workspaceCwd), (path: string) => {
                  this.fileChip(path, true)
                }, (path: string) => path)
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
          }.width('100%').padding({ top: 6, bottom: 6 })
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              this.positionTranscript(transcriptId, Number(newArea.height));
            })
        }.layoutWeight(1).width('100%').align(Alignment.TopStart)
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
                  Text('×').fontSize(13).fontColor($r('app.color.pigo_text'))
                }.id(`remove-attachment-${index}`).width(20).height(20).backgroundColor($r('app.color.pigo_selected'))
                  .enabled(!this.busy && !this.pendingSend)
                  .onClick(() => { this.removeAttachment(index); })
              }.width(item.kind === 'image' ? 64 : 170).height(64)
                .borderRadius(item.kind === 'image' ? 10 : 12)
                .backgroundColor(item.kind === 'image' ? Color.Transparent : $r('app.color.pigo_control'))
                .padding(item.kind === 'file' ? 6 : 0)
            }, (item: DraftAttachment, index: number) => `${index}-${item.kind}-${item.name}-${item.size}`)
          }.padding({ bottom: 2 })
        }.scrollable(ScrollDirection.Horizontal).width('100%').height(70)
      }
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Text(this.modelLabel || '选择模型').fontSize(12).fontColor(this.modelLabel ? $r('app.color.pigo_text') : $r('app.color.pigo_muted'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 190 })
        }.id('model-pill').height(34).padding({ left: 12, right: 12 }).borderRadius(17).backgroundColor(this.accentTint())
          .accessibilityText('切换模型')
          .enabled(this.reachable && !this.busy && !this.openingSession && !!this.currentId && this.idle && !this.queued)
          .onClick(() => { void this.openModelMenu(); })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_chevron')).width(22).height(22).fillColor($r('app.color.pigo_text'))
        }.id('scroll-bottom').width(38).height(38).borderRadius(12).backgroundColor($r('app.color.pigo_control'))
          .visibility(this.transcriptFollow ? Visibility.Hidden : Visibility.Visible)
          .accessibilityText('滚动到最新消息').onClick(() => { this.transcriptFollow = true; this.transcript.scrollEdge(Edge.Bottom); })
      }.width('100%').height(38)
      if (!this.reachable && !this.offlineDismissed) this.offlineNotice(false)
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
            }.constraintSize({ maxHeight: 216 }).width('100%').edgeEffect(EdgeEffect.Spring)
          }
        }.width('100%').padding(4)
        .backgroundColor($r('app.color.pigo_panel')).border({ width: 1, color: $r('app.color.pigo_line') }).borderRadius(14)
        .id('command-palette')
      }
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          Image(this.voiceMode ? $r('app.media.ic_keyboard') : $r('app.media.ic_mic')).width(22).height(22)
            .fillColor(this.voiceMode ? this.accent() : $r('app.color.pigo_muted'))
            .fillColor($r('app.color.pigo_text'))
        }.id('voice-toggle').width(38).height(42).backgroundColor(Color.Transparent).borderRadius(19)
          .accessibilityText(this.voiceMode ? '切换到文字输入' : '切换到语音输入')
          .enabled(!!this.currentId && !this.pendingSend && !this.busy && !this.recording && !this.voicePreparing && !this.voiceFinishing)
          .opacity(this.voiceMode ? 1 : 0.65)
          .onClick(() => { this.voiceMode = !this.voiceMode; this.liveVoiceText = ''; this.status = ''; if (this.voiceMode) this.dismissKeyboard(); })
        if (this.voiceMode) {
          Button({ type: ButtonType.Normal }) {
            Text(this.voicePreparing ? '正在准备…' : this.voiceFinishing ? (this.voiceCancelling ? '按住 说话' : '正在转文字…') : this.recording ? (this.holdCancel ? '松开 取消' : '松开 发送') : '按住 说话')
              .fontSize(16).fontColor(this.holdCancel ? $r('app.color.pigo_error') : $r('app.color.pigo_text')).maxLines(1)
          }.id('hold-to-talk').layoutWeight(1).height(58).borderRadius(28)
            .backgroundColor(this.recording ? (this.holdCancel ? $r('app.color.pigo_error_panel') : $r('app.color.pigo_selected')) : $r('app.color.pigo_control'))
            .enabled(!!this.currentId && this.reachable && !this.pendingSend && !this.busy && !this.openingSession)
            .onTouch((event: TouchEvent) => { this.holdTouch(event); })
        } else {
          TextArea({ placeholder: !this.reachable ? '设备离线' : this.windowWidth < 360 ? '输入消息' : '输入消息，/ 唤起命令',
            text: this.draft })
            .id('draft').layoutWeight(1).constraintSize({ minHeight: 46, maxHeight: 118 }).onFocus(() => { this.armTranscriptFollow(); })
            .fontSize(16).fontColor($r('app.color.pigo_text')).placeholderColor($r('app.color.pigo_muted')).backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 2, top: 13, bottom: 11 })
            .enabled(!this.pendingSend).onChange((value: string) => { this.draft = value; this.syncCommandPalette(); })
        }
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_plus')).width(25).height(25).fillColor($r('app.color.pigo_text'))
        }.id('attach-image').width(40).height(42).backgroundColor(Color.Transparent).borderRadius(20)
          .accessibilityText('添加图片或文件').enabled(this.reachable && !this.busy && !this.openingSession && !this.pendingSend && !this.recording)
          .bindMenu(this.acceptsImage ? [
            { value: '拍摄照片', action: (): void => { void this.attachImage('camera'); } },
            { value: '从相册选择', action: (): void => { void this.attachImage('gallery'); } },
            { value: '选择文件', action: (): void => { void this.attachFile(); } }
          ] : [
            { value: '选择文件', action: (): void => { void this.attachFile(); } }
          ])
        if (this.idle || this.hasDraft()) {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_send')).width(22).height(22)
              .fillColor(this.canSend() ? this.accentForeground() : $r('app.color.pigo_text'))
          }.id('send').width(42).height(42).padding(0).borderRadius(13)
            .backgroundColor(this.canSend() ? this.accent() : $r('app.color.pigo_control'))
            .accessibilityText(this.idle ? '发送消息' : '发送消息以引导当前任务').enabled(this.canSend())
            .onClick(() => { void this.send(); })
        } else {
          Button({ type: ButtonType.Normal }) {
            Rect().width(12).height(12).fill(this.accentForeground()).radius(2)
          }.id('abort').width(42).height(42).borderRadius(13).backgroundColor(this.accent())
            .accessibilityText('停止生成').enabled(this.reachable && !this.busy && !this.openingSession)
            .onClick(() => { void this.requestAction('/abort', { id: this.currentId }); })
        }
      }.width('100%').padding({ left: 6, right: 7, top: 5, bottom: 5 }).backgroundColor($r('app.color.pigo_panel'))
        .border({ width: 1, color: $r('app.color.pigo_line') }).borderRadius(22)
    }
  }

  private cacheChat(session: SessionState): void {
    const key = this.draftKey(session.id);
    const start = Math.max(0, this.messages.length - 60);
    this.chatCache.delete(key);
    this.chatCache.set(key, {
      session: session, messages: this.messages.slice(start), liveText: this.liveText,
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
    if (reveal) {
      this.pendingBottom = true;
      this.transcriptFollow = true;
      this.pendingSessionReveal = chat.session.id;
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
      this.getUIContext().postFrameCallback(new CachePaintFrame(this.navigationStarted));
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
    if (open) this.dismissKeyboard();
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.showSessions = open; });
    if (open) void this.loadSessionStatus();
    // Reuse the catalog for quick drawer toggles; stale data stays usable during refresh.
    if (open && this.reachable && (!this.sessionCatalogLoaded ||
      Date.now() - this.sessionCatalogUpdatedAt >= 30000 ||
      this.loadedQuery !== this.sessionQuery.trim() || this.loadedView !== this.sessionView)) {
      void this.loadSessions();
    }
  }

  private dockedSessions(): boolean {
    return this.isPaired && this.activeTab !== 'mine' && this.windowWidth >= SPLIT_WINDOW_WIDTH;
  }

  private sessionPaneWidth(preferred: number | undefined = this.preferredSessionPaneWidth): number {
    const width = preferred ?? Math.max(224, Math.min(288, Math.floor(this.windowWidth * 0.34)));
    return Math.max(160, Math.min(width, 420, this.windowWidth - 360));
  }

  private compactSessionPane(): boolean {
    if (this.dockedSessions()) return this.sessionPaneWidth() < 208;
    return this.windowWidth > 0 && this.windowWidth * 0.84 < 208;
  }

  private onWindowWidthChange(): void {
    // Once the list is docked, folding back should leave the conversation visible.
    if (this.dockedSessions()) this.showSessions = false;
  }

  private revealLibraryAnchor(): void {
    if (!this.pendingLibraryReveal || (!this.showSessions && !this.dockedSessions()) || this.libraryViewportY < 0) return;
    if (this.library.currentOffset().yOffset > 2) { this.pendingLibraryReveal = false; return; } // user scrolled first
    const anchor: number = this.libraryRowY >= 0 ? this.libraryRowY : this.librarySpaceY;
    if (anchor < 0) return; // current row not laid out yet; retried on its next area update
    this.pendingLibraryReveal = false;
    this.library.scrollTo({ xOffset: 0, yOffset: Math.max(0, anchor - this.libraryViewportY - 8), animation: false });
  }

  private chatTitle(): string {
    const listed = this.sessions.find((session: SessionRow): boolean => session.id === this.currentId);
    const firstPrompt = this.messages.find((message: ChatMessage): boolean => message.role === 'user');
    return this.sessionName || listed?.name || firstPrompt?.text || '新任务';
  }

  private computerTitle(): string {
    return validUsb(this.base) ? 'USB 电脑' : (this.base.split('://')[1] || '我的电脑');
  }

  // Spaces mirror the desktop project list only; sessions in unshared directories stay under Tasks.
  private spacePaths(): string[] {
    return this.projects.slice();
  }

  private unfiledSessions(): SessionRow[] {
    return this.sessions.filter((session: SessionRow): boolean => !session.cwd || !this.projects.includes(session.cwd));
  }

  private spaceSessions(path: string): SessionRow[] {
    return this.sessions.filter((session: SessionRow): boolean => (session.cwd || '') === path);
  }

  private toggleSpace(path: string): void {
    this.expandedSpaces = this.expandedSpaces.includes(path) ?
      this.expandedSpaces.filter((item: string): boolean => item !== path) : this.expandedSpaces.concat([path]);
    this.scheduleSidebarSave();
  }

  private toggleTasks(): void {
    this.tasksExpanded = !this.tasksExpanded;
    this.scheduleSidebarSave();
  }

  // Sidebar choices are per computer: folders stay collapsed on connect unless the user opened them.
  private applySidebar(address: string): void {
    const entry = this.sidebarBook.entries.find((kept: SidebarEntry): boolean => kept.address === address);
    this.expandedSpaces = entry ? entry.state.expandedSpaces.slice() : [];
    this.tasksExpanded = entry ? entry.state.tasksExpanded : true;
    this.sessionView = entry && SIDEBAR_VIEWS.includes(entry.state.sessionView) ? entry.state.sessionView : 'all';
    this.loadedView = this.sessionView;
  }

  private scheduleSidebarSave(): void {
    if (!this.base) return;
    const state: SidebarState = {
      expandedSpaces: this.expandedSpaces.slice(0, SIDEBAR_MAX_EXPANDED),
      tasksExpanded: this.tasksExpanded,
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
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text('切换模型').fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text')).layoutWeight(1)
        Button('关闭').chatAction().height(32).fontSize(13)
          .onClick(() => { this.showModelMenu = false; })
      }.width('100%')
      if (!this.idle || this.queued) Text('等待当前任务和队列结束后可切换模型。').fontSize(13).fontColor($r('app.color.pigo_warning')).width('100%')
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.models, (model: ModelOption, index: number) => {
            Button({ type: ButtonType.Normal }) {
              Text(`${this.isCurrentModel(model) ? '✓ ' : ''}${model.name} · ${model.provider}${model.image ? ' · 图片' : ''}`)
                .fontSize(15).fontColor($r('app.color.pigo_text')).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').textAlign(TextAlign.Start)
            }.id(`model-option-${index}`).width('100%').height(46).padding({ left: 16, right: 16 })
              .borderRadius(14).backgroundColor(this.isCurrentModel(model) ? $r('app.color.pigo_selected') : $r('app.color.pigo_control'))
              .enabled(this.reachable && this.idle && !this.queued && !this.busy)
              .onClick(() => { this.showModelMenu = false; void this.applyModelFromMenu(index); })
          }, (model: ModelOption) => `${model.provider}-${model.id}`)
          if (!this.models.length) Text('没有可用模型，请在桌面检查配置。').fontSize(13).width('100%')
        }.width('100%')
      }.constraintSize({ maxHeight: Math.min(260, Math.max(96, this.windowHeight - 140)) })
        .width('100%').align(Alignment.TopStart)
    }.width('100%').constraintSize({ maxWidth: 560 })
      .padding({ left: 14, right: 14, top: 14, bottom: this.bottomPad() + 14 })
      .backgroundColor($r('app.color.pigo_panel')).borderRadius({ topLeft: 28, topRight: 28 })
      .border({ width: { top: 1 }, color: $r('app.color.pigo_line') })
  }

  @Builder
  offlineNotice(compact: boolean, narrow: boolean = false) {
    Row({ space: narrow ? 6 : 10 }) {
      if (!narrow) {
        Text('!').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1B1B1B')
          .textAlign(TextAlign.Center).width(25).height(25).borderRadius(13).backgroundColor('#FF9518')
      }
      Column({ space: 4 }) {
        Text(narrow ? '电脑离线' : compact ? '设备已离线，当前为缓存内容' : '电脑设备已离线')
          .fontSize(compact ? 13 : 17).fontWeight(FontWeight.Medium).fontColor(compact ? $r('app.color.pigo_warning') : $r('app.color.pigo_text'))
        if (!compact) Text('请检查电脑与网络连接').fontSize(12).fontColor($r('app.color.pigo_muted'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (!compact) Button('切换').chatAction().height(34).fontSize(13)
        .onClick(() => { if (!this.busy) this.openComputers(); })
      Button(compact ? '↻' : '重试').chatAction().id(compact ? 'drawer-retry' : 'offline-retry')
        .height(34).width(narrow ? 40 : undefined).fontSize(compact ? 23 : 13).enabled(!this.busy)
        .accessibilityText('重试连接')
        .onClick(() => { this.offlineDismissed = false; this.schedule(0); })
      if (!compact) Button('×').chatAction().width(26).height(30).fontSize(21)
        .accessibilityText('关闭离线提示').onClick(() => { this.offlineDismissed = true; })
    }.width('100%').padding(narrow ? 6 : compact ? 12 : 16).borderRadius(compact ? 9 : 24)
      .backgroundColor(compact ? $r('app.color.pigo_warning_panel') : $r('app.color.pigo_panel'))
  }

  @Builder
  bottomTabs() {
    Row({ space: 4 }) {
      ForEach(this.isPaired ? ['tasks', 'pending', 'files', 'mine'] : ['tasks', 'mine'], (tab: string) => {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 5 }) {
            Image(tab === 'tasks' ? $r('app.media.ic_tasks') : tab === 'pending' ? $r('app.media.ic_pending') :
              tab === 'files' ? $r('app.media.ic_folder') : $r('app.media.ic_person')).width(22).height(22)
              .fillColor(this.activeTab === tab ? this.accent() : $r('app.color.pigo_muted'))
            Text(tab === 'tasks' ? '任务' : tab === 'pending' ? '运行中' : tab === 'files' ? '工作区' : '我的')
              .fontSize(11).fontColor(this.activeTab === tab ? this.accent() : $r('app.color.pigo_muted'))
          }
        }.id(`tab-${tab}`).layoutWeight(1).height(this.windowHeight < SHORT_WINDOW_HEIGHT ? 42 : 48)
          .padding(0).borderRadius(17)
          .accessibilitySelected(this.activeTab === tab)
          .backgroundColor(this.activeTab === tab ? this.accentTint() : Color.Transparent)
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
              this.minePage = '';
              this.addingComputer = false;
              this.restoringComputer = undefined;
              this.removeTarget = '';
            }
            this.activeTab = tab;
          })
      }, (tab: string) => tab)
    }.width('100%').padding(5).borderRadius(23).backgroundColor($r('app.color.pigo_panel'))
      .border({ width: 1, color: $r('app.color.pigo_line') })
  }

  @Builder
  welcome() {
    Column({ space: 12 }) {
      Stack() {
        Image($r('app.media.ic_terminal')).width(33).height(33).fillColor(this.accent())
      }.width(68).height(68).borderRadius(23).backgroundColor(this.accentTint())
        .border({ width: 1, color: $r('app.color.pigo_line') }).accessibilityLevel('no')
      Text('Pi Go').fontSize(36).fontWeight(FontWeight.Bold).fontColor($r('app.color.pigo_text'))
      Text(this.loading ? '正在读取已配对的电脑…' : !this.isPaired ? '连接电脑后查看和继续任务。' :
        this.noSession || '继续电脑上的任务，或开始一个新任务。')
        .fontSize(15).fontColor($r('app.color.pigo_muted')).textAlign(TextAlign.Center).lineHeight(23)
      if (!this.loading && !this.isPaired) {
        Button('连接电脑').chatAction().height(44).padding({ left: 24, right: 24 })
          .backgroundColor(this.accent()).fontColor(this.accentForeground()).onClick(() => { this.openComputers(); })
      }
    }.width('100%').padding({ top: this.windowHeight < SHORT_WINDOW_HEIGHT ? 8 : 76,
      bottom: this.windowHeight < SHORT_WINDOW_HEIGHT ? 8 : 48, left: 20, right: 20 }).layoutWeight(1)
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
            Scroll() {
              Text(session.name === '(no messages)' ? '新任务' : session.name || '未命名任务')
                .fontSize(16).fontColor($r('app.color.pigo_text')).maxLines(1)
            }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1).align(Alignment.Start)
          }
          if (this.sessionRunning(session.id)) {
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
        .height(this.compactSessionPane() && this.sessionRunning(session.id) ? 54 : 46)
        .padding({ left: this.compactSessionPane() ? (nested ? 16 : 6) : (nested ? 40 : 12), right: 2 })
        .backgroundColor(Color.Transparent).enabled(!this.busy && (this.reachable || session.id === this.currentId))
        .onClick(() => {
          if (this.openingSession) return;
          this.activeTab = 'tasks'; this.showSettings = false; this.showFiles = false;
          if (session.id === this.currentId) this.showSessions = false;
          else void this.requestAction('/open', { id: session.id });
        })
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ic_more')).width(17).height(17).fillColor($r('app.color.pigo_text')).opacity(0.5)
      }.id(`session-more-${session.id}`).width(this.compactSessionPane() ? 36 : 30).height(40).padding(0)
        .backgroundColor(Color.Transparent)
        .accessibilityText('任务操作').enabled(this.reachable && !this.busy).bindMenu([
          { value: session.pinned ? '取消置顶' : '置顶', action: () => { void this.updateSessionMeta(session, true); } },
          { value: session.archived ? '取消归档' : '归档', action: () => { void this.updateSessionMeta(session, false); } }
        ])
    }.width('100%').borderRadius(12).backgroundColor(session.id === this.currentId ? $r('app.color.pigo_control') : Color.Transparent)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        if (session.id !== this.currentId) return;
        this.libraryRowY = Number(newArea.globalPosition.y);
        if (this.pendingLibraryReveal) this.revealLibraryAnchor();
      })
  }

  @Builder
  runningView() {
    Scroll() {
      Column({ space: 10 }) {
        if (this.allRunningRows().length) {
          Text(`${this.allRunningRows().length} 个会话在运行`).fontSize(13).fontColor($r('app.color.pigo_muted'))
            .width('100%').textAlign(TextAlign.Start)
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
                Image($r('app.media.ic_chevron')).width(14).height(14).fillColor($r('app.color.pigo_text')).rotate({ angle: -90 }).opacity(0.6)
              }.width('100%').padding(14)
            }.id(`running-session-${row.id}`).width('100%').constraintSize({ minHeight: 60 }).padding(0)
              .borderRadius(12).backgroundColor(row.id === this.currentId ? $r('app.color.pigo_control') : $r('app.color.pigo_panel'))
              .accessibilityText(`${row.name || '后台任务'}，${this.stateLabel(this.sessionState(row.id))}，点击切换查看`)
              .enabled(!this.busy && !this.openingSession && (this.reachable || row.id === this.currentId))
              .onClick(() => {
                if (this.openingSession) return;
                if (row.id !== this.currentId) void this.requestAction('/open', { id: row.id });
                this.activeTab = 'tasks';
              })
          }, (row: RunningRow) => row.id)
        } else {
          Row({ space: 12 }) {
            Stack() {
              Image(this.reachable ? $r('app.media.ic_pending') : $r('app.media.ic_computer'))
                .width(22).height(22)
            }.width(40).height(40).borderRadius(10).backgroundColor($r('app.color.pigo_control'))
            Column({ space: 4 }) {
              Text(this.reachable ? '暂无运行中的会话' : '电脑未连接')
                .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
              Text(this.reachable ? '会话在电脑上执行时，会显示在这里' : '连接电脑后可查看运行中的会话')
                .fontSize(13).lineHeight(19).fontColor($r('app.color.pigo_muted'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%').padding(14).borderRadius(12).backgroundColor($r('app.color.pigo_panel'))
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 16 })
    }.scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off).width('100%').layoutWeight(1)
      .align(Alignment.TopStart).edgeEffect(EdgeEffect.Spring)
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
  sessionLibrary() {
    Row({ space: 4 }) {
      TextInput({ placeholder: '搜索任务', text: this.sessionQuery }).id('session-query').maxLength(100)
        .layoutWeight(1).height(36).fontSize(13).fontColor($r('app.color.pigo_text')).placeholderColor($r('app.color.pigo_muted'))
        .padding({ left: 8, right: 8 }).borderRadius(10)
        .backgroundColor(this.compactSessionPane() ? $r('app.color.pigo_control') : $r('app.color.pigo_panel'))
        .enabled(!this.busy && !this.sessionLoading)
        .onChange((value: string) => { this.sessionQuery = value; }).onSubmit(() => { void this.loadSessions(); })
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ic_search')).width(18).height(18).fillColor($r('app.color.pigo_text'))
      }.id('session-search').width(36).height(36).padding(0).borderRadius(10)
        .backgroundColor(this.compactSessionPane() ? $r('app.color.pigo_control') : $r('app.color.pigo_panel'))
        .accessibilityText('搜索任务').enabled(this.reachable && !this.busy && !this.sessionLoading).onClick(() => { void this.loadSessions(); })
    }.width('100%')
    Scroll(this.library) {
      Column({ space: 5 }) {
        if (this.unfiledSessions().length || this.loadedQuery || this.sessionView !== 'all') {
        Row({ space: 6 }) {
          Text(this.loadedQuery ? '搜索结果' : '任务').fontSize(14).fontColor($r('app.color.pigo_muted'))
          Image($r('app.media.ic_chevron')).width(14).height(14).fillColor($r('app.color.pigo_text')).rotate({ angle: this.tasksExpanded ? 0 : -90 }).opacity(0.5)
          Blank()
          Text(`${this.sessionTotal}`).fontSize(12).fontColor($r('app.color.pigo_muted'))
        }.width('100%').height(this.compactSessionPane() ? 36 : 42)
          .padding({ left: this.compactSessionPane() ? 4 : 12, right: this.compactSessionPane() ? 4 : 12 })
          .onClick(() => { this.toggleTasks(); })
        }
        if (this.tasksExpanded) {
          ForEach(this.unfiledSessions(), (session: SessionRow) => { this.taskRow(session, false) }, (session: SessionRow) => session.id)
          if (this.loadedQuery || this.sessionView !== 'all') {
            ForEach(this.sessions.filter((session: SessionRow): boolean => !!session.cwd && this.projects.includes(session.cwd)), (session: SessionRow) => {
              this.taskRow(session, false)
            }, (session: SessionRow) => session.id)
          }
        }
        if (!this.loadedQuery && this.sessionView === 'all') {
          Text(`空间 (${this.spacePaths().length})`).fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%')
            .padding({ left: this.compactSessionPane() ? 4 : 12, top: this.compactSessionPane() ? 12 : 24,
              bottom: this.compactSessionPane() ? 4 : 12 })
          ForEach(this.spacePaths(), (path: string) => {
            Row({ space: 4 }) {
              Row({ space: this.compactSessionPane() ? 4 : 9 }) {
                Image($r('app.media.ic_folder')).width(this.compactSessionPane() ? 17 : 23)
                  .height(this.compactSessionPane() ? 17 : 23).fillColor($r('app.color.pigo_text'))
                Text(path.split('/').pop() || path).fontSize(this.compactSessionPane() ? 14 : 18).fontColor($r('app.color.pigo_text'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                Image($r('app.media.ic_chevron')).width(this.compactSessionPane() ? 12 : 18)
                  .height(this.compactSessionPane() ? 12 : 18).fillColor($r('app.color.pigo_text'))
                  .rotate({ angle: this.expandedSpaces.includes(path) ? 0 : -90 }).opacity(0.6)
              }.layoutWeight(1).height(48).onClick(() => { this.toggleSpace(path); })
              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.plus')).fontSize(20).fontColor([$r('app.color.pigo_text')])
              }.id(`space-actions-${path}`).width(this.compactSessionPane() ? 40 : 44).height(44).padding(0).borderRadius(10)
                .backgroundColor($r('app.color.pigo_control'))
                .accessibilityText(`${path.split('/').pop() || path}空间操作`)
                .enabled(!this.busy && !this.openingSession)
                .onClick(() => { void this.openSpaceActions(path); })
            }.width('100%').padding({ left: this.compactSessionPane() ? 4 : 12 })
              .onAreaChange((_oldArea: Area, newArea: Area) => {
                if (path !== this.workspaceCwd) return;
                this.librarySpaceY = Number(newArea.globalPosition.y);
                if (this.pendingLibraryReveal) this.revealLibraryAnchor();
              })
            if (this.expandedSpaces.includes(path)) {
              ForEach(this.spaceSessions(path), (session: SessionRow) => { this.taskRow(session, true) }, (session: SessionRow) => session.id)
            }
          }, (path: string) => path)
        }
        if (!this.sessions.length) Text(this.loadedQuery ? '没有找到匹配的任务' : this.reachable ? '暂无任务，点击上方新建' : '连接电脑后加载任务')
          .fontSize(14).fontColor($r('app.color.pigo_muted')).width('100%').padding(this.compactSessionPane() ? 6 : 16)
        if (this.sessionCursor !== undefined) Button('加载更多').chatAction().id('session-more').width('100%').height(38)
          .enabled(this.reachable && !this.busy && !this.sessionLoading).onClick(() => { void this.loadSessions(true); })
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 20 })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        this.libraryViewportY = Number(newArea.globalPosition.y);
        if (this.pendingLibraryReveal) this.revealLibraryAnchor();
      })
  }

  @Builder
  sessionDrawer() {
    Column({ space: this.compactSessionPane() || this.windowHeight < SHORT_WINDOW_HEIGHT ? 8 : 14 }) {
      Row({ space: this.compactSessionPane() ? 6 : 10 }) {
        Image($r('app.media.ic_computer')).width(this.compactSessionPane() ? 20 : 26)
          .height(this.compactSessionPane() ? 20 : 26).fillColor($r('app.color.pigo_text'))
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text(this.computerTitle()).fontSize(this.compactSessionPane() ? 16 : 20)
              .fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            Image($r('app.media.ic_chevron')).width(16).height(16).fillColor($r('app.color.pigo_text'))
          }
        }.id('computers').layoutWeight(1).height(48).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('切换电脑').enabled(!this.busy).onClick(() => { this.openComputers(); })
        if (!this.dockedSessions()) {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_menu')).width(24).height(24).fillColor($r('app.color.pigo_text'))
          }.width(40).height(44).backgroundColor(Color.Transparent).accessibilityText('关闭任务抽屉')
            .onClick(() => { this.setDrawer(false); })
        }
      }.width('100%').padding({ left: this.compactSessionPane() ? 4 : 12 })
      Button({ type: ButtonType.Normal }) {
        Row({ space: this.compactSessionPane() ? 6 : 10 }) {
          Image($r('app.media.ic_compose')).width(this.compactSessionPane() ? 20 : 25)
            .height(this.compactSessionPane() ? 20 : 25).fillColor($r('app.color.pigo_text'))
          Text('新建任务').fontSize(this.compactSessionPane() ? 15 : 19).fontColor($r('app.color.pigo_text')).maxLines(1)
        }.justifyContent(FlexAlign.Center).width('100%')
      }.id('drawer-new-task').width('100%').height(this.compactSessionPane() ? 42 : 50).padding(0)
        .backgroundColor($r('app.color.pigo_panel'))
        .border({ width: 1, color: $r('app.color.pigo_line') }).borderRadius(18).enabled(this.reachable && !this.busy && this.desktopHandoff && this.projects.length > 0)
        .bindMenu(this.projects.map((path: string): MenuElement => ({ value: path.split('/').pop() || path,
          action: () => { this.activeTab = 'tasks'; void this.requestAction('/new', { cwd: path }); } })))
      if (!this.reachable) this.offlineNotice(true, this.compactSessionPane())
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignContent: FlexAlign.SpaceBetween }) {
        ForEach(['all', 'pinned', 'recent', 'archived'], (view: string) => {
          Button({ type: ButtonType.Normal }) {
            Text(view === 'all' ? '全部' : view === 'pinned' ? '置顶' : view === 'recent' ? '最近' : '归档')
              .fontSize(14).fontColor($r('app.color.pigo_text')).maxLines(1)
              .fontWeight(this.sessionView === view ? FontWeight.Medium : FontWeight.Regular)
          }.id(`session-view-${view}`).width(this.compactSessionPane() ? '49%' : '24%')
            .height(36).padding(0).borderRadius(8)
            .backgroundColor(this.sessionView === view ? $r('app.color.pigo_selected') : Color.Transparent)
            .accessibilitySelected(this.sessionView === view).enabled(!this.busy && !this.sessionLoading && this.reachable)
            .onClick(() => { this.sessionView = view; this.scheduleSidebarSave(); void this.loadSessions(); })
        }, (view: string) => view)
      }.width('100%').height(this.compactSessionPane() ? 76 : 36)
      this.sessionLibrary()
      Text(this.base.split('://')[1] || '').id('active-computer').fontSize(11).fontColor($r('app.color.pigo_muted'))
        .width('100%').padding({ left: this.compactSessionPane() ? 4 : 12 })
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.id('session-sidebar').width(this.dockedSessions() ? this.sessionPaneWidth() : '84%')
      .constraintSize({ maxWidth: 420 }).height('100%')
      .padding({ left: this.compactSessionPane() ? 8 : 12, right: 12,
        top: this.statusBarHeight + (this.compactSessionPane() ? 8 : 12), bottom: this.bottomPad() + 18 })
      .borderRadius(this.dockedSessions() ? 0 : { topRight: 26, bottomRight: 26 })
      .border({ width: { right: this.dockedSessions() ? 1 : 0 }, color: $r('app.color.pigo_line') })
      .backgroundColor($r('app.color.pigo_panel'))
      .transition(TransitionEffect.move(TransitionEdge.START))
      .onGestureJudgeBegin(() => this.dockedSessions() ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
      .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
      .onAppear(() => {
        // On entry, reveal the current session or its workspace when available.
        this.pendingLibraryReveal = !!this.currentId;
        this.libraryViewportY = -1;
        this.libraryRowY = -1;
        this.librarySpaceY = -1;
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

  @Builder
  statusNotice() {
    Text(this.status).fontColor($r('app.color.pigo_warning')).fontSize(13).width('100%')
      .padding(12).backgroundColor($r('app.color.pigo_warning_panel')).borderRadius(12)
  }

  @Builder
  textPreviewPage(preview: ReceivedFilePreview) {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text(preview.name).id('text-preview-title').layoutWeight(1)
          .fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('关闭').chatAction().id('text-preview-close').enabled(!this.savingPreview)
          .onClick(() => { this.textFilePreview = undefined; })
      }.width('100%')
      Row({ space: 8 }) {
        if (preview.version && !this.editingPath) {
          Button('编辑').chatAction().id('preview-edit').enabled(!this.busy && !this.savingPreview)
            .onClick(() => { this.editPreview(preview); })
        }
        if (preview.localPath || preview.text !== undefined) {
          Button(this.savingPreview ? '正在保存…' : '保存到本机').chatAction().id('preview-save-local')
            .enabled(!this.savingPreview).onClick(() => { void this.savePreviewLocally(preview); })
        }
        if (preview.systemUri) {
          Button('系统预览').chatAction().enabled(!this.savingPreview)
            .onClick(() => { void this.reopenSystemPreview(preview); })
        }
      }.width('100%')
      if (this.previewNotice) {
        Text(this.previewNotice).id('preview-notice').fontSize(13).fontColor($r('app.color.pigo_text')).width('100%')
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
        }.id('text-preview-body').scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
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
      .padding({ left: 16, right: 16, top: this.statusBarHeight + 12, bottom: this.bottomPad() + 4 })
  }

  @Builder
  markdownTableReaderPage(reader: MarkdownTableReader) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text('表格').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.pigo_text')).layoutWeight(1)
        Button('退出横屏').chatAction().id('markdown-exit-landscape').onClick(() => { this.closeMarkdownTableReader(); })
      }.width('100%')
      if (this.markdownRotationUnavailable) {
        Text('当前窗口无法自动横屏，可左右滑动表格。').fontSize(13).fontColor($r('app.color.pigo_muted')).width('100%')
      }
      Scroll() {
        Column() {
          this.richChatText(reader.source, reader.cwd, reader.documentPath, false)
        }.width('100%')
      }.width('100%').layoutWeight(1).align(Alignment.TopStart)
    }.width('100%').height('100%').padding({
      left: 16, right: 16, top: this.statusBarHeight + 4, bottom: this.bottomPad()
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
          if (!this.keyboardHeight) this.bottomTabs()
          else if (this.isPaired && this.activeTab !== 'mine' &&
            (this.activeTab !== 'tasks' || this.showSettings || this.showFiles)) this.bottomTabs()
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

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        // Reserve the sidebar's space without rebuilding the conversation or moving the session list.
        Blank().width(this.dockedSessions() ? this.sessionPaneWidth() : 0)
        Stack({ alignContent: Alignment.Top }) {
          this.mainNavigation()
        }.height('100%').layoutWeight(1)
          .onGestureJudgeBegin(() => this.dockedSessions() || this.showSessions || this.holdActive || this.recording ||
            this.voicePreparing || this.voiceFinishing || !this.isPaired || this.activeTab === 'mine'
            ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE)
          .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
      }.width('100%').height('100%').linearGradient({
        direction: GradientDirection.LeftTop,
        colors: [[this.accentTint(), 0], [$r('app.color.launch_background'), 0.48],
          [$r('app.color.launch_background'), 0.80], [this.accentTint(), 1]]
      })
      if (this.showSessions && this.isPaired && !this.dockedSessions()) {
        Button({ type: ButtonType.Normal }).chatAction().width('100%').height('100%').backgroundColor('#66000000').borderRadius(0)
          .accessibilityText('关闭会话列表').onClick(() => { this.setDrawer(false); })
          .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => { this.swipeDrawer(event); }))
      }
      if (this.dockedSessions() || (this.showSessions && this.isPaired)) {
        this.sessionDrawer()
      }
      if (this.dockedSessions()) this.sessionPaneHandle()
      if (this.showModelMenu) {
        Button({ type: ButtonType.Normal }).chatAction().width('100%').height('100%').backgroundColor('#66000000').borderRadius(0)
          .accessibilityText('关闭模型菜单').onClick(() => { this.showModelMenu = false; })
        Column() {
          this.modelSheet()
        }.width('100%').height('100%').justifyContent(FlexAlign.End).alignItems(HorizontalAlign.Center)
          .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 220, curve: Curve.EaseOut }))
      }
      if (this.recording || this.voicePreparing || (this.voiceFinishing && !this.voiceCancelling) || this.voiceHint) {
        Column() {
          Column({ space: 16 }) {
            if (this.recording) {
              Image(this.holdCancel ? $r('app.media.ic_close') : $r('app.media.ic_mic')).width(40).height(40).fillColor(this.holdCancel ? '#FFFFFF' : $r('app.color.pigo_text'))
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
    }.width('100%').height('100%').padding({ left: this.leftInset, right: this.rightInset })
      .backgroundColor($r('app.color.launch_background'))
      .bindSheet(this.showToolDetails, this.toolDetailsSheet(), {
        detents: ['65%', SheetSize.LARGE], dragBar: true, showClose: true,
        backgroundColor: $r('app.color.pigo_panel'), maskColor: '#99000000',
        onDisappear: () => { this.closeToolDetails(); }
      })
  }
}
