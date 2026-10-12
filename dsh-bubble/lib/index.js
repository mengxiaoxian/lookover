import { appendFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { StringDecoder } from 'node:string_decoder'
import { fileURLToPath } from 'node:url'
import { SessionBridge } from './session-bridge.js'
import { SurfaceBridge } from './surface-bridge.js'
export const inject = ['sessions', 'sessionController', 'agents']
export function apply(ctx, config = {}) {
  let stopped = false, snapshotTimer
  const args = ['--skins-dir', fileURLToPath(new URL('../skins/', import.meta.url)), ...(config.skinPath ? ['--skin', config.skinPath] : [])]
  // The official desktop Host is a direct child of this specific Electron app.
  if (process.execPath.includes('.app/Contents/')) args.push('--desktop-pid', String(process.ppid), '--desktop-path', process.execPath.split('/Contents/')[0])
  const child = spawn(fileURLToPath(new URL('../bin/Xiaoguang Companion.app/Contents/MacOS/xiaoguang-helper', import.meta.url)), args,
    {stdio:['pipe','pipe','pipe'], env:{PATH:'/usr/bin:/bin',LANG:'en_US.UTF-8'}})
  function send(value) {
    if (stopped || !child.stdin.writable) return
    const payload = JSON.stringify(value)
    if (Buffer.byteLength(payload) > 262144 || child.stdin.writableLength > 524288) { child.kill(); return }
    child.stdin.write(payload + '\n')
  }
  const bridge = new SessionBridge({sessions:ctx.sessions, controller:ctx.sessionController, agents:ctx.agents}, value => {
    if (value.kind !== 'snapshot') return send(value)
    // Coalesce model updates; only the current projection crosses the pipe.
    if (!snapshotTimer) snapshotTimer = setTimeout(() => {
      snapshotTimer = undefined
      send(bridge.snapshot())
    }, 50)
  }, config)
  const surface = new SurfaceBridge(bridge, send)
  ctx.inject(['connection'], connectionCtx => {
    connectionCtx.connection.fetch.register({
      path:'/api/xiaoguang/window', methods:['POST'], requestBody:'buffered',
      async fetch(request) {
        if (Number(request.headers.get('content-length')) > 4096) return new Response('too large', {status:413})
        const text = await request.text()
        if (text.length > 4096) return new Response('too large', {status:413})
        let body
        try { body = JSON.parse(text) } catch { return new Response('invalid JSON', {status:400}) }
        let result
        if (body.op === 'poll') result = {navigation:surface.poll()}
        else if (body.op === 'ack') result = {ok:surface.ack(body.revision, body.sessionId)}
        else if (body.op === 'bubble') result = {ok:await surface.bubble(body.sessionId)}
        else return new Response('unknown operation', {status:400})
        return Response.json(result)
      }
    })
  })
  const decoder = new StringDecoder('utf8')
  let buffered = ''
  child.stdout.on('data', bytes => {
    buffered += decoder.write(bytes)
    if (Buffer.byteLength(buffered) > 262144) { child.kill(); return }
    let end
    while ((end = buffered.indexOf('\n')) !== -1) {
      const line = buffered.slice(0,end); buffered = buffered.slice(end+1)
      let message
      try { message = JSON.parse(line) } catch { continue }
      if (!message || typeof message !== 'object') continue
      if (message.kind === 'request') void bridge.request(message)
      if (message.kind === 'surface-request' && message.surface === 'desktop') surface.desktop()
      if (config.diagnosticsPath) {
        const {kind,op,skin,running,messageCount,partialLength,pid,width,height,requestId,surface,x,y} = message
        appendFileSync(config.diagnosticsPath, JSON.stringify({time:Date.now(),kind,op,skin,running,messageCount,partialLength,pid,width,height,requestId,surface,x,y}) + '\n')
      }
      ctx.emit('xiaoguang-proof/message', message)
    }
  })
  child.on('error', error => ctx.emit('xiaoguang-proof/error', error.message))
  child.stdin.on('error', () => {})
  child.stderr.on('data', () => {})
  child.on('exit', (code, signal) => {
    bridge.close(); surface.close(); clearTimeout(snapshotTimer)
    ctx.emit('xiaoguang-proof/exit', {code,signal})
  })
  ctx.on('session/created', session => bridge.created(session))
  ctx.on('session/disposed', session => {
    bridge.allowedSessions.delete(session.id)
    if (bridge.selected === session.id) bridge.selected = null
    bridge.refresh()
  })
  ctx.on('session/event', (session,event) => bridge.event(session,event))
  ctx.on('agent/assistant-stream', ({agent,frame}) => bridge.stream(agent,frame))
  ctx.on('agent/status', ({agent}) => { if (agent.id === bridge.selected) bridge.refresh() })
  ctx.on('agent/error', ({agent,error}) => {
    if (agent.id === bridge.selected) send({kind:'error',message:error?.message ?? '任务执行失败，请查看主窗口'})
  })
  ctx.on('xiaoguang-proof/control', command => {
    if (['expand','collapse','capture','probe','surface'].includes(command.kind)) send(command)
    else if (command.kind === 'select') void bridge.request({op:'select',sessionId:command.sessionId})
  })
  ctx.effect(() => () => {
    stopped = true; bridge.close(); surface.close(); clearTimeout(snapshotTimer)
    child.stdin.end()
    const timer = setTimeout(() => child.kill('SIGTERM'),1500)
    timer.unref(); child.once('exit', () => clearTimeout(timer))
  })
  ctx.emit('xiaoguang-proof/spawn', {pid:child.pid})
  bridge.refresh()
}
