import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { buildTranscriptTurns } from './TranscriptTurns';
import type { ChatMessage } from './model/PiGoTypes';

export const SHARED_SESSION_DIR = 'pigo-shares';
export const MAX_SYSTEM_SHARE_TEXT_BYTES = 120 * 1024;
const SHARED_FILE_TTL_MS = 24 * 60 * 60 * 1000;

export type SessionShareFormat = 'markdown' | 'text';

export interface SessionShareMeta {
  title: string;
  workspace?: string;
  computer?: string;
  exportedAt?: Date;
}

export interface SessionShareOptions {
  liveText?: string;
  includeProcess?: boolean;
}

export interface SystemShareResult {
  mode: SessionShareFormat;
  fallbackToFile: boolean;
  filePath?: string;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

export function formatExportTime(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

export function normalizeShareTitle(title?: string): string {
  const cleaned = (title ?? '').replace(/\s+/g, ' ').trim();
  if (!cleaned || cleaned === '(no messages)') return '未命名会话';
  return cleaned;
}

export function safeShareFileName(title?: string): string {
  const base = normalizeShareTitle(title)
    .replace(/[\\/:*?"<>|\u0000-\u001f\u007f]+/g, '_')
    .replace(/\s+/g, ' ')
    .replace(/^[._\s-]+/, '')
    .replace(/[._\s-]+$/, '')
    .slice(0, 60)
    .trim();
  return base || 'pi-go-session';
}

export function utf8ByteLength(text: string): number {
  return new util.TextEncoder().encodeInto(text).byteLength;
}

export function formatSessionMarkdown(
  messages: ChatMessage[],
  meta: SessionShareMeta,
  options?: SessionShareOptions
): string {
  const liveText = options?.liveText?.trim() ?? '';
  const includeProcess = options?.includeProcess !== false;
  const turns = buildTranscriptTurns(messages, [], '', liveText, true);
  if (!turns.length) return '';

  const title = normalizeShareTitle(meta.title);
  const infoParts: string[] = [];
  if (meta.workspace?.trim()) infoParts.push(`工作区：${meta.workspace.trim()}`);
  if (meta.computer?.trim()) infoParts.push(`电脑：${meta.computer.trim()}`);
  infoParts.push(`导出时间：${formatExportTime(meta.exportedAt ?? new Date())}`);

  const sections: string[] = [`# ${title}\n\n> ${infoParts.join(' · ')}`];

  for (const turn of turns) {
    if (turn.kind === 'user') {
      const bodyParts: string[] = [];
      const text = turn.message?.text?.trim() ?? '';
      if (text) bodyParts.push(text);
      const images = turn.message?.imageCount ?? 0;
      if (images > 0) bodyParts.push(`（附 ${images} 张图片）`);
      if (bodyParts.length) {
        sections.push(`## 用户\n\n${bodyParts.join('\n\n')}`);
      }
      continue;
    }

    const bodyParts: string[] = [];
    if (includeProcess && turn.summary?.label) {
      bodyParts.push(`> 过程：${turn.summary.label}`);
    }
    for (const step of turn.steps) {
      if (step.kind === 'note' && step.text.trim()) {
        bodyParts.push(step.text.trim());
      }
    }
    const finalText = turn.message?.text?.trim() || turn.liveText.trim();
    if (finalText) bodyParts.push(finalText);
    let imageCount = turn.message?.imageCount ?? 0;
    for (const extra of turn.extraImageMessages) {
      imageCount += extra.imageCount ?? 0;
    }
    if (imageCount > 0) bodyParts.push(`（附 ${imageCount} 张图片）`);
    if (bodyParts.length) {
      sections.push(`## 助手\n\n${bodyParts.join('\n\n')}`);
    }
  }

  return sections.length > 1 ? sections.join('\n\n---\n\n') : '';
}

export function buildShareDescription(meta: SessionShareMeta, messageCount: number): string {
  const parts: string[] = [];
  if (meta.workspace?.trim()) parts.push(meta.workspace.trim());
  if (messageCount > 0) parts.push(`${messageCount} 条消息`);
  parts.push('来自 Pi Go');
  return parts.join(' · ');
}

function pruneSharedFiles(directory: string): void {
  try {
    const now = Date.now();
    const names = fileIo.listFileSync(directory);
    for (const name of names) {
      const target = `${directory}/${name}`;
      try {
        const stat = fileIo.statSync(target);
        if (now - stat.mtime * 1000 > SHARED_FILE_TTL_MS) {
          fileIo.unlinkSync(target);
        }
      } catch {}
    }
  } catch {}
}

export function writeSessionShareFile(cacheDir: string, title: string, content: string): string {
  const directory = `${cacheDir}/${SHARED_SESSION_DIR}`;
  if (!fileIo.accessSync(directory)) {
    fileIo.mkdirSync(directory, true);
  }
  pruneSharedFiles(directory);
  const localPath = `${directory}/${safeShareFileName(title)}.md`;
  const bytes = new util.TextEncoder().encodeInto(content);
  const file = fileIo.openSync(
    localPath,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY
  );
  try {
    let start = 0;
    while (start < bytes.length) {
      const written = fileIo.writeSync(file.fd, bytes.slice(start).buffer);
      if (written <= 0) throw new Error('share_write_failed');
      start += written;
    }
  } finally {
    fileIo.closeSync(file);
  }
  return localPath;
}

export async function shareSessionViaSystem(
  context: common.UIAbilityContext,
  content: string,
  meta: SessionShareMeta,
  messageCount: number,
  format: SessionShareFormat = 'markdown',
  anchor?: string
): Promise<SystemShareResult> {
  const title = normalizeShareTitle(meta.title);
  const description = buildShareDescription(meta, messageCount);
  const byteLength = utf8ByteLength(content);
  const useFile = format === 'markdown' || byteLength > MAX_SYSTEM_SHARE_TEXT_BYTES;
  const fallbackToFile = format === 'text' && useFile;

  let record: systemShare.SharedRecord;
  let filePath: string | undefined = undefined;
  if (useFile) {
    filePath = writeSessionShareFile(context.cacheDir, title, content);
    record = {
      utd: utd.UniformDataType.MARKDOWN,
      uri: fileUri.getUriFromPath(filePath),
      title: `${safeShareFileName(title)}.md`,
      description
    };
  } else {
    record = {
      utd: utd.UniformDataType.PLAIN_TEXT,
      content,
      title,
      description
    };
  }

  const data = new systemShare.SharedData(record);
  const controller = new systemShare.ShareController(data);
  const options: systemShare.ShareControllerOptions = {
    selectionMode: systemShare.SelectionMode.SINGLE,
    previewMode: systemShare.SharePreviewMode.DEFAULT
  };
  if (anchor) options.anchor = anchor;
  await controller.show(context, options);
  return {
    mode: useFile ? 'markdown' : 'text',
    fallbackToFile,
    filePath
  };
}
