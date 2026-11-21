import { existsSync, lstatSync, mkdirSync } from 'node:fs'
import { readdir, realpath, stat } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { app } from 'electron'
import { applyModelDefaults, applyPermissionModeToStartOptions } from './ipc/pi-start-options'
import { loadAppSettings } from './ipc/settings'
import { engineProjectSessionDirs } from './latest-project-session'
import { getSessionsRoot, isWithinSessionRoots } from './pi-paths'
import { readSessionMetadata } from './session-metadata'
import type { WorkspaceManager } from './workspace-manager'
import type { PiEventRouter } from './pi-event-router'
import { workspaceTrustStore } from './workspace-trust'

const sessionIdPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i

async function history(cwd: string, id?: string) {
  const candidates: { file: string; modified: number }[] = []
  const directories = new Set(await engineProjectSessionDirs('pi', cwd))
  if (id) {
    for (const entry of await readdir(getSessionsRoot(), { withFileTypes: true }).catch(() => [])) {
      if (entry.isDirectory()) directories.add(join(getSessionsRoot(), entry.name))
    }
  }
  for (const directory of directories) {
    const root = await realpath(directory).catch(() => undefined)
    if (!root || !isWithinSessionRoots(root)) continue
    const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith('.jsonl')) continue
      if (id && entry.name !== `${id}.jsonl` && !entry.name.endsWith(`_${id}.jsonl`)) continue
      const file = await realpath(join(root, entry.name)).catch(() => undefined)
      if (!file || dirname(file) !== root || !isWithinSessionRoots(file)) continue
      const info = await stat(file).catch(() => undefined)
      if (info?.isFile()) candidates.push({ file, modified: info.mtimeMs })
    }
  }
  if (id && candidates.length !== 1) return []
  candidates.sort((left, right) => right.modified - left.modified)
  const rows = []
  for (const candidate of candidates.slice(0, 100)) {
    const { header, name, preview, contentState } = await readSessionMetadata(candidate.file)
    if (!header?.cwd || !sessionIdPattern.test(header.id) || (id && header.id !== id) ||
      await realpath(header.cwd).catch(() => undefined) !== cwd || contentState === 'empty') continue
    rows.push({ file: candidate.file, id: header.id, name: (name || preview)?.slice(0, 100),
      modified: new Date(candidate.modified).toISOString() })
  }
  return rows
}

type PiGoNotes = { reassignToGlobal(workspaceId: string): Promise<void> }

export function registerPiGoHost(workspaces: WorkspaceManager, dialogs: PiEventRouter, notes?: PiGoNotes): void {
  if ((process.env.PIGO_DESKTOP_HOST !== '1' && !existsSync(join(process.resourcesPath, 'pi-go-host-enabled'))) || typeof process.getuid !== 'function') return
  const uid = process.getuid()
  const directory = resolve(process.env.PIGO_IPC_DIR ?? join(tmpdir(), `pigo-${uid}`))
  let info
  try {
    try { mkdirSync(directory, { mode: 0o700 }) } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') return
    }
    info = lstatSync(directory)
  } catch {
    return
  }
  if (!info.isDirectory() || info.uid !== uid || (info.mode & 0o077) !== 0) return
  const path = join(directory, `host-${process.pid}.sock`)
  const profile = createHash('sha256').update(JSON.stringify([app.getPath('userData'), process.env.PI_CODING_AGENT_DIR ?? ''])).digest('hex')
  if (Buffer.byteLength(path) > 100) return
  let pending = false
  let quitting = false
  const server = createServer({ requestTimeout: 3000, headersTimeout: 3000 }, async (request, response) => {
    const reply = (status: number, data: object): void => {
      response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
      response.end(JSON.stringify(data))
    }
    if (request.method === 'GET' && request.url === '/health') return reply(200, { protocol: 'pi-go-desktop-host/1', profile })
    if (request.method !== 'POST' || !['/open', '/new', '/catalog', '/projects', '/authorize', '/pending', '/answer', '/close-workspace'].includes(request.url ?? '') || request.headers.origin !== undefined) {
      return reply(404, { error: 'not_found' })
    }
    const mutating = request.url === '/open' || request.url === '/new' || request.url === '/close-workspace'
    if (quitting || (mutating && pending)) return reply(409, { error: 'desktop_busy' })
    if (mutating) pending = true
    try {
      const chunks: Buffer[] = []
      let length = 0
      for await (const chunk of request.iterator({ destroyOnReturn: false })) {
        length += chunk.length
        if (length > 8192) return reply(400, { error: 'invalid_target' })
        chunks.push(chunk)
      }
      const input = JSON.parse(Buffer.concat(chunks).toString('utf8')) as {
        cwd?: unknown; id?: unknown; pid?: unknown; pendingId?: unknown; answer?: unknown
      }
      if (request.url === '/pending' || request.url === '/answer') {
        const runtime = workspaces.getSessionRuntimes().find((entry) => entry.status === 'running' &&
          entry.pid === input.pid && entry.sessionId === input.id)
        const manager = runtime?.sessionId && workspaces.getPiManagerForSession(runtime.workspaceId, runtime.sessionId)
        if (!manager) return reply(409, { error: 'session_changed' })
        if (request.url === '/answer') {
          if (typeof input.pendingId !== 'string' || !dialogs.respondFromPiGo(manager, input.pendingId, input.answer)) {
            return reply(409, { error: 'interaction_unavailable' })
          }
          return reply(200, { answered: true })
        }
        const event = dialogs.pendingForPiGo(manager)
        return reply(200, event ? { interaction: { id: event.id, method: event.method,
          title: event.title, message: event.message, options: event.options,
          placeholder: event.method === 'input' ? event.placeholder : undefined,
          prefill: event.method === 'editor' ? event.prefill : undefined } } : {})
      }
      if (request.url === '/projects') {
        const projects = await Promise.all(workspaces.getWorkspaces()
          .map((workspace) => realpath(workspace.path).catch(() => undefined)))
        return reply(200, { projects: [...new Set(projects.filter((path): path is string => path !== undefined))] })
      }
      if (request.url === '/close-workspace') {
        // Pi Go mirrors Desktop's own "remove workspace": the folder leaves the
        // sidebar and its Pi processes stop, while files on disk are untouched.
        if (typeof input.cwd !== 'string') return reply(400, { error: 'invalid_target' })
        const cwd = await realpath(input.cwd).catch(() => undefined)
        const known = await Promise.all(workspaces.getWorkspaces().map(async (workspace) => ({
          workspace, path: await realpath(workspace.path).catch(() => undefined),
        })))
        const registered = known.filter((item) => cwd !== undefined && item.path === cwd)
        if (!cwd || registered.length === 0) return reply(404, { error: 'desktop_workspace_not_registered' })
        if (registered.length > 1) return reply(409, { error: 'desktop_workspace_ambiguous' })
        const workspace = registered[0].workspace
        // Managed worktrees and linked-task checkouts would be deleted from disk,
        // so Pi Go only closes plain folders remotely.
        if (workspace.kind !== 'folder' || workspace.linkedTask) return reply(409, { error: 'desktop_workspace_kind_unsupported' })
        const removed = await workspaces.removeWorkspace(workspace.id)
        if (notes) await notes.reassignToGlobal(workspace.id).catch(() => undefined)
        return reply(200, { closed: true, cwd, ...removed })
      }
      const opening = request.url === '/open'
      if (typeof input.cwd !== 'string' || (opening && (typeof input.id !== 'string' || !sessionIdPattern.test(input.id)))) {
        return reply(400, { error: 'invalid_target' })
      }
      const cwd = await realpath(input.cwd).catch(() => undefined)
      const known = await Promise.all(workspaces.getWorkspaces().map(async (workspace) => ({
        workspace, path: await realpath(workspace.path).catch(() => undefined),
      })))
      const registered = known.filter((item) => cwd !== undefined && item.path === cwd)
      let workspace = registered[0]?.workspace
      // Pi Go treats an authorized project as trusted when it is registered or opened.
      const sessionPath = opening && cwd ? (await history(cwd, input.id as string))[0]?.file : undefined
      const computerHistory = opening && sessionPath !== undefined
      const register = computerHistory || request.url === '/authorize' || request.url === '/new'
      if (register && cwd && registered.length === 0 && (await stat(cwd).catch(() => undefined))?.isDirectory()) {
        workspace = await workspaces.createWorkspace(basename(cwd), cwd)
      }
      if (!cwd || !workspace || registered.length > 1) {
        return reply(403, { error: 'desktop_workspace_untrusted' })
      }
      if (opening && !sessionPath) return reply(404, { error: 'desktop_session_not_found' })
      await workspaceTrustStore.trust(workspace.path)
      if (request.url === '/authorize') return reply(200, { cwd, profile })
      if (request.url === '/catalog') {
        return reply(200, { sessions: (await history(cwd)).map(({ id, name, modified }) => ({ id, name, modified })) })
      }
      const settings = await loadAppSettings(workspaces)
      if (quitting || response.destroyed) return
      let runtime = workspaces.preparePiGoRuntime(workspace.id, sessionPath)
      if (runtime.status === 'starting') return reply(409, { error: 'desktop_busy' })
      if (runtime.status !== 'running') {
        const options = applyModelDefaults({ cwd: workspace.path, engine: 'pi', ...(sessionPath ? { sessionPath } : {}) }, settings)
        runtime = await workspaces.startSessionRuntime(runtime.runtimeId, applyPermissionModeToStartOptions(options, settings))
      }
      if (quitting || response.destroyed) return
      if (runtime.closed || runtime.status !== 'running' || !runtime.sessionId || (opening && runtime.sessionId !== input.id)) {
        return reply(409, { error: 'desktop_session_not_ready' })
      }
      const pi = workspaces.getPiManagerForSession(workspace.id, runtime.sessionId)
      const state = (await pi?.sendCommand({ type: 'get_state' }))?.data as { isStreaming?: boolean; isCompacting?: boolean; sessionId?: string } | undefined
      if (!pi || state?.sessionId !== runtime.sessionId || state.isStreaming || state.isCompacting) {
        return reply(409, { error: 'desktop_busy' })
      }
      if (quitting || response.destroyed) return
      const shared = await pi.sendCommand({ type: 'prompt', message: '/pi-go-share desktop-host' })
      if (!shared?.success) return reply(409, { error: 'desktop_share_failed' })
      return reply(200, { id: runtime.sessionId })
    } catch {
      if (!response.headersSent) reply(409, { error: 'desktop_handoff_failed' })
    } finally {
      if (mutating) pending = false
    }
  })
  server.maxConnections = 4
  server.setTimeout(15000, (socket) => socket.destroy())
  server.on('error', () => {})
  server.listen(path)
  app.once('will-quit', () => {
    quitting = true
    server.close()
    server.closeAllConnections()
  })
}
