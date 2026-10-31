(() => {
  const parameters = new URL(location.href).searchParams;
  const scenario = parameters.get('scenario') || 'multiple';
  const language = parameters.get('lang') || 'zh-CN';
  Object.defineProperty(navigator, 'language', { configurable: true, get: () => language });
  Object.defineProperty(navigator, 'languages', { configurable: true, get: () => [language] });
  const titles = language.startsWith('zh') ? [
    '雨天书店 · 一小时的安静爵士',
    '深夜电台：和城市一起慢下来',
    '设计的细节 — 从声音、节奏和留白开始，聊聊那些让工具真正好用的微小决定'
  ] : [
    'A quiet afternoon · Jazz at the bookshop',
    'Late night radio — A slower kind of evening',
    'The details of design — Sound, rhythm, and all the little decisions that make a tool feel right'
  ];
  if (language.startsWith('ar')) titles.splice(0, titles.length,
    'جاز هادئ · مكتبة تحت المطر', 'راديو الليل — على مهل',
    'تفاصيل التصميم — الصوت والإيقاع والقرارات الصغيرة التي تجعل الأدوات سهلة الاستخدام');
  if (scenario === 'long') titles[0] = titles[2] + ' · ' + titles[2];
  let tabs = scenario === 'empty' || scenario === 'restricted' ? [] : [
    { tabId: 7, title: titles[0], url: 'https://www.youtube.com/watch?v=fixture', volume: 0.42, muted: false },
    { tabId: 8, title: titles[1], url: 'https://music.example.com/listen', volume: 0.68, muted: true },
    { tabId: 9, title: titles[2], url: 'https://podcasts.example.com/episode', volume: 1, muted: false }
  ];
  if (scenario === 'many') tabs = [...tabs, ...Array.from({ length: 9 }, (_, i) => ({
    tabId: 20 + i, title: titles[i % 3], url: `https://audio${i}.example.com`, volume: (i + 1) / 10, muted: false
  }))];
  const active = { id: scenario === 'error' || scenario === 'long' ? 10 : 7, title: titles[0],
    url: scenario === 'restricted' ? 'chrome://extensions' : 'https://www.youtube.com/watch?v=fixture' };
  const listeners = [];
  let revision = 0, queue = Promise.resolve();
  const fixture = { calls: [], latency: 0, failNext: '', tabs: () => structuredClone(tabs), ready: true };
  const mock = {
    i18n: { getUILanguage: () => language },
    tabs: { query: async () => [{ ...active }] },
    runtime: {
      onMessage: { addListener(listener) { listeners.push(listener); } },
      sendMessage(message) {
        fixture.calls.push(structuredClone(message));
        const result = queue.then(async () => {
          if (fixture.latency) await new Promise(resolve => setTimeout(resolve, fixture.latency));
          if (scenario === 'disconnected') return { ok: false, error: 'Audio processor unavailable' };
          if (fixture.failNext || (scenario === 'error' && message.action === 'start')) {
            const error = fixture.failNext || (language.startsWith('zh') ? '此网页暂时无法捕获音频。请刷新网页后重试。' : 'This page could not share its audio. Reload it and try again.');
            fixture.failNext = ''; return { ok: false, error };
          }
          if (message.action === 'start' && !tabs.some(tab => tab.tabId === message.tabId)) tabs.push({ ...active, tabId: active.id, volume: 1, muted: false });
          if (message.action === 'set') {
            const tab = tabs.find(tab => tab.tabId === message.tabId);
            if (!tab) return { ok: false, error: 'Tab is no longer controlled' };
            tab.volume = message.volume; tab.muted = message.muted;
          }
          if (message.action === 'stop') tabs = tabs.filter(tab => tab.tabId !== message.tabId);
          const response = { ok: true, revision: ++revision, tabs: structuredClone(tabs) };
          for (const listener of listeners) listener({ target: 'popup', ...response });
          return response;
        });
        queue = result.catch(() => {});
        return result;
      }
    }
  };
  Object.defineProperty(window, 'chrome', { configurable: true, value: mock });
  window.__fixture = fixture;
})();
