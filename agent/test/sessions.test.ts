import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { MAX_KNOWN_PER_PROJECT, SessionStore, defaultStorePath } from '../src/sessions.js';

describe('SessionStore', () => {
  let dir = '';
  let path = '';

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'nvime-store-'));
    path = join(dir, 'nested', 'sessions.json');
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('starts empty and creates its directory on first write', () => {
    const store = new SessionStore(path);
    assert.deepEqual(store.get('/proj'), { current: null, known: [] });
    store.remember('/proj', 'a');
    assert.deepEqual(new SessionStore(path).get('/proj'), { current: 'a', known: ['a'] });
  });

  it('keeps the most recent session first without duplicating ids', () => {
    const store = new SessionStore(path);
    store.remember('/proj', 'a');
    store.remember('/proj', 'b');
    store.remember('/proj', 'a');
    assert.deepEqual(store.get('/proj'), { current: 'a', known: ['a', 'b'] });
  });

  it('keeps projects independent', () => {
    const store = new SessionStore(path);
    store.remember('/one', 'a');
    store.remember('/two', 'b');
    assert.equal(store.get('/one').current, 'a');
    assert.equal(store.get('/two').current, 'b');
  });

  it('bounds the remembered list', () => {
    const store = new SessionStore(path);
    for (let i = 0; i <= MAX_KNOWN_PER_PROJECT + 5; i += 1) store.remember('/proj', `s${i}`);
    const known = store.get('/proj').known;
    assert.equal(known.length, MAX_KNOWN_PER_PROJECT);
    assert.equal(known[0], `s${MAX_KNOWN_PER_PROJECT + 5}`);
  });

  it('drops ids the SDK no longer knows, clearing a dead current pointer', () => {
    const store = new SessionStore(path);
    store.remember('/proj', 'a');
    store.remember('/proj', 'b');
    store.retain('/proj', new Set(['a']));
    assert.deepEqual(store.get('/proj'), { current: null, known: ['a'] });
  });

  it('hands back copies, so callers cannot mutate stored state', () => {
    const store = new SessionStore(path);
    store.remember('/proj', 'a');
    store.get('/proj').known.push('forged');
    assert.deepEqual(store.get('/proj').known, ['a']);
  });

  it('refuses an empty root or session id', () => {
    const store = new SessionStore(path);
    assert.throws(() => store.remember('', 'a'));
    assert.throws(() => store.remember('/proj', ''));
  });

  it('degrades to empty on a corrupt file instead of refusing to start', () => {
    writeFileSync(path.replace('nested/', ''), 'not json');
    const store = new SessionStore(path.replace('nested/', ''));
    assert.deepEqual(store.get('/proj'), { current: null, known: [] });
  });

  it('places the default store under XDG_DATA_HOME when set', () => {
    assert.equal(defaultStorePath({ XDG_DATA_HOME: '/xdg' }), '/xdg/nvime/sessions.json');
  });
});
