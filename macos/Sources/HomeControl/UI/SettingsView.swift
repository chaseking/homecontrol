import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case devices, presets, hue, kasa, customize, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .devices: return "Devices"
        case .presets: return "Presets"
        case .hue: return "Philips Hue"
        case .kasa: return "Kasa"
        case .customize: return "Customize"
        case .advanced: return "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .devices: return "square.grid.2x2"
        case .presets: return "sparkles"
        case .hue: return "lightbulb"
        case .kasa: return "powerplug"
        case .customize: return "paintbrush"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var pane: Pane = .devices
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var router = SettingsRouter.shared

    private let groups: [(String?, [Pane])] = [
        (nil, [.devices, .presets]),
        ("Integrations", [.hue, .kasa]),
        ("App", [.customize, .advanced]),
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .onAppear { model.settingsVisible = true; Task { await model.refresh() } }
        .onDisappear {
            model.settingsVisible = false
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 38) // room for the traffic lights
            ForEach(groups.indices, id: \.self) { gi in
                let g = groups[gi]
                if let title = g.0 {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                }
                ForEach(g.1) { pane in sidebarItem(pane) }
            }
            Spacer()
            UpdatePill { router.pane = .advanced }
            connectionFooter
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func sidebarItem(_ pane: Pane) -> some View {
        let selected = router.pane == pane
        return Button { router.pane = pane } label: {
            HStack(spacing: 9) {
                Image(systemName: pane.icon).font(.system(size: 13)).frame(width: 18)
                    .foregroundStyle(selected ? Color.primary : .secondary)
                Text(pane.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer()
                if pane == .hue || pane == .kasa, let err = model.providerErrors[pane.rawValue] {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.orange).help(err)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var connectionFooter: some View {
        HStack(spacing: 6) {
            switch model.connection {
            case .online: StatusDot(color: .green); Text(model.config.backend.isLocal ? "Local backend" : "Remote backend")
            case .connecting: StatusDot(color: .yellow); Text("Connecting…")
            case .offline: StatusDot(color: .red); Text("Backend offline")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .onTapGesture { router.pane = .advanced }
    }

    @ViewBuilder private var content: some View {
        switch router.pane {
        case .devices: DevicesPane()
        case .presets: PresetsPane()
        case .hue: ScrollPane { HuePane() }
        case .kasa: ScrollPane { KasaPane() }
        case .customize: ScrollPane { CustomizePane() }
        case .advanced: ScrollPane { AdvancedPane() }
        }
    }
}

/// Standard scrolling page with comfortable margins.
struct ScrollPane<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
