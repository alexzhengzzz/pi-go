// 聊天路径与预览工具:从 pages/Index.ets 外移的无状态纯函数。
// 负责消息文本里的工作区路径解析、文件 chip 提取与接收文件名清洗。

const HISTORY_IMAGE_EXTENSIONS: string[] = ['.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif', '.avif', '.tiff'];

export function textPreviewFormat(name: string): string {
  if (/\.(?:md|markdown|mdown)$/i.test(name)) return 'markdown';
  if (/\.(?:txt|text|log|csv|tsv|json|jsonl|yaml|yml|toml|ini|conf|cfg|xml|sql|sh|py|js|mjs|ts|ets|css|swift|java|go|rs|c|h|cpp|hpp)$/i.test(name) ||
    /^(?:readme|license|notice|changelog|dockerfile|makefile|\.gitignore|\.editorconfig)$/i.test(name)) return 'text';
  return '';
}

export function isImageFile(name: string): boolean {
  return /\.(?:jpe?g|png|gif|webp|bmp|heic|heif|avif|tiff?|svg|ico)$/i.test(name);
}

export function normalizeWorkspacePath(cwd: string, path: string): string {
  if (!cwd || !path || path.length > 2048 || /[\\\u0000-\u001f]/.test(path) ||
    /^[a-z][a-z0-9+.-]*:/i.test(path) || path.startsWith('//') || path.startsWith('~')) return '';
  let candidate = path;
  if (candidate.startsWith('/')) {
    const root = cwd.endsWith('/') ? cwd : `${cwd}/`;
    if (!root.startsWith('/') || !candidate.startsWith(root)) return '';
    candidate = candidate.slice(root.length);
  }
  const parts: string[] = [];
  for (const part of candidate.split('/')) {
    if (!part || part === '.') continue;
    if (part === '..') return '';
    parts.push(part);
  }
  return parts.join('/');
}

export function markdownWorkspacePath(target: string, cwd: string, documentPath: string): string {
  const path = target.split(/[?#]/)[0];
  try {
    const decoded = decodeURIComponent(path);
    if (!decoded || /^[a-z][a-z0-9+.-]*:/i.test(decoded)) return '';
    if (decoded.startsWith('/')) return normalizeWorkspacePath(cwd, decoded);
    if (decoded.startsWith('~') || /[\\\u0000-\u001f]/.test(decoded)) return '';
    const parts = documentPath ? documentPath.split('/').slice(0, -1) : [];
    for (const part of decoded.split('/')) {
      if (!part || part === '.') continue;
      if (part === '..') {
        if (!parts.length) return '';
        parts.pop();
      } else parts.push(part);
    }
    return normalizeWorkspacePath(cwd, parts.join('/'));
  } catch { return ''; }
}

// 沙箱文件名只保留安全字符,并压制长度,避免电脑端文件名带进手机存储异常字符。
export function safeLocalFileName(name: string): string {
  const cleaned = name.replace(/[^A-Za-z0-9._-]/g, '_').slice(-80).replace(/^[._-]+/, '_').trim();
  return cleaned || 'file';
}

export function messageFileChips(text: string, cwd: string): string[] {
  if (!text || !cwd) return [];
  const chips: string[] = [];
  // 保留 Markdown 目标及引号内的空格,仅剥离普通文本中的句末标点。
  const references = /\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))(?:\s+["'][^\n]*?["'])?\s*\)|`+([^`\n]+)`+|"([^"\n]+)"|'([^'\n]+)'|([^\s`'"()<>\[\]{}|，。；、！？（）〔〕「」『』]+)/g;
  let match = references.exec(text);
  while (match && chips.length < 4) {
    const destination = match[1] ?? match[2];
    const inlineImage = destination !== undefined && text[match.index - 1] === '!';
    let token = destination ?? match[3] ?? match[4] ?? match[5] ?? match[6].replace(/[.,;:!?]+$/, '');
    match = references.exec(text);
    if (inlineImage) continue;
    if (destination !== undefined) {
      try { token = decodeURIComponent(destination); } catch { continue; }
    }
    if (!/\.[A-Za-z0-9]{1,10}$/.test(token)) continue;
    const path = normalizeWorkspacePath(cwd, token);
    if (path && !chips.includes(path)) chips.push(path);
  }
  return chips;
}

export { HISTORY_IMAGE_EXTENSIONS };
