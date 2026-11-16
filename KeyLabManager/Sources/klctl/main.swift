import Foundation
import KeyLabCore

// klctl — command-line access to KeyLab mkII presets (also used to test KeyLabCore).

func usage() -> Never {
    print("""
    usage: klctl <command>
      info                          device, firmware, preset names
      get  <preset> <bank> <param> <ctrl>      read one value (hex ids, preset 0 = global, 3-12 = User 1-10)
      set  <preset> <bank> <param> <ctrl> <v>  write one value and store the preset
      dump <user 1-10>              print every parameter of a User preset
      backup <file.json> [users]    save global + User presets (default all), e.g. 1,2,5
      restore <file.json> <from> <to>   write User <from> from backup into User <to> and store it
      copy <from> <to>              copy User preset <from> to <to> and store it
      recall <user 1-10>            send 05 (MCC "recall from"; does NOT switch the active preset)
      store <user 1-10>             save the edit buffer into a User preset
    """)
    exit(2)
}

func hex(_ s: String) -> UInt8 { UInt8(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16) ?? { usage() }() }
func user(_ s: String) -> Int { guard let n = Int(s), (1...10).contains(n) else { usage() }; return n }

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
let schema = Schema.shared

do {
    let kl = try KeyLab()
    switch command {
    case "info":
        let id = try kl.identity()
        print("\(id.model) on \(kl.portName), firmware \(id.firmware)")
        for p in schema.userPresets {
            let n = schema.presetName
            let name = try kl.readString(Addr(preset: UInt8(p.id), param: UInt8(n.param), ctrl: UInt8(n.ctrl)))
            print(String(format: "  %@ (id %02X): %@", p.name, p.id, name.trimmingCharacters(in: .whitespaces)))
        }

    case "get" where args.count == 5:
        let a = Addr(bank: hex(args[2]), preset: hex(args[1]), param: hex(args[3]), ctrl: hex(args[4]))
        print("\(a) = \(try kl.read(a))")

    case "set" where args.count == 6:
        let a = Addr(bank: hex(args[2]), preset: hex(args[1]), param: hex(args[3]), ctrl: hex(args[4]))
        try kl.writeVerified(a, UInt8(args[5]) ?? hex(args[5]))
        if a.preset != 0 { try kl.store(preset: a.preset) }
        print("\(a) = \(try kl.read(a))\(a.preset != 0 ? " (stored)" : "")")

    case "dump" where args.count == 2:
        let pid = Schema.presetID(user: user(args[1]))
        let snap = try kl.readSnapshot(preset: pid, sections: schema.preset)
        print("User \(args[1]): \(snap.name)")
        for s in schema.preset {
            print("\n== \(s.title)")
            for item in s.items {
                let shown = item.params.compactMap { p -> String? in
                    if let conds = p.visibleIf {
                        for c in conds {
                            guard let sib = item.params.first(where: { $0.key == c.param }),
                                  let v = snap[value: sib.addr], c.in.contains(v) else { return nil }
                        }
                    }
                    if p.isString { return "\(p.title)=\"\(snap[string: p.addr] ?? "?")\"" }
                    guard let v = snap[value: p.addr] else { return "\(p.title)=?" }
                    let label = p.options?.first(where: { $0.value == v })?.label
                    return "\(p.title)=\(label ?? String(v))"
                }
                print("  \(item.title): " + shown.joined(separator: ", "))
            }
        }

    case "backup" where args.count >= 2:
        let users = args.count > 2 ? args[2].split(separator: ",").map { user(String($0)) } : Array(1...10)
        let id = try kl.identity()
        print("reading global settings…")
        let global = try kl.readSnapshot(preset: 0, sections: schema.global)
        var presets = [String: Snapshot]()
        for u in users {
            presets[String(u)] = try kl.readSnapshot(preset: Schema.presetID(user: u), sections: schema.preset)
            print("  User \(u): \(presets[String(u)]!.name) (\(presets[String(u)]!.values.count) values)")
        }
        try Backup(device: kl.portName, firmware: id.firmware, global: global, presets: presets)
            .save(to: URL(fileURLWithPath: args[1]))
        print("saved \(args[1])")

    case "restore" where args.count == 4:
        let b = try Backup.load(from: URL(fileURLWithPath: args[1]))
        guard let snap = b.presets[String(user(args[2]))] else { throw KeyLabError.badFile("User \(args[2]) not in backup") }
        let to = Schema.presetID(user: user(args[3]))
        let current = try kl.readSnapshot(preset: to, sections: schema.preset)
        let n = try kl.writeSnapshot(snap, preset: to, over: current)
        print("wrote \(n) changes into User \(args[3]) (verified)")

    case "copy" where args.count == 3:
        let from = Schema.presetID(user: user(args[1])), to = Schema.presetID(user: user(args[2]))
        let snap = try kl.readSnapshot(preset: from, sections: schema.preset)
        let current = try kl.readSnapshot(preset: to, sections: schema.preset)
        let n = try kl.writeSnapshot(snap, preset: to, over: current)
        print("copied User \(args[1]) → User \(args[2]): \(n) changes (verified)")

    case "recall" where args.count == 2:
        try kl.recall(preset: Schema.presetID(user: user(args[1]))); usleep(300_000)
    case "store" where args.count == 2:
        try kl.store(preset: Schema.presetID(user: user(args[1])))
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
