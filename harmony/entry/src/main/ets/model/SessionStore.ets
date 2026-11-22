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

export interface SidebarCatalog {
  view: string;
  loadedView: string;
  sessions: SessionRow[];
  projects: string[];
  workspaces: WorkspaceRow[];
  hasWorkspaceDetails: boolean;
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
    current: () => boolean,
    firstPage: (page: SessionCatalog) => void
  ): Promise<SessionCatalog | undefined> {
    const sessions: SessionRow[] = [];
    const ids = new Set<string>();
    let cursor: number | undefined = 0;
    let reply: BridgeReply;
    do {
      reply = await request(`/sessions?limit=100&cursor=${cursor}&view=${view}`);
      if (!current()) return undefined;
      for (const row of reply.sessions ?? []) {
        if (ids.has(row.id)) continue;
        ids.add(row.id);
        sessions.push(row);
      }
      const next = reply.nextCursor;
      if (cursor === 0 && next !== undefined) firstPage({ sessions: sessions.slice(), reply: reply });
      cursor = next !== undefined && next > cursor ? next : undefined;
    } while (cursor !== undefined);
    return { sessions: sessions, reply: reply };
  }

  rows(catalog: SidebarCatalog): SidebarRow[] {
    const rows: SidebarRow[] = [];
    const visibleSessions = catalog.view === catalog.loadedView ? catalog.sessions : [];
    if (catalog.view !== 'all') {
      for (const session of visibleSessions) rows.push(this.sessionRow(session, false));
      return rows;
    }

    const bySpace = new Map<string, SessionRow[]>();
    const paths = new Set<string>(catalog.projects);
    const expanded = new Set<string>(catalog.expandedSpaces);
    for (const session of visibleSessions) {
      if (!session.cwd) continue;
      if (catalog.hasWorkspaceDetails) paths.add(session.cwd);
      if (!expanded.has(session.cwd)) continue;
      let group = bySpace.get(session.cwd);
      if (!group) { group = []; bySpace.set(session.cwd, group); }
      group.push(session);
    }
    for (const path of paths) {
      rows.push({ key: `space:${path}:${workspaceName(catalog.workspaces, path)}`, path: path, nested: false });
      for (const session of bySpace.get(path) ?? []) rows.push(this.sessionRow(session, true));
    }
    return rows;
  }

  private sessionRow(session: SessionRow, nested: boolean): SidebarRow {
    const key = `session:${session.id}:${nested}:${session.revision}:${session.pinned}:${session.archived}:${session.cwd ?? ''}:${session.name ?? ''}`;
    return { key: key, session: session, nested: nested };
  }
}
