import { UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { appearanceMode, openSettings } from './Appearance';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;

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
    AppStorage.setOrCreate<boolean>('pigoDark', dark);
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

  private trackAvoidAreas(mainWindow: window.Window): void {
    const update = (): void => {
      const ui = mainWindow.getUIContext();
      const system = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const cutout = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const left = Math.max(system.leftRect.width, indicator.leftRect.width, cutout.leftRect.width);
      const right = Math.max(system.rightRect.width, indicator.rightRect.width, cutout.rightRect.width);
      const rect = mainWindow.getWindowProperties().windowRect;
      AppStorage.setOrCreate<number>('pigoLeftInset', ui.px2vp(left));
      AppStorage.setOrCreate<number>('pigoRightInset', ui.px2vp(right));
      AppStorage.setOrCreate<number>('pigoStatusBar', ui.px2vp(Math.max(system.topRect.height, cutout.topRect.height)));
      AppStorage.setOrCreate<number>('pigoNavBar', ui.px2vp(Math.max(indicator.bottomRect.height, cutout.bottomRect.height)));
      AppStorage.setOrCreate<number>('pigoWindowWidth', ui.px2vp(Math.max(0, rect.width - left - right)));
      AppStorage.setOrCreate<number>('pigoWindowHeight', ui.px2vp(rect.height));
    };
    update();
    mainWindow.on('windowSizeChange', () => { update(); });
    mainWindow.on('avoidAreaChange', () => { update(); });
    mainWindow.on('keyboardHeightChange', (height: number) => {
      AppStorage.setOrCreate<number>('pigoKeyboard', mainWindow.getUIContext().px2vp(height));
    });
  }

  private applyLaunch(want: Want): void {
    const address = want.parameters?.['address'];
    if (typeof address === 'string' && /^http:\/\/127\.0\.0\.1:\d{1,5}$/.test(address)) {
      AppStorage.setOrCreate<string>('pigoAddress', address);
    }
    // The pairing window on the computer hands the one-time ticket over USB
    // debugging, so the phone can pair without manual code entry.
    const ticket = want.parameters?.['ticket'];
    if (typeof ticket === 'string' && /^(\d{8}|[a-fA-F0-9]{64})$/.test(ticket)) {
      AppStorage.setOrCreate<string>('pigoTicket', ticket.toLowerCase());
    }
  }
}
