import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import './harmony-modules.mjs';
import { harmonyFile } from './harmony-source.mjs';
const { computerGroupId, computerGroups, computerGroupTitle, moveComputerConnection, renameComputerGroup } = await import('../harmony/entry/src/main/ets/ComputerGroups.ets');
const { connectionLabel, validCompanion } = await import('../harmony/entry/src/main/ets/CompanionCheck.ets');
const { SessionActions } = await import('../harmony/entry/src/main/ets/model/SessionActions.ets');
const { SessionViewState, StreamSyncController } = await import('../harmony/entry/src/main/ets/model/StreamSyncController.ets');
const { PiGoClient } = await import('../harmony/entry/src/main/ets/model/PiGoClient.ets');
const { buildWidgetSnapshot } = await import('../harmony/entry/src/main/ets/InboxWidget.ets');
const { RunCenterController } = await import('../harmony/entry/src/main/ets/model/RunCenterController.ets');
const { ScheduleController } = await import('../harmony/entry/src/main/ets/model/ScheduleController.ets');
const { WorkspaceFileController } = await import('../harmony/entry/src/main/ets/model/WorkspaceFileController.ets');
const { SidebarRows } = await import('../harmony/entry/src/main/ets/model/SidebarRows.ets');
const { BridgeFailure } = await import('../harmony/entry/src/main/ets/model/PiGoTypes.ets');
const { ChatState } = await import('../harmony/entry/src/main/ets/model/ChatState.ets');
const { ConnectionManager } = await import('../harmony/entry/src/main/ets/model/ConnectionManager.ets');
const { SessionStore, workspaceName } = await import('../harmony/entry/src/main/ets/model/SessionStore.ets');
const { SPLIT_WINDOW_WIDTH, LIVE_VIEW_SETTING } = await import('../harmony/entry/src/main/ets/model/PiGoConstants.ets');

// These cases cover page orchestration across the imported stores and ArkUI callbacks.
const page = harmonyFile('model/PiGoPageStore.ets');
function method(name) {
  const start = page.search(new RegExp(`\\n  (?:private )?(?:async )?${name}\\(`));
  assert.ok(start >= 0, `Missing page method: ${name}`);
  const end = page.indexOf('\n  }', start + 1) + 4;
  return page.slice(start + 1, end);
}
const { runNotificationText } = await import('../harmony/entry/src/main/ets/RunResults.ets');
const methods = ['setDrawer', 'swipeDrawer', 'loadSessions', 'applyCatalog', 'positionTranscript', 'loadSessionStatus', 'applyRunningStatus',
  'backgroundRunning', 'backgroundActive', 'sessionState', 'sessionRunning', 'toggleSpace', 'updateSidebarRows', 'revealLibraryAnchor',
  'appendSessionPage', 'setWorkspacePage', 'loadWorkspacePage', 'resetCatalog',
  'chooseComputer', 'leaveComputer', 'persistComputers', 'pair', 'workspaceName', 'openNewSpace', 'closeNewSpace',
  'openNewSession', 'closeNewSession', 'defaultNewSessionAgent', 'canCreateSession', 'onInboxFormLaunch', 'confirmCloseSpace',
  'closeWorkspace', 'armTranscriptFollow', 'onKeyboardChange', 'dockedSessions', 'sessionPaneWidth', 'compactSessionPane',
  'onWindowWidthChange', 'chatTitle', 'updateCachedSessionTitle', 'observeSessionRun', 'restoreSettings', 'saveSetting',
  'setLiveViewsEnabled', 'canSwitchNetwork', 'tryPublicConnection', 'refreshVisibleCatalog', 'sessionDeleted',
  'streamSyncHost', 'sessionActionsHost'];
const liveViewCalls = [];
const liveActivity = { sync: snapshot => liveViewCalls.push(snapshot) };
const phoneNotifications = [];
globalThis.pigoTestNotifications = phoneNotifications;
const Page = new Function('Curve', 'BridgeFailure', 'validUsb', 'Edge', '$r', 'DialogAlignment',
  'openSettings', 'themeStyle', 'appearanceMode', 'liveActivity', 'util', 'SPLIT_WINDOW_WIDTH',
  'LIVE_VIEW_SETTING', 'THEME_MOTION_SETTING', 'workspaceName', 'computerGroupId', 'connectionLabel', 'validCompanion',
  stripTypeScriptTypes(`class Harness {\n${methods.map(method).join('\n')}\n}`) + '; return Harness;')(
  { EaseOut: 0 },
  BridgeFailure,
  (address) => address === 'http://127.0.0.1:18977',
  { Bottom: 'bottom' },
  resource => resource,
  { Bottom: 'bottom' },
  (context) => context.settings,
  (id) => ({ id }),
  (id) => ({ id }),
  liveActivity,
  { generateRandomUUID: randomUUID },
  SPLIT_WINDOW_WIDTH, LIVE_VIEW_SETTING, 'theme_motion_enabled', workspaceName, computerGroupId, connectionLabel, validCompanion
);
// Existing scenarios describe page and transport state together. Wire the real
// controllers through the page's ports and allow scenarios to override their methods.
function expose(target, owner, keys = Object.keys(owner)) {
  for (const key of keys) {
    Object.defineProperty(target, key, {
      get() {
        const value = owner[key];
        return typeof value === 'function' ? value.bind(owner) : value;
      },
      set(value) { owner[key] = value; }
    });
  }
}

function fixture() {
  const state = new Page();
  state.session = new SessionViewState();
  state.appState = {};
  state.streamSync = new StreamSyncController(state.streamSyncHost());
  state.sessionActions = new SessionActions(state.sessionActionsHost());
  expose(state, state.session);
  expose(state, state.sessionActions.creation);
  expose(state, state.streamSync, ['streamAlive', 'streamGen', 'historyRequest', 'poll', 'startStream', 'stopStream',
    'schedule', 'cancelSchedule', 'scheduleStream', 'handleFrame', 'streamDown', 'applyStreamFrame', 'flushStreamDeltas',
    'queueStreamPaint', 'requestSessionSnapshot', 'applySessionSnapshot', 'refreshSessionHistory', 'applySessionHistory',
    'applyLiveSnapshot', 'mergeTranscript', 'syncLiveActivity', 'backgroundLiveActivity', 'trackDispatchedLiveRun',
    'draftKey', 'rememberDraft', 'applySession', 'cacheChat', 'presentChat', 'revealChat']);
  expose(state, state.sessionActions, ['requestAction', 'send', 'finishSend', 'reconcileSteering', 'forkAndContinue',
    'promptForkAndContinue', 'uploadAttachment', 'createSession', 'createWorkspaceTask']);
  Object.assign(state, {
    sidebarRows: new SidebarRows(), chatState: new ChatState(), connection: new ConnectionManager(),
    sessionStore: new SessionStore(), client: new PiGoClient(),
    voiceComposer: { state: {}, resetVoice() {}, stopReplySpeech() {} },
    split: {
      state: { splitOpen: false, splitNavigating: false, focusedPaneFirst: true, otherId: '', otherTitle: '', otherSession: new SessionViewState() },
      openingNativeWindow: false, launchedNativeWindow: false, pendingFocusedPosition: '', pendingOtherPosition: '',
      clearSplit() {}, restoreSplitPosition: () => false, mainPaneWidth: (s) => Math.max(0, (state.appState?.windowWidth ?? 0) - s)
    },
    toolCmd: {
      state: { showToolDetails: false, selectedTool: undefined, selectedToolDetails: undefined, toolDetailError: '',
        commandRows: [], commandPalette: false, commandsLoading: false, commandError: '', showComposerMenu: false, showSkillPicker: false, showModelMenu: false,
        sakuraBurstSeq: 0, sakuraBurstKind: 'send', sakuraBloomSeq: 0, sakuraBloomX: 0, sakuraBloomY: 0, sakuraGirlTapSeq: 0, sakuraCelebrateSeq: 0 },
      selectedToolMessageId: '',
      resetCommands() {}, syncCommandPalette() {}, closeToolDetails() {}, refreshSelectedTool() {}
    },
    resetCommands: () => {}, syncCommandPalette: () => {},
    tryPublicConnection: async () => {},
    scheduleEndpoint: (item) => item, scheduleComputerName: () => 'Desktop',
    accountSync: { state: {} },
    syncMode: 'legacy', busy: false, sessionLoading: false, epoch: 1, reachable: true,
    runningSessionIds: [], runningSessions: [], sessionStatusAt: 0, currentId: '', idle: true, queued: false,
    messages: [],
    settingsWrite: Promise.resolve(), liveViewsEnabled: true, liveViewSessionKey: '', liveViewRunId: '', syncLiveActivity: () => {},
    liveText: '', liveThinking: '', liveThinkSeq: 0, liveThinkingOpen: false, thinkingOpenIds: [],
    liveTools: [], liveSeq: 0, liveRevision: 0, streamAlive: false, queuedSteering: [],
    sessionCatalogLoaded: true, sessionCatalogUpdatedAt: Date.now(), sessionCatalogVersion: 0, catalogConnection: 0,
    workspacePageRequestId: 0, workspacePages: [], workspaces: [], agents: [],
    sessions: [{ id: 'one', cwd: '/project', name: 'Cached task' }], projects: ['/project'],
    sessionView: 'all', loadedView: 'all', expandedSpaces: [], scheduleSidebarSave: () => {},
    showSessions: false,
    draftKey: id => id, loadSessionStatus: async () => {}, dismissKeyboard: () => {},
    getUIContext: () => ({ animateTo: (_options, change) => change(),
      getPromptAction: () => ({ showToast: () => {} }) })
  });
  state.fileController = new WorkspaceFileController({
    busy: () => state.busy,
    setBusy: (value) => { state.busy = value; },
    openingSession: () => state.openingSession,
    epoch: () => state.epoch,
    request: (...args) => state.request(...args),
    setStatus: (status) => { state.status = status; }
  });
  state.runCenter = new RunCenterController({
    visible: () => state.visible,
    currentId: () => state.currentId,
    base: () => state.base,
    computers: () => state.computers,
    isPaired: () => state.isPaired,
    reachable: () => state.reachable,
    workspaceCwd: () => state.workspaceCwd,
    draftKey: (id) => state.draftKey(id),
    endpoint: () => state.connection.endpoint(),
    scheduleEndpoint: (item) => state.scheduleEndpoint(item),
    scheduleComputerName: (item) => state.scheduleComputerName(item),
    request: (...args) => state.request(...args),
    saveSetting: (...args) => state.saveSetting(...args),
    getUIContext: () => state.getUIContext(),
    publishWidgets() {},
    celebrate: () => {
      state.sakuraBurstKind = 'celebrate';
      state.sakuraBurstSeq += 1;
      if (state.themeId === 'sakura') state.sakuraCelebrateSeq += 1;
    },
  });
  state.runCenter.queueRunSync = () => {};
  state.scheduleController = new ScheduleController({
    loading: () => state.loading,
    isPaired: () => state.isPaired,
    closeReviewOverlays() {},
    selectRootTab: (tab) => state.selectRootTab(tab),
    openNewSession: () => state.openNewSession(),
    visible: () => state.visible,
    base: () => state.base,
    computers: () => state.computers,
    settings: () => state.settings,
    scheduleEndpoint: (item) => state.scheduleEndpoint(item),
    request: (...args) => state.request(...args),
    saveSetting: (...args) => state.saveSetting(...args),
    getUIContext: () => state.getUIContext(),
    publishWidgets() {},
  });
  state.scheduleController.queueScheduleSync = () => {};
  return state;
}

test('inbox cleanup survives restart and polling while keeping pending and new runs', async () => {
  const computer = { address: 'https://desktop', token: 'token' };
  const events = [
    { id: 'removed', status: 'completed' },
    { id: 'pending', status: 'waiting' },
    { id: 'kept', status: 'failed' },
  ];
  const values = new Map();
  const settings = {
    getSync: (key, fallback) => values.get(key) ?? fallback,
    putSync: (key, value) => values.set(key, value),
    flush: async () => {},
  };
  function restoredPage() {
    const state = fixture();
    Object.assign(state, {
      computers: [computer], visible: true,
      request: async () => ({ runEvents: events }),
      getUIContext: () => ({ getHostContext: () => ({ settings }) }),
    });
    state.restoreSettings();
    return state;
  }
  const state = restoredPage();
  await state.runCenter.syncRunInbox(computer);
  assert.equal(await state.runCenter.dismissInboxRuns(['removed', 'pending']), true);
  assert.deepEqual(state.runCenter.state.inboxRuns.map(({ run }) => run.id), ['pending', 'kept']);
  events.push({ id: 'new', status: 'completed' });
  const restarted = restoredPage();
  await restarted.runCenter.syncRunInbox(computer);
  assert.deepEqual(restarted.runCenter.state.inboxRuns.map(({ run }) => run.id), ['pending', 'kept', 'new']);
  assert.equal(restarted.runCenter.state.inboxRuns[0].unread, true);
});

test('inbox aggregates recent runs by sessionId per computer and dismisses earlier runs of the same session', async () => {
  const lan = { address: 'https://lan', token: 'token-1', computerId: 'mac-a' };
  const remote = { address: 'https://remote', token: 'token-2', computerId: 'mac-a' };
  const other = { address: 'https://other', token: 'token-3', computerId: 'mac-b' };
  const values = new Map();
  const settings = {
    getSync: (key, fallback) => values.get(key) ?? fallback,
    putSync: (key, value) => values.set(key, value),
    flush: async () => {},
  };
  const state = fixture();
  Object.assign(state, {
    base: lan.address,
    computers: [lan, remote, other],
    settings,
  });
  state.runCenter.state.inboxRuns = [
      { run: { id: 's1-old', sessionId: 'sess-1', status: 'completed', finishedAt: 100 }, address: lan.address, computer: 'Mac A', unread: true },
      { run: { id: 's1-new', sessionId: 'sess-1', status: 'failed', finishedAt: 300 }, address: remote.address, computer: 'Mac A', unread: true },
      { run: { id: 's1-new', sessionId: 'sess-1', status: 'failed', finishedAt: 300 }, address: lan.address, computer: 'Mac A', unread: true },
      { run: { id: 's1-wait', sessionId: 'sess-1', status: 'waiting', finishedAt: 200 }, address: lan.address, computer: 'Mac A', unread: true },
      { run: { id: 's2-only', sessionId: 'sess-2', status: 'completed', finishedAt: 250 }, address: lan.address, computer: 'Mac A', unread: false },
      { run: { id: 'other-s1', sessionId: 'sess-1', status: 'completed', finishedAt: 150 }, address: other.address, computer: 'Mac B', unread: true },
  ];

  const displayed = state.runCenter.displayedInboxRuns();
  assert.deepEqual(
    displayed.map(({ run, address }) => ({ id: run.id, address })),
    [
      { id: 's1-wait', address: lan.address },
      { id: 's1-new', address: lan.address },
      { id: 's2-only', address: lan.address },
      { id: 'other-s1', address: other.address },
    ],
  );

  // Dismissing the aggregated latest run of sess-1 on Mac A also dismisses older runs of sess-1 on Mac A,
  // while keeping its waiting item and sess-1 on Mac B intact.
  assert.equal(await state.runCenter.dismissInboxRuns(['s1-new']), true);
  assert.deepEqual(
    state.runCenter.displayedInboxRuns().map(({ run, address }) => ({ id: run.id, address })),
    [
      { id: 's1-wait', address: lan.address },
      { id: 's2-only', address: lan.address },
      { id: 'other-s1', address: other.address },
    ],
  );
  assert.equal(state.runCenter.dismissedInboxRuns.has('s1-old'), true);
  assert.equal(state.runCenter.dismissedInboxRuns.has('s1-new'), true);
  assert.equal(state.runCenter.dismissedInboxRuns.has('other-s1'), false);
});

test('widgets prioritize approvals and exclude dismissed runs without duplicating a running session', () => {
  const address = 'https://desktop';
  const run = (id, sessionId, status) => ({
    address, computer: 'Mac', unread: true, run: { id, sessionId, status, finishedAt: 100 }
  });
  const schedule = (id, dismissed) => ({
    key: `desktop:${id}`, address, computer: 'Mac', unread: true, dismissed,
    run: { id, name: id, status: 'completed', finishedAt: 100 }
  });
  const snapshot = buildWidgetSnapshot({
    inbox: [run('pending', 'one', 'waiting'), run('completed', 'three', 'completed')],
    scheduleMessages: [schedule('visible', false), schedule('dismissed', true)],
    jobs: [{ name: 'nightly', enabled: true, nextAt: 100 }, { name: 'paused', enabled: false, nextAt: 100 }],
    runningRows: [{ id: 'one', name: 'Pending task' }, { id: 'two', name: 'Running task' }],
    activeSchedules: [],
    running: 2,
    address,
    computer: 'Mac',
    pairedComputer: 'Mac',
    sessionState: () => 'streaming',
    stateLabel: () => '运行中'
  });
  assert.equal(snapshot.pending, 1);
  assert.equal(snapshot.unread, 3);
  assert.equal(snapshot.scheduleCount, 1);
  assert.equal(snapshot.nextScheduleName, 'nightly');
  assert.deepEqual(snapshot.items.map(({ id }) => id), ['pending', 'two', 'completed', 'visible']);
  assert.deepEqual(snapshot.scheduleItems.map(({ id }) => id), ['visible']);
});

test('background inbox polls publish one system notification per new terminal event', async () => {
  const computer = { address: 'https://desktop', token: 'token', computerName: '工作 Mac' };
  const since = Date.now();
  const events = [
    { id: 'old', status: 'completed', finishedAt: since - 1 },
    { id: 'waiting', status: 'waiting', finishedAt: since },
    { id: 'run-1', status: 'completed', finishedAt: since, title: '修复\n通知同步', cwd: '/private/dev/pi-go' },
    { id: 'run-2', status: 'failed', finishedAt: since + 1, title: '生成报表', cwd: '/private/dev/dashboard/' },
  ];
  const state = fixture();
  Object.assign(state, {
    computers: [computer], visible: false,
    request: async () => ({ runEvents: events }),
  });
  state.runCenter.backgroundRunNoticesSince = since;
  phoneNotifications.length = 0;
  await Promise.all([state.runCenter.syncRunInbox(computer), state.runCenter.syncRunInbox(computer)]);
  assert.deepEqual(phoneNotifications.map(request => request.content.normal), [
    { title: 'OK', text: '修复 通知同步' },
    { title: '运行失败', text: '生成报表' },
  ]);
  assert.equal(new Set(phoneNotifications.map(request => request.appMessageId)).size, 2);
  state.visible = true;
  events.push({ id: 'foreground', status: 'completed', finishedAt: since + 2 });
  await state.runCenter.syncRunInbox(computer);
  assert.equal(phoneNotifications.length, 2);
});

test('notification text shortens long titles without splitting Unicode characters', () => {
  assert.equal(runNotificationText('🚀'.repeat(70)), `${'🚀'.repeat(63)}…`);
  assert.equal(runNotificationText(' '), '未命名任务');
});

test('watch reminders accept only recent events and persist delivery ids', async () => {
  const state = fixture();
  const reminders = [];
  const writes = [];
  state.runCenter.watchReminders = { notify: reminder => reminders.push(reminder) };
  state.saveSetting = async (key, value) => writes.push([key, value]);
  state.runCenter.queueWatchReminder('inbox:new', '已完成', 'Mac', 'Build Pi Go', Date.now());
  state.runCenter.queueWatchReminder('inbox:old', '已完成', 'Mac', 'Old run', Date.now() - 6 * 60 * 1000);
  assert.equal(reminders.length, 1);
  assert.deepEqual(reminders[0], {
    id: 'inbox:new', title: 'Pi Go · 已完成', text: '已完成 · Mac\nBuild Pi Go'
  });
  await state.runCenter.rememberWatchReminder('inbox:new');
  assert.deepEqual(state.runCenter.watchReminderDelivered, ['inbox:new']);
  assert.deepEqual(writes, [['watch_reminder_delivered', '["inbox:new"]']]);
});

test('bulk history deletion removes successes and retains records the computer refused to delete', async () => {
  const state = fixture();
  const computer = { address: 'https://desktop' };
  const messages = ['first', 'blocked', 'last'].map(id => ({
    key: `source:${id}`, source: 'source', run: { id, cwd: '/project' },
  }));
  const calls = [];
  const toasts = [];
  let syncs = 0;
  Object.assign(state, {
    base: computer.address, computers: [computer],
    getUIContext: () => ({ getPromptAction: () => ({ showToast: ({ message }) => toasts.push(message) }) }),
    request: async (path, payload, endpoint) => {
      assert.equal(path, '/schedules/update');
      assert.equal(endpoint, computer);
      assert.equal(payload.operation, 'delete-run');
      assert.equal(payload.cwd, '/project');
      calls.push(payload.id);
      if (payload.id === 'blocked') throw new BridgeFailure(403, 'desktop_workspace_unshared');
    },
  });
  state.scheduleController.state.scheduleMessages = messages;
  state.scheduleController.queueScheduleSync = () => { syncs += 1; };
  assert.equal(await state.scheduleController.deleteScheduleRuns(messages), false);
  assert.deepEqual(calls, ['first', 'blocked', 'last']);
  assert.deepEqual(state.scheduleController.state.scheduleMessages, [messages[1]]);
  assert.match(toasts[0], /已删除 2 条/);
  assert.equal(state.scheduleController.scheduleMutation, 2);
  assert.equal(state.scheduleController.state.scheduleSaving, false);
  assert.equal(syncs, 1);
});

test('the network watcher tracks available and lost events and releases a late registration', () => {
  const manager = new ConnectionManager();
  const monitors = [];
  const createNetConnection = () => {
    const events = new Map();
    const monitor = {
      events,
      on: (event, callback) => events.set(event, callback),
      register(callback) { this.complete = callback; },
      unregister() { this.unregistered = true; }
    };
    monitors.push(monitor);
    return monitor;
  };
  globalThis.pigoTestNetwork = { createNetConnection };
  let changes = 0;
  try {
    manager.watchNetwork(() => { changes += 1; });
    manager.stopWatchingNetwork();
    manager.watchNetwork(() => { changes += 1; });
    monitors[0].complete();
    assert.equal(monitors[0].unregistered, true);
    monitors[0].events.get('netLost')();
    monitors[1].complete();
    monitors[1].events.get('netAvailable')();
    monitors[1].events.get('netLost')();
    manager.stopWatchingNetwork();
    monitors[1].events.get('netAvailable')();
    assert.equal(changes, 2);
    assert.equal(monitors[1].unregistered, true);
  } finally {
    delete globalThis.pigoTestNetwork;
  }
});

test('public fallback reopens the same session with its draft using a paired connection in the same group', async () => {
  const state = fixture();
  const credentials = {
    token: 'a'.repeat(64),
    ca: '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----',
    pin: 'A'.repeat(43) + '='
  };
  const lan = { ...credentials, address: 'https://192.168.1.5:18981', computerId: 'mac' };
  const remote = { ...credentials, address: 'https://93.184.216.34:8443', computerId: 'mac' };
  const unrelated = { ...remote, address: 'https://93.184.216.35:8443', computerId: 'other' };
  const attachment = { kind: 'file', name: 'log.txt' };
  const calls = [];
  Object.assign(state, {
    computers: [lan, unrelated, remote], base: lan.address, visible: true, isPaired: true,
    reachable: false, activeTab: 'tasks', currentId: 'one', draft: 'keep this', attachments: [attachment],
    lastNetworkFailover: 0, tryPublicConnection: Page.prototype.tryPublicConnection,
    draftKey: (id) => `${state.base}|${id}`,
    scheduleEndpoint: computer => computer,
    request: async (path, _input, endpoint) => {
      calls.push([path, endpoint.address]);
      return { session: { id: 'other-session' } };
    },
    leaveComputer(_revoked, next) {
      assert.equal(next, remote);
      this.chatState.drafts.set(this.draftKey(this.currentId), this.draft);
      this.chatState.draftAttachments.set(this.draftKey(this.currentId), this.attachments);
      this.base = next.address;
    },
    requestAction: async (path, input) => {
      calls.push([path, input.id]);
      assert.equal(state.chatState.drafts.get(state.draftKey(input.id)), 'keep this');
      assert.deepEqual(state.chatState.draftAttachments.get(state.draftKey(input.id)), [attachment]);
    }
  });
  await state.tryPublicConnection();
  assert.deepEqual(calls, [['/session', remote.address], ['/open', 'one']]);
  assert.equal(state.chatState.drafts.has(`${lan.address}|one`), false);
  assert.equal(state.chatState.draftAttachments.has(`${lan.address}|one`), false);
});

test('editor keyboard events leave the hidden chat transcript alone', () => {
  const state = fixture();
  Object.assign(state, {
    keyboardHeight: 300, transcriptFollow: false,
    transcript: { currentOffset() { assert.fail('editor keyboard queried the chat scroller'); } }
  });
  state.fileController.state.editingPath = 'aa.md';
  for (const activeTab of ['files', 'tasks']) {
    state.activeTab = activeTab;
    state.showFiles = activeTab === 'files';
    state.onKeyboardChange();
  }
  assert.equal(state.transcriptFollow, false);
});

test('chat keyboard events handle an unmounted scroller and preserve scroll-follow behavior', () => {
  const state = fixture();
  const positions = [];
  let offset;
  Object.assign(state, {
    activeTab: 'tasks', keyboardHeight: 300, transcriptViewport: 200, transcriptContentHeight: 500,
    transcriptFollow: false,
    transcript: { currentOffset: () => offset, scrollEdge: (edge) => positions.push(edge) }
  });
  state.onKeyboardChange();
  assert.equal(state.transcriptFollow, false);
  offset = { yOffset: 290 };
  state.onKeyboardChange();
  assert.equal(state.transcriptFollow, true);
  offset = { yOffset: 20 };
  state.onKeyboardChange();
  assert.equal(state.transcriptFollow, false);
  assert.deepEqual(positions, ['bottom']);
});

test('adding a USB computer does not use or replace the active TLS connection when pairing fails', async () => {
  const state = fixture();
  const active = { address: 'https://192.168.1.99:18981', ca: 'active-ca', pin: 'active-pin', token: 'active-token' };
  const usbAddress = 'http://127.0.0.1:18977';
  const requests = [];
  Object.assign(state, {
    base: active.address, ca: active.ca, pin: active.pin, token: active.token, isPaired: true,
    computers: [active], address: usbAddress, pairingMode: 'usb', ticket: '12345678',
    request: async (...args) => { requests.push(args); throw new Error('offline'); },
    leaveComputer: () => assert.fail('A failed pairing must preserve the active computer')
  });
  state.connection.activate(active);
  await state.pair();
  assert.deepEqual(requests, [['/pair', { ticket: '12345678' },
    { address: usbAddress, token: '' }]]);
  assert.equal(state.base, active.address);
  assert.deepEqual(state.connection.endpoint(), active);
  assert.deepEqual(state.computers, [active]);
  assert.equal(state.busy, false);
});

test('selecting a saved computer while connected switches once and retains both credentials', async () => {
  const state = fixture();
  const lan = { address: 'https://192.168.1.99:18981', token: 'lan' };
  const remote = { address: 'https://93.184.216.34:8443', token: 'remote' };
  const remembered = [], saves = [];
  Object.assign(state, {
    base: remote.address, isPaired: true, computers: [remote, lan], currentId: 'remote-session',
    rememberDraft: (id) => remembered.push([state.base, id]),
    cancelSchedule: () => {}, stopStream: () => {}, closeToolDetails: () => {}, flushSidebarSave: () => {},
    setInteraction: () => {},
    activateComputer: (record) => {
      assert.equal(state.currentId, '');
      state.base = record.address;
      state.isPaired = true;
    },
    vault: { save: async (book) => { saves.push(book); } }
  });
  state.chooseComputer(lan);
  assert.equal(state.base, lan.address);
  assert.deepEqual(remembered, [[remote.address, 'remote-session']]);
  assert.deepEqual(saves, [{ version: 2, active: lan.address, computers: [remote, lan] }]);
});

test('grouping connections keeps computers on the same public IP distinct', () => {
  const laptop = { address: 'https://93.184.216.34:8443', token: 'laptop', computerId: 'a' };
  const mini = { address: 'https://93.184.216.34:8444', token: 'mini', computerId: 'b', computerName: 'Mac mini' };
  const usb = { address: 'http://127.0.0.1:18977', token: 'usb', computerId: 'c' };
  assert.deepEqual(computerGroups([laptop, mini, usb]).map(computerGroupTitle),
    ['93.184.216.34:8443', 'Mac mini', 'USB 电脑']);
  const grouped = moveComputerConnection([laptop, mini, usb], usb.address, 'a', '');
  const renamed = renameComputerGroup(grouped, 'a', ' 本机 ');
  assert.deepEqual(computerGroups(renamed).map(group => [computerGroupTitle(group), group.connections.map(row => row.token)]),
    [['本机', ['laptop', 'usb']], ['Mac mini', ['mini']]]);
  const separated = moveComputerConnection(renamed, laptop.address, 'd', '');
  assert.deepEqual(computerGroups(separated).map(group => [computerGroupTitle(group), group.connections.map(row => row.token)]),
    [['93.184.216.34:8443', ['laptop']], ['Mac mini', ['mini']], ['本机', ['usb']]]);
});

test('pairing a new connection uses the chosen group and re-pairing preserves its existing group', async () => {
  const state = fixture();
  const laptop = { address: 'https://93.184.216.34:8443', token: 'laptop', computerId: 'a', computerName: '本机' };
  const usb = 'http://127.0.0.1:18977';
  const saved = [];
  Object.assign(state, {
    computers: [laptop], address: usb, pairingComputerId: 'a', pairingMode: 'usb', ticket: '12345678',
    request: async () => ({ token: 'a'.repeat(64) }), forgetDrafts: () => {},
    activateComputer: record => { state.base = record.address; state.isPaired = true; },
    vault: { save: async book => { saved.push(book); } }
  });
  await state.pair();
  assert.equal(state.computers[0].computerId, 'a');
  assert.equal(state.computers[0].computerName, '本机');
  assert.equal(saved[0].computers.length, 2);
  state.isPaired = false;
  state.pairingComputerId = 'different';
  await state.pair();
  assert.deepEqual(computerGroups(state.computers).map(group => group.id), ['a']);
});

test('reopening the sidebar uses the fresh catalog without another request', () => {
  const state = fixture();
  let requests = 0;
  state.request = async () => { requests++; return { sessions: [] }; };
  state.setDrawer(true);
  assert.equal(state.showSessions, true);
  assert.equal(requests, 0);
  assert.equal(state.busy, false);
  assert.equal(state.sessions[0].id, 'one');
});

test('an open drawer docks on unfold and folding back reveals the same conversation', () => {
  const state = fixture();
  Object.assign(state, { windowWidth: 459, isPaired: true, activeTab: 'tasks', currentId: 'one', draft: 'Keep this' });
  state.setDrawer(true);
  assert.equal(state.showSessions, true);
  assert.equal(state.dockedSessions(), false);

  state.windowWidth = 711;
  state.onWindowWidthChange();
  assert.equal(state.dockedSessions(), true);
  assert.equal(state.showSessions, false);
  assert.ok(711 - state.sessionPaneWidth() >= 460);
  state.setDrawer(true);
  assert.equal(state.showSessions, false);

  state.windowWidth = 939;
  state.onWindowWidthChange();
  assert.equal(state.dockedSessions(), true);
  assert.ok(state.sessionPaneWidth() <= 288);

  state.windowWidth = 459;
  state.onWindowWidthChange();
  assert.equal(state.dockedSessions(), false);
  assert.equal(state.showSessions, false);
  assert.equal(state.currentId, 'one');
  assert.equal(state.draft, 'Keep this');
});

test('the sidebar can be swiped open and docked across all root tabs including files and mine', () => {
  const state = fixture();
  let fileBackCalls = 0;
  Object.assign(state, {
    windowWidth: 459,
    isPaired: true,
    fileBack: () => { fileBackCalls += 1; }
  });
  const swipeRight = { offsetX: 80, offsetY: 5 };
  const swipeLeft = { offsetX: -80, offsetY: 5 };

  for (const tab of ['tasks', 'pending', 'files', 'mine']) {
    state.activeTab = tab;
    state.showFiles = tab === 'files';
    state.minePage = '';
    state.showSettings = false;
    state.showSessions = false;

    state.swipeDrawer(swipeRight);
    assert.equal(state.showSessions, true, `swipe right should open sidebar on ${tab}`);
    state.swipeDrawer(swipeLeft);
    assert.equal(state.showSessions, false, `swipe left should close sidebar on ${tab}`);
  }
  assert.equal(fileBackCalls, 0);

  // Subpages (mine subpage or session settings) keep swipe right from opening the drawer.
  state.activeTab = 'mine';
  state.minePage = 'computers';
  state.swipeDrawer(swipeRight);
  assert.equal(state.showSessions, false);

  state.activeTab = 'tasks';
  state.minePage = '';
  state.showSettings = true;
  state.swipeDrawer(swipeRight);
  assert.equal(state.showSessions, false);

  // On wide screens the sidebar stays docked across all root tabs including mine.
  state.windowWidth = 711;
  for (const tab of ['tasks', 'pending', 'files', 'mine']) {
    state.activeTab = tab;
    assert.equal(state.dockedSessions(), true, `sidebar should dock on ${tab}`);
  }
});

test('the user-chosen sidebar width fits the window and is restored when there is room', () => {
  const state = fixture();
  Object.assign(state, { windowWidth: 711, isPaired: true, activeTab: 'tasks', preferredSessionPaneWidth: 320 });
  assert.equal(state.sessionPaneWidth(), 320);

  state.windowWidth = 600;
  assert.equal(state.sessionPaneWidth(), 240);
  state.windowWidth = 711;
  assert.equal(state.sessionPaneWidth(), 320);

  state.preferredSessionPaneWidth = 0;
  assert.equal(state.sessionPaneWidth(), 160);
  assert.equal(state.compactSessionPane(), true);
  state.preferredSessionPaneWidth = 207;
  assert.equal(state.compactSessionPane(), true);
  state.preferredSessionPaneWidth = 208;
  assert.equal(state.compactSessionPane(), false);

  state.windowWidth = 600;
  state.preferredSessionPaneWidth = undefined;
  assert.equal(state.sessionPaneWidth(), 224);
  assert.equal(state.compactSessionPane(), false);

  state.windowWidth = 1100;
  state.preferredSessionPaneWidth = 800;
  assert.equal(state.sessionPaneWidth(), 420);
});

test('the workspace tree fetches folders on demand and paginates within a branch', async () => {
  const state = fixture();
  const files = state.fileController;
  files.state.fileRoot = '/project';
  const requests = [];
  const entry = (path, kind = 'file') => ({ path, name: path.split('/').at(-1), kind });
  state.request = async (_endpoint, { path, cursor }) => {
    requests.push([path, cursor]);
    if (!path) return { entries: [entry('src', 'directory'), entry('README.md')] };
    if (path === 'src/empty') return { entries: [] };
    if (cursor === 100) return { entries: [entry('src/index.ts'), entry('src/utils.ts')] };
    return { entries: [entry('src/empty', 'directory'), entry('src/index.ts')], nextCursor: 100 };
  };
  const rows = () => files.state.fileTreeRows.map(({ path, kind, depth }) => [path, kind, depth]);
  const rootRows = [['src', 'directory', 0], ['README.md', 'file', 0]];
  await files.loadFileDirectory('');
  assert.deepEqual(rows(), rootRows);
  await files.toggleFileDirectory('src');
  assert.deepEqual(rows(), [rootRows[0], ['src/empty', 'directory', 1], ['src/index.ts', 'file', 1],
    ['src', 'more', 1], rootRows[1]]);
  await files.loadFileDirectory('src', true);
  await files.toggleFileDirectory('src/empty');
  const expandedRows = [rootRows[0], ['src/empty', 'directory', 1], ['src/empty', 'empty', 2],
    ['src/index.ts', 'file', 1], ['src/utils.ts', 'file', 1], rootRows[1]];
  assert.deepEqual(rows(), expandedRows);
  await files.toggleFileDirectory('src');
  assert.deepEqual(rows(), rootRows);
  await files.toggleFileDirectory('src');
  assert.deepEqual(rows(), expandedRows);
  assert.deepEqual(requests, [['', 0], ['src', 0], ['src', 100], ['src/empty', 0]]);
  await files.loadFileDirectory('');
  assert.deepEqual(rows(), rootRows);
  await files.toggleFileDirectory('src');
  assert.deepEqual(requests.slice(-2), [['', 0], ['src', 0]]);
});

test('stale catalog refresh keeps cached rows interactive and respects closing the drawer', async () => {
  const state = fixture();
  state.sessionCatalogUpdatedAt = 0;
  let finish;
  state.request = () => new Promise(resolve => { finish = resolve; });
  const pending = state.loadSessions();
  assert.equal(state.busy, false, 'catalog reads must not disable task actions');
  assert.equal(state.sessions[0].id, 'one');
  state.setDrawer(false);
  finish({ sessions: [{ id: 'two' }], projects: ['/new'] });
  await pending;
  assert.equal(state.showSessions, false);
  assert.equal(state.sessions[0].id, 'two');
  assert.ok(state.sessionCatalogUpdatedAt > 0);
});


test('repeated drawer opens share one registration request and reuse the result', async () => {
  const state = fixture();
  state.sessionCatalogUpdatedAt = 0;
  let requests = 0;
  let finish;
  state.request = () => {
    requests++;
    return new Promise((resolve) => { finish = resolve; });
  };
  state.setDrawer(true);
  state.setDrawer(false);
  state.setDrawer(true);
  assert.equal(requests, 1);
  assert.equal(state.busy, false);
  finish({ workspaces: [{ cwd: '/project', name: 'Project' }] });
  await new Promise((resolve) => setImmediate(resolve));
  state.setDrawer(false);
  state.setDrawer(true);
  assert.equal(requests, 1);
  assert.deepEqual(state.projects, ['/project']);
});

test('opening the drawer leaves folders collapsed until the user expands one', () => {
  const state = fixture();
  state.currentId = 'one';
  state.workspaceCwd = '/project';
  const loads = [];
  state.loadWorkspacePage = async (path) => { loads.push(path); };
  state.setDrawer(true);
  assert.deepEqual(state.expandedSpaces, []);
  assert.deepEqual(loads, []);
  state.toggleSpace('/project');
  assert.deepEqual(state.expandedSpaces, ['/project']);
  assert.deepEqual(loads, ['/project']);
  state.setDrawer(false);
  state.setDrawer(true);
  assert.deepEqual(state.expandedSpaces, ['/project']);
});

test('a failed catalog refresh keeps the cached workspaces and can be retried', async () => {
  const state = fixture();
  state.request = async () => { throw new Error('offline'); };
  await state.loadSessions();
  assert.equal(state.sessions[0].id, 'one');
  assert.deepEqual(state.projects, ['/project']);
  assert.equal(state.sessionLoading, false);
  assert.equal(state.sessionCatalogFailed, true);
  state.request = async () => ({ workspaces: [{ cwd: '/new', name: 'New' }] });
  await state.loadSessions();
  assert.deepEqual(state.projects, ['/new']);
  assert.equal(state.sessionCatalogFailed, false);
});

test('a workspace entry opens the Agent picker and submits only after confirmation', async () => {
  const state = fixture();
  const requests = [];
  Object.assign(state, {
    hostAvailable: true,
    agents: [
      { id: 'pi', installed: true },
      { id: 'codex', installed: false },
      { id: 'agy', installed: true, authed: false },
    ],
    requestAction: async (...args) => { requests.push(args); return true; },
  });

  state.openNewSession('/project');
  assert.equal(state.showNewSession, true);
  assert.equal(state.newSessionFixedWorkspace, true);
  assert.equal(state.newSessionCwd, '/project');
  assert.equal(state.newSessionAgent, 'pi');
  assert.deepEqual(requests, []);

  state.newSessionAgent = 'codex';
  await state.createSession();
  assert.deepEqual(requests, []);

  state.newSessionAgent = 'agy';
  await state.createSession();
  assert.equal(state.activeTab, 'tasks');
  assert.deepEqual(requests, [['/new', { cwd: '/project', agent: 'agy' }]]);
  assert.equal(state.showNewSession, false);
});

test('the picker uses the current computer catalog and supports legacy Pi hosts', () => {
  const state = fixture();
  Object.assign(state, {
    visible: true, isPaired: true, reachable: false,
    selectRootTab: (tab) => { state.activeTab = tab; },
    request: async () => { assert.fail('the offline widget launch must not submit a request'); },
  });
  Object.assign(state.appState, { inboxFormLaunch: true, formDestination: 'new_task' });
  state.onInboxFormLaunch();
  assert.equal(state.activeTab, 'tasks');
  assert.equal(state.showNewSession, true);
  assert.equal(state.newSessionAgent, '');
  state.reachable = true;
  const workspaces = [{ cwd: '/workspace', name: 'Workspace' }];
  state.applyCatalog({ sessions: [], reply: {
    desktopHandoff: true, workspaces,
    agents: [{ id: 'codex', installed: true }, { id: 'agy', installed: true }],
  } }, 'all', false);
  assert.equal(state.newSessionCwd, '/workspace');
  assert.equal(state.newSessionAgent, 'codex');
  state.workspaceCwd = '/workspace';
  state.openNewSession('', 'agy');
  assert.equal(state.newSessionFixedWorkspace, false);
  assert.equal(state.newSessionCwd, '/workspace');
  assert.equal(state.newSessionAgent, 'agy');

  state.resetCatalog();
  assert.deepEqual(state.agents, []);
  assert.equal(state.showNewSession, false);
  state.applyCatalog({ sessions: [], reply: { desktopHandoff: true, workspaces } }, 'all', false);
  state.openNewSession();
  assert.equal(state.newSessionAgent, 'pi');
  assert.equal(state.canCreateSession(), true);
});

test('creating a space opens its picker and cancelling preserves the space', async () => {
  const state = fixture();
  Object.assign(state, { projects: [], expandedSpaces: [], hostAvailable: true, scheduleSidebarSave: () => {} });
  state.openNewSpace();
  assert.ok(!state.showNewSpace);
  state.canCreateWorkspace = true;
  state.openNewSpace();
  assert.equal(state.showNewSpace, true);
  state.closeNewSpace();
  assert.equal(state.showNewSpace, false);

  const requests = [];
  const cwd = '/Pi Go/Spaces/测试 空间';
  state.request = async (path, payload) => {
    if (path.startsWith('/sessions?')) return { desktopHandoff: true, workspaces: [{ cwd, name: '测试 空间' }] };
    requests.push([path, payload]);
    return { cwd };
  };
  state.requestAction = async (...args) => { requests.push(args); return true; };
  state.openNewSpace();
  state.newSpaceName = '../outside';
  await state.createWorkspaceTask();
  assert.ok(state.newSpaceError);
  assert.deepEqual(requests, []);
  state.newSpaceName = '  测试 空间  ';
  await Promise.all([state.createWorkspaceTask(), state.createWorkspaceTask()]);
  assert.deepEqual(requests, [['/create-workspace', { name: '测试 空间' }]]);
  assert.deepEqual(state.projects, [cwd]);
  assert.deepEqual(state.expandedSpaces, []);
  assert.equal(state.showNewSpace, false);
  assert.equal(state.showNewSession, true);
  assert.equal(state.newSessionCwd, cwd);
  state.closeNewSession();
  assert.deepEqual(state.projects, [cwd]);
});

test('a mismatched Agent leaves the picker and its selection available', async () => {
  const state = navigationFixture();
  let complete;
  let requests = 0;
  Object.assign(state, {
    hostAvailable: true,
    agents: [{ id: 'codex', installed: true }],
    request: () => { requests++; return new Promise((resolve) => { complete = resolve; }); },
  });
  state.openNewSession('/project', 'codex');
  const creation = state.createSession();
  await state.createSession();
  assert.equal(requests, 1);
  complete({ session: { id: 'wrong', cwd: '/project', agent: 'pi' } });
  await creation;
  assert.equal(state.currentId, 'one');
  assert.equal(state.showNewSession, true);
  assert.equal(state.newSessionAgent, 'codex');
  assert.match(state.newSessionError, /不一致/);
});

test('removing a space from its menu requires confirmation on the same computer', () => {
  const state = fixture();
  const requests = [];
  let confirmation;
  Object.assign(state, {
    isPaired: true,
    getUIContext: () => ({
      getPromptAction: () => ({ showToast: () => {} }),
      showAlertDialog: options => { confirmation = options; }
    }),
    requestAction: async (...args) => { requests.push(args); return false; }
  });

  state.confirmCloseSpace('/project', state.epoch - 1);
  assert.equal(confirmation, undefined);
  state.confirmCloseSpace('/project', state.epoch);
  assert.equal(confirmation.title, '移除空间');
  confirmation.primaryButton.action();
  assert.equal(requests.length, 0);
  state.confirmCloseSpace('/project', state.epoch);
  confirmation.secondaryButton.action();
  assert.deepEqual(requests, [['/close-workspace', { cwd: '/project' }]]);
});

test('removing a space reports errors in the drawer and removes the row after confirmation', async () => {
  const state = fixture();
  const messages = [];
  let attempts = 0;
  Object.assign(state, {
    showSessions: true, workspaceCwd: '/project', expandedSpaces: ['/project'],
    getUIContext: () => ({ getPromptAction: () => ({ showToast: ({ message }) => messages.push(message) }) }),
    scheduleSidebarSave: () => {}, schedule: () => {},
    request: async (path, payload) => {
      assert.equal(path, '/close-workspace');
      assert.deepEqual(payload, { cwd: '/project' });
      if (attempts++ === 0) throw new Error('offline');
      return { closed: true };
    }
  });
  await state.closeWorkspace('/project');
  assert.deepEqual(state.projects, ['/project']);
  assert.deepEqual(state.expandedSpaces, ['/project']);
  assert.deepEqual(messages, [state.status]);

  await state.closeWorkspace('/project');
  assert.deepEqual(state.projects, []);
  assert.deepEqual(state.expandedSpaces, []);
  assert.equal(messages.at(-1), '已移除空间「project」');
  assert.equal(state.sessionCatalogLoaded, false);
});

test('results from before a computer switch or catalog mutation are discarded', async () => {
  for (const field of ['catalogConnection', 'sessionCatalogVersion']) {
    const state = fixture();
    let finish;
    state.request = () => new Promise(resolve => { finish = resolve; });
    const pending = state.loadSessions();
    if (field === 'catalogConnection') state.resetCatalog();
    else state[field]++;
    finish({ sessions: [{ id: 'outdated' }] });
    await pending;
    assert.equal(state.sessions[0].id, 'one');
    assert.equal(state.sessionLoading, false);
  }
});

test('recent tasks request another page only on demand', async () => {
  const state = fixture();
  state.sessionView = 'recent';
  const paths = [];
  state.request = async (path) => {
    paths.push(path);
    return paths.length === 1 ? { sessions: [{ id: 'recent' }], nextCursor: 20 } : { sessions: [{ id: 'older' }] };
  };
  await state.loadSessions();
  assert.deepEqual(paths, ['/sessions?scope=filtered&limit=20&cursor=0&view=recent']);
  await state.loadSessions(true);
  assert.equal(paths[1], '/sessions?scope=filtered&limit=20&cursor=20&view=recent');
  assert.deepEqual(state.sessions.map((session) => session.id), ['recent', 'older']);
  assert.equal(state.loadedView, 'recent');
});

test('sidebar fetches only registrations until a workspace is expanded', async () => {
  const state = fixture();
  state.sessionCatalogLoaded = false;
  const requests = [];
  state.request = async (path) => {
    const { searchParams } = new URL(path, 'http://test');
    requests.push([...searchParams]);
    if (searchParams.get('scope') === 'workspaces') {
      return { projects: ['/project', '/unregistered'], workspaces: [{ cwd: '/project', name: 'Project' }] };
    }
    return searchParams.get('cursor') === '0'
      ? { sessions: [{ id: 'first', cwd: '/project' }], nextCursor: 10 }
      : { sessions: [{ id: 'first', cwd: '/project' }, { id: 'older', cwd: '/project' }] };
  };
  state.setDrawer(true);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(state.projects, ['/project']);
  assert.deepEqual(requests.map((params) => Object.fromEntries(params).scope), ['workspaces']);
  state.toggleSpace('/project');
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(requests.length, 2);
  assert.deepEqual(Object.fromEntries(requests[1]), { scope: 'workspace', limit: '10', cursor: '0', view: 'all', cwd: '/project' });
  await state.loadWorkspacePage('/project', true);
  assert.deepEqual(Object.fromEntries(requests[2]), { scope: 'workspace', limit: '10', cursor: '10', view: 'all', cwd: '/project' });
  assert.deepEqual(state.workspacePages[0].sessions.map(({ id }) => id), ['first', 'older']);
  assert.equal(state.workspacePages[0].nextCursor, undefined);
});

test('pull-to-refresh reloads only expanded registered workspaces and replaces a stale pagination response', async () => {
  const state = fixture();
  state.expandedSpaces = ['/project', '/removed'];
  state.workspacePages = [{ path: '/project', sessions: [{ id: 'old' }], nextCursor: 10 }];
  const requests = [];
  let finishMore;
  state.request = async (address) => {
    const params = Object.fromEntries(new URL(address, 'http://test').searchParams);
    requests.push(params);
    if (params.cursor === '10') return new Promise(resolve => { finishMore = resolve; });
    if (params.scope === 'workspaces') return { workspaces: [{ cwd: '/project' }, { cwd: '/closed' }] };
    return { sessions: [{ id: 'new' }], nextCursor: 10 };
  };

  const more = state.loadWorkspacePage('/project', true);
  await state.loadSessions(false, true);
  finishMore({ sessions: [{ id: 'older' }] });
  await more;

  assert.deepEqual(requests.map(({ scope, cwd, cursor, refresh }) => [scope, cwd, cursor, refresh]), [
    ['workspace', '/project', '10', undefined],
    ['workspaces', undefined, '0', undefined],
    ['workspace', '/project', '0', '1'],
  ]);
  assert.deepEqual(state.workspacePages[0].sessions.map(({ id }) => id), ['new']);
  assert.equal(state.workspacePages[0].nextCursor, 10);
  assert.equal(state.sessionLoading, false);
});

test('pull-to-refresh restarts the active filter and keeps cached sessions on failure', async () => {
  const state = fixture();
  state.sessionView = state.loadedView = 'archived';
  state.sessionNextCursor = 40;
  let request;
  state.request = async address => {
    request = address;
    throw new Error('offline');
  };

  await state.loadSessions(false, true);

  assert.equal(request, '/sessions?scope=filtered&limit=20&cursor=0&view=archived&refresh=1');
  assert.deepEqual(state.sessions.map(({ id }) => id), ['one']);
  assert.equal(state.sessionNextCursor, 40);
  assert.equal(state.sessionCatalogFailed, true);
  assert.equal(state.sessionLoading, false);
});

function navigationFixture() {
  const state = fixture();
  Object.assign(state, {
    showSessions: true, currentId: 'one', messages: [{ id: 'old' }], liveText: '',
    openingSession: false, pendingSessionReveal: '', pendingBottom: false,
    applySession: session => {
      if (state.currentId !== session.id) { state.messages = []; state.pendingBottom = true; }
      state.currentId = session.id; state.idle = session.idle ?? true;
    },
    schedule: () => {}, cancelSchedule: () => {}, setInteraction: () => {}
  });
  return state;
}

test('opening a task keeps sidebar controls bright and prevents duplicate opens', async () => {
  const state = navigationFixture();
  let finish;
  let requests = 0;
  state.request = () => { requests++; return new Promise(resolve => { finish = resolve; }); };
  const pending = state.requestAction('/open', { id: 'two' });
  assert.equal(state.openingSessionId, 'two');
  assert.equal(state.currentId, 'one');
  const stayedInteractive = !state.busy;
  await state.requestAction('/open', { id: 'three' });
  assert.equal(requests, 1);
  assert.equal(state.openingSessionId, 'two');
  finish({ session: { id: 'two' } });
  // A successful open must fetch the initial transcript before exposing the new session.
  state.request = async () => ({ session: { id: 'two' }, messages: [{ id: 'latest' }] });
  await pending;
  assert.equal(state.openingSessionId, '');
  assert.equal(stayedInteractive, true, 'opening a task must not gray out the sidebar');
});

test('navigation loads the transcript before dismissing the sidebar', async () => {
  const state = navigationFixture();
  const calls = [];
  let nextPoll;
  state.schedule = delay => { nextPoll = delay; };
  state.request = async path => {
    calls.push(path);
    return path === '/open' ? { session: { id: 'two' } } :
      { session: { id: 'two' }, messages: [{ id: 'latest' }], liveText: 'stream', historyCursor: 'older' };
  };
  assert.equal(await state.requestAction('/open', { id: 'two' }), true);
  assert.deepEqual(calls, ['/open', '/chat']);
  assert.equal(state.showSessions, true, 'keep the drawer until transcript layout is at the bottom');
  assert.equal(state.messages[0].id, 'latest');
  assert.equal(state.liveText, 'stream');
  assert.equal(state.historyCursor, 'older');
  assert.equal(state.pendingSessionReveal, 'two');
  assert.ok(nextPoll >= 650, 'avoid an immediate duplicate chat request');
});


test('initial positioning jumps without animation before revealing the conversation', () => {
  const state = navigationFixture();
  state.currentId = 'two';
  state.pendingBottom = true;
  state.pendingSessionReveal = 'two';
  const events = [];
  state.transcript = { scrollTo: options => {
    assert.equal(state.showSessions, true, 'position before exposing the conversation');
    events.push(['position', options]);
  } };
  state.setDrawer = () => { assert.fail('automatic reveal must not animate the drawer'); };
  state.positionTranscript('one', 5000);
  assert.equal(events.length, 0, 'ignore callbacks from the previous transcript');
  state.positionTranscript('two', 5000);
  assert.deepEqual(events, [
    ['position', { xOffset: 0, yOffset: 5000, animation: false }]
  ]);
  assert.equal(state.showSessions, false);
  assert.equal(state.pendingSessionReveal, '');
  assert.equal(state.pendingBottom, false);
  state.positionTranscript('two', 5000);
  assert.equal(events.length, 1, 'later layout must not reset the reading position');
});

test('polling does not race the initial navigation snapshot', async () => {
  const state = navigationFixture();
  state.openingSession = true;
  state.request = async () => { assert.fail('poll must wait for navigation'); };
  await state.poll();
});

test('failed initial transcript leaves the drawer available for retry', async () => {
  const state = navigationFixture();
  const messages = [];
  state.getUIContext = () => ({ getPromptAction: () => ({ showToast: ({ message }) => messages.push(message) }) });
  state.request = async path => {
    if (path === '/session/open' || path === '/open') return { session: { id: 'two' } };
    throw new Error('network');
  };
  assert.equal(await state.requestAction('/open', { id: 'two' }), false);
  assert.equal(state.showSessions, true);
  assert.equal(state.openingSession, false);
  assert.equal(state.busy, false);
  assert.equal(state.currentId, 'one');
  assert.equal(state.openingSessionId, '');
  assert.deepEqual(messages, [state.status]);
});

test('returning to a cached conversation renders before the open request finishes', async () => {
  const state = navigationFixture();
  state.chatState.chatCache = new Map([['two', {
    session: { id: 'two', cwd: '/project', idle: true },
    messages: [{ id: 'cached-latest', text: 'Already read' }], liveText: ''
  }]]);
  state.draftKey = id => id;
  let finishOpen;
  state.request = path => path === '/open' ? new Promise(resolve => { finishOpen = resolve; }) :
    Promise.resolve({ session: { id: 'two', cwd: '/project', idle: true }, messages: [{ id: 'fresh-latest' }] });
  const pending = state.requestAction('/open', { id: 'two' });
  const renderedBeforeOpen = state.currentId === 'two' && state.messages[0]?.id === 'cached-latest';
  if (renderedBeforeOpen) {
    state.transcript = { scrollTo: () => {} };
    state.positionTranscript('two', 5000);
    assert.equal(state.showSessions, false);
    assert.equal(state.openingSession, true, 'sending stays blocked until the remote switch is confirmed');
    state.draft = 'Must wait';
    await state.send();
    assert.equal(state.pendingSend, undefined);
  }
  finishOpen({ session: { id: 'two', cwd: '/project', idle: true } });
  await pending;
  assert.equal(renderedBeforeOpen, true, 'cached conversation must not wait for the network');
  assert.equal(state.messages[0].id, 'fresh-latest');
  assert.equal(state.openingSession, false);
});


test('running status refresh updates all tasks without replacing cached pages', async () => {
  const state = fixture();
  state.loadSessionStatus = Page.prototype.loadSessionStatus;
  state.sessions.push({ id: 'page-two' });
  let calls = 0;
  state.request = async path => {
    assert.equal(path, '/sessions/status');
    calls++;
    return { runningSessionIds: calls === 1 ? ['page-two'] : [] };
  };
  await state.loadSessionStatus();
  assert.equal(state.sessionRunning('page-two'), true);
  assert.equal(state.sessionRunning('one'), false);
  assert.equal(state.sessions.length, 2);
  await state.loadSessionStatus();
  assert.equal(state.sessionRunning('page-two'), false);
});

test('current task shows one banner after the queue drains across events and snapshots', (context) => {
  const state = navigationFixture();
  Object.assign(state, { visible: true });
  context.after(() => state.runCenter.clearRunNotices());
  const session = { id: 'one', idle: true };
  const snapshot = (idle, seq) => state.applySessionSnapshot({
    session: { ...session, idle }, cursor: { sessionId: 'one', streamId: 'worker', runId: null, seq }
  });
  snapshot(false, 1);
  snapshot(true, 2);
  assert.equal(state.runCenter.state.runNotice, undefined);
  state.applyStreamFrame({ type: 'session/status', idle: false });
  state.applyStreamFrame({ type: 'session/status', idle: true, queued: true });
  assert.equal(state.runCenter.state.runNotice, undefined);
  snapshot(true, 3);
  assert.deepEqual(state.runCenter.state.runNotice, { title: 'Cached task', stopped: false });
  state.applyStreamFrame({ type: 'session/status', idle: true });
  state.runCenter.advanceRunNotice();
  assert.equal(state.runCenter.state.runNotice, undefined);

  state.applyStreamFrame({ type: 'session/status', idle: false });
  state.applyStreamFrame({ type: 'session/status', idle: true, aborted: true });
  assert.equal(state.runCenter.state.runNotice.stopped, true);
});

test('background banners require a previously running task to be confirmed idle', (context) => {
  const state = fixture();
  Object.assign(state, {
    visible: true, currentId: 'one', sessionLoading: true,
    sessions: [{ id: 'two', name: 'Build' }, { id: 'three', name: 'Closed' }, { id: 'four', name: 'Dispatching' }]
  });
  context.after(() => state.runCenter.clearRunNotices());
  state.applyRunningStatus({
    runningSessionIds: ['one', 'two', 'three', 'four'],
    runningSessions: [{ id: 'four', started: false }],
    idleSessionIds: []
  });
  state.applyRunningStatus(undefined);
  assert.equal(state.runCenter.state.runNotice, undefined);
  state.applyRunningStatus({ runningSessionIds: [], idleSessionIds: ['one', 'two', 'four'] });
  assert.deepEqual(state.runCenter.state.runNotice, { title: 'Build', stopped: false });
  state.applyRunningStatus({ runningSessionIds: [], idleSessionIds: ['one', 'two', 'three'] });
  state.runCenter.advanceRunNotice();
  assert.equal(state.runCenter.state.runNotice, undefined);
});

test('disabling run notices clears existing banners and persists across app restarts', async (context) => {
  const saved = new Map();
  const pending = new Map();
  const settings = {
    getSync: (key, fallback) => saved.get(key) ?? fallback,
    putSync: (key, value) => pending.set(key, value),
    flush: async () => { for (const [key, value] of pending) saved.set(key, value); }
  };
  const openPage = () => {
    const state = fixture();
    Object.assign(state, { visible: true, getUIContext: () => ({ getHostContext: () => ({ settings }) }) });
    state.restoreSettings();
    context.after(() => state.runCenter.clearRunNotices());
    return state;
  };
  const state = openPage();
  assert.equal(state.runCenter.state.runNoticesEnabled, true);
  for (const id of ['one', 'two']) {
    state.runCenter.observeRun(id, id, true);
    state.runCenter.observeRun(id, id, false);
  }
  assert.equal(state.runCenter.state.runNotice.title, 'one');
  assert.equal(state.runCenter.pendingRunNotices.length, 1);
  const disabled = state.runCenter.setRunNoticesEnabled(false);
  assert.equal(state.runCenter.state.runNotice, undefined);
  assert.equal(state.runCenter.runNoticeTimer, -1);
  assert.equal(state.runCenter.pendingRunNotices.length, 0);
  await disabled;

  const reopened = openPage();
  assert.equal(reopened.runCenter.state.runNoticesEnabled, false);
  reopened.runCenter.observeRun('one', 'Finished while muted', true);
  reopened.runCenter.observeRun('one', '', false);
  reopened.runCenter.observeRun('two', 'Still running', true);
  await reopened.runCenter.setRunNoticesEnabled(true);
  assert.equal(reopened.runCenter.state.runNotice, undefined);
  reopened.runCenter.observeRun('two', '', false);
  assert.equal(reopened.runCenter.state.runNotice.title, 'Still running');
  assert.equal(openPage().runCenter.state.runNoticesEnabled, true);
});

test('live activity follows a phone-dispatched run and clears when it becomes idle', () => {
  const state = fixture();
  Object.assign(state, {
    syncLiveActivity: StreamSyncController.prototype.syncLiveActivity,
    visible: true, isPaired: true, currentId: 'one', idle: false, queued: false,
    reachable: true, base: 'http://127.0.0.1:18977', runId: 'run-one',
    cancelSchedule: () => assert.fail('foreground sync must not cancel polling'),
    stopStream: () => assert.fail('foreground sync must not stop the event stream')
  });
  liveViewCalls.length = 0;
  state.syncLiveActivity();
  assert.equal(liveViewCalls.at(-1), undefined);
  state.trackDispatchedLiveRun(state.liveRevision);
  assert.deepEqual({
    sessionId: liveViewCalls.at(-1).sessionId,
    address: liveViewCalls.at(-1).address,
    state: liveViewCalls.at(-1).state,
    foreground: liveViewCalls.at(-1).foreground
  }, {
    sessionId: 'one', address: 'http://127.0.0.1:18977', state: '运行中', foreground: true
  });
  assert.ok(liveViewCalls.at(-1).title);
  assert.ok(liveViewCalls.at(-1).badge);
  assert.ok(liveViewCalls.at(-1).progress > 0);
  state.interaction = { id: 'approval' };
  state.syncLiveActivity();
  assert.equal(liveViewCalls.at(-1).state, '等待处理');
  state.interaction = undefined;
  state.queued = true;
  state.syncLiveActivity();
  assert.equal(liveViewCalls.at(-1).state, '排队中');
  state.reachable = false;
  state.syncLiveActivity();
  assert.equal(liveViewCalls.at(-1).state, '重新连接中');
  state.idle = true;
  state.queued = false;
  state.syncLiveActivity();
  assert.equal(liveViewCalls.at(-1), undefined);
  state.idle = false;
  state.runId = 'desktop-run';
  state.syncLiveActivity();
  assert.equal(liveViewCalls.at(-1), undefined);
});

test('background live activity keeps syncing only while the selected run is active', () => {
  const state = fixture();
  let cancelled = 0, stopped = 0;
  Object.assign(state, {
    syncLiveActivity: StreamSyncController.prototype.syncLiveActivity,
    visible: false, isPaired: true, currentId: 'one', idle: false, queued: false,
    liveViewSessionKey: 'one',
    reachable: true, base: 'http://127.0.0.1:18977', project: 'pi-go',
    cancelSchedule: () => { cancelled++; }, stopStream: () => { stopped++; }
  });
  liveViewCalls.length = 0;
  state.syncLiveActivity();
  assert.equal(liveViewCalls.at(-1).foreground, false);
  assert.equal(cancelled, 0);
  assert.equal(stopped, 0);
  state.idle = true;
  state.syncLiveActivity();
  assert.equal(liveViewCalls.at(-1), undefined);
  assert.equal(cancelled, 1);
  assert.equal(stopped, 1);
});

test('running badges use current chat state and disappear when disconnected', () => {
  const state = fixture();
  state.currentId = 'one';
  state.runningSessionIds = ['one', 'other'];
  assert.equal(state.sessionRunning('one'), false);
  state.idle = false;
  assert.equal(state.sessionRunning('one'), true);
  state.idle = true;
  state.queued = true;
  assert.equal(state.sessionRunning('one'), true);
  state.reachable = false;
  assert.equal(state.sessionRunning('one'), false);
  assert.equal(state.sessionRunning('other'), false);
});

test('status requests deduplicate and discard results from the previous computer', async () => {
  const state = fixture();
  state.loadSessionStatus = Page.prototype.loadSessionStatus;
  let finish;
  let requests = 0;
  state.request = () => { requests++; return new Promise(resolve => { finish = resolve; }); };
  const pending = state.loadSessionStatus();
  await state.loadSessionStatus();
  assert.equal(requests, 1);
  state.epoch++;
  finish({ runningSessionIds: ['old-computer'] });
  await pending;
  assert.deepEqual(state.runningSessionIds, []);
  assert.equal(state.sessionStatusLoading, false);
});

test('failed status refresh clears old badges and preserves the catalog', async () => {
  const state = fixture();
  state.runningSessionIds = ['one'];
  state.request = async () => { throw new Error('offline'); };
  await Page.prototype.loadSessionStatus.call(state);
  assert.deepEqual(state.runningSessionIds, []);
  assert.equal(state.sessions[0].id, 'one');
});

test('running status carries session names for header capsules and merges legacy ids', () => {
  const state = fixture();
  state.applyRunningStatus({ runningSessions: [
    { id: 'one', name: 'Refactor tests', cwd: '/a' },
    { id: 'two', name: 'Deploy site', cwd: '/b' },
    { id: undefined, name: 'broken row' },
  ], runningSessionIds: ['one', 'two', 'three'] });
  assert.deepEqual(state.runningSessions.map(row => row.id), ['one', 'two']);
  assert.deepEqual(state.runningSessionIds, ['one', 'two', 'three']);
  assert.equal(state.sessions[0].name, 'Refactor tests');
  // Only legacy bridge without runningSessions: rows stay empty but ids still feed list badges.
  state.applyRunningStatus({ runningSessionIds: ['legacy'] });
  assert.deepEqual(state.runningSessions, []);
  assert.deepEqual(state.runningSessionIds, ['legacy']);
  state.applyRunningStatus(undefined);
  assert.deepEqual(state.runningSessionIds, []);
  assert.deepEqual(state.runningSessions, []);
});

test('background running rows exclude the open conversation so the header shows the others', () => {
  const state = fixture();
  state.currentId = 'one';
  state.runningSessions = [
    { id: 'one', name: 'Current chat' },
    { id: 'two', name: 'Deploy site' },
    { id: 'three', name: 'Refactor tests' },
  ];
  assert.deepEqual(state.backgroundRunning().map(row => row.id), ['two', 'three']);
  assert.equal(state.backgroundRunning()[0].name, 'Deploy site');
});

test('unnamed running rows fall back to the cached catalog name', () => {
  const state = fixture();
  state.currentId = 'one';
  state.sessions = [{ id: 'two', cwd: '/project', name: 'Cached task' }];
  state.runningSessions = [{ id: 'two' }];
  const [row] = state.backgroundRunning();
  assert.equal(row.name, 'Cached task');
  state.sessions = [];
  assert.equal(state.backgroundRunning()[0].name, undefined, 'no catalog rows still leave the pill usable');
});

test('session states distinguish streaming, waiting and queued for both pills and badges', () => {
  const state = fixture();
  state.currentId = 'one';
  state.runningSessions = [
    { id: 'two', state: 'waiting' },
    { id: 'three', state: 'queued' },
    { id: 'four', state: 'streaming' },
  ];
  state.runningSessionIds = ['one', 'two', 'three', 'four', 'legacy-raw'];
  assert.equal(state.sessionState('two'), 'waiting');
  assert.equal(state.sessionState('three'), 'queued');
  assert.equal(state.sessionState('four'), 'streaming');
  assert.equal(state.sessionState('legacy-raw'), 'streaming', 'legacy rows default to streaming');
  assert.equal(state.sessionState('idle-task'), '');
  // The open conversation prefers live local state: a pending interaction outranks streaming.
  state.idle = false;
  assert.equal(state.sessionState('one'), 'streaming');
  state.interaction = { id: 'q', method: 'input' };
  assert.equal(state.sessionState('one'), 'waiting');
  state.interaction = undefined;
  state.idle = true;
  state.queued = true;
  assert.equal(state.sessionState('one'), 'queued');
  state.reachable = false;
  assert.equal(state.sessionState('one'), '');
});

test('legacy bridges without runningSessions still produce header pills from raw ids', () => {
  const state = fixture();
  state.currentId = 'one';
  state.sessions = [{ id: 'two', cwd: '/project', name: 'Cached task' }, { id: 'three', cwd: '/project', name: 'Deploy site' }];
  state.runningSessionIds = ['one', 'two', 'three'];
  state.runningSessions = [];
  assert.deepEqual(state.backgroundRunning().map(row => [row.id, row.name]),
    [['two', 'Cached task'], ['three', 'Deploy site']]);
  assert.equal(state.backgroundActive(), true);
  // A merged mix keeps named rows and only synthesizes the missing ones.
  state.runningSessions = [{ id: 'two', name: 'Live name', cwd: '/project' }];
  assert.deepEqual(state.backgroundRunning().map(row => [row.id, row.name]),
    [['two', 'Live name'], ['three', 'Deploy site']]);
});

test('running status does not trigger a history request', () => {
  const state = fixture();
  state.currentId = 'one';
  state.sessions = [];
  state.loadSessions = async () => assert.fail('status polling must not refresh the history catalog');
  state.applyRunningStatus({ runningSessionIds: ['two'] });
  assert.equal(state.backgroundActive(), true);
  assert.equal(state.backgroundRunning()[0].id, 'two');
});

test('chat polling keeps watching background tasks with the drawer closed', async () => {
  const state = navigationFixture();
  state.showSessions = false;
  state.currentId = 'one';
  state.runningSessions = [];
  let statusRequests = 0;
  state.request = async path => {
    if (path === '/sessions/status') {
      statusRequests++;
      return statusRequests === 1 ?
        { runningSessions: [{ id: 'two', name: 'Deploy site' }], runningSessionIds: ['one', 'two'] } :
        { runningSessions: [{ id: 'two', name: 'Deploy site' }], runningSessionIds: ['two'] };
    }
    return { session: { id: 'one', idle: false }, messages: [] };
  };
  state.loadSessionStatus = Page.prototype.loadSessionStatus;
  state.sessionStatusAt = 0;
  await state.poll();
  assert.equal(statusRequests, 1, 'first poll probes desktop-started tasks');
  await state.poll();
  assert.equal(statusRequests, 2, 'background tasks keep refreshing while the chat stays open');
  assert.deepEqual(state.backgroundRunning().map(row => row.id), ['two']);
});

test('idle chats only probe running status on a slow schedule', async () => {
  const state = navigationFixture();
  state.showSessions = false;
  state.currentId = 'one';
  state.runningSessions = [];
  let statusRequests = 0;
  state.request = async path => {
    if (path === '/sessions/status') { statusRequests++; return { runningSessionIds: [] }; }
    return { session: { id: 'one', idle: true }, messages: [] };
  };
  state.loadSessionStatus = Page.prototype.loadSessionStatus;
  state.sessionStatusAt = Date.now();
  await state.poll();
  await state.poll();
  assert.equal(statusRequests, 0, 'fresh probe suppresses extra requests while nothing runs');
  state.sessionStatusAt -= 6000;
  await state.poll();
  assert.equal(statusRequests, 1, 'a slow probe still discovers tasks started later');
});


test('a failed remote switch restores the previous conversation and offers retry', async () => {
  const state = navigationFixture();
  state.chatState.chatCache.set('one', { session: { id: 'one' }, messages: [{ id: 'old' }] });
  state.chatState.chatCache.set('two', { session: { id: 'two' }, messages: [{ id: 'cached' }] });
  state.request = async () => { throw new Error('desktop unavailable'); };
  assert.equal(await state.requestAction('/open', { id: 'two' }), false);
  assert.equal(state.currentId, 'one');
  assert.equal(state.messages[0].id, 'old');
  assert.equal(state.showSessions, true);
  assert.equal(state.pendingSessionReveal, '');
  assert.equal(state.openingSession, false);
});

test('a failed refresh after a confirmed switch preserves the cached conversation', async () => {
  const state = navigationFixture();
  state.chatState.chatCache.set('two', { session: { id: 'two' }, messages: [{ id: 'cached' }] });
  state.request = async path => {
    if (path === '/open') return { session: { id: 'two' } };
    throw new Error('temporary chat failure');
  };
  await state.requestAction('/open', { id: 'two' });
  assert.equal(state.currentId, 'two');
  assert.equal(state.messages[0].id, 'cached');
  assert.equal(state.openingSession, false);
});

test('background refresh does not scroll again after the cached conversation is positioned', async () => {
  const state = navigationFixture();
  state.chatState.chatCache.set('two', { session: { id: 'two' }, messages: [{ id: 'cached' }] });
  let finish;
  state.request = path => path === '/open' ? new Promise(resolve => { finish = resolve; }) :
    Promise.resolve({ session: { id: 'two' }, messages: [{ id: 'fresh' }] });
  const pending = state.requestAction('/open', { id: 'two' });
  let scrolls = 0;
  state.transcript = { scrollTo: () => { scrolls++; } };
  state.positionTranscript('two', 3000);
  finish({ session: { id: 'two' } });
  await pending;
  state.positionTranscript('two', 4000);
  assert.equal(scrolls, 1);
  assert.equal(state.showSessions, false);
});

test('chat cache is bounded and retains a usable history cursor', () => {
  const state = navigationFixture();
  state.messages = Array.from({ length: 120 }, (_, index) => ({ id: String(index) }));
  for (let index = 0; index < 18; index++) state.cacheChat({ id: String(index) });
  assert.equal(state.chatState.chatCache.size, 16);
  assert.equal(state.chatState.chatCache.has('0'), false);
  const cached = state.chatState.chatCache.get('17');
  assert.equal(cached.messages.length, 60);
  assert.equal(cached.historyCursor, '60');
});

test('the same session id on a different computer cannot use another computer cache', async () => {
  const state = navigationFixture();
  state.draftKey = id => 'new-computer|' + id;
  state.chatState.chatCache.set('old-computer|two', { session: { id: 'two' }, messages: [{ id: 'private-old' }] });
  let finish;
  state.request = path => path === '/open' ? new Promise(resolve => { finish = resolve; }) :
    Promise.resolve({ session: { id: 'two' }, messages: [{ id: 'new' }] });
  const pending = state.requestAction('/open', { id: 'two' });
  assert.equal(state.currentId, 'one');
  finish({ session: { id: 'two' } });
  await pending;
  assert.equal(state.messages[0].id, 'new');
});

test('identical transcript polls reuse the existing array and preserve earlier history', () => {
  const state = navigationFixture();
  const recent = { id: 'latest', text: 'Answer', tools: [{ id: 'read', state: 'run' }] };
  const history = [{ id: 'older' }, recent];
  state.messages = history;
  state.historyCursor = 'oldest';

  state.mergeTranscript([structuredClone(recent)], 'latest');
  assert.equal(state.messages, history);

  const completed = { ...recent, tools: [{ id: 'read', state: 'ok' }] };
  state.mergeTranscript([completed], 'latest');
  assert.deepEqual(state.messages, [history[0], completed]);
  assert.equal(state.historyCursor, 'oldest');
});

test('confirmed steering is visible before transcript refresh and repeated messages reconcile individually', () => {
  const state = navigationFixture();
  Object.assign(state, { idle: false, draft: 'Change direction' });
  const original = { id: 'original', role: 'user', text: state.draft };
  state.messages = [original];
  const pending = id => ({ requestId: id, text: original.text, attachments: [], steeringAfter: original.id });
  state.finishSend('one', pending('first'));
  assert.deepEqual(state.queuedSteering.map(item => item.id), ['first']);
  assert.deepEqual(state.messages, [original]);
  assert.equal(state.draft, '');
  assert.equal(state.pendingBottom, true);

  state.pendingSend = pending('second');
  state.messages.push({ ...original, id: 'delivered-first' });
  state.reconcileSteering(false);
  state.finishSend('one', state.pendingSend);
  assert.deepEqual(state.queuedSteering.map(item => item.id), ['second']);
  state.reconcileSteering(false);
  assert.deepEqual(state.queuedSteering.map(item => item.id), ['second']);

  state.messages.push({ ...original, id: 'delivered-second' });
  state.reconcileSteering(false);
  assert.deepEqual(state.queuedSteering, []);
});

test('queued attachment previews stay scoped to the conversation and clear when it settles', () => {
  const state = navigationFixture();
  Object.assign(state, { idle: false, draft: '', messages: [] });
  state.finishSend('one', { requestId: 'file', text: '', steeringAfter: '', attachments: [{ kind: 'file', name: 'note.md' }] });
  assert.deepEqual(state.queuedSteering[0].files, ['note.md']);
  state.currentId = 'other';
  state.reconcileSteering(true);
  assert.equal(state.queuedSteering.length, 1);
  state.currentId = 'one';
  state.reconcileSteering(true);
  assert.deepEqual(state.queuedSteering, []);
});

test('idle send shows an optimistic user message immediately and reconciles when history arrives', async () => {
  const state = navigationFixture();
  Object.assign(state, { idle: true, draft: 'Hello Pi', messages: [{ id: 'a1', role: 'assistant', text: 'Ready' }] });
  let finishPrompt;
  state.request = path => path === '/prompt'
    ? new Promise(resolve => { finishPrompt = resolve; })
    : Promise.resolve({});
  const sending = state.send();
  assert.equal(state.draft, '');
  assert.equal(state.pendingBottom, true);
  assert.equal(state.transcriptFollow, true);
  assert.equal(state.optimisticMessages.length, 1);
  assert.equal(state.optimisticMessages[0].text, 'Hello Pi');
  assert.equal(state.optimisticMessages[0].sending, true);
  // A background settled poll during in-flight send must not drop the optimistic bubble.
  state.reconcileSteering(true);
  assert.equal(state.optimisticMessages.length, 1);

  finishPrompt({ dispatched: true });
  await sending;
  assert.equal(state.optimisticMessages.length, 1);
  assert.equal(state.optimisticMessages[0].sending, false);

  state.messages = state.messages.concat([{ id: 'u2', role: 'user', text: 'Hello Pi' }]);
  state.reconcileSteering(false);
  assert.deepEqual(state.optimisticMessages, []);
});

test('failed idle send removes optimistic message and restores the draft', async () => {
  const state = navigationFixture();
  Object.assign(state, { idle: true, draft: 'Retry me', messages: [] });
  state.request = async () => { throw new BridgeFailure(409, 'session_busy'); };
  await state.send();
  assert.deepEqual(state.optimisticMessages, []);
  assert.equal(state.draft, 'Retry me');
  assert.equal(state.pendingSend, undefined);
});

test('stream paints combine text and thinking and discard duplicate and finalized deltas', () => {
  const state = navigationFixture();
  const frame = payload => state.handleFrame(JSON.stringify({ sessionId: 'one', ...payload }));
  frame({ type: 'message/delta', text: 'Hello', seq: 1 });
  const timer = state.chatState.deltaPaintTimer;
  frame({ type: 'message/delta', text: ' duplicate', seq: 1 });
  frame({ type: 'message/delta', text: ' world', seq: 2 });
  frame({ type: 'message/thinking', text: 'Planning', seq: 1 });
  assert.equal(state.chatState.deltaPaintTimer, timer);
  assert.equal(state.liveText, '');
  state.flushStreamDeltas();
  assert.equal(state.liveText, 'Hello world');
  assert.equal(state.liveThinking, 'Planning');
  assert.equal(state.pendingBottom, true);

  frame({ type: 'message/delta', text: '!', seq: 3 });
  frame({ type: 'message/final', seq: 4, thinkingSeq: 2 });
  state.flushStreamDeltas();
  assert.equal(state.liveText, '');
  assert.equal(state.liveThinking, '');
});

test('an idle poll started before a new run preserves its buffered stream', async () => {
  const state = navigationFixture();
  let finish;
  state.request = () => new Promise(resolve => { finish = resolve; });
  const polling = state.poll();
  state.handleFrame(JSON.stringify({ type: 'session/status', sessionId: 'one', idle: false }));
  state.handleFrame(JSON.stringify({ type: 'message/delta', sessionId: 'one', seq: 1, text: 'New run' }));
  finish({ session: { id: 'one', idle: true }, messages: [] });
  await polling;
  state.flushStreamDeltas();
  assert.equal(state.idle, false);
  assert.equal(state.liveText, 'New run');
});

function syncFixture() {
  const state = navigationFixture();
  Object.assign(state, {
    syncMode: 'sequenced', historyRequest: 0,
    streamGen: 0, streamTimer: -1, startStream: () => {}, scheduleStream: () => {},
  });
  return state;
}

const syncCursor = (seq, sessionId = 'one', streamId = 'first-worker', runId = 'run-1') =>
  ({ sessionId, streamId, runId, seq });
const snapshot = (cursor, liveText = '', historyLeaf = 'leaf') =>
  ({ session: { id: cursor.sessionId, cwd: '/project', idle: cursor.runId === null },
    cursor, liveText, historyLeaf, tools: [] });
const feedFrame = (state, type, cursor, data = {}) =>
  state.handleFrame(JSON.stringify({ type, sessionId: cursor.sessionId, cursor, ...data }));

test('a sequence gap triggers one snapshot and drains only uncovered events', async () => {
  const state = syncFixture();
  state.historyStream = 'first-worker';
  state.historyLeaf = 'leaf';
  const scheduled = [];
  state.schedule = delay => scheduled.push(delay);
  feedFrame(state, 'ready', syncCursor(10));
  assert.equal(state.applySessionSnapshot(snapshot(syncCursor(10), 'a')), true);
  feedFrame(state, 'message/delta', syncCursor(12), { text: 'c' });
  assert.equal(state.liveText, 'a');
  assert.equal(scheduled.at(-1), 0);
  let reply;
  const calls = [];
  state.request = path => {
    calls.push(path);
    return new Promise(resolve => { reply = resolve; });
  };
  const recovery = state.poll();
  feedFrame(state, 'message/delta', syncCursor(12), { text: 'c' });
  feedFrame(state, 'message/thinking', syncCursor(13), { text: 'thinking' });
  await state.poll();
  assert.deepEqual(calls, ['/session/snapshot']);
  reply(snapshot(syncCursor(11), 'ab'));
  await recovery;
  feedFrame(state, 'message/delta', syncCursor(12), { text: ' duplicate' });
  state.flushStreamDeltas();
  assert.equal(state.liveText, 'abc');
  assert.equal(state.liveThinking, 'thinking');
  assert.equal(state.chatState.sync.needsSnapshot(), false);
  assert.equal(state.applySessionSnapshot(snapshot(syncCursor(12), 'stale')), false);
  assert.equal(state.liveText, 'abc');
});

test('reconnect restores a new baseline and rejects old runs and worker bindings', async () => {
  const state = syncFixture();
  feedFrame(state, 'ready', syncCursor(18));
  state.applySessionSnapshot(snapshot(syncCursor(18), 'old'));
  const scheduled = [];
  state.schedule = delay => scheduled.push(delay);
  state.streamDown(state.streamGen, 1);
  assert.equal(scheduled.at(-1), 0);
  const nextRun = seq => syncCursor(seq, 'one', 'second-worker', 'run-2');
  feedFrame(state, 'ready', nextRun(2));
  feedFrame(state, 'message/delta', nextRun(4), { text: ' tail' });
  feedFrame(state, 'session/status', syncCursor(19), { idle: true });
  assert.equal(state.applySessionSnapshot(snapshot(syncCursor(19), 'stale')), false);
  const result = snapshot(nextRun(3), 'recovered');
  state.request = async path => {
    assert.equal(path, '/session/snapshot');
    return result;
  };
  state.historyStream = 'second-worker';
  state.historyLeaf = 'leaf';
  await state.poll();
  state.flushStreamDeltas();
  assert.equal(state.liveText, 'recovered tail');
  assert.equal(state.idle, false);
  assert.equal(state.runId, 'run-2');
});

test('opening with bundled history shows the transcript without another request', async () => {
  for (const mode of ['probe', 'sequenced']) {
    const state = syncFixture();
    state.syncMode = mode;
    const requests = [];
    const current = snapshot(syncCursor(11, 'two', 'second-worker'), 'partial reply');
    state.request = async (path, input) => {
      requests.push([path, input]);
      return { ...current, messages: [{ id: 'latest' }], historyCursor: 'older' };
    };
    assert.equal(await state.requestAction('/open', { id: 'two' }), true);
    assert.deepEqual(requests, [['/session/open', { id: 'two', history: true }]]);
    assert.equal(state.syncMode, 'sequenced');
    assert.equal(state.currentId, 'two');
    assert.deepEqual(state.messages, [{ id: 'latest' }]);
    assert.equal(state.historyCursor, 'older');
    assert.equal(state.historyStream, 'second-worker');
    assert.equal(state.liveText, 'partial reply');
  }
});

test('switching away and back ignores earlier snapshots and history for the same session', async () => {
  const state = syncFixture();
  const first = snapshot(syncCursor(10), 'old');
  assert.equal(state.applySessionSnapshot(first), true);
  let previousHistory;
  let previousSnapshot;
  state.request = path => new Promise(resolve => {
    if (path.startsWith('/history')) previousHistory = resolve;
    else previousSnapshot = resolve;
  });
  const loadingHistory = state.refreshSessionHistory(first);
  const polling = state.poll();
  let selected = 'one';
  const calls = [];
  state.request = async (path, input) => {
    calls.push(path);
    if (path === '/session/open' || path === '/open') selected = input.id;
    const current = snapshot(syncCursor(11, selected, selected + '-worker'), selected);
    if (path.startsWith('/history')) return { ...current, messages: [{ id: selected + '-message' }] };
    return current;
  };
  assert.equal(await state.requestAction('/open', { id: 'two' }), true);
  assert.equal(await state.requestAction('/open', { id: 'one' }), true);
  previousHistory({ ...first, messages: [{ id: 'stale-message' }] });
  previousSnapshot(first);
  await Promise.all([loadingHistory, polling]);
  assert.equal(state.currentId, 'one');
  assert.equal(state.liveText, 'one');
  assert.deepEqual(state.messages, [{ id: 'one-message' }]);
  assert.deepEqual(calls, ['/session/open', '/session/snapshot?history=1', '/history?id=two&sync=2', '/session/open', '/session/snapshot?history=1', '/history?id=one&sync=2']);
});

test('legacy bridges fall back on a missing snapshot route, while transient errors keep the new protocol', async () => {
  const state = syncFixture();
  state.syncMode = 'probe';
  const calls = [];
  state.request = async path => {
    calls.push(path);
    if (path === '/session/snapshot') throw new BridgeFailure(503, 'unavailable');
    assert.fail('a transient issue must keep the new protocol');
  };
  await assert.rejects(state.requestSessionSnapshot(state.epoch), /unavailable/);
  assert.equal(state.syncMode, 'probe');
  state.request = async path => {
    calls.push(path);
    if (path === '/session/snapshot') throw new BridgeFailure(404, 'not_found');
    return { session: { id: 'one' }, messages: [] };
  };
  await state.requestSessionSnapshot(state.epoch);
  await state.requestSessionSnapshot(state.epoch);
  assert.equal(state.syncMode, 'legacy');
  assert.deepEqual(calls, ['/session/snapshot', '/session/snapshot', '/chat', '/chat']);
});


test('lightweight polls load history only when the committed leaf advances', async () => {
  const state = syncFixture();
  const calls = [];
  let leaf = 'old';
  let seq = 7;
  state.historyStream = 'first-worker';
  state.historyLeaf = leaf;
  state.messages = [{ id: 'older' }, { id: 'old' }];
  state.request = async path => {
    calls.push(path);
    const result = snapshot(syncCursor(seq), 'active', leaf);
    return path.startsWith('/history') ? { ...result, messages: [{ id: 'old' }, { id: leaf }] } : result;
  };
  await state.poll();
  leaf = 'new';
  seq++;
  await state.poll();
  await new Promise(resolve => setImmediate(resolve));
  await state.poll();
  assert.deepEqual(calls, ['/session/snapshot', '/session/snapshot', '/history?id=one&sync=2', '/session/snapshot']);
  assert.deepEqual(state.messages.map(message => message.id), ['older', 'old', 'new']);
});

test('a late idle snapshot cannot overwrite the next run on the same stream', () => {
  const state = syncFixture();
  feedFrame(state, 'ready', syncCursor(7));
  state.applySessionSnapshot(snapshot(syncCursor(7), 'last run'));
  feedFrame(state, 'session/status', syncCursor(8), { idle: true });
  feedFrame(state, 'session/status', syncCursor(9, 'one', 'first-worker', 'run-2'), { idle: false });
  feedFrame(state, 'message/delta', syncCursor(10, 'one', 'first-worker', 'run-2'), { text: 'next run' });
  assert.equal(state.applySessionSnapshot(snapshot(syncCursor(8, 'one', 'first-worker', null))), false);
  state.flushStreamDeltas();
  assert.equal(state.runId, 'run-2');
  assert.equal(state.liveText, 'next run');
});
