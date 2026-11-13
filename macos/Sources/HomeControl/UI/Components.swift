import SwiftUI

// MARK: - Color helpers

extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    static func kelvin(_ k: Double) -> Color {
        let t = max(1000, min(40000, k)) / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func c(_ x: Double) -> Double { max(0, min(255, x)) / 255 }
        return Color(red: c(r), green: c(g), blue: c(b))
    }
}

extension Device {
    /// Tint used for icons/tiles: the bulb's color when on, warm yellow for plugs.
    var tint: Color {
        guard on, online else { return .secondary }
        return Color(hex: color) ?? Color(red: 1.0, green: 0.78, blue: 0.35)
    }
}

let swatches = ["#ffffff", "#ffb46b", "#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#00c7be", "#0a84ff", "#5e5ce6", "#bf5af2", "#ff2d92"]

// MARK: - Settings building blocks (Claude-settings-like cards)

struct PaneHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var divider = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if divider { Divider().padding(.leading, 14) }
        }
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct StatusMessage: View {
    enum Kind { case ok, error, info, working }
    let kind: Kind
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch kind {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
            case .working: ProgressView().controlSize(.mini)
            }
            Text(text).font(.system(size: 12)).foregroundStyle(kind == .error ? .primary : .secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Icon in a soft circle, tinted with the device's light color.
struct DeviceIcon: View {
    let device: Device
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            Circle().fill(device.on && device.online ? device.tint.opacity(0.22) : Color.primary.opacity(0.06))
            Image(systemName: device.symbol)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(device.on && device.online ? device.tint : Color.secondary)
        }
        .frame(width: size, height: size)
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Slider with a warm→cool gradient track for color temperature.
struct TemperatureSlider: View {
    @Binding var kelvin: Double
    let range: ClosedRange<Double>
    var onCommit: () -> Void = {}
    var body: some View {
        VStack(spacing: 4) {
            Slider(value: $kelvin, in: range) { editing in if !editing { kelvin = (kelvin / 50).rounded() * 50; onCommit() } }
                .tint(Color.kelvin(kelvin))
            HStack {
                Text("Warm").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(String(Int(kelvin)) + " K").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text("Cool").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

struct SwatchRow: View {
    var selected: String?
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(swatches, id: \.self) { hex in
                Button { pick(hex) } label: {
                    Circle().fill(Color(hex: hex)!)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected?.lowercased() == hex ? 2 : 0).padding(-3))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct HoverHighlight: ViewModifier {
    @State private var hover = false
    var radius: CGFloat = 7
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .onHover { hover = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 7) -> some View { modifier(HoverHighlight(radius: radius)) }
}

let presetIcons = ["sparkles", "sun.max", "moon", "sofa", "bed.double", "fork.knife", "tv", "book", "leaf", "drop", "power", "house", "lightbulb", "lamp.floor", "party.popper", "film"]
