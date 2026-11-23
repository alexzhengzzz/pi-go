import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { formBindingData, formProvider } from '@kit.FormKit';

const FORM_KEY = 'form_';
const SUMMARY_KEY = 'summary';
const REFRESH_INTERVAL_MS = 5 * 60 * 1000;

export interface WidgetActionParams {
  destination: string;
  sessionId?: string;
  address?: string;
  pendingId?: string;
  eventId?: string;
}

export interface WidgetItem {
  id: string;
  sessionId: string;
  pendingId?: string;
  address: string;
  computer: string;
  title: string;
  subtitle: string;
  status: string;
  statusText: string;
  timeText: string;
  unread: boolean;
}

export interface WidgetSnapshot {
  dimension?: number;
  pending: number;
  unread: number;
  running: number;
  scheduleCount: number;
  syncedAt: number;
  paired: boolean;
  reachable: boolean;
  computer: string;
  workspace: string;
  currentSessionId: string;
  currentSessionTitle: string;
  nextScheduleName: string;
  nextScheduleTime: string;
  items: WidgetItem[];
  runningItems: WidgetItem[];
  scheduleItems: WidgetItem[];
}

interface WidgetBindingPayload {
  dimension: number;
  pending: string;
  unread: string;
  running: string;
  scheduleCount: string;
  syncedAt: string;
  paired: boolean;
  reachable: boolean;
  computer: string;
  workspace: string;
  currentSessionId: string;
  currentSessionTitle: string;
  nextScheduleName: string;
  nextScheduleTime: string;
  items: WidgetItem[];
  runningItems: WidgetItem[];
  scheduleItems: WidgetItem[];
}

export function emptyWidgetSnapshot(): WidgetSnapshot {
  return {
    pending: 0,
    unread: 0,
    running: 0,
    scheduleCount: 0,
    syncedAt: 0,
    paired: false,
    reachable: false,
    computer: '',
    workspace: '',
    currentSessionId: '',
    currentSessionTitle: '',
    nextScheduleName: '',
    nextScheduleTime: '',
    items: [],
    runningItems: [],
    scheduleItems: []
  };
}

function widgetStore(context: common.Context): preferences.Preferences | undefined {
  if (!preferences.isStorageTypeSupported(preferences.StorageType.GSKV)) return undefined;
  return preferences.getPreferencesSync(context, { name: 'pigo_inbox_widget', storageType: preferences.StorageType.GSKV });
}

function normalizeSnapshot(parsed?: Partial<WidgetSnapshot>): WidgetSnapshot {
  const base = emptyWidgetSnapshot();
  if (!parsed) return base;
  return {
    pending: Number(parsed.pending ?? 0),
    unread: Number(parsed.unread ?? 0),
    running: Number(parsed.running ?? 0),
    scheduleCount: Number(parsed.scheduleCount ?? 0),
    syncedAt: Number(parsed.syncedAt ?? 0),
    paired: Boolean(parsed.paired),
    reachable: Boolean(parsed.reachable),
    computer: typeof parsed.computer === 'string' ? parsed.computer : '',
    workspace: typeof parsed.workspace === 'string' ? parsed.workspace : '',
    currentSessionId: typeof parsed.currentSessionId === 'string' ? parsed.currentSessionId : '',
    currentSessionTitle: typeof parsed.currentSessionTitle === 'string' ? parsed.currentSessionTitle : '',
    nextScheduleName: typeof parsed.nextScheduleName === 'string' ? parsed.nextScheduleName : '',
    nextScheduleTime: typeof parsed.nextScheduleTime === 'string' ? parsed.nextScheduleTime : '',
    items: Array.isArray(parsed.items) ? parsed.items.slice(0, 6) : [],
    runningItems: Array.isArray(parsed.runningItems) ? parsed.runningItems.slice(0, 5) : [],
    scheduleItems: Array.isArray(parsed.scheduleItems) ? parsed.scheduleItems.slice(0, 5) : []
  };
}

function readSnapshot(store?: preferences.Preferences): WidgetSnapshot {
  const saved = store?.getSync(SUMMARY_KEY, '') as string | undefined;
  if (!saved) return emptyWidgetSnapshot();
  try {
    return normalizeSnapshot(JSON.parse(saved) as Partial<WidgetSnapshot>);
  } catch {
    return emptyWidgetSnapshot();
  }
}

function readFormDimension(store: preferences.Preferences | undefined, id: string): number {
  const raw = store?.getSync(FORM_KEY + id, 2);
  if (typeof raw === 'number' && raw >= 1 && raw <= 7) return raw;
  return 2;
}

function binding(snapshot: WidgetSnapshot, dimension: number = 2): formBindingData.FormBindingData {
  const payload: WidgetBindingPayload = {
    dimension: dimension,
    pending: String(snapshot.pending),
    unread: String(snapshot.unread),
    running: String(snapshot.running),
    scheduleCount: String(snapshot.scheduleCount),
    syncedAt: String(snapshot.syncedAt),
    paired: snapshot.paired,
    reachable: snapshot.reachable,
    computer: snapshot.computer,
    workspace: snapshot.workspace,
    currentSessionId: snapshot.currentSessionId,
    currentSessionTitle: snapshot.currentSessionTitle,
    nextScheduleName: snapshot.nextScheduleName,
    nextScheduleTime: snapshot.nextScheduleTime,
    items: snapshot.items,
    runningItems: snapshot.runningItems,
    scheduleItems: snapshot.scheduleItems
  };
  return formBindingData.createFormBindingData(payload);
}

function snapshotSignature(snapshot: WidgetSnapshot): string {
  const sig: WidgetSnapshot = {
    pending: snapshot.pending,
    unread: snapshot.unread,
    running: snapshot.running,
    scheduleCount: snapshot.scheduleCount,
    syncedAt: 0,
    paired: snapshot.paired,
    reachable: snapshot.reachable,
    computer: snapshot.computer,
    workspace: snapshot.workspace,
    currentSessionId: snapshot.currentSessionId,
    currentSessionTitle: snapshot.currentSessionTitle,
    nextScheduleName: snapshot.nextScheduleName,
    nextScheduleTime: snapshot.nextScheduleTime,
    items: snapshot.items,
    runningItems: snapshot.runningItems,
    scheduleItems: snapshot.scheduleItems
  };
  return JSON.stringify(sig);
}

export function inboxFormData(context: common.Context, id?: string, dimension?: number): formBindingData.FormBindingData {
  try {
    const store = widgetStore(context);
    const snapshot = readSnapshot(store);
    const resolvedDim = dimension ?? (id ? readFormDimension(store, id) : 2);
    return binding(snapshot, resolvedDim);
  } catch {
    return binding(emptyWidgetSnapshot(), dimension ?? 2);
  }
}

export function registerInboxForm(context: common.Context, id: string, active: boolean, dimension?: number): void {
  if (!/^\d+$/.test(id)) return;
  try {
    const store = widgetStore(context);
    if (active) {
      const existing = readFormDimension(store, id);
      store?.putSync(FORM_KEY + id, dimension ?? existing);
    } else {
      store?.deleteSync(FORM_KEY + id);
    }
  } catch { /* The system can still open the app from the card. */ }
}

export class InboxWidget {
  private publishing: boolean = false;
  private queued?: WidgetSnapshot;

  async publish(context: common.Context, input: WidgetSnapshot): Promise<void> {
    this.queued = normalizeSnapshot(input);
    if (this.publishing) return;
    this.publishing = true;
    try {
      const store = widgetStore(context);
      if (!store) return;
      while (this.queued) {
        const snapshot = this.queued;
        this.queued = undefined;
        const previous = readSnapshot(store);
        const syncStateChanged = !!snapshot.syncedAt !== !!previous.syncedAt;
        const contentChanged = snapshotSignature(snapshot) !== snapshotSignature(previous);
        if (!contentChanged && !syncStateChanged &&
            snapshot.syncedAt - previous.syncedAt < REFRESH_INTERVAL_MS) continue;
        store.putSync(SUMMARY_KEY, JSON.stringify(snapshot));
        const keys = Object.keys(store.getAllSync()).filter((key: string): boolean => key.startsWith(FORM_KEY));
        await Promise.all(keys.map((key: string): Promise<void> => {
          const formId = key.slice(FORM_KEY.length);
          const dim = readFormDimension(store, formId);
          return formProvider.updateForm(formId, binding(snapshot, dim)).catch((): void => {});
        }));
      }
    } catch { /* A widget update must leave the in-app inbox usable. */ }
    finally { this.publishing = false; }
  }
}
