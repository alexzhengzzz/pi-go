export interface SyncCursor {
  sessionId: string;
  streamId: string;
  runId: string | null;
  seq: number;
}

export interface SequencedFrame {
  cursor?: SyncCursor;
}

export class SessionSync<T extends SequencedFrame> {
  private readyCursor?: SyncCursor;
  private applied?: SyncCursor;
  private minimum: number = 0;
  private readonly pending: Map<number, T> = new Map<number, T>();

  disconnect(): void {
    this.readyCursor = undefined;
    this.applied = undefined;
    this.minimum = 0;
    this.pending.clear();
  }

  ready(cursor: SyncCursor): void {
    this.disconnect();
    this.readyCursor = cursor;
    this.minimum = cursor.seq;
  }

  private sameStream(left: SyncCursor, right: SyncCursor): boolean {
    return left.sessionId === right.sessionId && left.streamId === right.streamId;
  }

  matches(cursor: SyncCursor): boolean {
    return this.applied !== undefined && this.sameStream(this.applied, cursor);
  }

  receive(frame: T, apply: (event: T) => void): boolean {
    const cursor = frame.cursor;
    if (!cursor || !this.readyCursor || !this.sameStream(cursor, this.readyCursor)) return false;
    if (cursor.seq <= this.minimum || (this.applied && cursor.seq <= this.applied.seq)) return false;
    this.pending.set(cursor.seq, frame);
    if (this.pending.size > 256) {
      for (const seq of this.pending.keys()) this.minimum = Math.max(this.minimum, seq);
      this.pending.clear();
      return true;
    }
    return this.drain(apply);
  }

  snapshot(cursor: SyncCursor, apply: () => void, event: (frame: T) => void): boolean {
    if (this.readyCursor && !this.sameStream(cursor, this.readyCursor)) return false;
    if (cursor.seq < this.minimum || (this.matches(cursor) && this.applied && cursor.seq < this.applied.seq)) return false;
    this.applied = cursor;
    for (const seq of this.pending.keys()) {
      if (seq <= cursor.seq) this.pending.delete(seq);
    }
    apply();
    this.drain(event);
    return true;
  }

  needsSnapshot(): boolean {
    return this.readyCursor !== undefined &&
      (!this.applied || this.minimum > this.applied.seq || this.pending.size > 0);
  }

  private drain(apply: (frame: T) => void): boolean {
    while (this.applied && this.applied.seq >= this.minimum) {
      const next = this.pending.get(this.applied.seq + 1);
      if (!next || !next.cursor) break;
      this.pending.delete(next.cursor.seq);
      this.applied = next.cursor;
      apply(next);
    }
    return this.needsSnapshot();
  }
}
