import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var view: MenuView = AppModel.shared.config.menu.defaultView
    @State private var expanded: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            UpdateBanner()
            if let message = problem {
                StatusMessage(kind: .error, text: message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider().opacity(0.6)
            ScrollView {
                VStack(spacing: 1) {
                    if view == .all { deviceList } else { presetList }
                }
                .padding(6)
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 320)
        .onAppear {
            model.menuVisible = true
            Task { await model.refresh() }
        }
        .onDisappear {
            model.menuVisible = false
            model.banner = nil
        }
    }

    private var problem: String? {
        if let b = model.banner { return b }
        if case .offline(let m) = model.connection { return m }
        if !model.providerErrors.isEmpty {
            return model.providerErrors.sorted { $0.key < $1.key }.map { "\($0.key.capitalized): \($0.value)" }.joined(separator: "\n")
        }
        return nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Home").font(.system(size: 13, weight: .semibold))
            Spacer()
            let onCount = model.devices.filter { $0.on && $0.online }.count
            if model.connection == .online {
                Text("\(onCount) on").font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            StatusDot(color: model.connection == .online ? .green : (model.connection == .connecting ? .yellow : .red))
                .help(model.connection == .online ? "Backend connected" : "Backend not reachable")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder private var deviceList: some View {
        let devices = model.visibleMenuDevices
        if devices.isEmpty {
            empty(model.connection == .connecting ? "Looking for devices…" : "No devices found", icon: "lightbulb.slash")
        } else {
            ForEach(devices) { d in
                MenuDeviceRow(device: d, expanded: expanded == d.id) {
                    withAnimation(.snappy(duration: 0.2)) { expanded = expanded == d.id ? nil : d.id }
                }
            }
        }
    }

    @ViewBuilder private var presetList: some View {
        if model.config.presets.isEmpty {
            VStack(spacing: 10) {
                empty("No presets yet", icon: "sparkles")
                Button("Create a preset…") { showSettings(openWindow); SettingsRouter.shared.pane = .presets }
                    .controlSize(.small)
            }
            .padding(.bottom, 12)
        } else {
            ForEach(model.config.presets) { p in MenuPresetRow(preset: p) }
        }
    }

    private func empty(_ text: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Picker("", selection: $view) {
                ForEach(MenuView.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 140)
            Spacer()
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Button { showSettings(openWindow) } label: { Image(systemName: "gearshape") }
                .help("Open Settings")
                .keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("Open Settings…") { showSettings(openWindow) }
                if let v = Updater.shared.available, Updater.shared.state != .updating {
                    Button("Update to \(v.description)") { Updater.shared.install() }
                }
                Divider()
                Button("Quit HomeControl") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

// MARK: - Rows

struct MenuDeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: Device
    let expanded: Bool
    let onExpand: () -> Void
    @State private var brightness: Double = 100
    @State private var kelvin: Double = 2700

    private var adjustable: Bool { device.online && (device.capabilities.dimmable || device.capabilities.color || device.capabilities.colorTemp) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                DeviceIcon(device: device, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 13)).lineLimit(1)
                    if !device.online {
                        Text("Offline").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if device.on, let b = device.brightness, device.capabilities.dimmable {
                        Text("\(b)%").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 4)
                if adjustable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                Toggle("", isOn: Binding(get: { device.on }, set: { v in Task { await model.setPower(device, v) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(!device.online || model.pending.contains(device.id))
            }
            .contentShape(Rectangle())
            .onTapGesture { if adjustable { onExpand() } else if device.online { Task { await model.toggle(device) } } }
            .opacity(device.online ? 1 : 0.55)

            if expanded && adjustable { controls.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .hoverHighlight()
        .onAppear(perform: sync)
        .onChange(of: device) { sync() }
    }

    private func sync() {
        brightness = Double(device.brightness ?? 100)
        kelvin = Double(device.colorTemp ?? 2700)
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if device.capabilities.dimmable {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $brightness, in: 1...100) { editing in
                        if !editing { Task { await model.send(device.id, DeviceCommand(brightness: Int(brightness)), optimistic: { $0.brightness = Int(brightness); $0.on = true }) } }
                    }
                    .controlSize(.mini)
                    Image(systemName: "sun.max").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if device.capabilities.colorTemp && !device.capabilities.color {
                TemperatureSlider(kelvin: $kelvin, range: device.ctRange) {
                    Task { await model.send(device.id, DeviceCommand(colorTemp: Int(kelvin)), optimistic: { $0.colorTemp = Int(kelvin); $0.color = Color.kelvin(kelvin).hexString; $0.on = true }) }
                }
                .controlSize(.mini)
            }
            if device.capabilities.color {
                SwatchRow(selected: device.color) { hex in
                    Task { await model.send(device.id, DeviceCommand(color: hex), optimistic: { $0.color = hex; $0.on = true }) }
                }
            }
        }
        .padding(.leading, 38).padding(.trailing, 4).padding(.bottom, 2)
    }
}

struct MenuPresetRow: View {
    @Environment(AppModel.self) private var model
    let preset: Preset

    var body: some View {
        Button { Task { await model.run(preset) } } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.14))
                    Image(systemName: preset.icon).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.accentColor)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).font(.system(size: 13)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(failed ? Color.orange : .secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                status
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(failureText ?? "Run \(preset.name)")
    }

    private var failed: Bool { if case .failed = model.runStates[preset.id] { return true }; return false }
    private var failureText: String? { if case .failed(let f) = model.runStates[preset.id] { return f.joined(separator: "\n") }; return nil }

    private var subtitle: String {
        if case .failed(let f) = model.runStates[preset.id] { return f.count == 1 ? f[0] : "\(f.count) steps failed — \(f[0])" }
        let n = preset.steps.count
        return "\(n) step\(n == 1 ? "" : "s") · \(preset.mode == .parallel ? "all at once" : "in sequence")"
    }

    @ViewBuilder private var status: some View {
        switch model.runStates[preset.id] {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case nil: Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
