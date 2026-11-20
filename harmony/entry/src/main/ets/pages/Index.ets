import { FrameCallback, KeyboardAvoidMode } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { ChatContent } from '../ChatContent';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { filePreview } from '@kit.PreviewKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Companion, CredentialVault, SIDEBAR_MAX_COLLAPSED, SIDEBAR_MAX_ENTRIES, SIDEBAR_VIEWS, SidebarBook, SidebarEntry, SidebarState } from '../CredentialVault';
import { discoverLan } from '../LanDiscovery';
import { choosePromptImage, capturePromptImage, PromptImage } from '../PromptImage';
import { choosePromptFiles, PromptFile, MAX_FILES } from '../PromptFile';
import { ensureMicrophone, VoiceInputSession, voiceInputSupported } from '../VoiceInput';

interface ModelOption {
  provider: string;
  id: string;
  name: string;
  image: boolean;
  levels: string[];
  thinkingLevel?: string;
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
  truncated: boolean;
  state: string;
  path?: string;
}

interface ReceivedFilePreview {
  name: string;
  text?: string;
  markdown?: boolean;
  localPath?: string;
  systemUri?: string;
  offset?: number;
  nextOffset?: number;
}

interface StreamFrame {
  type: string;
  sessionId?: string;
  session?: SessionState;
  idle?: boolean;
  aborted?: boolean;
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

interface RunningRow {
  id: string;
  name?: string;
  cwd?: string;
  state?: string;
}

interface BridgeReply {
  attachment?: UploadedAttachment;
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
  liveText?: string;
  liveSeq?: number;
  liveThinking?: string;
  liveThinkSeq?: number;
  tools?: LiveTool[];
  toolDetail?: ToolDetails;
  promptError?: string;
}

interface Payload {
  path?: string;
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
}

interface LanBundle {
  url: string;
  ticket: string;
  ca: string;
  pin: string;
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
const PAGE_COLOR = '#15191C';
const PANEL_COLOR = '#20262B';
const CONTROL_COLOR = '#2A333A';
const LINE_COLOR = '#35414A';
const TEXT_COLOR = '#EDF2F4';
const MUTED_COLOR = '#A3AFB8';
const ACCENT_COLOR = '#9EE2CE';
const MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024;
const MAX_DOWNLOAD_ERROR_BYTES = 4096;
const MAX_TEXT_PREVIEW_BYTES = 128 * 1024;

function textPreviewFormat(name: string): string {
  if (/\.(?:md|markdown|mdown)$/i.test(name)) return 'markdown';
  if (/\.(?:txt|text|log|csv|tsv|json|jsonl|yaml|yml|toml|ini|conf|cfg|xml|sql|sh|py|js|mjs|ts|ets|css|swift|java|go|rs|c|h|cpp|hpp)$/i.test(name) ||
    /^(?:readme|license|notice|changelog|dockerfile|makefile|\.gitignore|\.editorconfig)$/i.test(name)) return 'text';
  return '';
}

function validUsb(address: string): boolean {
  const match = /^http:\/\/127\.0\.0\.1:(\d{1,5})$/.exec(address);
  return match !== null && Number(match[1]) >= 1 && Number(match[1]) <= 65535 && String(Number(match[1])) === match[1];
}

// 沙箱文件名只保留安全字符，并压制长度，避免电脑端文件名带进手机存储异常字符。
function safeLocalFileName(name: string): string {
  const cleaned = name.replace(/[^A-Za-z0-9._-]/g, '_').slice(-80).replace(/^[._-]+/, '_').trim();
  return cleaned || 'file';
}

function normalizeWorkspacePath(cwd: string, path: string): string {
  if (!cwd || !path || path.length > 2048 || /[\\\u0000-\u001f]/.test(path) ||
    /^[a-z][a-z0-9+.-]*:/i.test(path) || path.startsWith('//') || path.startsWith('~')) return '';
  let candidate = path;
  if (candidate.startsWith('/')) {
    const root = cwd.endsWith('/') ? cwd : `${cwd}/`;
    if (!root.startsWith('/') || !candidate.startsWith(root)) return '';
    candidate = candidate.slice(root.length);
  }
  const parts: string[] = [];
  for (const part of candidate.split('/')) {
    if (!part || part === '.') continue;
    if (part === '..') return '';
    parts.push(part);
  }
  return parts.join('/');
}

function messageFileChips(text: string, cwd: string): string[] {
  if (!text || !cwd) return [];
  const chips: string[] = [];
  // 保留 Markdown 目标及引号内的空格，仅剥离普通文本中的句末标点。
  const references = /\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))(?:\s+["'][^\n]*?["'])?\s*\)|`+([^`\n]+)`+|"([^"\n]+)"|'([^'\n]+)'|([^\s`'"()<>\[\]{}|，。；、！？（）〔〕「」『』]+)/g;
  let match = references.exec(text);
  while (match && chips.length < 4) {
    const destination = match[1] ?? match[2];
    let token = destination ?? match[3] ?? match[4] ?? match[5] ?? match[6].replace(/[.,;:!?]+$/, '');
    match = references.exec(text);
    if (destination !== undefined) {
      try { token = decodeURIComponent(destination); } catch { continue; }
    }
    if (!/\.[A-Za-z0-9]{1,10}$/.test(token)) continue;
    const path = normalizeWorkspacePath(cwd, token);
    if (path && !chips.includes(path)) chips.push(path);
  }
  return chips;
}

function validCompanion(record: Companion): boolean {
  return !!record && typeof record.address === 'string' && typeof record.token === 'string' && /^[a-f0-9]{64}$/.test(record.token) &&
    (validUsb(record.address) || (typeof record.ca === 'string' && typeof record.pin === 'string' && validLan(record.address, record.ca, record.pin)));
}

function decodeLanBundle(value: string): LanBundle {
  const encoded = value.trim().replace(/\s/g, '');
  if (!/^[a-zA-Z0-9_-]{100,4096}$/.test(encoded)) throw new Error('invalid_bundle');
  const raw = encoded.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(encoded.length / 4) * 4, '=');
  const bytes = new util.Base64Helper().decodeSync(raw);
  const bundle = JSON.parse(new util.TextDecoder('utf-8').decodeWithStream(bytes)) as LanBundle;
  if (typeof bundle.url !== 'string' || typeof bundle.ca !== 'string' || typeof bundle.pin !== 'string' ||
    typeof bundle.ticket !== 'string' || !validLan(bundle.url, bundle.ca, bundle.pin) ||
    !/^[a-f0-9]{64}$/.test(bundle.ticket)) throw new Error('invalid_bundle');
  return bundle;
}

function validLan(url: string, ca: string, pin: string): boolean {
  const match = /^https:\/\/(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):(\d{1,5})$/.exec(url);
  if (!match || Number(match[5]) < 1024 || Number(match[5]) > 65535 ||
    ca.length > 2000 || !/^-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+-----END CERTIFICATE-----\n?$/.test(ca) ||
    !/^[A-Za-z0-9+/]{43}=$/.test(pin)) return false;
  const first = Number(match[1]);
  const second = Number(match[2]);
  return match.slice(1, 5).every((part: string): boolean => Number(part) <= 255 && String(Number(part)) === part) &&
    (first === 10 || (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168));
}

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
  .backgroundColor('#292929')
  .fontColor('#E8E8E8')
  .fontSize(14)
  .borderRadius(14)
}

@Entry
@Component
struct Index {
  @StorageLink('pigoAddress') address: string = 'http://127.0.0.1:18977';
  @StorageLink('pigoTicket') @Watch('onLaunchTicket') launchTicket: string = '';
  private restoreChain: Promise<void> = Promise.resolve();
  @StorageLink('pigoStatusBar') statusBarHeight: number = 38;
  @StorageLink('pigoNavBar') navBarHeight: number = 28;
  @StorageLink('pigoKeyboard') @Watch('onKeyboardChange') keyboardHeight: number = 0;
  @State private showModelMenu: boolean = false;
  @State private currentModel?: ModelOption = undefined;
  private currentLevel: string = 'off';
  private pendingBottom: boolean = false;
  @State private openingSession: boolean = false;
  private pendingSessionReveal: string = '';
  private navigationStarted: number = 0;
  @State private ticket: string = '';
  @State private lanMode: boolean = false;
  @State private lanBundle: string = '';
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
  @State private showFiles: boolean = false;
  @State private fileRoot: string = '';
  @State private directoryPath: string = '';
  @State private fileEntries: FileEntry[] = [];
  @State private fileCursor?: number = undefined;
  @State private openingFile: boolean = false;
  private fileLoaded: boolean = false;
  @State private editingPath: string = '';
  @State private fileText: string = '';
  @State private fileOriginal: string = '';
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
  @State @Watch('onDrawerChange') private showSessions: boolean = false;
  @State private collapsedSpaces: string[] = [];
  @State private tasksExpanded: boolean = true;
  @State private offlineDismissed: boolean = false;
  @State private activeTab: string = 'tasks';
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
    if (this.textFilePreview) {
      if (!this.savingPreview) this.textFilePreview = undefined;
      return true;
    }
    if (this.recording || this.voicePreparing || this.voiceFinishing) { this.resetVoice(); return true; }
    if (this.showToolDetails) { this.closeToolDetails(); return true; }
    if (this.showModelMenu) { this.showModelMenu = false; return true; }
    if (this.showSessions) { this.showSessions = false; return true; }
    if (this.showSettings) { this.showSettings = false; return true; }
    if (this.showFiles) { this.fileBack(); return true; }
    return false;
  }

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.restoreChain = this.restore();
    void this.restoreChain.then(() => { void this.consumeLaunchTicket(); });
  }
  onPageShow(): void { this.visible = true; this.schedule(0); this.startStream(); }
  onPageHide(): void {
    this.visible = false;
    this.cancelSchedule();
    this.stopStream();
    this.resetVoice();
    this.flushSidebarSave();
  }
  aboutToDisappear(): void {
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
        this.lanMode = false;
        this.lanBundle = '';
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
    this.lanMode = !usb;
    if (usb) this.address = record.address;
    this.ca = usb ? undefined : record.ca;
    this.pin = usb ? undefined : record.pin;
    this.ticket = '';
    this.lanBundle = '';
    this.removeTarget = '';
    this.status = '';
    this.noSession = '正在加载该电脑的会话…';
    this.showSessions = true;
    this.sessionCatalogLoaded = false;
    this.applySidebar(record.address);
    this.reachable = false;
    this.isPaired = true;
    this.schedule(0);
    this.stopStream();
    this.startStream();
  }

  private chooseComputer(record: Companion): void {
    if (this.busy || this.openingSession || this.isPaired || this.removeTarget) return;
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

  private async request(path: string, input?: Payload): Promise<BridgeReply> {
    const req = http.createHttp();
    const headers: Record<string, string> = {};
    if (this.token) headers['Authorization'] = `Bearer ${this.token}`;
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
        readTimeout: path === '/open' || path === '/new' ? 16000 : 6500
      };
      if (this.ca && this.pin) {
        opts.caData = this.ca;
        opts.certificatePinning = { hashAlgorithm: 'SHA-256', publicKeyHash: this.pin };
      }
      if (input) opts.extraData = JSON.stringify(input);
      const response = await req.request(`${this.base}${path}`, opts);
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
    let base = this.address.trim();
    let ticket = this.ticket.trim().toLowerCase();
    this.ca = undefined;
    this.pin = undefined;
    if (this.lanMode) {
      try {
        const bundle = decodeLanBundle(this.lanBundle);
        base = bundle.url;
        ticket = bundle.ticket;
        this.ca = bundle.ca;
        this.pin = bundle.pin;
      } catch {
        this.status = '请粘贴从这台电脑直接取得的完整局域网配对包。';
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
    this.base = base;
    this.busy = true;
    this.status = '';
    try {
      const result = await this.request('/pair', { ticket: ticket });
      if (!result.token || !/^[a-f0-9]{64}$/.test(result.token)) throw new Error('invalid_token');
      const record: Companion = { address: base, token: result.token, ca: this.ca, pin: this.pin };
      this.forgetDrafts(base);
      this.computers = [record, ...this.computers.filter((item: Companion): boolean => item.address !== base)];
      this.activateComputer(record);
      try { await this.persistComputers(); }
      catch { this.status = '已连接；凭证未能保存。'; }
    } catch (error) {
      this.status = error instanceof BridgeFailure && error.status === 401 ? '票据已经失效，请在电脑上重新生成。' :
        this.lanMode ? '无法建立安全连接。请检查 Wi-Fi、桥接地址与配对包。' : '无法连接电脑，请确认 USB 转发和 Pi Go 桥接服务。';
    } finally { this.busy = false; }
  }

  private async scanLanBundle(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context || this.busy) return;
    this.busy = true;
    this.status = '';
    try {
      const result = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: true
      });
      const bundle = decodeLanBundle(result.originalValue);
      this.lanBundle = result.originalValue;
      this.status = `已导入 ${bundle.url}。确认是自己的电脑后，点「配对并连接」。`;
    } catch { this.status = '未导入配对包，可重新扫码或手动粘贴。'; }
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

  private leaveComputer(revoked: boolean = false): void {
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
    this.lanBundle = '';
    this.currentId = '';
    this.pendingSessionReveal = '';
    this.noSession = '';
    this.project = '';
    this.workspaceCwd = '';
    this.showFiles = false;
    this.activeTab = 'tasks';
    this.offlineDismissed = false;
    this.editingPath = '';
    this.fileText = '';
    this.fileOriginal = '';
    this.fileVersion = '';
    this.fileRoot = '';
    this.directoryPath = '';
    this.fileCursor = undefined;
    this.fileLoaded = false;
    this.fileEntries = [];
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
    void this.persistComputers().catch(() => { this.status = '无法保存电脑列表的本次更改。'; });
  }

  private removeComputer(address: string): void {
    if (this.removeTarget !== address || this.isPaired || this.busy) return;
    this.removeTarget = '';
    this.computers = this.computers.filter((record: Companion): boolean => record.address !== address);
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
      this.pendingBottom = true;
      this.transcriptFollow = true;
    }
    this.noSession = '';
    if (this.workspaceCwd !== session.cwd) {
      this.fileRoot = '';
      this.directoryPath = '';
      this.fileCursor = undefined;
      this.fileLoaded = false;
      this.fileEntries = [];
      this.editingPath = '';
      this.fileText = '';
      this.fileOriginal = '';
      this.fileVersion = '';
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
      if (this.showSessions && (!this.sessionCatalogLoaded || connected) && !this.busy) void this.loadSessions();
      if (this.showSessions) {
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
          result.state === 'no_shared_sessions' ? '电脑已连接，请从左上角会话列表选择一条对话。' : '请从左上角会话列表选择一个会话。';
        if (this.currentId) this.rememberDraft(this.currentId);
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
      if (moved || incoming[incoming.length - 1]?.id !== this.messages[this.messages.length - 1]?.id) {
        this.pendingBottom = true;
      }
      this.mergeTranscript(incoming, result.historyCursor);
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
      saved.thinking !== incoming.thinking || saved.thinkingMs !== incoming.thinkingMs || saved.imageCount !== incoming.imageCount) return false;
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

  private stateColor(state: string): string {
    if (state === 'waiting') return '#FFB024';
    if (state === 'queued') return '#B49BDB';
    return '#72D6A0';
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

  private parentOf(path: string): string {
    return path.split('/').slice(0, -1).join('/');
  }

  private closeFileEditor(): void {
    this.editingPath = '';
    this.fileText = '';
    this.fileOriginal = '';
    this.fileVersion = '';
  }

  private fileBack(): void {
    if (this.editingPath) {
      if (this.fileText !== this.fileOriginal) { this.status = '请先保存或放弃文件修改。'; return; }
      this.closeFileEditor();
      return;
    }
    if (this.busy || this.openingSession) return;
    if (this.directoryPath) void this.browseFiles(this.parentOf(this.directoryPath));
    else { this.showFiles = false; this.activeTab = 'tasks'; }
  }

  private async browseFiles(path: string, more: boolean = false): Promise<void> {
    if (this.busy || this.openingSession) return;
    if (this.editingPath && this.fileText !== this.fileOriginal) {
      this.status = '请先保存或放弃文件修改。'; return;
    }
    const epoch = this.epoch;
    this.busy = true;
    try {
      const result = await this.request('/files/list', { cwd: this.fileRoot, path: path, cursor: more ? this.fileCursor : 0 });
      if (epoch !== this.epoch) return;
      this.directoryPath = path;
      this.fileEntries = more ? this.fileEntries.concat(result.entries ?? []) : result.entries ?? [];
      this.fileCursor = result.nextCursor;
      this.editingPath = '';
      this.fileText = '';
      this.fileOriginal = '';
      this.fileVersion = '';
      this.fileLoaded = true;
      this.showFiles = true;
      this.status = '';
    } catch (error) { if (epoch === this.epoch) this.fileFailure(error); }
    finally { this.busy = false; }
  }

  private fileFailure(error: Error): void {
    if (error instanceof BridgeFailure && error.status === 401) { this.leaveComputer(true); return; }
    this.status = error.message === 'file_conflict' ? '电脑上的文件已变化，未覆盖。请复制手机修改后重新打开文件。' :
      error.message === 'file_too_large' ? '文本文件上限为 64 KiB，修改已保留。' :
      error.message === 'not_text_file' ? '此文件不是可编辑的 UTF-8 文本。' :
      error.message === 'path_forbidden' ? '此路径不可访问（不支持符号链接）。' :
      '文件操作未确认。请检查连接和项目授权；修改不会自动重发。';
  }

  private async openFile(path: string): Promise<void> {
    if (this.busy || this.openingSession) return;
    const epoch = this.epoch;
    this.busy = true;
    try {
      const result = await this.request('/files/read', { cwd: this.fileRoot, path: path });
      if (epoch !== this.epoch) return;
      this.editingPath = path;
      this.fileText = result.text ?? '';
      this.fileOriginal = this.fileText;
      this.fileVersion = result.version ?? '';
      this.status = '';
    } catch (error) {
      if (epoch !== this.epoch) return;
      const message = (error as Error).message;
      // 非文本或超大文件：不再报错，直接把原文件发到手机并用系统预览打开。
      if (message === 'not_text_file' || message === 'file_too_large') {
        await this.openWorkspaceFile(this.fileRoot, path);
        return;
      }
      this.fileFailure(error);
    } finally { this.busy = false; }
  }

  private async saveFile(): Promise<void> {
    if (this.busy || this.openingSession || !this.editingPath) return;
    const epoch = this.epoch;
    this.busy = true;
    try {
      const result = await this.request('/files/save', { cwd: this.fileRoot, path: this.editingPath, text: this.fileText, version: this.fileVersion });
      if (epoch !== this.epoch) return;
      this.fileVersion = result.version ?? '';
      this.fileOriginal = this.fileText;
      this.status = '文件已保存。';
    } catch (error) { if (epoch === this.epoch) this.fileFailure(error); }
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

  private async downloadFile(cwd: string, path: string, temporary: string, lookupName: boolean): Promise<void> {
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
        maxLimit: MAX_DOWNLOAD_BYTES
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
        if (received + chunk.byteLength > MAX_DOWNLOAD_BYTES) {
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
      if (expected > MAX_DOWNLOAD_BYTES) throw new Error('file_too_large');
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

  private readTextFilePreview(path: string, name: string, start: number = 0): ReceivedFilePreview | undefined {
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
        const textPreview = this.readTextFilePreview(local, name);
        if (textPreview) { this.textFilePreview = textPreview; return; }
        const uri = fileUri.getUriFromPath(local);
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
      const page = this.readTextFilePreview(preview.localPath, preview.name, offset);
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

  private async reopenSystemPreview(preview: ReceivedFilePreview): Promise<void> {
    if (!preview.systemUri) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await filePreview.openPreview(context, { title: preview.name, uri: preview.systemUri, mimeType: '' });
    } catch { this.previewNotice = '无法打开系统预览，仍可保存文件。'; }
  }

  private messageFiles(message: ChatMessage): string[] {
    return messageFileChips(message.text, this.workspaceCwd);
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
    return `${message.id}:${thinking}:${tools}`;
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
      const reply = await this.request(`/tool-detail?id=${encodeURIComponent(this.currentId)}&tool=${encodeURIComponent(tool.id)}${message}`);
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
      if (path === '/new' || path === '/rename' || path === '/session-meta') {
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
        this.cacheChat(chat.session);
      }
      return true;
    } catch (error) {
      if (epoch !== this.epoch) return false;
      if (cached && !navigationConfirmed && !(error instanceof BridgeFailure && error.status === 401)) {
        this.pendingSessionReveal = '';
        if (previous) this.presentChat(previous, false);
        this.showSessions = true;
      }
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else if (error instanceof BridgeFailure && error.message === 'desktop_handoff_required') this.status = '此电脑的 Desktop 尚未启用历史恢复支持。先在 Desktop 打开该会话，手机会自动接入。';
      else if (error instanceof BridgeFailure && error.message === 'desktop_workspace_untrusted') this.status = '该工作区未在 Pi Desktop 中登记或信任。';
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
        if (epoch === this.epoch) this.schedule(this.reachable && !this.idle ? 650 : 1500);
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
        Text('✻').fontSize(13).fontColor('#9BB7D4')
        Text(id ? (ms >= 0 ? `思考 · ${(ms / 1000).toFixed(1)}s` : '思考') : '思考中…')
          .fontSize(13).fontColor('#9BB7D4').layoutWeight(1)
        Image($r('app.media.ic_chevron')).width(16).height(16)
          .rotate({ angle: open ? 90 : 0 }).align(Alignment.End)
      }.width('100%').onClick(() => {
        if (id) this.toggleThinking(id, !open);
        else this.liveThinkingOpen = !open;
      })
      if (open) {
        Scroll() {
          Text(content).fontSize(13).fontStyle(FontStyle.Italic).fontColor('#8A8A8A').lineHeight(21)
            .copyOption(CopyOptions.LocalDevice).width('100%')
        }.constraintSize({ maxHeight: 320 }).width('100%')
      } else if (!id) {
        Text(content.split('\n').pop() ?? '').fontSize(12).fontColor('#7A7A7A').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
    }.width('100%').padding(12).backgroundColor(PANEL_COLOR).borderRadius(12)
      .border({ width: 1, color: LINE_COLOR })
  }

  @Builder
  fileChip(path: string, lookupName: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        Text(this.fileIcon(path.split('/').pop() ?? path)).fontSize(10).fontColor('#9BB7D4')
        Text(path.split('/').pop() ?? path).fontSize(14).fontColor('#E8E8E8').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 220 })
        Text(this.openingFile ? '接收中…' : '打开').fontSize(12).fontColor('#8A8A8A')
      }
    }.id(`file-chip-${path}`).backgroundColor('#242424').borderRadius(12)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(!this.openingFile)
      .onClick(() => { void this.openWorkspaceFile(this.workspaceCwd, path, lookupName); })
  }

  @Builder
  toolRow(tool: LiveTool, messageId: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        Image(this.toolIcon(tool)).width(18).height(18).fillColor(ACCENT_COLOR)
        Text(this.toolTitle(tool)).fontSize(13).fontColor(TEXT_COLOR)
        Text(tool.detail).fontSize(12).fontColor(MUTED_COLOR).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (tool.state === 'run' && !this.idle) {
          LoadingProgress().width(13).height(13).color(ACCENT_COLOR)
        } else if (tool.state === 'fail') {
          Text('失败').fontSize(12).fontColor('#FF9D9D')
        }
        Image($r('app.media.ic_chevron')).width(14).height(14)
      }.width('100%')
    }.width('100%').height(44).padding({ left: 12, right: 10 }).borderRadius(10).backgroundColor(PANEL_COLOR)
      .onClick(() => { this.openToolDetails(tool, messageId); })
  }

  @Builder
  copyButton(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      Image($r('app.media.ic_copy')).width(18).height(18)
    }.width(38).height(38).borderRadius(10).backgroundColor(Color.Transparent)
      .accessibilityText(label).onClick(() => { void this.copyText(value); })
  }

  @Builder
  toolDetailBlock(label: string, value: string) {
    Column({ space: 4 }) {
      Row() {
        Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(ACCENT_COLOR).layoutWeight(1)
        if (value) this.copyButton(`复制${label}`, value)
      }.width('100%')
      if (value) {
        Text(value).width('100%').fontFamily('monospace').fontSize(14).lineHeight(22).fontColor(TEXT_COLOR)
          .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
      .padding({ left: 12, right: 8, top: 4, bottom: 12 })
      .backgroundColor(PAGE_COLOR).borderRadius(12).border({ width: 1, color: LINE_COLOR })
  }

  @Builder
  toolDetailsSheet() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.selectedTool) {
          Row({ space: 10 }) {
            Image(this.toolIcon(this.selectedTool)).width(21).height(21).fillColor(ACCENT_COLOR)
            Text(this.toolTitle(this.selectedTool)).fontSize(21).fontWeight(FontWeight.Medium).fontColor(TEXT_COLOR)
          }.width('100%').padding({ right: 40 })
          if (this.toolFile(this.selectedTool)) this.fileChip(this.toolFile(this.selectedTool), false)
          if (this.selectedToolDetails) {
            if (this.selectedToolDetails.input) {
              this.toolDetailBlock(this.selectedToolDetails.command ? '命令' : '输入', this.selectedToolDetails.input)
            }
            if (this.selectedToolDetails.output) {
              this.toolDetailBlock(this.selectedToolDetails.state === 'fail' ? '错误输出' : '输出', this.selectedToolDetails.output)
            } else {
              Text(this.selectedTool.state === 'run' && !this.idle ? '正在运行…' : '没有文本输出')
                .fontSize(14).fontColor('#B6B6B6')
            }
            if (this.selectedToolDetails.truncated) {
              Text('较长的输入或输出仅显示前 64K 字符').fontSize(12).fontColor('#B6B6B6')
            }
          } else if (this.selectedTool.detail) {
            this.toolDetailBlock('摘要', this.selectedTool.detail)
          }
          if (this.toolDetailError) {
            Text(this.toolDetailError).fontSize(14).fontColor('#B6B6B6')
            Button('重试').chatAction().onClick(() => { void this.loadToolDetails(); })
          } else if (!this.selectedToolDetails) {
            LoadingProgress().width(22).height(22).color('#B6B6B6').accessibilityText('正在加载工具详情')
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
      }.padding(12).width('100%').backgroundColor('#342A15').borderRadius(14)
    }.constraintSize({ maxHeight: 240 }).width('100%')
  }

  private async send(mode: string = 'send'): Promise<void> {
    const text = this.draft.trim();
    const id = this.currentId;
    const attachments = this.attachments ?? [];
    if (!id || (!text && !attachments.length) || this.busy || this.openingSession || !this.reachable || (mode === 'send') !== this.idle || this.pendingSend) return;
    if (attachments.some((item: DraftAttachment): boolean => item.kind === 'image') && !this.acceptsImage) {
      this.status = '此模型不支持图片，请先移除图片附件或换模型。';
      return;
    }
    if (mode !== 'send' && (!this.runId || this.queued)) return;
    if (this.unconfirmed.size >= 128) { this.status = '请先核对未确认的发送。'; return; }
    const epoch = this.epoch;
    const key = this.draftKey(id);
    const pending: PendingSend = { requestId: util.generateRandomUUID(), text: text, attachments: attachments };
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
        runId: mode === 'send' ? undefined : this.runId, attachments: refs.length ? refs : undefined });
      if (epoch !== this.epoch) return;
      if (result.dispatched !== true) throw new Error('dispatch_unconfirmed');
      this.finishSend(key, pending);
      if (mode === 'send') this.idle = false;
      else this.status = mode === 'steer' ? '引导请求已交给 Pi。' : '后续请求已交给 Pi。';
    } catch (error) {
      if (epoch !== this.epoch) return;
      if (error instanceof BridgeFailure && error.status === 401) this.leaveComputer(true);
      else if (error instanceof BridgeFailure && ['session_busy', 'session_not_streaming', 'session_changed',
        'invalid_prompt', 'invalid_request_id', 'probe_request_limit', 'invalid_image', 'image_not_supported', 'payload_too_large',
        'invalid_attachment', 'unknown_attachment', 'invalid_content_type', 'not_found'].includes(error.message)) {
        this.unconfirmed.delete(key);
        this.pendingSend = undefined;
        this.status = error.message === 'image_not_supported' ? '此模型不支持图片；草稿已保留。' :
          ['invalid_image', 'payload_too_large'].includes(error.message) ? '发送内容过大（单文件 8MB 内）或图片格式无效；草稿已保留。' :
            ['invalid_attachment', 'unknown_attachment', 'invalid_content_type'].includes(error.message) ? '附件无效或已过期；草稿已保留。' :
              error.message === 'not_found' ? '电脑端扩展版本过旧，不支持附件上传；草稿已保留。' :
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
    this.pendingSend = undefined;
    // 自己刚发出的消息必须立刻滚到可见位置，即使之前在翻历史。
    this.transcriptFollow = true;
    this.pendingBottom = true;
    if (this.draft.trim() === pending.text) this.draft = '';
    this.attachments = [];
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
      if (this.idle && this.reachable && !this.busy && !this.openingSession && !this.pendingSend) {
        await this.send();
        if (attempt === this.voiceAttempt && this.draft.trim()) this.voiceMode = false;
      } else {
        this.voiceMode = false;
        this.showVoiceHint(this.idle ? '已转为文字，可编辑后发送' : '已转为文字，请选择发送方式');
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
    const gap = this.transcriptContentHeight - this.transcriptViewport - this.transcript.currentOffset().yOffset;
    this.transcriptFollow = gap <= 120;
    if (this.transcriptFollow) this.transcript.scrollEdge(Edge.Bottom);
  }

  private onKeyboardChange(): void {
    if (this.keyboardHeight > 0) this.armTranscriptFollow();
  }

  @Builder
  computerList() {
    if (this.computers.length) {
      Text('已配对的电脑').fontSize(16).fontWeight(FontWeight.Bold).width('100%')
      Scroll() {
        Column({ space: 7 }) {
          ForEach(this.computers, (record: Companion) => {
            Row({ space: 6 }) {
              Button(`${validUsb(record.address) ? 'USB' : 'Wi-Fi'} · ${record.address.split('://')[1]}`).chatAction()
                .id(`computer-${record.address}`).layoutWeight(1).enabled(!this.busy && !this.removeTarget)
                .onClick(() => { this.chooseComputer(record); })
              if (this.removeTarget === record.address) {
                Button('确认移除').chatAction().id('confirm-remove').enabled(!this.busy)
                  .onClick(() => { this.removeComputer(record.address); })
                Button('取消').chatAction().enabled(!this.busy).onClick(() => { this.removeTarget = ''; })
              } else {
                Button('移除').chatAction().id(`remove-${record.address}`).enabled(!this.busy && !this.removeTarget)
                  .onClick(() => { this.removeTarget = record.address; })
              }
            }.width('100%')
          }, (record: Companion) => record.address)
        }.width('100%')
      }.constraintSize({ maxHeight: 144 }).width('100%')
      if (this.removeTarget) Text('仅移除手机凭证。要吊销设备，请在电脑上操作。').fontSize(12).width('100%')
    }
  }

  @Builder
  connection() {
    Column({ space: 20 }) {
      Text('Pi Go').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#777777').width('100%')
      Text('连接你的电脑').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#E8E8E8').width('100%')
      this.computerList()
      Button(this.lanMode ? '切换到 USB' : '切换到局域网').chatAction().id('transport').enabled(!this.busy && !this.removeTarget)
        .onClick(() => {
          this.lanMode = !this.lanMode;
          if (!this.lanMode && !validUsb(this.address)) this.address = USB_ADDRESS;
          this.status = '';
          this.lanBundle = '';
          this.ticket = '';
        })
      if (this.lanMode) {
        Text('请扫描或粘贴从信任的 Desktop 直接取得的局域网配对包。').fontSize(14).fontColor('#777777').width('100%')
        Row({ space: 8 }) {
          Button('发现电脑').chatAction().id('lan-discover').enabled(!this.busy && !this.removeTarget).onClick(() => { void this.findLanCompanions(); })
          Button('扫码导入').chatAction().id('lan-scan').enabled(!this.busy && !this.removeTarget).onClick(() => { void this.scanLanBundle(); })
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
        TextInput({ placeholder: '局域网配对包', text: this.lanBundle }).id('lan-bundle').type(InputType.Password).maxLength(4096)
          .onChange((value: string) => { this.lanBundle = value; }).width('100%')
      } else {
        Text('先在桌面会话执行 /pi-go-bridge，再通过 USB 转发连接。').fontSize(14).fontColor('#777777').width('100%')
        TextInput({ placeholder: 'USB 地址', text: this.address }).id('address')
          .onChange((value: string) => { this.address = value; }).width('100%')
        TextInput({ placeholder: '8 位配对码或一次性票据', text: this.ticket }).id('ticket').type(InputType.Password)
          .onChange((value: string) => { this.ticket = value; }).width('100%')
      }
      Button('配对并连接').chatAction().id('pair').enabled(!this.busy && !this.removeTarget).backgroundColor('#353535').fontColor('#E8E8E8').width('100%')
        .onClick(() => { void this.pair(); })
    }.padding({ top: 52, bottom: 24, left: 4, right: 4 }).backgroundColor('#1B1B1B').width('100%')
  }

  @Builder
  workspaceFiles() {
    Text(this.fileRoot).fontSize(12).width('100%').copyOption(CopyOptions.LocalDevice)
    if (this.editingPath) {
      Text(this.editingPath).fontSize(15).width('100%')
      TextArea({ text: this.fileText }).id('file-editor').layoutWeight(1).width('100%').maxLength(65536)
        .enabled(!this.busy).onChange((value: string) => { this.fileText = value; })
      Row({ space: 8 }) {
        Button('预览').chatAction().id('file-editor-preview').enabled(!this.busy).onClick(() => {
          this.dismissKeyboard();
          const name = this.editingPath.split('/').pop() ?? this.editingPath;
          this.previewOffsets = [];
          this.previewNotice = '';
          this.textFilePreview = { name: name, text: this.fileText, markdown: textPreviewFormat(name) === 'markdown' };
        })
        Button('保存').chatAction().id('file-save').enabled(this.reachable && !this.busy && this.fileText !== this.fileOriginal)
          .onClick(() => { void this.saveFile(); })
        Button(this.fileText !== this.fileOriginal ? '放弃修改并返回' : '返回目录').chatAction().id('file-back').enabled(!this.busy)
          .onClick(() => { this.fileText = this.fileOriginal; this.closeFileEditor(); })
      }.width('100%')
    } else {
      Row({ space: 8 }) {
        Button('返回').chatAction().id('file-back-dir').enabled(!this.busy).onClick(() => { this.fileBack(); })
        Button('上一级').chatAction().id('file-parent').enabled(!this.busy && !!this.directoryPath)
          .onClick(() => { void this.browseFiles(this.parentOf(this.directoryPath)); })
        Button('刷新').chatAction().enabled(!this.busy).onClick(() => { void this.browseFiles(this.directoryPath); })
        Text(this.directoryPath || '项目根目录').fontSize(13).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.fileEntries, (entry: FileEntry) => {
            Button(`${entry.kind === 'directory' ? '目录 · ' : entry.kind === 'blocked' ? '不可访问 · ' : ''}${entry.name}`).chatAction()
              .id(`file-${entry.path}`).width('100%').enabled(!this.busy && entry.kind !== 'blocked')
              .onClick(() => {
                if (entry.kind === 'directory') void this.browseFiles(entry.path);
                else void this.openFile(entry.path);
              })
          }, (entry: FileEntry) => entry.path)
          if (!this.fileEntries.length) Text('空目录')
          if (this.fileCursor !== undefined) Button('加载更多文件').chatAction().enabled(!this.busy)
            .onClick(() => { void this.browseFiles(this.directoryPath, true); })
        }.width('100%')
      }.layoutWeight(1).width('100%')
    }
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
  chat() {
    Row({ space: 10 }) {
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ic_menu')).width(24).height(24)
      }.id('history').width(44).height(44).backgroundColor(PANEL_COLOR).borderRadius(13)
        .accessibilityText('打开任务抽屉').enabled(!this.busy && !this.showFiles)
        .onClick(() => { this.setDrawer(true); })
      Column({ space: 4 }) {
        Text(this.showFiles ? '工作区文件' : this.showSettings ? '会话设置' : this.activeTab === 'mine' ? '我的电脑' : this.activeTab === 'pending' ? '待处理' : this.chatTitle())
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor(TEXT_COLOR).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Row({ space: 6 }) {
          Text('').width(7).height(7).borderRadius(4).backgroundColor(this.reachable ? ACCENT_COLOR : '#FFB46E')
            .accessibilityText(this.reachable ? '电脑已连接' : '电脑离线')
          Text(`${this.computerTitle()}${this.project ? '  |  ' + this.project : ''}`)
            .fontSize(12).fontColor(MUTED_COLOR).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').onClick(() => { this.setDrawer(true); })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Row({ space: 0 }) {
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_compose')).width(25).height(25)
        }.id('new-task').width(40).height(44).backgroundColor(Color.Transparent).accessibilityText('在当前工作区新建会话')
          .enabled(this.reachable && !this.busy && !this.openingSession && this.desktopHandoff &&
            !!this.workspaceCwd && this.projects.includes(this.workspaceCwd))
          .onClick(() => { this.activeTab = 'tasks'; void this.requestAction('/new', { cwd: this.workspaceCwd }); })
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_more')).width(24).height(24)
        }.id('session-settings').width(38).height(44).backgroundColor(Color.Transparent).accessibilityText('更多操作')
          .bindMenu([
            { value: this.showSettings ? '返回聊天' : '模型与会话设置', action: () => {
              if (this.showSettings) this.showSettings = false;
              else if (this.reachable && this.currentId) void this.requestAction('/models');
            } },
            { value: '切换电脑', action: () => { if (!this.busy) this.leaveComputer(); } }
          ])
      }.backgroundColor(PANEL_COLOR).borderRadius(13)
    }.width('100%').height(60)
      .border({ width: { bottom: 1 }, color: LINE_COLOR })
    this.runningStrip()
    if (this.showFiles) {
      this.workspaceFiles()
    } else if (this.showSettings) {
      this.sessionSettings()
    } else if (this.activeTab === 'mine') {
      Column({ space: 20 }) {
        Image($r('app.media.ic_computer')).width(48).height(48).opacity(0.8)
        Text(this.computerTitle()).fontSize(20).fontColor('#E8E8E8')
        Text(this.reachable ? '设备已连接' : '设备离线，正在尝试重连').fontSize(14).fontColor(this.reachable ? '#8FBAA1' : '#FFB024')
        this.computerList()
        Button('连接其他电脑').chatAction().width('100%').enabled(!this.busy)
          .onClick(() => { this.leaveComputer(); })
      }.width('100%').layoutWeight(1).padding({ top: 48 }).alignItems(HorizontalAlign.Center)
    } else if (this.activeTab === 'pending') {
      Column({ space: 20 }) {
        if (this.interaction) this.pendingCard(this.interaction)
        else {
          Image($r('app.media.ic_pending')).width(42).height(42).opacity(0.5)
          Text('暂无待处理请求').fontSize(20).fontColor('#E8E8E8')
          Text('需要确认或补充信息时，会显示在这里').fontSize(14).fontColor('#888888')
        }
      }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
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
                          .copyOption(CopyOptions.LocalDevice).fontColor(TEXT_COLOR)
                      } else {
                        ChatContent({ text: message.text })
                        ForEach(this.messageFiles(message), (path: string) => {
                          this.fileChip(path, true)
                        }, (path: string) => path)
                        this.copyButton('复制回复', message.text)
                      }
                    }
                    if (message.imageCount) Text(`图片 × ${message.imageCount}`).id(`image-message-${message.id}`).fontSize(13).fontColor('#777777')
                  }.alignItems(HorizontalAlign.Start).padding(message.role === 'user' ? 13 : 0)
                    .constraintSize({ maxWidth: message.role === 'user' ? '88%' : '100%' })
                    .backgroundColor(message.role === 'user' ? '#2A3B3B' : Color.Transparent)
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
                ChatContent({ text: this.liveText })
                ForEach(messageFileChips(this.liveText, this.workspaceCwd), (path: string) => {
                  this.fileChip(path, true)
                }, (path: string) => path)
              }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 10, bottom: 18 })
            }
          }.width('100%').padding({ top: 6, bottom: 6 })
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              this.positionTranscript(transcriptId, Number(newArea.height));
            })
        }.layoutWeight(1).width('100%').align(Alignment.TopStart)
          .onTouch((event: TouchEvent) => {
            // 点击手势会被带 copyOption 的消息文本夺走，改用触摸广播：手指一按下就收键盘。
            if (event.type === TouchType.Down && this.keyboardHeight > 0) this.dismissKeyboard();
          })
          .onWillScroll((_xOffset: number, yOffset: number, _state: ScrollState, _source: ScrollSource) => {
            if (yOffset < -2) this.transcriptFollow = false;
          })
          .onScrollEdge((side: Edge) => {
            if (side === Edge.Bottom) this.transcriptFollow = true;
          })
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            this.transcriptViewport = Number(newArea.height);
            if (this.keyboardHeight > 0 && this.transcriptFollow) this.transcript.scrollEdge(Edge.Bottom);
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
                    Text(item.file ? this.fileIcon(item.file.name) : '文件').fontSize(15).fontColor('#9E9E9E')
                    Text(item.name).fontSize(12).fontColor('#BFBFBF').maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 150 })
                    Text(this.fileSize(item.size)).fontSize(11).fontColor('#777777')
                  }.justifyContent(FlexAlign.Center).width('100%').height('100%')
                }
                Button({ type: ButtonType.Circle }) {
                  Text('×').fontSize(13).fontColor('#E8E8E8')
                }.id(`remove-attachment-${index}`).width(20).height(20).backgroundColor('#5A5A5A')
                  .enabled(!this.busy && !this.pendingSend)
                  .onClick(() => { this.removeAttachment(index); })
              }.width(item.kind === 'image' ? 64 : 170).height(64)
                .borderRadius(item.kind === 'image' ? 10 : 12)
                .backgroundColor(item.kind === 'image' ? Color.Transparent : '#3A3A3A')
                .padding(item.kind === 'file' ? 6 : 0)
            }, (item: DraftAttachment, index: number) => `${index}-${item.kind}-${item.name}-${item.size}`)
          }.padding({ bottom: 2 })
        }.scrollable(ScrollDirection.Horizontal).width('100%').height(70)
      }
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Text(this.modelLabel || '选择模型').fontSize(12).fontColor(this.modelLabel ? TEXT_COLOR : MUTED_COLOR)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 190 })
        }.id('model-pill').height(32).padding({ left: 12, right: 12 }).borderRadius(10).backgroundColor(PANEL_COLOR)
          .accessibilityText('切换模型')
          .enabled(this.reachable && !this.busy && !this.openingSession && !!this.currentId && this.idle && !this.queued)
          .onClick(() => { void this.openModelMenu(); })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_chevron')).width(22).height(22)
        }.id('scroll-bottom').width(38).height(38).borderRadius(12).backgroundColor(CONTROL_COLOR)
          .visibility(this.transcriptFollow ? Visibility.Hidden : Visibility.Visible)
          .accessibilityText('滚动到最新消息').onClick(() => { this.transcriptFollow = true; this.transcript.scrollEdge(Edge.Bottom); })
      }.width('100%').height(38)
      if (!this.reachable && !this.offlineDismissed) this.offlineNotice(false)
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          Image(this.voiceMode ? $r('app.media.ic_keyboard') : $r('app.media.ic_mic')).width(24).height(24)
        }.id('voice-toggle').width(38).height(42).backgroundColor(Color.Transparent).borderRadius(19)
          .accessibilityText(this.voiceMode ? '切换到文字输入' : '切换到语音输入')
          .enabled(!!this.currentId && !this.pendingSend && !this.busy && !this.recording && !this.voicePreparing && !this.voiceFinishing)
          .opacity(this.voiceMode ? 1 : 0.65)
          .onClick(() => { this.voiceMode = !this.voiceMode; this.liveVoiceText = ''; this.status = ''; if (this.voiceMode) this.dismissKeyboard(); })
        if (this.voiceMode) {
          Button({ type: ButtonType.Normal }) {
            Text(this.voicePreparing ? '正在准备…' : this.voiceFinishing ? (this.voiceCancelling ? '按住 说话' : '正在转文字…') : this.recording ? (this.holdCancel ? '松开 取消' : '松开 发送') : '按住 说话')
              .fontSize(16).fontColor(this.holdCancel ? '#FF7A7A' : '#CFCFCF').maxLines(1)
          }.id('hold-to-talk').layoutWeight(1).height(58).borderRadius(28)
            .backgroundColor(this.recording ? (this.holdCancel ? '#4A2525' : '#3C3C3C') : '#3A3A3A')
            .enabled(!!this.currentId && this.reachable && !this.pendingSend && !this.busy && !this.openingSession)
            .onTouch((event: TouchEvent) => { this.holdTouch(event); })
        } else {
          TextArea({ placeholder: this.reachable ? '输入消息' : '设备离线', text: this.draft })
            .id('draft').layoutWeight(1).constraintSize({ minHeight: 46, maxHeight: 118 }).onFocus(() => { this.armTranscriptFollow(); })
            .fontSize(16).fontColor(TEXT_COLOR).placeholderColor(MUTED_COLOR).backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 2, top: 13, bottom: 11 })
            .enabled(!this.pendingSend).onChange((value: string) => { this.draft = value; })
        }
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_plus')).width(25).height(25)
        }.id('attach-image').width(40).height(42).backgroundColor(Color.Transparent).borderRadius(20)
          .accessibilityText('添加图片或文件').enabled(this.reachable && !this.busy && !this.openingSession && !this.pendingSend && !this.recording)
          .bindMenu(this.acceptsImage ? [
            { value: '拍摄照片', action: (): void => { void this.attachImage('camera'); } },
            { value: '从相册选择', action: (): void => { void this.attachImage('gallery'); } },
            { value: '选择文件', action: (): void => { void this.attachFile(); } }
          ] : [
            { value: '选择文件', action: (): void => { void this.attachFile(); } }
          ])
        if (this.idle) {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_send')).width(20).height(20)
          }.id('send').width(42).height(42).borderRadius(13).backgroundColor(ACCENT_COLOR)
            .accessibilityText('发送消息').enabled(this.reachable && !this.busy && !this.openingSession && !this.pendingSend && !this.recording && !this.voicePreparing && !this.voiceFinishing &&
              (this.draft.trim().length > 0 || this.attachments.length > 0) &&
              (!this.attachments.some((item: DraftAttachment): boolean => item.kind === 'image') || this.acceptsImage))
            .opacity(this.reachable ? 1 : 0.3).onClick(() => { void this.send(); })
        } else {
          Button({ type: ButtonType.Normal }) {
            Rect().width(12).height(12).fill('#1B1B1B').radius(2)
          }.id('abort').width(42).height(42).borderRadius(13).backgroundColor(ACCENT_COLOR)
            .accessibilityText('停止生成').enabled(this.reachable && !this.busy && !this.openingSession)
            .onClick(() => { void this.requestAction('/abort', { id: this.currentId }); })
        }
      }.width('100%').padding({ left: 4, right: 6, top: 4, bottom: 4 }).backgroundColor(PANEL_COLOR)
        .border({ width: 1, color: LINE_COLOR }).borderRadius(17)
      if (!this.idle && (this.draft.trim() || this.attachments.length) &&
        (!this.attachments.some((item: DraftAttachment): boolean => item.kind === 'image') || this.acceptsImage)) {
        Row({ space: 8 }) {
          Button('引导当前任务').chatAction().id('steer').layoutWeight(1).enabled(this.reachable && !this.busy && !this.openingSession && !this.pendingSend && !!this.runId && !this.queued)
            .onClick(() => { void this.send('steer'); })
          Button('完成后再处理').chatAction().id('follow-up').layoutWeight(1).enabled(this.reachable && !this.busy && !this.openingSession && !this.pendingSend && !!this.runId && !this.queued)
            .onClick(() => { void this.send('followUp'); })
        }.width('100%')
      }
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

  private setDrawer(open: boolean): void {
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

  // Opening the drawer should land on the current session's workspace position, not the list top.
  private onDrawerChange(_prop: string): void {
    if (!this.showSessions) { this.pendingLibraryReveal = false; return; }
    this.pendingLibraryReveal = !!this.currentId;
    this.libraryViewportY = -1;
    this.libraryRowY = -1;
    this.librarySpaceY = -1;
  }

  private revealLibraryAnchor(): void {
    if (!this.pendingLibraryReveal || !this.showSessions || this.libraryViewportY < 0) return;
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

  private spacePaths(): string[] {
    const paths: string[] = this.projects.slice();
    this.sessions.forEach((session: SessionRow) => {
      if (session.cwd && !paths.includes(session.cwd)) paths.push(session.cwd);
    });
    return paths;
  }

  private spaceSessions(path: string): SessionRow[] {
    return this.sessions.filter((session: SessionRow): boolean => (session.cwd || '') === path);
  }

  private toggleSpace(path: string): void {
    this.collapsedSpaces = this.collapsedSpaces.includes(path) ?
      this.collapsedSpaces.filter((item: string): boolean => item !== path) : this.collapsedSpaces.concat([path]);
    this.scheduleSidebarSave();
  }

  private toggleTasks(): void {
    this.tasksExpanded = !this.tasksExpanded;
    this.scheduleSidebarSave();
  }

  // Sidebar choices are per computer: restore the remembered collapse and filter state on connect.
  private applySidebar(address: string): void {
    const entry = this.sidebarBook.entries.find((kept: SidebarEntry): boolean => kept.address === address);
    this.collapsedSpaces = entry ? entry.state.collapsedSpaces.slice() : [];
    this.tasksExpanded = entry ? entry.state.tasksExpanded : true;
    this.sessionView = entry && SIDEBAR_VIEWS.includes(entry.state.sessionView) ? entry.state.sessionView : 'all';
    this.loadedView = this.sessionView;
  }

  private scheduleSidebarSave(): void {
    if (!this.base) return;
    const state: SidebarState = {
      collapsedSpaces: this.collapsedSpaces.slice(0, SIDEBAR_MAX_COLLAPSED),
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
        Text('切换模型').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#E8E8E8').layoutWeight(1)
        Button('关闭').chatAction().height(32).fontSize(13)
          .onClick(() => { this.showModelMenu = false; })
      }.width('100%')
      if (!this.idle || this.queued) Text('等待当前任务和队列结束后可切换模型。').fontSize(13).fontColor('#FFB024').width('100%')
      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.models, (model: ModelOption, index: number) => {
            Button({ type: ButtonType.Normal }) {
              Text(`${this.isCurrentModel(model) ? '✓ ' : ''}${model.name} · ${model.provider}${model.image ? ' · 图片' : ''}`)
                .fontSize(15).fontColor('#E8E8E8').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').textAlign(TextAlign.Start)
            }.id(`model-option-${index}`).width('100%').height(46).padding({ left: 16, right: 16 })
              .borderRadius(14).backgroundColor(this.isCurrentModel(model) ? '#373737' : '#292929')
              .enabled(this.reachable && this.idle && !this.queued && !this.busy)
              .onClick(() => { this.showModelMenu = false; void this.applyModelFromMenu(index); })
          }, (model: ModelOption) => `${model.provider}-${model.id}`)
          if (!this.models.length) Text('没有可用模型，请在桌面检查配置。').fontSize(13).width('100%')
        }.width('100%')
      }.constraintSize({ maxHeight: 260 }).width('100%').align(Alignment.TopStart)
    }.width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: this.bottomPad() + 14 })
      .backgroundColor('#1B1B1B').borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 1 }, color: '#454545' })
  }

  @Builder
  offlineNotice(compact: boolean) {
    Row({ space: 10 }) {
      Text('!').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1B1B1B')
        .textAlign(TextAlign.Center).width(25).height(25).borderRadius(13).backgroundColor('#FF9518')
      Column({ space: 4 }) {
        Text(compact ? '设备已离线，当前为缓存内容' : '电脑设备已离线')
          .fontSize(compact ? 13 : 17).fontWeight(FontWeight.Medium).fontColor(compact ? '#FFB024' : '#E8E8E8')
        if (!compact) Text('请检查电脑与网络连接').fontSize(12).fontColor('#999999')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (!compact) Button('切换').chatAction().height(34).fontSize(13)
        .onClick(() => { if (!this.busy) this.leaveComputer(); })
      Button(compact ? '↻' : '重试').chatAction().id(compact ? 'drawer-retry' : 'offline-retry')
        .height(34).fontSize(compact ? 23 : 13).enabled(!this.busy)
        .onClick(() => { this.offlineDismissed = false; this.schedule(0); })
      if (!compact) Button('×').chatAction().width(26).height(30).fontSize(21)
        .accessibilityText('关闭离线提示').onClick(() => { this.offlineDismissed = true; })
    }.width('100%').padding(compact ? 12 : 16).borderRadius(compact ? 9 : 24)
      .backgroundColor(compact ? '#382D10' : '#252525')
  }

  @Builder
  bottomTabs() {
    Row() {
      ForEach(['tasks', 'pending', 'files', 'mine'], (tab: string) => {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 5 }) {
            Image(tab === 'tasks' ? $r('app.media.ic_tasks') : tab === 'pending' ? $r('app.media.ic_pending') :
              tab === 'files' ? $r('app.media.ic_folder') : $r('app.media.ic_person')).width(22).height(22)
              .fillColor(this.activeTab === tab ? ACCENT_COLOR : MUTED_COLOR)
            Text(tab === 'tasks' ? '任务' : tab === 'pending' ? '待处理' : tab === 'files' ? '工作区' : '我的')
              .fontSize(11).fontColor(this.activeTab === tab ? ACCENT_COLOR : MUTED_COLOR)
          }
        }.id(`tab-${tab}`).layoutWeight(1).height(50).borderRadius(12)
          .backgroundColor(this.activeTab === tab ? PANEL_COLOR : Color.Transparent)
          .enabled(!this.busy).onClick(() => {
            this.dismissKeyboard();
            if (this.editingPath && this.fileText !== this.fileOriginal) {
              this.status = '请先保存或放弃文件修改。'; return;
            }
            if (tab === 'files') {
              if (!this.reachable || !this.workspaceCwd) { this.status = '请先连接电脑并打开一个任务。'; return; }
              if (this.activeTab === 'files' && this.showFiles) return;
              if (this.fileRoot === this.workspaceCwd && this.fileLoaded) {
                this.showFiles = true; this.status = '';
              } else { this.fileRoot = this.workspaceCwd; void this.browseFiles(''); }
            } else { this.showFiles = false; this.showSettings = false; }
            this.activeTab = tab;
          })
      }, (tab: string) => tab)
    }.width('100%').padding({ top: 4 })
  }

  @Builder
  welcome() {
    Column({ space: 14 }) {
      Text('Pi Go').fontSize(32).fontWeight(FontWeight.Bold).fontColor('#E8E8E8')
      Text('有什么可以帮你？').fontSize(23).fontWeight(FontWeight.Medium).fontColor('#E8E8E8')
      Text(this.loading ? '正在读取已配对的电脑…' : this.noSession || '继续电脑上的灵感，或开始一个新任务。').fontSize(14).fontColor('#888888').textAlign(TextAlign.Center).lineHeight(22)
    }.width('100%').padding({ top: 88, bottom: 60, left: 20, right: 20 }).layoutWeight(1)
  }

  @Builder
  taskRow(session: SessionRow, nested: boolean) {
    Row({ space: 0 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          Scroll() {
            Text(session.name === '(no messages)' ? '新任务' : session.name || '未命名任务')
              .fontSize(16).fontColor('#E8E8E8').maxLines(1)
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1).align(Alignment.Start)
          if (this.sessionRunning(session.id)) {
            Row({ space: 4 }) {
              Text('').width(6).height(6).borderRadius(3)
                .backgroundColor(this.stateColor(this.sessionState(session.id)))
              Text(this.stateLabel(this.sessionState(session.id))).fontSize(11)
                .fontColor(this.stateColor(this.sessionState(session.id)))
            }.accessibilityText(this.stateLabel(this.sessionState(session.id)))
          }
        }.width('100%')
      }.id(`session-${session.id}`).layoutWeight(1).height(46).padding({ left: nested ? 40 : 12, right: 2 })
        .backgroundColor(Color.Transparent).enabled(!this.busy && (this.reachable || session.id === this.currentId))
        .onClick(() => {
          if (this.openingSession) return;
          this.activeTab = 'tasks'; this.showSettings = false; this.showFiles = false;
          if (session.id === this.currentId) this.showSessions = false;
          else void this.requestAction('/open', { id: session.id });
        })
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ic_more')).width(17).height(17).opacity(0.5)
      }.id(`session-more-${session.id}`).width(30).height(40).backgroundColor(Color.Transparent)
        .accessibilityText('任务操作').enabled(this.reachable && !this.busy).bindMenu([
          { value: session.pinned ? '取消置顶' : '置顶', action: () => { void this.updateSessionMeta(session, true); } },
          { value: session.archived ? '取消归档' : '归档', action: () => { void this.updateSessionMeta(session, false); } }
        ])
    }.width('100%').borderRadius(12).backgroundColor(session.id === this.currentId ? CONTROL_COLOR : Color.Transparent)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        if (session.id !== this.currentId) return;
        this.libraryRowY = Number(newArea.globalPosition.y);
        if (this.pendingLibraryReveal) this.revealLibraryAnchor();
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
                Text(row.name || '后台任务').fontSize(13).fontColor('#C9C9C9').maxLines(1)
                Text(this.stateLabel(this.sessionState(row.id))).fontSize(11)
                  .fontColor(this.stateColor(this.sessionState(row.id)))
              }
            }.id(`running-${row.id}`).height(34).padding({ left: 12, right: 12 }).borderRadius(17)
              .backgroundColor('#242424').accessibilityText(`${row.name || '后台任务'}${this.stateLabel(this.sessionState(row.id))}，点击切换查看`)
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
    Row({ space: 6 }) {
      TextInput({ placeholder: '搜索任务', text: this.sessionQuery }).id('session-query').maxLength(100)
        .layoutWeight(1).height(36).fontSize(13).fontColor('#E8E8E8').placeholderColor('#777777')
        .borderRadius(10).backgroundColor('#242424').enabled(!this.busy && !this.sessionLoading)
        .onChange((value: string) => { this.sessionQuery = value; }).onSubmit(() => { void this.loadSessions(); })
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.ic_search')).width(18).height(18)
      }.id('session-search').width(36).height(36).backgroundColor('#242424').borderRadius(10)
        .accessibilityText('搜索任务').enabled(this.reachable && !this.busy && !this.sessionLoading).onClick(() => { void this.loadSessions(); })
    }.width('100%')
    Scroll(this.library) {
      Column({ space: 5 }) {
        if (this.spaceSessions('').length || this.loadedQuery || this.sessionView !== 'all') {
        Row({ space: 6 }) {
          Text(this.loadedQuery ? '搜索结果' : '任务').fontSize(14).fontColor('#888888')
          Image($r('app.media.ic_chevron')).width(14).height(14).rotate({ angle: this.tasksExpanded ? 0 : -90 }).opacity(0.5)
          Blank()
          Text(`${this.sessionTotal}`).fontSize(12).fontColor('#777777')
        }.width('100%').height(42).padding({ left: 12, right: 12 })
          .onClick(() => { this.toggleTasks(); })
        }
        if (this.tasksExpanded) {
          ForEach(this.spaceSessions(''), (session: SessionRow) => { this.taskRow(session, false) }, (session: SessionRow) => session.id)
          if (this.loadedQuery || this.sessionView !== 'all') {
            ForEach(this.sessions.filter((session: SessionRow): boolean => !!session.cwd), (session: SessionRow) => {
              this.taskRow(session, false)
            }, (session: SessionRow) => session.id)
          }
        }
        if (!this.loadedQuery && this.sessionView === 'all') {
          Text(`空间 (${this.spacePaths().length})`).fontSize(14).fontColor('#888888').width('100%')
            .padding({ left: 12, top: 24, bottom: 12 })
          ForEach(this.spacePaths(), (path: string) => {
            Row({ space: 8 }) {
              Row({ space: 9 }) {
                Image($r('app.media.ic_folder')).width(23).height(23)
                Text(path.split('/').pop() || path).fontSize(18).fontColor('#E8E8E8')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                Image($r('app.media.ic_chevron')).width(18).height(18)
                  .rotate({ angle: this.collapsedSpaces.includes(path) ? -90 : 0 }).opacity(0.6)
              }.layoutWeight(1).height(48).onClick(() => { this.toggleSpace(path); })
              Button({ type: ButtonType.Normal }) {
                Image($r('app.media.ic_plus')).width(23).height(23).opacity(0.6)
              }.id(`new-${path}`).width(34).height(44).backgroundColor(Color.Transparent).accessibilityText('在此空间新建任务')
                .enabled(this.reachable && !this.busy && this.desktopHandoff && this.projects.includes(path))
                .onClick(() => { this.activeTab = 'tasks'; void this.requestAction('/new', { cwd: path }); })
            }.width('100%').padding({ left: 12 })
              .onAreaChange((_oldArea: Area, newArea: Area) => {
                if (path !== this.workspaceCwd) return;
                this.librarySpaceY = Number(newArea.globalPosition.y);
                if (this.pendingLibraryReveal) this.revealLibraryAnchor();
              })
            if (!this.collapsedSpaces.includes(path)) {
              ForEach(this.spaceSessions(path), (session: SessionRow) => { this.taskRow(session, true) }, (session: SessionRow) => session.id)
            }
          }, (path: string) => path)
        }
        if (!this.sessions.length) Text(this.loadedQuery ? '没有找到匹配的任务' : this.reachable ? '暂无任务，点击上方新建' : '连接电脑后加载任务')
          .fontSize(14).fontColor('#888888').width('100%').padding(16)
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
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Image($r('app.media.ic_computer')).width(26).height(26)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text(this.computerTitle()).fontSize(20).fontWeight(FontWeight.Medium).fontColor('#E8E8E8')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            Image($r('app.media.ic_chevron')).width(16).height(16)
          }
        }.id('computers').layoutWeight(1).height(48).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText('切换电脑').enabled(!this.busy).onClick(() => { this.leaveComputer(); })
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_menu')).width(24).height(24)
        }.width(40).height(44).backgroundColor(Color.Transparent).accessibilityText('关闭任务抽屉')
          .onClick(() => { this.setDrawer(false); })
      }.width('100%').padding({ left: 12 })
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          Image($r('app.media.ic_compose')).width(25).height(25)
          Text('新建任务').fontSize(19).fontColor('#E8E8E8')
        }.justifyContent(FlexAlign.Center).width('100%')
      }.id('drawer-new-task').width('100%').height(50).borderRadius(18).backgroundColor('#242424')
        .border({ width: 1, color: '#56565C' }).borderRadius(18).enabled(this.reachable && !this.busy && this.desktopHandoff && this.projects.length > 0)
        .bindMenu(this.projects.map((path: string): MenuElement => ({ value: path.split('/').pop() || path,
          action: () => { this.activeTab = 'tasks'; void this.requestAction('/new', { cwd: path }); } })))
      if (!this.reachable) this.offlineNotice(true)
      Row({ space: 2 }) {
        ForEach(['all', 'pinned', 'recent', 'archived'], (view: string) => {
          Button(view === 'all' ? '全部' : view === 'pinned' ? '置顶' : view === 'recent' ? '最近' : '归档').chatAction()
            .id(`session-view-${view}`).layoutWeight(1).height(28).fontSize(11).borderRadius(8)
            .backgroundColor(this.sessionView === view ? '#373737' : Color.Transparent).enabled(!this.busy && !this.sessionLoading && this.reachable)
            .onClick(() => { this.sessionView = view; this.scheduleSidebarSave(); void this.loadSessions(); })
        }, (view: string) => view)
      }.width('100%')
      this.sessionLibrary()
      Text(this.base.split('://')[1] || '').id('active-computer').fontSize(11).fontColor('#666666').width('100%').padding({ left: 12 })
    }.width('84%').constraintSize({ maxWidth: 420 }).height('100%')
      .padding({ left: 12, right: 12, top: this.statusBarHeight + 12, bottom: this.bottomPad() + 18 })
      .backgroundColor(PANEL_COLOR)
      .transition(TransitionEffect.move(TransitionEdge.START))
      .gesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => {
        if (event.offsetX < -45) this.setDrawer(false);
      }))
  }

  @Builder
  statusNotice() {
    Text(this.status).fontColor('#FFAD25').fontSize(13).width('100%')
      .padding(12).backgroundColor('#342A15').borderRadius(12)
  }

  @Builder
  textPreviewPage(preview: ReceivedFilePreview) {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text(preview.name).id('text-preview-title').layoutWeight(1)
          .fontSize(18).fontWeight(FontWeight.Medium).fontColor(TEXT_COLOR)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('关闭').chatAction().id('text-preview-close').enabled(!this.savingPreview)
          .onClick(() => { this.textFilePreview = undefined; })
      }.width('100%')
      Row({ space: 8 }) {
        Button(this.savingPreview ? '正在保存…' : '保存到本机').chatAction().id('preview-save-local')
          .enabled(!this.savingPreview).onClick(() => { void this.savePreviewLocally(preview); })
        if (preview.systemUri) {
          Button('系统预览').chatAction().enabled(!this.savingPreview)
            .onClick(() => { void this.reopenSystemPreview(preview); })
        }
      }.width('100%')
      if (this.previewNotice) {
        Text(this.previewNotice).id('preview-notice').fontSize(13).fontColor(TEXT_COLOR).width('100%')
      }
      Scroll(this.previewScroller) {
        Column() {
          if (preview.text === undefined) {
            Text(preview.systemUri ? '点击「系统预览」打开文件。' : '已接收文件，可保存到本机。')
              .fontSize(15).fontColor(MUTED_COLOR)
          } else if (!preview.text.length) {
            Text('空文件').fontSize(15).fontColor(MUTED_COLOR)
          } else if (preview.markdown) {
            ChatContent({ text: preview.text })
          } else {
            Text(preview.text).fontSize(15).lineHeight(24).fontFamily('monospace').fontColor(TEXT_COLOR)
              .width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 16 })
      }.id('text-preview-body').scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
        .layoutWeight(1).width('100%').align(Alignment.TopStart)
      if (preview.nextOffset !== undefined || (preview.offset ?? 0) > 0) {
        Row({ space: 8 }) {
          Button('上一页').chatAction().enabled((preview.offset ?? 0) > 0 && !this.savingPreview)
            .onClick(() => { this.changePreviewPage(false); })
          Text(`第 ${this.previewOffsets.length + 1} 页`).fontSize(13).fontColor(MUTED_COLOR).layoutWeight(1)
            .textAlign(TextAlign.Center)
          Button('下一页').chatAction().enabled(preview.nextOffset !== undefined && !this.savingPreview)
            .onClick(() => { this.changePreviewPage(true); })
        }.width('100%')
      }
    }.id('text-file-preview').width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: this.statusBarHeight + 12, bottom: this.bottomPad() + 4 })
      .backgroundColor(PAGE_COLOR).hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 8 }) {
        if (this.loading) {
          this.welcome()
        } else if (this.isPaired) {
          this.chat()
          if (this.status) this.statusNotice()
          if (!this.keyboardHeight || this.activeTab !== 'tasks' || this.showSettings || this.showFiles) this.bottomTabs()
        } else {
          Scroll() {
            this.connection()
          }.layoutWeight(1).width('100%').align(Alignment.TopStart)
          if (this.status) this.statusNotice()
        }
      }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: this.statusBarHeight + 4, bottom: this.bottomPad() + 4 })
        .backgroundColor(PAGE_COLOR)
      if (this.showSessions && this.isPaired) {
        Button({ type: ButtonType.Normal }).chatAction().width('100%').height('100%').backgroundColor('#66000000').borderRadius(0)
          .accessibilityText('关闭会话列表').onClick(() => { this.setDrawer(false); })
        this.sessionDrawer()
      }
      if (this.showModelMenu) {
        Button({ type: ButtonType.Normal }).chatAction().width('100%').height('100%').backgroundColor('#66000000').borderRadius(0)
          .accessibilityText('关闭模型菜单').onClick(() => { this.showModelMenu = false; })
        Column() {
          this.modelSheet()
        }.width('100%').height('100%').justifyContent(FlexAlign.End)
          .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 220, curve: Curve.EaseOut }))
      }
      if (this.recording || this.voicePreparing || (this.voiceFinishing && !this.voiceCancelling) || this.voiceHint) {
        Column() {
          Column({ space: 16 }) {
            if (this.recording) {
              Image(this.holdCancel ? $r('app.media.ic_close') : $r('app.media.ic_mic')).width(40).height(40)
              Text(this.holdCancel ? '松开手指，取消发送' : '手指上滑，取消发送')
                .fontSize(15).fontColor(this.holdCancel ? '#FFFFFF' : '#D8D8D8')
              Text(this.recordSeconds >= 50 ? `还可说 ${60 - this.recordSeconds} 秒` : `${this.recordSeconds}″`)
                .fontSize(13).fontColor(this.holdCancel ? '#FFFFFF' : '#A8A8A8')
              if (this.liveVoiceText && !this.holdCancel) {
                Text(this.liveVoiceText).fontSize(14).fontColor('#D8D8D8').maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
              }
            } else if (this.voicePreparing || (this.voiceFinishing && !this.voiceCancelling && !this.voiceHint)) {
              LoadingProgress().width(36).height(36).color('#E8E8E8')
              Text(this.voicePreparing ? '正在准备麦克风…' : '正在转为文字…').fontSize(15).fontColor('#D8D8D8')
            } else {
              Text(this.voiceHint).fontSize(15).fontColor('#E8E8E8').textAlign(TextAlign.Center)
            }
          }.id('voice-feedback').width(250).padding(26).alignItems(HorizontalAlign.Center).borderRadius(20)
            .backgroundColor(this.holdCancel ? '#B74747' : '#EE303030')
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.textFilePreview) this.textPreviewPage(this.textFilePreview)
    }.width('100%').height('100%').backgroundColor(PAGE_COLOR)
      .bindSheet(this.showToolDetails, this.toolDetailsSheet(), {
        detents: ['65%', SheetSize.LARGE], dragBar: true, showClose: true,
        backgroundColor: PANEL_COLOR, maskColor: '#99000000',
        onDisappear: () => { this.closeToolDetails(); }
      })
      .priorityGesture(PanGesture({ direction: PanDirection.Horizontal }).onActionEnd((event: GestureEvent) => {
        if (this.textFilePreview || this.holdActive || this.recording || this.voicePreparing || this.voiceFinishing || !this.isPaired || Math.abs(event.offsetX) <= 45 ||
          Math.abs(event.offsetX) <= Math.abs(event.offsetY) * 1.3) return;
        if (this.showSessions && event.offsetX < 0) this.setDrawer(false);
        else if (this.showFiles && event.offsetX > 0 && !this.busy) this.fileBack();
        else if (!this.showSessions && event.offsetX > 0 && !this.showFiles && !this.showSettings && !this.busy) {
          this.setDrawer(true);
        }
      }))
  }
}
