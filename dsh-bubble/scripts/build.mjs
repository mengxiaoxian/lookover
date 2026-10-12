import { mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
const contents = 'bin/Xiaoguang Companion.app/Contents'
mkdirSync(`${contents}/MacOS`, {recursive:true})
writeFileSync(`${contents}/Info.plist`, `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.menke.xiaoguang.companion.proof</string><key>CFBundleExecutable</key><string>xiaoguang-helper</string><key>CFBundleName</key><string>Xiaoguang Companion</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>9</string><key>LSUIElement</key><true/></dict></plist>`)
execFileSync('swiftc',['-O','native/Skin.swift','native/MessageList.swift','native/ConversationWindow.swift','native/WindowCoordinator.swift','native/main.swift','-o',`${contents}/MacOS/xiaoguang-helper`])
execFileSync('codesign',['--force','--sign','-','bin/Xiaoguang Companion.app'])
rmSync('bin/xiaoguang-helper',{force:true})
