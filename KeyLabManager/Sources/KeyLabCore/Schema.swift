import Foundation

/// Parameter map of the KeyLab mkII, generated from the sysex-controls project (GPL-3.0)
/// by tools/gen_schema.py and bundled as kl2-schema.json.
public struct Schema: Codable, Sendable {
    public struct PresetInfo: Codable, Sendable, Hashable, Identifiable {
        public var id: Int
        public var name: String
        public var readonly: Bool?
    }

    public struct PAddr: Codable, Sendable, Hashable {
        public var bank: Int
        public var param: Int
        public var ctrl: Int
        public func addr(preset: UInt8) -> Addr {
            Addr(bank: UInt8(bank), preset: preset, param: UInt8(param), ctrl: UInt8(ctrl))
        }
    }

    public struct Option: Codable, Sendable, Hashable {
        public var value: Int
        public var label: String
        public init(value: Int, label: String) { self.value = value; self.label = label }
    }

    public struct Condition: Codable, Sendable, Hashable {
        public var param: String
        public var `in`: [Int]
        /// Key of another item holding `param` (nil = same item).
        public var item: String?
    }

    public struct Param: Codable, Sendable, Hashable, Identifiable {
        public var key: String
        public var title: String
        public var kind: String          // enum | int | string | bool | channel | note | color
        public var addr: PAddr
        public var addr2: PAddr?
        public var addr3: PAddr?
        public var options: [Option]?
        public var min: Int?
        public var max: Int?
        public var maxlen: Int?
        public var multiply: Double?
        public var inverted: Bool?
        public var useCcOffset: Bool?
        public var writeOnly: Bool?
        public var visibleIf: [Condition]?
        public var widget: String?
        public var rgb: RGB?

        public var id: String { "\(key)|\(addr.bank).\(addr.param).\(addr.ctrl)|\(visibleIf?.description ?? "")" }
        public var isString: Bool { kind == "string" }
        public var addrs: [PAddr] {
            if let c = rgb { return [c.r, c.g, c.b] }
            return [addr] + [addr2, addr3].compactMap { $0 }
        }
    }

    public struct RGB: Codable, Sendable, Hashable {
        public var r: PAddr
        public var g: PAddr
        public var b: PAddr
    }

    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var key: String
        public var title: String
        public var params: [Param]
        public var id: String { key }
    }

    public struct Section: Codable, Sendable, Hashable, Identifiable {
        public var key: String
        public var title: String
        public var items: [Item]
        public var id: String { key }
    }

    public struct StrAddr: Codable, Sendable, Hashable {
        public var param: Int
        public var ctrl: Int
        public var maxlen: Int?
    }

    public var presets: [PresetInfo]
    public var presetName: StrAddr
    public var global: [Section]
    public var preset: [Section]

    public static let shared: Schema = {
        // Inside the .app the JSON is copied straight into Contents/Resources.
        guard let url = Bundle.main.url(forResource: "kl2-schema", withExtension: "json")
                ?? Bundle.module.url(forResource: "kl2-schema", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let schema = try? JSONDecoder().decode(Schema.self, from: data)
        else { fatalError("kl2-schema.json missing or invalid") }
        return schema
    }()

    public var userPresets: [PresetInfo] { presets.filter { $0.readonly != true } }

    /// All distinct value / string addresses (preset-relative) used by a list of sections.
    public static func addresses(in sections: [Section], includeWriteOnly: Bool = false) -> (values: [PAddr], strings: [StrSpec]) {
        var values = Set<PAddr>(), strings = [PAddr: Int]()
        for s in sections { for i in s.items { for p in i.params where includeWriteOnly || p.writeOnly != true {
            if p.isString { strings[p.addr] = max(strings[p.addr] ?? 0, p.maxlen ?? 16) }
            else { p.addrs.forEach { values.insert($0) } }
        } } }
        let sortedValues = values.sorted { ($0.bank, $0.param, $0.ctrl) < ($1.bank, $1.param, $1.ctrl) }
        let sortedStrings = strings.map { StrSpec(addr: $0.key, maxlen: $0.value) }
            .sorted { ($0.addr.bank, $0.addr.param, $0.addr.ctrl) < ($1.addr.bank, $1.addr.param, $1.addr.ctrl) }
        return (sortedValues, sortedStrings)
    }

    public struct StrSpec: Sendable, Hashable { public var addr: PAddr; public var maxlen: Int }
}
