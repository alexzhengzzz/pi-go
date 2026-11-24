import type { common } from '@kit.AbilityKit';
import type { UIContext } from '@kit.ArkUI';
import type { AppUiState } from '../AppUiState';
import { MAX_SHARED_DRAFT_BYTES, releaseIncomingShare, sharedDraftSize } from '../IncomingShare';
import { choosePromptImage, capturePromptImage } from '../PromptImage';
import type { PromptImage } from '../PromptImage';
import { choosePromptFiles, MAX_FILES } from '../PromptFile';
import { formatSessionMarkdown, shareSessionViaSystem } from '../SessionShare';
import type { SessionShareMeta } from '../SessionShare';
import { MAX_IMAGE_ATTACHMENTS, MAX_TOTAL_IMAGE_DRAFTS, MAX_TOTAL_FILE_DRAFTS } from './PiGoConstants';
import type { BridgeReply, ChatMessage, DraftAttachment, Payload, SessionRow } from './PiGoTypes';

export interface ShareAttachmentHost {
  appState: AppUiState;
  messages: () => ChatMessage[];
  historyCursor: () => string | undefined;
  reachable: () => boolean;
  syncMode: () => string;
  epoch: () => number;
  currentId: () => string;
  openingSession: () => boolean;
  project: () => string;
  liveText: () => string;
  activeTab: () => string;
  minePage: () => string;
  busy: () => boolean;
  setBusy: (value: boolean) => void;
  setStatus: (status: string) => void;
  draft: () => string;
  setDraft: (draft: string) => void;
  attachments: () => DraftAttachment[];
  setAttachments: (attachments: DraftAttachment[]) => void;
  draftAttachments: () => Map<string, DraftAttachment[]>;
  acceptsImage: () => boolean;
  hasPendingSend: () => boolean;
  request: (path: string) => Promise<BridgeReply>;
  fetchFullMessageText: (sessionId: string, messageId: string, epoch: number) => Promise<string | undefined>;
  getUIContext: () => UIContext;
  dismissKeyboard: () => void;
  chatTitle: () => string;
  computerTitle: () => string;
  drawerOpen: () => boolean;
  setDrawer: (open: boolean) => void;
  requestAction: (path: string, input: Payload) => Promise<boolean>;
  prepareShareTarget: () => boolean;
  canAddShareToCurrent: () => boolean;
  openComputers: () => void;
  showChat: () => void;
  showSessionPicker: () => void;
  draftKey: (id: string) => string;
  rememberDraft: (id: string) => void;
}

@ObservedV2
export class ShareAttachmentState {
  @Trace shareError: string = '';
  @Trace shareTargetPicker: string = '';
  @Trace sharingSession: boolean = false;
}

export class ShareAttachmentController {
  readonly state: ShareAttachmentState = new ShareAttachmentState();
  private readonly host: ShareAttachmentHost;

  constructor(host: ShareAttachmentHost) {
    this.host = host;
  }

  chooseShareComputer(): void {
    if (!this.host.prepareShareTarget()) return;
    this.state.shareTargetPicker = 'computer';
    this.host.openComputers();
  }

  onIncomingShare(): void {
    this.state.shareError = '';
    this.state.shareTargetPicker = '';
    if (this.showIncomingShare() && this.host.drawerOpen()) this.host.setDrawer(false);
  }

  private async collectCurrentSessionMessages(sessionId: string, epoch: number): Promise<ChatMessage[]> {
    let collected: ChatMessage[] = this.host.messages().slice();
    let cursor: string | undefined = this.host.historyCursor();
    const seenCursors = new Set<string>();
    if (this.host.reachable() && cursor) {
      const sync = this.host.syncMode() === 'sequenced' ? '&sync=2' : '';
      for (let page = 0; page < 50 && cursor; page++) {
        if (seenCursors.has(cursor)) break;
        seenCursors.add(cursor);
        try {
          const result: BridgeReply = await this.host.request(`/history?id=${encodeURIComponent(sessionId)}&before=${encodeURIComponent(cursor)}${sync}`);
          if (epoch !== this.host.epoch() || this.host.currentId() !== sessionId || result.session?.id !== sessionId) break;
          const known = new Set<string>(collected.map((item: ChatMessage): string => item.id));
          const older: ChatMessage[] = (result.messages ?? []).filter((item: ChatMessage): boolean => !known.has(item.id));
          collected = older.concat(collected);
          cursor = result.historyCursor;
        } catch {
          break;
        }
      }
    }
    if (!this.host.reachable()) return collected;
    const expanded: ChatMessage[] = [];
    for (const message of collected) {
      if (epoch !== this.host.epoch() || this.host.currentId() !== sessionId) break;
      if (message.textTruncated) {
        try {
          const full = await this.host.fetchFullMessageText(sessionId, message.id, epoch);
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

  async shareCurrentSession(anchor: string = 'session-settings'): Promise<void> {
    if (this.state.sharingSession || this.host.openingSession()) return;
    if (!this.host.currentId()) {
      this.host.getUIContext().getPromptAction().showToast({ message: '请先打开一个会话' });
      return;
    }
    this.host.dismissKeyboard();
    const epoch = this.host.epoch();
    const id = this.host.currentId();
    this.state.sharingSession = true;
    try {
      const fullMessages = await this.collectCurrentSessionMessages(id, epoch);
      if (epoch !== this.host.epoch() || id !== this.host.currentId()) return;
      const meta: SessionShareMeta = {
        title: this.host.chatTitle(),
        workspace: this.host.project(),
        computer: this.host.computerTitle()
      };
      const markdown = formatSessionMarkdown(fullMessages, meta, { liveText: this.host.liveText() });
      if (!markdown) {
        this.host.getUIContext().getPromptAction().showToast({ message: '当前会话暂无可分享的内容' });
        return;
      }
      const host = this.host.getUIContext().getHostContext();
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
      if (epoch === this.host.epoch()) {
        this.host.getUIContext().getPromptAction().showToast({ message: '暂时无法调起系统分享，请重试' });
      }
    } finally {
      this.state.sharingSession = false;
    }
  }

  async shareSidebarSession(session: SessionRow): Promise<void> {
    if (this.state.sharingSession || this.host.openingSession()) return;
    if (session.id === this.host.currentId()) {
      this.host.setDrawer(false);
      await this.shareCurrentSession('session-settings');
      return;
    }
    if (!this.host.reachable()) {
      this.host.getUIContext().getPromptAction().showToast({ message: '请先连接电脑再分享该会话' });
      return;
    }
    this.host.showChat();
    const opened = await this.host.requestAction('/open', { id: session.id });
    if (opened && this.host.currentId() === session.id) {
      await this.shareCurrentSession('session-settings');
    }
  }

  showIncomingShare(): boolean {
    if (!this.host.appState.incomingShare.text && !this.host.appState.incomingShare.attachments.length && !this.host.appState.incomingShare.skipped) return false;
    if (this.state.shareTargetPicker === 'session' && this.host.drawerOpen()) return false;
    if (this.state.shareTargetPicker === 'computer' && this.host.activeTab() === 'mine' && this.host.minePage() === 'computers') return false;
    return true;
  }

  clearIncomingShare(): void {
    releaseIncomingShare(this.host.appState.incomingShare);
    this.host.appState.incomingShare = { text: '', attachments: [], skipped: false };
  }

  chooseShareSession(): void {
    if (!this.host.prepareShareTarget()) return;
    this.state.shareTargetPicker = 'session';
    this.host.showChat();
    this.host.showSessionPicker();
  }

  addShareToDraft(): void {
    const incoming = this.host.appState.incomingShare;
    if (!this.host.canAddShareToCurrent() || this.host.busy() || this.host.openingSession() || this.host.hasPendingSend()) return;
    const list = this.host.attachments().concat(incoming.attachments);
    const images = list.filter((item: DraftAttachment): boolean => item.kind === 'image').length;
    const addedImages = incoming.attachments.filter((item: DraftAttachment): boolean => item.kind === 'image').length;
    const addedFiles = incoming.attachments.length - addedImages;
    const stored = this.storedDraftAttachments();
    if (addedImages && !this.host.acceptsImage()) {
      this.state.shareError = '当前模型不支持图片，请换会话或切换模型。';
      return;
    }
    if (images > MAX_IMAGE_ATTACHMENTS || list.length - images > MAX_FILES ||
        stored[0] + addedImages > MAX_TOTAL_IMAGE_DRAFTS || stored[1] + addedFiles > MAX_TOTAL_FILE_DRAFTS) {
      this.state.shareError = '附件草稿已满，请移除部分附件或换个会话。';
      return;
    }
    const sharedText = incoming.text.startsWith('/') && !this.host.draft().trim() ? '> ' + incoming.text : incoming.text;
    const draft = [this.host.draft(), sharedText].filter((part: string): boolean => !!part).join('\n\n');
    if (sharedDraftSize(draft) > MAX_SHARED_DRAFT_BYTES) {
      this.state.shareError = '合并后超过消息长度上限，请缩短现有草稿或换个会话。';
      return;
    }
    const key = this.host.draftKey(this.host.currentId());
    this.host.setDraft(draft);
    this.host.rememberDraft(this.host.currentId());
    this.commitDraftAttachments(key, list);
    this.host.appState.incomingShare = { text: '', attachments: [], skipped: false };
    this.host.getUIContext().getPromptAction().showToast({ message: '已加入当前会话草稿' });
  }

  private storedDraftAttachments(): number[] {
    let images = 0;
    let files = 0;
    for (const list of this.host.draftAttachments().values()) {
      for (const item of list) {
        if (item.kind === 'image') images += 1;
        else files += 1;
      }
    }
    return [images, files];
  }

  private commitDraftAttachments(key: string, list: DraftAttachment[]): void {
    if (list.length) this.host.draftAttachments().set(key, list);
    else this.host.draftAttachments().delete(key);
    this.host.setAttachments(list);
  }

  removeAttachment(index: number): void {
    const key = this.host.draftKey(this.host.currentId());
    const list = this.host.attachments().slice();
    const removed = list.splice(index, 1)[0];
    if (removed && removed.image) removed.image.preview.release().catch((): void => {});
    this.commitDraftAttachments(key, list);
  }

  async attachImage(source: string): Promise<void> {
    if (this.host.busy() || this.host.openingSession() || !this.host.currentId() || this.host.hasPendingSend()) return;
    if (!this.host.acceptsImage()) { this.host.setStatus('当前模型不支持图片输入，可改发文件。'); return; }
    const key = this.host.draftKey(this.host.currentId());
    const slots = MAX_IMAGE_ATTACHMENTS - this.host.attachments().filter((item: DraftAttachment): boolean => item.kind === 'image').length;
    if (slots <= 0) { this.host.setStatus(`一条消息最多 ${MAX_IMAGE_ATTACHMENTS} 张图片。`); return; }
    const stored = this.storedDraftAttachments();
    if (stored[0] >= MAX_TOTAL_IMAGE_DRAFTS || stored[1] >= MAX_TOTAL_FILE_DRAFTS) {
      this.host.setStatus('附件草稿过多，请先发送或移除部分附件。');
      return;
    }
    const epoch = this.host.epoch();
    this.host.setBusy(true);
    this.host.setStatus('');
    try {
      let picked: PromptImage[] = [];
      if (source === 'camera') {
        const context = this.host.getUIContext().getHostContext();
        const image = context ? await capturePromptImage(context) : undefined;
        if (image) picked = [image];
      } else picked = await choosePromptImage(slots);
      if (picked.length && epoch === this.host.epoch() && key === this.host.draftKey(this.host.currentId())) {
        const addition: DraftAttachment[] = [];
        for (const image of picked) {
          if (addition.length < slots) {
            addition.push({ kind: 'image', name: 'photo.jpg', size: image.jpeg.length, image: image });
          } else image.preview.release().catch((): void => {});
        }
        this.commitDraftAttachments(key, this.host.attachments().concat(addition));
      } else {
        for (const image of picked) image.preview.release().catch((): void => {});
      }
    } catch {
      if (epoch === this.host.epoch()) this.host.setStatus('未能读取或缩小图片，可尝试更小的图片。');
    } finally { this.host.setBusy(false); }
  }

  async attachFile(): Promise<void> {
    if (this.host.busy() || this.host.openingSession() || !this.host.currentId() || this.host.hasPendingSend()) return;
    const key = this.host.draftKey(this.host.currentId());
    const slots = MAX_FILES - this.host.attachments().filter((item: DraftAttachment): boolean => item.kind === 'file').length;
    if (slots <= 0) { this.host.setStatus(`一条消息最多 ${MAX_FILES} 个文件（单个 8MB 内）。`); return; }
    const stored = this.storedDraftAttachments();
    if (stored[0] >= MAX_TOTAL_IMAGE_DRAFTS || stored[1] >= MAX_TOTAL_FILE_DRAFTS) {
      this.host.setStatus('附件草稿过多，请先发送或移除部分附件。');
      return;
    }
    const epoch = this.host.epoch();
    this.host.setBusy(true);
    this.host.setStatus('');
    try {
      const picked = await choosePromptFiles(slots);
      if (picked.length && epoch === this.host.epoch() && key === this.host.draftKey(this.host.currentId())) {
        const addition: DraftAttachment[] = [];
        for (const file of picked) {
          if (addition.length < slots) addition.push({ kind: 'file', name: file.name, size: file.size, file: file });
        }
        this.commitDraftAttachments(key, this.host.attachments().concat(addition));
      }
    } catch {
      if (epoch === this.host.epoch()) this.host.setStatus('未能读取所选文件；单个文件不超过 8MB。');
    } finally { this.host.setBusy(false); }
  }
}
