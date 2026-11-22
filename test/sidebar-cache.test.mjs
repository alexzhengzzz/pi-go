import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Exercise the actual page methods without requiring an ArkUI device runtime.
const syncSource = readFileSync(new URL('../harmony/entry/src/main/ets/SessionSync.ets', import.meta.url), 'utf8');
const { SessionSync } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(syncSource)).toString('base64')}`);
class BridgeFailure extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

const page = readFileSync(new URL('../harmony/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
function method(name) {
  const start = page.search(new RegExp(`  private (?:async )?${name}\\(`));
  assert.ok(start >= 0, `Missing page method: ${name}`);
  const end = page.indexOf('\n  }', start) + 4;
  return page.slice(start, end);
}
const methods = ['setDrawer', 'loadSessions', 'requestAction', 'positionTranscript', 'poll', 'loadSessionStatus', 'applyRunningStatus', 'backgroundRunning', 'backgroundActive', 'sessionState', 'sessionRunning'];
methods.push('spaceSessions');
methods.push('cacheChat', 'presentChat', 'revealChat', 'send', 'mergeTranscript', 'sameMessage', 'applyLiveSnapshot',
  'handleFrame', 'applyStreamFrame', 'requestSessionSnapshot', 'applySessionSnapshot', 'refreshSessionHistory',
  'applySessionHistory', 'stopStream', 'streamDown', 'queueStreamPaint', 'flushStreamDeltas', 'finishSend', 'reconcileSteering');
methods.push('chooseComputer', 'leaveComputer', 'persistComputers', 'pair', 'resetFileTree', 'closeFileEditor');
methods.push('appendFileTreeRows', 'updateFileTree', 'toggleFileDirectory', 'loadFileDirectory');
methods.push('newTaskOptions', 'closeNewSpace', 'createWorkspaceTask', 'createSpaceTask', 'confirmCloseSpace', 'closeWorkspace', 'armTranscriptFollow', 'onKeyboardChange');
methods.push('dockedSessions', 'sessionPaneWidth', 'compactSessionPane', 'onWindowWidthChange');
methods.push('chatTitle', 'observeSessionRun', 'observeRun', 'advanceRunNotice', 'clearRunNotices');
const splitWidth = page.match(/^const SPLIT_WINDOW_WIDTH = \d+;$/m)[0];
const Page = new Function('Curve', 'BridgeFailure', 'validUsb', 'MAX_COMPUTERS', 'Edge', '$r', 'DialogAlignment', stripTypeScriptTypes(`${splitWidth}\nconst STREAM_PAINT_INTERVAL_MS = 32;\nconst MAX_LIVE_TEXT_LENGTH = 16000;\nclass Harness {\n${methods.map(method).join('\n')}\n}`) + '; return Harness;')(
  { EaseOut: 0 },
  BridgeFailure,
  (address) => address === 'http://127.0.0.1:18977',
  12,
  { Bottom: 'bottom' },
  resource => resource,
  { Bottom: 'bottom' }
);
function fixture() {
  const state = new Page();
  Object.assign(state, {
    resetVoice: () => {}, resetCommands: () => {}, syncCommandPalette: () => {},
    fileDirectories: new Map(),
    syncMode: 'legacy', busy: false, sessionLoading: false, epoch: 1, reachable: true,
    runningSessionIds: [], runningSessions: [], sessionStatusAt: 0, runningCatalogAt: 0, currentId: '', idle: true, queued: false,
    observedRuns: new Map(), pendingRunNotices: [], runNoticeTimer: -1, messages: [],
    liveText: '', liveThinking: '', liveThinkSeq: 0, liveThinkingOpen: false, thinkingOpenIds: [],
    liveTools: [], liveSeq: 0, liveRevision: 0, streamAlive: false, queuedSteering: [],
    deltaPaintTimer: -1, pendingLiveText: '', pendingLiveThinking: '',
    sessionCatalogLoaded: true, sessionCatalogUpdatedAt: Date.now(), sessionCatalogVersion: 0,
    sessions: [{ id: 'one', cwd: '/project', name: 'Cached task' }], projects: ['/project'],
    sessionView: 'all', loadedView: 'all',
    showSessions: false, chatCache: new Map(),
    draftKey: id => id, loadSessionStatus: async () => {}, dismissKeyboard: () => {},
    getUIContext: () => ({ animateTo: (_options, change) => change(),
      getPromptAction: () => ({ showToast: () => {} }) })
  });
  return state;
}
const historyHandler = page.match(/\.id\('history'\)[\s\S]*?\.onClick\(\(\) => \{([^}]+)\}\)/)[1];
const clickHistory = new Function(historyHandler);

test('editor keyboard events leave the hidden chat transcript alone', () => {
  const state = fixture();
  Object.assign(state, {
    editingPath: 'aa.md', keyboardHeight: 300, transcriptFollow: false,
    transcript: { currentOffset() { assert.fail('editor keyboard queried the chat scroller'); } }
  });
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
  await state.pair();
  assert.deepEqual(requests, [['/pair', { ticket: '12345678' },
    { address: usbAddress, token: '', ca: undefined, pin: undefined }]]);
  assert.deepEqual([state.base, state.ca, state.pin, state.token],
    [active.address, active.ca, active.pin, active.token]);
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

test('reopening the sidebar uses the fresh catalog without another request', () => {
  const state = fixture();
  let requests = 0;
  state.request = async () => { requests++; return { sessions: [] }; };
  clickHistory.call(state);
  assert.equal(state.showSessions, true);
  assert.equal(requests, 0);
  assert.equal(state.busy, false);
  assert.equal(state.sessions[0].id, 'one');
});

test('an open drawer docks on unfold and folding back reveals the same conversation', () => {
  const state = fixture();
  Object.assign(state, { windowWidth: 459, isPaired: true, activeTab: 'tasks', currentId: 'one', draft: 'Keep this' });
  clickHistory.call(state);
  assert.equal(state.showSessions, true);
  assert.equal(state.dockedSessions(), false);

  state.windowWidth = 711;
  state.onWindowWidthChange();
  assert.equal(state.dockedSessions(), true);
  assert.equal(state.showSessions, false);
  assert.ok(711 - state.sessionPaneWidth() >= 460);
  clickHistory.call(state);
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
  state.fileRoot = '/project';
  const requests = [];
  const entry = (path, kind = 'file') => ({ path, name: path.split('/').at(-1), kind });
  state.request = async (_endpoint, { path, cursor }) => {
    requests.push([path, cursor]);
    if (!path) return { entries: [entry('src', 'directory'), entry('README.md')] };
    if (path === 'src/empty') return { entries: [] };
    if (cursor === 100) return { entries: [entry('src/index.ts'), entry('src/utils.ts')] };
    return { entries: [entry('src/empty', 'directory'), entry('src/index.ts')], nextCursor: 100 };
  };
  const rows = () => state.fileTreeRows.map(({ path, kind, depth }) => [path, kind, depth]);
  const rootRows = [['src', 'directory', 0], ['README.md', 'file', 0]];
  await state.loadFileDirectory('');
  assert.deepEqual(rows(), rootRows);
  await state.toggleFileDirectory('src');
  assert.deepEqual(rows(), [rootRows[0], ['src/empty', 'directory', 1], ['src/index.ts', 'file', 1],
    ['src', 'more', 1], rootRows[1]]);
  await state.loadFileDirectory('src', true);
  await state.toggleFileDirectory('src/empty');
  const expandedRows = [rootRows[0], ['src/empty', 'directory', 1], ['src/empty', 'empty', 2],
    ['src/index.ts', 'file', 1], ['src/utils.ts', 'file', 1], rootRows[1]];
  assert.deepEqual(rows(), expandedRows);
  await state.toggleFileDirectory('src');
  assert.deepEqual(rows(), rootRows);
  await state.toggleFileDirectory('src');
  assert.deepEqual(rows(), expandedRows);
  assert.deepEqual(requests, [['', 0], ['src', 0], ['src', 100], ['src/empty', 0]]);
  await state.loadFileDirectory('');
  assert.deepEqual(rows(), rootRows);
  await state.toggleFileDirectory('src');
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


test('repeated opens share one stale refresh and reuse the loaded catalog', async () => {
  const state = fixture();
  state.sessionCatalogUpdatedAt = 0;
  let requests = 0;
  let finish;
  state.request = () => {
    if (++requests === 1) return new Promise(resolve => { finish = resolve; });
    return Promise.resolve({ sessions: [{ id: 'page-two' }] });
  };
  clickHistory.call(state);
  state.setDrawer(false);
  clickHistory.call(state);
  assert.equal(requests, 1);
  assert.equal(state.busy, false);
  finish({ sessions: [{ id: 'one' }], nextCursor: 100 });
  await new Promise(resolve => setImmediate(resolve));
  state.setDrawer(false);
  clickHistory.call(state);
  assert.equal(requests, 2);
  assert.deepEqual(state.sessions.map(session => session.id), ['one', 'page-two']);
});

test('a failed catalog page keeps the cached spaces and tasks and can be retried', async () => {
  const state = fixture();
  let fail = true;
  state.request = async path => {
    if (path.includes('cursor=0&')) return { sessions: [{ id: 'two' }], projects: ['/new'], nextCursor: 100 };
    if (fail) throw new Error('offline');
    return { sessions: [{ id: 'three' }], projects: ['/new'] };
  };
  await state.loadSessions();
  assert.equal(state.sessions[0].id, 'one');
  assert.deepEqual(state.projects, ['/project']);
  assert.equal(state.busy, false);
  assert.equal(state.sessionLoading, false);
  assert.equal(state.sessionCatalogFailed, true);
  fail = false;
  await state.loadSessions();
  assert.deepEqual(state.sessions.map(session => session.id), ['two', 'three']);
  assert.deepEqual(state.projects, ['/new']);
  assert.equal(state.sessionCatalogFailed, false);
});

test('the space plus creates a task directly in that space', () => {
  const state = fixture();
  const requests = [];
  state.desktopHandoff = true;
  state.requestAction = async (...args) => { requests.push(args); return false; };

  state.createSpaceTask('/project');
  assert.equal(state.activeTab, 'tasks');
  assert.deepEqual(requests, [['/new', { cwd: '/project' }]]);
});

test('the empty new-task menu can create one space and open its first task', async () => {
  const state = fixture();
  Object.assign(state, { projects: [], expandedSpaces: [], desktopHandoff: true, scheduleSidebarSave: () => {} });
  assert.deepEqual(state.newTaskOptions(), []);
  state.canCreateWorkspace = true;
  const [option] = state.newTaskOptions();
  assert.equal(option.value, '新空间');
  option.action();
  assert.equal(state.showNewSpace, true);
  state.closeNewSpace();
  assert.equal(state.showNewSpace, false);

  const requests = [];
  const cwd = '/Pi Go/Spaces/测试 空间';
  state.request = async (...args) => { requests.push(args); return { cwd }; };
  state.requestAction = async (...args) => { requests.push(args); return true; };
  option.action();
  state.newSpaceName = '../outside';
  await state.createWorkspaceTask();
  assert.ok(state.newSpaceError);
  assert.deepEqual(requests, []);
  state.newSpaceName = '  测试 空间  ';
  await Promise.all([state.createWorkspaceTask(), state.createWorkspaceTask()]);
  assert.deepEqual(requests, [['/create-workspace', { name: '测试 空间' }], ['/new', { cwd }]]);
  assert.deepEqual(state.projects, [cwd]);
  assert.deepEqual(state.expandedSpaces, [cwd]);
  assert.equal(state.showNewSpace, false);
});

test('the sidebar keeps a created space if its first task fails to open', async () => {
  const state = fixture();
  const messages = [];
  Object.assign(state, {
    canCreateWorkspace: true, showNewSpace: true, newSpaceName: '测试', expandedSpaces: [],
    scheduleSidebarSave: () => {}, request: async () => ({ cwd: '/spaces/测试' }),
    requestAction: async () => { state.epoch++; state.status = '暂时无法打开任务。'; return false; },
    getUIContext: () => ({ getPromptAction: () => ({ showToast: ({ message }) => messages.push(message) }) })
  });
  await state.createWorkspaceTask();
  assert.ok(state.projects.includes('/spaces/测试'));
  assert.deepEqual(messages, ['空间已创建。暂时无法打开任务。']);
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
  for (const field of ['epoch', 'sessionCatalogVersion']) {
    const state = fixture();
    let finish;
    state.request = () => new Promise(resolve => { finish = resolve; });
    const pending = state.loadSessions();
    state[field]++;
    finish({ sessions: [{ id: 'outdated' }] });
    await pending;
    assert.equal(state.sessions[0].id, 'one');
    assert.equal(state.sessionLoading, false);
  }
});

test('recent tasks load and paginate through the recent catalog', async () => {
  const state = fixture();
  state.sessionView = 'recent';
  const paths = [];
  state.request = async path => {
    paths.push(path);
    return paths.length === 1 ? { sessions: [{ id: 'recent' }], nextCursor: 100 } : { sessions: [{ id: 'older' }] };
  };
  await state.loadSessions();
  assert.deepEqual(paths, ['/sessions?limit=100&cursor=0&view=recent', '/sessions?limit=100&cursor=100&view=recent']);
  assert.deepEqual(state.sessions.map(session => session.id), ['recent', 'older']);
  assert.equal(state.loadedView, 'recent');
});

test('opening the sidebar loads older tasks even when whole pages belong to a collapsed space', async () => {
  const state = fixture();
  state.sessionCatalogLoaded = false;
  const cursors = [];
  state.request = async path => {
    const { searchParams } = new URL(path, 'http://test');
    const cursor = Number(searchParams.get('cursor'));
    const limit = Number(searchParams.get('limit'));
    const projects = ['/project', '/other'];
    cursors.push(cursor);
    if (cursor === 0) return { projects, sessions: Array.from({ length: limit }, (_, index) =>
      ({ id: `other-${index}`, cwd: '/other' })), nextCursor: limit };
    return { projects, sessions: [{ id: 'other-0', cwd: '/other' }, { id: 'older', cwd: '/project' }] };
  };
  clickHistory.call(state);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(state.spaceSessions('/project').map(session => session.id), ['older']);
  assert.equal(state.spaceSessions('/other').filter(session => session.id === 'other-0').length, 1);
  assert.equal(cursors.length, 2);
  assert.doesNotMatch(page, /\.id\('session-more'\)/);
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
    schedule: () => {}, cancelSchedule: () => {}, setInteraction: () => {}, resetVoice: () => {}
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
    if (path === '/open') return { session: { id: 'two' } };
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
  state.chatCache = new Map([['two', {
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
  const state = fixture();
  Object.assign(state, { visible: true, currentId: 'one', schedule: () => {} });
  context.after(() => state.clearRunNotices());
  const session = { id: 'one', idle: true };
  state.observeSessionRun(session);
  assert.equal(state.runNotice, undefined);
  state.applyStreamFrame({ type: 'session/status', idle: false });
  state.applyStreamFrame({ type: 'session/status', idle: true, queued: true });
  assert.equal(state.runNotice, undefined);
  state.observeSessionRun(session);
  assert.deepEqual(state.runNotice, { title: 'Cached task', stopped: false });
  state.applyStreamFrame({ type: 'session/status', idle: true });
  state.advanceRunNotice();
  assert.equal(state.runNotice, undefined);

  state.applyStreamFrame({ type: 'session/status', idle: false });
  state.applyStreamFrame({ type: 'session/status', idle: true, aborted: true });
  assert.equal(state.runNotice.stopped, true);
});

test('background banners require a previously running task to be confirmed idle', (context) => {
  const state = fixture();
  Object.assign(state, {
    visible: true, currentId: 'one', sessionLoading: true,
    sessions: [{ id: 'two', name: 'Build' }, { id: 'three', name: 'Closed' }]
  });
  context.after(() => state.clearRunNotices());
  state.applyRunningStatus({ runningSessionIds: ['one', 'two', 'three'], idleSessionIds: [] });
  state.applyRunningStatus(undefined);
  assert.equal(state.runNotice, undefined);
  state.applyRunningStatus({ runningSessionIds: [], idleSessionIds: ['one', 'two'] });
  assert.deepEqual(state.runNotice, { title: 'Build', stopped: false });
  state.applyRunningStatus({ runningSessionIds: [], idleSessionIds: ['one', 'two', 'three'] });
  state.advanceRunNotice();
  assert.equal(state.runNotice, undefined);
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

test('an unknown background task triggers a catalog refresh at most every 30 seconds', async () => {
  const state = fixture();
  state.currentId = 'one';
  state.sessions = [];
  let catalogLoads = 0;
  state.loadSessions = async () => { catalogLoads++; };
  state.applyRunningStatus({ runningSessionIds: ['two'] });
  assert.equal(state.backgroundActive(), true);
  await new Promise(resolve => setImmediate(resolve));
  state.applyRunningStatus({ runningSessionIds: ['two'] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(catalogLoads, 1, 'second status update within 30s must not reload the catalog');
  state.runningCatalogAt -= 31000;
  state.applyRunningStatus({ runningSessionIds: ['two'] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(catalogLoads, 2);
  state.sessions = [{ id: 'two', name: 'Known now' }];
  state.applyRunningStatus({ runningSessionIds: ['two'] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(catalogLoads, 2, 'known tasks never trigger a catalog reload');
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
  state.chatCache.set('one', { session: { id: 'one' }, messages: [{ id: 'old' }] });
  state.chatCache.set('two', { session: { id: 'two' }, messages: [{ id: 'cached' }] });
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
  state.chatCache.set('two', { session: { id: 'two' }, messages: [{ id: 'cached' }] });
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
  state.chatCache.set('two', { session: { id: 'two' }, messages: [{ id: 'cached' }] });
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
  for (let index = 0; index < 10; index++) state.cacheChat({ id: String(index) });
  assert.equal(state.chatCache.size, 8);
  assert.equal(state.chatCache.has('0'), false);
  const cached = state.chatCache.get('9');
  assert.equal(cached.messages.length, 60);
  assert.equal(cached.historyCursor, '60');
});

test('the same session id on a different computer cannot use another computer cache', async () => {
  const state = navigationFixture();
  state.draftKey = id => 'new-computer|' + id;
  state.chatCache.set('old-computer|two', { session: { id: 'two' }, messages: [{ id: 'private-old' }] });
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
  Object.assign(state, { idle: false, unconfirmed: new Map(), draftAttachments: new Map(), draft: 'Change direction' });
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
  Object.assign(state, { idle: false, unconfirmed: new Map(), draftAttachments: new Map(), draft: '', messages: [] });
  state.finishSend('one', { requestId: 'file', text: '', steeringAfter: '', attachments: [{ kind: 'file', name: 'note.md' }] });
  assert.deepEqual(state.queuedSteering[0].files, ['note.md']);
  state.currentId = 'other';
  state.reconcileSteering(true);
  assert.equal(state.queuedSteering.length, 1);
  state.currentId = 'one';
  state.reconcileSteering(true);
  assert.deepEqual(state.queuedSteering, []);
});

test('stream paints combine text and thinking and discard duplicate and finalized deltas', () => {
  const state = navigationFixture();
  const frame = payload => state.handleFrame(JSON.stringify({ sessionId: 'one', ...payload }));
  frame({ type: 'message/delta', text: 'Hello', seq: 1 });
  const timer = state.deltaPaintTimer;
  frame({ type: 'message/delta', text: ' duplicate', seq: 1 });
  frame({ type: 'message/delta', text: ' world', seq: 2 });
  frame({ type: 'message/thinking', text: 'Planning', seq: 1 });
  assert.equal(state.deltaPaintTimer, timer);
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
    sessionSync: new SessionSync(), syncMode: 'sequenced', historyRequest: 0,
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
  assert.equal(state.sessionSync.needsSnapshot(), false);
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
    if (path === '/open') selected = input.id;
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
  assert.deepEqual(calls, ['/open', '/session/snapshot', '/history?id=two&sync=2', '/open', '/session/snapshot', '/history?id=one&sync=2']);
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
