import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { wearEngine } from '@kit.WearEngine';

export interface WatchReminder {
  id: string;
  title: string;
  text: string;
}

const RETRY_AFTER_MS: number = 60000;
const MAX_DELIVERED_IDS: number = 240;
const MAX_TEXT_CODE_POINTS: number = 90;

/** Keeps the notification below Wear Engine's 400 UTF-8 byte text limit. */
export function watchReminderText(status: string, computer: string, title: string): string {
  const text = `${status} · ${computer}${title ? `\n${title}` : ''}`;
  return Array.from(text).slice(0, MAX_TEXT_CODE_POINTS).join('');
}

export function watchReminderStatusText(status: string): string {
  switch (status) {
    case 'unsupported': return '当前手机系统不支持 Wear Engine';
    case 'service': return '请先在 AppGallery Connect 开通 Wear Engine 消息通知权限';
    case 'account': return '请登录华为账号并同意 Wear Engine 服务协议';
    case 'none': return '请在华为运动健康中连接手表';
    case 'capability': return '已连接的手表不支持模板化通知';
    case 'ready': return '已连接手表，任务状态变化时振动提醒';
    case 'error': return '手表提醒发送失败，将在新事件到达时重试';
    default: return '任务完成、失败、待处理和定时任务结果同步到手表';
  }
}

/**
 * Sends phone-side template notifications through Huawei Health. No watch HAP
 * is required. Delivery IDs are persisted by the page to suppress duplicates.
 */
export class WatchReminderController {
  private context?: common.UIAbilityContext = undefined;
  private enabled: boolean = true;
  private readonly delivered: Set<string> = new Set<string>();
  private readonly queued: Set<string> = new Set<string>();
  private work: Promise<void> = Promise.resolve();
  private retryAfter: number = 0;
  private connectionIssue: string = '';
  private statusCallback?: (status: string) => void = undefined;
  private deliveredCallback?: (id: string) => void = undefined;
  private readonly supported: () => boolean;
  private readonly now: () => number;

  constructor(supported: () => boolean = (): boolean => canIUse('SystemCapability.Health.WearEngine'),
    now: () => number = Date.now) {
    this.supported = supported;
    this.now = now;
  }

  attach(context: common.UIAbilityContext, statusCallback: (status: string) => void,
    deliveredCallback: (id: string) => void): void {
    this.context = context;
    this.statusCallback = statusCallback;
    this.deliveredCallback = deliveredCallback;
    if (this.enabled) this.refresh();
  }

  restore(ids: string[]): void {
    this.delivered.clear();
    for (const id of ids.slice(0, MAX_DELIVERED_IDS)) {
      if (id) this.delivered.add(id);
    }
  }

  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
    if (enabled) {
      this.retryAfter = 0;
      this.refresh();
    } else {
      this.setStatus('');
    }
  }

  refresh(): void {
    this.work = this.work.then(async (): Promise<void> => {
      if (!this.enabled || !this.context) return;
      try {
        const devices = await this.connectedDevices();
        this.setStatus(devices.length ? 'ready' : (this.connectionIssue || 'none'));
      } catch (error) {
        this.reportError(error);
      }
    });
  }

  notify(reminder: WatchReminder): void {
    if (!this.enabled || this.delivered.has(reminder.id) || this.queued.has(reminder.id)) return;
    this.queued.add(reminder.id);
    this.work = this.work.then(async (): Promise<void> => {
      try {
        await this.deliver(reminder, false);
      } finally {
        this.queued.delete(reminder.id);
      }
    });
  }

  async test(): Promise<void> {
    if (!this.enabled) return;
    const id = `test:${this.now()}`;
    this.queued.add(id);
    this.work = this.work.then(async (): Promise<void> => {
      try {
        await this.deliver({ id: id, title: 'Pi Go · 测试提醒', text: 'Pi Go 手表提醒已开启' }, true);
      } finally {
        this.queued.delete(id);
      }
    });
    await this.work;
  }

  async flush(): Promise<void> {
    await this.work;
  }

  private async deliver(reminder: WatchReminder, force: boolean): Promise<void> {
    if (!this.enabled || !this.context || this.delivered.has(reminder.id)) return;
    if (!force && this.now() < this.retryAfter) return;
    try {
      const devices = await this.connectedDevices();
      if (!devices.length) {
        this.retryAfter = this.now() + RETRY_AFTER_MS;
        this.setStatus(this.connectionIssue || 'none');
        return;
      }
      const notifyClient = wearEngine.getNotifyClient(this.context);
      const options: wearEngine.NotificationOptions = {
        notification: {
          type: wearEngine.NotificationType.NOTIFICATION_WITHOUT_BUTTONS,
          bundleName: 'com.alex.pigo',
          title: reminder.title,
          text: reminder.text
        },
        onAction: (_feedback: wearEngine.NotificationFeedback): void => {}
      };
      let sent = false;
      let lastError: BusinessError | undefined = undefined;
      for (const device of devices) {
        try {
          await notifyClient.notify(device.randomId, options);
          sent = true;
        } catch (error) {
          lastError = error as BusinessError;
        }
      }
      if (!sent) throw lastError ?? new Error('watch_notification_failed');
      this.delivered.add(reminder.id);
      if (this.deliveredCallback) this.deliveredCallback(reminder.id);
      this.retryAfter = 0;
      this.setStatus('ready');
    } catch (error) {
      this.retryAfter = this.now() + RETRY_AFTER_MS;
      this.reportError(error);
    }
  }

  private async connectedDevices(): Promise<wearEngine.Device[]> {
    this.connectionIssue = '';
    if (!this.supported()) {
      this.connectionIssue = 'unsupported';
      return [];
    }
    if (!this.context) return [];
    const devices = await wearEngine.getDeviceClient(this.context).getConnectedDevices();
    const capable: wearEngine.Device[] = [];
    for (const device of devices) {
      try {
        if (await device.isWearEngineCapabilitySupported(wearEngine.WearEngineCapability.NOTIFICATION)) {
          capable.push(device);
        }
      } catch { /* Ignore a device that disappeared during the capability check. */ }
    }
    if (devices.length && !capable.length) this.connectionIssue = 'capability';
    return capable;
  }

  private reportError(error: BusinessError | Error): void {
    const code = (error as BusinessError).code;
    if (code === 801) this.setStatus('unsupported');
    else if (code === 1008500004) this.setStatus('service');
    else if (code === 1008500005 || code === 1008500006 || code === 1008500008 || code === 1008500009) {
      this.setStatus('account');
    } else if (code === 1008500002 || code === 1008500003) this.setStatus('none');
    else if (code === 1008500007) this.setStatus('capability');
    else this.setStatus('error');
    console.warn(`[PiGoWatch] notification failed, code=${code ?? 'unknown'}`);
  }

  private setStatus(status: string): void {
    if (this.statusCallback) this.statusCallback(status);
  }
}
