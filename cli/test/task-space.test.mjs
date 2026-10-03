import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

// Each case gets its own round, discovery file and mock native bridge. No real browser traffic.
function scenario(body) {
  execFileSync(process.execPath, ['--input-type=module', '-e', String.raw`
    import assert from 'node:assert/strict';
    import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
    import { tmpdir } from 'node:os';
    import { join } from 'node:path';
    import { helpers, state, PageLedgerStore, acquireLease, releaseLease, generationOf } from './dist/peekr.js';
    const root=mkdtempSync(join(tmpdir(),'peekr-contract-'));
    process.env.PEEKR_AGENT_DISCOVERY=join(root,'agent.json');
    const discovery={pid:process.pid,port:12345,controlPort:12346,token:'test'};
    writeFileSync(process.env.PEEKR_AGENT_DISCOVERY,JSON.stringify(discovery));
    const spaces=[{id:'A',name:'alpha',ownership:'agent'},{id:'B',name:'beta',ownership:'agent'}];
    const tabs={A:[{targetId:'a',url:'https://example.test/a',title:'A'}],B:[{targetId:'b',url:'https://example.test/b',title:'B'}]};
    let calls=[];let down=false;
    globalThis.fetch=async (url,options={})=>{
      const path=new URL(url).pathname; calls.push([path,options.method]);
      if(down) throw new Error('offline');
      if(path==='/spaces') return Response.json({spaces});
      const match=path.match(/^\/spaces\/([^/]+)\/tabs$/);
      if(match && (options.method==='GET'||!options.method)) return Response.json({tabs:tabs[match[1]]});
      throw new Error('Unexpected route '+path);
    };
    for(const id of ['a','b'])state.sockets.set(id,{isOpen:true,send:async()=>({result:{value:id}}),close(){}});
    const ledger=new PageLedgerStore(join(root,'page-ledger.json'));
    ledger.bind('A','p1','a',{generation:generationOf(discovery)});
    ledger.bind('B','p1','b',{generation:generationOf(discovery)});
    try { ${body} } finally {releaseLease();rmSync(root,{recursive:true,force:true});}
  `], { cwd: new URL('..', import.meta.url), stdio: 'pipe' });
}

test('native space targets exclude global/user pages and raw foreign target is rejected', () => scenario(`
  await helpers.useOrCreateSpace('A');
  assert.deepEqual((await helpers.listTabs()).map(x=>x.targetId),['a']);
  await assert.rejects(helpers.switchTab('b'),{code:'PEEKR_TARGET_NOT_OWNED'});
  assert.equal(calls.some(([path])=>path==='/json/list'),false);
`));
test('delegated user ownership blocks browser work and catches cannot resume the round', () => scenario(`
  await helpers.useOrCreateSpace('A');
  spaces[0].ownership='agentDelegatedToUser';
  await assert.rejects(helpers.js('1'),{code:'PEEKR_SPACE_USER_IN_CONTROL'});
  spaces[0].ownership='agent';
  await assert.rejects(helpers.cdp('Runtime.evaluate'),{code:'PEEKR_SPACE_USER_IN_CONTROL'});
`));
test('unavailable control bridge fails closed', () => scenario(`
  await helpers.useOrCreateSpace('A');down=true;
  await assert.rejects(helpers.js('1'),{code:'PEEKR_CDP_UNAVAILABLE'});
`));
test('raw CDP does not bypass takeover guard', () => scenario(`
  await helpers.useOrCreateSpace('A');spaces[0].ownership='user';
  await assert.rejects(helpers.cdp('Runtime.evaluate'),{code:'PEEKR_SPACE_USER_IN_CONTROL'});
`));
test('operations require a selected space', () => scenario(`
  await assert.rejects(helpers.listTabs(),{code:'PEEKR_SPACE_REQUIRED'});
`));
test('parallel page handles are serialized and stay bound to their own space', () => scenario(`
  const a=(await helpers.taskSpace('A')).page('p1');
  const b=(await helpers.taskSpace('B')).page('p1');
  assert.deepEqual(await Promise.all([a.evaluate('1'),b.evaluate('1'),a.evaluate('1')]),['a','b','a']);
`));
test('selected closed page never falls back to another live page', () => scenario(`
  await helpers.useOrCreateSpace('A');await helpers.switchTab('a');
  tabs.A=[{targetId:'other',url:'https://example.test/other',title:'other'}];
  await assert.rejects(helpers.js('1'),{code:'PEEKR_STALE_PAGE'});
`));
test('stale labels are persisted, and cannot be silently reassigned', () => scenario(`
  const page=(await helpers.taskSpace('A')).page('p1');tabs.A=[];
  await assert.rejects(page.goto('https://example.test/new'),{code:'PEEKR_STALE_PAGE'});
  const restored=new PageLedgerStore(join(root,'page-ledger.json'));
  assert.equal(restored.resolve('A','p1').status,'stale');
  assert.throws(()=>restored.bind('A','p1','new'),{code:'PEEKR_STALE_PAGE'});
`));
test('app restart invalidates the entire in-flight round', () => scenario(`
  await helpers.useOrCreateSpace('A');
  writeFileSync(process.env.PEEKR_AGENT_DISCOVERY,JSON.stringify({...discovery,token:'new-launch'}));
  await assert.rejects(helpers.listTabs(),{code:'PEEKR_SESSION_CHANGED'});
`));
test('raw browser lifecycle CDP is explicitly unavailable from a page', () => scenario(`
  await helpers.useOrCreateSpace('A');
  await assert.rejects(helpers.cdp('Target.closeTarget',{targetId:'b'}),{code:'PEEKR_INVALID_ARGUMENT'});
`));
test('switching spaces invalidates refs and old target selection', () => scenario(`
  await helpers.useOrCreateSpace('A');await helpers.switchTab('a');state.refMap.set(1,{ref:1});
  await helpers.useOrCreateSpace('B');
  assert.equal(state.refMap.size,0);assert.equal(state.targetId,null);
`));

test('takeover during socket initialization closes the unregistered socket', () => scenario(`
  await helpers.useOrCreateSpace('A');
  state.sockets.delete('a');
  let closed=false;
  const nativeFetch=globalThis.fetch;
  globalThis.fetch=async(url,options)=>new URL(url).pathname==='/json/list'
    ? Response.json([{id:'a',type:'page',webSocketDebuggerUrl:'ws://127.0.0.1/a'}])
    : nativeFetch(url,options);
  globalThis.WebSocket=class extends EventTarget {
    static OPEN=1;
    readyState=1;
    constructor(){super();queueMicrotask(()=>{spaces[0].ownership='user';this.dispatchEvent(new Event('open'));});}
    close(){closed=true;this.readyState=3;this.dispatchEvent(new Event('close'));}
    send(){throw Error('Must not dispatch after takeover');}
  };
  await assert.rejects(helpers.pageInfo(),{code:'PEEKR_SPACE_USER_IN_CONTROL'});
  assert.equal(closed,true);
  assert.equal(state.sockets.has('a'),false);
`));

test('keyboard failure releases all successfully pressed keys and preserves the original error', () => scenario(`
  await helpers.useOrCreateSpace('A');
  const events=[];
  state.sockets.get('a').send=async(method,event)=>{
    events.push(event);
    if(event.type==='char')throw Error('injected character failure');
    return {};
  };
  await assert.rejects(helpers.pressKey('Shift+a'),/injected character failure/);
  assert.deepEqual(events.filter(event=>event.type==='keyUp').map(event=>[event.key,event.modifiers]),[['a',8],['Shift',0]]);
`));

test('claim and takeover TaskSpace aliases return page-capable handles', () => scenario(`
  const nativeFetch=globalThis.fetch;
  globalThis.fetch=async(url,options)=>new URL(url).pathname==='/spaces/A/claim'
    ? Response.json({space:spaces[0]}) : nativeFetch(url,options);
  const claimed=await helpers.claimTaskSpace('A');
  assert.equal(claimed.ownership,'agent');assert.equal(claimed.page('p1').spaceId,'A');
  const resumed=await helpers.takeOverTaskSpace('A');
  assert.equal(resumed.page('p1').label,'p1');
`));
