import assert from 'node:assert/strict';
import { test } from 'node:test';
import './harmony-modules.mjs';

const { SessionStore } = await import('../harmony/entry/src/main/ets/model/SessionStore.ets');
const { SidebarRows } = await import('../harmony/entry/src/main/ets/model/SidebarRows.ets');

function rowsFor(catalog) {
  const rows = new SidebarRows();
  rows.replace(new SessionStore().rows({
    view: 'all', loadedView: 'all', projects: ['/project'], workspaces: [],
    expandedSpaces: [], sessions: [], ...catalog,
  }));
  return rows;
}

test('only expanded spaces expose their tasks, with a space anchor for hidden tasks', () => {
  const rows = rowsFor({
    projects: ['/project', '/other'], expandedSpaces: ['/project'],
    workspacePages: [{ path: '/project', sessions: [
      { id: 'one', cwd: '/project', revision: 0 },
      { id: 'offscreen', cwd: '/project', revision: 0 },
    ] }],
  });
  assert.equal(rows.totalCount(), 4);
  assert.equal(rows.anchor('offscreen', '/project'), 2);
  assert.equal(rows.anchor('hidden', '/other'), 3);
  assert.equal(rows.getData(2).session.id, 'offscreen');
});

test('discovered history does not create rows in the workspace list', () => {
  const rows = rowsFor({
    workspaces: [{ cwd: '/project', name: 'Renamed workspace' }],
    sessions: [{ id: 'history', cwd: '/history', name: 'Previous task' }],
  });
  assert.equal(rows.getData(0).key, 'space:/project:Renamed workspace');
  assert.equal(rows.totalCount(), 1);
});

test('a workspace path is encoded and returns one requested page', async () => {
  const store = new SessionStore();
  const paths = [];
  const catalog = await store.loadCatalog('all', async (path) => {
    paths.push(path);
    return { sessions: [{ id: 'one' }], nextCursor: 10 };
  }, 0, '/a & b');
  assert.deepEqual(catalog.sessions.map((row) => row.id), ['one']);
  assert.equal(catalog.reply.nextCursor, 10);
  assert.deepEqual(paths, ['/sessions?scope=workspace&limit=10&cursor=0&view=all&cwd=%2Fa%20%26%20b']);
});
