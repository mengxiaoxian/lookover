import AppKit
final class FlippedView:NSView { override var isFlipped:Bool {true} }
final class MessageCard: NSView {
    override var isFlipped:Bool {true}
    let body=NSTextView()
    let name=NSTextField(labelWithString:"")
    let portrait=NSImageView()
    let bubble=FlippedView()
    let role:String
    let skin:ConversationSkin
    init(role:String,text:String,skin:ConversationSkin,streaming:Bool=false,formatted:NSAttributedString?=nil) {
        self.role=role;self.skin=skin;super.init(frame:.zero)
        name.stringValue=role=="user" ? "你" : skin.assistantName+(streaming ? " · 回复中" : "")
        name.font = .systemFont(ofSize:11,weight:.medium);name.textColor=skin.muted
        name.alignment=role=="user" ? .right : .left
        addSubview(name);addSubview(bubble);bubble.wantsLayer=true;bubble.layer?.cornerRadius=14
        bubble.layer?.backgroundColor=(role=="user" ? skin.userBackground : NSColor.clear).cgColor
        body.isEditable=false;body.isSelectable=true;body.isRichText=true;body.drawsBackground=false
        body.isVerticallyResizable=false;body.isHorizontallyResizable=false
        body.autoresizingMask=[];bubble.autoresizesSubviews=false
        // Leave room for glyph ink that extends beyond its typographic advance.
        body.textContainerInset = NSSize(width:0,height:3);body.textContainer?.lineFragmentPadding=5
        body.isHorizontallyResizable=false;body.textContainer?.widthTracksTextView=true
        body.textStorage?.setAttributedString(formatted ?? (role=="assistant" ? MessageMarkdown.render(text,skin:skin) : MessageMarkdown.plain(text,skin:skin)))
        body.linkTextAttributes=[.foregroundColor:skin.accent,.underlineStyle:NSUnderlineStyle.single.rawValue]
        body.setAccessibilityLabel(role=="user" ? "你的消息" : "助手回复")
        bubble.addSubview(body)
        if role != "user" {
            portrait.image=skin.avatar ?? NSImage(systemSymbolName:"bubble.left",accessibilityDescription:nil)
            portrait.contentTintColor=skin.accent;portrait.imageScaling = .scaleProportionallyUpOrDown
            portrait.wantsLayer=true;portrait.layer?.cornerRadius=12;portrait.layer?.masksToBounds=true
            addSubview(portrait)
        }
    }
    required init?(coder:NSCoder) {fatalError()}
    func fit(width:CGFloat) -> CGFloat {
        let user=role=="user", bubbleWidth=user ? width*0.87 : width-34
        let padding:CGFloat=user ? 12 : 0, textWidth=bubbleWidth-padding*2
        body.frame=NSRect(x:padding,y:padding,width:textWidth,height:1)
        body.textContainer?.containerSize=NSSize(width:textWidth,height:CGFloat.greatestFiniteMagnitude)
        body.layoutManager?.ensureLayout(for:body.textContainer!)
        let textHeight=ceil(body.layoutManager?.usedRect(for:body.textContainer!).height ?? 20)+body.textContainerInset.height*2
        body.frame.size.height=max(20,textHeight)
        let cardHeight=body.frame.height+padding*2
        let left=user ? width-bubbleWidth : 34
        name.frame=NSRect(x:left,y:0,width:bubbleWidth,height:16)
        bubble.frame=NSRect(x:left,y:23,width:bubbleWidth,height:cardHeight)
        portrait.frame=NSRect(x:0,y:0,width:24,height:24)
        frame.size=NSSize(width:width,height:23+cardHeight)
        return frame.height
    }
}
final class MessageList:NSView {
    override var isFlipped:Bool {true}
    var cards:[MessageCard]=[]
    private var formattedCache:[String:NSAttributedString]=[:]
    func render(messages:[[String:Any]],partial:String,skin:ConversationSkin,width:CGFloat,minimumHeight:CGFloat,resetFormatting:Bool=false) {
        if resetFormatting {formattedCache=[:]}
        subviews.forEach{$0.removeFromSuperview()};cards=[]
        var rows=messages
        if !partial.isEmpty {rows.append(["role":"assistant","text":partial,"streaming":true])}
        var y:CGFloat=12
        var nextCache:[String:NSAttributedString]=[:]
        for row in rows {
            let role=row["role"] as? String ?? "assistant",text=row["text"] as? String ?? ""
            let key=role+"\u{0}"+text
            let formatted=formattedCache[key] ?? (role=="assistant" ? MessageMarkdown.render(text,skin:skin) : MessageMarkdown.plain(text,skin:skin))
            nextCache[key]=formatted
            let card=MessageCard(role:role,text:text,skin:skin,streaming:row["streaming"] as? Bool ?? false,formatted:formatted)
            let height=card.fit(width:width-16);card.frame.origin=NSPoint(x:8,y:y)
            addSubview(card);cards.append(card);y+=height+24
        }
        formattedCache=nextCache
        if rows.isEmpty {
            let title=NSTextField(labelWithString:"开始一段新对话")
            title.font = .systemFont(ofSize:18,weight:.semibold);title.textColor=skin.foreground
            title.alignment = .center;title.frame=NSRect(x:8,y:minimumHeight*0.30,width:width-16,height:26);addSubview(title)
            let note=NSTextField(labelWithString:"写下问题，或从上方选择对话")
            note.font = .systemFont(ofSize:12);note.textColor=skin.muted;note.alignment = .center
            note.frame=NSRect(x:8,y:minimumHeight*0.30+34,width:width-16,height:22);addSubview(note)
        }
        frame.size=NSSize(width:width,height:max(minimumHeight,y))
    }
}
