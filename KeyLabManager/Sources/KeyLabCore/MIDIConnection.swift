import CoreMIDI
import Foundation

public enum KeyLabError: Error, LocalizedError {
    case deviceNotFound
    case midi(String, OSStatus)
    case timeout(String)
    case badFile(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "KeyLab mkII not found. Check the USB connection."
        case let .midi(what, status): return "CoreMIDI error in \(what): \(status)"
        case let .timeout(what): return "The keyboard did not answer: \(what)"
        case let .badFile(why): return "Invalid file: \(why)"
        }
    }
}

/// Thin CoreMIDI wrapper: connects to the KeyLab's "MIDI" (not "DAW") port pair,
/// sends raw bytes and reassembles incoming SysEx messages.
final class MIDIConnection: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()
    private var buffer: [UInt8] = []
    private var inSysex = false

    /// Called on the CoreMIDI thread for each complete SysEx message (F0 … F7).
    var onSysex: (([UInt8]) -> Void)?
    private(set) var portName = ""

    init() throws {
        var status = MIDIClientCreateWithBlock("KeyLab Manager" as CFString, &client) { _ in }
        guard status == noErr else { throw KeyLabError.midi("client", status) }
        status = MIDIOutputPortCreate(client, "out" as CFString, &outPort)
        guard status == noErr else { throw KeyLabError.midi("output port", status) }
        status = MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { [weak self] list, _ in
            self?.receive(list)
        }
        guard status == noErr else { throw KeyLabError.midi("input port", status) }

        guard let src = Self.find(count: MIDIGetNumberOfSources(), get: MIDIGetSource),
              let dst = Self.find(count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination)
        else { throw KeyLabError.deviceNotFound }
        source = src.0
        destination = dst.0
        portName = dst.1
        status = MIDIPortConnectSource(inPort, source, nil)
        guard status == noErr else { throw KeyLabError.midi("connect", status) }
    }

    deinit {
        MIDIPortDisconnectSource(inPort, source)
        MIDIClientDispose(client)
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() {
            return s as String
        }
        return ""
    }

    private static func find(count: Int, get: (Int) -> MIDIEndpointRef) -> (MIDIEndpointRef, String)? {
        for i in 0..<count {
            let ep = get(i)
            let n = name(of: ep)
            if n.contains("KeyLab mkII"), !n.contains("DAW") { return (ep, n) }
        }
        return nil
    }

    func send(_ bytes: [UInt8]) throws {
        let size = 1024
        var storage = [UInt8](repeating: 0, count: size)
        let status: OSStatus = storage.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            let packet = MIDIPacketListInit(list)
            _ = MIDIPacketListAdd(list, size, packet, 0, bytes.count, bytes)
            return MIDISend(outPort, destination, list)
        }
        guard status == noErr else { throw KeyLabError.midi("send", status) }
    }

    private func receive(_ list: UnsafePointer<MIDIPacketList>) {
        for packet in list.unsafeSequence() {
            let bytes = UnsafeRawBufferPointer(start: MIDIPacketGetData(packet),
                                               count: Int(packet.pointee.length))
            for b in bytes {
                if b >= 0xF8 { continue }               // real-time bytes may interleave
                if b == 0xF0 { inSysex = true; buffer = [b]; continue }
                guard inSysex else { continue }
                if b == 0xF7 {
                    buffer.append(b)
                    inSysex = false
                    onSysex?(buffer)
                } else if b & 0x80 != 0 {
                    inSysex = false                    // aborted by another status byte
                } else {
                    buffer.append(b)
                }
            }
        }
    }
}

private func MIDIPacketGetData(_ p: UnsafePointer<MIDIPacket>) -> UnsafeRawPointer {
    UnsafeRawPointer(p).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!)
}
