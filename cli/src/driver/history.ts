import { ErrorCodes, PeekrError } from '../errors.js';
import { forgetPageRefs } from '../page-refs.js';
import { currentSocket, pageInfo, waitForLoad, type WaitOptions } from './nav.js';

interface History { currentIndex: number; entries: Array<{ id: number; url: string }> }

/** History entry identity covers both document navigation and pushState/hash changes. */
export async function navigateHistory(delta: -1 | 1, options: WaitOptions = {}) {
  const timeout = options.timeout ?? 20_000;
  if (!Number.isFinite(timeout) || timeout <= 0) throw new PeekrError(ErrorCodes.invalidArgument, 'timeout must be positive milliseconds.');
  const socket = await currentSocket();
  const before = await socket.send<History>('Page.getNavigationHistory');
  const entry = before.entries[before.currentIndex + delta];
  if (!entry || !/^https?:/.test(entry.url)) return null;
  forgetPageRefs();
  const deadline = Date.now() + timeout;
  await socket.send('Page.navigateToHistoryEntry', {entryId:entry.id});
  for (;;) {
    const history = await socket.send<History>('Page.getNavigationHistory');
    if (history.entries[history.currentIndex]?.id === entry.id) break;
    if (Date.now() >= deadline) throw new PeekrError(ErrorCodes.actionFailed, 'History navigation timed out.');
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  await waitForLoad({timeout: Math.max(1, deadline-Date.now()), settle:options.settle});
  return pageInfo();
}
