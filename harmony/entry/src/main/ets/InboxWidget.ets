import { runStatus } from './RunResults';
import type { InboxRun } from './RunResults';
import { scheduleTime, scheduleRunStatus } from './ScheduledRuns';
import type { RunMessage, ScheduleJob } from './ScheduledRuns';
import type { RunningRow } from './model/PiGoTypes';
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

export interface WidgetOverview {
  inbox: InboxRun[];
  scheduleMessages: RunMessage[];
  jobs: ScheduleJob[];
  runningRows: RunningRow[];
  activeSchedules: RunMessage[];
  running: number;
  syncedAt: number;
  paired: boolean;
  reachable: boolean;
  address: string;
  computer: string;
  pairedComputer: string;
  workspace: string;
  currentSessionId: string;
  currentSessionTitle: string;
  sessionState: (id: string) => string;
  stateLabel: (state: string) => string;
  workspaceName: (cwd: string) => string;
}

export function buildWidgetSnapshot(overview: WidgetOverview): WidgetSnapshot {
  const displayedInbox = overview.inbox;
  const pendingSet = new Set<string>();
  const unreadSet = new Set<string>();
  for (const row of displayedInbox) {
    if (row.run.status === 'waiting') pendingSet.add(row.run.id);
    if (row.unread) unreadSet.add(row.run.id);
  }
  for (const msg of overview.scheduleMessages) {
    if (!msg.dismissed && msg.unread) unreadSet.add(msg.key);
  }

  const runningItems: WidgetItem[] = overview.runningRows.slice(0, 4).map((row: RunningRow): WidgetItem => {
    const state = row.state ?? overview.sessionState(row.id);
    return {
      id: row.id,
      sessionId: row.id,
      address: overview.address,
      computer: overview.computer,
      title: row.name || '后台任务',
      subtitle: row.cwd ? overview.workspaceName(row.cwd) : overview.computer,
      status: state || 'streaming',
      statusText: overview.stateLabel(state || 'streaming'),
      timeText: '进行中',
      unread: state === 'waiting'
    };
  }).concat(overview.activeSchedules.slice(0, 2).map((row: RunMessage): WidgetItem => ({
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

  const scheduleItems: WidgetItem[] = overview.scheduleMessages
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

  const nextJob = overview.jobs.find((job: ScheduleJob): boolean => job.enabled && job.nextAt !== null);
  return {
    pending: pendingSet.size,
    unread: unreadSet.size,
    running: overview.running,
    scheduleCount: overview.jobs.filter((job: ScheduleJob): boolean => job.enabled).length,
    syncedAt: overview.syncedAt,
    paired: overview.paired,
    reachable: overview.reachable,
    computer: overview.pairedComputer,
    workspace: overview.workspace,
    currentSessionId: overview.currentSessionId,
    currentSessionTitle: overview.currentSessionTitle,
    nextScheduleName: nextJob?.name ?? '',
    nextScheduleTime: nextJob?.nextAt ? scheduleTime(nextJob.nextAt).slice(5) : '',
    items: combinedItems,
    runningItems: runningItems,
    scheduleItems: scheduleItems
  };
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
