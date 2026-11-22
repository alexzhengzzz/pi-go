import type { SidebarRow } from './PiGoTypes';

export class SidebarRows implements IDataSource {
  private rows: SidebarRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.rows.length; }
  getData(index: number): SidebarRow { return this.rows[index]; }
  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener): boolean => item !== listener);
  }
  replace(rows: SidebarRow[]): void {
    if (this.rows.length === rows.length && this.rows.every((row: SidebarRow, index: number): boolean => row.key === rows[index].key)) return;
    this.rows = rows;
    for (const listener of this.listeners) listener.onDataReloaded();
  }
  anchor(sessionId: string, workspace: string): number {
    const session = this.rows.findIndex((row: SidebarRow): boolean => row.session?.id === sessionId);
    return session >= 0 ? session : this.rows.findIndex((row: SidebarRow): boolean => row.path === workspace);
  }
}
