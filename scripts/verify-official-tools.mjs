// Load real official registries; use isolated synthetic memory, no model or screen read.
import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
const runtime = process.env.DSH_RELEASE_RUNTIME
if (!runtime) throw new Error('Set DSH_RELEASE_RUNTIME to an extracted official app dsh directory')
const pkg = name => pathToFileURL(join(runtime, 'node_modules', name, 'lib/index.js')).href
const { boot } = await import(pkg('@deepseek-ai/dsh-app-boot'))
const { validateJsonSchemaValue, assertSupportedJsonSchema } = await import(pkg('@deepseek-ai/dsh-tools'))
const root = resolve(import.meta.dirname, '..')
const dir = mkdtempSync(join(tmpdir(), 'lookover-release-'))
process.env.MEM_DIR = join(dir, 'mem')
process.env.DSH_HOME = dir
const config = join(dir, 'cordis.json')
writeFileSync(config, JSON.stringify([
  { id:'prompt', name:pkg('@deepseek-ai/dsh-system-prompt'), config:{includeHarnessIdentity:false,includeRuntimeContext:false} },
  { id:'tools', name:pkg('@deepseek-ai/dsh-tools') },
  { id:'look', name:pathToFileURL(join(root,'dsh-look/lib/index.js')).href },
  { id:'mem', name:pathToFileURL(join(root,'dsh-expmem/lib/index.js')).href },
]))
let ctx
try {
  ctx = await boot('lookover-release-check', config, [])
  const schemas = ctx.tools.schemas()
  assert.equal(schemas.length, 6)
  for (const schema of schemas) assertSupportedJsonSchema(schema.parameters)
  const run = async (name,args) => {
    const tool = ctx.tools.get(name)
    assert.deepEqual(validateJsonSchemaValue(tool.parameters,args), [], name+' arguments')
    const value = await tool.execute(args)
    assert.deepEqual(validateJsonSchemaValue(tool.output.schema,value), [], name+' output')
    return value
  }
  const c = await run('mem_save_case',{question:'测试浏览器选中文字无法读取问题',choice:'检查辅助功能授权',outcomeStatus:'unknown',sources:[{type:'paste',excerpt:'模拟来源'}]})
  const k = await run('mem_add_claim',{caseId:c.caseId,conclusion:'先检查辅助功能授权',conditions:'仅适用于应用暴露选区且授权缺失',evidenceStatus:'pending'})
  const found = await run('mem_recall',{query:'测试浏览器选中文字无法读取问题'})
  assert.equal(found.hits[0].caseId,c.caseId)
  const inbound = {role:'user',content:[{type:'text',text:'测试浏览器选中文字无法读取问题'}]}
  const decision = await ctx.waterfall('agent/pre-step', {step:1,signal:new AbortController().signal}, async () => ({kind:'enter',messages:[inbound]}))
  assert.ok(decision.messages.some(m => m.source?.plugin === 'dsh-expmem'))
  const unrelated = await ctx.waterfall('agent/pre-step', {step:1,signal:new AbortController().signal}, async () => ({kind:'enter',messages:[{role:'user',content:[{type:'text',text:'请解释远古火山喷发'}]}]}))
  assert.equal(unrelated.messages.length,1)
  assert.equal((await run('mem_list',{})).length,1)
  await run('mem_correct',{id:c.caseId,action:'delete',note:'清理模拟案例'})
  assert.equal((await run('mem_recall',{query:'测试浏览器选中文字无法读取问题'})).hits.length,0)
  assert.ok(k.claimId)
  console.log('PASS: official Loader, real tools/systemPrompt, 6 schemas; save/claim/recall/list/delete outputs validated; relevant pre-step recall and unrelated no-injection; no screen read or model call')
} finally {
  if (ctx) await ctx.fiber.dispose()
  rmSync(dir,{recursive:true,force:true})
}
