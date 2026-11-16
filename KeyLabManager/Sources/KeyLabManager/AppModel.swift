import Foundation
import KeyLabCore
import Observation

enum Target: Hashable {
    case global
    case user(Int)          // 1…10

    var presetID: UInt8 {
        switch self {
        case .global: return 0
        case let .user(n): return Schema.presetID(user: n)
        }
    }
    var title: String {
        switch self {
        case .global: return "Device Settings"
        case let .user(n): return "User \(n)"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let schema = Schema.shared

    var device: KeyLab?
    var deviceInfo = "Not connected"
    var names: [Int: String] = [:]

    var selection: Target? = .user(1)
    /// What is on the keyboard (last read / written) and the local edited copy, per target.
    var loaded: [Target: Snapshot] = [:]
    var edited: [Target: Snapshot] = [:]

    var busy: String?
    var progress: Double = 0
    var errorMessage: String?
    var notice: String?

    /// Full backup waiting to be saved, restore file picker, and a loaded backup to map into slots.
    var backupToSave: Backup?
    var showRestorePicker = false
    var restoreSource: RestoreItem?

    var sections: [Schema.Section] {
        selection == .global ? schema.global : schema.preset
    }

    func sections(for t: Target) -> [Schema.Section] { t == .global ? schema.global : schema.preset }

    func changeCount(_ t: Target) -> Int {
        guard let e = edited[t], let l = loaded[t] else { return 0 }
        let d = e.differences(from: l)
        return d.values.count + d.strings.count + (e.name != l.name ? 1 : 0)
    }

    // MARK: - Connection

    func connect() async {
        do {
            let kl = try KeyLab()
            let id = try await kl.run { try $0.identity() }
            device = kl
            deviceInfo = "\(kl.portName) · firmware \(id.firmware)"
            await refreshNames()
            if let s = selection, loaded[s] == nil { await load(s) }
        } catch {
            device = nil
            deviceInfo = "Not connected"
            errorMessage = error.localizedDescription
        }
    }

    func refreshNames() async {
        guard let kl = device else { return }
        let n = schema.presetName
        let result = try? await kl.run { kl -> [Int: String] in
            var out = [Int: String]()
            for u in 1...10 {
                let a = Addr(preset: Schema.presetID(user: u), param: UInt8(n.param), ctrl: UInt8(n.ctrl))
                out[u] = try kl.readString(a).trimmingCharacters(in: .whitespaces)
            }
            return out
        }
        if let result { names = result }
    }

    // MARK: - Work helper

    private func work<T: Sendable>(_ label: String, _ body: @escaping @Sendable (KeyLab, @escaping KeyLab.Progress) throws -> T) async -> T? {
        guard let kl = device else { errorMessage = KeyLabError.deviceNotFound.localizedDescription; return nil }
        busy = label
        progress = 0
        defer { busy = nil }
        let report: KeyLab.Progress = { p in Task { @MainActor [weak self] in self?.progress = p } }
        do {
            return try await kl.run { try body($0, report) }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Presets

    func load(_ t: Target) async {
        let sections = sections(for: t), pid = t.presetID
        guard let snap = await work("Reading \(t.title)…", { kl, p in
            try kl.readSnapshot(preset: pid, sections: sections, progress: p)
        }) else { return }
        loaded[t] = snap
        edited[t] = snap
        if case let .user(n) = t { names[n] = snap.name }
    }

    func revert(_ t: Target) { edited[t] = loaded[t] }

    /// Write local edits to the keyboard and store the preset.
    func write(_ t: Target) async {
        guard let snap = edited[t] else { return }
        let current = loaded[t], pid = t.presetID
        guard let n = await work("Writing \(t.title)…", { kl, p in
            try kl.writeSnapshot(snap, preset: pid, over: current, progress: p)
        }) else { return }
        await load(t)          // read back what the keyboard really holds
        notice = n == 0 ? "No changes to write." : "Wrote \(n) change\(n == 1 ? "" : "s") to \(t.title) and stored it."
    }

    /// Copy the edited contents of `from` into User `to` (local copy only, until written).
    func copy(_ from: Target, toUser to: Int) async {
        let dest = Target.user(to)
        if loaded[dest] == nil { await load(dest) }
        guard let snap = edited[from] ?? loaded[from], loaded[dest] != nil else { return }
        edited[dest] = snap
        selection = dest
        notice = "Copied into User \(to). Review it, then press Write to Keyboard."
    }

    // MARK: - Backup / restore

    func backupAndSave() async {
        if let b = await backupAll() { backupToSave = b }
    }

    func backupAll() async -> Backup? {
        let schema = self.schema
        let info = deviceInfo
        let result = await work("Backing up all presets…", { kl, p -> Backup in
            let id = try kl.identity()
            let global = try kl.readSnapshot(preset: 0, sections: schema.global)
            var presets = [String: Snapshot]()
            for u in 1...10 {
                presets[String(u)] = try kl.readSnapshot(preset: Schema.presetID(user: u), sections: schema.preset) { f in
                    p((Double(u - 1) + f) / 10)
                }
            }
            _ = info
            return Backup(device: kl.portName, firmware: id.firmware, global: global, presets: presets)
        })
        if let result {
            for (k, s) in result.presets { if let u = Int(k) { loaded[.user(u)] = s; edited[.user(u)] = s; names[u] = s.name } }
            if let g = result.global { loaded[.global] = g; edited[.global] = g }
        }
        return result
    }

    /// Put presets from a backup into the local edited copies. `mapping` = backup user → slot.
    func stage(_ backup: Backup, mapping: [Int: Int], includeGlobal: Bool) async {
        for (_, slot) in mapping where loaded[.user(slot)] == nil { await load(.user(slot)) }
        if includeGlobal, loaded[.global] == nil { await load(.global) }
        for (src, slot) in mapping { if let s = backup.presets[String(src)] { edited[.user(slot)] = s } }
        if includeGlobal, let g = backup.global { edited[.global] = g }
    }

    /// Write every target that has local changes.
    func writeAllChanged() async {
        let targets = edited.keys.filter { changeCount($0) > 0 }
        for t in targets.sorted(by: { $0.presetID < $1.presetID }) { await write(t) }
        notice = targets.isEmpty ? "Nothing to write." : "Wrote \(targets.count) preset(s) to the keyboard."
    }

    // MARK: - Editing helpers

    func value(_ p: Schema.Param, in t: Target) -> Int? {
        guard let s = edited[t] else { return nil }
        guard let v1 = s[value: p.addr] else { return nil }
        var v = v1
        if let a2 = p.addr2, let v2 = s[value: a2] { v |= v2 << 7 }
        if let a3 = p.addr3, let v3 = s[value: a3] { v |= v3 << 14 }
        return v
    }

    func setValue(_ v: Int, _ p: Schema.Param, in t: Target) {
        guard edited[t] != nil else { return }
        edited[t]![value: p.addr] = v & 0x7F
        if let a2 = p.addr2 { edited[t]![value: a2] = (v >> 7) & 0x7F }
        if let a3 = p.addr3 { edited[t]![value: a3] = (v >> 14) & 0x7F }
    }

    func isVisible(_ p: Schema.Param, item: Schema.Item, in t: Target) -> Bool {
        guard let conds = p.visibleIf else { return true }
        for c in conds {
            var scope = item
            if let key = c.item, key != item.key {
                guard let other = sections(for: t).lazy.flatMap(\.items).first(where: { $0.key == key }) else { return false }
                scope = other
            }
            // Prefer a candidate that is itself visible (several rows can share a key).
            let candidates = scope.params.filter { $0.key == c.param }
            guard let sib = candidates.first(where: { $0.visibleIf == nil || isVisible($0, item: scope, in: t) }) ?? candidates.first,
                  let v = value(sib, in: t) else { return false }
            if !c.in.contains(v) { return false }
        }
        return true
    }

    func rgb(_ p: Schema.Param, in t: Target) -> (Int, Int, Int)? {
        guard let c = p.rgb, let s = edited[t],
              let r = s[value: c.r], let g = s[value: c.g], let b = s[value: c.b] else { return nil }
        return (r, g, b)
    }

    func setRGB(_ v: (Int, Int, Int), _ p: Schema.Param, in t: Target) {
        guard let c = p.rgb, edited[t] != nil else { return }
        edited[t]![value: c.r] = v.0
        edited[t]![value: c.g] = v.1
        edited[t]![value: c.b] = v.2
    }

    func isChanged(_ p: Schema.Param, in t: Target) -> Bool {
        guard let e = edited[t], let l = loaded[t] else { return false }
        if p.isString { return e[string: p.addr] != l[string: p.addr] }
        return p.addrs.contains { e[value: $0] != l[value: $0] }
    }
}
