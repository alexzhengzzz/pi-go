import { util } from '@kit.ArkTS';
import type { WindowConversation } from './model/WindowConversation';

const pending: Map<string, WindowConversation> = new Map();
const active: Set<WindowConversation> = new Set();

export function prepareConversationWindow(conversation: WindowConversation): string {
  const key = util.generateRandomUUID();
  pending.set(key, conversation);
  return key;
}

export function takeConversationWindow(key: string): WindowConversation | undefined {
  const conversation = pending.get(key);
  pending.delete(key);
  return conversation;
}

export function registerConversationWindow(conversation: WindowConversation): void {
  active.add(conversation);
}

export function unregisterConversationWindow(conversation: WindowConversation): void {
  active.delete(conversation);
}

export function findConversationWindow(address: string, id: string): WindowConversation | undefined {
  for (const conversation of active) {
    if (conversation.endpoint.address === address && conversation.id === id) return conversation;
  }
  for (const conversation of pending.values()) {
    if (conversation.endpoint.address === address && conversation.id === id) return conversation;
  }
  return undefined;
}

export function closeConversationWindows(): void {
  pending.forEach((conversation: WindowConversation): void => conversation.dispose());
  pending.clear();
  active.forEach((conversation: WindowConversation): void => conversation.close());
}
