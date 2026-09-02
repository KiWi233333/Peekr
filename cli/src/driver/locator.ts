// Element resolution: turns the shared target surface — `@N` refs, raw CSS,
// `xpath=…`, `loc=…` values (`css:…`, `role:<role>[name=<name>]`, `href:…`),
// and viewport coordinates — into an objectId and a viewport-space center.

import type { TargetSocket } from "../cdp.js";
import { ErrorCodes, PeekrError } from "../errors.js";
import { isRefToken, resolveRef } from "../ref-map.js";
import { state } from "../state.js";
import { currentSocket, socketFor } from "./nav.js";
import { ARIA_HELPERS_JS, resolveFramePoint } from "./frames.js";

export interface ResolvedElement {
  socket: TargetSocket;
  objectId?: string;
  x: number;
  y: number;
  /** Present when the element lives inside a same-origin iframe. */
  frame?: { chain: number[]; selector: string };
}

interface RectPoint {
  x: number;
  y: number;
}

/** Center of an element's border box, in viewport CSS pixels. */
async function centerOf(socket: TargetSocket, objectId: string): Promise<RectPoint> {
  const result = await socket.send<any>(
    "Runtime.callFunctionOn",
    {
      objectId,
      functionDeclaration: `function () {
        const rect = this.getBoundingClientRect();
        return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
      }`,
      returnByValue: true,
    },
  );
  const point = result?.result?.value;
  if (typeof point?.x !== "number" || typeof point?.y !== "number") {
    throw new PeekrError(ErrorCodes.actionFailed, "Element has no usable geometry.");
  }
  return point;
}

async function objectIdFromBackendNode(socket: TargetSocket, backendDOMNodeId: number): Promise<string> {
  const resolved = await socket.send<any>("DOM.resolveNode", { backendNodeId: backendDOMNodeId });
  if (!resolved?.object?.objectId) {
    throw new PeekrError(ErrorCodes.actionFailed, "Element no longer exists in the DOM.");
  }
  return resolved.object.objectId;
}

/** Find the first element whose computed role (and optionally name) matches. */
async function findByRole(socket: TargetSocket, role: string, name?: string): Promise<string> {
  const nameLiteral = name === undefined ? "null" : JSON.stringify(name);
  const result = await socket.send<any>(
    "Runtime.evaluate",
    {
      expression: `(() => {
        const wantedRole = ${JSON.stringify(role)};
        const wantedName = ${nameLiteral};
        ${ARIA_HELPERS_JS}
        const roots = [];
        const collect = (doc) => {
          roots.push(doc);
          for (const el of doc.querySelectorAll("*")) {
            if (el.shadowRoot) roots.push(el.shadowRoot);
          }
          for (const frame of doc.querySelectorAll("iframe,frame")) {
            try { if (frame.contentDocument && frame.contentDocument.body) collect(frame.contentDocument); } catch {}
          }
        };
        collect(document);
        for (const root of roots) {
          for (const el of root.querySelectorAll("a[href], button, input, textarea, select, [contenteditable=true], [role], img")) {
            const roleValue = roleOf(el);
            if (roleValue !== wantedRole) continue;
            if (wantedName !== null && nameOf(el, roleValue) !== wantedName) continue;
            return el;
          }
        }
        return null;
      })()`,
      returnByValue: false,
    },
  );
  const objectId = result?.result?.objectId;
  if (!objectId) {
    throw new PeekrError(
      ErrorCodes.actionFailed,
      `No element with role ${role}${name ? ` and name ${JSON.stringify(name)}` : ""}.`,
    );
  }
  return objectId;
}

async function findByHref(socket: TargetSocket, href: string): Promise<string> {
  const result = await socket.send<any>(
    "Runtime.evaluate",
    {
      expression: `(() => {
        const wanted = ${JSON.stringify(href)};
        for (const a of document.querySelectorAll("a[href]")) {
          if (a.href === wanted || a.getAttribute("href") === wanted) return a;
        }
        return null;
      })()`,
      returnByValue: false,
    },
  );
  const objectId = result?.result?.objectId;
  if (!objectId) throw new PeekrError(ErrorCodes.actionFailed, `No link with href ${href}.`);
  return objectId;
}

async function findBySelector(socket: TargetSocket, selector: string): Promise<string> {
  if (selector.startsWith("xpath=")) {
    const expression = selector.slice("xpath=".length);
    const result = await socket.send<any>(
      "Runtime.evaluate",
      {
        expression: `(() => {
          const result = document.evaluate(${JSON.stringify(expression)}, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
          return result.singleNodeValue;
        })()`,
        returnByValue: false,
      },
    );
    const objectId = result?.result?.objectId;
    if (!objectId) throw new PeekrError(ErrorCodes.actionFailed, `xpath matched nothing: ${selector}`);
    return objectId;
  }

  const css = selector.startsWith("css:") ? selector.slice(4) : selector;
  const result = await socket.send<any>(
    "Runtime.evaluate",
    {
      expression: `(() => {
        const sel = ${JSON.stringify(css)};
        const direct = document.querySelector(sel);
        if (direct) return direct;
        const roots = ${ALL_ROOTS_JS};
        for (const root of roots) {
          const hit = root.querySelector(sel);
          if (hit) return hit;
        }
        return null;
      })()`,
      returnByValue: false,
    },
  );
  const objectId = result?.result?.objectId;
  if (!objectId) throw new PeekrError(ErrorCodes.actionFailed, `No element matches ${selector}.`);
  return objectId;
}

/** JS snippet: every search root — the document plus open shadow roots. */
const ALL_ROOTS_JS = `(() => {
  const roots = [document];
  for (let i = 0; i < roots.length; i++) {
    for (const el of roots[i].querySelectorAll("*")) {
      if (el.shadowRoot) roots.push(el.shadowRoot);
    }
  }
  return roots;
})()`;

/** JS snippet: search roots plus every accessible iframe document (recursive). */
const ALL_ROOTS_WITH_FRAMES_JS = `(() => {
  const roots = [document];
  const collect = (doc) => {
    for (const el of doc.querySelectorAll("*")) {
      if (el.shadowRoot) roots.push(el.shadowRoot);
    }
    for (const frame of doc.querySelectorAll("iframe,frame")) {
      try { if (frame.contentDocument && frame.contentDocument.body) collect(frame.contentDocument); } catch {}
    }
  };
  collect(document);
  return roots;
})();`;

async function objectIdToCenter(socket: TargetSocket, objectId: string): Promise<ResolvedElement> {
  const point = await centerOf(socket, objectId);
  return { socket, objectId, ...point };
}

/**
 * Resolve any accepted target to viewport coordinates (plus objectId when the
 * target came from the DOM). Coordinate targets pass straight through; refs
 * resolve inside the frame target recorded by the snapshot.
 */
export async function resolveTarget(
  target: string | number | [number, number] | { x: number; y: number },
): Promise<ResolvedElement> {
  if (Array.isArray(target) || (typeof target === "object" && target !== null)) {
    const point = Array.isArray(target) ? { x: target[0], y: target[1] } : target;
    const socket = await currentSocket();
    return { socket, x: point.x, y: point.y };
  }

  if (isRefToken(target)) {
    const info = resolveRef(target);
    const socket = info.frameTargetId
      ? await socketFor(info.frameTargetId)
      : await currentSocket();
    if (info.frame) {
      const point = await resolveFramePoint(socket, info.frame.chain, info.frame.selector);
      return { socket, ...point, frame: info.frame };
    }
    if (info.backendDOMNodeId) {
      const objectId = await objectIdFromBackendNode(socket, info.backendDOMNodeId);
      const point = await centerOf(socket, objectId);
      return { socket, objectId, ...point };
    }
    if (info.locator?.startsWith("role:")) {
      const match = /^role:([^[]+)(?:\[name=(.+)\])?$/.exec(info.locator);
      if (match) {
        const objectId = await findByRole(socket, match[1], match[2] ? tryDecode(match[2]) : undefined);
        const point = await centerOf(socket, objectId);
        return { socket, objectId, ...point };
      }
    }
    throw new PeekrError(
      ErrorCodes.actionFailed,
      `Ref ${target} carries no DOM node; take a fresh snapshot.`,
    );
  }

  const socket = await currentSocket();
  const selector = String(target).trim();
  const roleMatch = /^role:([^[]+)(?:\[name=(.+)\])?$/.exec(selector);
  if (roleMatch) {
    const name = roleMatch[2] ? tryDecode(roleMatch[2]) : undefined;
    return objectIdToCenter(socket, await findByRole(socket, roleMatch[1], name));
  }
  if (selector.startsWith("href:")) {
    return objectIdToCenter(socket, await findByHref(socket, selector.slice(5)));
  }
  return objectIdToCenter(socket, await findBySelector(socket, selector));
}

function tryDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}
