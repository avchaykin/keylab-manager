import KeyLabCore
import SwiftUI

/// One row of an editor: a single parameter, or several numeric parameters shown as one multi-handle
/// slider (Min/Max, Off/On, velocity points…).
enum EditorRow: Identifiable {
    case single(Schema.Param)
    case multi(String, [Schema.Param])

    var id: String {
        switch self {
        case let .single(p): return p.key
        case let .multi(_, ps): return ps.map(\.key).joined(separator: "+")
        }
    }
    var title: String {
        switch self {
        case let .single(p): return p.title
        case let .multi(t, _): return t
        }
    }
    var params: [Schema.Param] {
        switch self {
        case let .single(p): return [p]
        case let .multi(_, ps): return ps
        }
    }

    static let multiGroups: [([String], String)] = [
        (["minValue", "maxValue"], "Range"),
        (["offValue", "onValue"], "Off · On"),
        (["minVelocity", "pianoVelocity", "mezzoVelocity", "forteVelocity", "maxVelocity"], "Min · p · mf · f · Max"),
        (["keyAftertouchMin", "keyAftertouchMax"], "Range"),
        (["padAftertouchMin", "padAftertouchMax"], "Range"),
        (["calibrationMin", "calibrationMax"], "Calibration"),
    ]
}

extension AppModel {
    /// Visible rows of an item, with paired numeric parameters merged into multi-handle rows.
    func editorRows(_ item: Schema.Item, in t: Target) -> [EditorRow] {
        let visible = item.params.filter { isVisible($0, item: item, in: t) }
        var out: [EditorRow] = [], used = Set<String>()
        for p in visible where !used.contains(p.key) {
            if let g = EditorRow.multiGroups.first(where: { $0.0.contains(p.key) }) {
                let ps = g.0.compactMap { k in visible.first { $0.key == k } }
                if ps.count == g.0.count, ps.allSatisfy({ ($0.options ?? []).isEmpty && !$0.isString && $0.rgb == nil }) {
                    out.append(.multi(g.1, ps)); used.formUnion(g.0); continue
                }
            }
            out.append(.single(p)); used.insert(p.key)
        }
        return out
    }

    func rowChanged(_ row: EditorRow, in t: Target) -> Bool { row.params.contains { isChanged($0, in: t) } }
    func rowValueKey(_ row: EditorRow, in t: Target) -> String { row.params.map { valueKey($0, in: t) }.joined(separator: "|") }
}

/// Editor for one row (single parameter or multi-handle slider).
struct RowEditor: View {
    let row: EditorRow
    let target: Target
    var compact = false

    var body: some View {
        switch row {
        case let .single(p): ParamEditor(param: p, target: target, compact: compact)
        case let .multi(_, ps): MultiEditor(params: ps, target: target, compact: compact)
        }
    }
}

/// The editing control for one parameter.
struct ParamEditor: View {
    @Environment(AppModel.self) private var model
    let param: Schema.Param
    let target: Target
    var compact = false

    var body: some View {
        if param.isString {
            BPTextField(text: stringBinding)
                .help(param.maxlen.map { "Up to \($0) characters" } ?? "")
        } else if param.rgb != nil {
            if model.rgb(param, in: target) != nil { BPColorWell(rgb: rgbBinding) } else { dash }
        } else if model.value(param, in: target) == nil {
            dash.help("The keyboard did not report this value")
        } else if param.kind == "bool" {
            BPSelector(options: [Schema.Option(value: 0, label: "Off"), Schema.Option(value: 1, label: "On")], value: boolBinding)
        } else if let options = param.options, !options.isEmpty {
            BPSelector(options: allOptions(options), value: intBinding)
        } else {
            BPSlider(values: [shownBinding(param)], range: shownRange(param), compact: compact)
        }
    }

    private var dash: some View { Text("—").font(BP.mono(11)).foregroundStyle(BP.dim).frame(maxWidth: .infinity) }

    private var stringBinding: Binding<String> {
        Binding { model.edited[target]?[string: param.addr] ?? "" } set: { v in
            model.edited[target]?[string: param.addr] = String(v.prefix(param.maxlen ?? 16))
        }
    }

    private var rgbBinding: Binding<RGB7> {
        Binding {
            let (r, g, b) = model.rgb(param, in: target) ?? (0, 0, 0)
            return RGB7(r: r, g: g, b: b)
        } set: { c in model.setRGB((c.r, c.g, c.b), param, in: target) }
    }

    private var intBinding: Binding<Int> {
        Binding { model.value(param, in: target) ?? 0 } set: { model.setValue($0, param, in: target) }
    }

    private var boolBinding: Binding<Int> {
        Binding {
            let on = (model.value(param, in: target) ?? 0) != 0
            return (param.inverted == true ? !on : on) ? 1 : 0
        } set: { v in
            let on = (v != 0) != (param.inverted == true)
            model.setValue(on ? 1 : 0, param, in: target)
        }
    }

    private func shownBinding(_ p: Schema.Param) -> Binding<Int> { ParamEditor.shown(p, target: target, model: model) }
    private func shownRange(_ p: Schema.Param) -> ClosedRange<Int> { ParamEditor.range(p) }

    /// Keep an unknown current value selectable.
    private func allOptions(_ options: [Schema.Option]) -> [Schema.Option] {
        guard let v = model.value(param, in: target), !options.contains(where: { $0.value == v }) else { return options }
        return options + [Schema.Option(value: v, label: "Value \(v)")]
    }

    /// Spin values: shown value = raw / multiply.
    @MainActor static func shown(_ p: Schema.Param, target: Target, model: AppModel) -> Binding<Int> {
        let m = p.multiply ?? 1
        let r = range(p)
        return Binding {
            Int((Double(model.value(p, in: target) ?? 0) / m).rounded())
        } set: { v in
            model.setValue(Int(Double(min(max(v, r.lowerBound), r.upperBound)) * m), p, in: target)
        }
    }

    static func range(_ p: Schema.Param) -> ClosedRange<Int> {
        let lo = p.min ?? 0, hi = max(p.max ?? 127, lo)
        return lo...hi
    }
}

struct MultiEditor: View {
    @Environment(AppModel.self) private var model
    let params: [Schema.Param]
    let target: Target
    var compact = false

    var body: some View {
        if params.contains(where: { model.value($0, in: target) == nil }) {
            Text("—").font(BP.mono(11)).foregroundStyle(BP.dim).frame(maxWidth: .infinity)
        } else {
            let lo = params.map { ParamEditor.range($0).lowerBound }.min() ?? 0
            let hi = params.map { ParamEditor.range($0).upperBound }.max() ?? 127
            BPSlider(values: params.map { ParamEditor.shown($0, target: target, model: model) }, range: lo...hi, compact: compact)
                .help(params.map(\.title).joined(separator: " · "))
        }
    }
}

/// Labelled row for list-style editors (device settings).
struct BPFormRow: View {
    @Environment(AppModel.self) private var model
    let row: EditorRow
    let target: Target

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(row.title).font(.system(size: 11.5)).foregroundStyle(BP.ink.opacity(0.85)).lineLimit(1)
                if model.rowChanged(row, in: target) { BPChangedDot() }
            }
            .frame(width: 150, alignment: .leading)
            RowEditor(row: row, target: target)
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 26)
    }
}
