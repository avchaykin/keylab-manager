import KeyLabCore
import SwiftUI

@main
struct KeyLabManagerApp: App {
    @State private var model = AppModel()

    init() { RenderCheck.runIfRequested() }

    var body: some Scene {
        WindowGroup("KeyLab Manager") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1500, height: 940)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Back Up All Presets…") { Task { await model.backupAndSave() } }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Restore from Backup…") { model.showRestorePicker = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Reconnect Keyboard") { Task { await model.connect() } }
            }
        }
    }
}

struct RestoreItem: Identifiable {
    let id = UUID()
    let backup: Backup
}

/// Choose which presets from a backup go into which User slot.
struct RestoreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let backup: Backup
    @State private var mapping: [Int: Int] = [:]      // backup user → slot (0 = skip)
    @State private var includeGlobal = 0

    private var sources: [Int] { backup.presets.keys.compactMap(Int.init).sorted() }
    private var slotOptions: [Schema.Option] {
        [Schema.Option(value: 0, label: "Skip")] + (1...10).map { Schema.Option(value: $0, label: "→ User \($0) · \(model.names[$0] ?? "")") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BPCaption("Restore from backup", size: 12, color: BP.ink)
            Text("Saved \(backup.created.formatted(date: .abbreviated, time: .shortened)) · firmware \(backup.firmware). "
                 + "Presets are loaded as local changes; nothing is sent until you press Write.")
                .font(BP.mono(10.5)).foregroundStyle(BP.faint).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(BP.hair).frame(height: 1)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sources, id: \.self) { u in
                        HStack(spacing: 10) {
                            Text("User \(u) · \(backup.presets[String(u)]?.name ?? "")").font(BP.mono(11.5)).lineLimit(1)
                                .frame(width: 200, alignment: .leading)
                            BPSelector(options: slotOptions, value: Binding { mapping[u] ?? u } set: { mapping[u] = $0 })
                        }
                    }
                    if backup.global != nil {
                        HStack(spacing: 10) {
                            Text("Device settings").font(BP.mono(11.5)).frame(width: 200, alignment: .leading)
                            BPSelector(options: [Schema.Option(value: 0, label: "Skip"), Schema.Option(value: 1, label: "Restore")],
                                       value: $includeGlobal)
                        }
                    }
                }
            }
            Rectangle().fill(BP.hair).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(BPButtonStyle())
                Button("Load selected") {
                    var m = [Int: Int]()
                    for u in sources { let slot = mapping[u] ?? u; if slot > 0 { m[u] = slot } }
                    Task {
                        await model.stage(backup, mapping: m, includeGlobal: includeGlobal == 1)
                        model.notice = "Loaded \(m.count) preset(s). Review, then use Write."
                        dismiss()
                    }
                }
                .buttonStyle(BPButtonStyle(prominent: true))
            }
        }
        .padding(18)
        .frame(width: 560, height: 520)
        .background(BP.paper)
        .preferredColorScheme(.dark)
    }
}
