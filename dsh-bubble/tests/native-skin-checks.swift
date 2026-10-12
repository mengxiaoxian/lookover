import AppKit
@main struct SkinChecks {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("xiaoguang-skin-checks-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let suite="xiaoguang-skin-checks-"+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        // No system appearance preferences or user session state are touched.
        defer {try? FileManager.default.removeItem(at:directory);preferences.removePersistentDomain(forName:suite)}
        let valid=try FileSkin(path:root.appendingPathComponent("skins/xiaoguang/skin.json").path)
        precondition(valid.id=="xiaoguang" && valid.avatar != nil && valid.launcher != nil)
        let path=directory.appendingPathComponent("skin.json")
        try Data("{\"id\":\"safe\",\"background\":\"#FFFFFF\",\"foreground\":\"#222222\",\"fontSize\":999,\"cornerRadius\":-1,\"avatar\":\"../outside.png\"}".utf8).write(to:path)
        let constrained=try FileSkin(path:path.path)
        precondition(constrained.fontSize==20 && constrained.cornerRadius==0 && constrained.avatar==nil)
        try Data("not-json".utf8).write(to:path)
        let fallback=SkinCatalog(arguments:[suite,"--skin",path.path],preferences:preferences)
        precondition(fallback.selected.id=="none")
        let catalog=SkinCatalog(arguments:[suite,"--skins-dir",root.appendingPathComponent("skins").path],preferences:preferences)
        precondition(catalog.selected.id=="none" && catalog.select("xiaoguang") != nil)
        let restored=SkinCatalog(arguments:[suite,"--skins-dir",root.appendingPathComponent("skins").path],preferences:preferences)
        precondition(restored.selected.id=="xiaoguang")
        precondition(restored.select("none") != nil && restored.select("unknown")==nil)
        try Data(repeating:65,count:32769).write(to:path)
        precondition((try? FileSkin(path:path.path))==nil)
        print("Skin contract: packaged assets, bounds, malformed fallback, selection restore, default and oversized rejection passed")
    }
}
