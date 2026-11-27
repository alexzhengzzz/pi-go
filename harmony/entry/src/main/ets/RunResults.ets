import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export interface RunFile {
  path: string;
  change: string;
  diff: boolean;
  artifact: boolean;
}

export interface RunCheck {
  id: string;
  command: string;
  state: string;
  ms?: number;
}

export interface RunScreenshot {
  toolId: string;
  messageId: string;
}

export interface RunEvent {
  id: string;
  sessionId: string;
  cwd: string;
  title?: string;
  body?: string;
  summary?: string;
  hasFullResult?: boolean;
  source?: string;
  severity?: string;
  suggestedPrompt?: string;
  artifacts?: string[];
  status: string;
  messageId?: string;
  pendingId?: string;
  finishedAt: number;
  files?: RunFile[];
  checks?: RunCheck[];
  screenshots?: RunScreenshot[];
  partial?: boolean;
}

export interface InboxRun {
  run: RunEvent;
  address: string;
  computer: string;
  unread: boolean;
}

export function runStatus(status: string): string {
  switch (status) {
    case 'waiting': return '等待处理';
    case 'failed': return '运行失败';
    case 'stopped': return '已停止';
    case 'alert': return '工作区提醒';
    default: return '已完成';
  }
}

export function pushDeviceId(token: string): string {
  return sha256Hex('pi-go-push:' + token);
}

export function runNotificationId(runId: string): string {
  return sha256Hex(runId).slice(0, 32);
}

export function runNotificationText(title: string): string {
  const chars = Array.from(title.replace(/\s+/g, ' ').trim());
  if (chars.length > 64) return `${chars.slice(0, 63).join('')}…`;
  return chars.join('') || '未命名任务';
}

function sha256Hex(value: string): string {
  const hash = cryptoFramework.createMd('SHA256');
  hash.updateSync({ data: new util.TextEncoder().encodeInto(value) });
  return Array.from(hash.digestSync().data, (byte: number): string => byte.toString(16).padStart(2, '0')).join('');
}

// The patch omits Git headers and contains one or more unified-diff hunks.
export interface DiffLine {
  key: number;
  text: string;
  line: number;
  kind: string;
}

export function diffLines(patch: string): DiffLine[] {
  let line = 0;
  const content = patch.endsWith('\n') ? patch.slice(0, -1) : patch;
  return content.split('\n').map((text: string, key: number): DiffLine => {
    const hunk = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(text);
    if (hunk) {
      line = Number(hunk[1]);
      return { key: key, text: text, line: 0, kind: 'hunk' };
    }
    if (text.startsWith('-')) return { key: key, text: text, line: 0, kind: 'remove' };
    if (text.startsWith('+') || text.startsWith(' ')) {
      return { key: key, text: text, line: line++, kind: text.startsWith('+') ? 'add' : 'context' };
    }
    return { key: key, text: text, line: 0, kind: 'context' };
  });
}
