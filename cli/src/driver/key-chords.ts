import { ErrorCodes, PeekrError } from '../errors.js';

export interface KeySpec { key: string; code: string; windowsVirtualKeyCode: number; modifier?: number }
const NAMED: Record<string, [string, number]> = {
  Enter:['Enter',13], Tab:['Tab',9], Escape:['Escape',27], Backspace:['Backspace',8], Delete:['Delete',46],
  Space:['Space',32], ArrowLeft:['ArrowLeft',37], ArrowUp:['ArrowUp',38], ArrowRight:['ArrowRight',39],
  ArrowDown:['ArrowDown',40], Home:['Home',36], End:['End',35], PageUp:['PageUp',33], PageDown:['PageDown',34],
};
const MODIFIERS: Record<string, KeySpec> = {
  alt:{key:'Alt', code:'AltLeft', windowsVirtualKeyCode:18, modifier:1},
  control:{key:'Control', code:'ControlLeft', windowsVirtualKeyCode:17, modifier:2},
  meta:{key:'Meta', code:'MetaLeft', windowsVirtualKeyCode:91, modifier:4},
  shift:{key:'Shift', code:'ShiftLeft', windowsVirtualKeyCode:16, modifier:8},
};
const ALIASES: Record<string, string> = {cmd:'meta', command:'meta', ctrl:'control', option:'alt', esc:'Escape', return:'Enter', space:'Space'};

function keySpec(raw: string, platform: string): KeySpec {
  let name = raw.toLowerCase();
  if (name === 'controlormeta' || name === 'mod') name = platform === 'darwin' ? 'meta' : 'control';
  name = ALIASES[name] ?? name;
  if (MODIFIERS[name]) return MODIFIERS[name];
  const named = Object.keys(NAMED).find(key => key.toLowerCase() === name.toLowerCase());
  if (named) return {key:named === 'Space' ? ' ' : named, code:NAMED[named][0], windowsVirtualKeyCode:NAMED[named][1]};
  if (/^F(?:[1-9]|1[0-2])$/i.test(raw)) return {key:raw.toUpperCase(), code:raw.toUpperCase(), windowsVirtualKeyCode:111+Number(raw.slice(1))};
  if (raw.length === 1) {
    const upper = raw.toUpperCase();
    return {key:raw, code:/[a-z]/i.test(raw) ? `Key${upper}` : /[0-9]/.test(raw) ? `Digit${raw}` : '',
      windowsVirtualKeyCode:/[a-z0-9]/i.test(raw) ? upper.charCodeAt(0) : 0};
  }
  throw new PeekrError(ErrorCodes.invalidArgument, `Unsupported key: ${raw}`);
}

export function parseChord(chord: string, platform = process.platform): KeySpec[] {
  if (typeof chord !== 'string' || !chord) throw new PeekrError(ErrorCodes.invalidArgument, 'A key or chord is required.');
  const parts = chord === '+' ? ['+'] : chord.split('+');
  if (parts.some(part => !part)) throw new PeekrError(ErrorCodes.invalidArgument, 'Malformed key chord.');
  const keys = parts.map(part => keySpec(part, platform));
  if (keys.slice(0,-1).some(key => !key.modifier) || new Set(keys.map(key => key.key)).size !== keys.length) {
    throw new PeekrError(ErrorCodes.invalidArgument, 'A chord has unique modifiers followed by one key.');
  }
  return keys;
}
