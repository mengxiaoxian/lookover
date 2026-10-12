import test from 'node:test'
import {execFileSync} from 'node:child_process'
import {mkdtempSync,rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
test('native Markdown preserves code and emoji, styles prose and stays safe while streaming',()=>{
  const folder=mkdtempSync(join(tmpdir(),'dsh-bubble-markdown-'))
  try {
    const executable=join(folder,'checks')
    execFileSync('swiftc',['native/Skin.swift','native/MessageMarkdown.swift','native/MessageList.swift','tests/native-markdown-checks.swift','-o',executable],{stdio:'pipe'})
    execFileSync(executable,[],{stdio:'pipe'})
  } finally {rmSync(folder,{recursive:true,force:true})}
})
