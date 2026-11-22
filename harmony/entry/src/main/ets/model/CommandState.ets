import type { BridgeReply, CommandRow } from './PiGoTypes';
import { BridgeFailure } from './PiGoTypes';

export interface CommandList {
  loading: boolean;
  error: string;
  rows?: CommandRow[];
}

export function skillCommands(rows: CommandRow[]): CommandRow[] {
  return rows.filter((row: CommandRow): boolean => row.source === 'skill');
}

export function commandDraft(row: CommandRow, prompt: string = ''): string {
  return `${row.invoke ?? `/${row.name}`} ${prompt}`;
}

export function skillDraft(row: CommandRow, draft: string): string {
  return commandDraft(row, draft.replace(/^\s*\/skill:\S*\s*/, ''));
}

export class CommandState {
  private generation: number = 0;
  private loadedAt: number = 0;
  private loading: boolean = false;

  stale(): boolean {
    return !this.loadedAt || Date.now() - this.loadedAt >= 60000;
  }

  reset(): void {
    this.generation += 1;
    this.loadedAt = 0;
    this.loading = false;
  }

  async load(id: string, request: () => Promise<BridgeReply>, publish: (list: CommandList) => void): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    const generation = ++this.generation;
    publish({ loading: true, error: '' });
    let rows: CommandRow[] | undefined;
    let message = '';
    try {
      const reply = await request();
      if (generation !== this.generation) return;
      if (reply.session?.id !== id || !reply.commands) {
        message = '加载命令失败，点此重试';
      } else {
        rows = reply.commands.slice(0, 200);
        this.loadedAt = Date.now();
      }
    } catch (error) {
      if (generation !== this.generation) return;
      message = error instanceof BridgeFailure && error.message === 'not_found' ?
        '请更新电脑端 Pi Go，并重启桥接和当前会话后重试' : '加载命令失败，点此重试';
    } finally {
      if (generation === this.generation) {
        this.loading = false;
        publish({ loading: false, error: message, rows: rows });
      }
    }
  }
}
