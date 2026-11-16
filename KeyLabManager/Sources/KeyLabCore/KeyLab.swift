import Foundation

/// Address of one parameter. On the wire: bank selects the command byte (+0x30 / +0x40),
/// then preset, param, ctrl. Preset 0 = global device settings, 3…12 = User 1…10.
public struct Addr: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var bank: UInt8
    public var preset: UInt8
    public var param: UInt8
    public var ctrl: UInt8

    public init(bank: UInt8 = 0, preset: UInt8, param: UInt8, ctrl: UInt8) {
        self.bank = bank; self.preset = preset; self.param = param; self.ctrl = ctrl
    }

    /// Key used in backup files: "bank.param.ctrl" in hex (preset-independent).
    public var key: String { String(format: "%d.%02X.%02X", bank, param, ctrl) }

    public init?(key: String, preset: UInt8) {
        let parts = key.split(separator: ".")
        guard parts.count == 3, let b = UInt8(parts[0]), let p = UInt8(parts[1], radix: 16),
              let c = UInt8(parts[2], radix: 16) else { return nil }
        self.init(bank: b, preset: preset, param: p, ctrl: c)
    }

    public var description: String { String(format: "b%d pr%02X p%02X c%02X", bank, preset, param, ctrl) }

    public static func < (a: Addr, b: Addr) -> Bool {
        (a.preset, a.bank, a.param, a.ctrl) < (b.preset, b.bank, b.param, b.ctrl)
    }
}

/// Blocking request/response access to a KeyLab mkII. All calls are serialized on an
/// internal queue; use the async wrappers from UI code.
public final class KeyLab: @unchecked Sendable {
    static let header: [UInt8] = [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42]
    private static let bankOffset: [UInt8] = [0x00, 0x30, 0x40]

    private let conn: MIDIConnection
    private let queue = DispatchQueue(label: "keylab.io")
    private let lock = NSLock()
    private var matcher: (([UInt8]) -> Bool)?
    private var reply: [UInt8]?
    private let signal = DispatchSemaphore(value: 0)

    public var timeout: TimeInterval = 0.25
    public var retries = 2
    public var portName: String { conn.portName }

    public init() throws {
        conn = try MIDIConnection()
        conn.onSysex = { [weak self] msg in self?.deliver(msg) }
    }

    private func deliver(_ msg: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        if let m = matcher, m(msg) {
            matcher = nil
            reply = msg
            signal.signal()
        }
    }

    /// Run `body` on the serial I/O queue.
    public func run<T: Sendable>(_ body: @escaping @Sendable (KeyLab) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try body(self) }) }
        }
    }

    // MARK: - Low level

    private func request(_ bytes: [UInt8], what: String, match: @escaping ([UInt8]) -> Bool) throws -> [UInt8] {
        for _ in 0...retries {
            lock.lock()
            while signal.wait(timeout: .now()) == .success {}   // drain stale signals
            reply = nil
            matcher = match
            lock.unlock()
            try conn.send(bytes)
            if signal.wait(timeout: .now() + timeout) == .success {
                lock.lock(); defer { lock.unlock() }
                if let r = reply { return r }
            }
            lock.lock(); matcher = nil; lock.unlock()
        }
        throw KeyLabError.timeout(what)
    }

    private func cmd(_ base: UInt8, _ a: Addr) -> UInt8 { base + Self.bankOffset[Int(min(a.bank, 2))] }

    // MARK: - Values

    public func read(_ a: Addr) throws -> UInt8 {
        let msg = Self.header + [cmd(0x01, a), a.preset, a.param, a.ctrl, 0xF7]
        let expect = Self.header + [cmd(0x02, a), a.preset, a.param, a.ctrl]
        let r = try request(msg, what: "read \(a)") { $0.count == expect.count + 2 && Array($0.prefix(expect.count)) == expect }
        return r[r.count - 2]
    }

    public func write(_ a: Addr, _ value: UInt8) throws {
        try conn.send(Self.header + [cmd(0x02, a), a.preset, a.param, a.ctrl, value & 0x7F, 0xF7])
        usleep(3_000)
    }

    /// The keyboard occasionally drops writes, so read each value back and resend until it sticks.
    public func writeVerified(_ a: Addr, _ value: UInt8, attempts: Int = 5) throws {
        let v = value & 0x7F
        for attempt in 0..<attempts {
            try write(a, v)
            if (try? read(a)) == v { return }
            usleep(UInt32(20_000 * (attempt + 1)))
        }
        throw KeyLabError.timeout("write \(a) = \(v) was not accepted")
    }

    public func writeStringVerified(_ a: Addr, _ text: String, maxLength: Int = 16, attempts: Int = 5) throws {
        let want = String(text.prefix(maxLength))
        let norm = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        for attempt in 0..<attempts {
            try writeString(a, want, maxLength: maxLength)
            if let got = try? readString(a), norm(got) == norm(want) { return }
            usleep(UInt32(20_000 * (attempt + 1)))
        }
        throw KeyLabError.timeout("text write \(a) was not accepted")
    }

    // MARK: - Strings

    public func readString(_ a: Addr) throws -> String {
        let msg = Self.header + [cmd(0x03, a), a.preset, a.param, a.ctrl, 0xF7]
        let expect = Self.header + [cmd(0x04, a), a.preset, a.param, a.ctrl]
        let r = try request(msg, what: "read text \(a)") { $0.count > expect.count && Array($0.prefix(expect.count)) == expect }
        let chars = r.dropFirst(expect.count).dropLast().prefix { $0 != 0 }
        return String(decoding: chars, as: UTF8.self)
    }

    public func writeString(_ a: Addr, _ text: String, maxLength: Int = 16) throws {
        let ascii = text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F ? UInt8($0.value) : UInt8(ascii: "?") }
        try conn.send(Self.header + [cmd(0x04, a), a.preset, a.param, a.ctrl] + ascii.prefix(maxLength) + [0x00, 0xF7])
        usleep(5_000)
    }

    // MARK: - Presets

    /// Make preset `id` (3…12 = User 1…10) the active one on the keyboard.
    public func recall(preset id: UInt8) throws {
        try conn.send(Self.header + [0x05, id, 0xF7])
        usleep(50_000)
    }

    /// Save the edit buffer (the preset accessed last) into slot `id`. Call right after writing to `id`.
    public func store(preset id: UInt8) throws {
        usleep(20_000)
        try conn.send(Self.header + [0x06, id, 0xF7])
        usleep(100_000)
        // After a store, reads of `id` keep returning the pre-write contents (and further writes would
        // build on them) until another preset has been accessed. Touch a different preset so the next
        // access to `id` reloads the stored slot.
        let other: UInt8 = id == 3 ? 4 : 3
        let n = Schema.shared.presetName
        _ = try? readString(Addr(preset: other, param: UInt8(n.param), ctrl: UInt8(n.ctrl)))
    }

    // MARK: - Device

    /// Returns firmware version string from the universal identity reply.
    public func identity() throws -> (model: String, firmware: String) {
        let r = try request([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], what: "identity") {
            $0.count >= 15 && $0[1] == 0x7E && $0[3] == 0x06 && $0[4] == 0x02
        }
        // F0 7E dev 06 02 00 20 6B fam fam mem mem v1 v2 v3 v4 F7
        let v = r.count >= 17 ? Array(r[12...15]) : []
        let firmware = v.count == 4 ? "\(v[3]).\(v[2]).\(v[1]).\(v[0])" : "?"
        return ("KeyLab mkII", firmware)
    }
}
