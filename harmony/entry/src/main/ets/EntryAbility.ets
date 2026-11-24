import { AppUiState, appUiState } from './AppUiState';
import { UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { formInfo } from '@kit.FormKit';
import { appearanceMode, openSettings } from './Appearance';
import { liveActivity } from './LiveActivity';
import { IncomingShare, readIncomingShare, releaseIncomingShare } from './IncomingShare';

export default class EntryAbility extends UIAbility {
  private readonly appState: AppUiState = appUiState();
  private mainWindow?: window.Window;
  private shareGeneration: number = 0;

  onCreate(want: Want): void {
    try {
      const saved = openSettings(this.context).getSync('appearance_mode', 'system') as string;
      this.context.getApplicationContext().setColorMode(appearanceMode(saved).colorMode);
    } catch { /* The default is the system color mode. */ }
    this.updateColorMode(this.context.config);
    this.applyLaunch(want);
  }
  onNewWant(want: Want): void { this.applyLaunch(want); }
  onConfigurationUpdate(config: Configuration): void { this.updateColorMode(config); }

  private updateColorMode(config: Configuration): void {
    if (config.colorMode === undefined) return;
    const dark = config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.appState.darkMode = dark;
    const foreground = dark ? '#EDF2F4' : '#1D2933';
    void this.mainWindow?.setWindowSystemBarProperties({
      statusBarContentColor: foreground, navigationBarContentColor: foreground
    }).catch(() => {});
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index', () => {
      void stage.getMainWindow().then((mainWindow: window.Window) => {
        this.mainWindow = mainWindow;
        this.updateColorMode(this.context.config);
        return mainWindow.setWindowLayoutFullScreen(true).then(() => {
          this.trackAvoidAreas(mainWindow);
        });
      }).catch(() => { /* The page remains usable if system bars are unavailable. */ });
    });
  }
  onWindowStageDestroy(): void { this.mainWindow = undefined; }
  async onDestroy(): Promise<void> {
    this.shareGeneration += 1;
    releaseIncomingShare(this.appState.incomingShare);
    this.appState.incomingShare = { text: '', attachments: [], skipped: false };
    await liveActivity.dispose();
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
    update();
    mainWindow.on('windowSizeChange', () => { update(); });
    mainWindow.on('avoidAreaChange', () => { update(); });
    mainWindow.on('keyboardHeightChange', (height: number) => {
      this.appState.keyboardHeight = mainWindow.getUIContext().px2vp(height);
    });
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
