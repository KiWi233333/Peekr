import { restorePageRefs, forgetPageRefs } from './page-refs.js';
import { ErrorCodes, PeekrError } from './errors.js';
import { acquireLease, runOperation } from './round.js';
import { state } from './state.js';
import { assertAgentMayOperate, controlRequest, completeSpace, handOffSpace, readSpace, selectSpace, useOrCreateSpace, claimSpace, takeOverSpace } from './driver/spaces.js';
import { closeTab, currentLedger, currentSocket, gotoAndWait, listTabs, openOrReuseTab, pageInfo, switchTab, waitForLoad } from './driver/nav.js';
import { snapshotRaw, snapshotText, screenshot, type SnapshotOptions } from './driver/observe.js';
import { click, doubleClick, hover, scrollBy, type ClickTarget } from './driver/pointer.js';
import { fillInput, pressKey, typeText, typeKeys } from './driver/keyboard.js';
import { navigateHistory } from './driver/history.js';
import { setChecked, selectOption, setInputFiles, type SelectOption } from './driver/forms.js';
import { js, cdp } from './driver/eval.js';

export class TaskSpace {
  constructor(readonly spaceId: string, readonly name: string, readonly ownership = 'agent') {}
  get id(): string { return this.spaceId; }
  page(label: string): Page {
    if (!label.trim()) throw new PeekrError(ErrorCodes.invalidArgument, 'A nonempty Page label is required.');
    return new Page(this.spaceId, label);
  }
  pages() { return runOperation(async () => { selectSpace(await readSpace(this.spaceId)); return listTabs(); }); }
  handOff() { return runOperation(async () => { selectSpace(await readSpace(this.spaceId)); await assertAgentMayOperate(); return handOffSpace(this.spaceId); }); }
  finish(options: { keep?: string[] | 'all' } = {}) { return runOperation(() => completeSpace(this.spaceId, { keep: options.keep === 'all' ? true : options.keep ?? [] })); }
}

export function taskSpace(nameOrId: string | number): Promise<TaskSpace> {
  return runOperation(async () => { const space = await useOrCreateSpace(nameOrId); return new TaskSpace(space.id, space.name, space.ownership); });
}

export function claimTaskSpace(id: string | number): Promise<TaskSpace> {
  return runOperation(async () => {
    const space = await claimSpace(id);
    return new TaskSpace(space.id, space.name, space.ownership);
  });
}

export function takeOverTaskSpace(id: string | number): Promise<TaskSpace> {
  return runOperation(async () => {
    const space = await takeOverSpace(id);
    return new TaskSpace(space.id, space.name, space.ownership);
  });
}

/** Handles address a space and label, never whichever tab happens to be selected. */
export class Page {
  constructor(readonly spaceId: string, readonly label: string) {}
  private run<T>(operation: (created: boolean) => Promise<T>, createURL?: string, timeout?: number): Promise<T> {
    return runOperation(async () => {
      selectSpace(await readSpace(this.spaceId));
      await assertAgentMayOperate();
      await listTabs();
      const entry = currentLedger().resolve(this.spaceId, this.label);
      let created = false;
      if (entry) {
        if (entry.status !== 'active' || entry.generation !== acquireLease()) throw new PeekrError(ErrorCodes.stalePage, `Page ${this.label} is stale or closed. Use a new label.`);
        await switchTab(entry.targetId);
      } else if (createURL) { await openOrReuseTab(createURL, { label: this.label, timeout }); created = true; }
      else throw new PeekrError(ErrorCodes.noActiveTab, `Page ${this.label} does not exist. Call goto(url) first.`);
      await restorePageRefs(await currentSocket());
      return operation(created);
    });
  }
  goto(url: string, options: { timeout?: number; settle?: number } = {}) { return this.run(async created => {
    if (!created) return gotoAndWait(url, options);
    if (options.settle) await new Promise(resolve => setTimeout(resolve, options.settle));
    return pageInfo();
  }, url, options.timeout); }
  info() { return this.run(pageInfo); }
  snapshot(options: SnapshotOptions = {}) { return this.run(() => snapshotText(options)); }
  snapshotRaw(options: SnapshotOptions = {}) { return this.run(() => snapshotRaw(options)); }
  screenshot(options: { path?: string; fullPage?: boolean } = {}) { return this.run(() => screenshot(options)); }
  click(target: ClickTarget) { return this.run(() => click(target)); }
  dblclick(target: ClickTarget) { return this.run(() => doubleClick(target)); }
  hover(target: ClickTarget) { return this.run(() => hover(target)); }
  fill(target: ClickTarget, text: string) { return this.run(() => fillInput(target, text)); }
  clear(target: string | number) { return this.fill(target, ''); }
  check(target: string | number) { return this.setChecked(target, true); }
  uncheck(target: string | number) { return this.setChecked(target, false); }
  setChecked(target: string | number, checked: boolean) { return this.run(() => setChecked(target, checked)); }
  selectOption(target: string | number, values: SelectOption | SelectOption[]) { return this.run(() => selectOption(target, values)); }
  setInputFiles(target: string | number, files: string | string[]) { return this.run(() => setInputFiles(target, files)); }
  close() { return this.run(() => closeTab()); }
  bringToFront() { return this.run(() => controlRequest('POST', `/spaces/${encodeURIComponent(this.spaceId)}/tabs/${encodeURIComponent(state.targetId!)}/activate`)); }
  evaluate<T = unknown>(expression: string | ((arg: any) => T), arg?: unknown): Promise<T> {
    const source = typeof expression === 'function' ? `(${expression.toString()})(${JSON.stringify(arg) ?? 'undefined'})` : expression;
    return this.run(() => js(source));
  }
  cdp(method: string, params: Record<string, unknown> = {}) { return this.run(() => cdp(method, params)); }
  goBack(options: { timeout?: number; settle?: number } = {}) { return this.run(() => navigateHistory(-1, options)); }
  goForward(options: { timeout?: number; settle?: number } = {}) { return this.run(() => navigateHistory(1, options)); }
  reload(options: { timeout?: number } = {}) {
    return this.run(async () => {
      const socket = await currentSocket();
      const previous = (await socket.send<any>('Page.getFrameTree')).frameTree.frame.loaderId;
      forgetPageRefs();
      await socket.send('Page.reload');
      let loader: string | undefined;
      const deadline = Date.now() + (options.timeout ?? 20_000);
      await this.poll(async () => {
        loader = (await socket.send<any>('Page.getFrameTree')).frameTree.frame.loaderId;
        return loader && loader !== previous;
      }, options.timeout ?? 20_000);
      await waitForLoad({timeout: Math.max(1, deadline - Date.now())}, loader);
      return pageInfo();
    });
  }
  stop() { return this.run(async () => { await (await currentSocket()).send('Page.stopLoading'); }); }
  waitForLoadState(loadState: 'load' | 'domcontentloaded' = 'load', options: { timeout?: number } = {}) {
    if (!['load', 'domcontentloaded'].includes(loadState)) throw new PeekrError(ErrorCodes.invalidArgument, 'Supported load states: load, domcontentloaded.');
    return this.waitForFunction(loadState === 'load' ? "document.readyState === 'complete'" : "document.readyState !== 'loading'", undefined, options);
  }
  waitForFunction(expression: string | ((arg: any) => unknown), arg?: unknown, options: { timeout?: number } = {}) {
    const source = typeof expression === 'function' ? `(${expression.toString()})(${JSON.stringify(arg) ?? 'undefined'})` : expression;
    return this.run(() => this.poll(() => js(source), options.timeout));
  }
  waitForURL(url: string, options: { timeout?: number } = {}) {
    return this.run(() => this.poll(async () => (await pageInfo()).url === url, options.timeout));
  }
  waitForSelector(selector: string, options: { state?: 'attached' | 'detached' | 'visible' | 'hidden'; timeout?: number } = {}) {
    const css = selector.replace(/^(loc=css:|css:|css=)/, '');
    const desired = options.state ?? 'visible';
    if (!['attached', 'detached', 'visible', 'hidden'].includes(desired)) throw new PeekrError(ErrorCodes.invalidArgument, 'Invalid selector state.');
    return this.run(() => this.poll(() => js(`(() => {
      const el = document.querySelector(${JSON.stringify(css)});
      const rect = el?.getBoundingClientRect();
      const visible = !!el && !!rect.width && !!rect.height && getComputedStyle(el).visibility !== 'hidden';
      return ${JSON.stringify(desired)} === 'attached' ? !!el : ${JSON.stringify(desired)} === 'detached' ? !el : ${JSON.stringify(desired)} === 'visible' ? visible : !visible;
    })()`), options.timeout));
  }
  private async poll(predicate: () => Promise<unknown>, timeout = 10_000): Promise<void> {
    if (!Number.isFinite(timeout) || timeout <= 0) throw new PeekrError(ErrorCodes.invalidArgument, 'timeout must be a positive millisecond value.');
    const deadline = Date.now() + timeout;
    while (true) {
      if (await predicate()) return;
      if (Date.now() >= deadline) throw new PeekrError(ErrorCodes.actionFailed, `Page condition timed out after ${timeout}ms.`);
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
  readonly keyboard = {
    press: (key: string, options: { delay?: number } = {}) => this.run(() => pressKey(key, options)),
    type: (text: string, options: { delay?: number } = {}) => this.run(() => typeKeys(text, options)),
    insertText: (text: string) => this.run(() => typeText(text)),
  };
  readonly mouse = {
    click: (x: number, y: number) => this.click([x, y]),
    wheel: (dx: number, dy: number) => this.run(() => scrollBy({ dx, dy })),
  };
}
