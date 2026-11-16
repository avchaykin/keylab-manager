import Foundation

/// Raw contents of one preset (or of the global settings): every byte value and string,
/// keyed by "bank.PARAM.CTRL" (hex), independent of which slot it came from.
public struct Snapshot: Codable, Sendable, Equatable {
    public var name: String
    public var values: [String: Int]
    public var strings: [String: String]

    public init(name: String = "", values: [String: Int] = [:], strings: [String: String] = [:]) {
        self.name = name; self.values = values; self.strings = strings
    }

    public subscript(value a: Schema.PAddr) -> Int? {
        get { values[Self.key(a)] }
        set { values[Self.key(a)] = newValue }
    }

    public subscript(string a: Schema.PAddr) -> String? {
        get { strings[Self.key(a)] }
        set { strings[Self.key(a)] = newValue }
    }

    public static func key(_ a: Schema.PAddr) -> String { String(format: "%d.%02X.%02X", a.bank, a.param, a.ctrl) }

    /// Keys whose value differs between two snapshots.
    public func differences(from other: Snapshot) -> (values: [String], strings: [String]) {
        let v = Set(values.keys).union(other.values.keys).filter { values[$0] != other.values[$0] }.sorted()
        let s = Set(strings.keys).union(other.strings.keys).filter { strings[$0] != other.strings[$0] }.sorted()
        return (v, s)
    }
}

/// A backup file: global settings plus any number of User presets (keyed by user number 1…10).
public struct Backup: Codable, Sendable {
    public var format = "keylab-mkii-backup"
    public var version = 1
    public var created = Date()
    public var device: String
    public var firmware: String
    public var global: Snapshot?
    public var presets: [String: Snapshot]

    public init(device: String, firmware: String, global: Snapshot?, presets: [String: Snapshot]) {
        self.device = device; self.firmware = firmware; self.global = global; self.presets = presets
    }

    public static func load(from url: URL) throws -> Backup {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let b = try d.decode(Backup.self, from: Data(contentsOf: url))
        guard b.format == "keylab-mkii-backup" else { throw KeyLabError.badFile("not a KeyLab mkII backup") }
        return b
    }

    public func save(to url: URL) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

public extension Schema {
    /// Wire preset id for User n (1…10).
    static func presetID(user n: Int) -> UInt8 { UInt8(n + 2) }
}

public extension KeyLab {
    typealias Progress = @Sendable (Double) -> Void

    /// Read all parameters of a preset (preset 0 + `schema.global` for device settings).
    func readSnapshot(preset: UInt8, sections: [Schema.Section], schema: Schema = .shared,
                      progress: Progress? = nil) throws -> Snapshot {
        let (values, strings) = Schema.addresses(in: sections)
        var snap = Snapshot()
        let total = Double(values.count + strings.count + 1)
        var done = 0.0
        if preset != 0 {
            let n = schema.presetName
            snap.name = try readString(Addr(preset: preset, param: UInt8(n.param), ctrl: UInt8(n.ctrl)))
                .trimmingCharacters(in: .whitespaces)
        }
        for a in values {
            // Some addresses only exist in some modes; a timeout there is not fatal.
            if let v = try? read(a.addr(preset: preset)) { snap[value: a] = Int(v) }
            done += 1; progress?(done / total)
        }
        for s in strings {
            if let v = try? readString(s.addr.addr(preset: preset)) { snap[string: s.addr] = v }
            done += 1; progress?(done / total)
        }
        progress?(1)
        return snap
    }

    /// Write the differences between `snap` and `current` (or everything when `current` is nil),
    /// then store the preset permanently.
    @discardableResult
    func writeSnapshot(_ snap: Snapshot, preset: UInt8, over current: Snapshot? = nil,
                       schema: Schema = .shared, includeName: Bool = true, progress: Progress? = nil) throws -> Int {
        var valueKeys = Array(snap.values.keys), stringKeys = Array(snap.strings.keys)
        if let c = current {
            let d = snap.differences(from: c)
            valueKeys = d.values.filter { snap.values[$0] != nil }
            stringKeys = d.strings.filter { snap.strings[$0] != nil }
        }
        let nameChanged = includeName && preset != 0 && (current == nil || current!.name != snap.name)
        let total = Double(valueKeys.count + stringKeys.count + 2)
        var done = 0.0
        for k in valueKeys.sorted() {
            guard let a = Addr(key: k, preset: preset), let v = snap.values[k] else { continue }
            try writeVerified(a, UInt8(clamping: v)); done += 1; progress?(done / total)
        }
        for k in stringKeys.sorted() {
            guard let a = Addr(key: k, preset: preset), let v = snap.strings[k] else { continue }
            try writeStringVerified(a, v); done += 1; progress?(done / total)
        }
        if nameChanged {
            let n = schema.presetName
            try writeStringVerified(Addr(preset: preset, param: UInt8(n.param), ctrl: UInt8(n.ctrl)), snap.name, maxLength: n.maxlen ?? 16)
        }
        let changes = valueKeys.count + stringKeys.count + (nameChanged ? 1 : 0)
        // Accessing preset N loads slot N into the edit buffer (preset 0); writes only change that
        // buffer and are discarded as soon as another preset is accessed. `06 N` commits the buffer
        // to slot N, so it must follow the writes directly, with no other preset touched in between.
        if preset != 0 && changes > 0 { try store(preset: preset) }
        progress?(1)
        return changes
    }
}
