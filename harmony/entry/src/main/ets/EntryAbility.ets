import {
  AppUiState,
  ENTRY_INSTANCE_KEY_STORAGE,
  appUiState,
  registerWindowAppUiState,
  unregisterWindowAppUiState
} from './AppUiState';
import { UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { formInfo } from '@kit.FormKit';
import { appearanceMode, openSettings } from './Appearance';
import { liveActivity } from './LiveActivity';
import { IncomingShare, readIncomingShare, releaseIncomingShare } from './IncomingShare';
import { entryInstances } from './EntryInstanceRegistry';

export default class EntryAbility extends UIAbility {
  private readonly appState: AppUiState = new AppUiState();
  private instanceKey: string = '';
  private mainWindow?: window.Window;
  private shareGeneration: number = 0;
  private onWindowSizeChange?: () => void;
  private onAvoidAreaChange?: (info: window.AvoidAreaOptions) => void;
  private onKeyboardHeightChange?: (height: number) => void;
  private onWindowStatusChange?: (status: window.WindowStatusType) => void;

  onCreate(want: Want): void {
    this.instanceKey = entryInstances.claimKey();
    registerWindowAppUiState(this.instanceKey, this.appState);
    console.info(`[PiGoMulti] onCreate key=${this.instanceKey} count=${entryInstances.count()}`);
    try {
      const saved = openSettings(this.context).getSync('appearance_mode', 'system') as string;
      this.context.getApplicationContext().setColorMode(appearanceMode(saved).colorMode);
    } catch { /* The default is the system color mode. */ }
    this.updateColorMode(this.context.config);
    this.applyLaunch(want);
  }
  onNewWant(want: Want): void {
    console.info(`[PiGoMulti] onNewWant key=${this.instanceKey}`);
    entryInstances.touch(this.instanceKey);
    this.applyLaunch(want);
  }
  onForeground(): void {
    entryInstances.setForeground(this.instanceKey, true);
    console.info(`[PiGoMulti] onForeground key=${this.instanceKey}`);
  }
  onBackground(): void {
    entryInstances.setForeground(this.instanceKey, false);
    console.info(`[PiGoMulti] onBackground key=${this.instanceKey}`);
  }
  onConfigurationUpdate(config: Configuration): void { this.updateColorMode(config); }

  private updateColorMode(config: Configuration): void {
    if (config.colorMode === undefined) return;
    const dark = config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.appState.darkMode = dark;
    appUiState().darkMode = dark;
    const foreground = dark ? '#EDF2F4' : '#1D2933';
    void this.mainWindow?.setWindowSystemBarProperties({
      statusBarContentColor: foreground, navigationBarContentColor: foreground
    }).catch(() => {});
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    const storage = new LocalStorage();
    storage.setOrCreate(ENTRY_INSTANCE_KEY_STORAGE, this.instanceKey);
    try {
      const main = stage.getMainWindowSync();
      entryInstances.setWindowStatus(this.instanceKey, main.getWindowStatus());
    } catch { /* Window status will be synced once the main window is ready. */ }
    stage.loadContent('pages/Index', storage, () => {
      void stage.getMainWindow().then((mainWindow: window.Window) => {
        this.mainWindow = mainWindow;
        this.updateColorMode(this.context.config);
        this.trackWindowStatus(mainWindow);
        return mainWindow.setWindowLayoutFullScreen(true).then(() => {
          this.trackAvoidAreas(mainWindow);
        });
      }).catch(() => { /* The page remains usable if system bars are unavailable. */ });
    });
  }
  onWindowStageDestroy(): void {
    this.detachWindowListeners();
    this.mainWindow = undefined;
  }
  async onDestroy(): Promise<void> {
    this.detachWindowListeners();
    entryInstances.unregister(this.instanceKey);
    unregisterWindowAppUiState(this.instanceKey);
    console.info(`[PiGoMulti] onDestroy key=${this.instanceKey} remaining=${entryInstances.count()}`);
    this.shareGeneration += 1;
    releaseIncomingShare(this.appState.incomingShare);
    this.appState.incomingShare = { text: '', attachments: [], skipped: false };
    if (entryInstances.count() === 0) {
      await liveActivity.dispose();
    } else {
      liveActivity.detach(this.context);
    }
  }

  private trackWindowStatus(mainWindow: window.Window): void {
    try {
      entryInstances.setWindowStatus(this.instanceKey, mainWindow.getWindowStatus());
    } catch { /* Ignore when window status is unavailable. */ }
    const handleStatus = (status: window.WindowStatusType): void => {
      entryInstances.setWindowStatus(this.instanceKey, status);
      console.info(`[PiGoMulti] windowStatusChange key=${this.instanceKey} status=${status}`);
    };
    this.onWindowStatusChange = handleStatus;
    try {
      mainWindow.on('windowStatusChange', handleStatus);
    } catch { /* Ignore on devices that do not emit windowStatusChange. */ }
  }

  private detachWindowListeners(): void {
    const mainWindow = this.mainWindow;
    if (!mainWindow) return;
    try {
      if (this.onWindowSizeChange) mainWindow.off('windowSizeChange', this.onWindowSizeChange);
      if (this.onAvoidAreaChange) mainWindow.off('avoidAreaChange', this.onAvoidAreaChange);
      if (this.onKeyboardHeightChange) mainWindow.off('keyboardHeightChange', this.onKeyboardHeightChange);
      if (this.onWindowStatusChange) mainWindow.off('windowStatusChange', this.onWindowStatusChange);
    } catch { /* Ignore listener cleanup errors during teardown. */ }
    this.onWindowSizeChange = undefined;
    this.onAvoidAreaChange = undefined;
    this.onKeyboardHeightChange = undefined;
    this.onWindowStatusChange = undefined;
  }

  private trackAvoidAreas(mainWindow: window.Window): void {
    const update = (): void => {
      const ui = mainWindow.getUIContext();
      const system = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const cutout = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const left = Math.max(system.leftRect.width, indicator.leftRect.width, cutout.leftRect.width);
      const right = Math.max(system.rightRect.width, indicator.rightRect.width, cutout.rightRect.width);
      const rect = mainWindow.getWindowProperties().windowRect;
      this.appState.leftInset = ui.px2vp(left);
      this.appState.rightInset = ui.px2vp(right);
      this.appState.statusBarHeight = ui.px2vp(Math.max(system.topRect.height, cutout.topRect.height));
      this.appState.navBarHeight = ui.px2vp(Math.max(indicator.bottomRect.height, cutout.bottomRect.height));
      this.appState.windowWidth = ui.px2vp(Math.max(0, rect.width - left - right));
      this.appState.windowHeight = ui.px2vp(rect.height);
    };
    const handleAvoidArea = (info: window.AvoidAreaOptions): void => {
      if (info.type === window.AvoidAreaType.TYPE_KEYBOARD) return;
      update();
    };
    const handleKeyboard = (height: number): void => {
      const next = mainWindow.getUIContext().px2vp(height);
      if (Math.abs(this.appState.keyboardHeight - next) < 1) return;
      this.appState.keyboardHeight = next;
    };
    this.onWindowSizeChange = update;
    this.onAvoidAreaChange = handleAvoidArea;
    this.onKeyboardHeightChange = handleKeyboard;
    update();
    mainWindow.on('windowSizeChange', update);
    mainWindow.on('avoidAreaChange', handleAvoidArea);
    mainWindow.on('keyboardHeightChange', handleKeyboard);
  }

  private async receiveShare(want: Want): Promise<void> {
    const generation = ++this.shareGeneration;
    let share: IncomingShare;
    try {
      share = await readIncomingShare(want, this.context.abilityInfo.bundleName);
    } catch {
      share = { text: '', attachments: [], skipped: true };
    }
    if (generation !== this.shareGeneration) {
      releaseIncomingShare(share);
      return;
    }
    releaseIncomingShare(this.appState.incomingShare);
    this.appState.incomingShare = share;
  }

  private applyLaunch(want: Want): void {
    if (want.action === 'ohos.want.action.sendData') {
      void this.receiveShare(want);
      return;
    }
    if (want.parameters?.[formInfo.FormParam.IDENTITY_KEY] !== undefined) {
      const params = want.parameters?.['params'];
      if (typeof params === 'string') {
        try {
          const payload = JSON.parse(params) as Record<string, string>;
          const destination = typeof payload.destination === 'string' ? payload.destination : '';
          if (destination) {
            this.appState.formDestination = destination;
            this.appState.formSessionId = typeof payload.sessionId === 'string' &&
              /^[a-zA-Z0-9._-]{1,200}$/.test(payload.sessionId) ? payload.sessionId : '';
            this.appState.formAddress = typeof payload.address === 'string' &&
              payload.address.length <= 2048 ? payload.address : '';
            this.appState.formPendingId = typeof payload.pendingId === 'string' &&
              /^[a-zA-Z0-9._:-]{1,200}$/.test(payload.pendingId) ? payload.pendingId : '';
            this.appState.formEventId = typeof payload.eventId === 'string' &&
              /^[a-zA-Z0-9._:-]{1,200}$/.test(payload.eventId) ? payload.eventId : '';
            this.appState.inboxFormLaunch = true;
          }
        } catch { /* Ignore malformed card parameters. */ }
      }
    }
    const pushDevice = want.parameters?.['pigoPushDevice'];
    const pushEvent = want.parameters?.['pigoPushEvent'];
    const pushSession = want.parameters?.['pigoPushSession'];
    const pushPending = want.parameters?.['pigoPushPending'];
    if (typeof pushDevice === 'string' && /^[a-f0-9]{64}$/.test(pushDevice) &&
      typeof pushEvent === 'string' && /^[a-f0-9]{32,64}$/.test(pushEvent)) {
      this.appState.pushLaunchDevice = pushDevice;
      this.appState.pushLaunchSession = typeof pushSession === 'string' &&
        /^[a-zA-Z0-9._-]{1,200}$/.test(pushSession) ? pushSession : '';
      this.appState.pushLaunchPending = typeof pushPending === 'string' &&
        /^[a-zA-Z0-9._:-]{1,200}$/.test(pushPending) ? pushPending : '';
      this.appState.pushLaunchEvent = pushEvent;
    }
    const liveSession = want.parameters?.['pigoLiveSession'];
    const liveAddress = want.parameters?.['pigoLiveAddress'];
    if (typeof liveSession === 'string' && /^[a-zA-Z0-9._-]{1,200}$/.test(liveSession) &&
      typeof liveAddress === 'string' && liveAddress.length <= 2048) {
      this.appState.liveLaunchAddress = liveAddress;
      this.appState.liveLaunchSession = liveSession;
    }
    const address = want.parameters?.['address'];
    if (typeof address === 'string' && /^http:\/\/127\.0\.0\.1:\d{1,5}$/.test(address)) {
      this.appState.address = address;
    }
    // The pairing window on the computer hands the one-time ticket over USB
    // debugging, so the phone can pair without manual code entry.
    const ticket = want.parameters?.['ticket'];
    if (typeof ticket === 'string' && /^(\d{8}|[a-fA-F0-9]{64})$/.test(ticket)) {
      this.appState.launchTicket = ticket.toLowerCase();
    }
  }
}
