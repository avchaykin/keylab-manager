import AppKit
import KeyLabCore
import SwiftUI

/// Grey/white blueprint look used by the whole app.
enum BP {
    static let paper = Color(white: 0.115)
    static let panel = Color(white: 0.145)
    static let grid = Color(white: 0.150)
    static let gridMajor = Color(white: 0.185)
    static let ink = Color(white: 0.93)
    static let line = Color(white: 0.60)
    static let faint = Color(white: 0.56)
    static let dim = Color(white: 0.36)
    static let hair = Color(white: 0.25)
    static let changed = Color(red: 1.0, green: 0.62, blue: 0.22)
    static let diff = Color.white.opacity(0.075)

    static func mono(_ size: CGFloat = 11, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func label(_ size: CGFloat = 10, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight) }
}

/// Small uppercase caption.
struct BPCaption: View {
    let text: String
    var size: CGFloat = 9.5
    var color: Color = BP.faint
    init(_ text: String, size: CGFloat = 9.5, color: Color = BP.faint) { self.text = text; self.size = size; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(BP.label(size, .bold)).tracking(0.7).foregroundStyle(color).lineLimit(1)
    }
}

// MARK: - Buttons

struct BPButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { BPButtonBody(configuration: configuration, prominent: prominent) }
}

private struct BPButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(BP.label(10.5, .bold)).textCase(.uppercase).tracking(0.6)
            .foregroundStyle(prominent ? Color.black : BP.ink)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(prominent ? BP.ink.opacity(pressed ? 0.7 : hover ? 0.88 : 1)
                                  : Color.white.opacity(pressed ? 0.16 : hover ? 0.08 : 0))
            .overlay(Rectangle().strokeBorder(prominent ? Color.clear : BP.line, lineWidth: 1))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// A button that opens a list of actions in a popover (replaces native menus).
struct BPMenuButton: View {
    let title: String
    let items: [(String, () -> Void)]
    @State private var open = false

    var body: some View {
        Button { open = true } label: { Text("\(title) ▾") }
            .buttonStyle(BPButtonStyle())
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items.indices, id: \.self) { i in
                        if items[i].0 == "-" {
                            Rectangle().fill(BP.hair).frame(height: 1).padding(.vertical, 3)
                        } else {
                            BPListRow(text: items[i].0, selected: false) { open = false; items[i].1() }
                        }
                    }
                }
                .padding(6)
                .frame(minWidth: 220)
                .background(BP.panel)
            }
    }
}

struct BPListRow: View {
    let text: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(selected ? "▸" : " ").font(BP.mono(11)).foregroundStyle(BP.ink)
                Text(text).font(BP.mono(11.5)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.black : BP.ink)
            .padding(.horizontal, 6).frame(height: 22)
            .background(selected ? BP.ink : hover ? Color.white.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Tabs

struct BPTabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let on = items[i].0 == selection
                if i > 0 { Rectangle().fill(BP.line).frame(width: 1, height: height) }
                Button { selection = items[i].0 } label: {
                    Text(items[i].1.uppercased())
                        .font(BP.label(10, .bold)).tracking(0.6).lineLimit(1)
                        .foregroundStyle(on ? Color.black : BP.ink)
                        .padding(.horizontal, 10).frame(height: height)
                        .background(on ? BP.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: height)
        .fixedSize()
        .overlay(Rectangle().strokeBorder(BP.line, lineWidth: 1))
    }
}

// MARK: - Value editors

/// "‹ value ›" selector; long lists show a dropdown instead of arrows. The value opens a list.
struct BPSelector: View {
    let options: [Schema.Option]
    @Binding var value: Int
    @State private var open = false

    static let arrowLimit = 17

    var body: some View {
        let idx = options.firstIndex { $0.value == value }
        let label = idx.map { options[$0].label } ?? "Value \(value)"
        let arrows = options.count <= Self.arrowLimit
        HStack(spacing: 0) {
            if arrows { arrow("‹", enabled: (idx ?? 0) > 0) { step(-1, idx) } }
            Button { open = true } label: {
                Text(label).font(BP.mono(11)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(BP.ink)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                BPOptionList(options: options, selected: value) { value = $0; open = false }
            }
            if arrows {
                arrow("›", enabled: (idx ?? options.count) < options.count - 1) { step(1, idx) }
            } else {
                Text("▾").font(.system(size: 8)).foregroundStyle(BP.faint).padding(.trailing, 6)
            }
        }
        .frame(height: 22)
        .overlay(Rectangle().strokeBorder(BP.hair, lineWidth: 1))
        .help(label)
    }

    private func step(_ d: Int, _ idx: Int?) {
        let i = min(max((idx ?? 0) + d, 0), options.count - 1)
        value = options[i].value
    }

    private func arrow(_ s: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        BPArrow(symbol: s, enabled: enabled, action: action)
    }
}

private struct BPArrow: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(enabled ? BP.ink : BP.dim)
                .frame(width: 18, height: 22)
                .background(hover && enabled ? Color.white.opacity(0.10) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

struct BPOptionList: View {
    let options: [Schema.Option]
    let selected: Int
    let pick: (Int) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(options, id: \.value) { o in
                        BPListRow(text: o.label, selected: o.value == selected) { pick(o.value) }.id(o.value)
                    }
                }
                .padding(6)
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
        .frame(width: 250, height: min(CGFloat(options.count) * 22 + 12, 340))
        .background(BP.panel)
    }
}

/// Slider with one or more handles (e.g. min/max range, velocity points). Values are integers.
struct BPSlider: View {
    let values: [Binding<Int>]
    let range: ClosedRange<Int>
    var compact = false
    @State private var dragging: Int?
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { g in track(width: g.size.width, height: g.size.height) }
                .frame(height: 20)
                .frame(minWidth: 40)
            Button { editing = true } label: {
                Text(values.map { String($0.wrappedValue) }.joined(separator: values.count == 2 ? "–" : "·"))
                    .font(BP.mono(compact ? 10 : 11)).foregroundStyle(BP.ink).lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: values.count == 1 ? 26 : 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to type exact values (\(range.lowerBound)…\(range.upperBound))")
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                HStack(spacing: 8) {
                    ForEach(values.indices, id: \.self) { i in BPNumberField(value: values[i], range: range) }
                }
                .padding(10).background(BP.panel)
            }
        }
    }

    private func x(_ v: Int, _ w: CGFloat) -> CGFloat {
        let span = CGFloat(max(range.upperBound - range.lowerBound, 1))
        return CGFloat(v - range.lowerBound) / span * w
    }

    private func value(at px: CGFloat, _ w: CGFloat) -> Int {
        let span = Double(range.upperBound - range.lowerBound)
        let f = min(max(Double(px / max(w, 1)), 0), 1)
        return range.lowerBound + Int((f * span).rounded())
    }

    @ViewBuilder private func track(width w: CGFloat, height h: CGFloat) -> some View {
        let mid = h / 2
        let xs = values.map { x($0.wrappedValue, w) }
        ZStack(alignment: .topLeading) {
            Path { p in
                for i in 0...8 {
                    let tx = CGFloat(i) / 8 * w
                    p.move(to: CGPoint(x: tx, y: mid + 4)); p.addLine(to: CGPoint(x: tx, y: mid + (i % 4 == 0 ? 8 : 6)))
                }
            }
            .stroke(BP.dim, lineWidth: 1)
            Rectangle().fill(BP.hair).frame(width: w, height: 1).offset(y: mid - 0.5)
            let lo = values.count > 1 ? (xs.min() ?? 0) : 0
            let hi = values.count > 1 ? (xs.max() ?? 0) : (xs.first ?? 0)
            Rectangle().fill(BP.ink.opacity(0.75)).frame(width: max(hi - lo, 1), height: 2).offset(x: lo, y: mid - 1)
            ForEach(values.indices, id: \.self) { i in
                Rectangle().fill(BP.paper)
                    .overlay(Rectangle().strokeBorder(dragging == i ? Color.white : BP.ink, lineWidth: dragging == i ? 1.5 : 1))
                    .frame(width: 7, height: 13)
                    .offset(x: xs[i] - 3.5, y: mid - 6.5)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            if dragging == nil {
                // nearest handle to where the drag started; ties go to the handle on the side we move to
                let d = xs.map { abs($0 - g.startLocation.x) }
                let best = d.min() ?? 0
                let cands = d.indices.filter { abs(d[$0] - best) < 0.5 }
                dragging = g.location.x >= g.startLocation.x ? cands.last : cands.first
            }
            if let i = dragging { values[i].wrappedValue = value(at: g.location.x, w) }
        }.onEnded { _ in dragging = nil })
    }
}

struct BPNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        TextField("", value: Binding { value } set: { value = min(max($0, range.lowerBound), range.upperBound) }, format: .number)
            .textFieldStyle(.plain)
            .font(BP.mono(12))
            .multilineTextAlignment(.trailing)
            .frame(width: 46)
            .padding(.horizontal, 4).frame(height: 22)
            .overlay(Rectangle().strokeBorder(BP.line, lineWidth: 1))
    }
}

struct BPTextField: View {
    @Binding var text: String
    var placeholder = ""
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(BP.mono(11.5))
            .foregroundStyle(BP.ink)
            .padding(.horizontal, 6).frame(height: 22)
            .overlay(Rectangle().strokeBorder(BP.hair, lineWidth: 1))
    }
}

struct RGB7: Equatable { var r, g, b: Int }

/// LED colour well: swatch → palette + R/G/B sliders (each channel 0…127 on the keyboard).
struct BPColorWell: View {
    @Binding var rgb: RGB7
    @State private var open = false

    static let palette: [RGB7] = [
        RGB7(r: 0, g: 0, b: 0), RGB7(r: 127, g: 127, b: 127), RGB7(r: 127, g: 0, b: 0), RGB7(r: 127, g: 35, b: 0),
        RGB7(r: 127, g: 95, b: 0), RGB7(r: 60, g: 127, b: 0), RGB7(r: 0, g: 127, b: 0), RGB7(r: 0, g: 127, b: 60),
        RGB7(r: 0, g: 127, b: 127), RGB7(r: 0, g: 60, b: 127), RGB7(r: 0, g: 0, b: 127), RGB7(r: 60, g: 0, b: 127),
        RGB7(r: 127, g: 0, b: 127), RGB7(r: 127, g: 0, b: 50), RGB7(r: 127, g: 90, b: 50), RGB7(r: 30, g: 30, b: 30),
    ]

    static func color(_ c: RGB7) -> Color { Color(red: Double(c.r) / 127, green: Double(c.g) / 127, blue: Double(c.b) / 127) }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Rectangle().fill(Self.color(rgb)).frame(width: 22, height: 14)
                    .overlay(Rectangle().strokeBorder(BP.line, lineWidth: 1))
                Text("\(rgb.r)·\(rgb.g)·\(rgb.b)").font(BP.mono(10)).foregroundStyle(BP.faint).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                BPCaption("LED colour")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 8), spacing: 4) {
                    ForEach(Self.palette.indices, id: \.self) { i in
                        let c = Self.palette[i]
                        Button { rgb = c } label: {
                            Rectangle().fill(Self.color(c)).frame(width: 26, height: 18)
                                .overlay(Rectangle().strokeBorder(c == rgb ? Color.white : BP.hair, lineWidth: c == rgb ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(["R", "G", "B"], id: \.self) { ch in
                    HStack(spacing: 6) {
                        Text(ch).font(BP.mono(11, .bold)).foregroundStyle(BP.faint).frame(width: 12)
                        BPSlider(values: [channel(ch)], range: 0...127)
                    }
                }
            }
            .padding(12).frame(width: 260).background(BP.panel)
        }
    }

    private func channel(_ ch: String) -> Binding<Int> {
        Binding {
            ch == "R" ? rgb.r : ch == "G" ? rgb.g : rgb.b
        } set: { v in
            if ch == "R" { rgb.r = v } else if ch == "G" { rgb.g = v } else { rgb.b = v }
        }
    }
}

/// Changed-but-not-written marker.
struct BPChangedDot: View {
    var body: some View { Circle().fill(BP.changed).frame(width: 6, height: 6).help("Changed, not yet written") }
}
