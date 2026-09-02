// Pointer driver: real input events through CDP's Input domain, so pages see
// the same trusted events a human produces (no synthetic .click() calls).

import { state } from "../state.js";
import { resolveTarget, type ResolvedElement } from "./locator.js";
import { currentSocket, pageInfo } from "./nav.js";

export interface ClickOptions {
  /** 3-6 word action description; reserved for visual highlight marks. */
  label?: string;
}

export type ClickTarget = string | number | [number, number] | { x: number; y: number };

async function dispatchMouse(type: string, point: ResolvedElement, extra: Record<string, unknown> = {}): Promise<void> {
  await point.socket.send(
    "Input.dispatchMouseEvent",
    { type, x: point.x, y: point.y, button: type === "mouseWheel" ? undefined : "left", ...extra },
  );
}

export async function click(target: ClickTarget, options: ClickOptions = {}): Promise<void> {
  void options.label;
  const point = await resolveTarget(target);
  await dispatchMouse("mousePressed", point, { clickCount: 1, buttons: 1 });
  await dispatchMouse("mouseReleased", point, { clickCount: 1 });
}

export async function doubleClick(target: ClickTarget, options: ClickOptions = {}): Promise<void> {
  void options.label;
  const point = await resolveTarget(target);
  await dispatchMouse("mousePressed", point, { clickCount: 1, buttons: 1 });
  await dispatchMouse("mouseReleased", point, { clickCount: 1 });
  await dispatchMouse("mousePressed", point, { clickCount: 2, buttons: 1 });
  await dispatchMouse("mouseReleased", point, { clickCount: 2 });
}

export async function hover(target: ClickTarget): Promise<void> {
  const point = await resolveTarget(target);
  await dispatchMouse("mouseMoved", point);
}

export interface ScrollOptions {
  dy?: number;
  dx?: number;
}

/** Real wheel event at the given target, or the viewport center. */
export async function scrollBy(amount: number | ScrollOptions, target?: ClickTarget): Promise<void> {
  const options = typeof amount === "number" ? { dy: amount } : amount;
  let point: ResolvedElement;
  if (target !== undefined) {
    point = await resolveTarget(target);
  } else {
    await currentSocket();
    const geometry = await pageInfo();
    point = { socket: state.sockets.get(state.targetId!)!, x: geometry.w / 2, y: geometry.h / 2 };
  }
  await point.socket.send(
    "Input.dispatchMouseEvent",
    {
      type: "mouseWheel",
      x: point.x,
      y: point.y,
      deltaX: options.dx ?? 0,
      deltaY: options.dy ?? 0,
    },
  );
}
