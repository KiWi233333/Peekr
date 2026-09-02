// Keyboard driver: key chord dispatch and text entry through the Input
// pipeline (IME-safe), plus fillInput which focuses and selects first so the
// new text replaces the old across React/Vue controlled inputs.

import { state } from "../state.js";
import { resolveTarget } from "./locator.js";
import type { ClickTarget } from "./pointer.js";
import { currentSocket } from "./nav.js";

const VIRTUAL_KEYS: Record<string, number> = {
  Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, Space: 32,
  ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40,
  Home: 36, End: 35, PageUp: 33, PageDown: 34,
};

export async function pressKey(key: string): Promise<void> {
  const socket = await currentSocket();
  const virtualKeyCode = VIRTUAL_KEYS[key] ?? 0;
  const base = {
    key,
    windowsVirtualKeyCode: virtualKeyCode,
    nativeVirtualKeyCode: virtualKeyCode,
  };
  const isPrintable = virtualKeyCode === 0 && key.length === 1;
  await socket.send("Input.dispatchKeyEvent", { type: isPrintable ? "keyDown" : "rawKeyDown", ...base });
  if (isPrintable) {
    await socket.send("Input.dispatchKeyEvent", { type: "char", ...base, text: key });
  }
  await socket.send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
}

export async function typeText(text: string): Promise<void> {
  const socket = await currentSocket();
  await socket.send("Input.insertText", { text });
}

/** Focus the element, select its content, then insert text as real input. */
export async function fillInput(target: ClickTarget, text: string): Promise<void> {
  const resolved = await resolveTarget(target);
  if (!resolved.objectId) {
    throw Object.assign(new Error("fillInput needs an element target, not bare coordinates"), { code: "PEEKR_ACTION_FAILED" });
  }
  await resolved.socket.send(
    "Runtime.callFunctionOn",
    {
      objectId: resolved.objectId,
      functionDeclaration: `function () {
        this.focus();
        if (typeof this.select === "function" && (this.tagName === "INPUT" || this.tagName === "TEXTAREA")) {
          this.select();
        } else if (this.isContentEditable) {
          const range = document.createRange();
          range.selectNodeContents(this);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        }
      }`,
      returnByValue: true,
    },
  );
  await resolved.socket.send("Input.insertText", { text });
}
