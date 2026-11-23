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
    id: 'mint',
    label: '雾松玻璃',
    subtitle: '林间晨雾 · 萤火漫游',
    styleTag: '玻璃',
    surface: 'glass',
    bubble: 'gradient',
    bubbleRadius: 18,
    cardRadius: 16,
    codeRadius: 12,
    light: {
      accent: '#166957', accentForeground: '#FFFFFF', accentTint: '#D8F2E9',
      canvas: '#F3F8F6', auraTop: '#428CE0C5', auraBottom: '#30A8E0E8',
      bubbleStart: '#D6F2E8', bubbleEnd: '#E4F5F3', bubbleBorder: '#B7E2D4',
      codeBg: '#FAFCFB', codeBorder: '#D2E5DE', codeHeaderBg: '#EDF6F2',
      cardBg: '#EBFFFFFF', cardBorder: '#D2E4DD', cardShadow: '#122E5A4C'
    },
    dark: {
      accent: '#8FE3C8', accentForeground: '#15191C', accentTint: '#1F3A35',
      canvas: '#0E1514', auraTop: '#381F7A65', auraBottom: '#2A1D4E5E',
      bubbleStart: '#1B3B35', bubbleEnd: '#1E353E', bubbleBorder: '#2D5950',
      codeBg: '#141F1D', codeBorder: '#243834', codeHeaderBg: '#1A2926',
      cardBg: '#CC16201E', cardBorder: '#2E544C', cardShadow: '#42000000'
    }
  },
  {
    id: 'aurora',
    label: '极光之境',
    subtitle: '北欧极光 · 流星闪烁',
    styleTag: '极光',
    surface: 'glass',
    bubble: 'gradient',
    bubbleRadius: 20,
    cardRadius: 18,
    codeRadius: 14,
    light: {
      accent: '#0E6B8A', accentForeground: '#FFFFFF', accentTint: '#DAF1FA',
      canvas: '#F3F7FC', auraTop: '#4A7DE0F0', auraBottom: '#40C4A8F8',
      bubbleStart: '#D9F1FA', bubbleEnd: '#EAE4FC', bubbleBorder: '#B9DFF0',
      codeBg: '#FAFBFD', codeBorder: '#D1E0EE', codeHeaderBg: '#EEF4FA',
      cardBg: '#E8FFFFFF', cardBorder: '#CFDFF0', cardShadow: '#14264C78'
    },
    dark: {
      accent: '#7CE6F2', accentForeground: '#15191C', accentTint: '#183A47',
      canvas: '#0B111A', auraTop: '#42177C8E', auraBottom: '#3A4E2A8A',
      bubbleStart: '#163A48', bubbleEnd: '#2B264D', bubbleBorder: '#2C5C6E',
      codeBg: '#111A26', codeBorder: '#23344A', codeHeaderBg: '#162333',
      cardBg: '#C8131C29', cardBorder: '#34587A', cardShadow: '#48000000'
    }
  },
  {
    id: 'ocean',
    label: '晴空蔚蓝',
    subtitle: '深海光柱 · 浮泡微光',
    styleTag: '玻璃',
    surface: 'glass',
    bubble: 'gradient',
    bubbleRadius: 18,
    cardRadius: 16,
    codeRadius: 12,
    light: {
      accent: '#225B9E', accentForeground: '#FFFFFF', accentTint: '#DCEBFF',
      canvas: '#F3F7FC', auraTop: '#4088B8FA', auraBottom: '#2C96D6FA',
      bubbleStart: '#DCEBFF', bubbleEnd: '#E8F1FD', bubbleBorder: '#BCD6F7',
      codeBg: '#FAFCFF', codeBorder: '#D2DFF0', codeHeaderBg: '#EEF4FC',
      cardBg: '#EBFFFFFF', cardBorder: '#D2DFF0', cardShadow: '#122A4E7A'
    },
    dark: {
      accent: '#9EC6FF', accentForeground: '#15191C', accentTint: '#1E3350',
      canvas: '#0E141E', auraTop: '#38205096', auraBottom: '#2819486E',
      bubbleStart: '#1D3352', bubbleEnd: '#23304A', bubbleBorder: '#314F78',
      codeBg: '#141D2B', codeBorder: '#26364D', codeHeaderBg: '#1A2638',
      cardBg: '#CC161F2D', cardBorder: '#30496B', cardShadow: '#44000000'
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
    id: 'tokyo',
    label: '东京夜色',
    subtitle: '赛博雨夜 · 霓虹网格',
    styleTag: '霓虹',
    surface: 'terminal',
    bubble: 'outline',
    bubbleRadius: 12,
    cardRadius: 12,
    codeRadius: 10,
    light: {
      accent: '#4352B5', accentForeground: '#FFFFFF', accentTint: '#E9ECFD',
      canvas: '#F2F3FA', auraTop: '#3C8E9CF5', auraBottom: '#34B990F5',
      bubbleStart: '#EEF0FE', bubbleEnd: '#EEF0FE', bubbleBorder: '#8C99E8',
      codeBg: '#EAECF7', codeBorder: '#CFD5F0', codeHeaderBg: '#E1E5F5',
      cardBg: '#F7F8FE', cardBorder: '#C7CEF0', cardShadow: '#14334099'
    },
    dark: {
      accent: '#9AA8FF', accentForeground: '#15191C', accentTint: '#202646',
      canvas: '#131624', auraTop: '#4238429E', auraBottom: '#36662D8C',
      bubbleStart: '#1F2442', bubbleEnd: '#1F2442', bubbleBorder: '#6978D6',
      codeBg: '#1A1E30', codeBorder: '#303754', codeHeaderBg: '#21273D',
      cardBg: '#EB181C2E', cardBorder: '#3C4673', cardShadow: '#3D2E3B8A'
    }
  },
  {
    id: 'terminal',
    label: '极客终端',
    subtitle: '黑客代码雨 · 扫描线',
    styleTag: '终端',
    surface: 'terminal',
    bubble: 'outline',
    bubbleRadius: 8,
    cardRadius: 10,
    codeRadius: 8,
    light: {
      accent: '#126B3F', accentForeground: '#FFFFFF', accentTint: '#E4F5EB',
      canvas: '#F2F6F3', auraTop: '#2E74D49E', auraBottom: '#2268C4B4',
      bubbleStart: '#E6F5EC', bubbleEnd: '#E6F5EC', bubbleBorder: '#58B584',
      codeBg: '#EAF1EC', codeBorder: '#C5DBC9', codeHeaderBg: '#E0ECE4',
      cardBg: '#F7FBF8', cardBorder: '#BFD9C7', cardShadow: '#12126B3F'
    },
    dark: {
      accent: '#5CE699', accentForeground: '#15191C', accentTint: '#11291D',
      canvas: '#070A08', auraTop: '#36136E3D', auraBottom: '#280F5246',
      bubbleStart: '#0F261A', bubbleEnd: '#0F261A', bubbleBorder: '#2E9E63',
      codeBg: '#0D1410', codeBorder: '#1F3B2B', codeHeaderBg: '#121D17',
      cardBg: '#F00C130F', cardBorder: '#245238', cardShadow: '#33126E3B'
    }
  },
  {
    id: 'paper',
    label: '京都纸墨',
    subtitle: '枯山水纹 · 水墨涟漪',
    styleTag: '纸墨',
    surface: 'paper',
    bubble: 'tinted',
    bubbleRadius: 12,
    cardRadius: 12,
    codeRadius: 10,
    light: {
      accent: '#9E3E26', accentForeground: '#FFFFFF', accentTint: '#F2E7D8',
      canvas: '#F7F3EB', auraTop: '#2EE8D2B5', auraBottom: '#24E5C8B0',
      bubbleStart: '#F2E7D8', bubbleEnd: '#F2E7D8', bubbleBorder: '#E2D2BC',
      codeBg: '#EFE9DD', codeBorder: '#DDD3C2', codeHeaderBg: '#E8E0D1',
      cardBg: '#FCF9F2', cardBorder: '#E0D6C6', cardShadow: '#0C5A442C'
    },
    dark: {
      accent: '#F0A384', accentForeground: '#15191C', accentTint: '#382B23',
      canvas: '#171411', auraTop: '#2C5E3A26', auraBottom: '#224A3422',
      bubbleStart: '#382B23', bubbleEnd: '#382B23', bubbleBorder: '#544135',
      codeBg: '#201B17', codeBorder: '#382F28', codeHeaderBg: '#28221D',
      cardBg: '#F21F1A16', cardBorder: '#3A312A', cardShadow: '#30000000'
    }
  },
  {
    id: 'iris',
    label: '暮色鸢尾',
    subtitle: '星河星座 · 紫雾连星',
    styleTag: '柔雾',
    surface: 'soft',
    bubble: 'gradient',
    bubbleRadius: 20,
    cardRadius: 18,
    codeRadius: 14,
    light: {
      accent: '#6845A0', accentForeground: '#FFFFFF', accentTint: '#EFE6FC',
      canvas: '#F7F4FC', auraTop: '#42C4A8F8', auraBottom: '#349BB8FA',
      bubbleStart: '#EFE6FC', bubbleEnd: '#E4ECFD', bubbleBorder: '#D5C4F2',
      codeBg: '#FDFCFF', codeBorder: '#DFD6EE', codeHeaderBg: '#F3EEFA',
      cardBg: '#F4FFFFFF', cardBorder: '#E3DAF2', cardShadow: '#12462A7A'
    },
    dark: {
      accent: '#D0B8FD', accentForeground: '#15191C', accentTint: '#33264D',
      canvas: '#14111C', auraTop: '#3A5A328F', auraBottom: '#2E2E448A',
      bubbleStart: '#33264D', bubbleEnd: '#262C4F', bubbleBorder: '#503E78',
      codeBg: '#1C1829', codeBorder: '#322B47', codeHeaderBg: '#241F33',
      cardBg: '#E01C1828', cardBorder: '#433861', cardShadow: '#44000000'
    }
  },
  {
    id: 'amber',
    label: '焦糖拿铁',
    subtitle: '咖啡暖汽 · 炉火浮光',
    styleTag: '纸墨',
    surface: 'paper',
    bubble: 'tinted',
    bubbleRadius: 14,
    cardRadius: 14,
    codeRadius: 10,
    light: {
      accent: '#85520C', accentForeground: '#FFFFFF', accentTint: '#F7E7CE',
      canvas: '#FAF6EE', auraTop: '#38F5D49E', auraBottom: '#2AEEC094',
      bubbleStart: '#F7E7CE', bubbleEnd: '#F7E7CE', bubbleBorder: '#E5CFAF',
      codeBg: '#F3ECE0', codeBorder: '#E2D6C3', codeHeaderBg: '#ECE3D3',
      cardBg: '#FDFBF6', cardBorder: '#E5DAC8', cardShadow: '#0C634314'
    },
    dark: {
      accent: '#F6C88A', accentForeground: '#15191C', accentTint: '#3E2F1E',
      canvas: '#181410', auraTop: '#326E4B1E', auraBottom: '#265C321C',
      bubbleStart: '#3E2F1E', bubbleEnd: '#3E2F1E', bubbleBorder: '#5E482E',
      codeBg: '#221C16', codeBorder: '#3B3126', codeHeaderBg: '#2B231C',
      cardBg: '#F2201A15', cardBorder: '#3D3328', cardShadow: '#30000000'
    }
  },
  {
    id: 'crimson',
    label: '朱砂丹霞',
    subtitle: '孔明灯火 · 鎏金星火',
    styleTag: '霞光',
    surface: 'glass',
    bubble: 'gradient',
    bubbleRadius: 18,
    cardRadius: 16,
    codeRadius: 12,
    light: {
      accent: '#B5352C', accentForeground: '#FFFFFF', accentTint: '#FCE5E3',
      canvas: '#FDF5F4', auraTop: '#42FF9E96', auraBottom: '#34FFD08C',
      bubbleStart: '#FCE5E3', bubbleEnd: '#FDEEDB', bubbleBorder: '#F2C4C0',
      codeBg: '#FFFDFC', codeBorder: '#EED6D4', codeHeaderBg: '#FAEEEC',
      cardBg: '#EBFFFDFC', cardBorder: '#EED6D4', cardShadow: '#1475241E'
    },
    dark: {
      accent: '#FFA39A', accentForeground: '#15191C', accentTint: '#4A2220',
      canvas: '#1A1111', auraTop: '#3A8C2620', auraBottom: '#2E7A4B1C',
      bubbleStart: '#4A2220', bubbleEnd: '#452E1E', bubbleBorder: '#733734',
      codeBg: '#231717', codeBorder: '#3D2828', codeHeaderBg: '#2D1D1D',
      cardBg: '#CC241818', cardBorder: '#593333', cardShadow: '#48000000'
    }
  },
  {
    id: 'graphite',
    label: '水墨石墨',
    subtitle: '宣纸山水 · 墨竹飞鹤',
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

export function openSettings(context: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: 'pigo_settings' });
}
