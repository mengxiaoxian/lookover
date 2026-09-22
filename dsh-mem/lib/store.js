// dsh-mem — storage layer (demo grade).
//
// Five object kinds (MVP subset of the 2026-09-21 PRD §6):
//   Project / Case / Source(embedded in Case) / Claim / Event(append-only).
// Storage: JSONL under MEM_DIR (default ~/.dsh/mem, demo overrides), plus a
// human-readable Markdown export per case. The search index is computed in
// memory on load — storage files are the only source of truth (rebuildable).
import { randomUUID } from 'node:crypto'
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const OUTCOME_STATUS = ['known', 'unknown', 'partial']
const EVIDENCE_STATUS = ['user-confirmed', 'inferred', 'pending']
const CLAIM_STATUS = ['candidate', 'active', 'invalid', 'superseded']

export function defaultMemDir() {
  if (process.env.MEM_DIR?.trim()) return process.env.MEM_DIR.trim()
  if (process.env.DSH_HOME?.trim()) return join(process.env.DSH_HOME.trim(), 'mem')
  return join(homedir(), '.dsh', 'mem')
}

const nowId = (prefix) => `${prefix}_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`

async function readJsonl(file, fallback) {
  if (!existsSync(file)) return fallback
  const text = await readFile(file, 'utf8')
  return text.split('\n').filter(Boolean).map((line) => JSON.parse(line))
}

async function writeJsonl(file, rows) {
  await mkdir(dirnameOf(file), { recursive: true })
  await writeFile(file, rows.map((r) => JSON.stringify(r)).join('\n') + '\n', 'utf8')
}

const dirnameOf = (file) => file.slice(0, file.lastIndexOf('/')) || '.'

// ---- tokenizer: latin words + CJK bigrams (demo-grade lexical scoring) ----
export function tokenize(text) {
  const chunks = String(text ?? '').toLowerCase().split(/[^a-z0-9\u4e00-\u9fff]+/).filter(Boolean)
  const tokens = new Set()
  for (const chunk of chunks) {
    if (/^[\u4e00-\u9fff]+$/.test(chunk)) {
      if (chunk.length <= 2) tokens.add(chunk)
      else for (let i = 0; i + 2 <= chunk.length; i++) tokens.add(chunk.slice(i, i + 2))
    } else {
      tokens.add(chunk)
    }
  }
  return [...tokens]
}

export class MemStore {
  constructor(dir = defaultMemDir()) {
    this.dir = dir
    this.files = {
      projects: join(dir, 'projects.jsonl'),
      cases: join(dir, 'cases.jsonl'),
      claims: join(dir, 'claims.jsonl'),
      events: join(dir, 'events.jsonl'),
      state: join(dir, 'state.json'),
    }
    this.loaded = false
    this.projects = []
    this.cases = []
    this.claims = []
    this.events = []
    this.ignored = {} // id -> { ts, note }
  }

  async load() {
    if (this.loaded) return this
    this.projects = await readJsonl(this.files.projects, [])
    this.cases = await readJsonl(this.files.cases, [])
    this.claims = await readJsonl(this.files.claims, [])
    this.events = await readJsonl(this.files.events, [])
    if (existsSync(this.files.state)) {
      try { this.ignored = JSON.parse(await readFile(this.files.state, 'utf8')).ignored ?? {} } catch { this.ignored = {} }
    }
    this.loaded = true
    return this
  }

  async persist() {
    await writeJsonl(this.files.projects, this.projects)
    await writeJsonl(this.files.cases, this.cases)
    await writeJsonl(this.files.claims, this.claims)
    await writeFile(this.files.state, JSON.stringify({ ignored: this.ignored }, null, 2), 'utf8')
  }

  async logEvent(action, targetId, note, actor = 'agent') {
    this.events.push({ id: nowId('e'), ts: new Date().toISOString(), actor, action, targetId, note: note ?? null })
    await writeJsonl(this.files.events, this.events)
  }

  // ---- Project -------------------------------------------------------------
  async ensureProject(name) {
    await this.load()
    const found = this.projects.find((p) => p.name === name)
    if (found) return found
    const project = { id: nowId('p'), name, status: 'active', createdAt: new Date().toISOString() }
    this.projects.push(project)
    await this.persist()
    await this.logEvent('project.create', project.id, name)
    return project
  }

  // ---- Case (C2) -----------------------------------------------------------
  async saveCase(input) {
    await this.load()
    if (!input?.question || typeof input.question !== 'string') throw new Error('case.question is required')
    const outcomeStatus = OUTCOME_STATUS.includes(input.outcomeStatus) ? input.outcomeStatus : 'unknown'
    const sources = (Array.isArray(input.sources) ? input.sources : []).map((s) => ({
      id: nowId('s'),
      type: s?.type ?? 'app',
      title: s?.title ?? null,
      url: s?.url ?? null,
      excerpt: typeof s?.excerpt === 'string' ? s.excerpt.slice(0, 2000) : null,
      capturedAt: s?.capturedAt ?? new Date().toISOString(),
    }))
    const project = input.projectName
      ? await this.ensureProject(input.projectName)
      : this.projects.find((p) => p.id === input.projectId) ?? null
    const record = {
      id: nowId('c'),
      projectId: project?.id ?? null,
      question: input.question,
      constraints: input.constraints ?? null,
      attempts: input.attempts ?? null,
      choice: input.choice ?? null,
      rationale: input.rationale ?? null,
      outcomeStatus,
      outcomeNote: outcomeStatus === 'known' ? (input.outcomeNote ?? null) : null,
      sources,
      status: outcomeStatus === 'known' ? 'resolved' : 'open',
      occurredAt: input.occurredAt ?? new Date().toISOString(),
      recordedAt: new Date().toISOString(),
      version: 1,
      supersededBy: null,
      reuseCount: 0,
      lastReusedAt: null,
    }
    this.cases.push(record)
    await this.persist()
    await this.exportCaseMd(record)
    await this.logEvent('case.create', record.id, record.question.slice(0, 80))
    return record
  }

  async exportCaseMd(record) {
    const dir = join(this.dir, 'cases')
    await mkdir(dir, { recursive: true })
    const claims = this.claims.filter((k) => k.caseId === record.id)
    const fm = [
      '---',
      `id: ${record.id}`,
      `projectId: ${record.projectId ?? 'null'}`,
      `status: ${record.status}`,
      `outcome: ${record.outcomeStatus}`,
      `occurredAt: ${record.occurredAt}`,
      `version: ${record.version}`,
      '---',
      '',
    ].join('\n')
    const body = [
      `# ${record.question}`,
      '',
      record.constraints ? `**约束：** ${record.constraints}` : null,
      record.attempts ? `**尝试：** ${record.attempts}` : null,
      record.choice ? `**选择：** ${record.choice}` : null,
      record.rationale ? `**理由：** ${record.rationale}` : null,
      `**结果：** ${record.outcomeStatus}${record.outcomeNote ? ` — ${record.outcomeNote}` : ''}`,
      '',
      '## 来源',
      ...(record.sources.length
        ? record.sources.map((s) => `- [${s.type}] ${s.title ?? s.url ?? 'untitled'}${s.excerpt ? `「${s.excerpt.slice(0, 120)}」` : ''} @${s.capturedAt}`)
        : ['- （无来源记录）']),
      '',
      '## 经验（Claim）',
      ...(claims.length
        ? claims.map((k) => `- (${k.evidenceStatus}/${k.status}) ${k.conclusion}｜适用条件：${k.conditions ?? '未注明'}${k.counterExamples ? `｜反例：${k.counterExamples}` : ''}`)
        : ['- （暂无）']),
      '',
    ].filter((x) => x !== null).join('\n')
    await writeFile(join(dir, `${record.id}.md`), fm + body, 'utf8')
  }

  // ---- Claim (C3) ----------------------------------------------------------
  async addClaim(input) {
    await this.load()
    const record = this.cases.find((c) => c.id === input?.caseId)
    if (!record) throw new Error(`case not found: ${input?.caseId}`)
    const evidenceStatus = EVIDENCE_STATUS.includes(input.evidenceStatus) ? input.evidenceStatus : 'pending'
    // naive dedupe: same conclusion text on same case -> bump version instead of new
    const dup = this.claims.find((k) => k.caseId === record.id && k.conclusion === input.conclusion)
    if (dup) {
      dup.version += 1
      dup.conditions = input.conditions ?? dup.conditions
      dup.counterExamples = input.counterExamples ?? dup.counterExamples
      dup.evidenceStatus = input.evidenceStatus ?? dup.evidenceStatus
      await this.persist()
      await this.exportCaseMd(record)
      await this.logEvent('claim.revise', dup.id, 'dedupe bump')
      return dup
    }
    const claim = {
      id: nowId('k'),
      caseId: record.id,
      projectId: record.projectId,
      conclusion: input.conclusion,
      conditions: input.conditions ?? null,
      counterExamples: input.counterExamples ?? null,
      evidenceStatus,
      status: evidenceStatus === 'user-confirmed' ? 'active' : 'candidate',
      version: 1,
      createdAt: new Date().toISOString(),
    }
    this.claims.push(claim)
    await this.persist()
    await this.exportCaseMd(record)
    await this.logEvent('claim.create', claim.id, claim.conclusion.slice(0, 80))
    return claim
  }

  // ---- Recall (C4) ---------------------------------------------------------
  async recall(query, opts = {}) {
    await this.load()
    const qTokens = new Set(tokenize(query))
    if (!qTokens.size) return { hits: [] }
    const scored = []
    for (const c of this.cases) {
      if (c.supersededBy || this.ignored[c.id]) continue
      if (opts.projectId && c.projectId && c.projectId !== opts.projectId) continue
      const hay = [c.question, c.constraints, c.attempts, c.choice, c.rationale].map(tokenize)
      let score = 0
      const hitFields = []
      hay.forEach((tokens, i) => {
        const hits = tokens.filter((t) => qTokens.has(t)).length
        if (hits) { score += hits; hitFields.push(['question', 'constraints', 'attempts', 'choice', 'rationale'][i]) }
      })
      const claims = this.claims.filter((k) => k.caseId === c.id && !this.ignored[k.id] && k.status !== 'invalid')
      for (const k of claims) {
        score += tokenize(k.conclusion).filter((t) => qTokens.has(t)).length
      }
      if (score >= 2) scored.push({ case: c, claims, score, hitFields })
    }
    scored.sort((a, b) => b.score - a.score)
    const top = scored.slice(0, opts.limit ?? 3)
    return {
      hits: top.map(({ case: c, claims, score, hitFields }) => ({
        caseId: c.id,
        projectId: c.projectId,
        question: c.question,
        choice: c.choice,
        rationale: c.rationale,
        outcomeStatus: c.outcomeStatus,
        outcomeNote: c.outcomeNote,
        conditionsHint: claims.map((k) => k.conditions).filter(Boolean),
        claims: claims.map((k) => ({ id: k.id, conclusion: k.conclusion, conditions: k.conditions, evidenceStatus: k.evidenceStatus, status: k.status })),
        sources: c.sources.map((s) => ({ type: s.type, title: s.title, url: s.url, capturedAt: s.capturedAt })),
        whyRelevant: `命中字段：${hitFields.join('/')}；词元命中 ${score}`,
        recordedAt: c.recordedAt,
      })),
    }
  }

  async noteReuse(caseId) {
    await this.load()
    const c = this.cases.find((x) => x.id === caseId)
    if (!c) return
    c.reuseCount += 1
    c.lastReusedAt = new Date().toISOString()
    await this.persist()
    await this.logEvent('case.reuse', caseId, null, 'agent')
  }

  // ---- Correct / ignore / delete (C5) ---------------------------------------
  async correct(input) {
    await this.load()
    const { id, action, note } = input ?? {}
    const actions = { ignore: 1, invalidate: 1, delete: 1, revive: 1 }
    if (!actions[action]) throw new Error(`action must be one of ignore|invalidate|delete|revive`)
    const caseRow = this.cases.find((c) => c.id === id)
    const claimRow = this.claims.find((k) => k.id === id)
    const target = caseRow ?? claimRow
    if (!target) throw new Error(`object not found: ${id}`)
    if (action === 'ignore') {
      this.ignored[id] = { ts: new Date().toISOString(), note: note ?? null }
    } else if (action === 'revive') {
      delete this.ignored[id]
      if (claimRow) claimRow.status = 'candidate'
    } else if (action === 'invalidate') {
      if (claimRow) claimRow.status = 'invalid'
      if (caseRow) caseRow.status = 'invalid'
    } else if (action === 'delete') {
      if (caseRow) {
        // cascade: claims lose their source case -> marked superseded-source
        for (const k of this.claims) {
          if (k.caseId === caseRow.id) {
            k.status = 'invalid'
            k.counterExamples = [k.counterExamples, '来源案例已删除'].filter(Boolean).join('；')
          }
        }
        this.cases = this.cases.filter((c) => c.id !== caseRow.id)
        await this.persist()
        await this.logEvent('case.delete', id, note)
        return { deleted: 'case', cascadedClaims: this.claims.filter((k) => k.caseId === id).map((k) => k.id) }
      }
      if (claimRow) this.claims = this.claims.filter((k) => k.id !== claimRow.id)
    }
    await this.persist()
    if (caseRow) await this.exportCaseMd(caseRow)
    await this.logEvent(`${(caseRow ? 'case' : 'claim')}.${action}`, id, note ?? null, 'user')
    return { ok: true, id, action }
  }

  // ---- Bookshelf (C6) -------------------------------------------------------
  async list(opts = {}) {
    await this.load()
    return this.cases
      .filter((c) => (opts.projectId ? c.projectId === opts.projectId : true) && !this.ignored[c.id])
      .map((c) => ({
        caseId: c.id,
        projectId: c.projectId,
        question: c.question,
        choice: c.choice,
        outcomeStatus: c.outcomeStatus,
        status: c.status,
        reuseCount: c.reuseCount,
        lastReusedAt: c.lastReusedAt,
        claimCount: this.claims.filter((k) => k.caseId === c.id).length,
        sourceCount: c.sources.length,
        recordedAt: c.recordedAt,
      }))
  }

  async stats() {
    await this.load()
    const files = existsSync(join(this.dir, 'cases')) ? await readdir(join(this.dir, 'cases')) : []
    return {
      projects: this.projects.length,
      cases: this.cases.length,
      claims: this.claims.length,
      events: this.events.length,
      markdownFiles: files.length,
      ignored: Object.keys(this.ignored).length,
    }
  }
}
