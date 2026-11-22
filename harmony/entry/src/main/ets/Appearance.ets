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
    subtitle: '清新松绿 · 液态通透',
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
    subtitle: '冰青幻紫 · 双色光晕',
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
    subtitle: '深海晴空 · 澄澈玻璃',
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
    subtitle: '晚霞暖橘 · 暮光微澜',
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
    label: '柔雾落樱',
    subtitle: '樱粉浪漫 · 圆润轻盈',
    styleTag: '柔雾',
    surface: 'soft',
    bubble: 'gradient',
    bubbleRadius: 22,
    cardRadius: 20,
    codeRadius: 14,
    light: {
      accent: '#B0385A', accentForeground: '#FFFFFF', accentTint: '#FDE6EE',
      canvas: '#FDF5F7', auraTop: '#44FFAEC7', auraBottom: '#36D8B8FA',
      bubbleStart: '#FDE4EC', bubbleEnd: '#F7E4F8', bubbleBorder: '#F4C6D6',
      codeBg: '#FFFBFD', codeBorder: '#EED6DF', codeHeaderBg: '#FAEDF2',
      cardBg: '#F4FFFFFF', cardBorder: '#F2DCE4', cardShadow: '#12702944'
    },
    dark: {
      accent: '#FFA6BE', accentForeground: '#15191C', accentTint: '#462431',
      canvas: '#1A1115', auraTop: '#388A294B', auraBottom: '#2C5B2466',
      bubbleStart: '#482331', bubbleEnd: '#3C2240', bubbleBorder: '#6E374C',
      codeBg: '#24181E', codeBorder: '#3E2933', codeHeaderBg: '#2D1E26',
      cardBg: '#E024181E', cardBorder: '#4D2F3D', cardShadow: '#44000000'
    }
  },
  {
    id: 'tokyo',
    label: '东京夜色',
    subtitle: '霓虹靛紫 · 锐利线框',
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
    subtitle: 'OLED 黑底 · 荧光绿框',
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
    subtitle: '暖宣护眼 · 朱砂印泥',
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
    subtitle: '丁香星梦 · 柔雾渐变',
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
    subtitle: '暖金秋叶 · 温润哑光',
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
    subtitle: '绯红鎏金 · 炽热光感',
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
    label: '极简石墨',
    subtitle: '冷静中性 · 纯粹克制',
    styleTag: '极简',
    surface: 'glass',
    bubble: 'tinted',
    bubbleRadius: 16,
    cardRadius: 16,
    codeRadius: 12,
    light: {
      accent: '#465361', accentForeground: '#FFFFFF', accentTint: '#E7ECF1',
      canvas: '#F8F9FB', auraTop: '#24C4D0DE', auraBottom: '#1CD2DCE6',
      bubbleStart: '#E7ECF1', bubbleEnd: '#E7ECF1', bubbleBorder: '#D2DAE3',
      codeBg: '#FFFFFF', codeBorder: '#DDE2E9', codeHeaderBg: '#F0F3F7',
      cardBg: '#EBFFFFFF', cardBorder: '#D6DDE5ED', cardShadow: '#0E637587'
    },
    dark: {
      accent: '#C6D0DB', accentForeground: '#15191C', accentTint: '#2D353F',
      canvas: '#121519', auraTop: '#223B4859', auraBottom: '#1A2B3645',
      bubbleStart: '#2D353F', bubbleEnd: '#2D353F', bubbleBorder: '#434E5C',
      codeBg: '#1A1F26', codeBorder: '#303843', codeHeaderBg: '#222831',
      cardBg: '#CC1A1F26', cardBorder: '#28D8E8FA', cardShadow: '#30000000'
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
