export function normalizeVolume(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error('Invalid volume');
  return Math.min(1, Math.max(0, value));
}

// Only this document owns streams. A service-worker suspension never drops audio.
export class TabAudioEngine {
  constructor({ getUserMedia, createContext, changed = () => {}, timeout = 8000 }) {
    Object.assign(this, { getUserMedia, createContext, changed, timeout });
    this.routes = new Map();
  }
  snapshot() {
    return [...this.routes.values()].map(({ tabId, volume, muted }) => ({ tabId, volume, muted }));
  }
  async start(tabId, streamId, volume = 1, muted = false) {
    if (!Number.isInteger(tabId) || tabId < 0 || typeof streamId !== 'string' || !streamId) throw new Error('Invalid capture');
    volume = normalizeVolume(volume);
    if (this.routes.has(tabId)) return this.snapshot();
    let stream, context, timer, expired = false;
    const acquisition = this.getUserMedia({
      audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
      video: false
    }).then(result => {
      if (expired) result.getTracks().forEach(track => track.stop());
      return result;
    });
    try {
      stream = await Promise.race([acquisition, new Promise((_, reject) => {
        timer = setTimeout(() => { expired = true; reject(new Error('Capture timed out')); }, this.timeout);
      })]);
      clearTimeout(timer);
      if (!stream.getAudioTracks().some(track => track.readyState === 'live')) throw new Error('No audio track');
      context = this.createContext();
      const gain = context.createGain();
      gain.gain.value = muted ? 0 : volume * volume;
      const source = context.createMediaStreamSource(stream);
      source.connect(gain).connect(context.destination);
      await Promise.race([context.resume(), new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Playback startup timed out')), this.timeout);
      })]);
      clearTimeout(timer);
      if (context.state !== 'running') throw new Error('Audio playback unavailable');
      const route = { tabId, stream, context, source, gain, volume, muted: !!muted };
      this.routes.set(tabId, route);
      for (const track of stream.getTracks()) track.addEventListener('ended', () => {
        if (this.routes.get(tabId) === route) void this.stop(tabId);
      }, { once: true });
      // A track may have ended while AudioContext.resume() was pending.
      if (!stream.getAudioTracks().some(track => track.readyState === 'live')) {
        await this.stop(tabId);
        throw new Error('Capture ended before playback started');
      }
      this.changed(this.snapshot());
      return this.snapshot();
    } catch (error) {
      clearTimeout(timer);
      stream?.getTracks().forEach(track => track.stop());
      if (context) await context.close().catch(() => {});
      throw error;
    }
  }
  set(tabId, volume, muted) {
    const route = this.routes.get(tabId);
    if (!route) throw new Error('Tab is no longer controlled');
    volume = normalizeVolume(volume);
    const parameter = route.gain.gain;
    const now = route.context.currentTime;
    if (parameter.cancelAndHoldAtTime) parameter.cancelAndHoldAtTime(now);
    else { parameter.cancelScheduledValues(now); parameter.setValueAtTime(parameter.value, now); }
    parameter.linearRampToValueAtTime(muted ? 0 : volume * volume, now + 0.01);
    route.volume = volume;
    route.muted = !!muted;
    this.changed(this.snapshot());
    return this.snapshot();
  }
  async stop(tabId) {
    const route = this.routes.get(tabId);
    if (!route) return this.snapshot();
    this.routes.delete(tabId);
    route.source.disconnect();
    route.gain.disconnect();
    route.stream.getTracks().forEach(track => track.stop());
    await route.context.close().catch(() => {});
    this.changed(this.snapshot());
    return this.snapshot();
  }
}
