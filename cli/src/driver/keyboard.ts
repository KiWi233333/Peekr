// Keyboard driver: key chord dispatch and text entry through the Input
// pipeline (IME-safe), plus fillInput which focuses and selects first so the
// new text replaces the old across React/Vue controlled inputs.

import { resolveTarget, resolveElement, callElement } from "./locator.js";
import type { ClickTarget } from "./pointer.js";
import { currentSocket } from "./nav.js";
import { ErrorCodes, PeekrError } from '../errors.js';
import { parseChord, type KeySpec } from './key-chords.js';

export async function pressKey(chord: string, options: { delay?: number } = {}): Promise<void> {
  const keys = parseChord(chord);
  const delay = options.delay ?? 0;
  if (!Number.isFinite(delay) || delay < 0) throw new PeekrError(ErrorCodes.invalidArgument, 'delay must be nonnegative milliseconds.');
  const socket = await currentSocket();
  let modifiers = 0;
  const pressed: KeySpec[] = [];
  let failure: unknown;
  try {
    for (const key of keys) {
      modifiers |= key.modifier ?? 0;
      const {modifier: _, ...event} = key;
      const commands = process.platform === 'darwin' && modifiers === 4 && key.key.toLowerCase() === 'a' ? ['selectAll'] : undefined;
      await socket.send('Input.dispatchKeyEvent', {type:'rawKeyDown', ...event, modifiers, commands});
      pressed.push(key);
      if (key.key.length === 1 && !(modifiers & 7)) {
        const text = modifiers & 8 ? key.key.toUpperCase() : key.key;
        await socket.send('Input.dispatchKeyEvent', {type:'char', ...event, key:text, text, modifiers});
      }
    }
    if (delay) await new Promise(resolve => setTimeout(resolve, delay));
  } catch (error) { failure = error; }
  // Every release still passes the ownership guard. Never bypass a takeover for cleanup.
  for (const key of pressed.reverse()) {
    modifiers &= ~(key.modifier ?? 0);
    const {modifier: _, ...event} = key;
    try { await socket.send('Input.dispatchKeyEvent', {type:'keyUp', ...event, modifiers}); }
    catch (error) { failure ??= error; }
  }
  if (failure) throw failure;

}

export async function typeKeys(text: string, options: { delay?: number } = {}): Promise<void> {
  if (typeof text !== 'string') throw new PeekrError(ErrorCodes.invalidArgument, 'text must be a string.');
  const delay = options.delay ?? 0;
  if (!Number.isFinite(delay) || delay < 0) throw new PeekrError(ErrorCodes.invalidArgument, 'delay must be nonnegative milliseconds.');
  for (const character of text) {
    if (character.length === 1) await pressKey(character);
    else await typeText(character);
    if (delay) await new Promise(resolve => setTimeout(resolve, delay));
  }
}

export async function typeText(text: string): Promise<void> {
  const socket = await currentSocket();
  await socket.send("Input.insertText", { text });
}

/** Focus the element, select its content, then insert text as real input. */
export async function fillInput(target: ClickTarget, text: string): Promise<void> {
  if (typeof text !== 'string') throw new PeekrError(ErrorCodes.invalidArgument, 'fill requires text.');
  await resolveTarget(target);
  const element = await resolveElement(target as string | number);
  await callElement(element, `
    if (this.readOnly) throw Error('Element is readonly');
    const textTypes = ['text','search','email','url','tel','password','number'];
    if (this.tagName === 'TEXTAREA' || (this.tagName === 'INPUT' && textTypes.includes(this.type))) {
      this.focus(); this.select();
    } else if (this.isContentEditable) {
      this.focus();
      const range = this.ownerDocument.createRange(); range.selectNodeContents(this);
      const selection = this.ownerDocument.defaultView.getSelection();
      selection.removeAllRanges(); selection.addRange(range);
    } else { throw Error('Expected a text input, textarea or contenteditable element'); }
  `);
  if (text) await element.socket.send('Input.insertText', {text});
  else await pressKey('Backspace');
}
