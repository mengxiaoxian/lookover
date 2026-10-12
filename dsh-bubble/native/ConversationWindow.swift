import AppKit
// Decorative text must never intercept clicks intended for the editor.
final class InputPlaceholder:NSTextField {
    override func hitTest(_ point:NSPoint) -> NSView? {nil}
}
final class MessageInput:NSTextView {
    var onCompositionChanged:(() -> Void)?
    override func setMarkedText(_ string:Any,selectedRange:NSRange,replacementRange:NSRange) {
        super.setMarkedText(string,selectedRange:selectedRange,replacementRange:replacementRange)
        onCompositionChanged?()
    }
    override func unmarkText() {super.unmarkText();onCompositionChanged?()}
    override var mouseDownCanMoveWindow:Bool {false}
    override var needsPanelToBecomeKey:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool {true}
}
final class ConversationPanel:NSPanel {
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {false}
}
final class ConversationWindow:NSObject,NSTextViewDelegate,NSWindowDelegate {
    var onCloseToLauncher:(() -> Void)?
    var onOpenDesktop:(() -> Void)?
    var onSkinChanged:((ConversationSkin) -> Void)?
    let catalog:SkinCatalog
    var skin:ConversationSkin
    let panel:ConversationPanel
    let surface=NSView(),composer=NSView(),divider=NSView()
    let transcript=MessageList(),transcriptScroll=NSScrollView()
    let input=MessageInput(),inputScroll=NSScrollView()
    let placeholder=InputPlaceholder(labelWithString:"说点什么…")
    let title=NSTextField(labelWithString:"对话"),portrait=NSImageView()
    let status=NSTextField(labelWithString:"正在连接…")
    let hint=NSTextField(labelWithString:"⌘ Enter 发送")
    let sessions=NSPopUpButton()
    let newButton=NSButton(),expandButton=NSButton(),collapseButton=NSButton(),appearanceButton=NSButton()
    let sendButton=NSButton(title:"发送",target:nil,action:nil),stopButton=NSButton(title:"停止",target:nil,action:nil)
    var drafts:[String:String]=[:],sessionIds:[String]=[]
    var selected:String?,draftRequest:String?,submittedDraft="",revision = -1
    var running=false,pending=false,connected=false,errorMessage:String?
    var lastMessages:[[String:Any]]=[],lastPartial="",lastContent=""
    init(catalog:SkinCatalog) {
        self.catalog=catalog;skin=catalog.selected
        panel=ConversationPanel(contentRect:NSRect(x:180,y:180,width:420,height:560),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        panel.delegate=self
        panel.level = .floating;panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
        panel.isMovableByWindowBackground=true
        surface.frame=NSRect(x:0,y:0,width:420,height:560);surface.wantsLayer=true;surface.layer?.masksToBounds=true
        composer.wantsLayer=true;composer.layer?.cornerRadius=16;composer.layer?.borderWidth=1
        divider.wantsLayer=true
        panel.contentView=surface
        for view in [composer,divider,title,portrait,status,hint,sessions,placeholder] {surface.addSubview(view)}
        transcriptScroll.documentView=transcript;transcriptScroll.hasVerticalScroller=true;transcriptScroll.drawsBackground=false
        transcriptScroll.scrollerStyle = .overlay;surface.addSubview(transcriptScroll)
        input.isEditable=true;input.isSelectable=true;input.isRichText=false;input.drawsBackground=false
        input.font = .systemFont(ofSize:14);input.textContainerInset=NSSize(width:4,height:6)
        input.isVerticallyResizable=true;input.isHorizontallyResizable=false;input.textContainer?.widthTracksTextView=true
        input.autoresizingMask=[.width]
        input.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        input.delegate=self;input.onCompositionChanged={ [weak self] in self?.updateControls() };input.setAccessibilityLabel("消息输入")
        inputScroll.documentView=input;inputScroll.hasVerticalScroller=true;inputScroll.drawsBackground=false
        inputScroll.scrollerStyle = .overlay;surface.addSubview(inputScroll)
        placeholder.font = .systemFont(ofSize:14);placeholder.isSelectable=false
        title.font = .systemFont(ofSize:18,weight:.semibold)
        portrait.imageScaling = .scaleProportionallyUpOrDown;portrait.wantsLayer=true
        portrait.layer?.cornerRadius=17;portrait.layer?.masksToBounds=true
        status.font = .systemFont(ofSize:11);hint.font = .systemFont(ofSize:11)
        sessions.font = .systemFont(ofSize:12);sessions.target=self;sessions.action = #selector(selectSession)
        let tools:[(NSButton,String,String,Selector)]=[
            (newButton,"plus","新对话",#selector(newSession)),
            (expandButton,"macwindow","主窗口",#selector(openDesktop)),
            (collapseButton,"minus","收起",#selector(closeToLauncher)),
            (appearanceButton,"paintpalette","外观",#selector(openAppearance))]
        for (button,symbol,label,action) in tools {
            button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:label)
            button.imagePosition = .imageOnly;button.isBordered=false;button.bezelStyle = .inline
            button.setAccessibilityLabel(label);button.toolTip=label;button.target=self;button.action=action
            surface.addSubview(button)
        }
        expandButton.toolTip="打开主窗口，继续当前对话";collapseButton.toolTip="收起到悬浮入口，任务继续运行"
        appearanceButton.toolTip="切换外观"
        for button in [sendButton,stopButton] {button.target=self;button.bezelStyle = .rounded;surface.addSubview(button)}
        sendButton.action = #selector(sendMessage);stopButton.action = #selector(stop)
        sendButton.keyEquivalent="\r";sendButton.keyEquivalentModifierMask=[.command]
        sendButton.toolTip="发送（⌘ Enter），Enter 换行"
        layout();applySkin(skin);updateControls()
    }
    func layout() {
        let w=surface.bounds.width,h=surface.bounds.height
        portrait.frame=NSRect(x:20,y:h-58,width:34,height:34)
        title.frame=NSRect(x:64,y:h-52,width:w-208,height:26)
        appearanceButton.frame=NSRect(x:w-126,y:h-54,width:30,height:30)
        expandButton.frame=NSRect(x:w-88,y:h-54,width:30,height:30)
        collapseButton.frame=NSRect(x:w-50,y:h-54,width:30,height:30)
        sessions.frame=NSRect(x:20,y:h-91,width:w-80,height:26)
        newButton.frame=NSRect(x:w-52,y:h-91,width:28,height:28)
        divider.frame=NSRect(x:20,y:h-105,width:w-40,height:1)
        transcriptScroll.frame=NSRect(x:16,y:166,width:w-32,height:h-280)
        composer.frame=NSRect(x:16,y:20,width:w-32,height:120)
        inputScroll.frame=NSRect(x:24,y:69,width:w-48,height:61)
        // A zero-height document view cannot receive mouse clicks or a text caret.
        let editorSize=inputScroll.contentSize
        input.minSize=NSSize(width:0,height:editorSize.height)
        input.frame=NSRect(origin:.zero,size:NSSize(width:editorSize.width,height:max(editorSize.height,input.frame.height)))
        input.textContainer?.containerSize=NSSize(width:editorSize.width,height:CGFloat.greatestFiniteMagnitude)
        placeholder.frame=NSRect(x:33,y:104,width:w-66,height:22)
        status.frame=NSRect(x:24,y:146,width:w-48,height:16)
        hint.frame=NSRect(x:32,y:34,width:w-140,height:18)
        sendButton.frame=NSRect(x:w-96,y:30,width:64,height:30);stopButton.frame=sendButton.frame
        render(force:true)
    }
    func applySkin(_ value:ConversationSkin) {
        skin=value;panel.appearance=skin.appearance;panel.title=skin.id=="none" ? "对话" : skin.title
        title.stringValue=skin.id=="none" ? "对话" : skin.title
        title.textColor=skin.foreground;input.textColor=skin.foreground;input.insertionPointColor=skin.accent
        input.font = .systemFont(ofSize:skin.fontSize)
        status.textColor=skin.muted;hint.textColor=skin.muted;placeholder.textColor=skin.muted.withAlphaComponent(0.72)
        portrait.image=skin.avatar ?? NSImage(systemSymbolName:"bubble.left.and.bubble.right",accessibilityDescription:nil)
        portrait.contentTintColor=skin.avatar==nil ? skin.accent : nil
        for button in [newButton,expandButton,collapseButton,appearanceButton] {button.contentTintColor=skin.muted}
        sendButton.bezelColor=skin.accent;stopButton.bezelColor=skin.accent
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            surface.layer?.cornerRadius=skin.cornerRadius;surface.layer?.backgroundColor=skin.background.cgColor
            surface.layer?.borderWidth=1;surface.layer?.borderColor=skin.muted.withAlphaComponent(0.14).cgColor
            composer.layer?.backgroundColor=skin.inputBackground.cgColor;composer.layer?.borderColor=skin.muted.withAlphaComponent(0.16).cgColor
            divider.layer?.backgroundColor=skin.muted.withAlphaComponent(0.10).cgColor
            render(force:true)
        }
        onSkinChanged?(skin)
        constrainToScreen()
    }
    func constrainToScreen() {
        guard let screen=panel.screen ?? NSScreen.main else {return}
        let visible=screen.visibleFrame;var frame=panel.frame
        frame.origin.x=max(visible.minX,min(frame.minX,visible.maxX-frame.width))
        frame.origin.y=max(visible.minY,min(frame.minY,visible.maxY-frame.height))
        if frame != panel.frame {panel.setFrame(frame,display:true)}
    }
    func windowDidMove(_ notification:Notification) {constrainToScreen()}
    @objc func openAppearance() {
        let menu=NSMenu(title:"外观")
        for skin in catalog.skins {
            let item=NSMenuItem(title:skin.title,action:#selector(chooseSkin(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=skin.id;item.state=skin.id==self.skin.id ? .on : .off;menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:appearanceButton.bounds.minY),in:appearanceButton)
    }
    @objc func chooseSkin(_ sender:NSMenuItem) {
        guard let id=sender.representedObject as? String,let next=catalog.select(id) else {return}
        applySkin(next);emit(["kind":"skin-changed","skin":next.id])
    }
    func render(force:Bool=false,resetScroll:Bool=false) {
        let key=lastMessages.map{($0["role"] as? String ?? "")+(($0["text"] as? String) ?? "")}.joined(separator:"\u{0}")+lastPartial
        guard force || key != lastContent else {return}
        let nearBottom=transcriptScroll.documentVisibleRect.maxY >= transcript.frame.height-50
        lastContent=key
        transcript.render(messages:lastMessages,partial:lastPartial,skin:skin,width:transcriptScroll.contentSize.width,minimumHeight:transcriptScroll.contentSize.height,resetFormatting:force)
        if nearBottom || resetScroll {
            transcriptScroll.contentView.scroll(to:NSPoint(x:0,y:max(0,transcript.frame.height-transcriptScroll.contentSize.height)))
            transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
        }
    }
    func textDidChange(_ notification:Notification) {updateControls()}
    func updateControls() {
        let hasText = !input.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        placeholder.isHidden=hasText || input.hasMarkedText()
        sendButton.isHidden=running;stopButton.isHidden = !running
        sendButton.isEnabled=selected != nil && !running && !pending && draftRequest==nil && hasText && !input.hasMarkedText()
        stopButton.isEnabled=running;newButton.isEnabled = !pending && draftRequest==nil;sessions.isEnabled=newButton.isEnabled
        status.stringValue=errorMessage ?? (!connected ? "正在连接…" : draftRequest != nil ? "正在发送…" : pending ? "处理中…" : running ? "正在回复…" : "")
        status.textColor=errorMessage != nil ? .systemRed : skin.muted
        status.isHidden=status.stringValue.isEmpty
    }
    func resize(expanded:Bool) {
        panel.setContentSize(NSSize(width:expanded ? 640 : 420,height:expanded ? 640 : 560))
        surface.frame.size=panel.contentView!.bounds.size
        if let screen=panel.screen ?? NSScreen.main {
            let v=screen.visibleFrame;var f=panel.frame;f.origin.x=max(v.minX,min(f.minX,v.maxX-f.width));f.origin.y=max(v.minY,min(f.minY,v.maxY-f.height));panel.setFrame(f,display:true)
        }
        layout();metrics(expanded ? "expanded" : "collapsed")
    }
    @objc func openDesktop() {onOpenDesktop?()}
    @objc func closeToLauncher() {onCloseToLauncher?()}
    @objc func expand() {resize(expanded:true)}
    @objc func collapse() {resize(expanded:false)}
    func request(_ op:String,extra:[String:Any]=[:]) -> String {
        let id=UUID().uuidString;var payload:[String:Any]=["kind":"request","op":op,"requestId":id,"sessionId":selected ?? NSNull()]
        for (k,v) in extra {payload[k]=v};emit(payload);return id
    }
    @objc func selectSession() {
        let i=sessions.indexOfSelectedItem
        if sessionIds.indices.contains(i) {errorMessage=nil;_ = request("select",extra:["sessionId":sessionIds[i]])}
    }
    @objc func newSession() {errorMessage=nil;_ = request("new")}
    @objc func sendMessage() {
        guard sendButton.isEnabled else {return}
        errorMessage=nil;submittedDraft=input.string;draftRequest=request("send",extra:["text":submittedDraft]);updateControls()
    }
    @objc func stop() {stopButton.isEnabled=false;_ = request("cancel")}
    func handle(_ m:[String:Any]) {
        switch m["kind"] as? String {
        case "snapshot":
            guard let next=m["revision"] as? Int,next>revision else {return};revision=next;connected=true
            let oldSelected=selected;selected=m["sessionId"] as? String
            if oldSelected != selected {
                if let old=oldSelected {drafts[old]=input.string}
                input.string=selected.flatMap{drafts[$0]} ?? "";errorMessage=nil
            }
            let choices=m["sessions"] as? [[String:Any]] ?? []
            sessionIds=choices.compactMap{$0["id"] as? String};sessions.removeAllItems()
            sessions.addItems(withTitles:choices.map{$0["title"] as? String ?? "会话"})
            if let id=selected,let i=sessionIds.firstIndex(of:id) {sessions.selectItem(at:i)}
            if choices.isEmpty {sessions.addItem(withTitle:"新对话")}
            lastMessages=m["messages"] as? [[String:Any]] ?? [];lastPartial=m["partial"] as? String ?? ""
            running=m["running"] as? Bool ?? false;pending=m["pending"] as? Bool ?? false
            panel.effectiveAppearance.performAsCurrentDrawingAppearance {render(resetScroll:oldSelected != selected)}
            updateControls()
            emit(["kind":"rendered","pid":ProcessInfo.processInfo.processIdentifier,"sessionId":selected ?? NSNull(),"messageCount":lastMessages.count,"text":m["text"] ?? "","partialLength":lastPartial.count,"running":running,"skin":skin.id])
        case "receipt":
            emit(["kind":"receipt","requestId":m["requestId"] ?? "","ok":m["ok"] ?? false])
            if m["requestId"] as? String == draftRequest {
                if m["ok"] as? Bool == true,input.string==submittedDraft {input.string=""}
                draftRequest=nil;submittedDraft=""
            }
            if m["ok"] as? Bool != true {errorMessage=m["error"] as? String ?? "操作失败"}
            else {errorMessage=nil}
            updateControls()
        case "error":errorMessage=m["message"] as? String ?? "任务执行失败";updateControls()
        case "expand":expand()
        case "collapse":collapse()
        case "probe":_ = request(m["op"] as? String ?? "invalid",extra:["sessionId":m["sessionId"] ?? NSNull()])
        case "capture":
            if let path=m["path"] as? String,let bitmap=surface.bitmapImageRepForCachingDisplay(in:surface.bounds) {
                surface.cacheDisplay(in:surface.bounds,to:bitmap)
                if let png=bitmap.representation(using:.png,properties:[:]) {try? png.write(to:URL(fileURLWithPath:path));emit(["kind":"captured","path":path])}
            }
        default:break
        }
    }
    func metrics(_ kind:String) {emit(["kind":kind,"width":panel.frame.width,"height":panel.frame.height,"floating":panel.level == .floating,"transparent": !panel.isOpaque,"skin":skin.id,"pid":ProcessInfo.processInfo.processIdentifier])}
}
