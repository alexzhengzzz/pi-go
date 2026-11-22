import assert from 'node:assert/strict';
import { test } from 'node:test';
import './harmony-modules.mjs';

const { SessionStore } = await import('../harmony/entry/src/main/ets/model/SessionStore.ets');
const { SidebarRows } = await import('../harmony/entry/src/main/ets/model/SidebarRows.ets');

function rowsFor(catalog) {
  const rows = new SidebarRows();
  rows.replace(new SessionStore().rows({
    view: 'all', loadedView: 'all', projects: ['/project'], workspaces: [],
    hasWorkspaceDetails: false, expandedSpaces: [], sessions: [], ...catalog,
  }));
  return rows;
}

test('only expanded spaces expose their tasks, with a space anchor for hidden tasks', () => {
  const rows = rowsFor({
    projects: ['/project', '/other'], expandedSpaces: ['/project'],
    sessions: [
      { id: 'one', cwd: '/project', revision: 0 },
      { id: 'offscreen', cwd: '/project', revision: 0 },
      { id: 'hidden', cwd: '/other', revision: 0 },
    ],
  });
  assert.equal(rows.totalCount(), 4);
  assert.equal(rows.anchor('offscreen', '/project'), 2);
  assert.equal(rows.anchor('hidden', '/other'), 3);
  assert.equal(rows.getData(2).session.id, 'offscreen');
});

test('registered space names and discovered history appear in the sidebar', () => {
  const rows = rowsFor({
    hasWorkspaceDetails: true, workspaces: [{ cwd: '/project', name: 'Renamed workspace' }],
    expandedSpaces: ['/history'], sessions: [{ id: 'history', cwd: '/history', name: 'Previous task' }],
  });
  assert.equal(rows.getData(0).key, 'space:/project:Renamed workspace');
  assert.equal(rows.getData(1).path, '/history');
  assert.equal(rows.getData(2).session.id, 'history');
});

test('pagination publishes a stable first page and deduplicates the final catalog', async () => {
  const store = new SessionStore();
  const first = [];
  const paths = [];
  const tail = Promise.withResolvers();
  const load = store.loadCatalog('recent', async path => {
    paths.push(path);
    if (paths.length === 1) return { sessions: [{ id: 'one' }], nextCursor: 100 };
    return tail.promise;
  }, () => true, page => first.push(page));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(first[0].sessions.map(row => row.id), ['one']);
  tail.resolve({ sessions: [{ id: 'one' }, { id: 'two' }], nextCursor: 100 });
  const catalog = await load;
  assert.deepEqual(catalog.sessions.map(row => row.id), ['one', 'two']);
  assert.deepEqual(first[0].sessions.map(row => row.id), ['one']);
  assert.deepEqual(paths, ['/sessions?limit=100&cursor=0&view=recent', '/sessions?limit=100&cursor=100&view=recent']);
});
