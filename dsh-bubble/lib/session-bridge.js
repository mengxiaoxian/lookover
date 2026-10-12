import { randomUUID } from 'node:crypto'
const MAX_TEXT = 16000
export function visibleMessages(session) {
  return session.deriveMessages()
    .filter(m => m.role === 'assistant' || (m.role === 'user' && m.source?.kind === 'user'))
    .map(m => ({ role: m.role, text: (m.content ?? []).filter(p => p.type === 'text').map(p => p.text).join('').slice(-MAX_TEXT) }))
    .filter(m => m.text)
    .slice(-40)
    .reverse().reduce((state, message) => {
      if (state.remaining > 0) {
        const text = message.text.slice(-state.remaining)
        state.messages.unshift({...message, text}); state.remaining -= text.length
      }
      return state
    }, {messages:[], remaining:24000}).messages
}
// Business state has no dependency on the native window or its skin.
export class SessionBridge {
  constructor(services, publish, options = {}) {
    this.services = services
    this.publish = publish
    this.selected = options.sessionId ?? services.sessions.list().at(-1)?.id ?? null
    this.followNew = !options.sessionId
    this.inFlight = false
    this.closed = false
    this.partials = new Map()
    this.revision = 0
    this.allowedSessions = new Set(services.sessions.list().map(s => s.id))
    this.abort = new AbortController()
  }
  snapshot() {
    const session = this.selected && this.services.sessions.get(this.selected)
    const messages = session ? visibleMessages(session) : []
    const running = this.selected ? this.services.agents.get(this.selected)?.status === 'running' : false
    return { kind: 'snapshot', revision: ++this.revision, sessionId: this.selected,
      messages, text: messages.map(m => m.text).join('\n'), messageCount: messages.length,
      partial: this.partials.get(this.selected)?.text ?? '', running, pending: this.inFlight,
      sessions: this.services.sessions.list().map((s, i) => ({ id: s.id, title: titleFor(s, i) })) }
  }
  refresh() { if (!this.closed) this.publish(this.snapshot()) }
  created(session) {
    this.allowedSessions.add(session.id)
    if (this.followNew && !this.inFlight) this.selected = session.id
    this.refresh()
  }
  event(session, event) {
    if (session.id !== this.selected) return
    if (event.type === 'assistant/message') this.partials.delete(session.id)
    if (['user/message', 'assistant/message', 'turn/start', 'turn/end', 'session/title', 'agent/title'].includes(event.type)) this.refresh()
  }
  stream(agent, frame) {
    if (!agent || !frame) return
    const id = agent.id
    if (frame.type === 'start') this.partials.set(id, { attemptId: frame.attemptId, revision: frame.revision, text: '' })
    else if (frame.type === 'chunk') {
      const partial = this.partials.get(id)
      if (!partial || partial.attemptId !== frame.attemptId || frame.revision <= partial.revision) return
      partial.revision = frame.revision
      if (frame.chunk?.type === 'text-delta' && typeof frame.chunk.text === 'string') partial.text = (partial.text + frame.chunk.text).slice(-MAX_TEXT)
    } else if (frame.type === 'end') this.partials.delete(id)
    if (id === this.selected) this.refresh()
  }
  async request(message) {
    if (this.closed) return
    const requestId = typeof message.requestId === 'string' ? message.requestId.slice(0, 128) : randomUUID()
    let ownsFlight = false
    const target = this.selected
    const reply = result => { if (!this.closed) this.publish({kind: 'receipt', requestId, sessionId: target, ...result}) }
    try {
      if (!['read', 'send', 'cancel', 'new', 'select'].includes(message.op)) throw new Error('不支持的操作')
      if (!['new', 'select'].includes(message.op) && message.sessionId !== target) throw new Error('会话已切换，请重试')
      if (message.op === 'read') { this.refresh(); return }
      if (this.inFlight) throw new Error('操作处理中，请稍候')
      if (message.op === 'select') {
        if (!this.allowedSessions.has(message.sessionId)) throw new Error('会话不存在')
        if (!this.services.sessions.get(message.sessionId)) throw new Error('此会话尚未加载，请先在主窗口打开')
        this.selected = message.sessionId
        this.refresh(); reply({ok: true}); return
      }
      if (message.op === 'new') {
        ownsFlight = true; this.inFlight = true; this.refresh()
        const result = await this.services.controller.create({}, this.abort.signal)
        this.selected = result.sessionId
        this.allowedSessions.add(result.sessionId)
        reply({ok: true}); return
      }
      if (!target || !this.services.sessions.get(target)) throw new Error('请先新建或选择一个会话')
      if (message.op === 'cancel') {
        await this.services.controller.cancel({ sessionId: target }, this.abort.signal)
        reply({ok: true}); return
      }
      if (typeof message.text !== 'string' || !message.text.trim()) throw new Error('请输入消息')
      if (message.text.length > MAX_TEXT) throw new Error('消息太长，请缩短到 16000 字以内')
      if (this.services.agents.get(target)?.status === 'running') throw new Error('任务正在运行，请等待完成或先停止')
      ownsFlight = true; this.inFlight = true; this.refresh()
      await this.services.controller.prompt({ sessionId: target, requestId,
        mode: 'queue', content: [{type:'text', text:message.text}],
        clientTimeZone: Intl.DateTimeFormat().resolvedOptions().timeZone }, this.abort.signal)
      reply({ok: true})
    } catch (error) {
      reply({ok: false, error: error instanceof Error ? error.message : String(error)})
    } finally { if (ownsFlight) this.inFlight = false; this.refresh() }
  }
  close() { this.closed = true; this.abort.abort(); this.partials.clear() }
}
function titleFor(session, index) {
  const events = session.snapshotEvents?.() ?? session.events ?? []
  const titled = [...events].reverse().find(e => (e.type === 'session/title' || e.type === 'agent/title') && typeof e.data?.title === 'string')
  if (titled) return titled.data.title.slice(0, 40)
  const first = visibleMessages(session).find(m => m.role === 'user')
  return first?.text.slice(0, 28) ?? `会话 ${index + 1}`
}
