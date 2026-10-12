import AppKit
@main struct MarkdownChecks {
    static func main() {
        _ = NSApplication.shared
        let skin=PlainSkin()
        let source="""
        # 鼓励一下

        **拍肩鼓励型**

        ```text
        (*^▽^*)  加油呀
            (^_^)  保留缩进和 **星号**
        ```

        普通第一行
        普通第二行

        - 第一项 **重点**
        - 第二项

        1. 有序项
           - 嵌套项

        > 引用一句

        行内 `a * b` 与 *斜体*、~~划掉~~、[链接](https://example.com)。
        """
        let rendered=MessageMarkdown.render(source,skin:skin)
        let text=rendered.string as NSString
        precondition(!rendered.string.contains("```"))
        precondition(!rendered.string.contains("**拍肩鼓励型**"))
        precondition(rendered.string.contains("(*^▽^*)  加油呀\n    (^_^)  保留缩进和 **星号**\n"))
        precondition(rendered.string.contains("普通第一行\n普通第二行"))
        precondition(rendered.string.contains("• 第一项 重点\n• 第二项"))
        precondition(rendered.string.contains("1. 有序项\n• 嵌套项"))
        precondition(rendered.string.contains("▎ 引用一句"))
        let fontAt:(String)->NSFont={needle in rendered.attribute(.font,at:text.range(of:needle).location,effectiveRange:nil) as! NSFont}
        precondition(NSFontManager.shared.traits(of:fontAt("拍肩鼓励型")).contains(.boldFontMask))
        precondition(fontAt("鼓励一下").pointSize>skin.fontSize)
        precondition(fontAt("(*^▽^*)").isFixedPitch)
        precondition(fontAt("a * b").isFixedPitch)
        precondition(NSFontManager.shared.traits(of:fontAt("斜体")).contains(.italicFontMask))
        precondition(rendered.attribute(.strikethroughStyle,at:text.range(of:"划掉").location,effectiveRange:nil) != nil)
        precondition(rendered.attribute(.link,at:text.range(of:"链接").location,effectiveRange:nil) as? URL == URL(string:"https://example.com"))
        let unsafe=MessageMarkdown.render("[不要自动打开](file:///tmp/example) ![图片说明](https://example.com/test.png)",skin:skin)
        precondition(unsafe.string.contains("不要自动打开") && unsafe.string.contains("图片说明"))
        unsafe.enumerateAttributes(in:NSRange(location:0,length:unsafe.length)) {attributes,_,_ in
            precondition(attributes[.link]==nil && attributes[.attachment]==nil && attributes[.imageURL]==nil)
        }
        let table="| A | B |\n| --- | --- |\n| 1 | 2 |"
        precondition(MessageMarkdown.render(table,skin:skin).string==table)
        let user=MessageCard(role:"user",text:"**原文**\n```\n(^_^)\n```",skin:skin)
        precondition(user.body.string=="**原文**\n```\n(^_^)\n```")
        // Every incoming prefix must parse/layout; unfinished fences preserve literal content.
        let streaming="**标题**\n\n```\n(*^▽^*)  加油\n    a * b\n```"
        for count in 1...streaming.count {
            let partial=String(streaming.prefix(count))
            let card=MessageCard(role:"assistant",text:partial,skin:skin,streaming:true)
            _=card.fit(width:350)
            let used=card.body.layoutManager!.usedRect(for:card.body.textContainer!)
            precondition(card.body.frame.height>=ceil(used.height)+card.body.textContainerInset.height*2)
        }
        let open=MessageMarkdown.render("```\n  (^_^)  a **b**\n",skin:skin)
        precondition(open.string=="  (^_^)  a **b**\n")
        let list=MessageList()
        list.render(messages:[["role":"assistant","text":"**重点**"]],partial:"**流式",skin:skin,width:380,minimumHeight:200)
        list.render(messages:[["role":"assistant","text":"**重点**"]],partial:"**流式完成**",skin:skin,width:380,minimumHeight:200)
        precondition(list.cards[0].body.string=="重点" && list.cards[1].body.string=="流式完成")
        print("Markdown regression: bold, headings, lists, links, code whitespace, emoji, raw user text, table fallback and streaming prefixes passed")
    }
}
