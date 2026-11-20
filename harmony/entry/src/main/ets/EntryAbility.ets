import { UIAbility, Want, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    this.applyLaunch(want);
  }
  onNewWant(want: Want): void { this.applyLaunch(want); }
  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index', () => {
      void stage.getMainWindow().then((mainWindow: window.Window) => {
        void mainWindow.setWindowSystemBarProperties({ statusBarContentColor: '#EEEEEE' });
        return mainWindow.setWindowLayoutFullScreen(true).then(() => {
          this.trackAvoidAreas(mainWindow);
        });
      }).catch(() => { /* The page remains usable if system bars are unavailable. */ });
    });
  }

  private trackAvoidAreas(mainWindow: window.Window): void {
    const update = (): void => {
      const ui = mainWindow.getUIContext();
      const top = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const bottom = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate<number>('pigoStatusBar', ui.px2vp(top.topRect.height));
      AppStorage.setOrCreate<number>('pigoNavBar', ui.px2vp(bottom.bottomRect.height));
    };
    update();
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
