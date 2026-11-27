// 沉浸式材质与光感体系：
// 1. API 26 Navigation 标题栏、Tabs 悬浮胶囊、bindSheet 半模态使用系统原生 uiMaterial.ImmersiveMaterial（真液态玻璃折射）。
// 2. 作用域之外的悬浮输入框、侧边栏抽屉、设置页卡片与悬浮弹窗使用高通透背景模糊 + 光学亮边 + HDS 动态点光源（hdsEffect）。
// 3. 旧版本或低算力设备自动平滑降级，不影响布局与可读性。
import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { hdsEffect } from '@kit.UIDesignKit';
import { ThemeStyle, themePalette, themeStyle } from './Appearance';

function materialLevel(): uiMaterial.MaterialLevel | undefined {
  try {
    if (deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported()) {
      return uiMaterial.getGlobalMaterialLevel();
    }
  } catch {
    // 部分设备没有系统材质能力。
  }
  return undefined;
}

const MATERIAL_LEVEL = materialLevel();

export function hasImmersiveMaterial(): boolean {
  return MATERIAL_LEVEL !== undefined && MATERIAL_LEVEL !== uiMaterial.MaterialLevel.SMOOTH;
}

let cachedSoftLight: VisualEffect | undefined = undefined;
let cachedBrightLight: VisualEffect | undefined = undefined;
let pointLightChecked: boolean = false;

function initPointLights(): void {
  if (pointLightChecked) return;
  pointLightChecked = true;
  try {
    cachedSoftLight = new hdsEffect.HdsEffectBuilder()
      .pointLight({
        sourceType: hdsEffect.PointLightSourceType.SOFT,
        illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
      })
      .buildEffect();
    cachedBrightLight = new hdsEffect.HdsEffectBuilder()
      .pointLight({
        sourceType: hdsEffect.PointLightSourceType.BRIGHT,
        illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
      })
      .buildEffect();
  } catch {
    // 不支持 HDS 光感点光源的设备自动忽略。
    cachedSoftLight = undefined;
    cachedBrightLight = undefined;
  }
}

function applyPointLight(instance: CommonAttribute, bright: boolean): void {
  initPointLights();
  const effect = bright ? cachedBrightLight : cachedSoftLight;
  if (effect) instance.visualEffect(effect);
}

function applyFrostedButton(instance: CommonAttribute, dark: boolean, radius: number): void {
  instance
    .backdropBlur(28)
    .backgroundColor(dark ? '#9E222832' : '#CCFFFFFF')
    .border({ width: 1, radius: radius, color: dark ? '#48D8E8FA' : '#D4DDE5ED' })
    .shadow({ radius: 14, offsetY: 3, color: dark ? '#58000000' : '#1A637587' });
  applyPointLight(instance, true);
}

class ImmersiveHeaderSurface implements AttributeModifier<CommonAttribute> {
  private material?: uiMaterial.Material;
  private readonly dark: boolean;
  private readonly radius: number;

  constructor(dark: boolean, radius: number) {
    this.dark = dark;
    this.radius = radius;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    if (!hasImmersiveMaterial()) {
      applyFrostedButton(instance, this.dark, this.radius);
      return;
    }
    if (!this.material) {
      this.material = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        applyShadow: true,
        interactive: true,
        lightEffect: {}
      });
    }
    instance.systemMaterial(this.material);
  }
}

class GlassButtonSurface implements AttributeModifier<CommonAttribute> {
  private readonly dark: boolean;
  private readonly radius: number;

  constructor(dark: boolean, radius: number) {
    this.dark = dark;
    this.radius = radius;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    applyFrostedButton(instance, this.dark, this.radius);
  }
}

class GlassComposerSurface implements AttributeModifier<CommonAttribute> {
  private readonly dark: boolean;
  private readonly radius: number;

  constructor(dark: boolean, radius: number) {
    this.dark = dark;
    this.radius = radius;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backdropBlur(36)
      .backgroundColor(this.dark ? '#A61A2029' : '#D6FFFFFF')
      .borderRadius(this.radius)
      .border({ width: 1, radius: this.radius, color: this.dark ? '#44D8E8FA' : '#E0DDE5ED' })
      .shadow({ radius: 22, offsetY: 6, color: this.dark ? '#66000000' : '#1E637587' });
    applyPointLight(instance, false);
  }
}

class GlassDrawerSurface implements AttributeModifier<CommonAttribute> {
  private readonly dark: boolean;
  private readonly docked: boolean;

  constructor(dark: boolean, docked: boolean) {
    this.dark = dark;
    this.docked = docked;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backdropBlur(44)
      .backgroundColor(this.dark ? '#D413171E' : '#E4F2F4F8')
      .border({
        width: { right: 1 },
        color: this.dark ? (this.docked ? '#24FFFFFF' : '#32D8E8FA') : (this.docked ? '#D8DDE5ED' : '#E6FFFFFF')
      });
  }
}

class GlassCardSurface implements AttributeModifier<CommonAttribute> {
  private readonly dark: boolean;
  private readonly radius: number;
  private readonly elevated: boolean;

  constructor(dark: boolean, radius: number, elevated: boolean) {
    this.dark = dark;
    this.radius = radius;
    this.elevated = elevated;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backdropBlur(this.elevated ? 32 : 20)
      .backgroundColor(this.dark ? (this.elevated ? '#B81C222B' : '#CC1A1F26') : (this.elevated ? '#DCFFFFFF' : '#EBFFFFFF'))
      .borderRadius(this.radius)
      .border({
        width: 1,
        radius: this.radius,
        color: this.dark ? (this.elevated ? '#44D8E8FA' : '#28D8E8FA') : (this.elevated ? '#E6FFFFFF' : '#D6DDE5ED')
      })
      .shadow({
        radius: this.elevated ? 20 : 10,
        offsetY: this.elevated ? 6 : 2,
        color: this.dark ? (this.elevated ? '#66000000' : '#30000000') : (this.elevated ? '#1E637587' : '#0E637587')
      });
    applyPointLight(instance, false);
  }
}

class FloatingTabsSurface implements AttributeModifier<TabsAttribute> {
  private readonly show: boolean;
  private readonly bottomMargin: number;
  private readonly dark: boolean;

  constructor(show: boolean, bottomMargin: number, dark: boolean) {
    this.show = show;
    this.bottomMargin = bottomMargin;
    this.dark = dark;
  }

  applyNormalAttribute(instance: TabsAttribute): void {
    if (!hasImmersiveMaterial()) {
      instance
        .barBackgroundBlurStyle(this.show ? BlurStyle.COMPONENT_ULTRA_THIN : BlurStyle.NONE)
        .barBackgroundColor(this.show ? (this.dark ? '#B81D2229' : '#EBFFFFFF') : Color.Transparent);
      return;
    }
    if (!this.show) {
      instance.barFloatingStyle(undefined);
      return;
    }
    instance.barFloatingStyle({
      barSideMargin: 16,
      barBottomMargin: this.bottomMargin,
      maskColor: Color.Transparent,
      systemMaterial: sharedTabBarMaterial()
    });
  }
}

let tabBarMaterial: uiMaterial.ImmersiveMaterial | undefined = undefined;
let sheetMaterial: uiMaterial.ImmersiveMaterial | undefined = undefined;

function sharedTabBarMaterial(): uiMaterial.ImmersiveMaterial {
  if (!tabBarMaterial) {
    tabBarMaterial = new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      applyShadow: true,
      interactive: false,
      lightEffect: null
    });
  }
  return tabBarMaterial;
}

// 用于 bindSheet 半模态面板（API 26 原生液态玻璃半模态）。
export function immersiveSheetMaterial(): uiMaterial.Material | undefined {
  if (!hasImmersiveMaterial()) return undefined;
  if (!sheetMaterial) {
    sheetMaterial = new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      applyShadow: true
    });
  }
  return sheetMaterial;
}

const darkHeaderSurface = new ImmersiveHeaderSurface(true, 22);
const lightHeaderSurface = new ImmersiveHeaderSurface(false, 22);
const darkGlassButton = new GlassButtonSurface(true, 22);
const lightGlassButton = new GlassButtonSurface(false, 22);
const darkComposerSurface = new GlassComposerSurface(true, 22);
const lightComposerSurface = new GlassComposerSurface(false, 22);
const darkPaletteSurface = new GlassComposerSurface(true, 16);
const lightPaletteSurface = new GlassComposerSurface(false, 16);
const darkDrawerFloating = new GlassDrawerSurface(true, false);
const lightDrawerFloating = new GlassDrawerSurface(false, false);
const darkDrawerDocked = new GlassDrawerSurface(true, true);
const lightDrawerDocked = new GlassDrawerSurface(false, true);
const darkCard16 = new GlassCardSurface(true, 16, false);
const lightCard16 = new GlassCardSurface(false, 16, false);
const darkCard14 = new GlassCardSurface(true, 14, false);
const lightCard14 = new GlassCardSurface(false, 14, false);
const darkElevated16 = new GlassCardSurface(true, 16, true);
const lightElevated16 = new GlassCardSurface(false, 16, true);
const darkElevated20 = new GlassCardSurface(true, 20, true);
const lightElevated20 = new GlassCardSurface(false, 20, true);

// 仅用于 Navigation 标题栏作用域内的按钮（系统原生液态玻璃）。
export function immersiveSurface(dark: boolean): ImmersiveHeaderSurface {
  return dark ? darkHeaderSurface : lightHeaderSurface;
}

// 用于非 Navigation 标题栏作用域的悬浮圆形按钮（如返回底部、独立预览返回按钮）。
export function glassButtonSurface(dark: boolean): GlassButtonSurface {
  return dark ? darkGlassButton : lightGlassButton;
}

// 用于会话底部悬浮输入框胶囊与命令浮层。
export function glassComposerSurface(dark: boolean, palette: boolean = false): GlassComposerSurface {
  if (palette) return dark ? darkPaletteSurface : lightPaletteSurface;
  return dark ? darkComposerSurface : lightComposerSurface;
}

// 用于侧边栏抽屉/停靠栏毛玻璃底板。
export function glassDrawerSurface(dark: boolean, docked: boolean): GlassDrawerSurface {
  if (docked) return dark ? darkDrawerDocked : lightDrawerDocked;
  return dark ? darkDrawerFloating : lightDrawerFloating;
}

// 用于设置页/任务页/侧边栏光感卡片与悬浮横幅/弹窗。
export function glassCardSurface(dark: boolean, radius: number = 16, elevated: boolean = false): GlassCardSurface {
  if (elevated) {
    if (radius >= 20) return dark ? darkElevated20 : lightElevated20;
    return dark ? darkElevated16 : lightElevated16;
  }
  if (radius <= 14) return dark ? darkCard14 : lightCard14;
  return dark ? darkCard16 : lightCard16;
}

// 用于根部 Tabs 悬浮胶囊底栏（API 26 原生 barFloatingStyle + ImmersiveMaterial）。
export function immersiveFloatingTabs(show: boolean, bottomMargin: number, dark: boolean): FloatingTabsSurface {
  return new FloatingTabsSurface(show, bottomMargin, dark);
}

class ThemedCardSurface implements AttributeModifier<CommonAttribute> {
  private readonly dark: boolean;
  private readonly style: ThemeStyle;
  private readonly elevated: boolean;

  constructor(dark: boolean, style: ThemeStyle, elevated: boolean) {
    this.dark = dark;
    this.style = style;
    this.elevated = elevated;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    const palette = themePalette(this.style.id, this.dark);
    const radius = this.style.cardRadius;
    if (this.style.surface === 'paper') {
      instance
        .backgroundColor(palette.cardBg)
        .borderRadius(radius)
        .border({ width: 1, radius: radius, color: palette.cardBorder })
        .shadow({ radius: this.elevated ? 12 : 4, offsetY: this.elevated ? 4 : 1, color: palette.cardShadow });
      return;
    }
    if (this.style.surface === 'terminal') {
      instance
        .backdropBlur(this.elevated ? 20 : 12)
        .backgroundColor(palette.cardBg)
        .borderRadius(radius)
        .border({ width: 1, radius: radius, color: palette.cardBorder })
        .shadow({ radius: this.elevated ? 18 : 10, offsetY: 2, color: palette.cardShadow });
      return;
    }
    if (this.style.surface === 'soft') {
      instance
        .backdropBlur(this.elevated ? 28 : 18)
        .backgroundColor(palette.cardBg)
        .borderRadius(radius)
        .border({ width: 0.5, radius: radius, color: palette.cardBorder })
        .shadow({ radius: this.elevated ? 22 : 12, offsetY: this.elevated ? 6 : 3, color: palette.cardShadow });
      return;
    }
    instance
      .backdropBlur(this.elevated ? 32 : 22)
      .backgroundColor(palette.cardBg)
      .borderRadius(radius)
      .border({ width: 1, radius: radius, color: palette.cardBorder })
      .shadow({ radius: this.elevated ? 20 : 12, offsetY: this.elevated ? 6 : 2, color: palette.cardShadow });
    applyPointLight(instance, false);
  }
}

// 按主题风格（液态玻璃 / 纸墨哑光 / 极客终端 / 柔雾圆润）渲染卡片材质。
export function themedCardSurface(dark: boolean, themeId: string, elevated: boolean = false): ThemedCardSurface {
  return new ThemedCardSurface(dark, themeStyle(themeId), elevated);
}
