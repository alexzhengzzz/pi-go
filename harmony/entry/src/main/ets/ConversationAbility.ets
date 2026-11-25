import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { registerConversationWindow, takeConversationWindow, unregisterConversationWindow } from './ConversationWindowLaunch';
import { WINDOW_CONVERSATION_STORAGE, WindowConversation } from './model/WindowConversation';

export default class ConversationAbility extends UIAbility {
  private stage?: window.WindowStage;
  private conversation?: WindowConversation;

  onCreate(want: Want): void { this.accept(want); }

  onWindowStageCreate(stage: window.WindowStage): void {
    this.stage = stage;
    void this.load(stage);
  }

  onForeground(): void { this.conversation?.resume(); }
  onBackground(): void { this.conversation?.suspend(); }

  onDestroy(): void {
    if (this.conversation) unregisterConversationWindow(this.conversation);
    this.conversation?.dispose();
    this.conversation = undefined;
    this.stage = undefined;
  }

  private accept(want: Want): boolean {
    const key = want.parameters?.['conversationKey'];
    const next = typeof key === 'string' ? takeConversationWindow(key) : undefined;
    if (!next) return false;
    this.conversation = next;
    registerConversationWindow(next);
    next.bindClose((): void => { void this.context.terminateSelf(); });
    return true;
  }

  private async load(stage: window.WindowStage): Promise<void> {
    const conversation = this.conversation;
    if (!conversation) {
      await this.context.terminateSelf();
      return;
    }
    try {
      const storage = new LocalStorage();
      storage.setOrCreate(WINDOW_CONVERSATION_STORAGE, conversation);
      await stage.loadContent('pages/SessionWindow', storage);
      const main = await stage.getMainWindow();
      if (this.confirmSplit(main, conversation)) return;
      // Scene transitions can finish after the ability has loaded its content.
      setTimeout(() => {
        if (this.conversation !== conversation || this.stage !== stage) return;
        if (!this.confirmSplit(main, conversation)) {
          conversation.statusChanged('此设备当前无法开启系统分屏，可使用应用内分屏。');
          conversation.close();
        }
      }, 1200);
    } catch {
      conversation.statusChanged('暂时无法打开会话窗口。');
      conversation.close();
    }
  }
  private confirmSplit(main: window.Window, conversation: WindowConversation): boolean {
    try {
      if (main.getWindowStatus() !== window.WindowStatusType.SPLIT_SCREEN) return false;
    } catch { return false; }
    conversation.onSplitReady();
    return true;
  }

}
