import AppKit
func emit(_ object:[String:Any]) {
    if let data=try? JSONSerialization.data(withJSONObject:object),let line=String(data:data,encoding:.utf8) {print(line);fflush(stdout)}
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let menu=NSMenu()
let editRoot=NSMenuItem(title:"编辑",action:nil,keyEquivalent:"")
let edit=NSMenu(title:"编辑")
for (title,action,key) in [("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] {
    edit.addItem(NSMenuItem(title:title,action:action,keyEquivalent:key))
}
editRoot.submenu=edit;menu.addItem(editRoot);app.mainMenu=menu
let catalog=SkinCatalog()
let window=ConversationWindow(catalog:catalog)
let coordinator=WindowCoordinator(conversation:window)
DispatchQueue.global().async {
    while let line=readLine() {
        if line.utf8.count>262144 {break}
        if let data=line.data(using:.utf8),let m=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {DispatchQueue.main.async {
            if m["kind"] as? String == "surface", let target=m["surface"] as? String {coordinator.show(target)}
            else {window.handle(m)}
        }}
    }
    DispatchQueue.main.async {app.terminate(nil)}
}
window.panel.orderFrontRegardless()
window.metrics("ready")
app.run()
