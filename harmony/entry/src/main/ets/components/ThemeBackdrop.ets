import { unboundAction } from './ComponentAction';
import { ThemePalette, themePalette } from '../Appearance';
import { ArtThemeScene } from './ArtThemeScene';
import { InkScene } from './InkScene';
import { SakuraScene } from './SakuraPetals';
import { SunsetScene } from './SunsetScene';

@ComponentV2
export struct ThemeBackdrop {
  @Param @Require themeId: string;
  @Param @Require darkMode: boolean;
  @Param @Require dimmed: boolean;
  @Param @Require visible: boolean;
  @Param @Require motionEnabled: boolean;
  @Param @Require windowHeight: number;
  @Param @Require girlTapSeq: number;
  @Param @Require celebrateSeq: number;
  @Param @Require burstSeq: number;
  @Param @Require burstKind: string;
  @Param @Require bloomSeq: number;
  @Param @Require bloomX: number;
  @Param @Require bloomY: number;

  private palette(): ThemePalette {
    return themePalette(this.themeId, this.darkMode);
  }

  private staticThemeWallpaper(): Resource {
    if (this.themeId === 'graphite') return $rawfile(this.darkMode ? 'ink_dark.jpg' : 'ink_light.jpg');
    if (this.themeId === 'sunset') return $rawfile(this.darkMode ? 'sunset_dark.jpg' : 'sunset_light.jpg');
    if (this.themeId === 'bookstore') return $rawfile(this.darkMode ? 'bookstore_dark.jpg' : 'bookstore_light.jpg');
    if (this.themeId === 'jellyfish') return $rawfile(this.darkMode ? 'jellyfish_dark.jpg' : 'jellyfish_light.jpg');
    if (this.themeId === 'sahara') return $rawfile(this.darkMode ? 'sahara_dark.jpg' : 'sahara_light.jpg');
    return $rawfile(this.darkMode ? 'sakura_dark.jpg' : 'sakura_light.jpg');
  }

  private themeVeilStops(): [ResourceColor, number][] {
    const raw = this.palette().canvas;
    const rgb = raw.startsWith('#') ? raw.slice(1) : raw;
    if (this.darkMode) {
      return [[`#B8${rgb}`, 0], [`#8A${rgb}`, 0.62], [`#24${rgb}`, 1]];
    }
    return [[`#C4${rgb}`, 0], [`#96${rgb}`, 0.62], [`#26${rgb}`, 1]];
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .radialGradient({
          center: ['16%', '10%'],
          radius: '78%',
          colors: [[this.palette().auraTop, 0], ['#00000000', 1]]
        })
      Column()
        .width('100%').height('100%')
        .radialGradient({
          center: ['86%', '86%'],
          radius: '74%',
          colors: [[this.palette().auraBottom, 0], ['#00000000', 1]]
        })
      if (!this.motionEnabled) {
        Image(this.staticThemeWallpaper())
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.dimmed
            ? (this.darkMode ? 0.56 : 0.60)
            : (this.darkMode ? 0.90 : 0.94))
        if (this.dimmed) {
          Column()
            .width('100%').height('100%')
            .linearGradient({ angle: 90, colors: this.themeVeilStops() })
        }
      } else if (this.themeId === 'sakura') {
        SakuraScene({
          darkMode: this.darkMode,
          dimmed: this.dimmed,
          active: this.visible,
          girlTapSeq: this.girlTapSeq,
          celebrateSeq: this.celebrateSeq,
          burstSeq: this.burstSeq,
          burstKind: this.burstKind,
          bloomSeq: this.bloomSeq,
          bloomX: this.bloomX,
          bloomY: this.bloomY,
          sceneOpacity: this.dimmed
            ? (this.darkMode ? 0.56 : 0.60)
            : (this.darkMode ? 0.88 : 0.92)
        })
        if (this.dimmed) {
          Column()
            .width('100%').height('100%')
            .linearGradient({ angle: 90, colors: this.themeVeilStops() })
        }
      } else if (this.themeId === 'graphite') {
        InkScene({
          darkMode: this.darkMode,
          dimmed: this.dimmed,
          active: this.visible,
          burstSeq: this.burstSeq,
          burstKind: this.burstKind,
          tapSeq: this.bloomSeq,
          tapX: this.bloomX,
          tapY: this.bloomY,
          sceneOpacity: this.dimmed
            ? (this.darkMode ? 0.56 : 0.60)
            : (this.darkMode ? 0.90 : 0.94)
        })
        if (this.dimmed) {
          Column()
            .width('100%').height('100%')
            .linearGradient({ angle: 90, colors: this.themeVeilStops() })
        }
      } else if (this.themeId === 'sunset') {
        SunsetScene({
          darkMode: this.darkMode,
          dimmed: this.dimmed,
          active: this.visible,
          burstSeq: this.burstSeq,
          burstKind: this.burstKind,
          tapSeq: this.bloomSeq,
          tapX: this.bloomX,
          tapY: this.bloomY,
          sceneOpacity: this.dimmed
            ? (this.darkMode ? 0.56 : 0.60)
            : (this.darkMode ? 0.90 : 0.94)
        })
        if (this.dimmed) {
          Column()
            .width('100%').height('100%')
            .linearGradient({ angle: 90, colors: this.themeVeilStops() })
        }
      } else {
        ArtThemeScene({
          themeId: this.themeId,
          darkMode: this.darkMode,
          dimmed: this.dimmed,
          active: this.visible,
          burstSeq: this.burstSeq,
          burstKind: this.burstKind,
          tapSeq: this.bloomSeq,
          tapX: this.bloomX,
          tapY: this.bloomY,
          sceneOpacity: this.dimmed
            ? (this.darkMode ? 0.56 : 0.60)
            : (this.darkMode ? 0.90 : 0.94)
        })
        if (this.dimmed) {
          Column()
            .width('100%').height('100%')
            .linearGradient({ angle: 90, colors: this.themeVeilStops() })
        }
      }
    }.width('100%').height(this.windowHeight).position({ x: 0, y: 0 }).hitTestBehavior(HitTestMode.None)
  }
}

@ComponentV2
export struct SakuraGirlHitZone {
  @Param @Require bottomInset: number;
  @Event tap: () => void = unboundAction;

  build() {
    Blank()
      .width(175)
      .height(210)
      .margin({ right: 6, bottom: this.bottomInset })
      .onClick(() => { this.tap(); })
  }
}
