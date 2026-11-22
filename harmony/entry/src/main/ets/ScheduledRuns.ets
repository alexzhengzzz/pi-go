import type { Companion } from './CredentialVault';
import { computerGroupId } from './ComputerGroups';

export interface ScheduleJob {
  id: string;
  cwd: string;
  name: string;
  prompt: string;
  kind: string;
  at?: number;
  time?: string;
  interval?: number;
  catchUp: number;
  enabled: boolean;
  version: number;
  nextAt: number | null;
}

export interface ScheduleRun {
  id: string;
  jobId: string;
  cwd: string;
  name: string;
  scheduledAt: number;
  startedAt: number | null;
  finishedAt: number | null;
  coalesced?: number;
  status: string;
  reason?: string;
  summary?: string;
  sessionId?: string;
}

export interface RunMessage {
  key: string;
  source: string;
  address: string;
  computer: string;
  run: ScheduleRun;
  unread: boolean;
  dismissed?: boolean;
}

export function isCurrentScheduleComputer(computers: Companion[], address: string, message: RunMessage): boolean {
  const current = computers.find((item: Companion): boolean => item.address === address);
  const origin = computers.find((item: Companion): boolean => item.address === message.address);
  return !!current && !!origin && computerGroupId(current) === computerGroupId(origin);
}

export interface ScheduleWatch {
  address: string;
  source?: string;
}

export function scheduleTime(timestamp: number): string {
  const date = new Date(timestamp);
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  const hours = String(date.getHours()).padStart(2, '0');
  const minutes = String(date.getMinutes()).padStart(2, '0');
  return `${date.getFullYear()}-${month}-${day} ${hours}:${minutes}`;
}

export function parseScheduleTime(value: string): number {
  if (!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(value)) return 0;
  const timestamp = new Date(value.replace(' ', 'T') + ':00').getTime();
  return Number.isFinite(timestamp) && scheduleTime(timestamp) === value ? timestamp : 0;
}

export function scheduleRunStatus(status: string): string {
  if (status === 'succeeded') return '已完成';
  if (status === 'running') return '运行中';
  if (status === 'failed') return '运行失败';
  if (status === 'interrupted') return '执行中断';
  if (status === 'missed') return '已错过';
  return '已跳过';
}

export function scheduleRunReason(reason: string): string {
  switch (reason) {
    case 'interaction_required': return 'Pi 需要确认或输入，本次无人值守运行已结束。';
    case 'model_failed': return '模型未正常完成，请查看 Pi 会话。';
    case 'runtime_exited': return 'Pi 进程提前退出。';
    case 'prompt_failed': return 'Pi 未能启动或接收提示词。';
    case 'run_timeout': return '本次运行超过 30 分钟。';
    case 'desktop_restarted': return '电脑端服务重启，本次运行中断。';
    case 'desktop_stopped': return '电脑端服务停止，本次运行中断。';
    case 'workspace_closed': return '工作区已关闭或不可用。';
    case 'missed_window': return '电脑恢复时已超过可补跑时间。';
    case 'overlap': return '上一次运行还在进行。';
    case 'capacity': return '电脑端定时任务并发数已达上限。';
    default: return '';
  }
}
