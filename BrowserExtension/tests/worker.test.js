import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const code = await readFile(new URL('../worker.js', import.meta.url), 'utf8');
function fixture({ routes = [], offscreen = true, active = 7, notifyChanges = false, missingTabs = [], initialRevision = 0 } = {}) {
  const listeners = {}, session = { controlledTabs: [{ tabId: 999 }], stateRevision: initialRevision }, calls = [];
  let captures = [];
  const url = path => 'chrome-extension://extension/' + path;
  const event = name => ({ addListener(fn) { listeners[name] = fn; } });
  const chrome = {
    runtime: { id: 'extension', getURL: url, onMessage: event('message'),
      getContexts: async () => offscreen ? [{}] : [],
      async sendMessage(message) {
        calls.push(message);
        if (message.target !== 'offscreen') return;
        const before = JSON.stringify(routes);
        if (message.action === 'start') routes.push({ tabId: message.tabId, volume: 1, muted: false });
        if (message.action === 'stop') routes = routes.filter(route => route.tabId !== message.tabId);
        if (message.action === 'set') {
          const route = routes.find(route => route.tabId === message.tabId);
          if (!route) return { ok: false, error: 'Missing route' };
          Object.assign(route, { volume: message.volume, muted: message.muted });
        }
        if (notifyChanges && JSON.stringify(routes) !== before) {
          listeners.message({ target: 'worker', action: 'changed' }, { id: 'extension', url: url('offscreen.html') }, () => {});
        }
        return { ok: true, routes: structuredClone(routes) };
      } },
    tabs: { onRemoved: event('removed'), onUpdated: event('updated'),
      get: async id => {
        if (missingTabs.includes(id)) throw new Error('Tab closed');
        return { id, title: 'Tab ' + id, url: 'https://example.com' };
      },
      query: async () => [{ id: active, url: 'https://example.com' }] },
    tabCapture: { onStatusChanged: event('status'), getCapturedTabs: async () => captures,
      getMediaStreamId: async options => { calls.push({ streamRequest: options }); return 'stream'; } },
    offscreen: { async createDocument() { offscreen = true; }, async closeDocument() { offscreen = false; } },
    storage: { session: { async get() { return { ...session }; }, async set(values) { Object.assign(session, values); } } },
    action: { async setBadgeBackgroundColor() {}, async setBadgeText() {} }
  };
  vm.runInNewContext(code, { chrome, console });
  const message = (action, properties = {}, senderURL = url('popup.html')) => new Promise(resolve => {
    const handled = listeners.message({ target: 'worker', action, ...properties }, { id: 'extension', url: senderURL }, resolve);
    if (!handled) resolve(undefined);
  });
  return { message, listeners, session, calls, setCaptures(value) { captures = value; } };
}

test('worker restart discovers live routes and preserves their gain/mute without capturing again', async () => {
  const value = fixture({ routes: [{ tabId: 7, volume: 0.25, muted: true }] });
  const state = await value.message('state');
  assert.equal(state.tabs[0].volume, 0.25);
  assert.equal(state.tabs[0].muted, true);
  assert.equal(value.session.controlledTabs[0].tabId, 7);
  assert.equal(value.calls.filter(call => call.streamRequest).length, 0);
});

test('missing offscreen document clears stale session state without silent recapture', async () => {
  const value = fixture({ offscreen: false });
  const state = await value.message('state');
  assert.equal(state.tabs.length, 0);
  assert.equal(value.session.controlledTabs.length, 0);
  assert.equal(value.calls.filter(call => call.streamRequest).length, 0);
});

test('activation is restricted to popup and current tab; repeated requests are serialized', async () => {
  const value = fixture({ offscreen: false });
  assert.equal(await value.message('start', { tabId: 7 }, 'https://evil.example'), undefined);
  assert.equal((await value.message('start', { tabId: 8 })).ok, false);
  const results = await Promise.all([value.message('start', { tabId: 7 }), value.message('start', { tabId: 7 })]);
  assert.equal(results.every(result => result.ok), true);
  assert.equal(value.calls.filter(call => call.streamRequest).length, 1);
  assert.equal((await value.message('state')).tabs.length, 1);
});

test('tab close tears down only that tab; stale stopped event cannot kill a newer active capture', async () => {
  const value = fixture({ routes: [{ tabId: 7, volume: 0.25, muted: false }, { tabId: 8, volume: 1, muted: false }] });
  await value.message('state');
  value.setCaptures([{ tabId: 7, status: 'active' }]);
  value.listeners.status({ tabId: 7, status: 'stopped' });
  assert.equal((await value.message('state')).tabs.length, 2);
  value.listeners.removed(8);
  const state = await value.message('state');
  assert.equal(state.tabs.length, 1);
  assert.equal(state.tabs[0].tabId, 7);
});

test('offscreen change notifications do not deadlock the command queue or recursively publish', async () => {
  const value = fixture({ offscreen: false, notifyChanges: true });
  assert.equal((await value.message('start', { tabId: 7 })).ok, true);
  assert.equal((await value.message('set', { tabId: 7, volume: 0.4, muted: false })).ok, true);
  const result = await value.message('state');
  assert.equal(result.tabs[0].volume, 0.4);
  await new Promise(resolve => setImmediate(resolve));
  const count = value.calls.length;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(value.calls.length, count);
  assert.ok(count < 30, 'bounded notifications, no state/changed feedback loop');
});

test('reconciliation removes a disappeared tab once and revisions survive worker restart', async () => {
  const value = fixture({ routes: [{ tabId: 7, volume: 0.4, muted: false }],
    notifyChanges: true, missingTabs: [7], initialRevision: 47 });
  const result = await value.message('state');
  assert.deepEqual(Array.from(result.tabs), []);
  assert.ok(result.revision > 47);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(value.calls.filter(call => call.action === 'stop').length, 1);
});
