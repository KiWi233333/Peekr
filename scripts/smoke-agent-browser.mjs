#!/usr/bin/env node
// Real CEF integration test with a fresh profile and a loopback fixture. Never touches the user's profile.
import assert from 'node:assert/strict';
import { runInteractionChecks } from './smoke-agent-interactions.mjs';
import { createServer } from 'node:http';
import { createServer as tcpServer } from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, openSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';

const app = resolve(process.argv[2] ?? 'build/Peekr.app');
const root = mkdtempSync(join(tmpdir(), 'peekr-agent-smoke-'));
const data = join(root, 'data');mkdirSync(data);
const fixture = createServer((req,res) => {
  res.setHeader('content-type','text/html');
  if(req.url.startsWith('/frame/inner')) {
    res.end('<!doctype html><label>Nested <input id="nested-input"></label>');
  } else if(req.url.startsWith('/frame/outer')) {
    res.end('<!doctype html><div style="padding:25px"><iframe style="width:500px;height:120px;border:4px solid #ddd" src="/frame/inner"></iframe></div>');
  } else {
    res.end(readFileSync(new URL('./fixtures/agent-browser.html',import.meta.url)));
  }
});
fixture.listen(0,'127.0.0.1');await once(fixture,'listening');
const base=`http://127.0.0.1:${fixture.address().port}`;
const reserve=tcpServer();reserve.listen(0,'127.0.0.1');await once(reserve,'listening');const port=reserve.address().port;await new Promise(r=>reserve.close(r));
writeFileSync(join(data,'settings.json'), JSON.stringify({agentAccessEnabled:true,agentDebugPort:port,bookmarkSync:'off'}));
const discovery=join(data,'agent.json');
const env={...process.env,PEEKR_SMOKE_DATA_ROOT:data,PEEKR_AGENT_DISCOVERY:discovery};
const fd=openSync(join(root,'app.log'),'a');
let appProcess;
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function startApp() {
  appProcess=spawn(join(app,'Contents/MacOS/Peekr'),[],{env:{...env,PEEKR_SMOKE_SHOW_PANEL:'1',PEEKR_SMOKE_URL:base+'/user',PEEKR_SMOKE_QUIT_AFTER:'150'},stdio:['ignore',fd,fd]});
  for(let i=0;i<100;i++) {
    if(appProcess.exitCode!==null) throw new Error('Isolated app exited; see '+join(root,'app.log'));
    if(existsSync(discovery)) {
      const d=JSON.parse(readFileSync(discovery));
      if(d.pid===appProcess.pid && await fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.ok).catch(()=>false)) return;
    }
    await delay(100);
  }
  throw new Error('Isolated browser discovery timed out');
}
async function stopApp() {
  if(!appProcess||appProcess.exitCode!==null)return;
  const exited=once(appProcess,'exit');appProcess.kill('SIGTERM');
  await Promise.race([exited,delay(3000)]);
  if(appProcess.exitCode===null) {appProcess.kill('SIGKILL');await exited;}
}
async function cli(source, expected=0) {
  const child=spawn(process.execPath,['cli/dist/peekr.js','nodejs','-e',source],{env,stdio:['ignore','pipe','pipe']});
  let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);
  const timer=setTimeout(()=>child.kill('SIGKILL'),25000);
  const [code]=await once(child,'exit');clearTimeout(timer);
  assert.equal(code,expected,`CLI failed: ${stderr}`);
  if(expected) return {error:JSON.parse(stderr),stdout};
  return stdout.trim()?JSON.parse(stdout):null;
}
async function control(path,method='GET',body) {
  const d=JSON.parse(readFileSync(discovery));
  const response=await fetch(`http://127.0.0.1:${d.controlPort}${path}`,{method,headers:{Authorization:`Bearer ${d.token}`,'content-type':'application/json'},body:body?JSON.stringify(body):undefined});
  return {status:response.status,body:await response.json()};
}
const results=[];
try {
  await startApp();
  const baseline=await fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.json());
  const first=await cli(`const t=await taskSpace('smoke-a');const p=t.page('p1');await p.goto(${JSON.stringify(base+'/a')});await p.fill('#name','Peekr verified');await p.click('#submit');await p.waitForFunction(()=>document.querySelector('#result').textContent==='Peekr verified');const snapshot=await p.snapshot();if(!snapshot.includes('Peekr verified'))throw Error('snapshot mismatch');await p.screenshot({path:${JSON.stringify(join(root,'page.png'))}});cliLog({id:t.id,tabs:await t.pages(),refs:(await p.snapshotRaw()).refs,value:await p.evaluate(()=>document.querySelector('#result').textContent)});`);
  results.push('native create + navigation + fill + click + wait + snapshot + screenshot');
  const again=await cli(`const t=await taskSpace(${JSON.stringify(first.id)});cliLog({tabs:await t.pages(),value:await t.page('p1').evaluate(()=>document.querySelector('#result').textContent)});`);
  assert.equal(again.tabs[0].targetId,first.tabs[0].targetId);assert.equal(again.value,'Peekr verified');
  results.push('label and page state survive a new CLI process');
  const input=first.refs.find(ref=>ref.role==='textbox');
  const button=first.refs.find(ref=>ref.role==='button');
  assert(input && button,'Fixture must expose input and button refs');
  const refs=await cli(`const t=await taskSpace(${JSON.stringify(first.id)});const p=t.page('p1');await p.bringToFront();await p.fill('@${input.ref}','Cross-round refs verified');await p.click('@${button.ref}');cliLog({tabs:await t.pages(),value:await p.evaluate(()=>document.querySelector('#result').textContent)});`);
  assert.equal(refs.tabs[0].targetId,first.tabs[0].targetId);assert.equal(refs.value,'Cross-round refs verified');
  results.push('cross-round refs and bringToFront reuse the same native page');
  const second=await cli(`const t=await taskSpace('smoke-b');await t.page('p1').goto(${JSON.stringify(base+'/a')});cliLog({id:t.id,tabs:await t.pages()});`);
  assert.notEqual(first.tabs[0].targetId,second.tabs[0].targetId);
  const foreign=await control(`/spaces/${first.id}/tabs/${second.tabs[0].targetId}`,'DELETE');
  assert.equal(foreign.body.code,'PEEKR_TARGET_NOT_OWNED');
  results.push('same-URL spaces stay separate; native cross-space close rejected');
  const yielded=await cli(`const t=await taskSpace(${JSON.stringify(first.id)});await t.handOff();try{await taskSpace(${JSON.stringify(second.id)});}catch{}cliLog('must not continue');`,1);
  assert.equal(yielded.error.code,'PEEKR_SPACE_USER_IN_CONTROL');assert.equal(yielded.stdout,'');
  const stopped=await cli(`try{const t=await taskSpace(${JSON.stringify(first.id)});await t.page('p1').cdp('Runtime.evaluate',{expression:'1'});}catch{}cliLog('must not report success');`,1);
  assert.equal(stopped.error.code,'PEEKR_SPACE_USER_IN_CONTROL');assert.equal(stopped.stdout,'');
  const nativeStopped=await control(`/spaces/${first.id}/tabs`);
  assert.equal(nativeStopped.body.code,'PEEKR_SPACE_USER_IN_CONTROL');
  results.push('handoff blocks native and CLI commands, even when script catches the hard stop');
  await cli(`const t=await takeOverTaskSpace(${JSON.stringify(first.id)});const p=t.page('p1');const epoch=await p.evaluate(()=>performance.timeOrigin);await p.reload();if(await p.evaluate(()=>performance.timeOrigin)===epoch)throw Error('reload returned the old document');await t.finish();`);
  await cli(`const t=await taskSpace(${JSON.stringify(second.id)});await t.finish();`);
  const remaining=await fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.json());
  for(const page of baseline)assert(remaining.some(x=>x.id===page.id),'User baseline target was closed');
  results.push('resume + reload + finish close only managed pages');
  const retained=await cli(`const t=await taskSpace('retain');await t.page('keep').goto(${JSON.stringify(base+'/keep')});await t.page('scratch').goto(${JSON.stringify(base+'/scratch')});const tabs=await t.pages();await t.finish({keep:['keep']});cliLog({id:t.id,tabs});`);
  const retainedTargets=await fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.json());
  assert(retainedTargets.some(x=>x.id===retained.tabs.find(x=>x.label==='keep').targetId));
  assert(!retainedTargets.some(x=>x.id===retained.tabs.find(x=>x.label==='scratch').targetId));
  assert.equal((await control(`/spaces/${retained.id}/tabs`)).body.code,'PEEKR_SPACE_USER_IN_CONTROL');
  results.push('finish keep preserves only selected managed pages and gives control to user');
  results.push(...await runInteractionChecks({cli,base,root}));
  const restart=await cli(`const t=await taskSpace('restart');await t.page('p1').goto(${JSON.stringify(base+'/restart')});cliLog({id:t.id});`);
  await stopApp();await startApp();
  const stale=await cli(`await takeOverSpace(${JSON.stringify(restart.id)});const t=await taskSpace(${JSON.stringify(restart.id)});await t.page('p1').info();`,1);
  assert.equal(stale.error.code,'PEEKR_STALE_PAGE');
  results.push('app restart explicitly invalidates old page labels without target adoption');
  writeFileSync(join(root,'result.json'),JSON.stringify({ok:true,results},null,2));
  console.log(JSON.stringify({ok:true,results,artifacts:root},null,2));
} finally {await stopApp();await new Promise(r=>fixture.close(r));}
