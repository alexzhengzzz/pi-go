import type { BridgeReply, SessionRow, SidebarRow, WorkspaceRow } from './PiGoTypes';

// Sidebar UI choices worth remembering between launches; plain state, no secrets.
export const SIDEBAR_VIEWS: string[] = ['all', 'pinned', 'recent', 'archived'];
export const SIDEBAR_MAX_EXPANDED = 100;
export const SIDEBAR_MAX_ENTRIES = 24;

export interface SidebarState {
  expandedSpaces: string[];
  sessionView: string;
}

export interface SidebarEntry {
  address: string;
  state: SidebarState;
}

export interface SidebarBook {
  version: number;
  entries: SidebarEntry[];
}

export interface SessionCatalog {
  sessions: SessionRow[];
  reply: BridgeReply;
}

export interface WorkspacePage {
  path: string;
  sessions: SessionRow[];
  nextCursor?: number;
  loading: boolean;
  failed: boolean;
  requestId?: number;
  retryRefresh?: boolean;
}

export interface SidebarCatalog {
  view: string;
  loadedView: string;
  sessions: SessionRow[];
  projects: string[];
  workspaces: WorkspaceRow[];
  workspacePages?: WorkspacePage[];
  nextCursor?: number;
  expandedSpaces: string[];
}

export function workspaceName(workspaces: WorkspaceRow[], path: string): string {
  return workspaces?.find((row: WorkspaceRow): boolean => row.cwd === path)?.name || path.split('/').pop() || path;
}

export class SessionStore {
  private sidebar: SidebarBook = { version: 1, entries: [] };
  private saveTimer: number = -1;

  restoreSidebar(book: SidebarBook): void {
    this.sidebar = book;
  }

  sidebarFor(address: string): SidebarState {
    const entry = this.sidebar.entries.find((item: SidebarEntry): boolean => item.address === address);
    const view = entry?.state.sessionView ?? 'all';
    return {
      expandedSpaces: entry?.state.expandedSpaces.slice() ?? [],
      sessionView: SIDEBAR_VIEWS.includes(view) ? view : 'all'
    };
  }

  saveSidebar(address: string, state: SidebarState, persist: (book: SidebarBook) => void): void {
    if (!address) return;
    this.removeSidebar(address);
    this.sidebar.entries.push({
      address: address,
      state: {
        expandedSpaces: state.expandedSpaces.slice(0, SIDEBAR_MAX_EXPANDED),
        sessionView: SIDEBAR_VIEWS.includes(state.sessionView) ? state.sessionView : 'all'
      }
    });
    this.sidebar = { version: 1, entries: this.sidebar.entries.slice(0, SIDEBAR_MAX_ENTRIES) };
    if (this.saveTimer !== -1) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => { this.flushSidebar(persist); }, 300);
  }

  removeSidebar(address: string): void {
    this.sidebar = { version: 1, entries: this.sidebar.entries.filter((item: SidebarEntry): boolean => item.address !== address) };
  }

  flushSidebar(persist: (book: SidebarBook) => void): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    persist(this.sidebar);
  }

  toggleSpace(expanded: string[], path: string): string[] {
    return expanded.includes(path) ? expanded.filter((item: string): boolean => item !== path) : expanded.concat([path]);
  }

  async loadCatalog(
    view: string,
    request: (path: string) => Promise<BridgeReply>,
    cursor: number = 0,
    workspace: string = '',
    refresh: boolean = false
  ): Promise<SessionCatalog> {
    const scope = workspace ? 'workspace' : view === 'all' ? 'workspaces' : 'filtered';
    const limit = workspace ? 10 : 20;
    let path = `/sessions?scope=${scope}&limit=${limit}&cursor=${cursor}&view=${view}`;
    if (workspace) path += '&cwd=' + encodeURIComponent(workspace);
    if (refresh && scope !== 'workspaces') path += '&refresh=1';
    const reply = await request(path);
    return { sessions: reply.sessions ?? [], reply: reply };
  }

  rows(catalog: SidebarCatalog): SidebarRow[] {
    const rows: SidebarRow[] = [];
    if (catalog.view !== 'all') {
      if (catalog.view !== catalog.loadedView) return rows;
      for (const session of catalog.sessions) rows.push(this.sessionRow(session, false));
      if (catalog.nextCursor !== undefined) rows.push({ key: 'more:sessions', more: '', nested: false });
      return rows;
    }

    const expanded = new Set<string>(catalog.expandedSpaces);
    for (const path of catalog.projects) {
      rows.push({ key: `space:${path}:${workspaceName(catalog.workspaces, path)}`, path: path, nested: false });
      if (!expanded.has(path)) continue;
      const page = catalog.workspacePages?.find((item: WorkspacePage): boolean => item.path === path);
      if (!page) continue;
      for (const session of page.sessions) rows.push(this.sessionRow(session, true));
      if (page.loading || page.failed || page.nextCursor !== undefined || !page.sessions.length) {
        const label = page.loading ? '正在加载会话…' : page.failed ? '重试' : page.nextCursor !== undefined ? '加载更多' : '暂无会话';
        const actionable = !page.loading && (page.failed || page.nextCursor !== undefined);
        rows.push({ key: `page:${path}:${label}`, more: actionable ? path : undefined, label: label, nested: true });
      }
    }
    return rows;
  }

  private sessionRow(session: SessionRow, nested: boolean): SidebarRow {
    const key = `session:${session.id}:${nested}:${session.revision}:${session.pinned}:${session.archived}:${session.nativeArchived}:${session.cwd ?? ''}:${session.name ?? ''}`;
    return { key: key, session: session, nested: nested };
  }
}
