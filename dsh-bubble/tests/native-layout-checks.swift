import AppKit
func emit(_ object:[String:Any]) {}
@main struct LayoutChecks {
    static func main() {
        _ = NSApplication.shared
        let preferences=UserDefaults(suiteName:"xiaoguang-layout-"+UUID().uuidString)!
        let window=ConversationWindow(catalog:SkinCatalog(arguments:[],preferences:preferences))
        precondition(window.input.frame.height>=window.inputScroll.contentSize.height && window.input.frame.height>0)
        precondition(window.input.minSize.height==window.inputScroll.contentSize.height)
        precondition(window.placeholder.hitTest(.zero)==nil)
        precondition(!window.input.mouseDownCanMoveWindow && window.input.needsPanelToBecomeKey)
        window.selected="test"
        window.input.setMarkedText("ni",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        precondition(window.placeholder.isHidden && !window.sendButton.isEnabled)
        window.input.unmarkText();window.input.string="";window.updateControls()
        precondition(!window.placeholder.isHidden)
        for text in ["换肤后对话正常",String(repeating:"回复文字完整，中文与English混合。\n",count:8)] {
            let card=MessageCard(role:"assistant",text:text,skin:PlainSkin())
            _=card.fit(width:360)
            let body=card.body
            let used=body.layoutManager!.usedRect(for:body.textContainer!)
            precondition(body.textContainer!.lineFragmentPadding>=5)
            precondition(body.frame.height>=ceil(used.height)+body.textContainerInset.height*2)
            precondition(body.frame.maxY<=card.bubble.bounds.height)
        }
        print("Layout regression: clickable editor, pass-through placeholder, panel focus and complete text bounds passed")
    }
}
