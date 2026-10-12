import test from 'node:test'
import {execFileSync} from 'node:child_process'
import {mkdtempSync,rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
test('native editor receives pointer focus and message glyphs fit their view',()=>{
  const folder=mkdtempSync(join(tmpdir(),'xiaoguang-layout-contract-'))
  try {
    const executable=join(folder,'checks')
    execFileSync('swiftc',['native/Skin.swift','native/MessageMarkdown.swift','native/MessageList.swift','native/ConversationWindow.swift','tests/native-layout-checks.swift','-o',executable],{stdio:'pipe'})
    execFileSync(executable,[],{stdio:'pipe'})
  } finally {rmSync(folder,{recursive:true,force:true})}
})
