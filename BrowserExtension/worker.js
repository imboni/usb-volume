const OFFSCREEN = chrome.runtime.getURL('offscreen.html');
const POPUP = chrome.runtime.getURL('popup.html');
// Serialize startup, slider changes and teardown; an ended stream cannot race a new route.
let queue = Promise.resolve();
let revision = 0;
const revisionReady = chrome.storage.session.get('stateRevision').then(saved => {
  if (Number.isSafeInteger(saved.stateRevision) && saved.stateRevision >= 0) revision = saved.stateRevision;
});
function enqueue(operation) {
  const result = queue.then(operation);
  queue = result.catch(() => {});
  return result;
}
async function hasOffscreen() {
  return (await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'], documentUrls: [OFFSCREEN] })).length > 0;
}
async function audio(action, properties = {}) {
  const response = await chrome.runtime.sendMessage({ target: 'offscreen', action, ...properties });
  if (!response?.ok) throw new Error(response?.error || 'Audio processor unavailable');
  return response.routes;
}
async function ensureOffscreen() {
  if (!await hasOffscreen()) await chrome.offscreen.createDocument({
    url: 'offscreen.html', reasons: ['USER_MEDIA'],
    justification: 'Adjust and play the audio of tabs explicitly enabled by the user, locally without recording.'
  });
}
async function state() {
  // The live audio graph is authoritative, including after the worker restarts.
  // Never re-capture a tab from stale cached/session data without a new click.
  const routes = await hasOffscreen() ? await audio('snapshot') : [];
  const tabs = [];
  for (const route of routes) {
    try {
      const tab = await chrome.tabs.get(route.tabId);
      // The popup supplies its localized placeholder when a title is unavailable.
      tabs.push({ ...route, title: tab.title || '', url: tab.url || '' });
    } catch { await audio('stop', { tabId: route.tabId }); }
  }
  await revisionReady;
  const snapshot = { tabs, revision: ++revision };
  await chrome.storage.session.set({ controlledTabs: tabs, stateRevision: revision });
  await chrome.action.setBadgeBackgroundColor({ color: '#3366cc' });
  await chrome.action.setBadgeText({ text: tabs.length ? String(tabs.length) : '' });
  return snapshot;
}
async function publish() {
  const snapshot = await state();
  chrome.runtime.sendMessage({ target: 'popup', ...snapshot }).catch(() => {});
  return snapshot;
}
async function command(message) {
  switch (message.action) {
    case 'state': return state();
    case 'start': {
      const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
      if (!active || active.id !== message.tabId || !/^https?:\/\//.test(active.url || '')) {
        throw new Error('请在需要控制的普通网页上点击扩展 / Open the extension on the desired web page.');
      }
      await ensureOffscreen();
      const routes = await audio('snapshot');
      if (!routes.some(route => route.tabId === active.id)) {
        const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: active.id });
        await audio('start', { tabId: active.id, streamId });
      }
      return publish();
    }
    case 'set':
      await audio('set', { tabId: message.tabId, volume: message.volume, muted: message.muted });
      return publish();
    case 'stop':
      if (await hasOffscreen()) {
        const routes = await audio('stop', { tabId: message.tabId });
        if (!routes.length) await chrome.offscreen.closeDocument();
      }
      return publish();
    default: throw new Error('Unknown command');
  }
}
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || message?.target !== 'worker') return;
  if (message.action === 'changed' && sender.url === OFFSCREEN) {
    enqueue(publish).then(() => respond({ ok: true }), error => respond({ ok: false, error: error.message }));
    return true;
  }
  // No webpage/content-script command surface. Only the bundled popup can start capture.
  if (sender.url !== POPUP) return;
  enqueue(() => command(message)).then(snapshot => respond({ ok: true, ...snapshot }), error => {
    respond({ ok: false, error: error.message });
  });
  return true;
});
chrome.tabs.onRemoved.addListener(tabId => {
  enqueue(async () => {
    if (await hasOffscreen()) {
      const routes = await audio('stop', { tabId });
      if (!routes.length) await chrome.offscreen.closeDocument();
    }
    await publish();
  }).catch(() => {});
});
chrome.tabs.onUpdated.addListener((_tabId, change) => {
  if (change.title || change.url) enqueue(publish).catch(() => {});
});
chrome.tabCapture.onStatusChanged.addListener(info => {
  if (info.status !== 'stopped' && info.status !== 'error') return;
  enqueue(async () => {
    if (await hasOffscreen()) {
      // Recheck current state: an old stopped event must not tear down a newer capture.
      const live = await chrome.tabCapture.getCapturedTabs();
      if (!live.some(item => item.tabId === info.tabId && (item.status === 'active' || item.status === 'pending'))) {
        const routes = await audio('stop', { tabId: info.tabId });
        if (!routes.length) await chrome.offscreen.closeDocument();
      }
    }
    await publish();
  }).catch(() => {});
});
// Wake-up reconciliation clears session entries after an offscreen crash or extension reload.
enqueue(publish).catch(() => {});
