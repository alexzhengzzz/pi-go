import { SessionSync } from '../SessionSync';
import type { BridgeReply, ChatMessage, DraftAttachment, LiveTool, OptimisticMessage, PendingSend, QueuedSteering, StreamFrame } from './PiGoTypes';
import { MAX_LIVE_TEXT_LENGTH, STREAM_PAINT_INTERVAL_MS } from './PiGoConstants';

export const CHAT_CACHE_MAX_ENTRIES: number = 16;
const PERSIST_MAX_MESSAGES: number = 24;
const PERSIST_MAX_TEXT: number = 2000;

export interface CachedTranscriptEntry {
  key: string;
  reply: BridgeReply;
}

export interface TranscriptCacheBook {
  version: number;
  entries: CachedTranscriptEntry[];
}

interface Transcript {
  messages: ChatMessage[];
  cursor?: string;
}

interface LiveDelta {
  text: string;
  thinking: string;
}

export class ChatState {
  readonly drafts: Map<string, string>;
  readonly unconfirmed: Map<string, PendingSend>;
  readonly draftAttachments: Map<string, DraftAttachment[]>;
  readonly chatCache: Map<string, BridgeReply> = new Map<string, BridgeReply>();
  readonly sync: SessionSync<StreamFrame> = new SessionSync<StreamFrame>();
  private pendingLiveText: string = '';
  private pendingLiveThinking: string = '';
  private deltaPaintTimer: number = -1;
  private persistCache?: (book: TranscriptCacheBook) => void;
  private cacheSaveTimer: number = -1;

  constructor(sharedDrafts?: ChatState) {
    this.drafts = sharedDrafts?.drafts ?? new Map<string, string>();
    this.unconfirmed = sharedDrafts?.unconfirmed ?? new Map<string, PendingSend>();
    this.draftAttachments = sharedDrafts?.draftAttachments ?? new Map<string, DraftAttachment[]>();
  }

  mergeTranscript(messages: ChatMessage[], historyCursor: string | undefined, incoming: ChatMessage[], cursor?: string): Transcript {
    const overlap = incoming.length ? messages.findIndex((message: ChatMessage): boolean => message.id === incoming[0].id) : -1;
    if (overlap < 0) {
      return { messages: incoming.length || messages.length ? incoming : messages, cursor: cursor };
    }
    if (messages.length - overlap !== incoming.length ||
      incoming.some((message: ChatMessage, index: number): boolean => !this.sameMessage(messages[overlap + index], message))) {
      messages = messages.slice(0, overlap).concat(incoming);
    }
    return { messages: messages, cursor: overlap === 0 ? cursor : historyCursor };
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

  reconcileSteering(queue: QueuedSteering[], messages: ChatMessage[], key: string,
    settled: boolean, sending?: PendingSend): QueuedSteering[] {
    if (!queue.length) return queue;
    const tail = messages[messages.length - 1]?.id;
    const used = new Set<string>();
    const remaining: QueuedSteering[] = [];
    for (const pending of queue) {
      if (pending.sessionKey !== key) { remaining.push(pending); continue; }
      if (settled) continue;
      const after = pending.afterId ? messages.findIndex((message: ChatMessage): boolean => message.id === pending.afterId) : -1;
      if (pending.afterId && after < 0) { remaining.push(pending); continue; }
      const text = pending.files.length
        ? `${pending.text}\n\n[Pi Go 附件] 手机上传了 ${pending.files.length} 个文件：`.slice(0, 8000)
        : pending.text.slice(0, 8000);
      const match = messages.findIndex((message: ChatMessage, index: number): boolean =>
        index > after && message.role === 'user' && !used.has(message.id) && (message.imageCount ?? 0) === pending.imageCount &&
        (pending.files.length ? message.text.startsWith(text) : message.text === text));
      if (match < 0) {
        pending.afterId = tail ?? pending.afterId;
        remaining.push(pending);
        continue;
      }
      const id = messages[match].id;
      used.add(id);
      if (sending && sending.requestId !== pending.id && sending.steeringAfter !== undefined &&
        match > messages.findIndex((message: ChatMessage): boolean => message.id === sending.steeringAfter)) {
        sending.steeringAfter = id;
      }
    }
    return remaining.length !== queue.length ? remaining : queue;
  }

  reconcileOptimistic(items: OptimisticMessage[], messages: ChatMessage[], key: string,
    settled: boolean): OptimisticMessage[] {
    if (!items.length) return items;
    const used = new Set<string>();
    const remaining: OptimisticMessage[] = [];
    for (const item of items) {
      if (item.sessionKey !== key) { remaining.push(item); continue; }
      const after = item.afterId ? messages.findIndex((message: ChatMessage): boolean => message.id === item.afterId) : -1;
      const start = item.afterId && after < 0 ? -1 : after;
      const text = item.files.length
        ? `${item.text}\n\n[Pi Go 附件] 手机上传了 ${item.files.length} 个文件：`.slice(0, 8000)
        : item.text.slice(0, 8000);
      const match = messages.findIndex((message: ChatMessage, index: number): boolean =>
        index > start && message.role === 'user' && !used.has(message.id) && (message.imageCount ?? 0) === item.imageCount &&
        (item.files.length ? message.text.startsWith(text) : message.text === text));
      if (match >= 0) {
        used.add(messages[match].id);
        continue;
      }
      if (settled && !item.sending) continue;
      remaining.push(item);
    }
    return remaining.length !== items.length ? remaining : items;
  }

  rememberDraft(key: string, draft: string): void {
    this.drafts.delete(key);
    if (draft) this.drafts.set(key, draft);
    if (this.drafts.size > 128) {
      let oldest: string = '';
      this.drafts.forEach((_text: string, item: string) => { if (!oldest) oldest = item; });
      if (oldest) this.drafts.delete(oldest);
    }
  }

  forgetDrafts(address: string): void {
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

  queueStreamPaint(paint: () => void): void {
    if (this.deltaPaintTimer !== -1) return;
    this.deltaPaintTimer = setTimeout(() => { paint(); }, STREAM_PAINT_INTERVAL_MS);
  }

  flushStreamDeltas(text: string, thinking: string, paint: boolean): LiveDelta | undefined {
    if (this.deltaPaintTimer !== -1) clearTimeout(this.deltaPaintTimer);
    this.deltaPaintTimer = -1;
    const delta: LiveDelta | undefined = paint && (this.pendingLiveText || this.pendingLiveThinking)
      ? {
        text: this.pendingLiveText ? (text + this.pendingLiveText).slice(-MAX_LIVE_TEXT_LENGTH) : text,
        thinking: this.pendingLiveThinking ? (thinking + this.pendingLiveThinking).slice(-MAX_LIVE_TEXT_LENGTH) : thinking
      }
      : undefined;
    this.pendingLiveText = '';
    this.pendingLiveThinking = '';
    return delta;
  }

  appendDelta(text: string, thinking: boolean): void {
    if (thinking) this.pendingLiveThinking = (this.pendingLiveThinking + text).slice(-MAX_LIVE_TEXT_LENGTH);
    else this.pendingLiveText = (this.pendingLiveText + text).slice(-MAX_LIVE_TEXT_LENGTH);
  }

  clearDelta(thinking: boolean): void {
    if (thinking) this.pendingLiveThinking = '';
    else this.pendingLiveText = '';
  }

  receiveFrame(raw: string, sequenced: boolean, apply: (frame: StreamFrame) => void): boolean {
    let frame: StreamFrame;
    try { frame = JSON.parse(raw) as StreamFrame; } catch { return false; }
    if (sequenced) {
      if (!frame.cursor) {
        return frame.type === 'bridge/status';
      }
      if (frame.type === 'ready') {
        this.sync.ready(frame.cursor);
        return true;
      }
      return this.sync.receive(frame, apply);
    }
    apply(frame);
    return false;
  }

  setCachePersister(persist?: (book: TranscriptCacheBook) => void): void {
    this.persistCache = persist;
  }

  restoreTranscriptCache(book: TranscriptCacheBook): void {
    if (!book || book.version !== 1 || !Array.isArray(book.entries)) return;
    const entries = book.entries.slice(-CHAT_CACHE_MAX_ENTRIES);
    for (let i = 0; i < entries.length; i++) {
      const item = entries[i];
      if (!item || typeof item.key !== 'string' || !item.key || !item.reply?.session?.id) continue;
      if (!this.chatCache.has(item.key)) {
        this.chatCache.set(item.key, item.reply);
      }
    }
    while (this.chatCache.size > CHAT_CACHE_MAX_ENTRIES) {
      const oldest = Array.from(this.chatCache.keys())[0];
      if (!oldest) break;
      this.chatCache.delete(oldest);
    }
  }

  exportTranscriptCache(): TranscriptCacheBook {
    const entries: CachedTranscriptEntry[] = [];
    this.chatCache.forEach((reply: BridgeReply, key: string) => {
      if (!reply.session) return;
      const rawMessages = reply.messages ?? [];
      const sliceStart = Math.max(0, rawMessages.length - PERSIST_MAX_MESSAGES);
      const messages: ChatMessage[] = [];
      for (let i = sliceStart; i < rawMessages.length; i++) {
        const msg = rawMessages[i];
        const compact: ChatMessage = {
          id: msg.id,
          role: msg.role,
          text: msg.text.length > PERSIST_MAX_TEXT ? msg.text.slice(0, PERSIST_MAX_TEXT) : msg.text,
          textTruncated: msg.textTruncated || msg.text.length > PERSIST_MAX_TEXT ? true : undefined,
          imageCount: msg.imageCount,
          thinking: msg.thinking ? msg.thinking.slice(0, PERSIST_MAX_TEXT) : undefined,
          thinkingMs: msg.thinkingMs,
          tools: msg.tools
        };
        messages.push(compact);
      }
      const compactReply: BridgeReply = {
        session: reply.session,
        messages: messages,
        historyCursor: sliceStart > 0 ? rawMessages[sliceStart].id : reply.historyCursor
      };
      entries.push({ key: key, reply: compactReply });
    });
    return { version: 1, entries: entries.slice(-CHAT_CACHE_MAX_ENTRIES) };
  }

  private scheduleCachePersist(): void {
    if (!this.persistCache) return;
    if (this.cacheSaveTimer !== -1) clearTimeout(this.cacheSaveTimer);
    this.cacheSaveTimer = setTimeout(() => {
      this.cacheSaveTimer = -1;
      if (this.persistCache) this.persistCache(this.exportTranscriptCache());
    }, 400);
  }

  flushTranscriptCache(): void {
    if (this.cacheSaveTimer !== -1) {
      clearTimeout(this.cacheSaveTimer);
      this.cacheSaveTimer = -1;
    }
    if (this.persistCache) this.persistCache(this.exportTranscriptCache());
  }

  deleteTranscriptCache(key: string): void {
    if (this.chatCache.delete(key)) this.scheduleCachePersist();
  }

  forgetTranscriptCache(address?: string): void {
    if (address) {
      const prefix = `${address}|`;
      for (const key of Array.from(this.chatCache.keys())) {
        if (key.startsWith(prefix)) this.chatCache.delete(key);
      }
    } else {
      this.chatCache.clear();
    }
    this.flushTranscriptCache();
  }

  cacheTranscript(key: string, reply: BridgeReply): void {
    this.chatCache.delete(key);
    this.chatCache.set(key, reply);
    if (this.chatCache.size > CHAT_CACHE_MAX_ENTRIES) this.chatCache.delete(Array.from(this.chatCache.keys())[0]);
    this.scheduleCachePersist();
  }
}
