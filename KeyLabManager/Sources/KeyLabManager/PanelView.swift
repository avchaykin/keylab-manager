import KeyLabCore
import SwiftUI

// Visual editor for a User preset: a blueprint-style vector drawing of the KeyLab 88 mkII (white
// edition) on top, and a comparison grid of the selected control group underneath.
//
// Geometry is measured from a top-down product photo (1200 px wide; the instrument spans x 5…1195)
// and the front/rear panel close-ups in the user manual (p. 5–7). All drawing coordinates below are
// in those photo pixels; the rear-panel view sits underneath the top view.

// MARK: - Selection & groups

struct PanelSelection: Equatable {
    var group = "pads"
    var column: Int?
    var element: String?
}

/// A set of similar controls shown side by side in the grid: one column per control,
/// one block of rows per section (e.g. Encoder / Fader / Select for the 9 channel strips).
struct PanelGroup: Identifiable {
    struct Column {
        let title: String
        /// Item key per section (nil = this control has nothing in that section). "bank*" = current bank.
        let items: [String?]
    }
    let id: String
    let title: String
    let sections: [String]
    let columns: [Column]

    static let all: [PanelGroup] = [
        PanelGroup(id: "keyboard", title: "Keyboard", sections: ["Part", "Split", "Buttons & Aftertouch"], columns: [
            Column(title: "Part 1", items: ["keyboard.part1", "keyboard.splitMode", "keyboard.octButtonsAssign"]),
            Column(title: "Part 2", items: ["keyboard.part2", nil, nil]),
        ]),
        PanelGroup(id: "wheels", title: "Wheels", sections: ["Wheel"], columns: [
            Column(title: "Pitch Bend", items: ["pitchMod.pitchBend"]),
            Column(title: "Mod Wheel", items: ["pitchMod.modWheel"]),
        ]),
        PanelGroup(id: "pedals", title: "Pedals", sections: ["Pedal"], columns: [
            Column(title: "Sustain", items: ["pedals.sustainPedal"]),
            Column(title: "Expression", items: ["pedals.expressionPedal"]),
            Column(title: "AUX 1", items: ["pedals.aux1Pedal"]),
            Column(title: "AUX 2", items: ["pedals.aux2Pedal"]),
            Column(title: "AUX 3", items: ["pedals.aux3Pedal"]),
        ]),
        PanelGroup(id: "cv", title: "CV / Gate", sections: ["Connector", "More", "Assignment"], columns: [
            Column(title: "Pitch Out", items: ["cv.cvPitch", "cv.notePriority", "cv.pitchAssignment"]),
            Column(title: "Gate Out", items: ["cv.cvGate", nil, nil]),
            Column(title: "Mod 1", items: ["cv.modulationCV1", nil, nil]),
            Column(title: "Mod 2", items: ["cv.modulationCV2", nil, nil]),
            Column(title: "CV In", items: ["cv.cvModulationInput", "cv.channel", nil]),
        ]),
        PanelGroup(id: "pads", title: "Pads", sections: ["Pad"],
                   columns: (1...16).map { Column(title: "Pad \($0)", items: ["pads.pad\($0)"]) }),
        PanelGroup(id: "columns", title: "Knobs · Faders · Select", sections: ["Encoder", "Fader", "Select button"],
                   columns: (1...9).map { Column(title: "\($0)", items: ["bank*.col\($0).encoder", "bank*.col\($0).fader", "bank*.col\($0).select"]) }),
        PanelGroup(id: "daw", title: "DAW Buttons", sections: ["Button"], columns: [
            ("Solo", "solo"), ("Mute", "mute"), ("Record", "rec"), ("Read", "read"), ("Write", "off"),
            ("Save", "save"), ("In", "in"), ("Out", "out"), ("Metro", "marker"), ("Undo", "undo"),
        ].map { Column(title: $0.0, items: ["dawButtons.\($0.1)"]) }),
    ]

    static func named(_ id: String) -> PanelGroup { all.first { $0.id == id } ?? all[0] }
}

extension AppModel {
    func item(_ key: String, in t: Target) -> Schema.Item? {
        sections(for: t).lazy.flatMap(\.items).first { $0.key == key }
    }

    /// The visible parameter with `key` in `item` (several rows may share a key under different conditions).
    func visibleParam(_ key: String, in item: Schema.Item, target t: Target) -> Schema.Param? {
        item.params.first { $0.key == key && isVisible($0, item: item, in: t) }
    }

    func optionLabel(_ key: String, in item: Schema.Item, target t: Target) -> String? {
        guard let p = visibleParam(key, in: item, target: t), let v = value(p, in: t) else { return nil }
        return p.options?.first { $0.value == v }?.label ?? String(v)
    }

    /// Short description of what a control sends, e.g. "CC 74", "C1", "PC 5", "Off".
    func summary(of item: Schema.Item, in t: Target) -> String {
        if let m = item.params.first(where: { $0.key == "mode" || $0.key == "enabled" }), value(m, in: t) == 0 { return "Off" }
        func v(_ k: String) -> Int? { visibleParam(k, in: item, target: t).flatMap { value($0, in: t) } }
        if let n = v("note") { return Self.noteName(n) }
        if let n = v("programChange") { return "PC \(n)" }
        if let n = v("userPreset") { return "User \(n + 1)" }
        if let n = v("cc") { return "CC \(n)" }
        if visibleParam("rpnNRPNMSB", in: item, target: t) != nil { return "NRPN" }
        if item.key == "pitchMod.pitchBend" { return "Bend" }
        // The part a control plays on is a setting, not what it sends: keep it out of the value slot.
        if let m = item.params.first(where: { $0.options?.isEmpty == false && $0.key != "channel" }), let val = value(m, in: t),
           let label = m.options?.first(where: { $0.value == val })?.label { return label }
        return ""
    }

    /// Comparable representation of a parameter's current value (for difference highlighting).
    func valueKey(_ p: Schema.Param, in t: Target) -> String {
        if p.isString { return edited[t]?[string: p.addr]?.trimmingCharacters(in: .whitespaces) ?? "" }
        if p.rgb != nil { return rgb(p, in: t).map { "\($0.0),\($0.1),\($0.2)" } ?? "" }
        return value(p, in: t).map(String.init) ?? ""
    }

    nonisolated static func noteName(_ n: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[((n % 12) + 12) % 12])\(n / 12 - 2)"
    }
}

// MARK: - Editor (drawing + grid)

struct PanelEditor: View {
    @Environment(AppModel.self) private var model
    let target: Target
    let nameBinding: Binding<String>
    @Binding var selection: PanelSelection
    @Binding var bank: Int
    @AppStorage("panelZoom") private var zoom = "controls"

    var body: some View {
        VSplitView {
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    BPCaption("Name")
                    BPTextField(text: nameBinding, placeholder: "Preset name").frame(width: 170)
                    Spacer()
                    BPCaption("Bank")
                    BPTabs(items: [(1, "1"), (2, "2"), (3, "3")], selection: $bank)
                        .help("Encoder / fader / select-button bank (the Live/Bank button on the keyboard)")
                    BPCaption("View")
                    BPTabs(items: [("controls", "Controls"), ("whole", "Whole")], selection: $zoom)
                }
                BlueprintView(target: target, selection: $selection, bank: $bank, zoom: zoom)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 260, idealHeight: 430, maxHeight: .infinity)
            .background(BP.paper)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    BPTabs(items: PanelGroup.all.map { ($0.id, $0.title) }, selection: $selection.group)
                    Spacer()
                    Legend()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Rectangle().fill(BP.hair).frame(height: 1)
                GroupGrid(target: target, group: PanelGroup.named(selection.group), bank: bank, selection: $selection)
            }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            .background(BP.paper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selection.group) { old, new in
            if old != new, selection.element.map({ Blueprint.control($0)?.group != new }) ?? true {
                selection.column = nil; selection.element = nil
            }
        }
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Rectangle().fill(BP.diff).frame(width: 14, height: 11)
                    .overlay(alignment: .leading) { Rectangle().fill(BP.ink.opacity(0.7)).frame(width: 2) }
                BPCaption("differs from row majority", size: 9)
            }
            HStack(spacing: 5) {
                BPChangedDot()
                BPCaption("not yet written", size: 9)
            }
        }
    }
}

// MARK: - Comparison grid

struct GroupGrid: View {
    @Environment(AppModel.self) private var model
    let target: Target
    let group: PanelGroup
    let bank: Int
    @Binding var selection: PanelSelection
    /// false = no scroll view (offscreen rendering).
    var scrolls = true

    private var cellWidth: CGFloat { group.columns.count > 10 ? 104 : group.columns.count > 5 ? 128 : 170 }
    private let labelWidth: CGFloat = 150

    var body: some View {
        if scrolls {
            ScrollView([.horizontal, .vertical]) { grid }
        } else {
            grid
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                BPCaption(group.id == "columns" ? "Bank \(bank)" : group.title)
                    .frame(width: labelWidth, alignment: .leading).padding(.leading, 12)
                ForEach(group.columns.indices, id: \.self) { c in header(c) }
            }
            ForEach(group.sections.indices, id: \.self) { s in
                if group.sections.count > 1 {
                    GridRow {
                        HStack(spacing: 8) {
                            BPCaption(group.sections[s], color: BP.ink)
                            Rectangle().fill(BP.hair).frame(height: 1)
                        }
                        .padding(.leading, 12).padding(.top, 10).padding(.bottom, 3)
                        .gridCellColumns(group.columns.count + 1)
                    }
                }
                ForEach(rows(section: s), id: \.id) { row in
                    GridRow {
                        Text(row.title).font(.system(size: 11.5)).foregroundStyle(BP.ink.opacity(0.85)).lineLimit(1)
                            .frame(width: labelWidth, alignment: .leading).padding(.leading, 12)
                        ForEach(group.columns.indices, id: \.self) { c in cell(c, s, row.id) }
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(BP.grid).frame(height: 1) }
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func item(_ c: Int, _ s: Int) -> Schema.Item? {
        guard let key = group.columns[c].items[s] else { return nil }
        return model.item(key.replacingOccurrences(of: "bank*", with: "bank\(bank)"), in: target)
    }

    private func editorRow(_ c: Int, _ s: Int, _ id: String) -> EditorRow? {
        item(c, s).flatMap { it in model.editorRows(it, in: target).first { $0.id == id } }
    }

    private struct Row { let id: String; let title: String }

    /// Union of the rows of the section's items (schema order), keeping rows visible in any column.
    private func rows(section s: Int) -> [Row] {
        var out: [Row] = [], seen = Set<String>(), titles = Set<String>()
        for c in group.columns.indices {
            guard let it = item(c, s) else { continue }
            for r in model.editorRows(it, in: target) where !seen.contains(r.id) {
                seen.insert(r.id)
                var title = r.title
                if titles.contains(title) { title = r.id == "mode2" ? "Fader Type" : "\(title) 2" }
                titles.insert(title)
                out.append(Row(id: r.id, title: title))
            }
        }
        return out
    }

    private func header(_ c: Int) -> some View {
        let selected = selection.column == c
        let led = group.sections.indices.lazy.compactMap { s -> Color? in
            guard let it = item(c, s), let p = model.visibleParam("color", in: it, target: target),
                  let (r, g, b) = model.rgb(p, in: target), r + g + b > 0 else { return nil }
            return BPColorWell.color(RGB7(r: r, g: g, b: b))
        }.first
        return HStack(spacing: 5) {
            if let led { Rectangle().fill(led).frame(width: 9, height: 9) }
            Text(group.columns[c].title.uppercased()).font(BP.label(10.5, .bold)).tracking(0.5).lineLimit(1)
        }
        .foregroundStyle(selected ? Color.black : BP.ink)
        .frame(width: cellWidth - 2, height: 24)
        .background(selected ? BP.ink : Color.clear)
        .overlay(Rectangle().strokeBorder(selected ? BP.ink : BP.hair, lineWidth: 1))
        .padding(.horizontal, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            selection.column = c
            selection.element = Blueprint.element(group: group.id, column: c)
        }
    }

    @ViewBuilder
    private func cell(_ c: Int, _ s: Int, _ id: String) -> some View {
        let row = editorRow(c, s, id)
        let isDiff = row.map { differs($0, s, id) } ?? false
        ZStack(alignment: .topTrailing) {
            if let row {
                RowEditor(row: row, target: target, compact: true)
                    .frame(width: cellWidth - 14)
                if model.rowChanged(row, in: target) { BPChangedDot().offset(x: -2, y: 2) }
            } else {
                Text("·").font(BP.mono(11)).foregroundStyle(BP.dim).frame(width: cellWidth - 14)
            }
        }
        .frame(width: cellWidth, height: 32)
        .background(isDiff ? BP.diff : .clear)
        .overlay(alignment: .leading) { if isDiff { Rectangle().fill(BP.ink.opacity(0.7)).frame(width: 2) } }
        .background(selection.column == c ? Color.white.opacity(0.05) : .clear)
    }

    /// True when this cell's value is not the majority value of its row (rows of all-unique values stay plain).
    private func differs(_ row: EditorRow, _ s: Int, _ id: String) -> Bool {
        var counts: [String: Int] = [:], order: [String] = []
        for col in group.columns.indices {
            guard let r = editorRow(col, s, id) else { continue }
            let v = model.rowValueKey(r, in: target)
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        let best = counts.values.max() ?? 0
        guard counts.count > 1, best >= 2 else { return false }
        let top = order.first { counts[$0] == best }
        return model.rowValueKey(row, in: target) != top
    }
}

// MARK: - Blueprint geometry

/// One interactive control on the drawing (photo-pixel coordinates).
struct HWControl {
    enum Kind { case pad, button, round, knob, fader, wheel, jack, keys, block }
    let id: String
    let kind: Kind
    let rect: CGRect
    var group: String?
    var column: Int?
    var item: String?
    var label: String?
}

enum Blueprint {
    /// Canvas: x 0…1200, y 340…730 — rear panel strip (340…414) above the top view (414…730).
    static let origin = CGPoint(x: 0, y: 340)
    static let size = CGSize(width: 1200, height: 390)
    /// Visible part of the canvas for each zoom.
    static func viewport(_ zoom: String) -> CGRect {
        zoom == "whole" ? CGRect(origin: origin, size: size) : r(0, 340, 845, 600)
    }
    static let rearY: CGFloat = 386

    static let padX: [CGFloat] = [136.4, 166.9, 197.4, 227.4]
    static let padY: [CGFloat] = [456.9, 481.7, 506.6, 531.9]
    static let stripX: [CGFloat] = [555.8, 583.5, 611.6, 638.8, 666.4, 694, 722.7, 750.4, 778]
    static let dawX: [CGFloat] = [276, 299, 322, 345, 368]

    static func r(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    static func c(_ x: CGFloat, _ y: CGFloat, _ rad: CGFloat) -> CGRect { CGRect(x: x - rad, y: y - rad, width: 2 * rad, height: 2 * rad) }

    static let controls: [HWControl] = {
        var a: [HWControl] = []
        for i in 0..<16 {
            a.append(HWControl(id: "pad\(i)", kind: .pad, rect: r(padX[i % 4], padY[i / 4], padX[i % 4] + 24.4, padY[i / 4] + 19.7),
                               group: "pads", column: i, item: "pads.pad\(i + 1)"))
        }
        for (i, x) in stripX.enumerated() {
            a.append(HWControl(id: "enc\(i)", kind: .knob, rect: c(x, 462.5, 7.2), group: "columns", column: i, item: "bank*.col\(i + 1).encoder"))
            a.append(HWControl(id: "fad\(i)", kind: .fader, rect: r(x - 6.1, 481, x + 6.1, 530.5), group: "columns", column: i, item: "bank*.col\(i + 1).fader"))
            a.append(HWControl(id: "sel\(i)", kind: .button, rect: r(x - 6.5, 542, x + 6.5, 548.8), group: "columns", column: i, item: "bank*.col\(i + 1).select"))
        }
        let daw = PanelGroup.named("daw").columns
        for i in 0..<10 {
            let x = dawX[i % 5], y: CGFloat = i < 5 ? 472.8 : 499
            a.append(HWControl(id: "daw\(i)", kind: .button, rect: r(x - 7, y, x + 7, y + 6.6), group: "daw", column: i,
                               item: daw[i].items[0], label: daw[i].title))
        }
        a.append(HWControl(id: "wheel0", kind: .wheel, rect: r(49, 454, 64, 498), group: "wheels", column: 0, item: "pitchMod.pitchBend", label: "Pitch"))
        a.append(HWControl(id: "wheel1", kind: .wheel, rect: r(75, 454, 89, 498), group: "wheels", column: 1, item: "pitchMod.modWheel", label: "Mod"))
        for (i, t) in ["Chord", "Trans", "Oct −", "Oct +"].enumerated() {
            let x0: CGFloat = i % 2 == 0 ? 48 : 74, y0: CGFloat = i < 2 ? 522.5 : 542
            a.append(HWControl(id: "kbtn\(i)", kind: .button, rect: r(x0, y0, x0 + 14.5, y0 + 6.2), group: "keyboard", column: 0,
                               item: "keyboard.octButtonsAssign", label: t))
        }
        a.append(HWControl(id: "part1", kind: .round, rect: c(530, 469.5, 3.6), group: "keyboard", column: 0, item: "keyboard.part1"))
        a.append(HWControl(id: "part2", kind: .round, rect: c(530, 495.3, 3.6), group: "keyboard", column: 1, item: "keyboard.part2"))
        a.append(HWControl(id: "bank", kind: .round, rect: c(530, 521, 3.6)))
        a.append(HWControl(id: "keys", kind: .keys, rect: r(33, 576, 1167, 715), group: "keyboard", item: "keyboard.splitMode"))
        a.append(HWControl(id: "title", kind: .block, rect: r(858, 486, 1150, 556), group: "keyboard"))
        // Rear panel, as seen from behind (manual p. 7).
        let cvCols = PanelGroup.named("cv").columns, pedalCols = PanelGroup.named("pedals").columns
        for (i, (t, x)) in [("Pitch Out", 268.0), ("Gate Out", 298.0), ("Mod 1", 328.0), ("Mod 2", 358.0)].enumerated() {
            a.append(HWControl(id: "cv\(i)", kind: .jack, rect: c(x, rearY, 3.4), group: "cv", column: i, item: cvCols[i].items[0], label: t))
        }
        let pedals: [(String, CGFloat, Int)] = [("AUX 3", 472, 4), ("AUX 2", 506, 3), ("AUX 1", 540, 2), ("Expression", 579, 1), ("Sustain", 619, 0)]
        for (t, x, col) in pedals {
            a.append(HWControl(id: "ped\(col)", kind: .jack, rect: c(x, rearY, 5.6), group: "pedals", column: col,
                               item: pedalCols[col].items[0], label: t))
        }
        a.append(HWControl(id: "cv4", kind: .jack, rect: c(651, rearY, 3.4), group: "cv", column: 4, item: "cv.cvModulationInput", label: "CV In"))
        return a
    }()

    static func control(_ id: String) -> HWControl? { controls.first { $0.id == id } }
    static func element(group: String, column: Int) -> String? {
        controls.first { $0.group == group && $0.column == column }?.id
    }
}

// MARK: - Blueprint view

struct BlueprintStyle {
    let paper = BP.paper
    let grid = BP.grid
    let gridMajor = BP.gridMajor
    let ink = BP.ink
    let faint = BP.faint
    let data = Color.white
    let select = Color.white
}

/// What the drawing shows for one control, computed from the model on the main actor.
private struct Annotation {
    var value = ""
    var name = ""
    var led: Color?
    var changed = false
}

private struct Info {
    var annotations: [String: Annotation] = [:]
    var presetName = ""
    var slot = ""
    var lines: [(String, String)] = []
    var split: Int?
}

struct BlueprintView: View {
    let target: Target
    @Binding var selection: PanelSelection
    @Binding var bank: Int
    let zoom: String

    var body: some View {
        GeometryReader { geo in
            let vp = Blueprint.viewport(zoom)
            let s = max(0.3, min(geo.size.width / vp.width, geo.size.height / vp.height))
            BlueprintCanvas(target: target, selection: $selection, bank: $bank, scale: s, viewport: vp)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }
}

/// The drawing at a fixed scale (points per photo pixel), with click targets.
struct BlueprintCanvas: View {
    @Environment(AppModel.self) private var model
    let target: Target
    @Binding var selection: PanelSelection
    @Binding var bank: Int
    let scale: CGFloat
    var viewport = CGRect(origin: Blueprint.origin, size: Blueprint.size)
    @Environment(\.displayScale) private var displayScale

    /// Smallest legible text on screen, in points (SF Pro Condensed): non-Retina pixels need bigger glyphs.
    static func minTextPoints(displayScale: CGFloat) -> CGFloat { displayScale >= 2 ? 7.5 : 9 }

    var body: some View {
        let s = scale
        let minText = Self.minTextPoints(displayScale: displayScale) / s
        let ds = max(displayScale, 1)
        let px = 1 / (s * ds)
        let info = makeInfo()
        let style = BlueprintStyle()
        let sel = selection, bk = bank, vp = viewport
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                ctx.scaleBy(x: s, y: s)
                ctx.translateBy(x: -vp.minX, y: -vp.minY)
                BlueprintPainter(ctx: ctx, st: style, info: info, sel: sel, bank: bk, minText: minText, px: px, scale: s, displayScale: ds).paint()
            }
            .frame(width: vp.width * s, height: vp.height * s)
            ForEach(Blueprint.controls.filter { vp.intersects($0.rect) }, id: \.id) { hw in hitArea(hw, s: s, info: info) }
        }
        .frame(width: vp.width * s, height: vp.height * s, alignment: .topLeading)
        .background(style.paper)
        .overlay(Rectangle().strokeBorder(BP.hair, lineWidth: 1))
        .clipped()
    }

    private func hitArea(_ hw: HWControl, s: CGFloat, info: Info) -> some View {
        let r = hw.rect.insetBy(dx: -2, dy: -2)
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: r.width * s, height: r.height * s)
            .help(help(hw, info))
            .onTapGesture { tap(hw) }
            .position(x: (r.midX - viewport.minX) * s, y: (r.midY - viewport.minY) * s)
    }

    private func tap(_ hw: HWControl) {
        if hw.id == "bank" { bank = bank % 3 + 1; return }
        guard let g = hw.group else { return }
        selection = PanelSelection(group: g, column: hw.column, element: hw.id)
    }

    private func help(_ hw: HWControl, _ info: Info) -> String {
        if hw.id == "bank" { return "Live / Bank — click to switch bank (now Bank \(bank))" }
        if hw.id == "title" || hw.id == "keys" { return "Keyboard: parts, split, transpose" }
        let title = hw.group.flatMap { g in hw.column.map { PanelGroup.named(g).columns[$0].title } } ?? ""
        let a = info.annotations[hw.id]
        return [title, a?.value ?? "", a?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func resolve(_ key: String) -> String { key.replacingOccurrences(of: "bank*", with: "bank\(bank)") }

    private func makeInfo() -> Info {
        var info = Info()
        for hw in Blueprint.controls {
            guard let key = hw.item, let it = model.item(resolve(key), in: target) else { continue }
            var a = Annotation()
            a.value = model.summary(of: it, in: target)
            if let p = model.visibleParam("name", in: it, target: target) {
                a.name = model.edited[target]?[string: p.addr]?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            if let p = model.visibleParam("color", in: it, target: target), let (r, g, b) = model.rgb(p, in: target), r + g + b > 0 {
                a.led = Color(red: Double(r) / 127, green: Double(g) / 127, blue: Double(b) / 127)
            }
            a.changed = it.params.contains { model.isChanged($0, in: target) }
            info.annotations[hw.id] = a
        }
        info.presetName = model.edited[target]?.name ?? ""
        info.slot = target.title
        func part(_ key: String) -> String {
            guard let it = model.item(key, in: target) else { return "" }
            let parts = [
                model.optionLabel("channel", in: it, target: target).map { "ch \($0)" },
                model.optionLabel("transposeOct", in: it, target: target).map { "oct \($0)" },
                model.optionLabel("transposeSemi", in: it, target: target).map { "semi \($0)" },
                model.optionLabel("keyVelocityCurve", in: it, target: target).map { "vel \($0)" },
            ]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
        if let it = model.item("keyboard.splitMode", in: target) {
            let mode = model.optionLabel("splitMode", in: it, target: target) ?? "?"
            if let m = model.visibleParam("splitMode", in: it, target: target), (model.value(m, in: target) ?? 0) != 0,
               let p = model.visibleParam("splitPoint", in: it, target: target), let v = model.value(p, in: target) {
                info.split = v
                info.lines = [("PART 1", part("keyboard.part1")), ("PART 2", part("keyboard.part2")),
                              ("SPLIT", "\(mode) at \(AppModel.noteName(v))")]
            } else {
                info.lines = [("KEYS", part("keyboard.part1")), ("SPLIT", mode)]
            }
        }
        if let it = model.item("keyboard.octButtonsAssign", in: target),
           let at = model.optionLabel("aftertouchAssign", in: it, target: target) {
            info.lines.append(("AFTERTOUCH", at))
        }
        info.lines.append(("BANK", "\(bank) of 3 (encoders · faders · select)"))
        return info
    }
}

// MARK: - Painter

private struct BlueprintPainter {
    var ctx: GraphicsContext
    let st: BlueprintStyle
    let info: Info
    let sel: PanelSelection
    let bank: Int
    /// Smallest text size and one device pixel, in drawing units.
    var minText: CGFloat = 0
    var px: CGFloat = 0
    /// Points per drawing unit, and device pixels per point.
    var scale: CGFloat = 1
    var displayScale: CGFloat = 2

    let hair: CGFloat = 0.45
    let line: CGFloat = 0.7

    func paint() {
        paintGrid()
        paintBody()
        paintKeys()
        paintStatic()
        for hw in Blueprint.controls { paintControl(hw) }
        paintTitleBlock()
        paintRear()
    }

    // Helpers
    func stroke(_ p: Path, _ c: Color? = nil, _ w: CGFloat? = nil) {
        ctx.stroke(p, with: .color(c ?? st.ink), lineWidth: max(w ?? line, px))
    }
    func fill(_ p: Path, _ c: Color) { ctx.fill(p, with: .color(c)) }
    func rect(_ r: CGRect, _ corner: CGFloat = 1) -> Path { Path(roundedRect: r, cornerRadius: corner) }
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: Color? = nil,
              weight: Font.Weight = .regular, anchor: UnitPoint = .center, mono: Bool = false, maxWidth: CGFloat? = nil, optional: Bool = false) {
        guard !s.isEmpty, !(optional && skipOptional(size)) else { return }
        let r = fitted(s, size, c, weight: weight, mono: mono, maxWidth: maxWidth)
        // Lay the text out in screen points with its left edge and baseline on whole device pixels, so small
        // glyphs are not smeared across pixel boundaries by the drawing's fractional scale.
        let p = CGPoint(x: x, y: y).applying(ctx.transform)
        let big = CGSize(width: 10_000, height: 1_000)
        let sz = r.measure(in: big), base = r.firstBaseline(in: big)
        func snap(_ v: CGFloat) -> CGFloat { (v * displayScale).rounded() / displayScale }
        let left = snap(p.x - anchor.x * sz.width)
        let top = snap(p.y - anchor.y * sz.height + base) - base
        var dc = ctx
        dc.transform = .identity
        dc.draw(r, at: CGPoint(x: left, y: top), anchor: .topLeading)
    }

    /// Secondary captions are left out when they would have to grow a lot to be legible (small drawing on a
    /// non-Retina screen): enlarged, they would collide with the controls around them.
    func skipOptional(_ size: CGFloat) -> Bool { minText > size * 2 }

    /// Text at `size` (drawing units), raised to the legible minimum, and cut with "…" when wider than
    /// `maxWidth` (the room a control's label has before it runs into the next control). The result is
    /// resolved in screen points, for drawing with an identity transform.
    /// SF Pro Condensed: narrow enough for the cramped labels, and still clear at 9 px on a 1x screen.
    func fitted(_ s: String, _ size: CGFloat, _ c: Color? = nil, weight: Font.Weight = .regular,
                mono: Bool = false, maxWidth: CGFloat? = nil) -> GraphicsContext.ResolvedText {
        let enlarged = minText > size
        // Thin strokes vanish on a 1x screen; give regular captions a bit more weight there.
        // Bold condensed glyphs clog up at 9 px, so use semibold for values there.
        let w = displayScale >= 2 ? weight : weight == .regular ? .medium : weight == .bold ? .semibold : weight
        func make(_ str: String, _ sz: CGFloat) -> GraphicsContext.ResolvedText {
            let f: Font = mono ? .system(size: sz, weight: w, design: .monospaced) : .system(size: sz, weight: w).width(.condensed)
            return ctx.resolve(Text(str).font(f).foregroundColor(c ?? st.ink))
        }
        let eff = (enlarged ? minText : size) * scale
        let big = CGSize(width: 10_000, height: 1_000)
        guard let limit = maxWidth.map({ $0 * scale }) else { return make(s, eff) }
        var r = make(s, eff)
        // "CC 52" → "52" before cutting: the number is the part that matters, and the CC type is in the tooltip.
        if r.measure(in: big).width > limit, s.hasPrefix("CC "), s.count > 3 {
            let short = make(String(s.dropFirst(3)), eff)
            if short.measure(in: big).width <= limit { return short }
        }
        var keep = s.count
        while r.measure(in: big).width > limit && keep > 1 {
            keep -= 1
            r = make(String(s.prefix(keep)).trimmingCharacters(in: .whitespaces) + "…", eff)
        }
        return r
    }
    func hline(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, _ c: Color? = nil, _ w: CGFloat? = nil) {
        var p = Path(); p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y)); stroke(p, c, w ?? hair)
    }
    func vline(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat, _ c: Color? = nil, _ w: CGFloat? = nil) {
        var p = Path(); p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1)); stroke(p, c, w ?? hair)
    }
    /// Horizontal room for a label centred on control `hw`: the distance to its nearest neighbour in the same row.
    func room(_ hw: HWControl) -> CGFloat {
        let r = hw.rect
        let d = Blueprint.controls.filter { $0.id != hw.id && $0.kind != .keys && $0.kind != .block && abs($0.rect.midY - r.midY) < 6 }
            .map { abs($0.rect.midX - r.midX) }.min() ?? 60
        return min(max(d - 1.5, r.width), 60)
    }
    var dawCompact: Bool {
        let narrowest = Blueprint.controls.filter { $0.group == "daw" }.map(room).min() ?? 60
        return fitted("CC 00", 4.2, weight: .bold).measure(in: CGSize(width: 1_000, height: 100)).width > narrowest * scale
    }
    func short(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    func paintGrid() {
        let o = Blueprint.origin, sz = Blueprint.size
        var minor = Path(), major = Path()
        for x in stride(from: CGFloat(0), through: sz.width, by: 10) {
            let isMajor = Int(x) % 50 == 0
            if isMajor { major.move(to: CGPoint(x: o.x + x, y: o.y)); major.addLine(to: CGPoint(x: o.x + x, y: o.y + sz.height)) }
            else { minor.move(to: CGPoint(x: o.x + x, y: o.y)); minor.addLine(to: CGPoint(x: o.x + x, y: o.y + sz.height)) }
        }
        for y in stride(from: CGFloat(0), through: sz.height, by: 10) {
            let isMajor = Int(y) % 50 == 0
            if isMajor { major.move(to: CGPoint(x: o.x, y: o.y + y)); major.addLine(to: CGPoint(x: o.x + sz.width, y: o.y + y)) }
            else { minor.move(to: CGPoint(x: o.x, y: o.y + y)); minor.addLine(to: CGPoint(x: o.x + sz.width, y: o.y + y)) }
        }
        stroke(minor, st.grid, 0.3)
        stroke(major, st.gridMajor, 0.45)
        text("TOP VIEW", 8, 421, 5.5, st.faint, weight: .bold, anchor: .leading)
        text("KEYLAB 88 MKII · USER-PRESET MAP", 60, 421, 4.5, st.faint, anchor: .leading)
    }

    func paintBody() {
        // Outer shell, panel/keybed lip, keybed rail
        stroke(rect(Blueprint.r(5, 429, 1195, 722), 5), st.ink, 0.9)
        hline(5, 1195, 572, st.ink, line)
        hline(5, 1195, 575, st.faint, hair)
        hline(18, 1182, 716.5, st.faint, hair)
        // Wooden end cheeks, hatched
        for x0 in [CGFloat(18), 1167] {
            let r = Blueprint.r(x0, 575, x0 + 15, 716)
            stroke(rect(r, 0.5), st.ink, line)
            var h = Path()
            var y = r.minY
            while y < r.maxY + r.width {
                h.move(to: CGPoint(x: r.minX, y: y))
                h.addLine(to: CGPoint(x: r.maxX, y: y - r.width))
                y += 5
            }
            var clipped = ctx
            clipped.clip(to: Path(r))
            clipped.stroke(h, with: .color(st.faint), lineWidth: 0.3)
        }
        // Logo
        text("KEYLAB", 1129, 455, 9, st.ink, weight: .heavy, anchor: .trailing)
        stroke(rect(Blueprint.r(1131, 448.5, 1149, 461.5), 1), st.ink, line)
        text("88", 1140, 455, 8, st.ink, weight: .heavy)
        text("mkII", 1094, 465.5, 5, st.ink, weight: .semibold, anchor: .leading)
    }

    func paintKeys() {
        let x0: CGFloat = 33, x1: CGFloat = 1167, y0: CGFloat = 576, y1: CGFloat = 715
        let w = (x1 - x0) / 52
        var whites = Path()
        for i in 1..<52 { whites.move(to: CGPoint(x: x0 + CGFloat(i) * w, y: y0)); whites.addLine(to: CGPoint(x: x0 + CGFloat(i) * w, y: y1)) }
        whites.addRect(Blueprint.r(x0, y0, x1, y1))
        stroke(whites, st.ink, hair)
        func isBlack(_ n: Int) -> Bool { [1, 3, 6, 8, 10].contains(n % 12) }
        var idx = 0
        for n in 21...108 {
            if isBlack(n) {
                let bx = x0 + CGFloat(idx) * w
                let r = Blueprint.r(bx - w * 0.29, y0, bx + w * 0.29, y0 + (y1 - y0) * 0.64)
                fill(rect(r, 0.8), st.paper)
                fill(rect(r, 0.8), Color(white: 0.30))
                stroke(rect(r, 0.8), st.ink, hair)
            } else { idx += 1 }
        }
        // MIDI channel numbers over the first 16 keys (MIDI Ch + key)
        hline(30.5, 247.5, 563.5, st.faint)
        vline(30.5, 561, 563.5, st.faint); vline(247.5, 561, 563.5, st.faint)
        for i in 0..<16 { text("\(i + 1)", 39 + CGFloat(i) * 12.9, 567.5, 3.4, st.faint) }
        // User-parameter shortcuts over the top octave
        text("USER PARAMETERS", 740, 560, 3.6, st.faint, weight: .semibold, optional: true)
        hline(661, 818, 563.5, st.faint)
        let shortcuts: [(String, CGFloat)] = [("Global", 664), ("Store", 690), ("Velo Curve", 705), ("Name", 719), ("Mode", 732),
                                              ("Option", 747), ("MIDI Ch", 761), ("CC", 772), ("Min LSB", 787), ("Max MSB", 807)]
        // All or nothing: a row with some names missing or cut off is just noise.
        let allFit = shortcuts.indices.allSatisfy { i in
            let x = shortcuts[i].1
            let gap = min(i > 0 ? x - shortcuts[i - 1].1 : 30, i < shortcuts.count - 1 ? shortcuts[i + 1].1 - x : 30)
            return fitted(shortcuts[i].0, 3.0).measure(in: CGSize(width: 1_000, height: 100)).width < (gap - 1) * scale
        }
        if allFit { for (t, x) in shortcuts { text(t, x, 567.5, 3.0, st.faint, optional: true) } }
        if let s = info.split, (21...108).contains(s) {
            let white = (21..<s).filter { !isBlack($0) }.count
            let sx = x0 + CGFloat(white) * w - (isBlack(s) ? w * 0.29 : 0)
            vline(sx, y0 - 2, y1 + 2, st.data, 1.4)
            text("SPLIT \(AppModel.noteName(s))", sx + 3, y1 - 6, 6, st.data, weight: .bold, anchor: .leading)
        }
    }

    func paintStatic() {
        // Pad-mode buttons + bracket to the pads
        let padModes: [(String, CGFloat)] = [("Pad", 469.5), ("Chord Memory", 495), ("Chord Transp.", 521)]
        for (t, y) in padModes {
            stroke(Path(ellipseIn: Blueprint.c(113.5, y, 3.5)), st.ink, line)
            text(t, 113.5, y + 7.5, 3.0, st.faint, maxWidth: 34, optional: true)
        }
        vline(125.6, 459, 536, st.faint); hline(125.6, 129, 459, st.faint); hline(125.6, 129, 536, st.faint)
        stroke(rect(Blueprint.r(105, 542, 119.5, 548.2)), st.faint, hair)
        text("MIDI Ch", 112.3, 552.5, 3.4, st.faint, optional: true)
        text("Reset", 68, 556.5, 3.2, st.faint, optional: true)
        hline(55, 63, 556.5, st.faint); hline(73, 81, 556.5, st.faint)
        // DAW section headings and transport
        text("DAW COMMANDS / USER", 322, 456.5, 3.6, st.faint, weight: .semibold)
        hline(268, 376.5, 459.7, st.faint)
        text("TRACK CONTROLS", 322, 468.8, 3.2, st.faint, optional: true)
        text("GLOBAL CONTROLS", 322, 495.3, 3.2, st.faint, optional: true)
        text("TRANSPORTS", 322, 528.8, 3.4, st.faint, weight: .semibold)
        hline(268, 376.5, 532.3, st.faint)
        for (i, t) in ["◀◀", "▶▶", "■", "❙❙▶", "●", "⟲"].enumerated() {
            let x = 275.7 + CGFloat(i) * 18.5
            stroke(rect(Blueprint.r(x - 7.7, 537, x + 7.7, 548.3), 1), st.faint, hair)
            text(t, x, 542.7, 3.6, st.faint)
        }
        // Display / browser block
        var bezel = Path()
        bezel.addRoundedRect(in: Blueprint.r(388.4, 454, 501, 538), cornerSize: CGSize(width: 3, height: 3))
        bezel.move(to: CGPoint(x: 388.4, y: 536)); bezel.addLine(to: CGPoint(x: 396, y: 551.6))
        bezel.addLine(to: CGPoint(x: 493.4, y: 551.6)); bezel.addLine(to: CGPoint(x: 501, y: 536))
        stroke(bezel, st.ink, line)
        let lcd = Blueprint.r(413.8, 466.3, 476, 481.7)
        fill(rect(lcd, 1), st.ink.opacity(0.08))
        stroke(rect(lcd, 1), st.ink, line)
        stroke(rect(lcd.insetBy(dx: -1.5, dy: -1.5), 1.5), st.faint, hair)
        // The slot line only fits above the name while text needs little enlarging.
        if minText < 6 { text(info.slot, 416.5, 470.5, 4.6, st.ink, anchor: .leading, mono: true) }
        text(short(info.presetName, 16), 416.5, 477.3, 5.2, st.data, weight: .bold, anchor: .leading, mono: true)
        for (t, x0) in [("Category", CGFloat(403.4)), ("Preset", 472.8)] {
            stroke(rect(Blueprint.r(x0, 499, x0 + 13.2, 504.7)), st.faint, hair)
            text(t, x0 + 6.6, 501.9, 2.6, st.faint, maxWidth: 22, optional: true)
        }
        for (t, x0) in [("←", CGFloat(410)), ("→", 465)] {
            stroke(rect(Blueprint.r(x0, 522.5, x0 + 13.3, 528)), st.faint, hair)
            text(t, x0 + 6.6, 525.2, 3.6, st.faint)
        }
        stroke(Path(ellipseIn: Blueprint.c(441, 511.7, 16)), st.faint, hair)
        stroke(Path(ellipseIn: Blueprint.c(441, 511.7, 11.7)), st.ink, line)
        vline(441, 501.5, 506, st.ink, line)
        for (i, t) in ["ANALOG LAB", "DAW", "USER"].enumerated() {
            let x0: CGFloat = [403.4, 431.6, 460][i]
            let r = Blueprint.r(x0, 542, x0 + 25.8, 548.8)
            let on = t == "USER"
            if on { fill(rect(r), st.ink.opacity(0.15)) }
            stroke(rect(r), on ? st.ink : st.faint, on ? line : hair)
            text(t, x0 + 12.9, 545.4, 2.8, on ? st.ink : st.faint, weight: .semibold, maxWidth: 27, optional: true)
        }
        text("ARTURIA", 444.7, 563.5, 6.5, st.ink, weight: .medium)
        // Part / Live labels
        text("Part 1", 530, 462.8, 3.2, st.faint, maxWidth: 26, optional: true); text("Next", 530, 476.5, 3.2, st.faint, maxWidth: 26, optional: true)
        text("Part 2", 530, 488.6, 3.2, st.faint, maxWidth: 26, optional: true); text("Previous", 530, 502.3, 3.2, st.faint, maxWidth: 26, optional: true)
        text("Live", 530, 514.3, 3.2, st.faint, maxWidth: 26, optional: true); text("Bank \(bank)", 530, 528, 3.8, st.data, weight: .bold)
        // Grouping rules under the encoder labels (1-4, 5-8)
        hline(549, 646, 478.4, st.faint); hline(659, 757, 478.4, st.faint)
        // Collides with the enlarged encoder names; the bank also shows under the Live button.
        if minText <= 4 { text("BANK \(bank)", 546, 449, 4, st.faint, weight: .bold, anchor: .trailing) }
    }

    func paintControl(_ hw: HWControl) {
        guard hw.kind != .jack else { return }   // drawn by paintRear
        let a = info.annotations[hw.id] ?? Annotation()
        let r = hw.rect
        let inGroup = hw.group != nil && hw.group == sel.group && (sel.column == nil || sel.column == hw.column)
        if inGroup && hw.kind != .keys && hw.kind != .block {
            fill(rect(r.insetBy(dx: -1.8, dy: -1.8), 2), st.select.opacity(0.10))
        }
        switch hw.kind {
        case .pad:
            if let led = a.led { fill(rect(r, 2), led.opacity(0.30)) }
            stroke(rect(r, 2), a.led ?? st.ink, a.led == nil ? line : 1.2)
            stroke(rect(r.insetBy(dx: 1.6, dy: 1.6), 1.2), st.faint, hair)
            text("\((hw.column ?? 0) + 1)", r.minX + 2.6, r.maxY - 2.4, 2.8, st.faint, anchor: .bottomLeading, optional: true)
            text(a.value, r.midX, r.midY - 0.5, 6, st.data, weight: .bold, maxWidth: r.width - 1)
        case .knob:
            stroke(Path(ellipseIn: r.insetBy(dx: -1.2, dy: -1.2)), st.faint, hair)
            fill(Path(ellipseIn: r), st.ink.opacity(0.10))
            stroke(Path(ellipseIn: r), st.ink, line)
            vline(r.midX, r.minY + 1, r.minY + 4.5, st.ink, line)
            text(a.value, r.midX, 474.6, 4.4, st.data, weight: .bold, maxWidth: room(hw))
            text(a.name, r.midX, 450, 3.2, st.faint, maxWidth: room(hw), optional: true)
        case .fader:
            let slot = Blueprint.r(r.midX - 0.9, 482, r.midX + 0.9, 526)
            fill(rect(slot, 0.9), st.ink.opacity(0.35))
            let cap = Blueprint.r(r.midX - 6.1, 521, r.midX + 6.1, 530.5)
            fill(rect(cap, 1), st.paper)
            stroke(rect(cap, 1), st.ink, line)
            hline(cap.minX, cap.maxX, cap.midY, st.ink, hair)
            text(a.value, r.midX, 535, 4.6, st.data, weight: .bold, maxWidth: room(hw))
            if !a.name.isEmpty && !skipOptional(3.2) {
                var c = ctx
                c.transform = .identity
                let o = CGPoint(x: r.midX + 4.4, y: 500).applying(ctx.transform)
                c.translateBy(x: o.x, y: o.y)
                c.rotate(by: .degrees(-90))
                c.draw(fitted(short(a.name, 14), 3.2, st.faint, maxWidth: 40), at: .zero, anchor: .center)
            }
        case .button:
            if let led = a.led { fill(rect(r, 1), led.opacity(0.55)) }
            stroke(rect(r, 1), st.ink, line)
            if hw.group == "columns" {
                text(a.value, r.midX, 553, 4.2, st.data, weight: .bold, maxWidth: room(hw))
            } else if hw.group == "daw" {
                // Name and value are 4.6 units apart: the name only fits above the value while text stays small.
                if minText < 4.4 { text(hw.label ?? "", r.midX, r.maxY + 3.6, 3.2, st.faint, maxWidth: room(hw)) }
                // Same form for the whole row: drop "CC " from all values once "CC 00" no longer fits.
                let v = dawCompact && a.value.hasPrefix("CC ") ? String(a.value.dropFirst(3)) : a.value
                text(v, r.midX, r.maxY + 8.2, 4.2, st.data, weight: .bold, maxWidth: room(hw))
            } else {
                text(hw.label ?? "", r.midX, r.maxY + 3.6, 3.4, st.faint, maxWidth: room(hw))
            }
        case .round:
            stroke(Path(ellipseIn: r), st.ink, line)
            fill(Path(ellipseIn: r.insetBy(dx: 1.2, dy: 1.2)), st.ink.opacity(hw.id == "bank" ? 0.35 : 0.12))
        case .wheel:
            stroke(rect(r.insetBy(dx: -2, dy: -2), 2), st.faint, hair)
            fill(rect(r, 2), st.ink.opacity(0.08))
            stroke(rect(r, 2), st.ink, line)
            var ridges = Path()
            for i in 1..<14 {
                let y = r.minY + CGFloat(i) * r.height / 14
                ridges.move(to: CGPoint(x: r.minX + 2, y: y)); ridges.addLine(to: CGPoint(x: r.maxX - 2, y: y))
            }
            stroke(ridges, st.faint, 0.3)
            text(hw.label ?? "", r.midX, 503.5, 3.6, st.faint, maxWidth: room(hw), optional: true)
            text(a.value, r.midX, 509, 4.4, st.data, weight: .bold, maxWidth: room(hw))
        case .keys, .block, .jack:
            break
        }
        if hw.id == sel.element {
            stroke(rect(r.insetBy(dx: -2.4, dy: -2.4), 2.5), st.select, 1.2)
        }
        if a.changed, hw.kind != .keys, hw.kind != .block {
            fill(Path(ellipseIn: Blueprint.c(r.maxX + 0.5, r.minY - 0.5, 1.7)), BP.changed)
        }
    }

    /// Classic drawing title block in the empty right part of the panel.
    func paintTitleBlock() {
        let b = Blueprint.r(858, 486, 1150, 556)
        let selected = sel.group == "keyboard"
        if selected { fill(rect(b, 1), st.select.opacity(0.06)) }
        stroke(rect(b, 1), selected ? st.select : st.ink, selected ? 1.0 : line)
        hline(b.minX, b.maxX, b.minY + 13, st.ink, hair)
        vline(b.minX + 52, b.minY, b.maxY, st.faint, hair)
        text("PRESET", b.minX + 4, b.minY + 6.5, 3.8, st.faint, weight: .bold, anchor: .leading)
        text("\(info.slot.uppercased())  “\(info.presetName)”", b.minX + 56, b.minY + 6.5, 5.6, st.data, weight: .bold, anchor: .leading)
        for (i, l) in info.lines.prefix(5).enumerated() {
            let y = b.minY + 19 + CGFloat(i) * 10.5
            text(l.0, b.minX + 4, y, 3.8, st.faint, weight: .bold, anchor: .leading)
            text(l.1, b.minX + 56, y, 4.6, st.ink, anchor: .leading)
            if i > 0 { hline(b.minX, b.maxX, y - 5.2, st.gridMajor, hair) }
        }
    }

    /// Rear strip above the top view. The static outline is laid out around y = 772 and shifted up
    /// by 386; the jacks use their real (shifted) positions from `Blueprint.controls`.
    func paintRear() {
        var shifted = self
        shifted.ctx.translateBy(x: 0, y: Blueprint.rearY - 772)
        shifted.paintRearShell()
        paintJacks()
    }

    func paintRearShell() {
        text("REAR PANEL", 8, 738, 5.5, st.faint, weight: .bold, anchor: .leading)
        text("connectors as seen from behind (manual p. 7) · position along the case not to scale", 64, 738, 4.2, st.faint, anchor: .leading)
        let y: CGFloat = 772
        stroke(rect(Blueprint.r(250, 748, 776, 798), 2), st.ink, line)
        stroke(rect(Blueprint.r(256, 754, 370, 794), 1), st.faint, hair)          // CV outs
        stroke(rect(Blueprint.r(388, 754, 450, 794), 1), st.faint, hair)          // MIDI
        for (t, x) in [("MIDI In", CGFloat(403)), ("MIDI Out", 435)] {
            stroke(Path(ellipseIn: Blueprint.c(x, y, 9)), st.faint, line)
            for k in 0..<5 {
                let ang = Double.pi * (1.0 + 0.25 * Double(k))
                fill(Path(ellipseIn: Blueprint.c(x + 5.5 * CGFloat(cos(ang)), y + 5.5 * CGFloat(sin(ang)) + 1.5, 0.7)), st.faint)
            }
            text(t, x, y - 13.5, 3.4, st.faint)
        }
        text("⏚", 379, y, 5, st.faint)
        text("CONTROLS / PEDALS", 547, 751.5, 3.4, st.faint, weight: .semibold)
        stroke(rect(Blueprint.r(458, 755, 556, 794), 1), st.faint, hair)
        stroke(rect(Blueprint.r(562, 755, 597, 794), 1), st.faint, hair)
        stroke(rect(Blueprint.r(602, 755, 637, 794), 1), st.faint, hair)
        stroke(rect(Blueprint.r(642, 755, 660, 794), 1), st.faint, hair)
        stroke(rect(Blueprint.r(668, 754, 692, 794), 1), st.faint, hair)             // USB
        stroke(rect(Blueprint.c(680, y, 4.5), 1), st.faint, line)
        text("USB", 680, y - 10.5, 3.4, st.faint)
        stroke(rect(Blueprint.r(698, 754, 730, 794), 1), st.faint, hair)             // DC
        stroke(Path(ellipseIn: Blueprint.c(714, y, 5)), st.faint, line)
        text("9–12 V DC", 714, y - 10.5, 3.2, st.faint)
        stroke(rect(Blueprint.r(736, 754, 768, 794), 1), st.faint, hair)             // switch
        stroke(rect(Blueprint.r(745, y - 7, 759, y + 7), 1.5), st.faint, line)
        text("Power", 752, y - 10.5, 3.2, st.faint)
    }

    func paintJacks() {
        for hw in Blueprint.controls where hw.kind == .jack {
            let a = info.annotations[hw.id] ?? Annotation()
            let r = hw.rect
            let inGroup = hw.group == sel.group && (sel.column == nil || sel.column == hw.column)
            if inGroup { fill(rect(r.insetBy(dx: -4, dy: -4), 3), st.select.opacity(0.10)) }
            stroke(Path(ellipseIn: r.insetBy(dx: -1.4, dy: -1.4)), st.ink, line)
            fill(Path(ellipseIn: r.insetBy(dx: r.width * 0.25, dy: r.width * 0.25)), st.ink.opacity(0.6))
            text(hw.label ?? "", r.midX, r.minY - 5, 3.4, st.faint, maxWidth: room(hw))
            text(a.value, r.midX, r.maxY + 6.5, 4.2, st.data, weight: .bold, maxWidth: room(hw))
            if hw.id == sel.element { stroke(rect(r.insetBy(dx: -4.5, dy: -4.5), 3), st.select, 1.2) }
            if a.changed { fill(Path(ellipseIn: Blueprint.c(r.maxX + 2, r.minY - 2, 1.7)), BP.changed) }
        }
    }
}
