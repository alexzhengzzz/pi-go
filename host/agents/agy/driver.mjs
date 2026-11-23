// Antigravity CLI (`agy acp`) Agent Client Protocol (ACP) driver for Pi Go's worker-core.
//
// Translates ACP JSON-RPC 2.0 methods (`initialize`, `session/new`, `session/load`,
// `session/prompt`, `session/cancel`, `session/set_model`, `session/set_config_option`),
// `session/update` notifications, and `session/request_permission` server requests
// into the unified AgentSession interface consumed by `host/agents/worker-core.mjs`.
import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { JsonRpcProcess } from '../jsonrpc.mjs';
import { sessionTitlePreview } from '../../bridge/message-view.mjs';
import {
  agyConversationsRoot, agyHomes, findAgySession, invalidateAgyCatalog, listAgySessions,
} from './catalog.mjs';

const effortLevels = ['low', 'medium', 'high', 'xhigh'];
const effortSuffixPattern = /^(.*?)-(low|medium|high|xhigh)$/i;
const effortLabelSuffixPattern = /\s*\((Low|Medium|High|XHigh|Extra)\)\s*$/i;

function extraArgs() {
  if (!process.env.PIGO_AGY_ARGS) return [];
  try {
    const value = JSON.parse(process.env.PIGO_AGY_ARGS);
    return Array.isArray(value) && value.every((item) => typeof item === 'string') ? value : [];
  } catch { return []; }
}

function cleanUserText(raw) {
  if (typeof raw !== 'string') return '';
  const match = /<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/i.exec(raw);
  return (match ? match[1] : raw).trim();
}

function parseJsonArg(value) {
  if (typeof value !== 'string') return value;
  const trimmed = value.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    try { return JSON.parse(trimmed); } catch { return value; }
  }
  return value;
}

function normalizeTranscriptArgs(rawArgs) {
  if (!rawArgs || typeof rawArgs !== 'object') return {};
  const out = {};
  for (const [k, v] of Object.entries(rawArgs)) {
    out[k] = parseJsonArg(v);
  }
  return out;
}

function mapToolNameAndArgs(rawName, rawInput, kind, title) {
  const nameLower = String(rawName || kind || '').toLowerCase();
  const args = normalizeTranscriptArgs(rawInput);
  if (nameLower === 'run_command' || nameLower === 'execute' || nameLower === 'bash' || nameLower === 'command') {
    const command = args.CommandLine ?? args.command ?? title ?? '';
    return {
      name: 'bash',
      args: { command: String(command), cwd: args.Cwd ?? args.cwd },
      detail: String(args.toolSummary || command || title || '').replace(/\s+/g, ' ').trim().slice(0, 120),
    };
  }
  if (nameLower === 'edit_file' || nameLower === 'edit' || nameLower === 'patch') {
    const path = args.Path ?? args.path ?? title ?? '';
    return {
      name: 'edit',
      args: { path: String(path) },
      detail: String(path || title || '').slice(0, 120),
    };
  }
  if (nameLower === 'write_file' || nameLower === 'write') {
    const path = args.Path ?? args.path ?? title ?? '';
    return {
      name: 'write',
      args: { path: String(path) },
      detail: String(path || title || '').slice(0, 120),
    };
  }
  if (nameLower === 'read_file' || nameLower === 'read') {
    const path = args.Path ?? args.path ?? title ?? '';
    return {
      name: 'read',
      args: { path: String(path) },
      detail: String(path || title || '').slice(0, 120),
    };
  }
  const detailText = title
    || args.toolSummary
    || args.Path
    || args.path
    || args.CommandLine
    || args.command
    || args.query
    || (Object.keys(args).length ? JSON.stringify(args) : '');
  return {
    name: rawName || kind || 'tool',
    args,
    detail: String(detailText).replace(/\s+/g, ' ').trim().slice(0, 120),
  };
}

function parseTranscriptEntries(sessionId) {
  let file;
  for (const { dir } of agyHomes()) {
    const candidate = join(dir, 'brain', sessionId, '.system_generated', 'logs', 'transcript.jsonl');
    if (existsSync(candidate)) { file = candidate; break; }
  }
  if (!file) return [];
  let raw;
  try { raw = readFileSync(file, 'utf8'); } catch { return []; }
  const entries = [];
  let currentAssistant;
  let pendingTools = [];

  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    let step;
    try { step = JSON.parse(line); } catch { continue; }
    if (!step || typeof step !== 'object') continue;

    if (step.type === 'USER_INPUT') {
      currentAssistant = undefined;
      pendingTools = [];
      const text = cleanUserText(step.content ?? '');
      const media = Array.isArray(step.media) ? step.media : [];
      const images = [];
      for (const item of media) {
        const uri = typeof item?.uri === 'string' ? item.uri : '';
        const path = uri.startsWith('file://') ? decodeURIComponent(new URL(uri).pathname) : uri;
        if (path && existsSync(path)) {
          try {
            images.push({ mimeType: item.mime_type || 'image/jpeg', data: readFileSync(path).toString('base64') });
          } catch {}
        }
      }
      if (text || images.length) {
        entries.push({
          id: `step-${step.step_index ?? entries.length}:user`,
          role: 'user',
          text,
          images,
          imageCount: images.length || media.length,
        });
      }
      continue;
    }

    if (step.type === 'PLANNER_RESPONSE') {
      if (!currentAssistant) {
        currentAssistant = {
          id: `step-${step.step_index ?? entries.length}:assistant`,
          role: 'assistant',
          text: '',
          thinking: '',
          tools: [],
        };
        entries.push(currentAssistant);
      }
      if (typeof step.thinking === 'string' && step.thinking.trim()) {
        currentAssistant.thinking = currentAssistant.thinking
          ? `${currentAssistant.thinking}\n\n${step.thinking.trim()}`
          : step.thinking.trim();
      }
      if (typeof step.content === 'string' && step.content.trim()) {
        currentAssistant.text = currentAssistant.text
          ? `${currentAssistant.text}\n\n${step.content.trim()}`
          : step.content.trim();
      }
      pendingTools = [];
      for (let i = 0; i < (step.tool_calls?.length ?? 0); i += 1) {
        const tc = step.tool_calls[i];
        if (!tc || typeof tc !== 'object') continue;
        if (tc.name === 'update_focus' || tc.name === 'update_steps') continue;
        const mapped = mapToolNameAndArgs(tc.name, tc.args, undefined, undefined);
        const toolId = tc.id || `tc-${step.step_index}-${i}`;
        const activity = {
          id: toolId,
          summary: {
            id: toolId,
            name: mapped.name,
            detail: mapped.detail,
            state: step.status === 'ERROR' ? 'fail' : 'ok',
          },
          args: mapped.args,
          result: { content: [] },
        };
        currentAssistant.tools.push(activity);
        pendingTools.push(activity);
      }
      continue;
    }

    if (step.type === 'GENERIC' && typeof step.content === 'string' && pendingTools.length > 0) {
      const target = pendingTools.shift();
      let output = step.content;
      const idx = output.indexOf('Command output:\n');
      if (idx >= 0) output = output.slice(idx + 'Command output:\n'.length);
      target.result = { content: [{ type: 'text', text: output.trim() }] };
    }
  }

  return entries.filter((e) => e.role === 'user' || e.text || e.thinking || e.tools?.length);
}

function buildModelsCatalog(sessionReply, providerDefault = 'google') {
  const available = Array.isArray(sessionReply?.models?.availableModels) ? sessionReply.models.availableModels : [];
  const configOptions = Array.isArray(sessionReply?.configOptions) ? sessionReply.configOptions : [];
  const modelOpt = configOptions.find((o) => o?.id === 'model');
  const thoughtOpt = configOptions.find((o) => o?.id === 'thought_level');

  const families = new Map();
  const variantMap = new Map();

  for (const item of available) {
    const modelId = item?.modelId || item?.id;
    if (typeof modelId !== 'string' || !modelId) continue;
    const rawName = item?.name || modelId;
    const match = effortSuffixPattern.exec(modelId);
    const baseId = match ? match[1] : modelId;
    const level = match ? match[2].toLowerCase() : 'medium';
    const baseName = rawName.replace(effortLabelSuffixPattern, '').trim() || rawName;
    if (!families.has(baseId)) {
      families.set(baseId, {
        provider: providerDefault,
        id: baseId,
        name: baseName,
        levels: [],
        variants: new Map(),
      });
    }
    const family = families.get(baseId);
    if (!family.levels.includes(level)) family.levels.push(level);
    family.variants.set(level, modelId);
    variantMap.set(modelId, { familyId: baseId, level });
  }

  if (Array.isArray(modelOpt?.options)) {
    for (const opt of modelOpt.options) {
      if (typeof opt?.value !== 'string' || !opt.value) continue;
      if (!families.has(opt.value)) {
        const levels = Array.isArray(thoughtOpt?.options)
          ? thoughtOpt.options.map((t) => t?.value).filter((v) => effortLevels.includes(v))
          : ['medium'];
        families.set(opt.value, {
          provider: providerDefault,
          id: opt.value,
          name: opt.name || opt.value,
          levels: levels.length ? levels : ['medium'],
          variants: new Map(),
        });
      } else if (opt.name) {
        families.get(opt.value).name = opt.name;
      }
    }
  }

  const models = [...families.values()].map((f) => {
    const orderedLevels = effortLevels.filter((l) => f.levels.includes(l));
    const finalLevels = orderedLevels.length ? orderedLevels : ['medium'];
    return {
      provider: f.provider,
      id: f.id,
      name: f.name,
      levels: finalLevels,
      reasoning: finalLevels.length > 0,
      image: true,
      defaultLevel: finalLevels.includes('high') ? 'high' : finalLevels[0],
      variants: f.variants,
    };
  });

  const rawCurrent = sessionReply?.models?.currentModelId;
  const parsedCurrent = rawCurrent && variantMap.get(rawCurrent);
  const currentFamilyId = modelOpt?.currentValue || parsedCurrent?.familyId || models[0]?.id;
  const currentThinking = thoughtOpt?.currentValue || parsedCurrent?.level || models[0]?.defaultLevel || 'medium';

  return {
    models,
    currentFamilyId,
    currentThinking,
    hasConfigOptions: Boolean(modelOpt),
  };
}

function extractUpdateText(content) {
  if (!content) return '';
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((c) => extractUpdateText(c)).join('');
  if (typeof content === 'object') {
    if (typeof content.text === 'string') return content.text;
    if (content.content) return extractUpdateText(content.content);
  }
  return '';
}

function extractToolOutputText(update) {
  const chunks = [];
  if (Array.isArray(update.content)) {
    for (const item of update.content) {
      if (!item || typeof item !== 'object') continue;
      if (item.type === 'diff') {
        const header = `${item.path || ''}`.trim();
        const oldText = typeof item.oldText === 'string' ? item.oldText : '';
        const newText = typeof item.newText === 'string' ? item.newText : '';
        chunks.push([header, oldText ? `--- old\n${oldText}` : '', newText ? `+++ new\n${newText}` : ''].filter(Boolean).join('\n'));
      } else {
        const text = extractUpdateText(item);
        if (text) chunks.push(text);
      }
    }
  }
  if (!chunks.length && update.rawOutput !== undefined) {
    chunks.push(typeof update.rawOutput === 'string' ? update.rawOutput : JSON.stringify(update.rawOutput, null, 2));
  }
  return chunks.filter(Boolean).join('\n\n');
}

export class AgyDriver extends EventEmitter {
  constructor({ cwd, sessionId, attach = false, scheduled = false }) {
    super();
    this.agent = 'agy';
    this.cwd = realpathSync(cwd);
    this.initialSessionId = sessionId;
    this.attach = attach;
    this.scheduled = scheduled;
    this.permission = process.env.PIGO_AGY_PERMISSION === 'ask' ? 'ask' : 'bypass';
    this.capabilities = {
      steer: false,
      followUp: true,
      images: true,
      models: true,
      thinking: true,
      commands: true,
      rename: true,
      fork: false,
      regenerate: false,
      approvals: true,
    };
    this.sessionId = sessionId;
    this.sessionTitle = undefined;
    this.titlePreview = undefined;
    this.appDataDir = process.env.PIGO_AGY_APP_DATA_DIR || undefined;
    this.activeTurnId = undefined;
    this.currentProvider = 'google';
    this.currentModelId = undefined;
    this.thinkingLevel = 'high';
    this.modelsCache = [];
    this.hasConfigOptions = false;
    this.commandsCache = [];
    this.entriesList = [];
    this.liveTurn = undefined;
    this.replaying = false;
    this.replayAssistant = undefined;
    this.uiQueue = [];
    try { this.historyDirectory = realpathSync(agyConversationsRoot()); } catch { this.historyDirectory = undefined; }
  }

  async spawnRpc() {
    const bin = process.env.PIGO_AGY_BIN || 'agy';
    const args = ['acp'];
    if (this.permission === 'bypass') args.push('--dangerously-skip-permissions');
    if (process.env.PIGO_AGY_GEMINI_DIR) args.push('--gemini-dir', process.env.PIGO_AGY_GEMINI_DIR);
    if (this.appDataDir) args.push('--app-data-dir', this.appDataDir);
    args.push(...extraArgs());

    const rpc = new JsonRpcProcess(bin, args, {
      cwd: this.cwd,
      wireVersion: true,
      requestTimeoutMs: 60000,
    });
    rpc.on('notification', (method, params) => this.onNotification(method, params));
    rpc.onRequest((method, params, id) => this.onServerRequest(method, params, id));
    rpc.on('exit', () => {
      if (this.rpc === rpc) {
        for (const item of this.uiQueue) item.reject(new Error('process_exited'));
        this.uiQueue = [];
      }
    });
    await rpc.request('initialize', {
      protocolVersion: 1,
      clientInfo: { name: 'pi-go', title: 'Pi Go', version: '0.2.0' },
      clientCapabilities: {},
    });
    this.rpc = rpc;
    return rpc;
  }

  async start() {
    let existing;
    if (this.initialSessionId) {
      existing = await findAgySession(this.cwd, this.initialSessionId).catch(() => undefined);
      if (existing?.name && existing.name !== '未命名会话') {
        this.sessionTitle = existing.name;
      }
      if (existing?.appDataDir && !this.appDataDir) {
        this.appDataDir = existing.appDataDir;
      }
    }
    await this.spawnRpc();

    let sessionReply;
    if (this.initialSessionId) {
      this.replaying = true;
      this.replayAssistant = undefined;
      try {
        sessionReply = await this.rpc.request('session/load', {
          sessionId: this.initialSessionId,
          cwd: this.cwd,
          mcpServers: [],
        });
      } finally {
        this.replaying = false;
        this.replayAssistant = undefined;
      }
      this.sessionId = sessionReply?.sessionId || this.initialSessionId;
      const richEntries = parseTranscriptEntries(this.sessionId);
      if (richEntries.length >= this.entriesList.length) {
        this.entriesList = richEntries;
      }
    } else {
      sessionReply = await this.rpc.request('session/new', {
        cwd: this.cwd,
        mcpServers: [],
      });
      this.sessionId = sessionReply?.sessionId;
    }

    this.applySessionConfig(sessionReply);
    invalidateAgyCatalog();
  }

  applySessionConfig(sessionReply) {
    if (!sessionReply || typeof sessionReply !== 'object') return;
    const { models, currentFamilyId, currentThinking, hasConfigOptions } = buildModelsCatalog(sessionReply, this.currentProvider);
    if (models.length) {
      this.modelsCache = models;
      this.currentModelId = currentFamilyId || models[0].id;
      this.thinkingLevel = currentThinking || models[0].defaultLevel || 'high';
      this.hasConfigOptions = hasConfigOptions;
    }
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
    if (!this.sessionId) return undefined;
    const model = this.currentModelObject();
    const firstUser = this.entriesList.find((e) => e.role === 'user' && e.text);
    const name = this.sessionTitle || this.titlePreview || (firstUser ? sessionTitlePreview(firstUser.text) : undefined);
    return {
      id: this.sessionId,
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
    return this.entriesList.at(-1)?.id ?? null;
  }

  async entries() {
    return this.entriesList;
  }

  async listModels() {
    const model = this.currentModelObject();
    return {
      scoped: false,
      models: this.modelsCache.map(({ defaultLevel: _d, variants: _v, ...rest }) => rest),
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
        variants: new Map(),
      } : undefined);
    if (!target) return { status: 404, error: 'model_not_found' };
    if (thinkingLevel !== undefined && !effortLevels.includes(thinkingLevel) && thinkingLevel !== 'off') {
      return { status: 400, error: 'invalid_thinking_level' };
    }
    const nextLevel = thinkingLevel !== undefined
      ? (thinkingLevel === 'off' ? 'low' : thinkingLevel)
      : (target.levels.includes(this.thinkingLevel) ? this.thinkingLevel : (target.defaultLevel || target.levels[0] || 'medium'));

    try {
      if (this.hasConfigOptions) {
        if (target.id !== this.currentModelId) {
          await this.rpc.request('session/set_config_option', {
            sessionId: this.sessionId,
            configId: 'model',
            value: target.id,
          });
        }
        if (target.levels.includes(nextLevel)) {
          await this.rpc.request('session/set_config_option', {
            sessionId: this.sessionId,
            configId: 'thought_level',
            value: nextLevel,
          }).catch(() => {});
        }
      } else {
        const variantId = target.variants?.get(nextLevel) || `${target.id}-${nextLevel}`;
        await this.rpc.request('session/set_model', {
          sessionId: this.sessionId,
          modelId: variantId,
        }).catch(async () => {
          await this.rpc.request('session/set_model', {
            sessionId: this.sessionId,
            modelId: target.id,
          });
        });
      }
    } catch {
      return { status: 409, error: 'model_switch_failed' };
    }

    this.currentModelId = target.id;
    this.currentProvider = target.provider;
    this.thinkingLevel = nextLevel;
    const { current } = await this.listModels();
    return { current };
  }

  async listCommands() {
    return this.commandsCache;
  }

  async listProjectSessions() {
    return await listAgySessions(this.cwd);
  }

  async rename(name) {
    this.sessionTitle = name;
    invalidateAgyCatalog();
    return true;
  }

  buildPromptBlocks({ text, images }) {
    const blocks = [];
    if (text) {
      blocks.push({ type: 'text', text });
    }
    for (const img of images ?? []) {
      const bytes = img.bytes ?? (img.path ? readFileSync(img.path) : undefined);
      if (bytes) {
        blocks.push({
          type: 'image',
          mimeType: 'image/jpeg',
          data: bytes.toString('base64'),
        });
      }
    }
    if (!blocks.length) blocks.push({ type: 'text', text: '' });
    return blocks;
  }

  async prompt({ text, images }) {
    if (this.activeTurnId) throw new Error('session_busy');
    if (!this.titlePreview && !this.sessionTitle && text) {
      this.titlePreview = sessionTitlePreview(text);
    }

    const turnId = `turn-${randomUUID()}`;
    this.activeTurnId = turnId;
    const userImages = (images ?? []).map((img) => {
      const bytes = img.bytes ?? (img.path ? readFileSync(img.path) : undefined);
      return bytes ? { mimeType: 'image/jpeg', data: bytes.toString('base64') } : undefined;
    }).filter(Boolean);

    this.entriesList.push({
      id: `${turnId}:user`,
      turnId,
      role: 'user',
      text: text || '',
      images: userImages,
      imageCount: userImages.length,
    });

    const assistantEntry = {
      id: `${turnId}:assistant`,
      turnId,
      role: 'assistant',
      text: '',
      thinking: '',
      tools: [],
    };
    this.liveTurn = {
      turnId,
      assistantEntry,
      startedAt: Date.now(),
      toolsById: new Map(),
      appended: false,
    };
    this.emit('turn_start', { runId: turnId });

    const promptBlocks = this.buildPromptBlocks({ text, images });
    void this.rpc.request('session/prompt', {
      sessionId: this.sessionId,
      prompt: promptBlocks,
    }, 30 * 60 * 1000).then((res) => {
      this.finishTurn(turnId, res?.stopReason);
    }).catch((error) => {
      const cancelled = /cancel/i.test(String(error?.message ?? ''));
      this.finishTurn(turnId, cancelled ? 'cancelled' : 'error');
    });
  }

  finishTurn(turnId, stopReason) {
    if (this.activeTurnId !== turnId) return;
    const live = this.liveTurn;
    this.activeTurnId = undefined;
    this.liveTurn = undefined;

    if (live) {
      const entry = live.assistantEntry;
      if ((entry.text || entry.thinking || entry.tools.length) && !live.appended) {
        if (entry.thinking) entry.thinkingMs = Math.max(1, Date.now() - live.startedAt);
        this.entriesList.push(entry);
        live.appended = true;
      }
    }

    const richEntries = parseTranscriptEntries(this.sessionId);
    if (richEntries.length >= this.entriesList.length) {
      this.entriesList = richEntries;
    }

    const aborted = stopReason === 'cancelled' || stopReason === 'aborted';
    const reason = aborted ? 'aborted' : stopReason === 'error' ? 'error' : 'stop';
    invalidateAgyCatalog();
    this.emit('message_final', reason);
    this.emit('turn_end', { aborted, reason });
  }

  async abort() {
    if (!this.activeTurnId || !this.sessionId) return;
    this.rpc.notify('session/cancel', { sessionId: this.sessionId });
  }

  onNotification(method, params) {
    if (method !== 'session/update') return;
    if (params?.sessionId && this.sessionId && params.sessionId !== this.sessionId) return;
    const update = params?.update;
    if (!update || typeof update !== 'object') return;
    const kind = update.sessionUpdate;

    if (kind === 'available_commands_update') {
      const list = Array.isArray(update.availableCommands) ? update.availableCommands : [];
      this.commandsCache = list
        .filter((c) => c && typeof c.name === 'string' && c.name)
        .map((c) => ({
          name: c.name,
          description: typeof c.description === 'string' ? c.description.slice(0, 300) : undefined,
          source: 'command',
          invoke: `/${c.name}`,
        }));
      return;
    }

    if (kind === 'session_info_update') {
      if (typeof update.title === 'string' && update.title.trim()) {
        this.sessionTitle = update.title.trim();
        invalidateAgyCatalog();
        if (!this.replaying) this.emit('changed');
      }
      return;
    }

    if (kind === 'config_option_update') {
      if (update.configId === 'model' && typeof update.currentValue === 'string') {
        this.currentModelId = update.currentValue;
        if (!this.replaying) this.emit('changed');
      } else if (update.configId === 'thought_level' && typeof update.currentValue === 'string') {
        this.thinkingLevel = update.currentValue;
        if (!this.replaying) this.emit('changed');
      }
      return;
    }

    if (this.replaying) {
      this.handleReplayUpdate(kind, update);
      return;
    }

    if (kind === 'agent_message_chunk') {
      const text = extractUpdateText(update.content);
      if (!text) return;
      if (this.liveTurn) {
        this.liveTurn.assistantEntry.text += text;
        if (!this.liveTurn.appended) {
          this.entriesList.push(this.liveTurn.assistantEntry);
          this.liveTurn.appended = true;
        }
      }
      this.emit('delta', text);
      return;
    }

    if (kind === 'agent_thought_chunk') {
      const text = extractUpdateText(update.content);
      if (!text) return;
      if (this.liveTurn) {
        this.liveTurn.assistantEntry.thinking += text;
        if (!this.liveTurn.appended) {
          this.entriesList.push(this.liveTurn.assistantEntry);
          this.liveTurn.appended = true;
        }
      }
      this.emit('thinking', text);
      return;
    }

    if (kind === 'tool_call') {
      const id = update.toolCallId || `tool-${randomUUID()}`;
      const mapped = mapToolNameAndArgs(update.rawInput?.ToolName || update.kind, update.rawInput, update.kind, update.title);
      const status = update.status || 'in_progress';
      const failed = status === 'failed' || status === 'error';
      const done = status === 'completed' || failed;
      const output = extractToolOutputText(update);
      const activity = {
        id,
        startedAt: Date.now(),
        summary: {
          id,
          name: mapped.name,
          detail: mapped.detail,
          state: done ? (failed ? 'fail' : 'ok') : 'run',
        },
        args: mapped.args,
        result: { content: output ? [{ type: 'text', text: output }] : [] },
      };
      if (this.liveTurn) {
        this.liveTurn.toolsById.set(id, activity);
        this.liveTurn.assistantEntry.tools.push(activity);
        if (!this.liveTurn.appended) {
          this.entriesList.push(this.liveTurn.assistantEntry);
          this.liveTurn.appended = true;
        }
      }
      this.emit('tool_start', {
        id,
        name: mapped.name,
        args: mapped.args,
        detail: mapped.detail,
      });
      if (done) {
        this.emit('tool_end', {
          id,
          failed,
          ms: 0,
          result: activity.result,
          detail: mapped.detail,
        });
      }
      return;
    }

    if (kind === 'tool_call_update') {
      const id = update.toolCallId;
      if (!id) return;
      const existing = this.liveTurn?.toolsById.get(id);
      const status = update.status;
      const failed = status === 'failed' || status === 'error';
      const done = status === 'completed' || failed || status === 'cancelled';
      const output = extractToolOutputText(update);
      const detail = typeof update.title === 'string' && update.title.trim()
        ? update.title.trim().slice(0, 120)
        : existing?.summary.detail;
      const ms = existing?.startedAt ? Math.max(1, Date.now() - existing.startedAt) : undefined;
      if (existing) {
        if (detail) existing.summary.detail = detail;
        if (done) existing.summary.state = failed ? 'fail' : 'ok';
        if (ms !== undefined) existing.summary.ms = ms;
        if (output) existing.result = { content: [{ type: 'text', text: output }] };
      }
      if (done) {
        this.emit('tool_end', {
          id,
          failed,
          ms,
          result: existing?.result ?? (output ? { content: [{ type: 'text', text: output }] } : { content: [] }),
          detail,
        });
      }
    }
  }

  handleReplayUpdate(kind, update) {
    if (kind === 'user_message_chunk') {
      this.replayAssistant = undefined;
      const text = cleanUserText(extractUpdateText(update.content));
      if (!text) return;
      this.entriesList.push({
        id: `replay-${this.entriesList.length}:user`,
        role: 'user',
        text,
      });
      return;
    }
    if (kind === 'agent_message_chunk' || kind === 'agent_thought_chunk') {
      const text = extractUpdateText(update.content);
      if (!text) return;
      if (!this.replayAssistant) {
        this.replayAssistant = {
          id: `replay-${this.entriesList.length}:assistant`,
          role: 'assistant',
          text: '',
          thinking: '',
          tools: [],
        };
        this.entriesList.push(this.replayAssistant);
      }
      if (kind === 'agent_thought_chunk') this.replayAssistant.thinking += text;
      else this.replayAssistant.text += text;
      return;
    }
    if (kind === 'tool_call') {
      if (!this.replayAssistant) {
        this.replayAssistant = {
          id: `replay-${this.entriesList.length}:assistant`,
          role: 'assistant',
          text: '',
          thinking: '',
          tools: [],
        };
        this.entriesList.push(this.replayAssistant);
      }
      const id = update.toolCallId || `replay-tool-${this.replayAssistant.tools.length}`;
      const mapped = mapToolNameAndArgs(update.rawInput?.ToolName || update.kind, update.rawInput, update.kind, update.title);
      const output = extractToolOutputText(update);
      const failed = update.status === 'failed' || update.status === 'error';
      this.replayAssistant.tools.push({
        id,
        summary: { id, name: mapped.name, detail: mapped.detail, state: failed ? 'fail' : 'ok' },
        args: mapped.args,
        result: { content: output ? [{ type: 'text', text: output }] : [] },
      });
    }
  }

  onServerRequest(method, params, rpcId) {
    if (method === 'session/request_permission') {
      const rawOptions = Array.isArray(params?.options) ? params.options : [];
      if (this.scheduled) {
        const rejectOpt = rawOptions.find((o) => /reject|decline|deny/i.test(String(o?.kind || o?.optionId || '')));
        return { outcome: rejectOpt ? { outcome: 'selected', optionId: rejectOpt.optionId } : { outcome: 'cancelled' } };
      }
      const optionMap = new Map();
      const labels = [];
      for (const opt of rawOptions) {
        const label = String(opt?.name || opt?.optionId || '').trim();
        const optionId = String(opt?.optionId || opt?.id || label);
        if (!label) continue;
        labels.push(label);
        optionMap.set(label, optionId);
      }
      if (!labels.length) {
        labels.push('允许一次', '本会话允许', '拒绝');
        optionMap.set('允许一次', 'allow_once');
        optionMap.set('本会话允许', 'allow_always');
        optionMap.set('拒绝', 'reject_once');
      }
      const toolCall = params?.toolCall ?? {};
      const title = toolCall.title || params?.title || 'Antigravity 请求权限';
      const detail = extractToolOutputText(toolCall)
        || (toolCall.rawInput ? JSON.stringify(toolCall.rawInput, null, 2) : '')
        || params?.message
        || '是否允许执行该操作？';

      return new Promise((resolve, reject) => {
        const id = `agy-approval-${rpcId}`;
        const interaction = {
          id,
          method: 'select',
          kind: 'approval',
          requestedAt: Date.now(),
          title: String(title).slice(0, 200),
          message: String(detail).slice(0, 4000),
          options: labels.slice(0, 20),
        };
        this.uiQueue.push({
          interaction,
          resolve: (answer) => {
            if (answer === false) {
              resolve({ outcome: { outcome: 'cancelled' } });
              return;
            }
            const optionId = optionMap.get(answer) || rawOptions[0]?.optionId || 'reject_once';
            resolve({ outcome: { outcome: 'selected', optionId } });
          },
          reject,
        });
        this.emit('interaction', interaction);
      });
    }
    throw Object.assign(new Error('unsupported_server_request'), { code: -32601 });
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
    await this.rpc?.stop();
  }
}
