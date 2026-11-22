import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface ThemeStyle {
  id: string;
  label: string;
  subtitle: string;
  light: string;
  dark: string;
  lightTint: string;
  darkTint: string;
  lightCanvas: string;
  darkCanvas: string;
}

export interface AppearanceMode {
  id: string;
  label: string;
  colorMode: ConfigurationConstant.ColorMode;
}

export const THEME_STYLES: ThemeStyle[] = [
  {
    id: 'mint', label: '薄荷', subtitle: '清新松绿',
    light: '#166957', dark: '#9EE2CE', lightTint: '#DFF2EC', darkTint: '#223A36',
    lightCanvas: '#F4F9F7', darkCanvas: '#101716'
  },
  {
    id: 'forest', label: '青黛', subtitle: '沉静松林',
    light: '#1F6E43', dark: '#8CE0AC', lightTint: '#E0F4E8', darkTint: '#1F382A',
    lightCanvas: '#F4F9F5', darkCanvas: '#101713'
  },
  {
    id: 'cyan', label: '冰川', subtitle: '澄澈湖青',
    light: '#0E6B78', dark: '#8CDCE8', lightTint: '#DEF3F6', darkTint: '#1E373C',
    lightCanvas: '#F3F9FA', darkCanvas: '#101618'
  },
  {
    id: 'ocean', label: '海蓝', subtitle: '晴空深海',
    light: '#245D9B', dark: '#A5CAFF', lightTint: '#E3EEFC', darkTint: '#22354D',
    lightCanvas: '#F4F7FC', darkCanvas: '#10151C'
  },
  {
    id: 'indigo', label: '靛蓝', subtitle: '午夜星河',
    light: '#3F4FA8', dark: '#B3BFFF', lightTint: '#E8ECFC', darkTint: '#282F52',
    lightCanvas: '#F5F6FC', darkCanvas: '#11131C'
  },
  {
    id: 'iris', label: '鸢紫', subtitle: '暮色丁香',
    light: '#6845A0', dark: '#D0B8FD', lightTint: '#F0E8FC', darkTint: '#362A4C',
    lightCanvas: '#F8F5FC', darkCanvas: '#15121B'
  },
  {
    id: 'plum', label: '梅韵', subtitle: '醇厚浆果',
    light: '#94326E', dark: '#F2A7D4', lightTint: '#FAE6F2', darkTint: '#452439',
    lightCanvas: '#FCF5F9', darkCanvas: '#191217'
  },
  {
    id: 'sakura', label: '樱粉', subtitle: '柔雾落樱',
    light: '#B33A5B', dark: '#FFA8BE', lightTint: '#FCE8EE', darkTint: '#472630',
    lightCanvas: '#FDF6F8', darkCanvas: '#1A1215'
  },
  {
    id: 'crimson', label: '绯红', subtitle: '朱砂丹霞',
    light: '#B5382E', dark: '#FFA69E', lightTint: '#FCEAE8', darkTint: '#482522',
    lightCanvas: '#FDF6F5', darkCanvas: '#1B1312'
  },
  {
    id: 'sunset', label: '落日', subtitle: '暖橘赤陶',
    light: '#AD4B1F', dark: '#FFB692', lightTint: '#FDECE4', darkTint: '#462B1E',
    lightCanvas: '#FDF7F3', darkCanvas: '#1A1411'
  },
  {
    id: 'amber', label: '琥珀', subtitle: '暖金秋叶',
    light: '#85520C', dark: '#F6C88A', lightTint: '#FAEDD9', darkTint: '#423320',
    lightCanvas: '#FBF8F2', darkCanvas: '#191510'
  },
  {
    id: 'graphite', label: '石墨', subtitle: '极简中性',
    light: '#465361', dark: '#C6D0DB', lightTint: '#E7ECF1', darkTint: '#303842',
    lightCanvas: '#F8F9FB', darkCanvas: '#121519'
  }
];

export const APPEARANCE_MODES: AppearanceMode[] = [
  { id: 'system', label: '跟随系统', colorMode: ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET },
  { id: 'light', label: '浅色', colorMode: ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT },
  { id: 'dark', label: '深色', colorMode: ConfigurationConstant.ColorMode.COLOR_MODE_DARK }
];

export function themeStyle(id: string): ThemeStyle {
  return THEME_STYLES.find((item: ThemeStyle): boolean => item.id === id) ?? THEME_STYLES[0];
}

export function themeCanvasColor(style: ThemeStyle, darkMode: boolean): string {
  return darkMode ? style.darkCanvas : style.lightCanvas;
}

export function canvasFadeStops(canvasHex: string): [ResourceColor, number][] {
  const rgb = canvasHex.startsWith('#') ? canvasHex.slice(1) : canvasHex;
  return [
    [`#FA${rgb}`, 0],
    [`#D9${rgb}`, 0.55],
    [`#44${rgb}`, 0.85],
    [`#00${rgb}`, 1]
  ];
}

export function appearanceMode(id: string): AppearanceMode {
  return APPEARANCE_MODES.find((item: AppearanceMode): boolean => item.id === id) ?? APPEARANCE_MODES[0];
}

export function openSettings(context: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: 'pigo_settings' });
}
