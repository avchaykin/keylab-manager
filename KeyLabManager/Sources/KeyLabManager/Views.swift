import KeyLabCore
import SwiftUI
import UniformTypeIdentifiers

/// Window layout: top bar (title, status, actions), preset strip, then the editor.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TopBar()
            PresetStrip()
            Rectangle().fill(BP.hair).frame(height: 1)
            if let t = model.selection {
                PresetDetail(target: t).id(t)
            } else {
                Spacer()
            }
        }
        .background(BP.paper)
        .foregroundStyle(BP.ink)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.selection) { _, t in
            if let t, model.loaded[t] == nil { Task { await model.load(t) } }
        }
        .alert("Error", isPresented: Binding { model.errorMessage != nil } set: { if !$0 { model.errorMessage = nil } }) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        // Full backup / restore (from the top bar or the File menu)
        .fileExporter(isPresented: Binding { model.backupToSave != nil } set: { if !$0 { model.backupToSave = nil } },
                      document: model.backupToSave.map(BackupDocument.init), contentType: .json,
                      defaultFilename: "KeyLab backup \(Date.now.formatted(.iso8601.year().month().day())).json") { result in
            if case let .failure(e) = result { model.errorMessage = e.localizedDescription } else { model.notice = "Backup saved." }
        }
        .fileImporter(isPresented: $model.showRestorePicker, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                model.restoreSource = RestoreItem(backup: try Backup.load(from: url))
            } catch { model.errorMessage = error.localizedDescription }
        }
        .sheet(item: $model.restoreSource) { item in RestoreSheet(backup: item.backup).environment(model) }
        .task { await model.connect() }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var model
    @State private var exporting: Backup?
    @State private var importing = false

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64)         // traffic lights
            VStack(alignment: .leading, spacing: 1) {
                Text("KEYLAB MANAGER").font(BP.label(11, .heavy)).tracking(1.2)
                Text(model.deviceInfo).font(BP.mono(9.5)).foregroundStyle(model.device == nil ? BP.changed : BP.faint).lineLimit(1)
            }
            .fixedSize()
            ZStack { Color.clear; status }.frame(maxWidth: .infinity, maxHeight: .infinity)
            actions
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .disabled(model.busy != nil)
        .fileExporter(isPresented: Binding { exporting != nil } set: { if !$0 { exporting = nil } },
                      document: exporting.map(BackupDocument.init), contentType: .json,
                      defaultFilename: "\(model.selection?.title ?? "Preset") \(model.selection.flatMap { model.edited[$0]?.name } ?? "").keylab.json") { result in
            if case let .failure(e) = result { model.errorMessage = e.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { importPreset($0) }
    }

    @ViewBuilder private var status: some View {
        if let busy = model.busy {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(BP.hair).frame(width: 160, height: 2)
                    Rectangle().fill(BP.ink).frame(width: 160 * model.progress, height: 2)
                }
                Text(busy).font(BP.mono(10.5)).foregroundStyle(BP.faint).lineLimit(1)
            }
        } else if let notice = model.notice {
            Text(notice).font(BP.mono(10.5)).foregroundStyle(BP.faint).lineLimit(1)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(5))
                    if model.notice == notice { model.notice = nil }
                }
        }
    }

    @ViewBuilder private var actions: some View {
        let t = model.selection
        let changes = t.map { model.changeCount($0) } ?? 0
        let pending = model.edited.keys.filter { model.changeCount($0) > 0 }.count
        HStack(spacing: 6) {
            if let t {
                Button("Reload") { Task { await model.load(t) } }
                    .help("Read this preset from the keyboard again (discards local changes)")
                if changes > 0 {
                    Button("Revert") { model.revert(t) }.help("Discard local changes")
                }
                if case let .user(n) = t {
                    BPMenuButton(title: "Copy to", items: (1...10).filter { $0 != n }.map { m in
                        ("User \(m) — \(model.names[m] ?? "")", { _ = Task { await model.copy(t, toUser: m) } })
                    })
                }
            }
            BPMenuButton(title: "File", items: fileItems)
            if pending > 1 {
                Button("Write all (\(pending))") { Task { await model.writeAllChanged() } }
            }
            if let t {
                Button(changes > 0 ? "Write (\(changes))" : "Write") { Task { await model.write(t) } }
                    .buttonStyle(BPButtonStyle(prominent: true))
                    .disabled(changes == 0)
                    .help("Send the changes to the keyboard and store the preset")
            }
        }
        .buttonStyle(BPButtonStyle())
    }

    private var fileItems: [(String, () -> Void)] {
        var items: [(String, () -> Void)] = []
        if case let .user(n) = model.selection {
            items.append(("Export User \(n)…", {
                if let s = model.edited[.user(n)] {
                    exporting = Backup(device: model.deviceInfo, firmware: "", global: nil, presets: [String(n): s])
                }
            }))
            items.append(("Import into User \(n)…", { importing = true }))
            items.append(("-", {}))
        }
        items.append(("Back up all presets…   ⇧⌘B", { _ = Task { await model.backupAndSave() } }))
        items.append(("Restore from backup…  ⇧⌘O", { model.showRestorePicker = true }))
        items.append(("-", {}))
        items.append(("Reconnect keyboard", { _ = Task { await model.connect() } }))
        return items
    }

    private func importPreset(_ result: Result<URL, Error>) {
        guard let t = model.selection else { return }
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let b = try Backup.load(from: url)
            guard let snap = b.presets.sorted(by: { $0.key < $1.key }).first?.value else {
                throw KeyLabError.badFile("the file contains no presets")
            }
            model.edited[t] = snap
            model.notice = "Imported “\(snap.name)”. Review it, then press Write."
        } catch { model.errorMessage = error.localizedDescription }
    }
}

// MARK: - Preset strip

private struct PresetStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            cell(.global, top: "Device", name: "Settings")
            ForEach(1...10, id: \.self) { n in
                cell(.user(n), top: "User \(n)", name: model.names[n] ?? "—")
                    .contextMenu {
                        Button("Reload from Keyboard") { Task { await model.load(.user(n)) } }
                    }
            }
        }
        .overlay(Rectangle().strokeBorder(BP.line, lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 8)
        .disabled(model.busy != nil)
    }

    private func cell(_ t: Target, top: String, name: String) -> some View {
        let on = model.selection == t
        let n = model.changeCount(t)
        return Button { model.selection = t } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(top.uppercased()).font(BP.label(9, .bold)).tracking(0.7)
                        .foregroundStyle(on ? Color.black.opacity(0.6) : BP.faint)
                    Spacer(minLength: 0)
                    if n > 0 {
                        Text("\(n)").font(BP.mono(9, .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 4).background(BP.changed)
                            .help("\(n) unsaved change(s)")
                    }
                }
                Text(name).font(BP.mono(11.5, on ? .bold : .regular)).lineLimit(1)
                    .foregroundStyle(on ? Color.black : BP.ink)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? BP.ink : Color.clear)
            .overlay(alignment: .trailing) { Rectangle().fill(BP.hair).frame(width: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail

struct PresetDetail: View {
    @Environment(AppModel.self) private var model
    let target: Target
    @State private var panelSelection = PanelSelection()
    @State private var bank = 1

    var body: some View {
        if model.edited[target] == nil {
            VStack(spacing: 12) {
                if model.busy != nil {
                    BPCaption("Reading…")
                } else {
                    Button("Read \(target.title) from keyboard") { Task { await model.load(target) } }
                        .buttonStyle(BPButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if target == .global {
            DeviceSettingsView(target: target)
        } else {
            PanelEditor(target: target, nameBinding: nameBinding, selection: $panelSelection, bank: $bank)
        }
    }

    private var nameBinding: Binding<String> {
        Binding { model.edited[target]?.name ?? "" } set: {
            model.edited[target]?.name = String($0.prefix(model.schema.presetName.maxlen ?? 16))
        }
    }
}

/// Device-wide settings as a dense grid of cards.
private struct DeviceSettingsView: View {
    @Environment(AppModel.self) private var model
    let target: Target

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400, maximum: 640), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                ForEach(model.sections(for: target)) { section in
                    ForEach(section.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                BPCaption(section.title == item.title ? item.title : "\(section.title) · \(item.title)", color: BP.ink)
                                Rectangle().fill(BP.hair).frame(height: 1)
                            }
                            .padding(.bottom, 2)
                            ForEach(model.editorRows(item, in: target)) { row in BPFormRow(row: row, target: target) }
                        }
                        .padding(10)
                        .overlay(Rectangle().strokeBorder(BP.hair, lineWidth: 1))
                    }
                }
            }
            .padding(12)
        }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var backup: Backup
    init(_ b: Backup) { backup = b }
    init(configuration: ReadConfiguration) throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        backup = try d.decode(Backup.self, from: configuration.file.regularFileContents ?? Data())
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try e.encode(backup))
    }
}
