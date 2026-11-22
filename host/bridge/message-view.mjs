import { maxHistoryImageBase64 } from './attachments.mjs';

// 消息与工具视图纯函数:从 phase0.ts 外移,负责从 Pi 消息内容提取文本/图片/工具详情。
// 无状态、可被扩展路由与测试直接复用;HTTP 响应仅依赖 reply 的 JSON 包装。

export function imageParts(content) {
  return Array.isArray(content) ? content.filter((part) => part?.type === 'image') : [];
}

export function reply(response, status, value) {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}

export function replyImage(response, content, index) {
  const part = imageParts(content)[index];
  if (!part) return reply(response, 404, { error: 'image_not_found' });
  const { mimeType, data } = part;
  if (typeof mimeType !== 'string' || !/^image\/(?:jpeg|png|gif|webp|bmp|heic|heif|avif|tiff)$/i.test(mimeType) ||
    typeof data !== 'string' || !data.length) return reply(response, 415, { error: 'unsupported_image' });
  if (data.length > maxHistoryImageBase64) return reply(response, 413, { error: 'image_too_large' });
  return reply(response, 200, { image: { mimeType: mimeType.toLowerCase(), data } });
}

export function messageText(content) {
  if (typeof content === 'string') return content;
  return Array.isArray(content) ? content.flatMap((part) =>
    part?.type === 'text' && typeof part.text === 'string' ? [part.text] : []).join('\n') : '';
}

export const sessionAttachmentMarker = '\n\n[Pi Go 附件] 手机上传了 ';
const titleLength = 48;
const titleSegments = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

export function sessionPromptText(content) {
  const text = messageText(content);
  const attachmentStart = text.lastIndexOf(sessionAttachmentMarker);
  return (attachmentStart < 0 ? text : text.slice(0, attachmentStart)).trim();
}

function shortSessionTitle(text) {
  const line = text.replace(/[\s\p{Cc}]+/gu, ' ').trim();
  let count = 0;
  let end = 0;
  for (const { index } of titleSegments.segment(line)) {
    if (count === titleLength) return line.slice(0, end).trimEnd() + '…';
    count += 1;
    end = index;
  }
  return line || undefined;
}

export function sessionTitlePreview(content) {
  return shortSessionTitle(sessionPromptText(content)) ??
    (imageParts(content).length || messageText(content).includes(sessionAttachmentMarker) ? '附件会话' : undefined);
}

export function generatedSessionTitle(content) {
  const text = messageText(content).trim();
  if (/[\r\n\u2028\u2029]/.test(text)) return undefined;
  return shortSessionTitle(text.replace(/^#{1,6}\s+/, '').replace(/^["“`]+|["”`]+$/g, ''));
}

export function messageTextSlice(text, offset, length) {
  const end = offset + length;
  const chunk = text.slice(offset, end);
  // Keep UTF-16 surrogate pairs together across response boundaries.
  return end < text.length ? chunk.replace(/[\uD800-\uDBFF]$/, '') : chunk;
}

export function toolResultText(result, separateImages) {
  const content = result?.content;
  if (!Array.isArray(content)) return '';
  return content.map((part) => {
    if (part?.type === 'text' && typeof part.text === 'string') return part.text;
    if (part?.type === 'image' && !separateImages) return '［图片输出］';
    return undefined;
  }).filter((text) => text !== undefined).join('\n');
}

export function toolDetails(activity, separateImages) {
  const args = activity.args;
  const command = activity.summary.name === 'bash' && typeof args?.command === 'string' ? args.command : undefined;
  const input = command ?? (args === undefined ? '' : JSON.stringify(args, null, 2) ?? '');
  const output = toolResultText(activity.result, separateImages);
  const limit = 64 * 1024;
  return {
    input: input.slice(0, limit), output: output.slice(0, limit),
    command: command !== undefined, truncated: input.length > limit || output.length > limit,
    state: activity.summary.state,
    imageCount: imageParts(activity.result?.content).length,
    path: typeof args?.path === 'string' && args.path.length <= 2048 ? args.path : undefined,
  };
}

export const toolDetail = (args) => {
  if (!args || typeof args !== 'object') return '';
  for (const key of ['command', 'path', 'file', 'pattern', 'query', 'url', 'prompt', 'description', 'name']) {
    const value = args[key];
    if (typeof value === 'string' && value.trim()) return value.replace(/\s+/g, ' ').trim().slice(0, 120);
  }
  try { return JSON.stringify(args).slice(0, 120); } catch { return ''; }
};
