import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { formBindingData, formProvider } from '@kit.FormKit';

const FORM_KEY = 'form_';
const SUMMARY_KEY = 'summary';
const REFRESH_INTERVAL_MS = 5 * 60 * 1000;

interface InboxSummary {
  pending: number;
  syncedAt: number;
}

function widgetStore(context: common.Context): preferences.Preferences | undefined {
  if (!preferences.isStorageTypeSupported(preferences.StorageType.GSKV)) return undefined;
  return preferences.getPreferencesSync(context, { name: 'pigo_inbox_widget', storageType: preferences.StorageType.GSKV });
}

function readSummary(store?: preferences.Preferences): InboxSummary {
  const saved = store?.getSync(SUMMARY_KEY, '') as string | undefined;
  return saved ? JSON.parse(saved) as InboxSummary : { pending: 0, syncedAt: 0 };
}

function binding(summary: InboxSummary): formBindingData.FormBindingData {
  return formBindingData.createFormBindingData({ pending: String(summary.pending), syncedAt: String(summary.syncedAt) });
}

export function inboxFormData(context: common.Context): formBindingData.FormBindingData {
  try {
    return binding(readSummary(widgetStore(context)));
  } catch {
    return binding(readSummary());
  }
}

export function registerInboxForm(context: common.Context, id: string, active: boolean): void {
  if (!/^\d+$/.test(id)) return;
  try {
    const store = widgetStore(context);
    if (active) store?.putSync(FORM_KEY + id, true);
    else store?.deleteSync(FORM_KEY + id);
  } catch { /* The system can still open the inbox from the card. */ }
}

export class InboxWidget {
  private publishing: boolean = false;
  private queued?: InboxSummary;

  async publish(context: common.Context, pending: number, syncedAt: number): Promise<void> {
    this.queued = { pending: pending, syncedAt: syncedAt };
    if (this.publishing) return;
    this.publishing = true;
    try {
      const store = widgetStore(context);
      if (!store) return;
      while (this.queued) {
        const summary = this.queued;
        this.queued = undefined;
        const previous = readSummary(store);
        const syncStateChanged = !!summary.syncedAt !== !!previous.syncedAt;
        if (summary.pending === previous.pending && !syncStateChanged &&
            summary.syncedAt - previous.syncedAt < REFRESH_INTERVAL_MS) continue;
        store.putSync(SUMMARY_KEY, JSON.stringify(summary));
        const ids = Object.keys(store.getAllSync()).filter((key: string): boolean => key.startsWith(FORM_KEY));
        await Promise.all(ids.map((key: string): Promise<void> =>
          formProvider.updateForm(key.slice(FORM_KEY.length), binding(summary)).catch((): void => {})));
      }
    } catch { /* A widget update must leave the in-app inbox usable. */ }
    finally { this.publishing = false; }
  }
}
