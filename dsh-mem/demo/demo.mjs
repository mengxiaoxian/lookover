// dsh-mem demo — runs the E2–E5 acceptance script WITHOUT the DSH host.
// Simulates the full pipeline against the real store + a fake look snapshot.
//
//   node demo/demo.mjs           (or: npm run demo)
//
// Scenario mirrors PRD §9:
//   E2  case sinks with honest unknown outcome + sourced
//   E3  recall in a NEW task surfaces the old case WITH condition-change hint
//   E4  correction (ignore / delete) takes effect on subsequent recall
//   E5  bookshelf listing shows reuse counts
import { MemStore } from '../lib/store.js'
import { rmSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const DATA = join(dirname(fileURLToPath(import.meta.url)), 'data')
if (existsSync(DATA)) rmSync(DATA, { recursive: true, force: true })

const ok = (name, cond, detail = '') => {
  if (!cond) { console.error(`✗ ${name} ${detail}`); process.exitCode = 1 }
  else console.log(`✓ ${name}${detail ? ` — ${detail}` : ''}`)
}

const store = await new MemStore(DATA).load()
const T0 = '2026-09-18T10:00:00+08:00'

// ---- E2: a real task two days ago (storage 选型) ---------------------------
const snap = { // 模拟 look 快照（ax 档）
  app: 'Google Chrome', title: 'SQLite vs JSONL for local-first apps · 讨论',
  url: 'https://example.com/db-choice',
  selected: '单机单人场景下 JSONL 足够，索引可以重建',
}
const c1 = await store.saveCase({
  projectName: 'dsh-mem 方案验证',
  question: '本地记忆存储选型：结构化状态 + 可读内容怎么存',
  constraints: '单机单人，macOS，数据量小（百级案例），索引必须可重建',
  attempts: '考虑过 SQLite、JSONL、图数据库',
  choice: 'JSONL 存状态 + Markdown 存正文 + 内存重建索引',
  rationale: '索引是派生物可重建；可读性优先；规模小无需图数据库',
  outcomeStatus: 'unknown', // 尚无上线证据 —— 诚实标注
  sources: [
    { type: 'ax-selection', title: snap.title, url: snap.url, excerpt: snap.selected, capturedAt: T0 },
  ],
  occurredAt: T0,
})
ok('E2a 案例落库', !!c1.id, `caseId=${c1.id}`)
ok('E2b 无结果证据标 unknown', c1.outcomeStatus === 'unknown' && c1.outcomeNote === null)

const k1 = await store.addClaim({
  caseId: c1.id,
  conclusion: '小规模个人记忆用 JSONL+Markdown 优于图数据库',
  conditions: '单机单人、百级记录、索引可重建的前提下',
  evidenceStatus: 'pending',
})
ok('E2c 经验带适用条件', !!k1.conditions && k1.status === 'candidate')

const md = existsSync(join(DATA, 'cases', `${c1.id}.md`))
ok('E2d Markdown 导出', md)

// ---- E3: NEW task, constraints changed (多端同步) ---------------------------
const r1 = await store.recall('新任务：记忆存储要支持多端同步和多人协作，选型怎么定', { limit: 3 })
ok('E3a 召回命中旧案例', r1.hits.length >= 1 && r1.hits[0].caseId === c1.id, `hits=${r1.hits.length}`)
const hit = r1.hits[0]
ok('E3b 召回带适用条件', hit.conditionsHint.some((c) => c.includes('单机单人')),
  '条件提示包含「单机单人」→ 代理应提示多端场景下旧结论可能不适用')
ok('E3c 结果状态如实传递', hit.outcomeStatus === 'unknown')
ok('E3d 来源可回溯', hit.sources.some((s) => s.title === snap.title))

await store.noteReuse(hit.caseId)

// ---- 干扰项：无关案例不应淹没相关案例 ----------------------------------------
await store.saveCase({
  projectName: 'dsh-mem 方案验证',
  question: 'Chrome 无障碍树默认不构建需要手动唤醒',
  attempts: '设 AXManualAccessibility 参数',
  choice: '探测时顺手设置，报错也无妨',
  rationale: '探测本身就能触发树构建',
  outcomeStatus: 'known', outcomeNote: '实测有效',
  sources: [{ type: 'app', title: 'AXManualAccessibility docs' }],
})
const r2 = await store.recall('Chrome 页面选中文本读不到怎么办', { limit: 3 })
ok('E3e 无关查询不误召回存储案例', !(r2.hits.length && r2.hits[0].question.includes('存储选型')), `top=${r2.hits[0]?.question.slice(0, 18)}…`)

// ---- E4: correction takes effect ---------------------------------------------
await store.correct({ id: k1.id, action: 'ignore', note: '用户：这不代表我的长期偏好' })
const r3 = await store.recall('记忆存储选型 多端同步', { limit: 3 })
ok('E4a ignore 后该经验不再出现在召回', r3.hits.every((h) => !h.claims.some((k) => k.id === k1.id)))

const del = await store.correct({ id: c1.id, action: 'delete', note: '清理测试' })
ok('E4b 删除级联关联经验', del.cascadedClaims.includes(k1.id), `cascaded=${del.cascadedClaims.join(',')}`)
const r4 = await store.recall('记忆存储选型', { limit: 3 })
ok('E4c 删除后不再召回', r4.hits.every((h) => h.caseId !== c1.id))

// ---- E5: bookshelf ------------------------------------------------------------
const shelf = await store.list({})
ok('E5 书架列出剩余案例', shelf.length === 1 && shelf[0].sourceCount === 1)

// ---- stats --------------------------------------------------------------------
console.log('\n数据目录：', DATA)
console.log(JSON.stringify(await store.stats(), null, 2))
console.log('\n事件流（纠正留痕）：')
for (const e of store.events.filter((e) => e.action.includes('ignore') || e.action.includes('delete'))) {
  console.log(`  ${e.ts} ${e.actor} ${e.action} -> ${e.targetId} ${e.note ?? ''}`)
}
