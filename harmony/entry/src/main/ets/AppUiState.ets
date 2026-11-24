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

export function appUiState(): AppUiState {
  return AppStorageV2.connect(AppUiState, 'piGoUi', () => new AppUiState())!;
}
