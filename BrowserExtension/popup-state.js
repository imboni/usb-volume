// Preserve local keyboard/pointer edits until every earlier command has settled.
// Worker snapshots carry a session-persisted revision so delayed broadcasts or
// responses cannot overwrite a newer value, even after worker suspension.
export class PopupState {
  constructor(render) {
    this.render = render;
    this.pending = 0;
    this.dragging = false;
    this.latest = { revision: -1, tabs: [] };
  }
  receive(snapshot) {
    if (!snapshot || !Number.isSafeInteger(snapshot.revision) || !Array.isArray(snapshot.tabs) ||
        snapshot.revision <= this.latest.revision) return;
    this.latest = snapshot;
    this.flush();
  }
  begin() { this.pending++; }
  end() { this.pending = Math.max(0, this.pending - 1); this.flush(); }
  gesture(active) { this.dragging = active; this.flush(); }
  flush() { if (!this.pending && !this.dragging && this.latest.revision >= 0) this.render(this.latest.tabs); }
}
