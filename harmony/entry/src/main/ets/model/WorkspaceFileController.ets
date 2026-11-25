import type { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import type { UIContext } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { filePreview } from '@kit.PreviewKit';
import { HISTORY_IMAGE_EXTENSIONS, isImageFile, markdownWorkspacePath, safeLocalFileName, textPreviewFormat } from '../ChatPaths';
import { MAX_DOWNLOAD_BYTES, MAX_INLINE_IMAGE_BYTES, MAX_TEXT_PREVIEW_BYTES, RECEIVED_FILE_DIR, RECEIVED_FILE_TTL_S } from './PiGoConstants';
import { BridgeFailure } from './PiGoTypes';
import type { BridgeEndpoint, BridgeReply, FileDirectory, FileEntry, FileTreeRow, MarkdownTableReader, Payload,
  ReceivedFilePreview } from './PiGoTypes';

export interface WorkspaceFileHost {
  busy: () => boolean;
  setBusy: (value: boolean) => void;
  openingSession: () => boolean;
  reachable: () => boolean;
  epoch: () => number;
  currentId: () => string;
  workspaceCwd: () => string;
  base: () => string;
  endpoint: () => BridgeEndpoint;
  setStatus: (status: string) => void;
  getUIContext: () => UIContext;
  request: (path: string, input?: Payload) => Promise<BridgeReply>;
  leaveComputer: (forget: boolean) => void;
  downloadFile: (endpoint: BridgeEndpoint, cwd: string, path: string, local: string, lookupName: boolean,
    limit: number) => Promise<void>;
  dismissKeyboard: () => void;
  closeToolDetails: () => void;
  scrollPreviewToTop: () => void;
}

@ObservedV2
export class WorkspaceFileState {
  @Trace fileRoot: string = '';
  @Trace fileTreeRows: FileTreeRow[] = [];
  @Trace fileTreeIndex: number = 0;
  @Trace openingFile: boolean = false;
  @Trace editingPath: string = '';
  editingRoot: string = '';
  @Trace fileText: string = '';
  @Trace fileOriginal: string = '';
  @Trace editorNotice: string = '';
  fileVersion: string = '';
  @Trace markdownTableReader?: MarkdownTableReader = undefined;
  @Trace markdownRotationUnavailable: boolean = false;
  @Trace textFilePreview?: ReceivedFilePreview = undefined;
  @Trace savingPreview: boolean = false;
  @Trace previewNotice: string = '';
  @Trace previewOffsets: number[] = [];
}

export class WorkspaceFileController {
  readonly state: WorkspaceFileState = new WorkspaceFileState();
  private imageQueue: Promise<void> = Promise.resolve();
  private lastImageCachePrune: number = 0;
  private readonly fileDirectories: Map<string, FileDirectory> = new Map();
  private markdownRotation: Promise<void> = Promise.resolve();
  private markdownRotationRevision: number = 0;
  private markdownWindow?: window.Window;
  private markdownPreviousOrientation?: window.Orientation;
  private readonly host: WorkspaceFileHost;

  constructor(host: WorkspaceFileHost) {
    this.host = host;
  }

  showDirectory(root: string): void {
    if (this.state.fileRoot !== root) {
      this.resetFileTree();
      this.state.fileRoot = root;
    }
    if (!this.fileDirectories.has('')) void this.loadFileDirectory('');
  }

  previewPageNumber(): number {
    return this.state.previewOffsets.length + 1;
  }

  previewDraft(): void {
    this.showTextPreview(this.state.editingRoot, this.state.editingPath, this.state.fileText);
  }

  closeFileEditor(): void {
    this.state.editingPath = '';
    this.state.editingRoot = '';
    this.state.fileText = '';
    this.state.fileOriginal = '';
    this.state.fileVersion = '';
    this.state.editorNotice = '';
  }

  returnToFilePreview(discard: boolean = false): void {
    if (this.host.busy()) return;
    if (!discard && this.state.fileText !== this.state.fileOriginal) {
      this.state.editorNotice = '请先保存或放弃文件修改。';
      return;
    }
    this.showTextPreview(this.state.editingRoot, this.state.editingPath, this.state.fileOriginal, this.state.fileVersion);
    this.closeFileEditor();
  }

  resetFileTree(): void {
    this.state.fileRoot = '';
    this.fileDirectories.clear();
    this.state.fileTreeRows = [];
    this.state.fileTreeIndex = 0;
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
    this.state.fileTreeRows = rows;
  }

  async toggleFileDirectory(path: string): Promise<void> {
    if (this.host.busy() || this.host.openingSession()) return;
    const directory = this.fileDirectories.get(path);
    if (!directory) {
      await this.loadFileDirectory(path);
      return;
    }
    directory.expanded = !directory.expanded;
    this.updateFileTree();
  }

  async loadFileDirectory(path: string, more: boolean = false): Promise<void> {
    if (this.host.busy() || this.host.openingSession() || !this.state.fileRoot) return;
    const directory = this.fileDirectories.get(path);
    if (more && directory?.nextCursor === undefined) return;
    const epoch = this.host.epoch();
    const root = this.state.fileRoot;
    this.host.setBusy(true);
    try {
      const result = await this.host.request('/files/list', { cwd: root, path: path, cursor: more ? directory?.nextCursor : 0 });
      if (epoch !== this.host.epoch() || root !== this.state.fileRoot) return;
      const page = result.entries ?? [];
      const previous = more ? directory?.entries ?? [] : [];
      const loadedPaths = new Set(previous.map((entry: FileEntry): string => entry.path));
      const entries = previous.concat(page.filter((entry: FileEntry): boolean => !loadedPaths.has(entry.path)));
      if (!path && !more) this.fileDirectories.clear();
      this.fileDirectories.set(path, { entries: entries, nextCursor: result.nextCursor, expanded: true });
      this.updateFileTree();
      this.host.setStatus('');
    } catch (error) {
      if (epoch === this.host.epoch() && root === this.state.fileRoot) this.fileFailure(error);
    } finally { this.host.setBusy(false); }
  }

  private fileFailure(error: Error, editing: boolean = false): void {
    if (error instanceof BridgeFailure && error.status === 401) { this.host.leaveComputer(true); return; }
    const notice = error.message === 'file_conflict' ? '电脑上的文件已变化，未覆盖。请复制手机修改后重新打开文件。' :
      error.message === 'file_too_large' ? '文本文件上限为 64 KiB，修改已保留。' :
      error.message === 'not_text_file' ? '此文件不是可编辑的 UTF-8 文本。' :
      error.message === 'file_not_found' ? '当前工作区找不到该文件。' :
      error.message === 'ambiguous_file_name' ? '工作区有多个同名文件，请使用完整的相对路径。' :
      error.message === 'file_lookup_limit' ? '工作区过大，无法按文件名查找。请使用完整的相对路径。' :
      error.message === 'path_forbidden' ? '此路径不可访问（不支持符号链接）。' :
      '文件操作未确认。请检查连接和项目授权；修改不会自动重发。';
    if (editing) this.state.editorNotice = notice;
    else if (this.state.textFilePreview) this.state.previewNotice = notice;
    else this.host.setStatus(notice);
  }

  showTextPreview(cwd: string, path: string, text: string, version?: string): void {
    this.host.dismissKeyboard();
    this.host.closeToolDetails();
    this.state.previewOffsets = [];
    this.state.previewNotice = '';
    this.host.setStatus('');
    const name = path.split('/').pop() ?? path;
    this.state.textFilePreview = { name: name, text: text, markdown: textPreviewFormat(name) === 'markdown',
      workspaceRoot: cwd, workspacePath: path, version: version };
  }

  async openFile(cwd: string, path: string, lookupName: boolean = false): Promise<void> {
    if (this.host.busy() || this.host.openingSession() || this.state.openingFile || !cwd) return;
    if (!this.host.reachable()) { this.host.setStatus('电脑离线，稍后再试。'); return; }
    const epoch = this.host.epoch();
    this.host.setBusy(true);
    try {
      const lookup = lookupName && !path.includes('/') ? 'name' : undefined;
      const result = await this.host.request('/files/read', { cwd: cwd, path: path, lookup: lookup });
      if (epoch !== this.host.epoch()) return;
      if (result.text === undefined || !result.path || !result.version) throw new Error('invalid_file');
      this.showTextPreview(cwd, result.path, result.text, result.version);
    } catch (error) {
      if (epoch !== this.host.epoch()) return;
      const message = (error as Error).message;
      if (message === 'not_text_file' || message === 'file_too_large' || message === 'not_found' ||
        (message === 'file_not_found' && lookupName && !path.includes('/'))) {
        await this.openWorkspaceFile(cwd, path, lookupName);
        return;
      }
      this.fileFailure(error);
    } finally { this.host.setBusy(false); }
  }

  async openReferencedFile(cwd: string, path: string, lookupName: boolean): Promise<void> {
    if (this.host.busy() || this.host.openingSession()) return;
    const name = path.split('/').pop() ?? path;
    if (textPreviewFormat(name)) await this.openFile(cwd, path, lookupName);
    else await this.openWorkspaceFile(cwd, path, lookupName);
  }

  editPreview(preview: ReceivedFilePreview): void {
    if (this.host.busy() || this.state.savingPreview || this.state.editingPath || preview.text === undefined ||
      !preview.version || !preview.workspaceRoot || !preview.workspacePath) return;
    this.state.editingRoot = preview.workspaceRoot;
    this.state.editingPath = preview.workspacePath;
    this.state.fileText = preview.text;
    this.state.fileOriginal = preview.text;
    this.state.fileVersion = preview.version;
    this.state.editorNotice = '';
    this.state.textFilePreview = undefined;
  }

  async saveFile(): Promise<void> {
    if (this.host.busy() || this.host.openingSession() || !this.host.reachable() || !this.state.editingPath || this.state.fileText === this.state.fileOriginal) return;
    const epoch = this.host.epoch();
    const text = this.state.fileText;
    this.host.setBusy(true);
    this.state.editorNotice = '';
    try {
      const result = await this.host.request('/files/save', { cwd: this.state.editingRoot, path: this.state.editingPath, text: text, version: this.state.fileVersion });
      if (epoch !== this.host.epoch()) return;
      if (!result.version) throw new Error('invalid_file');
      this.state.fileVersion = result.version;
      this.state.fileOriginal = text;
      this.state.editorNotice = '已保存到电脑。';
    } catch (error) { if (epoch === this.host.epoch()) this.fileFailure(error, true); }
    finally { this.host.setBusy(false); }
  }

  // —— 电脑 → 手机：接收文件并点击打开 ——

  private downloadFailure(error: Error): void {
    if (error instanceof BridgeFailure && error.status === 401) { this.host.leaveComputer(true); return; }
    this.host.setStatus(error.message === 'not_found' ? '当前 Pi Go 服务缺少文件下载接口。请更新电脑端 Pi Go 后重新连接。' :
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
      '接收文件未完成，请检查连接后重试。');
  }

  private localFilePrefix(cwd: string, path: string): string {
    const hash = cryptoFramework.createMd('SHA256');
    const key = JSON.stringify([this.host.base(), this.host.endpoint().token, cwd, path]);
    hash.updateSync({ data: new util.TextEncoder().encodeInto(key) });
    return Array.from(hash.digestSync().data, (byte: number): string => byte.toString(16).padStart(2, '0')).join('');
  }

  private async downloadFile(cwd: string, path: string, temporary: string, lookupName: boolean, limit: number = MAX_DOWNLOAD_BYTES): Promise<void> {
    return this.host.downloadFile(this.host.endpoint(), cwd, path, temporary, lookupName, limit);
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

  async openWorkspaceFile(cwd: string, path: string, lookupName: boolean = false): Promise<void> {
    if (this.state.openingFile) { this.host.setStatus('正在接收上一个文件…'); return; }
    if (!this.host.reachable()) { this.host.setStatus('电脑离线，稍后再试。'); return; }
    const epoch = this.host.epoch();
    const name = path.split('/').pop() ?? path;
    this.state.openingFile = true;
    this.host.setStatus(`正在接收 ${name}…`);
    let temporary = '';
    try {
      const host = this.host.getUIContext().getHostContext();
      if (!host) throw new Error('no_context');
      const context = host as common.UIAbilityContext;
      const directory = `${context.cacheDir}/${RECEIVED_FILE_DIR}`;
      if (!fileIo.accessSync(directory)) fileIo.mkdirSync(directory, true);
      this.pruneReceivedFiles(directory);
      const local = `${directory}/${this.localFilePrefix(cwd, path)}-${safeLocalFileName(name)}`;
      temporary = `${directory}/.download-${util.generateRandomUUID()}`;
      await this.downloadFile(cwd, path, temporary, lookupName);
      if (epoch !== this.host.epoch()) return;
      fileIo.renameSync(temporary, local);
      temporary = '';
      this.host.dismissKeyboard();
      this.host.closeToolDetails();
      this.state.previewOffsets = [];
      this.state.previewNotice = '';
      this.host.setStatus('');
      this.state.textFilePreview = { name: name, localPath: local };
      try {
        const textPreview = this.readTextFilePreview(local, name, 0, cwd, path);
        if (textPreview) { this.state.textFilePreview = textPreview; return; }
        const uri = fileUri.getUriFromPath(local);
        if (isImageFile(name)) {
          this.state.textFilePreview = { name: name, localPath: local, imageUri: uri };
          return;
        }
        const previewable = await filePreview.canPreview(context, uri);
        if (epoch !== this.host.epoch() || this.state.textFilePreview?.localPath !== local || !previewable) return;
        this.state.textFilePreview = { name: name, localPath: local, systemUri: uri };
        await filePreview.openPreview(context, { title: name, uri: uri, mimeType: '' });
      } catch {
        if (epoch === this.host.epoch() && this.state.textFilePreview?.localPath === local) this.state.previewNotice = '无法打开预览，仍可保存文件。';
      }
    } catch (error) {
      if (epoch === this.host.epoch()) this.downloadFailure(error as Error);
    } finally {
      if (temporary) {
        try { fileIo.unlinkSync(temporary); } catch {}
      }
      this.state.openingFile = false;
    }
  }

  changePreviewPage(forward: boolean): void {
    const preview = this.state.textFilePreview;
    const offset = forward ? preview?.nextOffset : this.state.previewOffsets[this.state.previewOffsets.length - 1];
    if (!preview?.localPath || offset === undefined) return;
    try {
      const page = this.readTextFilePreview(preview.localPath, preview.name, offset, preview.workspaceRoot, preview.workspacePath);
      if (!page) throw new Error('preview_read_failed');
      if (forward) this.state.previewOffsets.push(preview.offset ?? 0);
      else this.state.previewOffsets.pop();
      this.state.previewNotice = '';
      this.state.textFilePreview = page;
      this.host.scrollPreviewToTop();
    } catch { this.state.previewNotice = '无法读取这一页，仍可保存完整文件。'; }
  }

  async savePreviewLocally(preview: ReceivedFilePreview): Promise<void> {
    if (this.state.savingPreview) return;
    this.state.savingPreview = true;
    this.state.previewNotice = '';
    const epoch = this.host.epoch();
    try {
      const context = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [preview.name];
      const uris = await new picker.DocumentViewPicker(context).save(options);
      if (!uris.length || epoch !== this.host.epoch()) return;
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
      if (epoch === this.host.epoch()) this.state.previewNotice = '已保存到本机。';
    } catch {
      if (epoch === this.host.epoch()) this.state.previewNotice = '保存未完成，请检查所选位置和可用空间。';
    } finally { this.state.savingPreview = false; }
  }

  async imagePreviewError(preview: ReceivedFilePreview): Promise<void> {
    if (this.state.textFilePreview?.imageUri !== preview.imageUri) return;
    this.state.previewNotice = '图片无法解码';
    if (!preview.localPath || !preview.imageUri || preview.systemUri) return;
    try {
      const context = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
      if (await filePreview.canPreview(context, preview.imageUri) && this.state.textFilePreview?.imageUri === preview.imageUri) {
        this.state.textFilePreview = { name: preview.name, localPath: preview.localPath, imageUri: preview.imageUri,
          systemUri: preview.imageUri };
        this.state.previewNotice = '应用内无法显示这张图片，可尝试系统预览。';
      }
    } catch {}
  }

  async reopenSystemPreview(preview: ReceivedFilePreview): Promise<void> {
    if (!preview.systemUri) return;
    try {
      const context = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
      await filePreview.openPreview(context, { title: preview.name, uri: preview.systemUri, mimeType: '' });
    } catch { this.state.previewNotice = '无法打开系统预览，仍可保存文件。'; }
  }

  private cacheChatImage(cwd: string, key: string, extensions: string[], write: (path: string) => Promise<string>): Promise<string> {
    const epoch = this.host.epoch();
    const sessionId = this.host.currentId();
    const checkContext = (): void => {
      if (epoch !== this.host.epoch() || sessionId !== this.host.currentId()) throw new Error('session_changed');
    };
    const load = this.imageQueue.then(async (): Promise<string> => {
      checkContext();
      const context = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
      const directory = `${context.cacheDir}/${RECEIVED_FILE_DIR}`;
      if (!fileIo.accessSync(directory)) fileIo.mkdirSync(directory, true);
      if (Date.now() - this.lastImageCachePrune >= 3600000) {
        this.pruneReceivedFiles(directory);
        this.lastImageCachePrune = Date.now();
      }
      const local = `${directory}/image-${this.localFilePrefix(cwd, key)}`;
      const cached = extensions.find((extension: string): boolean => fileIo.accessSync(local + extension));
      if (cached !== undefined) return local + cached;
      if (!this.host.reachable()) throw new Error('disconnected');
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

  loadHistoryImage(sessionId: string, messageId: string, index: number, toolId: string,
    paneCwd?: string, paneRequest?: (path: string) => Promise<BridgeReply>): Promise<string> {
    if (!sessionId || (!paneRequest && sessionId !== this.host.currentId())) return Promise.reject(new Error('session_changed'));
    const identity = JSON.stringify([sessionId, messageId, index, toolId]);
    return this.cacheChatImage(paneCwd ?? this.host.workspaceCwd(), identity, HISTORY_IMAGE_EXTENSIONS, async (local: string): Promise<string> => {
      const tool = toolId ? `&tool=${encodeURIComponent(toolId)}` : '';
      const reply = await (paneRequest ?? this.host.request)(`/message-image?id=${encodeURIComponent(sessionId)}&message=${encodeURIComponent(messageId)}&index=${index}${tool}`);
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

  loadMarkdownImage(target: string, cwd: string, documentPath: string): Promise<string> {
    const path = markdownWorkspacePath(target, cwd, documentPath);
    if (!path) return Promise.reject(new Error('image_not_found'));
    const extension = path.match(/\.[a-z0-9]{1,10}$/i)?.[0] ?? '';
    return this.cacheChatImage(cwd, JSON.stringify([path, this.host.currentId()]), [extension], async (local: string): Promise<string> => {
      await this.downloadFile(cwd, path, local, false, MAX_INLINE_IMAGE_BYTES);
      return extension;
    });
  }

  showChatImage(source: string, label: string): void {
    this.host.dismissKeyboard();
    this.host.closeToolDetails();
    this.state.previewNotice = '';
    this.state.previewOffsets = [];
    const remote = /^https?:\/\//i.test(source);
    const extension = remote ? '' : source.match(/\.[a-z0-9]{1,10}$/i)?.[0] ?? '';
    const name = label.toLowerCase().endsWith(extension.toLowerCase()) ? label : label + extension;
    this.state.textFilePreview = { name: name, localPath: remote ? undefined : source,
      imageUri: remote ? source : fileUri.getUriFromPath(source) };
  }

  async openMarkdownLink(target: string, cwd: string, documentPath: string): Promise<void> {
    if (/^https?:\/\/[^\s]+$/i.test(target)) {
      try {
        const context = this.host.getUIContext().getHostContext() as common.UIAbilityContext;
        await context.openLink(target);
      } catch {
        this.host.getUIContext().getPromptAction().showToast({ message: '无法打开链接' });
      }
      return;
    }
    const path = markdownWorkspacePath(target, cwd, documentPath);
    if (path) await this.openReferencedFile(cwd, path, !documentPath);
  }

  openMarkdownTableReader(source: string, cwd: string, documentPath: string): void {
    if (this.state.markdownTableReader) return;
    this.host.dismissKeyboard();
    const revision = ++this.markdownRotationRevision;
    this.state.markdownRotationUnavailable = false;
    this.state.markdownTableReader = { source: source, cwd: cwd, documentPath: documentPath };
    this.markdownRotation = this.markdownRotation.then(async (): Promise<void> => {
      if (revision !== this.markdownRotationRevision) return;
      const context = this.host.getUIContext().getHostContext();
      if (!context) throw new Error('no_window_context');
      const mainWindow = await window.getLastWindow(context);
      if (revision !== this.markdownRotationRevision) return;
      this.markdownPreviousOrientation = mainWindow.getPreferredOrientation();
      this.markdownWindow = mainWindow;
      await mainWindow.setPreferredOrientation(window.Orientation.LANDSCAPE);
    }).catch((): void => {
      if (revision === this.markdownRotationRevision) this.state.markdownRotationUnavailable = true;
    });
  }

  closeMarkdownTableReader(): void {
    this.markdownRotationRevision++;
    this.state.markdownTableReader = undefined;
    this.markdownRotation = this.markdownRotation.then(async (): Promise<void> => {
      const mainWindow = this.markdownWindow;
      const previous = this.markdownPreviousOrientation;
      this.markdownWindow = undefined;
      this.markdownPreviousOrientation = undefined;
      if (mainWindow && previous !== undefined) await mainWindow.setPreferredOrientation(previous);
    }).catch((): void => {});
  }
}
