import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync, readdirSync, renameSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export const maxHistoryImageBase64 = Math.ceil(8 * 1024 * 1024 / 3) * 4;
export const maxImageBytes = 512 * 1024;
export const maxImagesPerPrompt = 4;
export const maxFileBytes = 8 * 1024 * 1024;
export const maxFilesPerPrompt = 3;
// Legacy inline base64 image prompts (single JPEG) plus text keep the old budget;
// token-based attachments travel over POST /upload instead.
export const maxPromptBody = Math.ceil(maxImageBytes / 3) * 4 + 16 * 1024;
// Raw octet-stream cap for POST /upload; phone and bridge agree on it.
export const maxUploadBody = maxFileBytes + 1024;
export const attachmentMaxAgeMs = 14 * 24 * 60 * 60 * 1000;
export const attachmentFolder = join('.pi-go', 'attachments');

export function validPromptImageBuffer(image) {
  if (!Buffer.isBuffer(image) || image.length < 12 || image.length > maxImageBytes ||
      image.readUInt16BE(0) !== 0xffd8 || image.readUInt16BE(image.length - 2) !== 0xffd9) return false;
  let dimensions = false;
  let offset = 2;
  while (offset + 4 <= image.length) {
    if (image[offset++] !== 0xff) return false;
    while (offset < image.length && image[offset] === 0xff) offset++;
    const marker = image[offset++];
    if (offset + 2 > image.length || marker === 0 || marker === 0xd8 || marker === 0xd9) return false;
    const length = image.readUInt16BE(offset);
    if (length < 2 || offset + length > image.length - 2) return false;
    if (marker === 0xda) return dimensions && length >= 6 && offset + length < image.length - 2;
    if ([0xc0, 0xc1, 0xc2].includes(marker)) {
      if (dimensions || length < 11 || image[offset + 2] !== 8) return false;
      const height = image.readUInt16BE(offset + 3);
      const width = image.readUInt16BE(offset + 5);
      const components = image[offset + 7];
      if (!width || !height || width > 1280 || height > 1280 || ![1, 3].includes(components) ||
        length !== 8 + 3 * components) return false;
      dimensions = true;
    }
    offset += length;
  }
  return false;
}

export function validPromptImage(value) {
  if (typeof value !== 'string' || value.length < 20 || value.length > Math.ceil(maxImageBytes / 3) * 4) return false;
  const image = Buffer.from(value, 'base64');
  if (image.toString('base64') !== value) return false;
  return validPromptImageBuffer(image);
}

export function safeAttachmentName(value) {
  if (typeof value !== 'string') return undefined;
  const name = value.normalize('NFC').replace(/[\\/\u0000-\u001f\u007f]/g, '').replace(/^\.+/, '')
    .trim().replace(/\s+/g, ' ').slice(0, 80);
  return name ? name : undefined;
}

export function stagingDir(cwd) {
  if (typeof cwd !== 'string' || !cwd.startsWith('/') || cwd.includes('\0')) throw new Error('invalid_path');
  return join(cwd, attachmentFolder);
}

const tokenOf = (bytes) => createHash('sha256').update(bytes).digest('hex').slice(0, 16);

// Best-effort cleanup of stale uploads; failures never block a new attachment.
function pruneAttachments(directory) {
  try {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.includes('-') || entry.name.startsWith('.')) continue;
      try {
        const info = statSync(join(directory, entry.name));
        if (Date.now() - info.mtimeMs > attachmentMaxAgeMs) rmSync(join(directory, entry.name), { force: true });
      } catch {}
    }
  } catch {}
}

// Content-addressed staging: re-uploading identical bytes is idempotent, so
// phone retries and duplicate sends never fork extra files.
export function stageAttachment(cwd, name, bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 1 || bytes.length > maxFileBytes) throw new Error('invalid_attachment');
  const safe = safeAttachmentName(name);
  if (!safe) throw new Error('invalid_attachment');
  const directory = stagingDir(cwd);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const token = tokenOf(bytes);
  const target = join(directory, `${token}-${safe}`);
  if (statSync(target, { throwIfNoEntry: false }) === undefined) {
    const temporary = join(directory, `.tmp-${process.pid}-${randomBytes(4).toString('hex')}`);
    try {
      writeFileSync(temporary, bytes, { mode: 0o600, flag: 'wx' });
      renameSync(temporary, target);
    } catch (cause) {
      try { unlinkSync(temporary); } catch {}
      if (statSync(target, { throwIfNoEntry: false }) === undefined) throw cause;
    }
  }
  pruneAttachments(directory);
  return { token, path: target, name: safe, size: bytes.length };
}

export function stagedAttachment(cwd, token) {
  if (typeof token !== 'string' || !/^[a-f0-9]{16}$/.test(token)) return undefined;
  let directory;
  try { directory = stagingDir(cwd); } catch { return undefined; }
  let found;
  try {
    for (const name of readdirSync(directory).sort()) {
      if (!name.startsWith(`${token}-`)) continue;
      // The token addresses content, so several display names may share it;
      // resolve deterministically to the first one.
      found = name.slice(token.length + 1);
      break;
    }
  } catch { return undefined; }
  if (found === undefined) return undefined;
  const path = join(directory, `${token}-${found}`);
  const info = statSync(path, { throwIfNoEntry: false });
  if (info === undefined || !info.isFile() || info.size > maxFileBytes) return undefined;
  return { token, path, name: found, size: info.size };
}

// 手机 prompt 附件列表校验:去重、限数,返回 { token, kind } 列表或 undefined 表示非法。
export function promptAttachments(value) {
  if (value === undefined) return [];
  if (!Array.isArray(value)) return undefined;
  const items = [];
  for (const entry of value) {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry) || typeof entry.token !== 'string' ||
      !/^[a-f0-9]{16}$/.test(entry.token) || (entry.kind !== 'image' && entry.kind !== 'file')) return undefined;
    if (!items.some((item) => item.kind === entry.kind && item.token === entry.token))
      items.push({ token: entry.token, kind: entry.kind });
  }
  if (items.filter((item) => item.kind === 'image').length > maxImagesPerPrompt) return undefined;
  if (items.filter((item) => item.kind === 'file').length > maxFilesPerPrompt) return undefined;
  return items;
}
