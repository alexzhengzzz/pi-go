import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export type ThemeSurfaceStyle = 'glass' | 'paper' | 'terminal' | 'soft';
export type ThemeBubbleStyle = 'tinted' | 'gradient' | 'outline';

export interface ThemePalette {
  accent: string;
  accentForeground: string;
  accentTint: string;
  canvas: string;
  auraTop: string;
  auraBottom: string;
  bubbleStart: string;
  bubbleEnd: string;
  bubbleBorder: string;
  codeBg: string;
  codeBorder: string;
  codeHeaderBg: string;
  cardBg: string;
  cardBorder: string;
  cardShadow: string;
}

export interface ThemeStyle {
  id: string;
  label: string;
  subtitle: string;
  styleTag: string;
  surface: ThemeSurfaceStyle;
  bubble: ThemeBubbleStyle;
  bubbleRadius: number;
  cardRadius: number;
  codeRadius: number;
  light: ThemePalette;
  dark: ThemePalette;
}

export interface AppearanceMode {
  id: string;
  label: string;
  colorMode: ConfigurationConstant.ColorMode;
}

export const THEME_STYLES: ThemeStyle[] = [
  {
    id: 'sakura',
    label: '落樱粉雪',
    subtitle: '樱瓣飘落 · 粉嫩甜软',
    styleTag: '樱花',
    surface: 'soft',
    bubble: 'gradient',
    bubbleRadius: 24,
    cardRadius: 22,
    codeRadius: 16,
    light: {
      accent: '#D84B84', accentForeground: '#FFFFFF', accentTint: '#FFE3EE',
      canvas: '#FFF6F9', auraTop: '#6EFFB7D5', auraBottom: '#5EFFD8E8',
      bubbleStart: '#FFDCEB', bubbleEnd: '#FFF0F6', bubbleBorder: '#FFAEC9',
      codeBg: '#FFF9FB', codeBorder: '#FAD0E0', codeHeaderBg: '#FFEBF3',
      cardBg: '#F4FFFBFD', cardBorder: '#FCD4E4', cardShadow: '#24EC689E'
    },
    dark: {
      accent: '#FFA8C8', accentForeground: '#26101B', accentTint: '#472335',
      canvas: '#1C1217', auraTop: '#52D95B8E', auraBottom: '#40C4749C',
      bubbleStart: '#4F253A', bubbleEnd: '#412138', bubbleBorder: '#944A6E',
      codeBg: '#251820', codeBorder: '#4F2E40', codeHeaderBg: '#321F2A',
      cardBg: '#E6261821', cardBorder: '#63374E', cardShadow: '#44000000'
    }
  },
  {
    id: 'sunset',
    label: '落日橘海',
    subtitle: '加州海岸 · 夕阳碎波',
    styleTag: '霞光',
    surface: 'glass',
    bubble: 'gradient',
    bubbleRadius: 20,
    cardRadius: 18,
    codeRadius: 14,
    light: {
      accent: '#B2461C', accentForeground: '#FFFFFF', accentTint: '#FDE7DA',
      canvas: '#FDF6F2', auraTop: '#48FFB88C', auraBottom: '#3CFF9EB5',
      bubbleStart: '#FDE6D8', bubbleEnd: '#FCE1E6', bubbleBorder: '#F5CBB6',
      codeBg: '#FFFDFB', codeBorder: '#EEDAD0', codeHeaderBg: '#FAF0E8',
      cardBg: '#EBFFFDFB', cardBorder: '#EED9CE', cardShadow: '#146E361E'
    },
    dark: {
      accent: '#FFB28A', accentForeground: '#15191C', accentTint: '#47281C',
      canvas: '#1A1210', auraTop: '#3A8C3D1F', auraBottom: '#30782442',
      bubbleStart: '#47271B', bubbleEnd: '#45222E', bubbleBorder: '#703D2B',
      codeBg: '#231917', codeBorder: '#3D2B26', codeHeaderBg: '#2C1F1C',
      cardBg: '#CC231917', cardBorder: '#57362C', cardShadow: '#48000000'
    }
  },
  {
    id: 'graphite',
    label: '水墨石墨',
    subtitle: '宣纸山水 · 苍松孤舟',
    styleTag: '国风',
    surface: 'paper',
    bubble: 'gradient',
    bubbleRadius: 16,
    cardRadius: 14,
    codeRadius: 10,
    light: {
      accent: '#34424E', accentForeground: '#FFFFFF', accentTint: '#E5E9EC',
      canvas: '#F6F5F0', auraTop: '#2AC2C6C2', auraBottom: '#26B6BFC7',
      bubbleStart: '#E8ECEE', bubbleEnd: '#F2F1EA', bubbleBorder: '#CDD4D9',
      codeBg: '#FAF9F4', codeBorder: '#DCDCD4', codeHeaderBg: '#EFEFE8',
      cardBg: '#F2FAF9F5', cardBorder: '#D8D9D2', cardShadow: '#122B353E'
    },
    dark: {
      accent: '#CFD8E2', accentForeground: '#121519', accentTint: '#262E37',
      canvas: '#111317', auraTop: '#283F4C5B', auraBottom: '#222F3A47',
      bubbleStart: '#262E38', bubbleEnd: '#1E252D', bubbleBorder: '#424E5C',
      codeBg: '#171B21', codeBorder: '#2C343F', codeHeaderBg: '#1E242C',
      cardBg: '#E6181C22', cardBorder: '#343E4A', cardShadow: '#3A000000'
    }
  },
  {
    id: 'bookstore',
    label: '左岸书店',
    subtitle: '复古暖灯 · 羊皮纸墨',
    styleTag: '书房',
    surface: 'paper',
    bubble: 'tinted',
    bubbleRadius: 14,
    cardRadius: 14,
    codeRadius: 10,
    light: {
      accent: '#8A5016', accentForeground: '#FFFFFF', accentTint: '#F5E7CE',
      canvas: '#FAF6EE', auraTop: '#40F0CE96', auraBottom: '#36DFB47A',
      bubbleStart: '#F3E7D2', bubbleEnd: '#F8EFE0', bubbleBorder: '#DFC7A0',
      codeBg: '#FDFBF6', codeBorder: '#E5D8C3', codeHeaderBg: '#F4ECDD',
      cardBg: '#F2FCF9F2', cardBorder: '#E2D4BC', cardShadow: '#164A3012'
    },
    dark: {
      accent: '#F2C483', accentForeground: '#1D150D', accentTint: '#3A2B1C',
      canvas: '#171310', auraTop: '#366E4B26', auraBottom: '#2C52371B',
      bubbleStart: '#382A1D', bubbleEnd: '#2B2016', bubbleBorder: '#694F35',
      codeBg: '#1F1914', codeBorder: '#3C3025', codeHeaderBg: '#28201A',
      cardBg: '#E6201A15', cardBorder: '#47382B', cardShadow: '#44000000'
    }
  },
  {
    id: 'jellyfish',
    label: '深海水母',
    subtitle: '荧光水母 · 蔚蓝浮泡',
    styleTag: '深海',
    surface: 'glass',
    bubble: 'gradient',
    bubbleRadius: 22,
    cardRadius: 20,
    codeRadius: 14,
    light: {
      accent: '#0E6888', accentForeground: '#FFFFFF', accentTint: '#D8EFF9',
      canvas: '#F1F8FC', auraTop: '#469BE2FA', auraBottom: '#3CB2D6FF',
      bubbleStart: '#D8F0FA', bubbleEnd: '#E7F3FD', bubbleBorder: '#A9D9EE',
      codeBg: '#F8FCFF', codeBorder: '#CEE5F2', codeHeaderBg: '#E8F4FA',
      cardBg: '#EBF8FCFF', cardBorder: '#CBE3F1', cardShadow: '#160E5270'
    },
    dark: {
      accent: '#82E1F7', accentForeground: '#081622', accentTint: '#163148',
      canvas: '#0A1220', auraTop: '#381B5A7E', auraBottom: '#3029437A',
      bubbleStart: '#16334A', bubbleEnd: '#1C294A', bubbleBorder: '#346689',
      codeBg: '#101B2D', codeBorder: '#243A57', codeHeaderBg: '#16243A',
      cardBg: '#CC101B2E', cardBorder: '#2B4666', cardShadow: '#4A000000'
    }
  },
  {
    id: 'sahara',
    label: '撒哈拉篝火',
    subtitle: '沙丘星夜 · 暖火微光',
    styleTag: '星夜',
    surface: 'paper',
    bubble: 'gradient',
    bubbleRadius: 18,
    cardRadius: 16,
    codeRadius: 12,
    light: {
      accent: '#A8491C', accentForeground: '#FFFFFF', accentTint: '#FBE5D4',
      canvas: '#FBF5EC', auraTop: '#44F6C798', auraBottom: '#38E8B088',
      bubbleStart: '#FAE3D0', bubbleEnd: '#F7ECD9', bubbleBorder: '#EBC2A2',
      codeBg: '#FEFAF4', codeBorder: '#EAD8C4', codeHeaderBg: '#F6EADF',
      cardBg: '#F0FDF9F2', cardBorder: '#E6D4C0', cardShadow: '#165E2C12'
    },
    dark: {
      accent: '#FFB584', accentForeground: '#1F120A', accentTint: '#3E251A',
      canvas: '#121118', auraTop: '#364A325C', auraBottom: '#346E361E',
      bubbleStart: '#3D261C', bubbleEnd: '#2A2233', bubbleBorder: '#734632',
      codeBg: '#1A1822', codeBorder: '#352E40', codeHeaderBg: '#231F2C',
      cardBg: '#E61A1822', cardBorder: '#43384C', cardShadow: '#48000000'
    }
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

export function themePalette(id: string, darkMode: boolean): ThemePalette {
  const style = themeStyle(id);
  return darkMode ? style.dark : style.light;
}

export function themeCanvasColor(style: ThemeStyle, darkMode: boolean): string {
  return darkMode ? style.dark.canvas : style.light.canvas;
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

export const THEME_MOTION_SETTING = 'theme_motion_enabled';

export function openSettings(context: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: 'pigo_settings' });
}
