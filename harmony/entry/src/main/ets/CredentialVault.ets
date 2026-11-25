import type { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import type { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import type { TranscriptCacheBook } from './model/ChatState';
import { SIDEBAR_MAX_ENTRIES, SIDEBAR_MAX_EXPANDED, SIDEBAR_VIEWS } from './model/SessionStore';
import type { SidebarBook, SidebarEntry, SidebarState } from './model/SessionStore';

export interface Companion {
  address: string;
  token: string;
  ca?: string;
  pin?: string;
  computerId?: string;
  computerName?: string;
}

export interface ComputerBook {
  version: number;
  active: string;
  computers: Companion[];
}

type ComputerBookListener = (record: ComputerBook, source: CredentialVault) => void;
const computerBookListeners: Set<ComputerBookListener> = new Set();

export function subscribeComputerBook(listener: ComputerBookListener): () => void {
  computerBookListeners.add(listener);
  return (): void => { computerBookListeners.delete(listener); };
}

interface StoredCompanions {
  version?: number;
  active?: string;
  computers?: Companion[];
  address?: string;
  token?: string;
  ca?: string;
  pin?: string;
}

interface StoredSidebarState {
  expandedSpaces?: string[];
  sessionView?: string;
}

interface StoredSidebarEntry {
  address?: string;
  state?: StoredSidebarState;
}

interface StoredSidebar {
  version?: number;
  entries?: StoredSidebarEntry[];
}

interface Sealed {
  nonce: string;
  data: string;
}

export class CredentialVault {
  private readonly alias: string = 'pigo.companion.v1';
  private readonly encoder: util.TextEncoder = new util.TextEncoder();
  private readonly base64: util.Base64Helper = new util.Base64Helper();
  private readonly store: preferences.Preferences;
  private readonly cacheFile: string;
  private writing: Promise<void> = Promise.resolve();
  private cacheWriting: Promise<void> = Promise.resolve();

  private constructor(store: preferences.Preferences, cacheFile: string) {
    this.store = store;
    this.cacheFile = cacheFile;
  }

  static async open(context: common.Context): Promise<CredentialVault> {
    const cacheFile = `${context.filesDir}/pigo-chat-cache.json`;
    return new CredentialVault(await preferences.getPreferences(context, { name: 'pigo' }), cacheFile);
  }

  private properties(purpose: number): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE }
    ];
  }

  private async ensureKey(): Promise<void> {
    let exists: boolean = false;
    try { exists = await huks.isKeyItemExist(this.alias, { properties: [] }); }
    catch (error) { if ((error as BusinessError).code !== 12000011) throw error as Error; }
    if (exists) return;
    const purposes = huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT;
    await huks.generateKeyItem(this.alias, { properties: this.properties(purposes) });
  }

  private cipher(purpose: number, nonce: Uint8Array, tag?: Uint8Array): huks.HuksParam[] {
    const properties = this.properties(purpose);
    properties.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce });
    properties.push({ tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: this.encoder.encodeInto(this.alias) });
    if (tag) properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag });
    return properties;
  }

  async load(): Promise<ComputerBook | undefined> {
    const raw = await this.store.get('sealed', '') as string;
    if (!raw) return undefined;
    const sealed = JSON.parse(raw) as Sealed;
    const nonce = this.base64.decodeSync(sealed.nonce);
    const bytes = this.base64.decodeSync(sealed.data);
    if (nonce.length !== 12 || bytes.length < 17) throw new Error('invalid_vault');
    const tagAt = bytes.length - 16;
    const properties = this.cipher(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, nonce, bytes.slice(tagAt));
    const session = await huks.initSession(this.alias, { properties: properties });
    let result: huks.HuksReturnResult;
    try {
      result = await huks.finishSession(session.handle, { properties: properties, inData: bytes.slice(0, tagAt) });
    } catch (error) {
      await huks.abortSession(session.handle, { properties: [] }).catch(() => {});
      throw error as Error;
    }
    const text = new util.TextDecoder('utf-8').decodeWithStream(result.outData);
    const stored = JSON.parse(text) as StoredCompanions;
    if (stored.version === 2 && Array.isArray(stored.computers) && typeof stored.active === 'string') {
      return { version: 2, active: stored.active, computers: stored.computers };
    }
    if (stored.version === undefined && typeof stored.address === 'string' && typeof stored.token === 'string') {
      const legacy: Companion = { address: stored.address, token: stored.token, ca: stored.ca, pin: stored.pin };
      return { version: 2, active: legacy.address, computers: [legacy] };
    }
    throw new Error('invalid_companion_book');
  }

  save(record: ComputerBook): Promise<void> {
    const snapshot = JSON.stringify(record);
    this.writing = this.writing.catch(() => {}).then(async () => {
      if (!record.computers.length) await this.store.delete('sealed');
      else {
        await this.ensureKey();
        const nonce = (await cryptoFramework.createRandom().generateRandom(12)).data;
        const properties = this.cipher(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce);
        const session = await huks.initSession(this.alias, { properties: properties });
        let result: huks.HuksReturnResult;
        try {
          const inData = this.encoder.encodeInto(snapshot);
          result = await huks.finishSession(session.handle, { properties: properties, inData: inData });
        } catch (error) {
          await huks.abortSession(session.handle, { properties: [] }).catch(() => {});
          throw error as Error;
        }
        const value: Sealed = { nonce: this.base64.encodeToStringSync(nonce), data: this.base64.encodeToStringSync(result.outData) };
        await this.store.put('sealed', JSON.stringify(value));
      }
      await this.store.flush();
      const copied: ComputerBook = JSON.parse(snapshot) as ComputerBook;
      computerBookListeners.forEach((listener: ComputerBookListener): void => {
        if (listener) listener(copied, this);
      });
    });
    return this.writing;
  }

  // Expanded-space and filter choices are plain UI state, so they stay unsealed beside the vault.
  async loadSidebar(): Promise<SidebarBook> {
    const book: SidebarBook = { version: 1, entries: [] };
    try {
      const raw = await this.store.get('sidebar', '') as string;
      if (!raw) return book;
      const stored = JSON.parse(raw) as StoredSidebar;
      if (stored.version !== 1 || !Array.isArray(stored.entries)) return book;
      const entries: SidebarEntry[] = [];
      stored.entries.forEach((entry: StoredSidebarEntry) => {
        if (!entry || typeof entry.address !== 'string' || !entry.state) return;
        const address: string = entry.address;
        if (entries.some((kept: SidebarEntry): boolean => kept.address === address)) return;
        const view: string = entry.state.sessionView ?? '';
        const restored: SidebarState = {
          expandedSpaces: (Array.isArray(entry.state.expandedSpaces) ? entry.state.expandedSpaces : [])
            .filter((path: string): boolean => typeof path === 'string').slice(0, SIDEBAR_MAX_EXPANDED),
          sessionView: SIDEBAR_VIEWS.includes(view) ? view : 'all'
        };
        const kept: SidebarEntry = { address: address, state: restored };
        entries.push(kept);
      });
      book.entries = entries.slice(0, SIDEBAR_MAX_ENTRIES);
    } catch { /* a corrupted sidebar cache just falls back to defaults */ }
    return book;
  }

  saveSidebar(book: SidebarBook): Promise<void> {
    const snapshot = JSON.stringify(book);
    this.writing = this.writing.catch(() => {}).then(async () => {
      await this.store.put('sidebar', snapshot);
      await this.store.flush();
    });
    return this.writing;
  }

  async loadTranscriptCache(): Promise<TranscriptCacheBook> {
    const empty: TranscriptCacheBook = { version: 1, entries: [] };
    try {
      const stat = fileIo.statSync(this.cacheFile);
      if (stat.size <= 0 || stat.size > 512 * 1024) return empty;
      const file = fileIo.openSync(this.cacheFile, fileIo.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(stat.size);
        const read = fileIo.readSync(file.fd, buffer);
        const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer, 0, read));
        const parsed = JSON.parse(text) as TranscriptCacheBook;
        if (parsed && parsed.version === 1 && Array.isArray(parsed.entries)) return parsed;
      } finally {
        fileIo.closeSync(file);
      }
    } catch { /* missing or corrupted cache falls back cleanly */ }
    return empty;
  }

  saveTranscriptCache(book: TranscriptCacheBook): Promise<void> {
    const snapshot = JSON.stringify(book);
    this.cacheWriting = this.cacheWriting.catch(() => {}).then(() => {
      try {
        if (!book.entries.length) {
          try { fileIo.unlinkSync(this.cacheFile); } catch {}
          return;
        }
        if (snapshot.length > 512 * 1024) return;
        const file = fileIo.openSync(this.cacheFile, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
        try {
          fileIo.writeSync(file.fd, snapshot);
        } finally {
          fileIo.closeSync(file);
        }
      } catch { /* cache persistence is best-effort */ }
    });
    return this.cacheWriting;
  }
}
