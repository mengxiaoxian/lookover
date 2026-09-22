// dsh-expmem — personal-experience memory plugin (host half).
//
// Design: the AGENT is the extractor. This plugin ships four tools
// (mem_save_case / mem_add_claim / mem_recall / mem_correct) + a bookshelf
// listing tool, plus system-prompt guidance that tells the agent WHEN to
// persist (after finishing a real task) and HOW to recall-with-conditions.
// A pre-step hook runs a lexical recall over the user's incoming message and
// injects top hits as hidden context — same injection pattern as dsh-look's
// hotkey snapshot.
import { randomUUID } from 'node:crypto'
import { MemStore, defaultMemDir } from './store.js'

export const name = 'dsh-expmem'
export const inject = ['tools', 'systemPrompt']

const RECALL_INJECT_LIMIT = 2
const RECALL_MIN_SCORE = 3 // lexical hits; below this we stay silent (anti-noise)

const PROMPT_TEXT = [
  '你装配了个人经验记忆（dsh-expmem）。它把真实解决过的问题存为「带来源的问题案例」，供以后的任务复用。',
  '',
  '什么时候保存（mem_save_case）：',
  '- 刚完成一个有复用价值的任务：做过选型比较、排障、方案评审、得出过决策',
  '- 字段务必如实：没有结果证据时 outcomeStatus 填 unknown，禁止补写结果',
  '- sources 里记录当时的真实上下文（窗口标题/URL/选中文本），来自 look 快照或用户粘贴',
  '- 每个案例最多用 mem_add_claim 抽 0–3 条经验：必须有适用条件（conditions），没有把握就填 pending',
  '',
  '什么时候召回（mem_recall）：',
  '- 新任务与旧案例可能相关时（选型、排障、重复出现的决策）',
  '- 引用旧经验时必须同时给出它的适用条件；若本次任务的约束与当时不同，要明确指出「旧结论可能不适用」',
  '- 区分「引用旧材料」与「本次新判断」：旧经验用引用格式呈现，并注明 caseId',
  '- 用户说「本次忽略历史」「这不代表我的偏好」时，用 mem_correct(action=ignore) 记录，之后不再召回',
  '',
  '纠正（mem_correct）：用户纠正、标记失效、删除时调用；删除会级联处理关联经验。',
  '',
  '诚实边界：',
  '- 系统无法因为内容出现在窗口里就声称用户读过或认可；推断要标 inferred',
  '- 没有相关旧案例时如实说「还没有相关经验」，不要硬凑',
].join('\n')

const render = (value) => [{ type: 'text', text: JSON.stringify(value, null, 2) }]
const objSchema = { type: 'object', additionalProperties: false, properties: {} }

function lastUserText(messages = []) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]
    if (m?.role !== 'user') continue
    const content = Array.isArray(m.content) ? m.content : [m.content]
    const text = content.filter((c) => typeof c === 'string' || c?.type === 'text')
      .map((c) => (typeof c === 'string' ? c : c.text)).join('\n').trim()
    if (text) return text
  }
  return null
}

const renderRecallBlock = (result) => {
  const lines = [
    '[dsh-expmem 召回的旧经验（隐藏上下文）]',
    '以下是 lexical 检索命中的历史案例。它们是当时的真实记录，不保证现在仍然适用。',
    '引用时给出适用条件；若本次任务约束与当时不同，明确提示。没有把握就当作参考而非结论。',
  ]
  for (const h of result.hits) {
    lines.push(`- caseId=${h.caseId}｜问题：${h.question}`)
    lines.push(`  选择：${h.choice ?? '—'}｜理由：${h.rationale ?? '—'}｜结果：${h.outcomeStatus}${h.outcomeNote ? `（${h.outcomeNote}）` : ''}`)
    if (h.conditionsHint.length) lines.push(`  适用条件：${h.conditionsHint.join('；')}`)
    lines.push(`  为何相关：${h.whyRelevant}`)
  }
  return lines.join('\n')
}

export function apply(ctx) {
  const store = new MemStore(process.env.MEM_DIR?.trim() || defaultMemDir())

  ctx.systemPrompt.section({
    name: 'tool:mem',
    order: (ctx.systemPrompt.getSectionOrder('TOOL_SESSION_QUERY') ?? 2300) + 20,
    text: PROMPT_TEXT,
  })

  const tool = (spec) => ctx.tools.register(spec)

  tool({
    name: 'mem_save_case',
    description:
      '把刚完成的一个有复用价值的任务保存为问题案例（选型、排障、方案评审、重要决策）。没有结果证据时 outcomeStatus 必须为 unknown，禁止编造结果。sources 记录当时的真实上下文。',
    parameters: {
      type: 'object', additionalProperties: false,
      required: ['question'],
      properties: {
        projectName: { type: 'string', description: '所属项目名；不存在会自动创建' },
        question: { type: 'string', description: '当时想解决什么问题' },
        constraints: { type: 'string', description: '当时的约束条件' },
        attempts: { type: 'string', description: '考虑/尝试过哪些选项' },
        choice: { type: 'string', description: '最后采取的选择' },
        rationale: { type: 'string', description: '选择的理由' },
        outcomeStatus: { type: 'string', enum: ['known', 'unknown', 'partial'] },
        outcomeNote: { type: 'string', description: '结果证据；仅 outcomeStatus=known 时填写' },
        sources: {
          type: 'array', description: '当时依据的来源（look 快照/用户粘贴等）',
          items: {
            type: 'object', additionalProperties: false,
            properties: {
              type: { type: 'string', enum: ['app', 'ax-selection', 'paste', 'file'] },
              title: { type: 'string' }, url: { type: 'string' },
              excerpt: { type: 'string', description: '原文摘录（≤2000字）' },
              capturedAt: { type: 'string' },
            },
          },
        },
      },
    },
    output: { schema: objSchema, render: (_a, v) => render(v) },
    isConcurrencySafe: () => false,
    async execute(args) {
      const record = await store.saveCase(args)
      return { saved: true, caseId: record.id, outcomeStatus: record.outcomeStatus, markdown: `cases/${record.id}.md` }
    },
  })

  tool({
    name: 'mem_add_claim',
    description: '从一个案例抽取一条可复用经验（最多每案例 3 条）。必须写适用条件 conditions；没有用户确认时 evidenceStatus 填 inferred 或 pending。',
    parameters: {
      type: 'object', additionalProperties: false,
      required: ['caseId', 'conclusion'],
      properties: {
        caseId: { type: 'string' },
        conclusion: { type: 'string', description: '可复用的结论/方法' },
        conditions: { type: 'string', description: '适用条件；跨出该条件时结论可能不成立' },
        counterExamples: { type: 'string', description: '已知反例' },
        evidenceStatus: { type: 'string', enum: ['user-confirmed', 'inferred', 'pending'] },
      },
    },
    output: { schema: objSchema, render: (_a, v) => render(v) },
    isConcurrencySafe: () => false,
    async execute(args) {
      const claim = await store.addClaim(args)
      return { saved: true, claimId: claim.id, status: claim.status, version: claim.version }
    },
  })

  tool({
    name: 'mem_recall',
    description: '检索与当前任务相关的旧案例与经验。返回案例摘要、来源、适用条件与为何相关。新任务涉及选型/排障/重复决策时调用。',
    parameters: {
      type: 'object', additionalProperties: false,
      required: ['query'],
      properties: {
        query: { type: 'string', description: '当前任务的问题/主题描述' },
        projectId: { type: 'string' },
        limit: { type: 'number', description: '默认 3' },
      },
    },
    output: { schema: objSchema, render: (_a, v) => render(v) },
    isConcurrencySafe: () => true,
    async execute(args) {
      return await store.recall(args.query, args)
    },
  })

  tool({
    name: 'mem_correct',
    description: '用户纠正记忆时调用：ignore（本次及以后不再召回）/ invalidate（标记失效）/ delete（删除，级联关联经验）/ revive（恢复）。',
    parameters: {
      type: 'object', additionalProperties: false,
      required: ['id', 'action'],
      properties: {
        id: { type: 'string', description: 'caseId 或 claimId' },
        action: { type: 'string', enum: ['ignore', 'invalidate', 'delete', 'revive'] },
        note: { type: 'string', description: '纠正原因，写入事件流' },
      },
    },
    output: { schema: objSchema, render: (_a, v) => render(v) },
    isConcurrencySafe: () => false,
    async execute(args) { return await store.correct(args) },
  })

  tool({
    name: 'mem_list',
    description: '列出已积累的案例（书架视图数据）：问题、选择、结果状态、复用次数、来源数。',
    parameters: {
      type: 'object', additionalProperties: false,
      properties: { projectId: { type: 'string' } },
    },
    output: { schema: objSchema, render: (_a, v) => render(v) },
    isConcurrencySafe: () => true,
    async execute(args) { return await store.list(args ?? {}) },
  })

  // ---- pre-step: lexical recall injected as hidden context -----------------
  ctx.on('agent/pre-step', async ({ step, signal }, next) => {
    const decision = await next()
    if (decision.kind === 'reject' || signal.aborted || step !== 1) return decision
    const text = lastUserText(decision.messages)
    if (!text || text.length < 6 || text.includes('[dsh-expmem')) return decision
    let result
    try { result = await store.recall(text, { limit: RECALL_INJECT_LIMIT }) } catch { return decision }
    if (!result.hits.length) return decision
    // top hit must clear the anti-noise bar; otherwise let the agent decide
    if ((result.hits[0]?.whyRelevant?.match(/命中 (\d+)/)?.[1] ?? 0) < RECALL_MIN_SCORE) return decision
    for (const h of result.hits) await store.noteReuse(h.caseId)
    return {
      ...decision,
      messages: [...decision.messages, Object.freeze({
        id: randomUUID(),
        role: 'user',
        content: [{ type: 'text', text: renderRecallBlock(result) }],
        source: { kind: 'plugin', plugin: name, form: 'memory', sections: [{ name, text: renderRecallBlock(result) }] },
      })],
    }
  }, { prepend: true })

  ctx.effect(() => () => { /* nothing long-running to stop */ }, 'dsh-expmem: loaded')
}
