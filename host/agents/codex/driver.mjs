// Codex CLI `codex app-server` driver for Pi Go's worker-core.
//
// Translates Codex app-server JSON-RPC 2.0 methods, notifications, and server
// approval/input requests into the unified AgentSession interface consumed by
// `host/agents/worker-core.mjs`.
import { EventEmitter } from 'node:events';
import { readFileSync, realpathSync, statSync, watchFile, unwatchFile } from 'node:fs';
import { JsonRpcProcess } from '../jsonrpc.mjs';
import { sessionTitlePreview } from '../../bridge/message-view.mjs';
import { codexSessionsRoot, findCodexSession, invalidateCodexCatalog, listCodexSessions } from './catalog.mjs';

const effortLevels = ['low', 'medium', 'high', 'xhigh'];
const approvalChoices = ['允许一次', '本会话允许', '拒绝'];

function extraArgs() {
  if (!process.env.PIGO_CODEX_ARGS) return [];
  try {
    const value = JSON.parse(process.env.PIGO_CODEX_ARGS);
    return Array.isArray(value) && value.every((item) => typeof item === 'string') ? value : [];
  } catch { return []; }
}

function cleanUserText(raw) {
  if (typeof raw !== 'string') return '';
  const marker = '## My request:\n';
  const index = raw.lastIndexOf(marker);
  return (index >= 0 ? raw.slice(index + marker.length) : raw).trim();
}

function mapCodexModel(raw, providerDefault = 'openai') {
  const levels = Array.isArray(raw.supportedReasoningEfforts) && raw.supportedReasoningEfforts.length
    ? raw.supportedReasoningEfforts.map((item) => item.reasoningEffort).filter((e) => effortLevels.includes(e))
    : ['medium'];
  const image = Array.isArray(raw.inputModalities) ? raw.inputModalities.includes('image') : true;
  return {
    provider: providerDefault,
    id: raw.id || raw.model,
    name: raw.displayName || raw.id || raw.model,
    levels: levels.length ? levels : ['medium'],
    reasoning: levels.length > 0,
    image,
    defaultLevel: raw.defaultReasoningEffort || levels[0] || 'medium',
  };
}

function itemToToolActivity(item) {
  if (!item || typeof item !== 'object') return undefined;
  const durationMs = typeof item.durationMs === 'number'
    ? item.durationMs
    : (typeof item.startedAtMs === 'number' && typeof item.completedAtMs === 'number'
      ? Math.max(0, item.completedAtMs - item.startedAtMs) : undefined);

  if (item.type === 'commandExecution') {
    const command = typeof item.command === 'string' ? item.command : '';
    const detail = command.replace(/\s+/g, ' ').trim().slice(0, 120);
    const state = item.status === 'inProgress' ? 'run'
      : (item.status === 'completed' && (item.exitCode === 0 || item.exitCode === null)) ? 'ok'
        : item.status === 'completed' || item.status === 'failed' || item.status === 'declined' ? 'fail' : 'unknown';
    const output = typeof item.aggregatedOutput === 'string' ? item.aggregatedOutput : '';
    return {
      id: item.id,
      summary: { id: item.id, name: 'bash', detail, state, ...(durationMs !== undefined ? { ms: durationMs } : {}) },
      args: { command, cwd: item.cwd },
      result: { content: output ? [{ type: 'text', text: output }] : [] },
      failed: state === 'fail',
      ms: durationMs,
    };
  }

  if (item.type === 'fileChange') {
    const changes = Array.isArray(item.changes) ? item.changes : [];
    const paths = changes.map((c) => c?.path).filter((p) => typeof p === 'string');
    const firstPath = paths[0] ?? '';
    const detail = paths.join(', ').slice(0, 120);
    const state = item.status === 'inProgress' ? 'run'
      : item.status === 'completed' ? 'ok'
        : item.status === 'failed' || item.status === 'declined' ? 'fail' : 'unknown';
    const diffText = changes.map((c) => `${c?.kind ?? 'change'} ${c?.path ?? ''}\n${c?.diff ?? ''}`.trim()).join('\n\n');
    return {
      id: item.id,
      summary: { id: item.id, name: 'edit', detail, state, ...(durationMs !== undefined ? { ms: durationMs } : {}) },
      args: { path: firstPath, files: paths },
      result: { content: diffText ? [{ type: 'text', text: diffText }] : [] },
      failed: state === 'fail',
      ms: durationMs,
    };
  }

  if (item.type === 'mcpToolCall' || item.type === 'dynamicToolCall') {
    const toolName = item.server ? `${item.server}:${item.tool}` : (item.tool || 'tool');
    const args = item.arguments ?? {};
    const detail = typeof args === 'object' && args ? JSON.stringify(args).slice(0, 120) : String(args ?? '').slice(0, 120);
    const state = item.status === 'inProgress' ? 'run'
      : item.status === 'completed' && !item.error && item.success !== false ? 'ok' : 'fail';
    const out = item.error ? JSON.stringify(item.error) : item.result ? JSON.stringify(item.result, null, 2) : '';
    return {
      id: item.id,
      summary: { id: item.id, name: toolName, detail, state, ...(durationMs !== undefined ? { ms: durationMs } : {}) },
      args,
      result: { content: out ? [{ type: 'text', text: out }] : [] },
      failed: state === 'fail',
      ms: durationMs,
    };
  }

  if (item.type === 'webSearch') {
    const query = item.query || item.action?.query || '';
    return {
      id: item.id,
      summary: { id: item.id, name: 'web_search', detail: String(query).slice(0, 120), state: 'ok', ...(durationMs !== undefined ? { ms: durationMs } : {}) },
      args: { query },
      result: { content: [{ type: 'text', text: JSON.stringify(item.action ?? item, null, 2) }] },
      failed: false,
      ms: durationMs,
    };
  }

  return undefined;
}

function turnsToEntries(turns) {
  const entries = [];
  for (const turn of turns) {
    const items = Array.isArray(turn.items) ? turn.items : [];
    const userTexts = [];
    const userImages = [];
    let userId;
    const thinkings = [];
    let thinkingStart;
    let thinkingEnd;
    const tools = [];
    const agentMessages = [];

    for (const item of items) {
      if (item.type === 'userMessage') {
        userId ??= item.id;
        for (const part of item.content ?? []) {
          if (part.type === 'text' && typeof part.text === 'string') {
            userTexts.push(cleanUserText(part.text));
          } else if (part.type === 'localImage' && typeof part.path === 'string') {
            try {
              const bytes = readFileSync(part.path);
              userImages.push({ mimeType: 'image/jpeg', data: bytes.toString('base64') });
            } catch {
              userImages.push({ mimeType: 'image/jpeg', data: '' });
            }
          } else if (part.type === 'image') {
            userImages.push({ mimeType: 'image/jpeg', data: '' });
          } else if (part.type === 'skill' && typeof part.name === 'string') {
            userTexts.unshift(`/skill:${part.name}`);
          }
        }
        continue;
      }
      if (item.type === 'reasoning') {
        const text = [...(item.summary ?? []), ...(item.content ?? [])].filter(Boolean).join('\n').trim();
        if (text) thinkings.push(text);
        if (typeof item.startedAtMs === 'number') thinkingStart = thinkingStart === undefined ? item.startedAtMs : Math.min(thinkingStart, item.startedAtMs);
        if (typeof item.completedAtMs === 'number') thinkingEnd = thinkingEnd === undefined ? item.completedAtMs : Math.max(thinkingEnd, item.completedAtMs);
        continue;
      }
      if (item.type === 'agentMessage') {
        if (typeof item.text === 'string' && item.text) agentMessages.push(item);
        continue;
      }
      const tool = itemToToolActivity(item);
      if (tool) tools.push(tool);
    }

    if (userId || userTexts.length || userImages.length) {
      entries.push({
        id: userId || `${turn.id}:user`,
        turnId: turn.id,
        role: 'user',
        text: userTexts.filter(Boolean).join('\n'),
        images: userImages.filter((img) => img.data),
        imageCount: userImages.length,
      });
    }

    const combinedText = agentMessages.map((m) => m.text).join('\n\n');
    const combinedThinking = thinkings.join('\n\n');
    if (combinedText || combinedThinking || tools.length) {
      const lastMsg = agentMessages.at(-1);
      const thinkingMs = thinkingStart !== undefined && thinkingEnd !== undefined && thinkingEnd >= thinkingStart
        ? thinkingEnd - thinkingStart : (typeof turn.durationMs === 'number' ? turn.durationMs : undefined);
      entries.push({
        id: lastMsg?.id || `${turn.id}:assistant`,
        turnId: turn.id,
        role: 'assistant',
        text: combinedText,
        thinking: combinedThinking || undefined,
        thinkingMs,
        tools: tools.length ? tools : undefined,
      });
    }
  }
  return entries;
}

export class CodexDriver extends EventEmitter {
  constructor({ cwd, sessionId, attach = false, scheduled = false }) {
    super();
    this.agent = 'codex';
    this.cwd = realpathSync(cwd);
    this.initialSessionId = sessionId;
    this.attach = attach;
    this.scheduled = scheduled;
    this.permission = process.env.PIGO_CODEX_PERMISSION === 'ask' ? 'ask' : 'bypass';
    this.capabilities = {
      steer: true,
      followUp: true,
      images: true,
      models: true,
      thinking: true,
      commands: true,
      rename: true,
      fork: true,
      regenerate: false,
      approvals: true,
    };
    this.thread = undefined;
    this.writerClaimed = false;
    this.activeTurnId = undefined;
    this.currentModelId = undefined;
    this.currentProvider = 'openai';
    this.thinkingLevel = 'medium';
    this.modelsCache = [];
    this.skillsCache = [];
    this.cachedEntries = [];
    this.entriesDirty = true;
    this.uiQueue = [];
    this.titlePreview = undefined;
    this.rolloutPath = undefined;
    this.rolloutMtime = 0;
    this.rolloutSize = 0;
    this.restartingRpc = undefined;
    try { this.historyDirectory = realpathSync(codexSessionsRoot()); } catch { this.historyDirectory = undefined; }
  }

  approvalPolicy() { return this.permission === 'ask' ? 'on-request' : 'never'; }
  sandboxMode() { return this.permission === 'ask' ? 'workspace-write' : 'danger-full-access'; }

  async spawnRpc() {
    const bin = process.env.PIGO_CODEX_BIN || 'codex';
    const args = this.attach ? ['app-server', 'proxy', ...extraArgs()] : ['app-server', ...extraArgs()];
    const rpc = new JsonRpcProcess(bin, args, { cwd: this.cwd });
    rpc.on('notification', (method, params) => this.onNotification(method, params));
    rpc.onRequest((method, params, id) => this.onServerRequest(method, params, id));
    rpc.on('exit', () => {
      if (this.rpc === rpc) {
        for (const item of this.uiQueue) item.reject(new Error('process_exited'));
        this.uiQueue = [];
      }
    });
    await rpc.request('initialize', {
      clientInfo: { name: 'pi-go', title: 'Pi Go', version: '0.2.0' },
      capabilities: null,
    });
    rpc.notify('initialized');
    this.rpc = rpc;
    return rpc;
  }

  // Release the exclusive ~/.codex/thread-writer-locks/<id>.lock after a phone
  // turn finishes so Codex Desktop can open or write to the same thread freely.
  async releaseWriterLock() {
    if (!this.writerClaimed || this.activeTurnId || !this.thread?.id) return;
    if (this.restartingRpc) return this.restartingRpc;
    this.restartingRpc = (async () => {
      const old = this.rpc;
      this.writerClaimed = false;
      await old?.stop();
      await this.spawnRpc();
    })().catch(() => {}).finally(() => { this.restartingRpc = undefined; });
    return this.restartingRpc;
  }

  async watchRolloutFile() {
    if (!this.thread?.id) return;
    const found = this.thread.path || (await findCodexSession(this.cwd, this.thread.id))?.path;
    if (!found || found === this.rolloutPath) return;
    if (this.rolloutPath) unwatchFile(this.rolloutPath);
    this.rolloutPath = found;
    try {
      const info = statSync(found);
      this.rolloutMtime = info.mtimeMs;
      this.rolloutSize = info.size;
    } catch {}
    watchFile(found, { persistent: false, interval: 1000 }, (curr) => {
      if (this.activeTurnId) return;
      if (curr.mtimeMs === this.rolloutMtime && curr.size === this.rolloutSize) return;
      this.rolloutMtime = curr.mtimeMs;
      this.rolloutSize = curr.size;
      invalidateCodexCatalog();
      const prevLeaf = this.historyLeaf();
      void this.refreshEntries().then(() => {
        if (this.historyLeaf() !== prevLeaf) this.emit('changed');
      }).catch(() => {});
    });
  }

  async start() {
    await this.spawnRpc();

    const modelRes = await this.rpc.request('model/list', {}).catch(() => ({ data: [] }));
    if (Array.isArray(modelRes?.data)) {
      this.modelsCache = modelRes.data.filter((m) => !m.hidden).map((m) => mapCodexModel(m, this.currentProvider));
    }

    let response;
    if (this.initialSessionId) {
      // Always open existing sessions in read-only mode (`thread/read`) so
      // opening a session on the phone never steals or holds the exclusive
      // writer lock away from Codex Desktop.
      try {
        response = await this.rpc.request('thread/read', {
          threadId: this.initialSessionId,
          includeTurns: false,
        });
        this.writerClaimed = false;
      } catch {
        response = await this.rpc.request('thread/resume', {
          threadId: this.initialSessionId,
          cwd: this.cwd,
          approvalPolicy: this.attach ? undefined : this.approvalPolicy(),
          sandbox: this.attach ? undefined : this.sandboxMode(),
          excludeTurns: true,
        });
        this.writerClaimed = true;
      }
    } else {
      response = await this.rpc.request('thread/start', {
        cwd: this.cwd,
        approvalPolicy: this.approvalPolicy(),
        sandbox: this.sandboxMode(),
      });
      this.writerClaimed = true;
    }

    this.thread = response.thread;
    this.currentProvider = response.modelProvider || this.thread?.modelProvider || 'openai';
    this.currentModelId = response.model || this.thread?.model || this.modelsCache.find((m) => m.isDefault)?.id || this.modelsCache[0]?.id;
    this.thinkingLevel = response.reasoningEffort || this.thread?.reasoningEffort || 'medium';
    if (this.modelsCache.length) {
      this.modelsCache = this.modelsCache.map((m) => ({ ...m, provider: this.currentProvider }));
    }
    await this.refreshEntries().catch(() => {});
    await this.watchRolloutFile().catch(() => {});
    invalidateCodexCatalog();
  }

  currentModelObject() {
    if (!this.currentModelId) return this.modelsCache[0];
    return this.modelsCache.find((m) => m.id === this.currentModelId) ?? {
      provider: this.currentProvider,
      id: this.currentModelId,
      name: this.currentModelId,
      levels: effortLevels,
      reasoning: true,
      image: true,
    };
  }

  state() {
    if (!this.thread) return undefined;
    const model = this.currentModelObject();
    const name = this.thread.name || this.titlePreview || (this.thread.preview ? sessionTitlePreview(cleanUserText(this.thread.preview)) : undefined);
    return {
      id: this.thread.id,
      cwd: this.cwd,
      name,
      idle: !this.activeTurnId,
      runId: this.activeTurnId,
      queued: false,
      acceptsImage: model ? model.image === true : true,
      model: model && {
        provider: model.provider,
        id: model.id,
        name: model.name,
        levels: model.levels,
        reasoning: model.reasoning,
        image: model.image,
      },
      thinkingLevel: this.thinkingLevel,
    };
  }

  historyLeaf() {
    return this.cachedEntries.at(-1)?.id ?? null;
  }

  async callRpc(method, params, timeoutMs) {
    if (this.restartingRpc) await this.restartingRpc;
    return this.rpc.request(method, params, timeoutMs);
  }

  async refreshEntries() {
    if (!this.thread?.id) return [];
    const turns = [];
    let cursor = null;
    for (let page = 0; page < 4; page += 1) {
      const res = await this.callRpc('thread/turns/list', {
        threadId: this.thread.id,
        cursor,
        limit: 25,
        sortDirection: 'desc',
        itemsView: 'full',
      });
      if (Array.isArray(res?.data)) turns.push(...res.data);
      if (!res?.nextCursor) break;
      cursor = res.nextCursor;
    }
    turns.reverse();
    this.cachedEntries = turnsToEntries(turns);
    this.entriesDirty = false;
    return this.cachedEntries;
  }

  async entries() {
    if (this.entriesDirty) await this.refreshEntries().catch(() => {});
    return this.cachedEntries;
  }

  async listModels() {
    const model = this.currentModelObject();
    return {
      scoped: false,
      models: this.modelsCache.map(({ defaultLevel: _d, ...rest }) => rest),
      current: model && {
        provider: model.provider,
        id: model.id,
        name: model.name,
        levels: model.levels,
        reasoning: model.reasoning,
        image: model.image,
        thinkingLevel: this.thinkingLevel,
      },
    };
  }

  async setModel({ provider, modelId, thinkingLevel }) {
    const target = this.modelsCache.find((m) => m.id === modelId && (!provider || m.provider === provider))
      ?? (typeof modelId === 'string' && modelId ? {
        provider: provider || this.currentProvider,
        id: modelId,
        name: modelId,
        levels: effortLevels,
        reasoning: true,
        image: true,
      } : undefined);
    if (!target) return { status: 404, error: 'model_not_found' };
    if (thinkingLevel !== undefined && !effortLevels.includes(thinkingLevel) && thinkingLevel !== 'off') {
      return { status: 400, error: 'invalid_thinking_level' };
    }
    this.currentModelId = target.id;
    this.currentProvider = target.provider;
    if (thinkingLevel !== undefined) {
      this.thinkingLevel = thinkingLevel === 'off' ? 'low' : thinkingLevel;
    } else if (!target.levels.includes(this.thinkingLevel)) {
      this.thinkingLevel = target.defaultLevel || target.levels[0] || 'medium';
    }
    const { current } = await this.listModels();
    return { current };
  }

  async listCommands() {
    const res = await this.callRpc('skills/list', { cwds: [this.cwd] }).catch(() => undefined);
    const list = res?.data?.[0]?.skills ?? [];
    this.skillsCache = list.filter((s) => s && s.enabled !== false && typeof s.name === 'string');
    return this.skillsCache.map((skill) => ({
      name: `skill:${skill.name}`,
      description: (skill.interface?.shortDescription || skill.shortDescription || skill.description || '').slice(0, 300) || undefined,
      source: 'skill',
      invoke: `/skill:${skill.name}`,
    }));
  }

  async listProjectSessions() {
    return await listCodexSessions(this.cwd);
  }

  async rename(name) {
    await this.callRpc('thread/name/set', { threadId: this.thread.id, name });
    this.thread.name = name;
    invalidateCodexCatalog();
    return true;
  }

  async fork(messageId) {
    const entries = await this.entries();
    const entry = messageId
      ? entries.find((row) => row.id === messageId && row.role === 'assistant')
      : [...entries].reverse().find((row) => row.role === 'assistant');
    if (messageId && !entry) return { status: 404, error: 'message_not_found' };
    const forked = await this.callRpc('thread/fork', {
      threadId: this.thread.id,
      lastTurnId: entry?.turnId || null,
      cwd: this.cwd,
      approvalPolicy: this.approvalPolicy(),
      sandbox: this.sandboxMode(),
      excludeTurns: true,
    });
    const newId = forked?.thread?.id;
    if (!newId) return { status: 409, error: 'desktop_handoff_failed' };
    const baseName = this.state()?.name || '会话';
    await this.callRpc('thread/name/set', {
      threadId: newId,
      name: `${baseName.slice(0, 190)}（分支）`,
    }).catch(() => {});
    invalidateCodexCatalog();
    return { id: newId };
  }

  buildUserInput({ text, command, images }) {
    const input = [];
    let bodyText = text;
    if (command?.name?.startsWith('skill:')) {
      const skillName = command.name.slice('skill:'.length);
      const skill = this.skillsCache.find((s) => s.name === skillName);
      if (skill?.path) {
        input.push({ type: 'skill', name: skill.name, path: skill.path });
        const prefix = `/${command.name}`;
        bodyText = bodyText.trimStart().startsWith(prefix) ? bodyText.trimStart().slice(prefix.length).trim() : bodyText;
      }
    }
    if (bodyText) {
      input.push({ type: 'text', text: bodyText, text_elements: [] });
    }
    for (const img of images ?? []) {
      if (img?.path) input.push({ type: 'localImage', path: img.path });
    }
    if (!input.length) input.push({ type: 'text', text: '', text_elements: [] });
    return input;
  }

  async ensureWriter() {
    if (this.restartingRpc) await this.restartingRpc;
    if (this.writerClaimed || !this.thread?.id) return;
    try {
      await this.rpc.request('thread/resume', {
        threadId: this.thread.id,
        cwd: this.cwd,
        approvalPolicy: this.attach ? undefined : this.approvalPolicy(),
        sandbox: this.attach ? undefined : this.sandboxMode(),
        excludeTurns: true,
      });
      this.writerClaimed = true;
    } catch (error) {
      if (/active writer/i.test(String(error?.message ?? ''))) {
        throw new Error('session_occupied');
      }
      throw error;
    }
  }

  async prompt({ text, command, images, mode }) {
    await this.ensureWriter();
    if (!this.titlePreview && !this.thread?.name && text) {
      this.titlePreview = sessionTitlePreview(text);
    }
    const input = this.buildUserInput({ text, command, images });
    if (mode === 'steer' && this.activeTurnId) {
      await this.rpc.request('turn/steer', {
        threadId: this.thread.id,
        expectedTurnId: this.activeTurnId,
        input,
      });
      this.entriesDirty = true;
      return;
    }
    const res = await this.rpc.request('turn/start', {
      threadId: this.thread.id,
      cwd: this.cwd,
      input,
      model: this.currentModelId || undefined,
      effort: this.thinkingLevel || undefined,
      approvalPolicy: this.attach ? undefined : this.approvalPolicy(),
    });
    if (res?.turn?.id && !this.activeTurnId) {
      this.activeTurnId = res.turn.id;
      this.entriesDirty = true;
      this.emit('turn_start', { runId: this.activeTurnId });
    }
  }

  async abort() {
    if (!this.activeTurnId || !this.thread?.id) return;
    await this.rpc.request('turn/interrupt', {
      threadId: this.thread.id,
      turnId: this.activeTurnId,
    }).catch(() => {});
  }

  onNotification(method, params) {
    if (params?.threadId && this.thread?.id && params.threadId !== this.thread.id) return;
    if (method === 'turn/started') {
      const turnId = params.turn?.id;
      if (turnId && this.activeTurnId !== turnId) {
        this.activeTurnId = turnId;
        this.entriesDirty = true;
        this.emit('turn_start', { runId: turnId });
      }
      return;
    }
    if (method === 'item/agentMessage/delta') {
      if (typeof params.delta === 'string') this.emit('delta', params.delta);
      return;
    }
    if (method === 'item/reasoning/summaryTextDelta') {
      if (typeof params.delta === 'string') this.emit('thinking', params.delta);
      return;
    }
    if (method === 'item/started') {
      const tool = itemToToolActivity(params.item);
      if (tool) {
        this.emit('tool_start', {
          id: tool.id,
          name: tool.summary.name,
          args: tool.args,
          detail: tool.summary.detail,
        });
      }
      return;
    }
    if (method === 'item/completed') {
      this.entriesDirty = true;
      const tool = itemToToolActivity(params.item);
      if (tool) {
        this.emit('tool_end', {
          id: tool.id,
          failed: tool.failed,
          ms: tool.ms,
          result: tool.result,
          detail: tool.summary.detail,
        });
      }
      return;
    }
    if (method === 'turn/completed') {
      const status = params.turn?.status;
      const aborted = status === 'interrupted';
      const reason = aborted ? 'aborted' : status === 'failed' ? 'error' : 'stop';
      this.activeTurnId = undefined;
      this.entriesDirty = true;
      invalidateCodexCatalog();
      void this.refreshEntries().catch(() => {}).finally(() => {
        try {
          if (this.rolloutPath) {
            const info = statSync(this.rolloutPath);
            this.rolloutMtime = info.mtimeMs;
            this.rolloutSize = info.size;
          }
        } catch {}
        this.emit('message_final', reason);
        this.emit('turn_end', { aborted, reason });
      });
      return;
    }
    if (method === 'thread/name/updated') {
      if (typeof params.name === 'string' && this.thread) {
        this.thread.name = params.name;
        invalidateCodexCatalog();
        this.emit('changed');
      }
    }
  }

  onServerRequest(method, params, rpcId) {
    if (this.scheduled) {
      return { decision: 'decline' };
    }
    if (method === 'item/commandExecution/requestApproval' || method === 'execCommandApproval') {
      const cmd = Array.isArray(params.command) ? params.command.join(' ') : (params.command ?? '');
      return this.enqueueApproval(rpcId, 'Codex 请求执行命令', [cmd, params.cwd ? `目录: ${params.cwd}` : '', params.reason ?? ''].filter(Boolean).join('\n'));
    }
    if (method === 'item/fileChange/requestApproval' || method === 'applyPatchApproval') {
      return this.enqueueApproval(rpcId, 'Codex 请求修改文件', params.reason || '是否允许写入工作区文件？');
    }
    if (method === 'item/permissions/requestApproval') {
      return this.enqueueApproval(rpcId, 'Codex 请求附加权限', params.reason || JSON.stringify(params.permissions ?? {}));
    }
    if (method === 'item/tool/requestUserInput') {
      const q = Array.isArray(params.questions) ? params.questions[0] : undefined;
      if (!q) return { answers: {} };
      const options = Array.isArray(q.options) && q.options.length
        ? q.options.map((o) => o.label || o.value || String(o)).slice(0, 20)
        : undefined;
      return new Promise((resolve, reject) => {
        const id = `codex-ui-${rpcId}`;
        const interaction = {
          id,
          method: options ? 'select' : 'input',
          requestedAt: Date.now(),
          title: q.header || 'Codex 需要你的输入',
          message: q.question || '',
          options,
        };
        this.uiQueue.push({
          interaction,
          resolve: (answer) => {
            if (answer === false) resolve({ answers: {} });
            else resolve({ answers: { [q.id]: { answers: [String(answer)] } } });
          },
          reject,
        });
        this.emit('interaction', interaction);
      });
    }
    throw Object.assign(new Error('unsupported_server_request'), { code: -32601 });
  }

  enqueueApproval(rpcId, title, message) {
    return new Promise((resolve, reject) => {
      const id = `codex-approval-${rpcId}`;
      const interaction = {
        id,
        method: 'select',
        kind: 'approval',
        requestedAt: Date.now(),
        title,
        message: String(message || '').slice(0, 4000),
        options: approvalChoices,
      };
      this.uiQueue.push({
        interaction,
        resolve: (answer) => {
          const decision = answer === '允许一次' ? 'accept'
            : answer === '本会话允许' ? 'acceptForSession' : 'decline';
          resolve({ decision });
        },
        reject,
      });
      this.emit('interaction', interaction);
    });
  }

  pendingInteraction() {
    return this.uiQueue[0]?.interaction;
  }

  respondInteraction(pendingId, answer) {
    const entry = this.uiQueue[0];
    if (!entry || entry.interaction.id !== pendingId) return false;
    const { interaction } = entry;
    if (interaction.method === 'select') {
      if (answer !== false && (typeof answer !== 'string' || !interaction.options?.includes(answer))) return false;
    } else if (interaction.method === 'input') {
      if (answer !== false && (typeof answer !== 'string' || answer.length > 1024 || /[\r\n]/.test(answer))) return false;
    } else return false;
    this.uiQueue.shift();
    entry.resolve(answer);
    return true;
  }

  async stop() {
    if (this.rolloutPath) {
      unwatchFile(this.rolloutPath);
      this.rolloutPath = undefined;
    }
    await this.rpc?.stop();
  }
}
