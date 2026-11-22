import type { RunEvent } from '../RunResults';
import type { PromptFile } from '../PromptFile';
import type { PromptImage } from '../PromptImage';
import type { ScheduleJob, ScheduleRun } from '../ScheduledRuns';
import type { SequencedFrame, SyncCursor } from '../SessionSync';

// Bridge protocol shapes and page-level records shared by the Index page and its components.

export interface ModelOption {
  provider: string;
  id: string;
  name: string;
  image: boolean;
  levels: string[];
  thinkingLevel?: string;
}

export interface BridgeEndpoint {
  address: string;
  token: string;
  ca?: string;
  pin?: string;
}

export interface SessionState {
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

export interface SessionRow {
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

export interface SidebarRow {
  key: string;
  path?: string;
  session?: SessionRow;
  nested: boolean;
}

export interface ChatMessage {
  id: string;
  role: string;
  text: string;
  textTruncated?: boolean;
  imageCount?: number;
  thinking?: string;
  thinkingMs?: number;
  tools?: LiveTool[];
}

export interface DraftAttachment {
  kind: string;
  name: string;
  size: number;
  image?: PromptImage;
  file?: PromptFile;
}

export interface AttachmentRef {
  token: string;
  kind: string;
}

export interface UploadedAttachment {
  token: string;
  kind?: string;
  name?: string;
  size?: number;
  path?: string;
}

export interface LiveTool {
  id: string;
  name: string;
  detail: string;
  state: string;
  ms?: number;
}

export interface ToolDetails {
  input: string;
  output: string;
  command: boolean;
  imageCount?: number;
  truncated: boolean;
  state: string;
  path?: string;
}

export interface CommandRow {
  name: string;
  description?: string;
  source?: string;
  invoke?: string;
}

export interface ReceivedFilePreview {
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

export interface MarkdownTableReader {
  source: string;
  cwd: string;
  documentPath: string;
}

export interface StreamFrame extends SequencedFrame {
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

export interface PendingInteraction {
  id: string;
  method: string;
  title?: string;
  message?: string;
  options?: string[];
  placeholder?: string;
  prefill?: string;
}

export interface FileEntry {
  name: string;
  path: string;
  kind: string;
}

export interface FileDirectory {
  entries: FileEntry[];
  nextCursor?: number;
  expanded: boolean;
}

export interface FileTreeRow {
  path: string;
  name: string;
  kind: string;
  depth: number;
  expanded?: boolean;
}

export interface RunningRow {
  id: string;
  name?: string;
  cwd?: string;
  state?: string;
  started?: boolean;
}

export interface RunNotice {
  title: string;
  stopped: boolean;
}

export interface WorkspaceRow {
  cwd: string;
  name: string;
}

export interface BridgeReply {
  runEvents?: RunEvent[];
  pushAvailable?: boolean;
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

export interface HistoryImage {
  mimeType: string;
  data: string;
}

export interface Payload {
  enabled?: boolean;
  device?: string;
  token?: string;
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

export interface PendingSend {
  requestId: string;
  text: string;
  attachments: DraftAttachment[];
  steeringAfter?: string;
}

export interface QueuedSteering {
  id: string;
  sessionKey: string;
  afterId: string;
  text: string;
  imageCount: number;
  files: string[];
}

export class BridgeFailure extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}
