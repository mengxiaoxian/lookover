import AppKit

// Render only presentation data. Original messages stay in the Host unchanged.
enum MessageMarkdown {
    static func plain(_ text:String,skin:ConversationSkin) -> NSAttributedString {
        let paragraph=NSMutableParagraphStyle()
        paragraph.lineSpacing=5;paragraph.paragraphSpacing=7
        return NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:skin.fontSize),.foregroundColor:skin.foreground,.paragraphStyle:paragraph])
    }

    static func render(_ text:String,skin:ConversationSkin) -> NSAttributedString {
        let options=AttributedString.MarkdownParsingOptions(interpretedSyntax:.full,failurePolicy:.returnPartiallyParsedIfPossible)
        guard let parsed=try? AttributedString(markdown:text,options:options) else {return plain(text,skin:skin)}
        // Tables need a dedicated layout. Preserve their source instead of
        // concatenating cells and silently changing the meaning of a result.
        if parsed.runs.contains(where:{run in
            run.presentationIntent?.components.contains(where:{component in
                if case .table = component.kind {return true}
                return false
            }) ?? false
        }) {return plain(text,skin:skin)}

        let result=NSMutableAttributedString(string:"")
        var previousBlock:Int?
        var seenItems=Set<Int>()
        for run in parsed.runs {
            let components=run.presentationIntent?.components ?? []
            let block=components.first?.identity
            let newBlock=block != previousBlock
            var level=0,codeBlock=false,quoteDepth=0,listDepth=0
            var itemOrdinal:Int?,itemIdentity:Int?
            var ordered:Bool?
            for component in components {
                switch component.kind {
                case .header(let value):level=value
                case .codeBlock:codeBlock=true
                case .blockQuote:quoteDepth+=1
                case .orderedList:if ordered==nil {ordered=true};listDepth+=1
                case .unorderedList:if ordered==nil {ordered=false};listDepth+=1
                case .listItem(let ordinal):if itemIdentity==nil {itemOrdinal=ordinal;itemIdentity=component.identity}
                default:break
                }
            }
            let paragraph=NSMutableParagraphStyle()
            paragraph.lineSpacing=codeBlock ? 3 : 5;paragraph.paragraphSpacing=7
            let indent=CGFloat(min(8,max(0,listDepth-1)))*14+CGFloat(min(8,quoteDepth))*10
            paragraph.firstLineHeadIndent=indent;paragraph.headIndent=indent
            var prefix=""
            if newBlock {
                if result.length>0 && !result.string.hasSuffix("\n") {
                    result.append(plain("\n",skin:skin))
                }
                if quoteDepth>0 {prefix="▎ "}
                if let identity=itemIdentity,let ordinal=itemOrdinal,!seenItems.contains(identity) {
                    prefix+=ordered==true ? "\(ordinal). " : "• "
                    seenItems.insert(identity)
                }
            }
            if listDepth>0 {
                paragraph.headIndent=indent+skin.fontSize*1.4
                if prefix.isEmpty {paragraph.firstLineHeadIndent=paragraph.headIndent}
            }
            let inline=run.inlinePresentationIntent ?? []
            let code=codeBlock || inline.contains(.code)
            let size=skin.fontSize+(level>0 ? CGFloat(max(1,6-level)) : 0)
            var font=code ? NSFont.monospacedSystemFont(ofSize:skin.fontSize,weight:.regular) : NSFont.systemFont(ofSize:size,weight:level>0 ? .semibold : .regular)
            var traits=NSFontTraitMask()
            if inline.contains(.stronglyEmphasized) {traits.insert(.boldFontMask)}
            if inline.contains(.emphasized) {traits.insert(.italicFontMask)}
            if !traits.isEmpty {font=NSFontManager.shared.convert(font,toHaveTrait:traits)}
            var attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:skin.foreground,.paragraphStyle:paragraph]
            if code {attributes[.backgroundColor]=skin.muted.withAlphaComponent(0.09)}
            if inline.contains(.strikethrough) {attributes[.strikethroughStyle]=NSUnderlineStyle.single.rawValue}
            // No image download or HTML execution. Only explicit web links are clickable.
            if let link=run.link,["https","http"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link]=link;attributes[.foregroundColor]=skin.accent
                attributes[.underlineStyle]=NSUnderlineStyle.single.rawValue
            }
            if !prefix.isEmpty {result.append(NSAttributedString(string:prefix,attributes:attributes))}
            let content=inline.contains(.softBreak) || inline.contains(.lineBreak) ? "\n" : String(parsed[run.range].characters)
            result.append(NSAttributedString(string:content,attributes:attributes))
            previousBlock=block
        }
        return result
    }
}
