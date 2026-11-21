// The desktop host must translate a phone-side workspace close into Pi
// Desktop's own "remove workspace" semantics: sidebar entry gone, Pi stopped,
// files on disk untouched. The real host module runs against stub collaborators.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, symlink, writeFile, readFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { localRequest } from '../desktop/local-ipc.mjs';

const project = fileURLToPath(new URL('../', import.meta.url));

async function loadHost(ipc, home) {
  // Strip the module's types and drop it into a sandbox with stubbed imports,
  // so the exact source that ships in the Desktop build is what gets exercised.
  const source = await readFile(join(project, 'desktop/pi-go-host.ts'), 'utf8');
  const sandbox = await mkdtemp(join(tmpdir(), 'pigo-host-sandbox-'));
  await mkdir(join(sandbox, 'node_modules/electron'), { recursive: true });
  await writeFile(join(sandbox, 'node_modules/electron/package.json'), JSON.stringify({ name: 'electron', type: 'module', main: 'index.mjs' }));
  await writeFile(join(sandbox, 'node_modules/electron/index.mjs'),
    `export const app = { getPath: (key) => key === 'home' ? ${JSON.stringify(home)} : ${JSON.stringify(join(sandbox, 'user-data'))}, once: () => {} }\n`);
  await mkdir(join(sandbox, 'ipc'), { recursive: true });
  await writeFile(join(sandbox, 'ipc/pi-start-options.mjs'),
    'export const applyModelDefaults = (options) => options\nexport const applyPermissionModeToStartOptions = (options) => options\n');
  await writeFile(join(sandbox, 'ipc/settings.mjs'), 'export const loadAppSettings = async () => ({})\n');
  await writeFile(join(sandbox, 'latest-project-session.mjs'), 'export const engineProjectSessionDirs = async () => []\n');
  await writeFile(join(sandbox, 'pi-paths.mjs'), 'export const getSessionsRoot = () => "/nonexistent"\nexport const isWithinSessionRoots = () => false\n');
  await writeFile(join(sandbox, 'session-metadata.mjs'), 'export const readSessionMetadata = async () => ({})\n');
  await writeFile(join(sandbox, 'workspace-trust.mjs'),
    'export const trustedPaths = []\nexport const workspaceTrustStore = { trust: async (path) => { trustedPaths.push(path) } }\n');
  await writeFile(join(sandbox, 'pi-go-host.mjs'),
    stripTypeScriptTypes(source).replace(/from '(\.\/[^']+)'/g, (match, specifier) =>
      specifier.endsWith('.mjs') ? match : `from '${specifier}.mjs'`));
  const previous = process.env.PIGO_IPC_DIR;
  const previousHost = process.env.PIGO_DESKTOP_HOST;
  // The host reads both variables when registerPiGoHost is CALLED, not when the
  // module loads, so they must stay set until the test is done with the server.
  process.env.PIGO_IPC_DIR = ipc;
  process.env.PIGO_DESKTOP_HOST = '1';
  try {
    const loaded = await import(join(sandbox, 'pi-go-host.mjs'));
    const { trustedPaths } = await import(join(sandbox, 'workspace-trust.mjs'));
    return { registerPiGoHost: loaded.registerPiGoHost, trustedPaths, restoreEnv: () => {
      if (previous === undefined) delete process.env.PIGO_IPC_DIR; else process.env.PIGO_IPC_DIR = previous;
      if (previousHost === undefined) delete process.env.PIGO_DESKTOP_HOST; else process.env.PIGO_DESKTOP_HOST = previousHost;
    } };
  } finally {
    await rm(sandbox, { force: true, recursive: true });
  }
}

test('closing a workspace removes it from Desktop without touching disk files', { timeout: 30000 }, async (context) => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'pigo-host-close-')));
  context.after(async () => { await rm(root, { force: true, recursive: true }); });
  const ipc = join(root, 'ipc');
  await mkdir(ipc, { mode: 0o700 });
  await chmod(ipc, 0o700);

  // A real project folder with content, reached through a symlink like macOS /tmp.
  const folder = join(root, 'my-project');
  await mkdir(folder);
  await writeFile(join(folder, 'notes.txt'), 'keep me');
  const alias = join(root, 'alias-project');
  await symlink(folder, alias);
  // Managed worktrees live on disk too; only their workspace kind differs.
  const worktreeDir = join(root, 'wt');
  await mkdir(worktreeDir);

  // A mutable workspace list, mirroring WorkspaceManager's own state.
  const spaces = [
    { id: 'ws-folder', name: 'My Project', path: alias, kind: 'folder' },
    { id: 'ws-worktree', name: 'Managed checkout', path: worktreeDir, kind: 'worktree' },
  ];
  const removed = [];
  const reassigned = [];
  const workspaces = {
    getWorkspaces: () => spaces.slice(),
    createWorkspace: async (name, path) => {
      if (name === '失败') throw new Error('failed to register');
      const workspace = { id: 'created', name, path, kind: 'folder' };
      spaces.push(workspace);
      return workspace;
    },
    removeWorkspace: async (id) => {
      const index = spaces.findIndex((workspace) => workspace.id === id);
      if (index === -1) throw new Error('workspace not found');
      spaces.splice(index, 1);
      removed.push(id);
      return {};
    },
  };
  const { registerPiGoHost, trustedPaths, restoreEnv } = await loadHost(ipc, root);
  // The host only unregisters on Electron's will-quit; in the test harness we
  // close its listening socket directly so the process can exit.
  context.after(async () => {
    restoreEnv();
    for (const handle of process._getActiveHandles()) {
      if (handle?.listening === true && String(handle._pipeName ?? '').endsWith(`host-${process.pid}.sock`)) {
        handle.closeAllConnections();
        await new Promise((resolve) => handle.close(() => resolve()));
      }
    }
  });
  registerPiGoHost(workspaces, {}, { reassignToGlobal: async (id) => { reassigned.push(id); } });

  const socket = join(ipc, `host-${process.pid}.sock`);
  assert.equal((await localRequest(socket, 'GET', '/health')).data.canCreateWorkspace, true);

  assert.deepEqual(await localRequest(socket, 'POST', '/catalog', { cwd: folder }),
    { status: 200, data: { sessions: [] } });
  assert.deepEqual(trustedPaths, []);
  assert.equal((await localRequest(socket, 'POST', '/authorize', { cwd: folder })).status, 200);
  assert.deepEqual(trustedPaths, [alias]);

  const create = (name) => localRequest(socket, 'POST', '/create-workspace', { name });
  const parent = join(root, 'Pi Go', 'Spaces');
  for (const name of ['', '..', '/outside', 'a/b', 'a\\b', 'a\nb', 'a'.repeat(81)]) {
    assert.deepEqual(await create(name), { status: 400, data: { error: 'invalid_workspace_name' } });
  }
  const cwd = join(parent, '测试 空间');
  assert.deepEqual(await create('  测试 空间  '), { status: 200, data: { cwd } });
  assert.deepEqual(spaces.at(-1), { id: 'created', name: '测试 空间', path: cwd, kind: 'folder' });
  assert.ok((await localRequest(socket, 'POST', '/projects', {})).data.projects.includes(cwd));
  assert.deepEqual(await create('测试 空间'), { status: 409, data: { error: 'workspace_exists' } });
  await symlink(folder, join(parent, 'alias'));
  assert.deepEqual(await create('alias'), { status: 409, data: { error: 'workspace_exists' } });
  assert.deepEqual(await create('失败'), { status: 500, data: { error: 'desktop_create_workspace_failed' } });
  await mkdir(join(parent, '失败'));

  // Closing through the real path stops and unregisters the workspace that was
  // registered under a symlinked alias, and hands its notes to the global scope
  // exactly like the Desktop UI's own remove-workspace flow.
  const closed = await localRequest(socket, 'POST', '/close-workspace', { cwd: folder });
  assert.equal(closed.status, 200);
  assert.equal(closed.data.closed, true);
  assert.deepEqual(removed, ['ws-folder']);
  assert.deepEqual(reassigned, ['ws-folder']);
  // The files stay exactly as they were: close, not delete.
  assert.equal(await readFile(join(folder, 'notes.txt'), 'utf8'), 'keep me');

  // Managed worktrees would be deleted from disk, so Pi Go refuses to close them.
  const worktree = await localRequest(socket, 'POST', '/close-workspace', { cwd: worktreeDir });
  assert.equal(worktree.status, 409);
  assert.equal(worktree.data.error, 'desktop_workspace_kind_unsupported');

  // Two workspaces pointing at the same folder: refuse instead of guessing.
  spaces.push({ id: 'ws-clone', name: 'Same folder twice', path: folder, kind: 'folder' },
    { id: 'ws-alias', name: 'Same folder again', path: alias, kind: 'folder' });
  const ambiguous = await localRequest(socket, 'POST', '/close-workspace', { cwd: folder });
  assert.equal(ambiguous.status, 409);
  assert.equal(ambiguous.data.error, 'desktop_workspace_ambiguous');

  // Unknown folders and malformed input never reach removeWorkspace.
  const unknown = await localRequest(socket, 'POST', '/close-workspace', { cwd: join(root, 'ghost') });
  assert.equal(unknown.status, 404);
  assert.equal(unknown.data.error, 'desktop_workspace_not_registered');
  const malformed = await localRequest(socket, 'POST', '/close-workspace', {});
  assert.equal(malformed.status, 400);
  assert.equal(malformed.data.error, 'invalid_target');
  assert.deepEqual(removed, ['ws-folder']);
});
