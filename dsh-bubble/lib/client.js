window.__ModuleLoader__.load({
  id:'dsh-bubble',
  factory(require) {
    const React = require('react')
    const inject = ['slots','uiWorkspace']
    function apply(ctx) {
      // Only the official local desktop renderer participates in window switching.
      if (location.protocol !== 'dsh-app:') return
      const lifetime = new AbortController()
      let timer, disposed = false, navigationRevision = 0
      async function call(body) {
        const response = await fetch('/api/xiaoguang/window', {method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body),signal:lifetime.signal})
        if (!response.ok) throw new Error('窗口连接暂不可用')
        return response.json()
      }
      async function poll() {
        try {
          const {navigation} = await call({op:'poll'})
          if (navigation && navigation.revision !== navigationRevision) {
            ctx.uiWorkspace.openSession(navigation.sessionId)
            const deadline = Date.now()+6500
            while (!disposed && Date.now()<deadline && ctx.uiWorkspace.selection.getSnapshot().sessionId !== navigation.sessionId) {
              await new Promise(resolve => setTimeout(resolve,50))
            }
            if (!disposed && ctx.uiWorkspace.selection.getSnapshot().sessionId === navigation.sessionId) {
              await call({op:'ack', ...navigation}); navigationRevision = navigation.revision
            }
          }
        } catch(error) { if (!disposed) console.debug('[xiaoguang] window connection waiting') }
        finally { if (!disposed) timer = setTimeout(poll,500) }
      }
      function ReturnButton() {
        const [pending,setPending] = React.useState(false)
        const [error,setError] = React.useState('')
        return React.createElement('button', {
          type:'button',title:error || '继续当前对话，切换到悬浮气泡', 'aria-label':'切回气泡',disabled:pending,
          style:{border:'1px solid var(--dsw-alias-border-l1)',borderRadius:8,padding:'5px 10px',background:'transparent',color:'inherit',cursor:'pointer',fontSize:13},
          onClick:async () => {
            setPending(true);setError('')
            try {
              const sessionId = ctx.uiWorkspace.selection.getSnapshot().sessionId
              const result = await call({op:'bubble',sessionId})
              if (!result.ok) throw new Error('当前会话尚未准备好，请稍后重试')
              // Standard renderer close follows the official close-to-background policy.
              window.close()
            } catch(error) {setError(error.message)} finally {setPending(false)}
          }
        }, error ? '切回失败 · 重试' : pending ? '切换中…' : '切回气泡')
      }
      ctx.slots.inject('conversation.session.header.actions', () => ctx.slots.register({name:'conversation.session.header.actions',id:'xiaoguang-return',order:100},ReturnButton))
      ctx.effect(() => {
        void poll()
        return () => {disposed=true;clearTimeout(timer);lifetime.abort()}
      })
    }
    return {inject,apply}
  }
})
