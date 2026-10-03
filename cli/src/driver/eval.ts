import { forgetPageRefs } from '../page-refs.js';
// Direct evaluation surfaces: page JS (`js`) and raw CDP passthrough (`cdp`).
// `js` is Runtime.evaluate — pass a string; wrap multi-step logic in one IIFE.

import { ErrorCodes, PeekrError } from '../errors.js';
import { currentSocket } from "./nav.js";

/** Evaluate an expression in the current page; objects return as plain values. */
export async function js(expression: string): Promise<any> {
  const socket = await currentSocket();
  const result = await socket.send<any>(
    "Runtime.evaluate",
    {
      expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: true,
    },
  );
  if (result?.exceptionDetails) {
    const description = result.exceptionDetails?.exception?.description
      ?? result.exceptionDetails?.text
      ?? "evaluation failed";
    throw new Error(`js() failed: ${description}`);
  }
  return result?.result?.value;
}

/** Raw CDP passthrough for anything the helpers do not cover. */
export async function cdp(method: string, params: Record<string, unknown> = {}): Promise<any> {
  if (!/^(Page|Runtime|DOM|DOMSnapshot|Accessibility|Input|Network|CSS)\.[A-Za-z]+$/.test(method)
      || ['Page.close', 'Page.crash', 'Page.setDownloadBehavior'].includes(method)
      || 'sessionId' in params || 'targetId' in params) {
    throw new PeekrError(ErrorCodes.invalidArgument, 'Raw CDP is page-scoped; use managed tab helpers for lifecycle operations.');
  }
  const socket = await currentSocket();
  forgetPageRefs();
  return socket.send(method, params);
}
