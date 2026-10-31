import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TabAudioEngine } from '../audio-engine.js';

function fixture(overrides = {}) {
  const streams = [], contexts = [];
  function stream() {
    const track = { readyState: 'live', stops: 0, stop() { this.stops++; this.readyState = 'ended'; },
      addEventListener(_name, fn) { this.ended = fn; } };
    const value = { track, getTracks: () => [track], getAudioTracks: () => [track] };
    streams.push(value); return value;
  }
  function createContext() {
    const gain = { gain: { value: 1, cancelAndHoldAtTime() {}, linearRampToValueAtTime(value, time) { this.value = value; this.time = time; } },
      connect() {}, disconnect() { this.disconnected = true; } };
    const source = { connect() { return gain; }, disconnect() { this.disconnected = true; } };
    const context = { state: 'suspended', currentTime: 4, destination: {}, gain, source,
      createGain: () => gain, createMediaStreamSource: () => source,
      async resume() { this.state = 'running'; }, async close() { this.state = 'closed'; } };
    contexts.push(context); return context;
  }
  const engine = new TabAudioEngine({ getUserMedia: async () => stream(), createContext, ...overrides });
  return { engine, streams, contexts, stream, createContext };
}

test('two tabs remain independent; mute retains volume, master-independent gain never exceeds unity', async () => {
  const { engine, streams, contexts } = fixture();
  await engine.start(11, 'a'); await engine.start(22, 'b');
  engine.set(11, 0.5, false);
  assert.equal(contexts[0].gain.gain.value, 0.25);
  assert.equal(contexts[1].gain.gain.value, 1);
  engine.set(11, 0.7, true);
  assert.equal(contexts[0].gain.gain.value, 0);
  assert.equal(engine.snapshot()[0].volume, 0.7);
  engine.set(11, 3, false);
  assert.equal(contexts[0].gain.gain.value, 1);
  assert.equal(contexts[0].gain.gain.time, 4.01);
  assert.throws(() => engine.set(11, NaN, false));
  assert.equal(contexts[0].gain.gain.value, 1);
  await engine.stop(11);
  assert.equal(streams[0].track.stops, 1);
  assert.equal(contexts[0].state, 'closed');
  assert.equal(contexts[0].source.disconnected, true);
  assert.deepEqual(engine.snapshot(), [{ tabId: 22, volume: 1, muted: false }]);
});

test('duplicate activation never creates a second audio path; ended track releases the route', async () => {
  const { engine, streams, contexts } = fixture();
  await engine.start(1, 'first'); await engine.start(1, 'again');
  assert.equal(streams.length, 1);
  streams[0].track.readyState = 'ended';
  streams[0].track.ended();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(engine.snapshot(), []);
  assert.equal(contexts[0].state, 'closed');
  assert.throws(() => engine.set(1, 0.3, false), /no longer/);
});

test('playback startup failure stops captured tracks to restore normal tab playback', async () => {
  const value = fixture();
  value.engine.createContext = () => {
    const context = value.createContext();
    context.resume = async () => { throw new Error('Playback denied'); };
    return context;
  };
  await assert.rejects(value.engine.start(1, 'id'), /Playback denied/);
  assert.equal(value.streams[0].track.stops, 1);
  assert.equal(value.contexts[0].state, 'closed');
  assert.deepEqual(value.engine.snapshot(), []);
});

test('capture timeout also stops a stream that arrives after timeout', async () => {
  let resolveCapture;
  const value = fixture({ timeout: 5, getUserMedia: () => new Promise(resolve => { resolveCapture = resolve; }) });
  await assert.rejects(value.engine.start(1, 'slow'), /timed out/);
  const late = value.stream(); resolveCapture(late);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(late.track.stops, 1);
  assert.deepEqual(value.engine.snapshot(), []);
});

test('a suspended playback context cannot leave captured audio silent indefinitely', async () => {
  const value = fixture({ timeout: 5 });
  value.engine.createContext = () => {
    const context = value.createContext();
    context.resume = () => new Promise(() => {});
    return context;
  };
  await assert.rejects(value.engine.start(1, 'id'), /Playback startup timed out/);
  assert.equal(value.streams[0].track.stops, 1);
  assert.equal(value.contexts[0].state, 'closed');
  assert.deepEqual(value.engine.snapshot(), []);
});
