import test from 'node:test'
import assert from 'node:assert/strict'
import {SurfaceBridge} from '../lib/surface-bridge.js'
function fixture(options) {
  const output=[]
  const bridge={selected:'a',allowedSessions:new Set(['a']),services:{sessions:{get:id=>['a','b'].includes(id)?{id}:null}},async request(m){this.selected=m.sessionId}}
  return {bridge,output,surface:new SurfaceBridge(bridge,m=>output.push(m),options)}
}
test('main window only switches after exact navigation acknowledgment; stale acknowledgments ignored',()=>{
  const {surface,output}=fixture()
  surface.desktop();surface.desktop()
  assert.equal(output.length,0)
  assert.deepEqual(surface.poll(),{revision:1,sessionId:'a'})
  assert.equal(surface.ack(1,'b'),false)
  assert.equal(surface.ack(0,'a'),false)
  assert.equal(surface.ack(1,'a'),true)
  assert.deepEqual(output,[{kind:'surface',surface:'desktop'}])
  assert.equal(surface.ack(1,'a'),false)
  surface.close()
})
test('return adopts the official current loaded session and rejects unknown sessions',async()=>{
  const {surface,bridge,output}=fixture()
  surface.desktop()
  assert.equal(await surface.bubble('unknown'),false)
  assert.equal(await surface.bubble('b'),true)
  assert.equal(bridge.selected,'b')
  assert.equal(surface.poll(),null)
  assert.equal(output.at(-1).surface,'bubble')
  surface.close();assert.equal(await surface.bubble('a'),false)
})
test('navigation timeout keeps the conversation available and disposal cancels pending navigation',async()=>{
  const {surface,output}=fixture({timeoutMs:10})
  surface.desktop()
  await new Promise(resolve=>setTimeout(resolve,20))
  assert.equal(surface.poll(),null)
  assert.equal(output[0].kind,'error')
  surface.desktop();surface.close()
  await new Promise(resolve=>setTimeout(resolve,20))
  assert.equal(output.length,1)
})
