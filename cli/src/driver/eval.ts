// Direct evaluation surfaces: page JS (`js`) and raw CDP passthrough (`cdp`).
// `js` is Runtime.evaluate — pass a string; wrap multi-step logic in one IIFE.

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
  const socket = await currentSocket();
  return socket.send(method, params);
}
