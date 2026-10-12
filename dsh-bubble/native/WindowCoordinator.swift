import AppKit
// Only coordinates the companion's windows and its exact parent desktop app.
// No Accessibility permission, UI scripting, private Electron IPC or engine access.
final class LauncherButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard let window=window else {return}
        highlight(true)
        while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp {
                highlight(false)
                if let action=action {NSApp.sendAction(action,to:target,from:self)}
                return
            }
            if abs(next.locationInWindow.x-event.locationInWindow.x)>3 || abs(next.locationInWindow.y-event.locationInWindow.y)>3 {
                highlight(false);window.performDrag(with:event);return
            }
        }
        highlight(false)
    }
}
final class WindowCoordinator: NSObject, NSWindowDelegate {
    let conversation: ConversationWindow
    let launcher: ConversationPanel
    let launcherButton = LauncherButton(title:"聊", target:nil, action:nil)
    var surface = "bubble"
    var desktop: NSRunningApplication? {
        let args = CommandLine.arguments
        guard let p = args.firstIndex(of:"--desktop-pid"), args.count > p+1, let pid = Int32(args[p+1]),
              let d = args.firstIndex(of:"--desktop-path"), args.count > d+1,
              let app = NSRunningApplication(processIdentifier:pid), !app.isTerminated,
              app.bundleIdentifier == "com.deepseek.dsh",
              app.bundleURL?.standardizedFileURL == URL(fileURLWithPath:args[d+1]).standardizedFileURL else {return nil}
        return app
    }
    init(conversation: ConversationWindow) {
        self.conversation=conversation
        launcher=ConversationPanel(contentRect:NSRect(x:180,y:180,width:56,height:56),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        launcher.title="对话入口";launcher.level = .floating;launcher.isOpaque=false;launcher.backgroundColor = .clear
        launcher.isMovableByWindowBackground=true
        launcherButton.frame=NSRect(x:0,y:0,width:56,height:56)
        launcherButton.bezelStyle = .regularSquare;launcherButton.isBordered=false
        launcherButton.wantsLayer=true;launcherButton.layer?.cornerRadius=28
        launcherButton.layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor
        launcherButton.layer?.borderWidth=1;launcherButton.layer?.borderColor=NSColor.separatorColor.cgColor
        launcherButton.font = .systemFont(ofSize:20,weight:.medium)
        launcherButton.toolTip="打开对话 · 拖动可移动";launcherButton.setAccessibilityLabel("打开对话")
        launcher.delegate=self
        launcherButton.target=self;launcherButton.action = #selector(openBubble)
        let menu=NSMenu()
        menu.addItem(withTitle:"打开对话",action:#selector(openBubble),keyEquivalent:"").target=self
        menu.addItem(withTitle:"打开主窗口",action:#selector(openDesktop),keyEquivalent:"").target=self
        launcherButton.menu=menu;launcher.contentView=launcherButton
        conversation.onCloseToLauncher = { [weak self] in self?.show("launcher") }
        conversation.onOpenDesktop = { [weak self] in self?.openDesktop() }
        conversation.onSkinChanged = { [weak self] skin in self?.applySkin(skin) }
        applySkin(conversation.skin)
    }
    func applySkin(_ skin:ConversationSkin) {
        launcher.appearance=skin.appearance
        let old=launcher.frame
        let size=skin.launcher == nil ? NSSize(width:56,height:56) : NSSize(width:80,height:92)
        launcher.setContentSize(size)
        launcher.setFrameOrigin(NSPoint(x:old.midX-size.width/2,y:old.maxY-size.height))
        launcherButton.frame=NSRect(origin:.zero,size:size)
        launcherButton.title=""
        launcherButton.image=skin.launcher ?? NSImage(systemSymbolName:"bubble.left.and.bubble.right.fill",accessibilityDescription:"打开对话")
        launcherButton.imagePosition = .imageOnly;launcherButton.imageScaling = .scaleProportionallyUpOrDown
        launcherButton.contentTintColor=skin.launcher == nil ? skin.accent : nil
        launcher.hasShadow=skin.launcher == nil
        launcherButton.layer?.cornerRadius=skin.launcher == nil ? 28 : 0
        launcher.effectiveAppearance.performAsCurrentDrawingAppearance {
            launcherButton.layer?.backgroundColor=(skin.launcher == nil ? skin.inputBackground : NSColor.clear).cgColor
            launcherButton.layer?.borderWidth=skin.launcher == nil ? 1 : 0
            launcherButton.layer?.borderColor=skin.muted.withAlphaComponent(0.18).cgColor
        }
    }
    func windowDidMove(_ notification: Notification) {
        emit(["kind":"launcher-moved","x":launcher.frame.minX,"y":launcher.frame.minY])
    }
    @objc func openBubble() {show("bubble")}
    @objc func openDesktop() {
        guard let desktop=desktop, let url=desktop.bundleURL, let link=URL(string:"dsh://open") else {conversation.handle(["kind":"error","message":"未连接官方桌面窗口，请从官方版启动插件"]);return}
        let configuration=NSWorkspace.OpenConfiguration()
        configuration.activates=true
        // Target this exact app, not whichever install owns the global dsh URL scheme.
        NSWorkspace.shared.open([link],withApplicationAt:url,configuration:configuration) { [weak self] _,error in
            DispatchQueue.main.async {
                if error != nil {self?.conversation.handle(["kind":"error","message":"无法打开官方主窗口，请重试"])}
                else {emit(["kind":"surface-request","surface":"desktop"])}
            }
        }
    }
    func show(_ next:String) {
        switch next {
        case "launcher":
            let old=conversation.panel.frame
            launcher.setFrameOrigin(NSPoint(x:old.minX,y:old.maxY-launcher.frame.height))
            conversation.panel.orderOut(nil);launcher.orderFrontRegardless()
        case "bubble":
            if surface == "launcher" {
                let old=launcher.frame
                var rect=conversation.panel.frame;rect.origin=NSPoint(x:old.minX,y:old.maxY-rect.height)
                if let screen=launcher.screen ?? NSScreen.main {
                    let visible=screen.visibleFrame
                    rect.origin.x=max(visible.minX,min(rect.minX,visible.maxX-rect.width))
                    rect.origin.y=max(visible.minY,min(rect.minY,visible.maxY-rect.height))
                }
                conversation.panel.setFrame(rect,display:true)
            }
            launcher.orderOut(nil);conversation.panel.makeKeyAndOrderFront(nil)
        case "desktop":
            guard let app=desktop else {conversation.handle(["kind":"error","message":"官方主窗口已退出"]);return}
            app.unhide()
            guard app.activate(options:[]) else {conversation.handle(["kind":"error","message":"主窗口暂未激活，请重试"]);return}
            conversation.panel.orderOut(nil);launcher.orderOut(nil)
        default:return
        }
        surface=next
        emit(["kind":"surface-changed","surface":next,"pid":ProcessInfo.processInfo.processIdentifier])
    }
}
