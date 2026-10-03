// Unique element resolution and actionability; no implicit first-match clicks.
import type { TargetSocket } from '../cdp.js';
import { ErrorCodes, PeekrError } from '../errors.js';
import { isRefToken, resolveRef } from '../ref-map.js';
import { currentSocket, socketFor } from './nav.js';
import { ARIA_HELPERS_JS } from './frames.js';
import { ACTION_POINT_JS, SEARCH_ROOTS_JS } from './element-scripts.js';

export interface ElementHandle { socket: TargetSocket; objectId: string }
export interface ResolvedElement { socket: TargetSocket; objectId?: string; x: number; y: number }
export type ElementTarget = string | number;
export type ActionTarget = ElementTarget | [number, number] | { x: number; y: number };

export function protocolValue<T>(result: any): T {
  if (result?.exceptionDetails) {
    throw new PeekrError(ErrorCodes.actionFailed,
      result.exceptionDetails.exception?.description ?? result.exceptionDetails.text ?? 'Element operation failed.');
  }
  return result?.result?.value as T;
}

export async function callElement<T>(element: ElementHandle, body: string): Promise<T> {
  const result = await element.socket.send('Runtime.callFunctionOn', {
    objectId: element.objectId, functionDeclaration: `function () { ${body} }`, returnByValue: true, awaitPromise: true,
  });
  return protocolValue<T>(result);
}

async function queryObject(socket: TargetSocket, expression: string): Promise<string> {
  const result = await socket.send<any>('Runtime.evaluate', { expression, returnByValue: false });
  protocolValue(result);
  if (!result?.result?.objectId) throw new PeekrError(ErrorCodes.actionFailed, 'No element matches the target.');
  return result.result.objectId;
}

async function uniqueMatch(socket: TargetSocket, candidates: string): Promise<string> {
  return queryObject(socket, `(() => {
    const matches = [...new Set(${candidates})];
    if (matches.length > 1) throw Error('Strict locator matched ' + matches.length + ' elements; use a unique target');
    return matches[0] ?? null;
  })()`);
}

async function findByRole(socket: TargetSocket, role: string, name?: string): Promise<string> {
  return uniqueMatch(socket, `(() => {
    ${ARIA_HELPERS_JS}
    return ${SEARCH_ROOTS_JS}.flatMap(root => [...root.querySelectorAll('*')]).filter(el =>
      roleOf(el) === ${JSON.stringify(role)} &&
      (${name === undefined ? 'true' : `nameOf(el, roleOf(el)) === ${JSON.stringify(name)}`}));
  })()`);
}

async function findByHref(socket: TargetSocket, href: string): Promise<string> {
  return uniqueMatch(socket, `${SEARCH_ROOTS_JS}.flatMap(root => [...root.querySelectorAll('a[href]')])
    .filter(el => el.href === ${JSON.stringify(href)} || el.getAttribute('href') === ${JSON.stringify(href)})`);
}

async function findBySelector(socket: TargetSocket, selector: string): Promise<string> {
  if (selector.startsWith('xpath=')) {
    return uniqueMatch(socket, `(() => {
      const found = document.evaluate(${JSON.stringify(selector.slice(6))}, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      return Array.from({length:found.snapshotLength}, (_, i) => found.snapshotItem(i));
    })()`);
  }
  const css = selector.replace(/^css[:=]/, '');
  return uniqueMatch(socket, `${SEARCH_ROOTS_JS}.flatMap(root => [...root.querySelectorAll(${JSON.stringify(css)})])`);
}

export async function resolveElement(target: ElementTarget): Promise<ElementHandle> {
  if (typeof target !== 'string' && typeof target !== 'number') {
    throw new PeekrError(ErrorCodes.invalidArgument, 'This operation needs an element ref or selector.');
  }
  if (isRefToken(target)) {
    const info = resolveRef(target);
    const socket = info.frameTargetId ? await socketFor(info.frameTargetId) : await currentSocket();
    if (info.frame) {
      const {chain, selector, epoch} = info.frame;
      const objectId = await queryObject(socket, `(() => {
        let doc = document;
        for (const id of ${JSON.stringify(chain)}) {
          doc = doc.querySelector('iframe[data-peekr-frame="' + id + '"],frame[data-peekr-frame="' + id + '"]')?.contentDocument;
          if (!doc) throw Error('Frame disappeared or is cross-origin');
        }
        if (JSON.stringify([doc.location.href, doc.defaultView.performance.timeOrigin]) !== ${JSON.stringify(epoch) ?? 'undefined'}) {
          throw Error('Frame document changed; take a fresh snapshot');
        }
        const matches = doc.querySelectorAll(${JSON.stringify(selector)});
        if (matches.length !== 1) throw Error('Frame ref is stale or ambiguous; take a fresh snapshot');
        return matches[0];
      })()`);
      return {socket, objectId};
    }
    if (info.backendDOMNodeId) {
      const result = await socket.send<any>('DOM.resolveNode', {backendNodeId: info.backendDOMNodeId});
      if (result?.object?.objectId) return {socket, objectId: result.object.objectId};
    }
    throw new PeekrError(ErrorCodes.unknownRef, 'Ref is no longer attached to a DOM node; take a fresh snapshot.');
  }
  const socket = await currentSocket();
  const selector = String(target).trim().replace(/^loc=/, '');
  const role = /^role:([^[]+)(?:\[name=(.+)\])?$/.exec(selector);
  const objectId = role ? await findByRole(socket, role[1], role[2] ? tryDecode(role[2]) : undefined)
    : selector.startsWith('href:') ? await findByHref(socket, selector.slice(5))
    : await findBySelector(socket, selector);
  return {socket, objectId};
}

export async function resolveTarget(target: ActionTarget): Promise<ResolvedElement> {
  if (Array.isArray(target) || (typeof target === 'object' && target !== null)) {
    const point = Array.isArray(target) ? {x:target[0], y:target[1]} : target;
    if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) throw new PeekrError(ErrorCodes.invalidArgument, 'Coordinates must be finite.');
    return {socket:await currentSocket(), ...point};
  }
  const element = await resolveElement(target);
  const point = await callElement<{x:number; y:number}>(element, ACTION_POINT_JS);
  return {...element, ...point};
}

function tryDecode(value: string): string {
  try { return decodeURIComponent(value); } catch { return value; }
}
