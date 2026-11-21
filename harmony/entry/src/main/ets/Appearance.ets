import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface ThemeStyle {
  id: string;
  label: string;
  light: string;
  dark: string;
  lightTint: string;
  darkTint: string;
}

export interface AppearanceMode {
  id: string;
  label: string;
  colorMode: ConfigurationConstant.ColorMode;
}

export const THEME_STYLES: ThemeStyle[] = [
  { id: 'mint', label: '薄荷', light: '#166957', dark: '#9EE2CE', lightTint: '#DFF2EC', darkTint: '#2A3B3B' },
  { id: 'ocean', label: '海蓝', light: '#245D9B', dark: '#A5CAFF', lightTint: '#E3EEFC', darkTint: '#28394F' },
  { id: 'iris', label: '鸢紫', light: '#6845A0', dark: '#D0B8FD', lightTint: '#F0E8FC', darkTint: '#3C3150' },
  { id: 'amber', label: '琥珀', light: '#85520C', dark: '#F6C88A', lightTint: '#FAEDD9', darkTint: '#463827' },
  { id: 'graphite', label: '石墨', light: '#465361', dark: '#C6D0DB', lightTint: '#E7ECF1', darkTint: '#353D46' }
];

export const APPEARANCE_MODES: AppearanceMode[] = [
  { id: 'system', label: '跟随系统', colorMode: ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET },
  { id: 'light', label: '浅色', colorMode: ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT },
  { id: 'dark', label: '深色', colorMode: ConfigurationConstant.ColorMode.COLOR_MODE_DARK }
];

export function themeStyle(id: string): ThemeStyle {
  return THEME_STYLES.find((item: ThemeStyle): boolean => item.id === id) ?? THEME_STYLES[0];
}

export function appearanceMode(id: string): AppearanceMode {
  return APPEARANCE_MODES.find((item: AppearanceMode): boolean => item.id === id) ?? APPEARANCE_MODES[0];
}

export function openSettings(context: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: 'pigo_settings' });
}
