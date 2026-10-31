import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PopupState } from '../popup-state.js';
const snapshot = (revision, volume) => ({ revision, tabs: [{ tabId: 7, volume, muted: false }] });

test('rapid keyboard changes are not overwritten by earlier in-flight acknowledgements', () => {
  const rendered = [];
  const state = new PopupState(tabs => rendered.push(tabs[0].volume));
  state.receive(snapshot(1, 0.3));
  state.begin(); // Arrow right to 31%.
  state.begin(); // Arrow right again before its acknowledgement: 32%.
  state.receive(snapshot(2, 0.31));
  state.end();
  assert.deepEqual(rendered, [0.3]);
  state.receive(snapshot(3, 0.32));
  state.end();
  assert.equal(rendered.at(-1), 0.32);
  state.receive(snapshot(2, 0.31)); // Late broadcast from the first command.
  assert.equal(rendered.at(-1), 0.32);
});

test('pointer-up waits for the last outstanding change, and errors can reconcile a removed tab', () => {
  const rendered = [];
  const state = new PopupState(tabs => rendered.push(tabs));
  state.receive(snapshot(9, 0.5));
  state.gesture(true); state.begin();
  state.receive(snapshot(10, 0.2));
  state.gesture(false);
  assert.equal(rendered.length, 1);
  state.receive({ revision: 11, tabs: [] });
  state.end();
  assert.deepEqual(rendered.at(-1), []);
});
