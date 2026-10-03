import { access, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { resolve } from 'node:path';
import { ErrorCodes, PeekrError } from '../errors.js';
import { callElement, resolveElement, type ElementTarget } from './locator.js';
import { click } from './pointer.js';

const FORM_GUARD = `
  if (!this.isConnected) throw Error('Element is detached');
  if (this.matches(':disabled') || this.closest('[aria-disabled="true"], [inert]')) throw Error('Element is disabled');
`;

export async function setChecked(target: ElementTarget, checked: boolean): Promise<void> {
  if (typeof checked !== 'boolean') throw new PeekrError(ErrorCodes.invalidArgument, 'checked must be a boolean.');
  const element = await resolveElement(target);
  const read = `${FORM_GUARD}
    if (this.tagName !== 'INPUT' || !['checkbox','radio'].includes(this.type)) throw Error('Expected a checkbox or radio input');
    if (this.type === 'radio' && !${checked}) throw Error('A radio button cannot be unchecked directly');
    return this.checked;`;
  if (await callElement<boolean>(element, read) === checked) return;
  await click(target);
  if (await callElement<boolean>(element, read) !== checked) {
    throw new PeekrError(ErrorCodes.actionFailed, 'Input did not reach the requested checked state.');
  }
}

export type SelectOption = string | { value?: string; label?: string; index?: number };
export async function selectOption(target: ElementTarget, values: SelectOption | SelectOption[]): Promise<string[]> {
  const requested = Array.isArray(values) ? values : [values];
  for (const option of requested) {
    if (typeof option === 'string') continue;
    if (!option || Object.keys(option).length !== 1 ||
        !((typeof option.value === 'string') || (typeof option.label === 'string') ||
          (Number.isInteger(option.index) && option.index! >= 0))) {
      throw new PeekrError(ErrorCodes.invalidArgument, 'Select options require a value string or exactly one value, label or nonnegative index.');
    }
  }
  return callElement<string[]>(await resolveElement(target), `${FORM_GUARD}
    if (this.tagName !== 'SELECT') throw Error('Expected a select element');
    const requested = ${JSON.stringify(requested)};
    if (!this.multiple && requested.length > 1) throw Error('Select does not allow multiple options');
    const options = Array.from(this.options);
    const selected = requested.map(wanted => {
      const matches = options.filter((option, index) => typeof wanted === 'string' ? option.value === wanted :
        wanted.value !== undefined ? option.value === wanted.value :
        wanted.label !== undefined ? option.label === wanted.label : index === wanted.index);
      if (matches.length !== 1) throw Error('Option is missing or ambiguous');
      const option = matches[0];
      if (option.disabled || option.parentElement?.disabled) throw Error('Option is disabled');
      return option;
    });
    for (const option of options) option.selected = selected.includes(option);
    if (!selected.length) this.selectedIndex = -1;
    const Event = this.ownerDocument.defaultView.Event;
    this.dispatchEvent(new Event('input', {bubbles:true}));
    this.dispatchEvent(new Event('change', {bubbles:true}));
    return Array.from(this.selectedOptions, option => option.value);
  `);
}

export async function setInputFiles(target: ElementTarget, paths: string | string[]): Promise<void> {
  const files = Array.isArray(paths) ? paths : [paths];
  if (!files.every(file => typeof file === 'string' && file.trim())) {
    throw new PeekrError(ErrorCodes.invalidArgument, 'Files must be nonempty filesystem paths; [] clears the input.');
  }
  const absolute = files.map(file => resolve(file));
  for (const file of absolute) {
    try {
      await access(file, constants.R_OK);
      if (!(await stat(file)).isFile()) throw Error('not a regular file');
    } catch { throw new PeekrError(ErrorCodes.invalidArgument, `File is missing or unreadable: ${file}`); }
  }
  const element = await resolveElement(target);
  await callElement(element, `${FORM_GUARD}
    if (this.tagName !== 'INPUT' || this.type !== 'file') throw Error('Expected a file input');
    if (this.webkitdirectory) throw Error('Directory inputs are not supported');
    if (!this.multiple && ${absolute.length} > 1) throw Error('Input does not allow multiple files');
  `);
  if (absolute.length) {
    await element.socket.send('DOM.setFileInputFiles', {objectId:element.objectId, files:absolute});
  } else {
    // CEF accepts an empty CDP file array without clearing the native input.
    await callElement(element, `
      this.value = '';
      const Event = this.ownerDocument.defaultView.Event;
      this.dispatchEvent(new Event('input', {bubbles:true}));
      this.dispatchEvent(new Event('change', {bubbles:true}));
    `);
  }
  if (await callElement<number>(element, 'return this.files.length;') !== absolute.length) {
    throw new PeekrError(ErrorCodes.actionFailed, 'File input did not retain the requested file count.');
  }
}
