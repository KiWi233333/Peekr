import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

/** Runs only against the isolated bridge/fixture supplied by smoke-agent-browser. */
export async function runInteractionChecks({cli, base, root}) {
  const fileA = join(root, 'upload-a.txt'), fileB = join(root, 'upload-b.txt');
  writeFileSync(fileA, 'first file'); writeFileSync(fileB, 'second file');
  const {id} = await cli(`const t=await taskSpace('interaction-checks');await t.page('p1').goto(${JSON.stringify(base+'/forms')});cliLog({id:t.id});`);
  const page = `const t=await taskSpace(${JSON.stringify(id)});const p=t.page('p1');`;
  const results = [];
  const forms = await cli(`${page}
    await p.check('#agree');await p.check('#agree');await p.uncheck('#agree');await p.check('#radio');
    await p.selectOption('#plan',{label:'Pro'});await p.selectOption('#multi',[{index:0},'z']);
    await p.fill('#notes','temporary');await p.clear('#notes');
    cliLog(await p.evaluate(()=>({checked:document.querySelector('#agree').checked,changes:window.checkChanges,
      radio:document.querySelector('#radio').checked,plan:document.querySelector('#plan').value,
      multiple:Array.from(document.querySelector('#multi').selectedOptions,o=>o.value),notes:document.querySelector('#notes').value})));`);
  assert.deepEqual(forms,{checked:false,changes:2,radio:true,plan:'b',multiple:['x','z'],notes:''});
  results.push('checkbox idempotence + radio + select by label/index/value + multiselect + clear');
  const rejected = await cli(`${page}
    const errors=[];
    for(const target of ['.duplicate','#hidden','#disabled','#covered']) {
      try {await p.click(target);}catch(e){errors.push(e.code);}
    }
    try{await p.fill('#readonly','changed');}catch(e){errors.push(e.code);}
    try{await p.selectOption('#plan','c');}catch(e){errors.push(e.code);}
    cliLog({errors,readonly:await p.evaluate(()=>document.querySelector('#readonly').value),covered:await p.evaluate(()=>!!window.coverClicked)});`);
  assert.deepEqual(rejected,{errors:Array(6).fill('PEEKR_ACTION_FAILED'),readonly:'unchanged',covered:false});
  results.push('strict/hidden/disabled/covered/readonly/disabled-option failures preserve page state');
  const keyboard = await cli(`${page}
    await p.fill('#name','replace me');await p.keyboard.press('ControlOrMeta+a');await p.keyboard.type('Hi');
    await p.keyboard.press('Shift+z');await p.click('loc=css:#shadow-button');
    cliLog({value:await p.evaluate(()=>document.querySelector('#name').value),shadow:await p.evaluate(()=>document.querySelector('#shadow').shadowRoot.querySelector('button').textContent)});`);
  assert.deepEqual(keyboard,{value:'HiZ',shadow:'Shadow clicked'});
  results.push('portable select-all chord + physical typing + Shift chord + loc= shadow selector');
  const upload = await cli(`${page}
    await p.setInputFiles('#upload',${JSON.stringify([fileA,fileB])});
    const files=await p.evaluate(async()=>Promise.all(Array.from(document.querySelector('#upload').files,async file=>({name:file.name,text:await file.text()}))));
    await p.setInputFiles('#upload',[]);let invalid;
    try{await p.setInputFiles('#upload',${JSON.stringify(join(root,'missing-file'))});}catch(e){invalid=e.code;}
    cliLog({files,count:await p.evaluate(()=>document.querySelector('#upload').files.length),invalid});`);
  assert.deepEqual(upload,{files:[{name:'upload-a.txt',text:'first file'},{name:'upload-b.txt',text:'second file'}],count:0,invalid:'PEEKR_INVALID_ARGUMENT'});
  results.push('hidden multiple file input receives real files, clears files and rejects missing paths');
  const frame = await cli(`${page}
    await p.waitForFunction(()=>!!document.querySelector('#outer').contentDocument?.querySelector('iframe')?.contentDocument?.querySelector('#nested-input'));
    const snapshot=await p.snapshotRaw();
    const field=snapshot.refs.find(r=>r.frame?.chain.length===2 && r.role==='textbox');
    if(!field)throw Error('Missing nested frame ref');
    await p.fill('@'+field.ref,'Nested verified');
    const value=await p.evaluate(()=>document.querySelector('#outer').contentDocument.querySelector('iframe').contentDocument.querySelector('#nested-input').value);
    await p.evaluate(()=>{document.querySelector('#outer').contentDocument.querySelector('iframe').src='/frame/inner?new';});
    await p.waitForFunction(()=>document.querySelector('#outer').contentDocument.querySelector('iframe').contentDocument?.location.search==='?new');
    let stale;try{await p.fill('@'+field.ref,'must not write');}catch(e){stale=e.code;}
    cliLog({value,stale,fresh:await p.evaluate(()=>document.querySelector('#outer').contentDocument.querySelector('iframe').contentDocument.querySelector('#nested-input').value)});`);
  assert.deepEqual(frame,{value:'Nested verified',stale:'PEEKR_ACTION_FAILED',fresh:''});
  results.push('nested same-origin ref geometry works; frame navigation rejects stale refs');
  const history = await cli(`${page}
    await p.goto(${JSON.stringify(base+'/history-one')});await p.goto(${JSON.stringify(base+'/history-two')});
    const back=await p.goBack();const forward=await p.goForward();
    await p.evaluate(()=>history.pushState({},'', '#state'));const same=await p.goBack();
    cliLog({back:back.url,forward:forward.url,same:same.url});`);
  assert.deepEqual(history,{back:base+'/history-one',forward:base+'/history-two',same:base+'/history-two'});
  results.push('history back/forward and same-document pushState navigation');
  await cli(`${page}await p.screenshot({path:${JSON.stringify(join(root,'interactions.png'))}});await t.finish();`);
  const budget = await cli(`const t=await taskSpace('budget-check');
    for(let i=0;i<8;i++)await t.page('p'+i).goto(${JSON.stringify(base+'/budget')});
    let code;try{await t.page('overflow').goto(${JSON.stringify(base+'/overflow')});}catch(e){code=e.code;}
    const before=(await t.pages()).length;
    await t.page('p0').close();await t.page('replacement').goto(${JSON.stringify(base+'/replacement')});
    const after=(await t.pages()).length;await t.finish();cliLog({code,before,after});`);
  assert.deepEqual(budget,{code:'PEEKR_TAB_LIMIT',before:8,after:8});
  results.push('real native tab budget rejects overflow and recovers after scratch close');
  const retained = await cli(`const t=await taskSpace('keep-all-check');
    await t.page('keep').goto(${JSON.stringify(base+'/keep-all')});const pages=await t.pages();
    const receipt=await t.finish({keep:'all'});cliLog({pages:pages.length,closed:receipt.closed});`);
  assert.deepEqual(retained,{pages:1,closed:false});
  results.push('TaskSpace finish keep all retains managed pages for the user');
  return results;
}
