import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { TargetSocket, PeekrError, ErrorCodes } from '../dist/peekr.js';

test('hard stops and uncertain transport failures never advise automatic replay', () => {
  for (const code of Object.values(ErrorCodes)) {
    const error = new PeekrError(code, 'test');
    if (error.hardStop) assert.match(error.guidance, /hard stop/i);
  }
  assert.match(new PeekrError(ErrorCodes.cdpUnavailable, 'offline').guidance, /do not automatically replay/);
});

class FakeWebSocket extends EventEmitter {
  static OPEN=1;
  readyState=1;
  static last;
  constructor(){super();FakeWebSocket.last=this;queueMicrotask(()=>this.emit('open'));}
  addEventListener(event,handler){this.on(event,handler);}
  send(){}
  close(){this.readyState=3;this.emit('close');}
}

test('socket close rejects every in-flight request and event waiter immediately',async()=>{
  const original=globalThis.WebSocket;globalThis.WebSocket=FakeWebSocket;
  try {
    const socket=await TargetSocket.open('ws://127.0.0.1/test');
    const request=socket.send('Runtime.evaluate');
    const event=socket.waitForEvent('Page.loadEventFired');
    await Promise.resolve();
    socket.close();
    await assert.rejects(request,{code:'PEEKR_CDP_UNAVAILABLE'});
    await assert.rejects(event,{code:'PEEKR_CDP_UNAVAILABLE'});
    await assert.rejects(socket.send('Runtime.evaluate'),{code:'PEEKR_CDP_UNAVAILABLE'});
    assert.equal(socket.isOpen,false);
  } finally {globalThis.WebSocket=original;}
});

test('a live CLI process has exclusive access; SIGKILL lease is recovered by the next process',async()=>{
  const root=mkdtempSync(join(tmpdir(),'peekr-lease-test-'));
  const discovery=join(root,'agent.json');writeFileSync(discovery,JSON.stringify({port:1,controlPort:2,pid:process.pid,token:'test'}));
  const env={...process.env,PEEKR_AGENT_DISCOVERY:discovery};
  const cwd=new URL('..',import.meta.url);
  const owner=spawn(process.execPath,['--input-type=module','-e',"import {acquireLease} from './dist/peekr.js';acquireLease();console.log('ready');setInterval(()=>{},1000);"],{env,cwd,stdio:['ignore','pipe','pipe']});
  try {
    await once(owner.stdout,'data');
    const result=execFileSync(process.execPath,['--input-type=module','-e',"import {acquireLease} from './dist/peekr.js';try{acquireLease();process.exit(2)}catch(e){console.log(e.code)}"],{env,cwd,encoding:'utf8'});
    assert.equal(result.trim(),'PEEKR_BROWSER_BUSY');
    const exited=once(owner,'exit');owner.kill('SIGKILL');await exited;
    execFileSync(process.execPath,['--input-type=module','-e',"import {acquireLease,releaseLease} from './dist/peekr.js';acquireLease();releaseLease();"],{env,cwd});
  } finally {owner.kill('SIGKILL');rmSync(root,{recursive:true,force:true});}
});

test('SIGINT exits 130 even when user script is waiting forever',async()=>{
  const child=spawn(process.execPath,['dist/peekr.js','nodejs','-e',"setInterval(()=>{},1000);console.error('ready');await new Promise(()=>{});"],{cwd:new URL('..',import.meta.url),stdio:['ignore','pipe','pipe']});
  let stderr='';child.stderr.on('data',b=>stderr+=b);
  await once(child.stderr,'data');const exit=once(child,'exit');child.kill('SIGINT');
  assert.equal((await exit)[0],130);assert.match(stderr,/PEEKR_INTERRUPTED/);
});
