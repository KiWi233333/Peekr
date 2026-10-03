import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parseChord} from '../dist/peekr.js';

test('portable shortcuts choose the platform modifier', () => {
  assert.equal(parseChord('ControlOrMeta+a','darwin')[0].key,'Meta');
  assert.equal(parseChord('ControlOrMeta+a','linux')[0].key,'Control');
  assert.deepEqual(parseChord('cmd+Shift+z','darwin').map(key=>key.key),['Meta','Shift','z']);
});

test('named keys ignore case while printable keys preserve it', () => {
  assert.equal(parseChord('enter')[0].windowsVirtualKeyCode,13);
  assert.equal(parseChord('ESC')[0].key,'Escape');
  assert.equal(parseChord('A')[0].key,'A');
  assert.equal(parseChord('a')[0].code,'KeyA');
  assert.equal(parseChord('F12')[0].windowsVirtualKeyCode,123);
  assert.equal(parseChord('+')[0].key,'+');
});

test('malformed and ambiguous chords are rejected before dispatch', () => {
  for(const chord of ['', 'Ctrl+', 'a+b', 'Meta+Meta+a', 'Banana', 'Control++a']) {
    assert.throws(()=>parseChord(chord),{code:'PEEKR_INVALID_ARGUMENT'});
  }
});
