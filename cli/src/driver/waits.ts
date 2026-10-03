// Wait helpers: fixed sleeps (seconds, like ego), full-load waits, and
// polling waits for elements or arbitrary JS conditions.

import { ErrorCodes, PeekrError } from "../errors.js";
import { currentSocket } from "./nav.js";

export async function wait(seconds: number): Promise<void> {
  await new Promise((resolvePromise) => setTimeout(resolvePromise, seconds * 1_000));
}

export { waitForLoad } from "./nav.js";

/** Poll `document.querySelector(selector)` until it exists. */
export async function waitForElement(selector: string, timeoutSeconds = 10): Promise<void> {
  const socket = await currentSocket();
  const deadline = Date.now() + timeoutSeconds * 1_000;
  for (;;) {
    const result = await socket
      .send<any>(
        "Runtime.evaluate",
        { expression: `!!document.querySelector(${JSON.stringify(selector)})`, returnByValue: true },
      );
    if (result?.result?.value === true) return;
    if (Date.now() > deadline) {
      throw new PeekrError(ErrorCodes.actionFailed, `waitForElement timed out for ${selector}.`);
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 150));
  }
}
