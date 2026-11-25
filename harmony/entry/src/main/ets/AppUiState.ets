import { AppStorageV2 } from '@kit.ArkUI';
import { IncomingShare } from './IncomingShare';

@ObservedV2
export class AppUiState {
  @Trace darkMode: boolean = false;
  @Trace address: string = 'http://127.0.0.1:18977';
  @Trace launchTicket: string = '';
  @Trace liveLaunchSession: string = '';
  @Trace liveLaunchAddress: string = '';
  @Trace pushLaunchEvent: string = '';
  @Trace pushLaunchDevice: string = '';
  @Trace pushLaunchSession: string = '';
  @Trace pushLaunchPending: string = '';
  @Trace incomingShare: IncomingShare = { text: '', attachments: [], skipped: false };
  @Trace inboxFormLaunch: boolean = false;
  @Trace formDestination: string = '';
  @Trace formSessionId: string = '';
  @Trace formAddress: string = '';
  @Trace formPendingId: string = '';
  @Trace formEventId: string = '';
  @Trace statusBarHeight: number = 38;
  @Trace navBarHeight: number = 28;
  @Trace leftInset: number = 0;
  @Trace rightInset: number = 0;
  @Trace windowWidth: number = 0;
  @Trace windowHeight: number = 800;
  @Trace keyboardHeight: number = 0;
}

export const ENTRY_INSTANCE_KEY_STORAGE: string = 'piGoEntryInstanceKey';
const windowStates: Map<string, AppUiState> = new Map();

export function appUiState(): AppUiState {
  return AppStorageV2.connect(AppUiState, 'piGoUi', () => new AppUiState())!;
}

export function registerWindowAppUiState(instanceKey: string, state: AppUiState): void {
  windowStates.set(instanceKey, state);
}

export function unregisterWindowAppUiState(instanceKey: string): void {
  windowStates.delete(instanceKey);
}

export function windowAppUiState(): AppUiState {
  try {
    const shared = LocalStorage.getShared();
    const key = shared?.get<string>(ENTRY_INSTANCE_KEY_STORAGE);
    if (key) {
      const state = windowStates.get(key);
      if (state) return state;
    }
  } catch { /* Fall back to the shared store outside a LocalStorage-backed window. */ }
  return appUiState();
}
