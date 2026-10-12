import {test} from 'node:test'
import assert from 'node:assert/strict'
import {SessionBridge,visibleMessages} from '../lib/session-bridge.js'
function fixture() {
  const messages=[{role:'system',content:[{type:'text',text:'hidden'}]}, {role:'user',source:{kind:'runtime'},content:[{type:'text',text:'hidden2'}]}, {role:'user',source:{kind:'user'},content:[{type:'text',text:'hello'}]}]
  const session={id:'s1',events:[],deriveMessages:()=>messages}
  const agent={id:'s1',status:'idle'}
  const outputs=[],calls=[]
  const controller={async prompt(r){calls.push(['prompt',r]);return {accepted:true}},cancel(r){calls.push(['cancel',r]);agent.status='idle';return {accepted:true}},async create(){calls.push(['create']);return {sessionId:'s1'}}}
  const bridge=new SessionBridge({sessions:{list:()=>[session],get:id=>id==='s1'?session:undefined},agents:{get:id=>id==='s1'?agent:undefined},controller},m=>outputs.push(m))
  return {bridge,session,agent,controller,calls,outputs,messages}
}
test('send uses official prompt admission with user request id; cancel uses same session API',async()=>{
  const f=fixture();await f.bridge.request({op:'send',sessionId:'s1',text:'hello',requestId:'r1'})
  assert.equal(f.calls[0][0],'prompt');assert.equal(f.calls[0][1].requestId,'r1');assert.equal(f.calls[0][1].mode,'queue');assert.equal(f.calls[0][1].sessionId,'s1')
  f.agent.status='running';await f.bridge.request({op:'cancel',sessionId:'s1'});assert.deepEqual(f.calls[1],['cancel',{sessionId:'s1'}])
})
test('empty, oversized, stale session and busy sends never reach official API',async()=>{
  const f=fixture()
  for(const message of [{op:'send',sessionId:'s1',text:' '},{op:'send',sessionId:'s1',text:'x'.repeat(16001)},{op:'send',sessionId:'other',text:'hello'},{op:'select',sessionId:'other'},{op:'execute',sessionId:'s1'}])await f.bridge.request(message)
  f.agent.status='running';await f.bridge.request({op:'send',sessionId:'s1',text:'hello'})
  assert.equal(f.calls.length,0);assert.equal(f.outputs.filter(m=>m.kind==='receipt'&&!m.ok).length,6)
})
test('pending send is not released by rejected concurrent requests',async()=>{
  const f=fixture();let finish;f.controller.prompt=()=>new Promise(r=>finish=r)
  const first=f.bridge.request({op:'send',sessionId:'s1',text:'one'});assert.equal(f.bridge.inFlight,true)
  await f.bridge.request({op:'send',sessionId:'s1',text:'two'});assert.equal(f.bridge.inFlight,true)
  await f.bridge.request({op:'read',sessionId:'s1'});assert.equal(f.bridge.inFlight,true)
  finish({accepted:true});await first;assert.equal(f.bridge.inFlight,false)
})
test('stream hides reasoning, drops duplicate/stale frames, and reconciles durable reply',()=>{
  const f=fixture();f.bridge.stream(f.agent,{type:'start',attemptId:'a1',revision:1})
  f.bridge.stream(f.agent,{type:'chunk',attemptId:'a1',revision:2,chunk:{type:'reasoning-delta',text:'secret'}})
  f.bridge.stream(f.agent,{type:'chunk',attemptId:'a1',revision:3,chunk:{type:'text-delta',text:'Hi'}})
  f.bridge.stream(f.agent,{type:'chunk',attemptId:'a1',revision:3,chunk:{type:'text-delta',text:'duplicate'}})
  assert.equal(f.bridge.snapshot().partial,'Hi');assert.equal(f.bridge.snapshot().text,'hello')
  f.messages.push({role:'assistant',content:[{type:'text',text:'Hi'}]});f.bridge.event(f.session,{type:'assistant/message'})
  assert.equal(f.bridge.snapshot().partial,'');assert.equal(f.bridge.snapshot().messages.at(-1).text,'Hi')
})
test('failed send retains receipt error and no forged local messages; teardown suppresses late receipts',async()=>{
  const f=fixture();f.controller.prompt=async()=>{throw new Error('model unavailable')}
  await f.bridge.request({op:'send',sessionId:'s1',text:'hello'});assert.equal(f.outputs.find(m=>m.kind==='receipt').error,'model unavailable');assert.equal(f.messages.length,3)
  f.bridge.close();const count=f.outputs.length;await f.bridge.request({op:'send',sessionId:'s1',text:'hello'});assert.equal(f.outputs.length,count)
})
test('transcript projection is bounded even for long histories',()=>{
  const result=visibleMessages({deriveMessages:()=>Array.from({length:100},()=>({role:'assistant',content:[{type:'text',text:'长'.repeat(16000)}]}))})
  assert.ok(result.reduce((n,m)=>n+m.text.length,0)<=24000)
})
