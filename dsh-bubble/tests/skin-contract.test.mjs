import test from 'node:test'
import {execFileSync} from 'node:child_process'
import {mkdtempSync,rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join,resolve} from 'node:path'
test('native skin contract bounds resources and falls back without touching conversation state',()=>{
  const folder=mkdtempSync(join(tmpdir(),'xiaoguang-skin-contract-'))
  try {
    const executable=join(folder,'checks')
    execFileSync('swiftc',['native/Skin.swift','tests/native-skin-checks.swift','-o',executable],{stdio:'pipe'})
    execFileSync(executable,[resolve('.')],{stdio:'pipe'})
  } finally {rmSync(folder,{recursive:true,force:true})}
})
