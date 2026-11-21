// 沉浸式材质自 API 26 起可用。其他设备使用常规背景模糊。
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

  constructor(dark: boolean) {
    this.dark = dark;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    const color = this.dark ? '#A01D2229' : '#EBFFFFFF';
    if (MATERIAL_LEVEL === undefined || MATERIAL_LEVEL === uiMaterial.MaterialLevel.SMOOTH) {
      instance.backdropBlur(20).backgroundColor(color);
      return;
    }
    if (!this.material) {
      this.material = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        materialColor: color,
        applyShadow: false
      });
    }
    instance.systemMaterial(this.material);
  }
}

const darkSurface = new ImmersiveSurface(true);
const lightSurface = new ImmersiveSurface(false);

export function immersiveSurface(dark: boolean): ImmersiveSurface {
  return dark ? darkSurface : lightSurface;
}
