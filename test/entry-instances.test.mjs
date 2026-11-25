import './harmony-modules.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const { EntryInstanceRegistry, isTargetedEntryLaunch } = await import(
  '../harmony/entry/src/main/ets/EntryInstanceRegistry.ets'
);

const WindowStatusType = {
  UNDEFINED: 0,
  FULL_SCREEN: 1,
  MAXIMIZE: 2,
  MINIMIZE: 3,
  FLOATING: 4,
  SPLIT_SCREEN: 5
};

const ICON_WANT = {
  abilityName: 'EntryAbility',
  action: 'ohos.want.action.home',
  entities: ['entity.system.home']
};

test('module.json5 configures EntryAbility as specified with MyAbilityStage', () => {
  const manifest = JSON.parse(
    readFileSync(new URL('../harmony/entry/src/main/module.json5', import.meta.url), 'utf8')
  );
  assert.equal(manifest.module.srcEntry, './ets/MyAbilityStage.ets');
  const entry = manifest.module.abilities.find((ability) => ability.name === 'EntryAbility');
  assert.ok(entry);
  assert.equal(entry.launchType, 'specified');
});

test('fullscreen instance allows only one instance on icon click', () => {
  const registry = new EntryInstanceRegistry();

  const firstKey = registry.acceptWant(ICON_WANT);
  assert.equal(firstKey, 'entry_1');
  assert.equal(registry.claimKey(), 'entry_1');
  registry.setWindowStatus('entry_1', WindowStatusType.FULL_SCREEN);
  registry.setForeground('entry_1', true);

  // Foreground fullscreen -> reuse existing instance.
  assert.equal(registry.acceptWant(ICON_WANT), 'entry_1');

  // Background fullscreen (user returned to home screen) -> still reuse.
  registry.setForeground('entry_1', false);
  assert.equal(registry.acceptWant(ICON_WANT), 'entry_1');
  assert.equal(registry.count(), 1);
});

test('foreground non-fullscreen instance allows opening new instances on icon click', () => {
  const registry = new EntryInstanceRegistry();

  const k1 = registry.acceptWant(ICON_WANT);
  assert.equal(registry.claimKey(), k1);
  registry.setWindowStatus(k1, WindowStatusType.FLOATING);
  registry.setForeground(k1, true);

  // One floating instance in foreground -> icon click creates a second instance.
  const k2 = registry.acceptWant(ICON_WANT);
  assert.equal(k2, 'entry_2');
  assert.equal(registry.claimKey(), k2);
  registry.setWindowStatus(k2, WindowStatusType.SPLIT_SCREEN);
  registry.setForeground(k2, true);

  // Another foreground non-fullscreen instance -> icon click creates a third instance.
  const k3 = registry.acceptWant(ICON_WANT);
  assert.equal(k3, 'entry_3');
  assert.equal(registry.claimKey(), k3);
  assert.equal(registry.count(), 3);
});

test('all backgrounded non-fullscreen instances resume the most recently active one', () => {
  const registry = new EntryInstanceRegistry();

  const k1 = registry.acceptWant(ICON_WANT);
  registry.claimKey();
  registry.setWindowStatus(k1, WindowStatusType.FLOATING);
  registry.setForeground(k1, true);

  const k2 = registry.acceptWant(ICON_WANT);
  registry.claimKey();
  registry.setWindowStatus(k2, WindowStatusType.FLOATING);
  registry.setForeground(k2, true);

  // Both move to background; k1 touched more recently.
  registry.setForeground(k2, false);
  registry.setForeground(k1, false);
  registry.touch(k1);

  assert.equal(registry.acceptWant(ICON_WANT), k1);
});

test('targeted external launches reuse an active instance instead of spawning a new window', () => {
  const registry = new EntryInstanceRegistry();
  const k1 = registry.acceptWant(ICON_WANT);
  registry.claimKey();
  registry.setWindowStatus(k1, WindowStatusType.FLOATING);
  registry.setForeground(k1, true);

  const shareWant = { abilityName: 'EntryAbility', action: 'ohos.want.action.sendData' };
  const formWant = {
    abilityName: 'EntryAbility',
    parameters: { 'ohos.extra.param.key.form_identity': 'form-1', params: '{}' }
  };
  const pushWant = {
    abilityName: 'EntryAbility',
    parameters: { pigoPushDevice: 'a'.repeat(64), pigoPushEvent: 'b'.repeat(32) }
  };
  const liveWant = {
    abilityName: 'EntryAbility',
    parameters: { pigoLiveSession: 'sess-1', pigoLiveAddress: 'http://127.0.0.1:18977' }
  };
  const ticketWant = {
    abilityName: 'EntryAbility',
    parameters: { ticket: '12345678' }
  };

  for (const want of [shareWant, formWant, pushWant, liveWant, ticketWant]) {
    assert.equal(isTargetedEntryLaunch(want), true);
    assert.equal(registry.acceptWant(want), k1);
  }
});

test('explicit pigoInstanceKey and unregister lifecycle work cleanly', () => {
  const registry = new EntryInstanceRegistry();
  const explicit = registry.acceptWant({
    abilityName: 'EntryAbility',
    parameters: { pigoInstanceKey: 'custom_window' }
  });
  assert.equal(explicit, 'custom_window');
  assert.equal(registry.claimKey(), 'custom_window');
  assert.equal(registry.count(), 1);

  registry.unregister('custom_window');
  assert.equal(registry.count(), 0);
});

test('SessionActions opens sessions via detached /session/open and falls back to /open on 404', async () => {
  const { SessionActions } = await import('../harmony/entry/src/main/ets/model/SessionActions.ets');
  const { SessionViewState } = await import('../harmony/entry/src/main/ets/model/StreamSyncController.ets');
  const { ChatState } = await import('../harmony/entry/src/main/ets/model/ChatState.ets');
  const { BridgeFailure } = await import('../harmony/entry/src/main/ets/model/PiGoTypes.ets');

  const makeActions = (handler) => {
    const session = new SessionViewState();
    session.syncMode = 'sequenced';
    const chatState = new ChatState();
    const streamSync = {
      draftKey: (id) => `http://127.0.0.1:18977|${id}`,
      cacheChat: () => {},
      cancelSchedule: () => {},
      stopStream: () => {},
      presentChat: () => {},
      applySessionSnapshot: (reply) => {
        session.currentId = reply.session.id;
        session.workspaceCwd = reply.session.cwd;
        return true;
      },
      applySessionHistory: () => {},
      revealChat: () => {},
      startStream: () => {},
      schedule: () => {},
      requestSessionSnapshot: async () => ({
        session: { id: 's2', cwd: '/repo', idle: true },
        cursor: { streamId: 'st2', seq: 1 },
        messages: []
      })
    };
    const actions = new SessionActions({
      session,
      streamSync,
      chatState: () => chatState,
      request: handler,
      leaveComputer: () => {},
      observeSessionRun: () => {},
      setInteraction: () => {},
      syncCommandPalette: () => {},
      getUIContext: () => ({}),
      accent: () => '#000',
      resetVoice: () => {},
      revealSessionDrawer: () => {},
      showSessions: () => false,
      invalidateCatalog: () => {},
      refreshExpandedSpace: () => {},
      catalogConnection: () => 1,
      canCreateWorkspace: () => true,
      canCreateSession: () => true,
      closeNewSession: () => {},
      closeNewSpace: () => {},
      openNewSession: () => {},
      loadSessions: async () => {},
      addWorkspace: () => {},
      showTasks: () => {},
      animateSend: () => {},
      uploadAttachment: async () => ({ id: 'u1', kind: 'file', name: 'a.txt', size: 1 })
    });
    return { actions, session };
  };

  // Modern broker: uses /session/open directly without touching global selection.
  const calls = [];
  const modern = makeActions(async (path, input) => {
    calls.push({ path, input });
    return {
      session: { id: input.id, cwd: '/repo/a', idle: true },
      cursor: { streamId: 'st1', seq: 1 },
      messages: []
    };
  });
  assert.equal(await modern.actions.requestAction('/open', { id: 's1' }), true);
  assert.deepEqual(calls.map((c) => c.path), ['/session/open']);
  assert.equal(modern.session.currentId, 's1');

  // Legacy broker (404 on /session/open): falls back cleanly to /open.
  const fallbackCalls = [];
  const legacy = makeActions(async (path, input) => {
    fallbackCalls.push(path);
    if (path === '/session/open') throw new BridgeFailure(404, 'not_found');
    return {
      session: { id: input.id, cwd: '/repo/b', idle: true },
      cursor: { streamId: 'st2', seq: 1 },
      messages: []
    };
  });
  assert.equal(await legacy.actions.requestAction('/open', { id: 's2' }), true);
  assert.deepEqual(fallbackCalls, ['/session/open', '/open']);
  assert.equal(legacy.session.currentId, 's2');
});
