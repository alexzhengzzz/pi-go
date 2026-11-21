// 沉浸式材质自 API 26 起可用。旧设备保留组件设置的背景和边框。
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

class ImmersiveSurface implements AttributeModifier<CommonAttribute> {
  private material?: uiMaterial.Material;

  private readonly dark: boolean;
  private readonly glow: string;

  constructor(dark: boolean, glow: string) {
    this.dark = dark;
    this.glow = glow;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    if (MATERIAL_LEVEL === undefined) return;
    if (!this.material) {
      const solid = MATERIAL_LEVEL === uiMaterial.MaterialLevel.SMOOTH;
      const color = this.dark ? '#A0233036' : '#A8FFFFFF';
      this.material = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        materialColor: solid ? $r('app.color.pigo_panel') : color,
        applyShadow: false,
        lightEffect: !solid && this.glow ? { color: this.glow } : undefined
      });
    }
    instance.systemMaterial(this.material);
  }
}

const surfaces: Map<string, ImmersiveSurface> = new Map<string, ImmersiveSurface>();

export function immersiveSurface(dark: boolean, glow: string = ''): ImmersiveSurface {
  const key = `${dark}-${glow}`;
  let surface = surfaces.get(key);
  if (!surface) {
    surface = new ImmersiveSurface(dark, glow);
    surfaces.set(key, surface);
  }
  return surface;
}
