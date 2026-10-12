// Window navigation is separate from task execution and presentation skins.
export class SurfaceBridge {
  constructor(sessionBridge, send, {timeoutMs = 8000} = {}) {
    this.bridge = sessionBridge; this.send = send; this.timeoutMs = timeoutMs
    this.revision = 0; this.pending = null; this.closed = false
  }
  desktop() {
    if (this.closed || this.pending) return
    const sessionId = this.bridge.selected
    if (!sessionId) return this.send({kind:'error', message:'请先新建或选择对话'})
    const revision = ++this.revision
    const timer = setTimeout(() => {
      if (this.pending?.revision !== revision) return
      this.pending = null
      this.send({kind:'error', message:'主窗口未完成会话切换，请确认官方主窗口已打开后重试'})
    }, this.timeoutMs)
    timer.unref?.()
    this.pending = {revision, sessionId, timer}
  }
  poll() { return this.pending ? {revision:this.pending.revision, sessionId:this.pending.sessionId} : null }
  ack(revision, sessionId) {
    if (this.closed || !this.pending || this.pending.revision !== revision || this.pending.sessionId !== sessionId) return false
    if (this.bridge.selected !== sessionId) {
      clearTimeout(this.pending.timer); this.pending = null
      this.send({kind:'error',message:'当前气泡会话已变化，请重新打开主窗口'}); return false
    }
    clearTimeout(this.pending.timer); this.pending = null
    this.send({kind:'surface', surface:'desktop'}); return true
  }
  async bubble(sessionId) {
    if (this.closed || !this.bridge.services.sessions.get(sessionId)) return false
    // Explicit UI navigation can load an archived session into the Host.
    this.bridge.allowedSessions.add(sessionId)
    await this.bridge.request({op:'select',sessionId})
    if (this.bridge.selected !== sessionId || this.closed) return false
    if (this.pending) clearTimeout(this.pending.timer)
    this.pending = null
    this.send({kind:'surface', surface:'bubble'}); return true
  }
  close() { this.closed = true; if (this.pending) clearTimeout(this.pending.timer); this.pending = null }
}
