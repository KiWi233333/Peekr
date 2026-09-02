// The snapshot engine. ego-lite generates this inside its customized Chromium
// kernel; Peekr cannot modify the CEF kernel, so the same output is produced
// at the harness layer: CDP Accessibility.getFullAXTree per frame, joined with
// DOMSnapshot.captureSnapshot for stable-locator attributes and geometry, and
// cross-origin (OOPIF) frames merged from their own targets.

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { ErrorCodes, PeekrError } from "../errors.js";
import { refToken, resolveRef } from "../ref-map.js";
import { resetRefs, state, type RefInfo } from "../state.js";
import { currentSocket, ensureCurrentPage, pageInfo } from "./nav.js";
import { collectFrameInfos, walkFrameElements } from "./frames.js";
import type { TargetSocket } from "../cdp.js";

export interface SnapshotOptions {
  scope?: "only_within_viewport" | "full_page";
  includeActionMarks?: boolean;
  includeStableLocator?: boolean;
}

export interface SnapshotResult {
  content: string;
  refs: RefInfo[];
}

interface AxNode {
  nodeId: string;
  backendDOMNodeId?: number;
  ignored?: boolean;
  role?: { type: string; value?: string };
  name?: { value?: string };
  value?: { value?: string };
  properties?: Array<{ name: string; value: { type: string; value: any } }>;
  childIds?: string[];
}

/** Roles that always get an @N ref (clickable / fillable / selectable). */
const INTERACTIVE_ROLES = new Set([
  "link", "button", "textbox", "searchbox", "combobox", "listbox", "option",
  "checkbox", "radio", "slider", "spinbutton", "switch", "menuitem",
  "menuitemcheckbox", "menuitemradio", "tab", "treeitem",
]);

/** Containers only worth a line when they carry an accessible name. */
const NAMED_STRUCTURE_ROLES = new Set([
  "group", "list", "table", "region", "navigation", "main", "complementary",
  "banner", "contentinfo", "form", "dialog", "alertdialog", "tablist",
  "tree", "toolbar", "menu", "menubar", "status", "timer", "log", "marquee",
]);

/** Transparent roles: never emitted, but their children keep flowing. */
const TRANSPARENT_ROLES = new Set(["none", "presentation", "inlinetextbox"]);

function normRole(node: AxNode): string {
  return (node.role?.value ?? "generic").toLowerCase();
}

const MAX_LINES = 1_000;
const MAX_TEXT_LENGTH = 300;

interface FrameContext {
  socket: TargetSocket;
  /** backendNodeId → attributes (name/value pairs) from DOMSnapshot. */
  attributes: Map<number, string[]>;
  /** backendNodeId → [x, y, width, height] layout bounds (CSS px). */
  bounds: Map<number, [number, number, number, number]>;
  viewport?: { sx: number; sy: number; w: number; h: number };
}

export async function snapshotRaw(options: SnapshotOptions = {}): Promise<SnapshotResult> {
  const includeStableLocator = options.includeStableLocator ?? true;
  const scope = options.scope ?? "full_page";

  const targetId = await ensureCurrentPage();
  const socket = state.sockets.get(targetId)!;

  await socket.try("Accessibility.enable");
  const tree = await socket.send<{ nodes: AxNode[] }>("Accessibility.getFullAXTree");

  const mainFrame = await describeFrame(socket, scope);
  const renderer = new SnapshotRenderer({ includeStableLocator, scope });
  const info = await pageInfo().catch(() => undefined);
  renderer.render(tree.nodes, mainFrame, "");

  // Iframe content: CEF exposes no OOPIF targets and folds no child-frame
  // content into the page AX tree, so same-origin frames are walked with an
  // injected contentDocument walker, and cross-origin frames degrade to an
  // explicit placeholder. One broken embed never kills the snapshot.
  const frames = await collectFrameInfos(socket).catch(() => []);
  for (const frame of frames) {
    const indent = "  ".repeat(frame.depth);
    if (!frame.accessible) {
      renderer.lines.push(
        `${indent}[iframe src=${frame.src}] [iframe: cross-origin — content unavailable]`,
      );
      continue;
    }
    renderer.lines.push(`${indent}[iframe src=${frame.src}]`);
    try {
      const elements = await walkFrameElements(socket, frame.chain);
      for (const element of elements) {
        const ref = renderer.nextRefFor(element.role, element.name, frame.chain, element.selector);
        const parts = [
          `${indent}  ${refToken(ref)} [${element.role}]`,
          element.name ? JSON.stringify(element.name.slice(0, MAX_TEXT_LENGTH)) : undefined,
          element.selector ? `loc=css:${element.selector}` : undefined,
          element.href ? `url=${element.href}` : undefined,
          element.value ? `value=${JSON.stringify(element.value)}` : undefined,
        ];
        renderer.lines.push(parts.filter(Boolean).join(" "));
      }
    } catch (err) {
      renderer.lines.push(`${indent}  [iframe: unavailable — ${(err as Error).message}]`);
    }
  }

  const header = [
    `Page: ${info?.title ?? ""}`.trimEnd(),
    `URL: ${info?.url ?? ""}`.trimEnd(),
  ];
  const content = [...header, ...renderer.finish(), ""].join("\n");
  resetRefs(renderer.refs);
  return { content, refs: renderer.refs };
}

/** ego-compatible text surface: content only. */
export async function snapshotText(options: SnapshotOptions = {}): Promise<string> {
  const result = await snapshotRaw(options);
  return result.content;
}

let screenshotSeq = 0;

/**
 * PNG capture of the current page. Defaults to the viewport; `fullPage`
 * captures beyond the fold. Writes to a pid+sequence-named tmp file unless
 * `path` is given, so parallel agents never overwrite each other.
 */
export async function screenshot(options: { path?: string; fullPage?: boolean } = {}): Promise<string> {
  const socket = await currentSocket();
  const result = await socket.send<any>(
    "Page.captureScreenshot",
    { format: "png", captureBeyondViewport: options.fullPage ?? false },
  );
  if (!result?.data) {
    throw new PeekrError(ErrorCodes.actionFailed, "Page.captureScreenshot returned no data.");
  }
  const path = options.path
    ?? join(tmpdir(), `peekr-shot-${process.pid}-${++screenshotSeq}.png`);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, Buffer.from(result.data, "base64"));
  return path;
}

async function describeFrame(socket: TargetSocket, scope: string): Promise<FrameContext> {
  const attributes = new Map<number, string[]>();
  const bounds = new Map<number, [number, number, number, number]>();
  const snap = await socket.try<any>(
    "DOMSnapshot.captureSnapshot",
    { computedStyles: [], includePaintOrder: false, includeDOMRects: true },
  );
  const doc = snap?.documents?.[0];
  if (doc) {
    const nodeAttrs: string[] = doc.nodes?.attributes ?? [];
    const nodeBackends: number[] = doc.nodes?.backendNodeId ?? [];
    const nodeIndex: number[] = doc.layout?.nodeIndex ?? [];
    const rawBounds: number[] = doc.layout?.bounds ?? [];
    for (let nodeArrayIndex = 0; nodeArrayIndex < nodeBackends.length; nodeArrayIndex++) {
      const backend = nodeBackends[nodeArrayIndex];
      attributes.set(backend, nodeAttrs.slice(nodeArrayIndex * 2, nodeArrayIndex * 2 + 2));
    }
    for (let layoutIndex = 0; layoutIndex < nodeIndex.length; layoutIndex++) {
      const backend = nodeBackends[nodeIndex[layoutIndex]];
      if (backend === undefined) continue;
      const base = layoutIndex * 4;
      if (base + 3 >= rawBounds.length) break;
      bounds.set(backend, [rawBounds[base], rawBounds[base + 1], rawBounds[base + 2], rawBounds[base + 3]]);
    }
  }
  const context: FrameContext = { socket, attributes, bounds };
  if (scope === "only_within_viewport") {
    try {
      const geometry = await pageInfo();
      context.viewport = { sx: geometry.sx, sy: geometry.sy, w: geometry.w, h: geometry.h };
    } catch {
      // No viewport info → treat everything as in-viewport.
    }
  }
  return context;
}

export class SnapshotRenderer {
  lines: string[] = [];
  refs: RefInfo[] = [];
  private nextRef = 1;
  private truncated = 0;

  constructor(
    private readonly options: { includeStableLocator: boolean; scope: string },
  ) {}

  /** Test + debug hook: the internal pending line count. */
  get lineCount(): number {
    return this.lines.length;
  }

  /** Register a frame-walked element as a ref and return its number. */
  nextRefFor(role: string, name: string, chain: number[], selector: string): number {
    const ref = this.nextRef++;
    this.refs.push({
      ref,
      role,
      name,
      locator: selector ? `css:${selector}` : undefined,
      frame: { chain, selector },
    });
    return ref;
  }

  render(nodes: AxNode[], frame: FrameContext, baseIndent: string): void {
    const byId = new Map(nodes.map((node) => [node.nodeId, node]));
    const claimed = new Set<string>();
    for (const node of nodes) for (const child of node.childIds ?? []) claimed.add(child);
    const roots = nodes.filter((node) => !claimed.has(node.nodeId));
    if (roots.length === 0) return;
    // The usual root is the frame's RootWebArea, often wrapped in a `none`
    // node — the header block already reports the page, so unwrap both and
    // walk straight into the visible children.
    for (const root of roots) {
      const rootRole = normRole(root);
      if (rootRole === "rootwebarea" || TRANSPARENT_ROLES.has(rootRole)) {
        for (const childId of root.childIds ?? []) {
          const child = byId.get(childId);
          if (child) this.walk(child, byId, frame, 0, baseIndent, undefined);
        }
      } else {
        this.walk(root, byId, frame, 0, baseIndent, undefined);
      }
    }
  }

  finish(): string[] {
    const lines = this.lines.slice(0, MAX_LINES);
    if (this.truncated > 0) {
      lines.push(`… (truncated ${this.truncated} more nodes; scope the snapshot or narrow the page)`);
    }
    return lines;
  }

  private walk(
    node: AxNode,
    byId: Map<string, AxNode>,
    frame: FrameContext,
    depth: number,
    baseIndent: string,
    parentName: string | undefined,
  ): void {
    if (this.lines.length >= MAX_LINES) {
      this.truncated++;
      return;
    }
    const role = normRole(node);
    // Ignored nodes and presentational wrappers stay transparent: their
    // children carry the real content (the root container of a page is
    // typically an ignored `none` wrapper).
    if (node.ignored || TRANSPARENT_ROLES.has(role)) {
      for (const childId of node.childIds ?? []) {
        const child = byId.get(childId);
        if (child) this.walk(child, byId, frame, depth, baseIndent, parentName);
      }
      return;
    }
    if (this.options.scope === "only_within_viewport" && !inViewport(node, frame)) return;

    const name = (node.name?.value ?? "").trim();
    const indent = baseIndent + "  ".repeat(depth);
    const interactive = INTERACTIVE_ROLES.has(role)
      || (role === "generic" && this.prop(node, "clickable") === true);

    if (role === "statictext") {
      const text = name.slice(0, MAX_TEXT_LENGTH);
      if (text && text !== parentName) this.lines.push(`${indent}${text}`);
      return;
    }

    if (interactive) {
      const ref = this.nextRef++;
      const locator = this.options.includeStableLocator
        ? buildLocator(node, frame)
        : undefined;
      const href = role === "link" ? (this.prop(node, "url") as string | undefined) : undefined;
      this.refs.push({
        ref,
        backendDOMNodeId: node.backendDOMNodeId,
        locator,
        role,
        name,
        frameTargetId: frame.socket === state.sockets.get(state.targetId ?? "") ? undefined : state.targetId ?? undefined,
        href,
      });
      const parts = [
        `${indent}${refToken(ref)} [${role}]`,
        name ? JSON.stringify(name.slice(0, MAX_TEXT_LENGTH)) : undefined,
        locator ? `loc=${locator}` : undefined,
        href ? `url=${href}` : undefined,
      ];
      const value = node.value?.value;
      if (typeof value === "string" && value) parts.push(`value=${JSON.stringify(value)}`);
      if (this.prop(node, "disabled") === true) parts.push("[disabled]");
      if (this.prop(node, "checked") === true) parts.push("[checked]");
      this.lines.push(parts.filter(Boolean).join(" "));
      for (const childId of node.childIds ?? []) {
        const child = byId.get(childId);
        if (child) this.walk(child, byId, frame, depth + 1, baseIndent, name || parentName);
      }
      return;
    }

    if (role === "heading") {
      if (name) this.lines.push(`${indent}[heading] ${JSON.stringify(name)}`);
    } else if (NAMED_STRUCTURE_ROLES.has(role) && name) {
      this.lines.push(`${indent}[${role}] ${JSON.stringify(name.slice(0, MAX_TEXT_LENGTH))}`);
    } else if (role === "image" && name) {
      this.lines.push(`${indent}[image] ${JSON.stringify(name.slice(0, MAX_TEXT_LENGTH))}`);
    }

    for (const childId of node.childIds ?? []) {
      const child = byId.get(childId);
      if (child) {
        const childIsText = child.role?.value === "staticText";
        this.walk(child, byId, frame, depth, baseIndent, childIsText ? undefined : name || parentName);
      }
    }
  }

  private prop(node: AxNode, name: string): any {
    return node.properties?.find((property) => property.name === name)?.value?.value;
  }
}

function inViewport(node: AxNode, frame: FrameContext): boolean {
  if (!frame.viewport) return true;
  if (!node.backendDOMNodeId) return true; // containers without geometry pass through
  const bounds = frame.bounds.get(node.backendDOMNodeId);
  if (!bounds) return true;
  const { sx, sy, w, h } = frame.viewport;
  const [x, y, width, height] = bounds;
  const intersects = x < sx + w && x + width > sx && y < sy + h && y + height > sy;
  return intersects;
}

/**
 * Stable locator priority per the goal: `role:<role>[name=<name>]` →
 * `css:` (id / data-testid / name attr) → `href:` for links.
 */
export function buildLocator(node: AxNode, frame: FrameContext): string | undefined {
  const role = normRole(node);
  const name = (node.name?.value ?? "").trim();

  if (role && name) {
    return `role:${role}[name=${encodeURIComponent(name)}]`;
  }

  if (node.backendDOMNodeId) {
    const attrs = frame.attributes.get(node.backendDOMNodeId) ?? [];
    const map = new Map<string, string>();
    for (let index = 0; index + 1 < attrs.length; index += 2) map.set(attrs[index], attrs[index + 1]);
    const id = map.get("id");
    const testId = map.get("data-testid") ?? map.get("data-test");
    const inputName = map.get("name");
    if (id) return `css:#${cssEscape(id)}`;
    if (testId) return `css:[data-testid="${escapeQuotes(testId)}"]`;
    if (inputName) return `css:[name="${escapeQuotes(inputName)}"]`;
  }

  const href = node.properties?.find((property) => property.name === "url")?.value?.value;
  if (typeof href === "string" && href) return `href:${href}`;
  return undefined;
}

function cssEscape(value: string): string {
  return value.replace(/([^a-zA-Z0-9_\u00A0-\uFFFF-])/g, "\\$1");
}

function escapeQuotes(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}
