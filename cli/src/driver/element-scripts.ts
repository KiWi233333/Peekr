/** Page-side code shared by element actions. It has no harness-side dependencies. */
export const SEARCH_ROOTS_JS = `(() => {
  const roots = [document];
  for (let i = 0; i < roots.length; i++) {
    for (const el of roots[i].querySelectorAll('*')) {
      if (el.shadowRoot) roots.push(el.shadowRoot);
    }
  }
  return roots;
})()`;

export const ACTION_POINT_JS = `
  if (!this.isConnected) throw Error('Element is detached; take a fresh snapshot');
  this.scrollIntoView({block:'center', inline:'center', behavior:'instant'});
  let view = this.ownerDocument.defaultView;
  const frames = [];
  while (view.frameElement) {
    frames.push(view.frameElement);
    view.frameElement.scrollIntoView({block:'center', inline:'center', behavior:'instant'});
    view = view.parent;
  }
  const style = this.ownerDocument.defaultView.getComputedStyle(this);
  const rect = this.getBoundingClientRect();
  if (!rect.width || !rect.height || style.visibility !== 'visible' || style.display === 'none') {
    throw Error('Element is not visible');
  }
  if (this.matches(':disabled') || this.closest('[aria-disabled="true"], [inert]')) throw Error('Element is disabled');
  let x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
  let hit = this.ownerDocument.elementFromPoint(x, y);
  while (hit?.shadowRoot) {
    const child = hit.shadowRoot.elementFromPoint(x, y);
    if (!child || child === hit) break;
    hit = child;
  }
  if (hit !== this && !this.contains(hit)) throw Error('Element is covered or outside the viewport');
  for (const frame of frames) {
    const bounds = frame.getBoundingClientRect();
    x += bounds.left + frame.clientLeft; y += bounds.top + frame.clientTop;
    if (frame.ownerDocument.elementFromPoint(x, y) !== frame) throw Error('Frame is covered');
  }
  return {x, y};
`;
