import AppKit
import KeyLabCore
import SwiftUI

/// Developer hook: `KLM_RENDER=/path/prefix KLM_BACKUP=backup.json` renders the panel drawing for
/// User 1 of the backup to PNG files (light + dark) and exits, without touching the keyboard.
@MainActor
enum RenderCheck {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["KLM_RENDER"], let file = env["KLM_BACKUP"] else { return }
        do {
            let b = try Backup.load(from: URL(fileURLWithPath: file))
            let user = Int(env["KLM_USER"] ?? "1") ?? 1
            let model = AppModel()
            model.loaded[.user(user)] = b.presets[String(user)]
            model.edited[.user(user)] = b.presets[String(user)]
            let sel = PanelSelection(group: env["KLM_GROUP"] ?? "columns", column: 2, element: env["KLM_ELEMENT"] ?? "enc2")
            let pxScale = CGFloat(Double(env["KLM_PXSCALE"] ?? "2") ?? 2)   // 1 = non-Retina display
            for (name, scheme) in [("dark", ColorScheme.dark)] {
                let view = BlueprintCanvas(target: .user(user), selection: .constant(sel), bank: .constant(1),
                                           scale: CGFloat(Double(env["KLM_SCALE"] ?? "1.5") ?? 1.5),
                                           viewport: Blueprint.viewport(env["KLM_ZOOM"] ?? "whole"))
                    .environment(model)
                    .environment(\.colorScheme, scheme)
                    .environment(\.displayScale, pxScale)
                if let g = env["KLM_GRID"] {
                    let grid = GroupGrid(target: .user(user), group: PanelGroup.named(g), bank: 1, selection: .constant(sel), scrolls: false)
                        .environment(model).environment(\.colorScheme, scheme)
                        .padding().background(BP.paper)
                    let gr = ImageRenderer(content: grid); gr.scale = 2
                    if let img = gr.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: "\(out)-grid-\(name).png"))
                    }
                }
                let r = ImageRenderer(content: view)
                r.scale = pxScale
                guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: URL(fileURLWithPath: "\(out)-\(name).png"))
            }
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
        }
        exit(0)
    }
}
