import { PopupState } from './popup-state.js';
import { loadLocale, isolate, localizedError } from './i18n.js';
const locale = await loadLocale([
  chrome.i18n?.getUILanguage?.(), ...(navigator.languages || [navigator.language])
]);
const { copy } = locale;
document.documentElement.lang = locale.locale;
document.documentElement.dir = locale.direction;
document.title = copy.extensionName;
const $ = id => document.getElementById(id);
$('subtitle').textContent = copy.subtitle;
$('current').setAttribute('aria-label', copy.current);
$('mixer').setAttribute('aria-label', copy.list);
$('hint').textContent = copy.hint;
$('privacy-label').textContent = copy.privacy;
$('help-label').setAttribute('aria-label', copy.help);
$('help-label').title = copy.help;
$('help').addEventListener('toggle', () => {
  document.body.style.minHeight = $('help').open ? Math.min(440, Math.ceil(document.querySelector('.help-content').getBoundingClientRect().bottom + 8)) + 'px' : '';
});
$('dismiss-error').setAttribute('aria-label', copy.dismiss);
$('dismiss-error').title = copy.dismiss;
$('dismiss-error').addEventListener('click', () => { $('error').hidden = true; });
let activeTab, focusStartedTab = false;
const state = new PopupState(render);
const rows = new Map();
async function send(action, properties = {}) {
  let response;
  try { response = await chrome.runtime.sendMessage({ target: 'worker', action, ...properties }); }
  catch { throw new Error(copy.errorConnection); }
  if (!response?.ok) throw new Error(localizedError(response?.error, copy, action === 'start' ? copy.errorCapture : copy.errorOperation));
  $('error').hidden = true;
  return response;
}
function showError(error) { $('error-text').textContent = copy.failure + error.message; $('error').hidden = false; }
function domain(url) {
  try { return new URL(url).hostname.replace(/^www\./, '') || copy.browserPage; } catch { return copy.browserPage; }
}
async function mutate(action, properties) {
  state.begin();
  try { state.receive(await send(action, properties)); }
  catch (error) {
    // Roll back optimistic UI to the actual route if a tab ended mid-command.
    try { state.receive(await send('state')); } catch { /* Keep the initiating error. */ }
    showError(error);
  } finally { state.end(); }
}
function paintMute(row) {
  const label = (row.muted ? copy.unmute : copy.mute) + ' · ' + isolate(row.pageTitle || copy.tab);
  row.querySelector('.mute').setAttribute('aria-label', label);
  row.querySelector('.mute').title = label;
  row.querySelector('.mute use').setAttribute('href', row.muted ? '#icon-muted' : '#icon-speaker');
  row.dataset.muted = String(row.muted);
  if (row.lastMuted !== undefined && row.lastMuted !== row.muted &&
      document.body.dataset.input !== 'keyboard' && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const icon = row.querySelector('.mute svg');
    icon.getAnimations().forEach(animation => animation.cancel());
    icon.animate([{ opacity: .45, transform: 'scale(.9)' }, { opacity: 1, transform: 'scale(1)' }],
      { duration: 140, easing: 'cubic-bezier(.23,1,.32,1)' });
  }
  row.lastMuted = row.muted;
  row.querySelector('.mute').setAttribute('aria-pressed', String(row.muted));
}
function render(tabs) {
  const ids = new Set(tabs.map(tab => tab.tabId));
  let removedFocus = false;
  for (const [id, node] of rows) if (!ids.has(id)) {
    removedFocus ||= node.contains(document.activeElement);
    node.remove(); rows.delete(id);
  }
  for (const tab of tabs) {
    let row = rows.get(tab.tabId);
    if (!row) {
      row = $('row-template').content.firstElementChild.cloneNode(true);
      rows.set(tab.tabId, row);
      $('tabs').append(row);
      const slider = row.querySelector('input');
      slider.addEventListener('pointerdown', () => state.gesture(true));
      slider.addEventListener('input', () => {
        row.querySelector('output').textContent = locale.percent(Number(slider.value) / 100);
        slider.setAttribute('aria-valuetext', locale.percent(Number(slider.value) / 100));
        slider.style.setProperty('--volume', slider.value + '%');
        row.volume = Number(slider.value) / 100;
        // Match the native app: adjusting the slider also unmutes the source.
        row.muted = false;
        paintMute(row);
        void mutate('set', { tabId: tab.tabId, volume: row.volume, muted: false });
      });
      row.querySelector('.mute').addEventListener('click', () => {
        row.muted = !row.muted;
        paintMute(row);
        void mutate('set', { tabId: tab.tabId, volume: row.volume, muted: row.muted });
      });
      row.querySelector('.reset').title = copy.reset;
      row.querySelector('.reset').addEventListener('click', () => {
        row.volume = 1; row.muted = false;
        slider.value = 100; slider.style.setProperty('--volume', '100%'); row.querySelector('output').textContent = locale.percent(1);
        slider.setAttribute('aria-valuetext', locale.percent(1));
        paintMute(row);
        void mutate('set', { tabId: tab.tabId, volume: 1, muted: false });
      });
      row.querySelector('.stop').title = copy.stop + ' · ' + copy.stopped;
      row.querySelector('.stop').addEventListener('click', () => {
        void mutate('stop', { tabId: tab.tabId });
      });
    }
    row.volume = tab.volume; row.muted = tab.muted; row.pageTitle = tab.title;
    row.dataset.tabId = String(tab.tabId);
    const pageTitle = tab.title || copy.tab;
    const title = row.querySelector('.title'); title.textContent = pageTitle; title.title = pageTitle + '\n' + isolate(domain(tab.url));
    row.querySelector('input').value = Math.round(tab.volume * 100);
    row.querySelector('input').style.setProperty('--volume', Math.round(tab.volume * 100) + '%');
    row.querySelector('.reset').setAttribute('aria-label', copy.reset + ' · ' + isolate(pageTitle));
    row.querySelector('.stop').setAttribute('aria-label', copy.stop + ' · ' + isolate(pageTitle));
    row.querySelector('input').setAttribute('aria-label', isolate(pageTitle) + ' · ' + copy.volume);
    row.querySelector('input').setAttribute('aria-valuetext', locale.percent(tab.volume));
    row.querySelector('output').textContent = locale.percent(tab.volume);
    paintMute(row);
  }
  const enabled = tabs.some(tab => tab.tabId === activeTab?.id);
  const eligible = /^https?:\/\//.test(activeTab?.url || '');
  $('enable').disabled = enabled || !eligible;
  $('enable').hidden = enabled;
  $('enable').removeAttribute('aria-busy');
  $('current').hidden = enabled;
  $('enable-label').textContent = eligible ? copy.enable : copy.unavailable;
  if (enabled && focusStartedTab) {
    rows.get(activeTab.id)?.querySelector('input').focus();
    focusStartedTab = false;
  } else if (removedFocus) {
    const target = !$('enable').hidden && !$('enable').disabled ? $('enable') : $('tabs').querySelector('.mute');
    target?.focus();
  }
}
document.body.addEventListener('animationend', event => {
  if (event.target === document.body) document.body.classList.remove('entering');
});
if (matchMedia('(prefers-reduced-motion: reduce)').matches) document.body.classList.remove('entering');
document.addEventListener('keydown', event => {
  document.body.dataset.input = 'keyboard';
  document.body.classList.remove('entering');
  document.getAnimations().forEach(animation => animation.cancel());
  if (event.key === 'Escape' && $('help').open) {
    $('help').open = false; $('help-label').focus(); event.preventDefault();
  }
}, true);
document.addEventListener('pointerdown', event => {
  document.body.dataset.input = 'pointer';
  if (!$('help').contains(event.target)) $('help').open = false;
}, true);
function finishDrag() { state.gesture(false); }
document.addEventListener('pointerup', finishDrag);
document.addEventListener('pointercancel', finishDrag);
window.addEventListener('blur', finishDrag);
chrome.runtime.onMessage.addListener(message => { if (message?.target === 'popup') state.receive(message); });
$('enable').addEventListener('click', async () => {
  focusStartedTab = true;
  $('enable').disabled = true;
  $('enable').setAttribute('aria-busy', 'true');
  $('enable-label').textContent = copy.connecting;
  await mutate('start', { tabId: activeTab.id });
  focusStartedTab = false;
});
try {
  [activeTab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  $('current-title').textContent = activeTab?.title || copy.tab;
  $('current-title').title = (activeTab?.title || copy.tab) + '\n' + isolate(domain(activeTab?.url));
  render([]);
  state.receive(await send('state'));
} catch (error) {
  showError(new Error(error.message + ' ' + copy.reopen));
  $('enable-label').textContent ||= copy.unavailable;
  $('enable').disabled = true;
}
