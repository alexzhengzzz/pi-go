// 沉浸式材质自 API 26 起可用；需挂在 Navigation 标题栏或 Tabs 悬浮栏作用域内才会激活硬件液态玻璃效果。
// 作用域之外的悬浮按钮或低算力/旧版本设备回退到通透磨砂玻璃与高亮描边。
import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';

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

function applyFrostedFallback(instance: CommonAttribute, dark: boolean, radius: number): void {
  instance
    .backdropBlur(24)
    .backgroundColor(dark ? '#9E222832' : '#CCFFFFFF')
    .border({ width: 1, radius: radius, color: dark ? '#45D8E8FA' : '#C8DDE5ED' })
    .shadow({ radius: 12, offsetY: 3, color: dark ? '#55000000' : '#18637587' });
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
      applyFrostedFallback(instance, this.dark, this.radius);
      return;
    }
    if (!this.material) {
      // 不叠加不透明 materialColor，保留系统原生液态玻璃折射、光学亮边与动态光感交互反馈。
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

class GlassSurface implements AttributeModifier<CommonAttribute> {
  private readonly dark: boolean;
  private readonly radius: number;

  constructor(dark: boolean, radius: number) {
    this.dark = dark;
    this.radius = radius;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    applyFrostedFallback(instance, this.dark, this.radius);
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

function sharedTabBarMaterial(): uiMaterial.ImmersiveMaterial {
  if (!tabBarMaterial) {
    tabBarMaterial = new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      applyShadow: true,
      interactive: true,
      lightEffect: {}
    });
  }
  return tabBarMaterial;
}

const darkHeaderSurface = new ImmersiveHeaderSurface(true, 22);
const lightHeaderSurface = new ImmersiveHeaderSurface(false, 22);
const darkGlassButton = new GlassSurface(true, 22);
const lightGlassButton = new GlassSurface(false, 22);

// 仅用于 Navigation 标题栏作用域内的按钮（系统原生液态玻璃）。
export function immersiveSurface(dark: boolean): ImmersiveHeaderSurface {
  return dark ? darkHeaderSurface : lightHeaderSurface;
}

// 用于非 Navigation 标题栏作用域的悬浮圆形按钮（如返回底部、独立覆盖层返回按钮）。
export function glassButtonSurface(dark: boolean): GlassSurface {
  return dark ? darkGlassButton : lightGlassButton;
}

// 用于根部 Tabs 悬浮胶囊底栏（API 26 原生 barFloatingStyle + ImmersiveMaterial）。
export function immersiveFloatingTabs(show: boolean, bottomMargin: number, dark: boolean): FloatingTabsSurface {
  return new FloatingTabsSurface(show, bottomMargin, dark);
}
