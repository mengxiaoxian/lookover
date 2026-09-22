// look: frontmost-window probe for DSH (M0 + M3).
//
// Prints a single-line JSON describing the frontmost window that does NOT
// belong to the calling app (DSH itself). CGWindowListCopyWindowInfo with
// .optionOnScreenOnly returns windows front-to-back, so skipping our own
// windows yields the app the user was using right before they focused DSH.
//
// Two fidelity tiers:
//   - "app" (zero permission): app / bundleId / pid / windowId / bounds / layer.
//   - "ax"  (Accessibility granted): + window title, document, selected text,
//     focused-element text — read via AXUIElement, best-effort, char-capped.
//
// Subcommands:
//   (default)            one-shot frontmost-window probe (see below)
//   watch                long-lived Carbon global hotkey watcher; emits
//                        {"event":"hotkey"} lines on each press
//   activate-self        bring the DSH app (by bundle id) to the front
//
// Usage: look [--self-bundle <b>] [--self-pid <n>] [--max-chars <n>]
//             watch [--key-code <n>] [--modifiers <n>]
//             activate-self --self-bundle <b>

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Vision

var selfBundle: String? = nil
var selfPid: Int = -1
var maxChars = 4000
var ocrRequested = false
var pickText: String? = nil
var keyCode = UInt32(6)         // kVK_ANSI_Z — rides DSH's own ⌥⌘Z toggle
var newKeyCode = UInt32(45)     // kVK_ANSI_N — ⌥⌘N = start a new session
var dryRun = false
var waitSeconds = 3.5
var modifiers = UInt32(2304)    // optionKey(0x800) | cmdKey(0x100), Carbon-style reporting only
var args = Array(CommandLine.arguments.dropFirst())
let command = args.first?.hasPrefix("--") == false ? args.removeFirst() : ""
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--self-bundle", let v = args.first { selfBundle = v; args.removeFirst() }
    else if a == "--self-pid", let v = args.first, let p = Int(v) { selfPid = p; args.removeFirst() }
    else if a == "--max-chars", let v = args.first, let n = Int(v) { maxChars = max(0, n); args.removeFirst() }
    else if a == "--key-code", let v = args.first, let n = UInt32(v) { keyCode = n; args.removeFirst() }
    else if a == "--modifiers", let v = args.first, let n = UInt32(v) { modifiers = n; args.removeFirst() }
    else if a == "--ocr" { ocrRequested = true }
    else if a == "--pick", let v = args.first { pickText = v; args.removeFirst() }
    else if a == "--new-key-code", let v = args.first, let n = UInt32(v) { newKeyCode = n; args.removeFirst() }
    else if a == "--dry" { dryRun = true }
    else if a == "--wait", let v = args.first, let d = Double(v) { waitSeconds = max(0.5, d) }
}

func output(_ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        print(#"{"error":"json_encode_failed"}"#)
    }
    fflush(stdout)
}

/// Long-lived global hotkey watcher via a listen-only CGEventTap on keyDown.
/// (Carbon RegisterEventHotKey registers fine on modern macOS but never
/// delivers to background CLI processes; the event tap needs only the
/// Accessibility grant the M3 tier already requires.) The host reacts to each
/// {"event":"hotkey"} line by snapshotting `look` while the target app is
/// STILL frontmost, then activating DSH.
private var hotkeyTap: CFMachPort?

func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = hotkeyTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    // Match ⌥⌘Z — the DSH app's own bubble/expand toggle — so one press both
    // summons the app (its built-in global shortcut) and captures a snapshot
    // (this listen-only tap). ⌥⌘N = start a new session (AXPress the sidebar
    // button). Falls back to configured key codes when they differ.
    let flags = event.flags
    let altCmd = flags.contains(.maskAlternate) && flags.contains(.maskCommand)
        && !flags.contains(.maskControl) && !flags.contains(.maskShift)
    // ⌥⌘N collides with browsers' new-incognito-window; new session uses ⌃⌥⌘N.
    let altCmdCtrl = flags.contains(.maskAlternate) && flags.contains(.maskCommand)
        && flags.contains(.maskControl) && !flags.contains(.maskShift)
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if altCmd && code == Int64(keyCode) {
        output(["event": "hotkey"])
    } else if altCmdCtrl && code == Int64(newKeyCode) {
        output(["event": "new_session"])
    }
    return Unmanaged.passUnretained(event)
}

func runWatch() {
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: hotkeyTapCallback,
        userInfo: nil
    ) else {
        output(["error": "tap_create_failed", "note": "需要在系统设置中给 DSH 授予辅助功能权限"])
        exit(1)
    }
    hotkeyTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    output(["event": "ready", "mode": "eventtap", "keyCode": Int(keyCode), "modifiers": Int(modifiers)])
    CFRunLoopRun()
}

func runActivateSelf() {
    guard let bundle = selfBundle else {
        output(["error": "self_not_running", "note": "--self-bundle required"])
        exit(1)
    }
    guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        output(["error": "self_not_running"])
        exit(1)
    }
    if #available(macOS 14.0, *) { target.activate() }
    else { target.activate(options: [.activateIgnoringOtherApps]) }
    output(["event": "activated"])
    exit(0)
}

/// focus-input: after ⌥⌘Z summons/expands the DSH window, put keyboard focus
/// into its input box so the user can type (or dictate) immediately — no
/// manual click. BFS the DSH app's focused window for the first editable
/// text area/field and set kAXFocusedAttribute. Retries briefly because the
/// expand animation may not have materialized the web AX tree yet.
func runFocusInput() {
    guard let bundle = selfBundle,
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        output(["error": "self_not_running"])
        exit(1)
    }
    let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(opts) else {
        output(["error": "ax_untrusted"])
        exit(1)
    }
    let appElem = AXUIElementCreateApplication(pid_t(app.processIdentifier))
    AXUIElementSetMessagingTimeout(appElem, 0.5)
    // Chromium (Electron) only builds its AX tree when probed with these
    // switches — same trick readAx uses for target apps; errors are fine.
    AXUIElementSetAttributeValue(appElem, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appElem, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    let deadline = Date().addingTimeInterval(waitSeconds)
    var attempt = 0
    while Date() < deadline {
        attempt += 1
        var winRef: CFTypeRef?
        var winElem: AXUIElement?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winRef) == .success {
            winElem = winRef as! AXUIElement?
        }
        if winElem == nil, let wins = axChildren(appElem), !wins.isEmpty { winElem = wins[0] }
        if let win = winElem {
            var queue: [AXUIElement] = [win]
            var visited = 0
            while !queue.isEmpty && visited < 1500 {
                let elem = queue.removeFirst()
                visited += 1
                let role = axString(elem, kAXRoleAttribute) ?? ""
                if role == "AXTextArea" || role == "AXTextField" {
                    AXUIElementSetAttributeValue(elem, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    output(["event": "focus_input", "ok": true, "role": role, "attempts": attempt, "visited": visited])
                    exit(0)
                }
                if let children = axChildren(elem) { queue.append(contentsOf: children) }
            }
        }
        usleep(250_000)  // wait for expand animation / web AX tree to build
    }
    output(["event": "focus_input", "ok": false, "attempts": attempt, "note": "未找到可聚焦的输入框（气泡可能处于收起状态，或 AX 树未暴露编辑区）"])
    exit(0)
}

/// ax-dump: debug — list roles/labels of the DSH app's windows so we can see
/// what the web content actually exposes to AX.
func runAxDump() {
    guard let bundle = selfBundle,
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        output(["error": "self_not_running"])
        exit(1)
    }
    let appElem = AXUIElementCreateApplication(pid_t(app.processIdentifier))
    AXUIElementSetMessagingTimeout(appElem, 0.5)
    AXUIElementSetAttributeValue(appElem, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appElem, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    usleep(400_000)  // give Chromium a beat to build the tree
    var rows: [[String: Any]] = []
    var queue: [AXUIElement] = []
    var winRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
       let w = winRef { queue.append(w as! AXUIElement) }
    if let wins = axChildren(appElem) { queue.append(contentsOf: wins) }
    var visited = 0
    while !queue.isEmpty && visited < 400 {
        let elem = queue.removeFirst()
        visited += 1
        let role = axString(elem, kAXRoleAttribute) ?? "?"
        let label = [axString(elem, kAXDescriptionAttribute), axString(elem, kAXTitleAttribute), axString(elem, kAXValueAttribute)]
            .compactMap { $0 }.first.map { String($0.prefix(40)) } ?? ""
        rows.append(["i": visited, "role": role, "label": label])
        if let children = axChildren(elem) { queue.append(contentsOf: children) }
    }
    output(["event": "ax_dump", "elements": rows])
    exit(0)
}

/// new-session: AXPress the sidebar "新会话/新建会话" button of the DSH app.
/// --dry finds the button and reports without pressing. Retries briefly for
/// the web AX tree. Bound to the global ⌥⌘N hotkey via the watch tap.
func runNewSession() {
    guard let bundle = selfBundle,
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        output(["error": "self_not_running"])
        exit(1)
    }
    let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(opts) else {
        output(["error": "ax_untrusted"])
        exit(1)
    }
    let needles = ["新建会话", "新会话", "new session"]
    func labelOf(_ elem: AXUIElement) -> String? {
        for attr in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
            if let v = axString(elem, attr), !v.isEmpty { return v }
        }
        return nil
    }
    let appElem = AXUIElementCreateApplication(pid_t(app.processIdentifier))
    AXUIElementSetMessagingTimeout(appElem, 0.5)
    let deadline = Date().addingTimeInterval(2.5)
    var attempt = 0
    while Date() < deadline {
        attempt += 1
        var roots: [AXUIElement] = []
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let w = winRef { roots.append(w as! AXUIElement) }
        if let wins = axChildren(appElem) { roots.append(contentsOf: wins) }
        outer: for root in roots {
            var queue: [AXUIElement] = [root]
            var visited = 0
            while !queue.isEmpty && visited < 2000 {
                let elem = queue.removeFirst()
                visited += 1
                if axString(elem, kAXRoleAttribute) == "AXButton" {
                    let label = (labelOf(elem) ?? "").lowercased()
                    if needles.contains(where: { label.contains($0.lowercased()) }) {
                        if dryRun {
                            output(["event": "new_session", "ok": true, "dry": true, "label": labelOf(elem) ?? "", "attempts": attempt, "visited": visited])
                            exit(0)
                        }
                        let err = AXUIElementPerformAction(elem, kAXPressAction as CFString)
                        output(["event": "new_session", "ok": err == .success, "label": labelOf(elem) ?? "", "attempts": attempt, "visited": visited])
                        exit(0)
                    }
                }
                if let children = axChildren(elem) { queue.append(contentsOf: children) }
            }
            if dryRun && attempt > 1 { break outer }
        }
        usleep(250_000)
    }
    output(["event": "new_session", "ok": false, "dry": dryRun, "note": "未找到「新建会话」按钮（侧边栏可能未显示）"])
    exit(0)
}

switch command {
case "watch": runWatch()
case "activate-self": runActivateSelf()
case "focus-input": runFocusInput()
case "ax-dump": runAxDump()
case "new-session": runNewSession()
default: break  // fall through to the one-shot probe below
}

// PIDs that belong to the calling app (Electron: main + renderer + GPU all
// share the bundle id). NSWorkspace.runningApplications needs no permission.
var selfPids = Set<Int>()
if selfPid > 0 { selfPids.insert(selfPid) }
if let bundle = selfBundle {
    for app in NSWorkspace.shared.runningApplications {
        if app.bundleIdentifier == bundle { selfPids.insert(Int(app.processIdentifier)) }
    }
}

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else {
    output(["error": "frontmost_unavailable", "note": "CGWindowListCopyWindowInfo returned nil"])
    exit(1)
}

// pid -> (appName, bundleId) from NSWorkspace (more reliable than CG owner name).
var byPid: [Int: (String, String)] = [:]
for app in NSWorkspace.shared.runningApplications {
    let name = app.localizedName ?? (app.bundleIdentifier ?? "pid-\(app.processIdentifier)")
    byPid[Int(app.processIdentifier)] = (name, app.bundleIdentifier ?? "")
}

let ts = Int(Date().timeIntervalSince1970 * 1000)

// ---- M3: Accessibility tier (best-effort; silently degrades to app tier) ----

func clipped(_ s: String) -> [String: Any] {
    // Strip object-replacement and private-use scalars Blink embeds for
    // images/attachments inside marker text.
    let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
        scalar == "\u{FFFC}" || (scalar.value >= 0xE000 && scalar.value <= 0xF8FF) ? " " : scalar
    }))
    if cleaned.count > maxChars { return ["text": String(cleaned.prefix(maxChars)), "truncated": true] }
    return ["text": cleaned, "truncated": false]
}

func axString(_ elem: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(elem, attr as CFString, &value) == .success,
          let v = value else { return nil }
    if let s = v as? String { return s }
    if let num = v as? NSNumber { return num.stringValue }
    return nil
}

func axChildren(_ elem: AXUIElement) -> [AXUIElement]? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement], !children.isEmpty else { return nil }
    return children
}

func axParamString(_ elem: AXUIElement, _ name: String, _ argument: CFTypeRef) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(elem, name as CFString, argument, &ref) == .success,
          let v = ref as? String else { return nil }
    return v
}

/// Blink/WebKit expose non-editable selection via "AXSelectedTextMarkerRange"
/// instead of AXSelectedText. Convert that range to a plain string.
func axSelectedMarkerText(_ elem: AXUIElement) -> String? {
    var rangeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(elem, "AXSelectedTextMarkerRange" as CFString, &rangeRef) == .success,
          let range = rangeRef else { return nil }
    guard let text = axParamString(elem, "AXStringForTextMarkerRange", range) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Returns the ax sub-object, or nil when the process is not AX-trusted.
func readAx(pid: Int) -> [String: Any]? {
    let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(opts) else { return nil }
    let appElem = AXUIElementCreateApplication(pid_t(pid))
    var ax: [String: Any] = [:]

    // Chromium-family apps (Chrome / Edge / Electron) only build their AX tree
    // when a client asks for it. Flip both historical switches (errors are
    // fine — merely probing often wakes the renderer tree) and the BFS below
    // retries once to give the tree time to materialize.
    AXUIElementSetAttributeValue(appElem, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appElem, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

    // Window title + document of the frontmost window of that app.
    var winRef: CFTypeRef?
    var winElem: AXUIElement? = nil
    if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winRef) == .success {
        winElem = winRef as! AXUIElement?
    }
    if let win = winElem {
        ax["title"] = axString(win, kAXTitleAttribute) ?? ""
        ax["document"] = axString(win, kAXDocumentAttribute) ?? ""
    }

    // Selected text + focused element text (guarded by timeouts so a hung app
    // can't stall the tool).
    AXUIElementSetMessagingTimeout(appElem, 0.5)
    var focusedRef: CFTypeRef?
    var focusedElem: AXUIElement? = nil
    if AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success {
        focusedElem = focusedRef as! AXUIElement?
    }
    if let focused = focusedElem {
        if let sel = axString(focused, kAXSelectedTextAttribute), !sel.isEmpty {
            ax["selected"] = clipped(sel)
        }
        if let role = axString(focused, kAXRoleAttribute) { ax["focusedRole"] = role }
        // Value/text of the focused element (search box, editor, chat input…)
        if let val = axString(focused, kAXValueAttribute), !val.isEmpty, val != ax["title"] as? String {
            ax["focusedValue"] = clipped(val)
        }
    }

    // Fallback: the target app has LOST focus by the time we look (the user
    // switched to DSH to type), so kAXFocusedUIElement is often empty and the
    // selection lives on some text element inside the window. Do a bounded BFS
    // over the focused window's element tree looking for any non-empty
    // AXSelectedText (plain for native text, marker-range for Blink/WebKit).
    // Chromium may need a beat before its freshly woken renderer tree shows
    // the AXWebArea, so scan twice with a short pause when the first pass saw
    // only a shallow tree.
    if ax["selected"] == nil, let win = winElem {
        if let sel = axString(win, kAXSelectedTextAttribute), !sel.isEmpty {
            ax["selected"] = clipped(sel)
            ax["selectedSource"] = "window"
        } else {
            func scan() -> (String, Int)? {
                let deadline = Date().addingTimeInterval(2.0)
                var queue: [AXUIElement] = [win]
                var visited = 0
                while !queue.isEmpty && visited < 1500 && Date() < deadline {
                    let elem = queue.removeFirst()
                    visited += 1
                    if let sel = axString(elem, kAXSelectedTextAttribute) ?? axSelectedMarkerText(elem), !sel.isEmpty {
                        return (sel, visited)
                    }
                    if let children = axChildren(elem) {
                        queue.append(contentsOf: children)
                    }
                }
                return nil
            }
            var hit = scan()
            if hit == nil { usleep(600_000); hit = scan() }   // let Chromium wake up
            if let (sel, visited) = hit {
                ax["selected"] = clipped(sel)
                ax["selectedSource"] = "window-scan(\(visited))"
            }
        }
    }
    return ax
}

// ---- M4: screenshot + local Vision OCR + gated multimodal -------------------
//
// CGWindowListCreateImage needs the Screen Recording TCC grant (returns nil
// otherwise). OCR runs fully on-device via Vision (zero token cost); the PNG
// is kept in /tmp/dsh-look/ (10-min TTL) so the agent can do a *gated*
// multimodal follow-up (read_image on imagePath) only when the question is
// genuinely visual-semantic. Default path stays text-only.

func ocrWindow(winId: Int, bounds: CGRect) -> [String: Any] {
    guard winId > 0 else { return ["error": "bad_window_id"] }

    // Persist the PNG for gated multimodal follow-up; prune files older than 10 min.
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("dsh-look")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
        for f in files {
            let p = (dir as NSString).appendingPathComponent(f)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
               let mtime = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(mtime) > 600 {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
    }
    let path = (dir as NSString).appendingPathComponent("w\(winId)-\(Int(Date().timeIntervalSince1970 * 1000)).png")

    // CGWindowListCreateImage is obsoleted on macOS 15; capture via the signed
    // system binary instead (needs the Screen Recording TCC grant for DSH).
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    proc.arguments = ["-x", "-l", String(winId), path]
    proc.standardError = FileHandle.nullDevice
    do { try proc.run(); proc.waitUntilExit() } catch {
        return ["error": "capture_failed", "note": "screencapture 启动失败: \(error.localizedDescription)"]
    }
    guard proc.terminationStatus == 0, let imgSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
        return [
            "error": "capture_failed",
            "note": "窗口截图失败：可能未授予屏幕录制权限（系统设置 → 隐私与安全性 → 屏幕录制 → DSH）",
        ]
    }

    // Local OCR — zh-Hans + en-US, accurate, language-corrected.
    // Lines are split by x-position into sidebar/content so a chat app's
    // ever-present left list can't be mistaken for "the whole page".
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do { try handler.perform([request]) } catch {
        let err: [String: Any] = ["error": "ocr_failed", "note": "\(error.localizedDescription)", "imagePath": path]
        return err
    }
    var sidebarLines: [String] = []
    var contentLines: [String] = []
    for observed in request.results ?? [] {
        guard let top = observed.topCandidates(1).first else { continue }
        let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let box = observed.boundingBox              // normalized, origin bottom-left
        let midX = box.minX + box.width / 2
        if midX < 0.3 { sidebarLines.append(text) } else { contentLines.append(text) }
    }
    let joined = (sidebarLines + contentLines).joined(separator: "\n")
    var ocr: [String: Any] = ["imagePath": path]
    let cap = { (lines: [String]) -> String in
        let s = lines.joined(separator: "\n")
        return s.count > maxChars ? String(s.prefix(maxChars)) : s
    }
    ocr["sidebar"] = cap(sidebarLines)
    ocr["content"] = cap(contentLines)
    if joined.isEmpty {
        ocr["ocrText"] = ""
        ocr["note"] = "OCR 未识别到文本（可能是纯图像/视频画面）；如问题是视觉语义类，可用 imagePath 做多模态判断"
        return ocr
    }
    if joined.count > maxChars {
        ocr["ocrText"] = String(joined.prefix(maxChars))
        ocr["truncated"] = true
    } else {
        ocr["ocrText"] = joined
    }
    return ocr
}

// ---- candidate collection + pick --------------------------------------------
//
// P2 multi-window: apps like WeChat open each chat as a SEPARATE window, and
// the frontmost non-self window may not be the one the user means. Collect
// every qualifying window; pick by --pick <substring> (app name or CG window
// name, case-insensitive) when given, else keep M0 semantics (frontmost).
// When ≥2 candidates exist, attach a `windows` list so the agent can see the
// alternatives and retry with pick.

struct Candidate {
    let pid: Int
    let app: String
    let bundleId: String
    let wid: Int
    let bx: Double, by: Double, bw: Double, bh: Double
    let cgName: String?
}

var candidates: [Candidate] = []
for w in list {
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    if layer != 0 { continue }                    // skip menus, dock, overlays
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    if pid <= 0 { continue }
    if selfPids.contains(pid) { continue }        // skip DSH's own windows
    guard let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
          let bx = boundsDict["X"] as? Double, let by = boundsDict["Y"] as? Double,
          let bw = boundsDict["Width"] as? Double, let bh = boundsDict["Height"] as? Double else { continue }
    if bw < 40 || bh < 40 { continue }            // skip tiny utility windows
    let info = byPid[pid]
    candidates.append(Candidate(
        pid: pid,
        app: info?.0 ?? (w[kCGWindowOwnerName as String] as? String ?? "pid-\(pid)"),
        bundleId: info?.1 ?? "",
        wid: w[kCGWindowNumber as String] as? Int ?? 0,
        bx: bx, by: by, bw: bw, bh: bh,
        cgName: w[kCGWindowName as String] as? String
    ))
}

guard let first = candidates.first else {
    output([
        "error": "frontmost_unavailable",
        "note": selfPids.isEmpty
            ? "没有找到任何可报告的非自身窗口"
            : "当前除 DSH 自身外没有其他可见窗口，无法判断你刚才在用什么应用",
        "ts": ts,
        "source": "agent",
    ])
    exit(1)
}

var selected = first
var pickedBy = "frontmost"
if let needle = pickText?.lowercased(), !needle.isEmpty {
    // app name first (e.g. "微信"), then CG window name (needs screen-recording
    // TCC on modern macOS; absent is fine — app-name picking still works).
    if let hit = candidates.first(where: {
        $0.app.lowercased().contains(needle) || ($0.cgName?.lowercased().contains(needle) ?? false)
    }) {
        selected = hit
        pickedBy = "pick(\(pickText!))"
    } else {
        output([
            "error": "pick_no_match",
            "note": "没有匹配「\(pickText!)」的窗口；可用候选见 windows 列表",
            "windows": candidates.prefix(8).map { windowEntry($0, isSelf: false) },
            "ts": ts,
            "source": "agent",
        ])
        exit(1)
    }
}

func windowEntry(_ c: Candidate, isSelf: Bool) -> [String: Any] {
    var e: [String: Any] = [
        "app": c.app,
        "id": c.wid,
        "bounds": ["x": c.bx, "y": c.by, "w": c.bw, "h": c.bh],
    ]
    if let n = c.cgName, !n.isEmpty { e["name"] = n }
    if isSelf { e["selected"] = true }
    return e
}

let pid = selected.pid
let app = selected.app
let bundleId = selected.bundleId
let wid = selected.wid
let bx = selected.bx, by = selected.by, bw = selected.bw, bh = selected.bh
var result: [String: Any] = [
    "app": app,
    "bundleId": bundleId,
    "pid": pid,
    "window": [
        "id": wid,
        "bounds": ["x": bx, "y": by, "w": bw, "h": bh],
        "layer": 0,
    ],
    "ts": ts,
    "source": "agent",
]
if candidates.count > 1 {
    result["windows"] = candidates.prefix(8).map { windowEntry($0, isSelf: $0.wid == wid) }
    result["windowsNote"] = "存在多个可见窗口，已选\(pickedBy == "frontmost" ? "最前窗口" : pickedBy)；如不是用户所指，可用 pick 参数按应用名/窗口名重试"
}
if let ax = readAx(pid: pid), !ax.isEmpty {
    result["fidelity"] = "ax"
    result["ax"] = ax
    result["note"] = "辅助功能模式：窗口标题/选中文本/焦点元素已尽力读取；其余页面内容仍不可见，不要猜测。"
} else {
    result["fidelity"] = "app"
    result["note"] = "零权限模式：仅 app 级信息。窗口标题与内容需授予辅助功能权限后可用。"
}
if ocrRequested {
    result["ocr"] = ocrWindow(winId: wid, bounds: CGRect(x: bx, y: by, width: bw, height: bh))
}
output(result)
exit(0)
