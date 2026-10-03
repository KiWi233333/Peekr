// Frame content support. CEF 148 exposes no OOPIF targets over CDP (neither
// /json/list nor flattened auto-attach — verified), so same-origin iframe
// content is collected with an injected walker through `contentDocument`,
// while cross-origin frames degrade to an explicit placeholder line.
//
// Frame identity: each iframe gets a per-run `data-peekr-frame` attribute;
// nested frames are addressed by the chain of those ids from the main
// document down. Elements inside a frame are addressed by a positional or
// attribute CSS selector inside that frame's document.

import type { TargetSocket } from "../cdp.js";
import { ErrorCodes, PeekrError } from "../errors.js";

export interface FrameInfo {
  /** Chain of data-peekr-frame ids, main document first. */
  chain: number[];
  src: string;
  accessible: boolean;
  depth: number;
}

export interface FrameElement {
  role: string;
  name: string;
  value?: string;
  href?: string;
  selector: string;
  epoch: string;
}

/**
 * Compact ARIA role/name computation shared by the frame walker and the
 * role: locator resolver — CEF 148 lacks Element.computedRole.
 */
export const ARIA_HELPERS_JS = `
  const roleOf = (el) => {
    const explicit = el.getAttribute("role");
    if (explicit) return explicit;
    const tag = el.tagName.toLowerCase();
    if (tag === "a" && el.hasAttribute("href")) return "link";
    if (tag === "button" || (tag === "input" && ["button", "submit", "reset"].includes(el.type))) return "button";
    if (tag === "input" || tag === "textarea") {
      const t = (el.getAttribute("type") || "text").toLowerCase();
      if (t === "checkbox") return "checkbox";
      if (t === "radio") return "radio";
      if (t === "range") return "slider";
      return "textbox";
    }
    if (tag === "select") return "combobox";
    if (tag === "img") return "image";
    if (el.isContentEditable) return "textbox";
    return "generic";
  };
  const nameOf = (el, role) => {
    const labelledBy = (el.getAttribute("aria-labelledby") || "").split(/\\s+/).filter(Boolean)
      .map(id => el.ownerDocument.getElementById(id)?.textContent || "").join(" ").trim();
    const label = labelledBy || el.getAttribute("aria-label") ||
      Array.from(el.labels || []).map(label => label.textContent || "").join(" ").trim() || el.getAttribute("placeholder") || "";
    if (label) return label.trim();
    if (role === "image") return (el.getAttribute("alt") || "").trim();
    if (role === "button" || role === "link") {
      const text = (el.textContent || "").trim().slice(0, 200);
      if (text) return text;
      return (el.value || "").trim();
    }
    if (role === "textbox" || role === "searchbox") return (el.value || "").trim();
    return "";
  };
`;

const COLLECT_FRAMES_JS = `(() => {
  const infos = [];
  let counter = 0;
  const walk = (doc, chain, depth) => {
    for (const el of doc.querySelectorAll("iframe,frame")) {
      counter += 1;
      const id = counter;
      el.setAttribute("data-peekr-frame", String(id));
      let accessible = false;
      try { accessible = !!(el.contentDocument && el.contentDocument.body); } catch {}
      const childChain = [...chain, id];
      infos.push({
        chain: childChain,
        src: el.getAttribute("src") || "about:blank",
        accessible,
        depth,
      });
      if (accessible) walk(el.contentDocument, childChain, depth + 1);
    }
  };
  walk(document, [], 0);
  return infos;
})()`;

const FRAME_WALKER_BODY = `{
  let doc = document;
  for (const id of chainIds) {
    const frame = doc.querySelector('iframe[data-peekr-frame="' + id + '"],frame[data-peekr-frame="' + id + '"]');
    if (!frame) return { error: "frame " + id + " gone" };
    doc = frame.contentDocument;
    if (!doc) return { error: "frame " + id + " cross-origin" };
  }
  ${ARIA_HELPERS_JS}
  const selectorFor = (doc, el) => {
    if (el.id) return "#" + el.id.replace(/([^a-zA-Z0-9_-])/g, "\\\\$1");
    const testAttribute = el.hasAttribute("data-testid") ? "data-testid" : "data-test";
    const test = el.getAttribute(testAttribute);
    if (test) return '[' + testAttribute + '="' + test.replace(/"/g, '\\\\"') + '"]';
    const name = el.getAttribute("name");
    if (name) return el.tagName.toLowerCase() + '[name="' + name.replace(/"/g, '\\\\"') + '"]';
    let path = "";
    let node = el;
    while (node && node !== doc.body && node.nodeType === 1) {
      let index = 1;
      let sibling = node;
      while ((sibling = sibling.previousElementSibling)) if (sibling.tagName === node.tagName) index += 1;
      path = node.tagName.toLowerCase() + ":nth-of-type(" + index + ")" + (path ? " > " + path : "");
      node = node.parentElement;
    }
    return "body > " + path;
  };
  const out = [];
  for (const el of doc.querySelectorAll("a[href], button, input, textarea, select, [contenteditable=true], [role=button], [role=link], [role=checkbox], [role=radio], [role=textbox], [role=searchbox], [role=combobox]")) {
    const role = roleOf(el);
    if (role === "generic") continue;
    const name = nameOf(el, role);
    out.push({
      role,
      name,
      value: ["textbox", "searchbox", "combobox"].includes(role) ? (el.value || "") : undefined,
      href: role === "link" ? el.href : undefined,
      selector: selectorFor(doc, el),
      epoch: JSON.stringify([doc.location.href, doc.defaultView.performance.timeOrigin]),
    });
  }
  return { elements: out };
}`;

/** Enumerate iframes (depth-first) and tag them for later resolution. */
export async function collectFrameInfos(socket: TargetSocket): Promise<FrameInfo[]> {
  const result = await socket.try<any>("Runtime.evaluate", {
    expression: COLLECT_FRAMES_JS,
    returnByValue: true,
  });
  return result?.result?.value ?? [];
}

/** Interactive elements inside one (same-origin) frame. */
export async function walkFrameElements(
  socket: TargetSocket,
  chain: number[],
): Promise<FrameElement[]> {
  // CEF's callFunctionOn mangles `args` arrays, so the chain is interpolated
  // into the function source instead of passed as an argument.
  const result = await socket.send<any>("Runtime.callFunctionOn", {
    objectId: (await mainWindowObjectId(socket)),
    functionDeclaration: `function () {
  const chainIds = ${JSON.stringify(chain)};
  ${FRAME_WALKER_BODY}
}`,
    returnByValue: true,
  });
  const value = result?.result?.value;
  if (!value || value.error) return [];
  return value.elements as FrameElement[];
}

async function mainWindowObjectId(socket: TargetSocket): Promise<string> {
  const result = await socket.send<any>("Runtime.evaluate", {
    expression: "window",
    returnByValue: false,
  });
  const objectId = result?.result?.objectId;
  if (!objectId) {
    throw new PeekrError(ErrorCodes.cdpUnavailable, "Could not obtain the page execution context.");
  }
  return objectId;
}
