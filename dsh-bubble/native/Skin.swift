import AppKit
import ImageIO
// A declarative presentation contract. No model, task, session or pipe capabilities.
protocol ConversationSkin {
    var appearance: NSAppearance? { get }
    var id: String { get }
    var title: String { get }
    var assistantName: String { get }
    var background: NSColor { get }
    var foreground: NSColor { get }
    var muted: NSColor { get }
    var accent: NSColor { get }
    var inputBackground: NSColor { get }
    var userBackground: NSColor { get }
    var avatar: NSImage? { get }
    var launcher: NSImage? { get }
    var fontSize: CGFloat { get }
    var cornerRadius: CGFloat { get }
}
struct PlainSkin: ConversationSkin {
    let appearance: NSAppearance? = nil
    let id = "none", title = "默认", assistantName = "助手"
    let background = NSColor.windowBackgroundColor, foreground = NSColor.labelColor
    let muted = NSColor.secondaryLabelColor, accent = NSColor.systemBlue
    let inputBackground = NSColor.textBackgroundColor
    let userBackground = NSColor.controlAccentColor.withAlphaComponent(0.09)
    let avatar: NSImage? = nil, launcher: NSImage? = nil
    let fontSize: CGFloat = 14, cornerRadius: CGFloat = 22
}
struct FileSkin: ConversationSkin {
    let appearance: NSAppearance?
    let id: String, title: String, assistantName: String
    let background: NSColor, foreground: NSColor, muted: NSColor, accent: NSColor
    let inputBackground: NSColor, userBackground: NSColor
    let avatar: NSImage?, launcher: NSImage?
    let fontSize: CGFloat, cornerRadius: CGFloat
    init(path: String) throws {
        let url=URL(fileURLWithPath:path)
        guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=32768 else {throw NSError(domain:"Skin",code:1)}
        let data = try Data(contentsOf: URL(fileURLWithPath:path))
        guard data.count <= 32768, let value = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let id = value["id"] as? String, !id.isEmpty, id != "none",
              let background = Self.color(value["background"]), let foreground = Self.color(value["foreground"]) else { throw NSError(domain:"Skin",code:1) }
        self.id=String(id.prefix(80));self.title=String((value["title"] as? String ?? "自定义").prefix(40))
        self.assistantName=String((value["assistantName"] as? String ?? "助手").prefix(40))
        self.background=background;self.foreground=foreground
        let dark = 0.2126*background.redComponent+0.7152*background.greenComponent+0.0722*background.blueComponent < 0.5
        self.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
        self.muted=Self.color(value["muted"]) ?? foreground.withAlphaComponent(0.60)
        self.accent=Self.color(value["accent"]) ?? .systemBlue
        self.inputBackground=Self.color(value["inputBackground"]) ?? (dark ? background.blended(withFraction:0.08,of:.white)! : .white)
        self.userBackground=Self.color(value["userBackground"]) ?? self.accent.withAlphaComponent(0.10)
        self.fontSize=min(20,max(12,value["fontSize"] as? CGFloat ?? 14))
        self.cornerRadius=min(32,max(0,value["cornerRadius"] as? CGFloat ?? 22))
        let directory=URL(fileURLWithPath:path).deletingLastPathComponent()
        self.avatar=Self.image(value["avatar"],directory:directory)
        self.launcher=Self.image(value["launcher"],directory:directory)
    }
    private static func color(_ value: Any?) -> NSColor? {
        guard let text=value as? String,text.count==7,text.first=="#",let rgb=UInt32(text.dropFirst(),radix:16) else {return nil}
        return NSColor(calibratedRed:CGFloat((rgb>>16)&255)/255,green:CGFloat((rgb>>8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
    }
    private static func image(_ value:Any?,directory:URL) -> NSImage? {
        guard let path=value as? String,!path.hasPrefix("/"),!path.split(separator:"/").contains("..") else {return nil}
        let root=directory.resolvingSymlinksInPath().standardizedFileURL
        let url=root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path+"/"),["png","jpg","jpeg"].contains(url.pathExtension.lowercased()),
              let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=8*1024*1024,
              let source=CGImageSourceCreateWithURL(url as CFURL,nil),
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512] as CFDictionary) else {return nil}
        return NSImage(cgImage:image,size:.zero)
    }
}
final class SkinCatalog {
    private let preferences:UserDefaults
    var skins:[ConversationSkin]=[PlainSkin()]
    var selected:ConversationSkin
    init(arguments:[String]=CommandLine.arguments,preferences:UserDefaults = .standard) {
        self.preferences=preferences
        let args=arguments
        if let index=args.firstIndex(of:"--skins-dir"),args.count>index+1 {
            let directory=URL(fileURLWithPath:args[index+1])
            let children=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
            for child in children.sorted(by:{$0.lastPathComponent<$1.lastPathComponent}).prefix(20) {
                if let skin=try? FileSkin(path:child.appendingPathComponent("skin.json").path),!skins.contains(where:{$0.id==skin.id}) {skins.append(skin)}
            }
        }
        var initial:ConversationSkin=skins[0]
        if let index=args.firstIndex(of:"--skin"),args.count>index+1 {
            if let skin=try? FileSkin(path:args[index+1]) {initial=skin;if !skins.contains(where:{$0.id==skin.id}) {skins.append(skin)}}
        } else if let saved=preferences.string(forKey:"appearance.skin"),let skin=skins.first(where:{$0.id==saved}) {initial=skin}
        selected=initial
    }
    func select(_ id:String) -> ConversationSkin? {
        guard let skin=skins.first(where:{$0.id==id}) else {return nil}
        selected=skin;preferences.set(id,forKey:"appearance.skin");return skin
    }
}
