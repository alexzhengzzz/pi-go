import type { ChatMessage, LiveTool } from './model/PiGoTypes';

export interface ProcessStep {
  id: string;
  kind: 'thinking' | 'tool' | 'note';
  messageId: string;
  text: string;
  ms: number;
  tool?: LiveTool;
  live: boolean;
}

export interface RecentToolRef {
  tool: LiveTool;
  messageId: string;
}

export interface ProcessSummary {
  thinkingMs: number;
  thinkingCount: number;
  toolCount: number;
  failCount: number;
  runningCount: number;
  label: string;
  liveTitle: string;
  latestThinking: string;
  recentTools: RecentToolRef[];
  hasFailure: boolean;
  isLive: boolean;
}

export interface TranscriptTurn {
  id: string;
  kind: 'user' | 'assistant';
  message?: ChatMessage;
  processId: string;
  steps: ProcessStep[];
  summary?: ProcessSummary;
  extraImageMessages: ChatMessage[];
  isLive: boolean;
  liveText: string;
}

export function toolCategoryLabel(name: string): string {
  switch (name) {
    case 'read': return '读取';
    case 'write':
    case 'edit': return '修改';
    case 'bash': return '命令';
    case 'grep':
    case 'find':
    case 'web_search': return '搜索';
    case 'ls': return '目录';
    case 'computer_screenshot': return '截图';
    default: return '操作';
  }
}

export function toolActionTitle(name: string): string {
  switch (name) {
    case 'bash': return '执行命令';
    case 'read': return '读取文件';
    case 'write': return '写入文件';
    case 'edit': return '编辑文件';
    case 'grep':
    case 'find': return '搜索工作区';
    case 'ls': return '列出目录';
    case 'web_search': return '网页搜索';
    case 'computer_screenshot': return '截取电脑屏幕';
    default: return name;
  }
}

export function isReadOnlyTool(name: string): boolean {
  return name === 'read' || name === 'grep' || name === 'find' || name === 'ls' || name === 'web_search';
}

export function lastNonEmptyLine(text: string): string {
  if (!text) return '';
  const lines = text.split('\n');
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const trimmed = lines[index].trim();
    if (trimmed) return trimmed;
  }
  return '';
}

function formatDuration(ms: number): string {
  if (ms <= 0) return '';
  return `${(ms / 1000).toFixed(1)}s`;
}

function buildToolBreakdown(tools: RecentToolRef[]): string {
  if (!tools.length) return '';
  const counts = new Map<string, number>();
  const order: string[] = [];
  for (const item of tools) {
    const label = toolCategoryLabel(item.tool.name);
    const current = counts.get(label) ?? 0;
    if (current === 0) order.push(label);
    counts.set(label, current + 1);
  }
  order.sort((left: string, right: string): number => (counts.get(right) ?? 0) - (counts.get(left) ?? 0));
  const parts: string[] = [];
  const limit = Math.min(order.length, 3);
  for (let index = 0; index < limit; index += 1) {
    const label = order[index];
    parts.push(`${label} ${counts.get(label) ?? 0}`);
  }
  return parts.join('、');
}

function buildProcessSummary(steps: ProcessStep[], isLive: boolean, idle: boolean): ProcessSummary | undefined {
  if (!steps.length) return undefined;
  let thinkingMs = 0;
  let thinkingCount = 0;
  let failCount = 0;
  let runningCount = 0;
  let latestThinking = '';
  let activeTool: LiveTool | undefined = undefined;
  const allTools: RecentToolRef[] = [];

  for (const step of steps) {
    if (step.kind === 'thinking') {
      thinkingCount += 1;
      if (step.ms > 0) thinkingMs += step.ms;
      const line = lastNonEmptyLine(step.text);
      if (line) latestThinking = line;
    } else if (step.kind === 'tool' && step.tool) {
      allTools.push({ tool: step.tool, messageId: step.messageId });
      if (step.tool.state === 'fail') failCount += 1;
      if (step.tool.state === 'run' && !idle) {
        runningCount += 1;
        activeTool = step.tool;
      }
    }
  }

  const labelParts: string[] = [];
  if (thinkingCount > 0) {
    const duration = formatDuration(thinkingMs);
    if (isLive && !idle && runningCount === 0 && steps[steps.length - 1].kind === 'thinking') {
      labelParts.push('思考中…');
    } else if (duration) {
      labelParts.push(`思考 ${duration}`);
    } else {
      labelParts.push('已思考');
    }
  }
  if (allTools.length > 0) {
    const breakdown = buildToolBreakdown(allTools);
    labelParts.push(breakdown ? `${allTools.length} 项操作（${breakdown}）` : `${allTools.length} 项操作`);
  }
  if (!labelParts.length) {
    labelParts.push(`${steps.length} 条过程记录`);
  }
  if (failCount > 0) {
    labelParts.push(`${failCount} 项失败`);
  }

  let liveTitle = '处理中…';
  if (activeTool) {
    liveTitle = `正在${toolActionTitle(activeTool.name)}`;
  } else if (steps[steps.length - 1].kind === 'thinking') {
    liveTitle = '正在思考…';
  } else if (allTools.length > 0) {
    liveTitle = '正在整理结果…';
  }
  const stepNumber = allTools.length > 0 ? allTools.length : thinkingCount;
  if (stepNumber > 1) {
    liveTitle = `${liveTitle} · 第 ${stepNumber} 步`;
  }

  const recentTools: RecentToolRef[] = allTools.length > 2 ? allTools.slice(allTools.length - 2) : allTools.slice(0);
  return {
    thinkingMs,
    thinkingCount,
    toolCount: allTools.length,
    failCount,
    runningCount,
    label: labelParts.join(' · '),
    liveTitle,
    latestThinking,
    recentTools,
    hasFailure: failCount > 0,
    isLive
  };
}

function appendAssistantTurn(
  turns: TranscriptTurn[],
  group: ChatMessage[],
  liveTools: LiveTool[],
  liveThinking: string,
  liveText: string,
  idle: boolean
): void {
  const hasLive = liveTools.length > 0 || liveThinking.length > 0 || liveText.length > 0;
  if (!group.length && !hasLive) return;

  const steps: ProcessStep[] = [];
  const extraImageMessages: ChatMessage[] = [];

  // Determine which message (if any) serves as the final visible assistant reply.
  // While the run is active (!idle) or liveText is streaming, keep committed messages in process steps
  // so the live pulse card stays continuous between tool rounds.
  let finalIndex = -1;
  if (idle && !liveText && group.length > 0) {
    const last = group[group.length - 1];
    const hasTrailingLiveActivity = liveTools.length > 0 || liveThinking.length > 0;
    if (!hasTrailingLiveActivity && (last.text || last.imageCount)) {
      finalIndex = group.length - 1;
    }
  }

  for (let index = 0; index < group.length; index += 1) {
    const message = group[index];
    const isFinal = index === finalIndex;
    if (message.thinking) {
      steps.push({
        id: `${message.id}:thinking`,
        kind: 'thinking',
        messageId: message.id,
        text: message.thinking,
        ms: message.thinkingMs ?? -1,
        live: false
      });
    }
    if (!isFinal && message.text) {
      steps.push({
        id: `${message.id}:note`,
        kind: 'note',
        messageId: message.id,
        text: message.text,
        ms: -1,
        live: false
      });
    }
    if (!isFinal && message.imageCount) {
      extraImageMessages.push(message);
    }
    const tools = message.tools ?? [];
    for (const tool of tools) {
      steps.push({
        id: `${message.id}:tool:${tool.id}`,
        kind: 'tool',
        messageId: message.id,
        text: tool.detail,
        ms: tool.ms ?? -1,
        tool,
        live: false
      });
    }
  }

  for (const tool of liveTools) {
    steps.push({
      id: `live:tool:${tool.id}`,
      kind: 'tool',
      messageId: '',
      text: tool.detail,
      ms: tool.ms ?? -1,
      tool,
      live: true
    });
  }

  if (liveThinking) {
    steps.push({
      id: 'live:thinking',
      kind: 'thinking',
      messageId: '',
      text: liveThinking,
      ms: -1,
      live: true
    });
  }

  const finalMessage = finalIndex >= 0 ? group[finalIndex] : undefined;
  const firstId = group.length > 0 ? group[0].id : 'live';
  const isLiveTurn = hasLive || !idle;
  const processId = isLiveTurn ? 'live' : firstId;
  const summary = buildProcessSummary(steps, isLiveTurn, idle);

  if (!finalMessage && !steps.length && !liveText && !extraImageMessages.length) return;

  turns.push({
    id: finalMessage ? `turn:${firstId}:${finalMessage.id}` : `turn:${firstId}:live`,
    kind: 'assistant',
    message: finalMessage,
    processId,
    steps,
    summary,
    extraImageMessages,
    isLive: isLiveTurn,
    liveText
  });
}

export function buildTranscriptTurns(
  messages: ChatMessage[],
  unlistedLiveTools: LiveTool[],
  liveThinking: string,
  liveText: string,
  idle: boolean
): TranscriptTurn[] {
  const turns: TranscriptTurn[] = [];
  let pendingAssistant: ChatMessage[] = [];

  for (const message of messages) {
    if (message.role === 'user') {
      if (pendingAssistant.length > 0) {
        appendAssistantTurn(turns, pendingAssistant, [], '', '', true);
        pendingAssistant = [];
      }
      if (message.text || message.imageCount) {
        turns.push({
          id: `user:${message.id}`,
          kind: 'user',
          message,
          processId: '',
          steps: [],
          extraImageMessages: [],
          isLive: false,
          liveText: ''
        });
      }
    } else {
      pendingAssistant.push(message);
    }
  }

  appendAssistantTurn(turns, pendingAssistant, unlistedLiveTools, liveThinking, liveText, idle);
  return turns;
}
