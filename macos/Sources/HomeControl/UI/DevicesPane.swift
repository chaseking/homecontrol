import SwiftUI

struct DevicesPane: View {
    enum Filter: String, CaseIterable, Identifiable { case all = "All", on = "On", off = "Off", offline = "Offline"; var id: String { rawValue } }

    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var provider = "all"
    @State private var selected: String?

    private var filtered: [Device] {
        model.devices.filter { d in
            (search.isEmpty || d.name.localizedCaseInsensitiveContains(search) || (d.model ?? "").localizedCaseInsensitiveContains(search) || d.kindLabel.localizedCaseInsensitiveContains(search))
            && (provider == "all" || d.provider == provider)
            && {
                switch filter {
                case .all: return true
                case .on: return d.online && d.on
                case .off: return d.online && !d.on
                case .offline: return !d.online
                }
            }()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                PaneHeader(title: "Devices", subtitle: summary)
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            HStack(spacing: 10) {
                SearchField(text: $search, prompt: "Search devices").frame(maxWidth: 260)
                Picker("", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("", selection: $provider) {
                    Text("All brands").tag("all")
                    Text("Philips Hue").tag("hue")
                    Text("Kasa").tag("kasa")
                }
                .labelsHidden().fixedSize()
                Spacer()
            }
            ForEach(model.providerErrors.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                StatusMessage(kind: .error, text: "\(k == "hue" ? "Philips Hue" : "Kasa"): \(v)")
            }
            if case .offline(let m) = model.connection {
                StatusMessage(kind: .error, text: m)
            }
            ScrollView {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text(model.devices.isEmpty ? "No devices yet" : "No matching devices").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 190), spacing: 14)], spacing: 14) {
                        ForEach(filtered) { d in
                            DeviceTile(device: d, selected: Binding(get: { selected == d.id }, set: { selected = $0 ? d.id : nil }))
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 32).padding(.top, 40)
    }

    private var summary: String {
        let on = model.devices.filter { $0.online && $0.on }.count
        let off = model.devices.filter { !$0.online }.count
        var s = "\(model.devices.count) devices · \(on) on"
        if off > 0 { s += " · \(off) offline" }
        return s
    }
}

struct DeviceTile: View {
    @Environment(AppModel.self) private var model
    let device: Device
    @Binding var selected: Bool
    @State private var hover = false

    var body: some View {
        let lit = device.on && device.online
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                DeviceIcon(device: device, size: 36)
                Spacer()
                if device.online {
                    Button { Task { await model.toggle(device) } } label: {
                        Image(systemName: "power")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(lit ? Color.white : .secondary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(lit ? Color.accentColor : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.pending.contains(device.id))
                    .help(device.on ? "Turn off" : "Turn on")
                } else {
                    Text("Offline").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.red.opacity(0.14)))
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                Text(statusText)
                if model.pending.contains(device.id) { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
        }
        .padding(13)
        .frame(height: 148)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(lit ? AnyShapeStyle(LinearGradient(colors: [device.tint.opacity(0.20), device.tint.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.primary.opacity(0.035)))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hover ? 0.18 : 0.08), lineWidth: selected ? 2 : 1))
        .opacity(device.online ? 1 : 0.6)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hover = $0 }
        .onTapGesture { selected = true }
        .popover(isPresented: $selected, arrowEdge: .trailing) { DeviceDetail(deviceId: device.id) }
        .contextMenu {
            Button(device.on ? "Turn Off" : "Turn On") { Task { await model.toggle(device) } }.disabled(!device.online)
            Button("Details…") { selected = true }
            Divider()
            Button("Copy Device ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(device.id, forType: .string) }
        }
        .animation(.easeOut(duration: 0.15), value: device.on)
    }

    private var statusText: String {
        guard device.online else { return "\(device.providerLabel) · \(device.kindLabel)" }
        var parts = [device.on ? "On" : "Off"]
        if device.on, device.capabilities.dimmable, let b = device.brightness { parts.append("\(b)%") }
        if device.on, device.capabilities.colorTemp, !device.capabilities.color || device.colorTemp != nil, let k = device.colorTemp { parts.append("\(k)K") }
        parts.append(device.providerLabel)
        return parts.joined(separator: " · ")
    }
}

/// Full controls for one device: rename, power, brightness, color temperature, color.
struct DeviceDetail: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    @State private var name = ""
    @State private var brightness: Double = 100
    @State private var kelvin: Double = 2700
    @State private var color: Color = .white

    var body: some View {
        if let d = model.device(deviceId) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    DeviceIcon(device: d, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: $name)
                            .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                            .onSubmit { rename(d) }
                        Text("\(d.providerLabel) · \(d.model ?? d.kindLabel)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { d.on }, set: { v in Task { await model.setPower(d, v) } }))
                        .toggleStyle(.switch).labelsHidden().disabled(!d.online)
                }
                if !d.online {
                    StatusMessage(kind: .error, text: d.provider == "hue" ? "Unreachable — the bulb may be switched off at the wall." : "Offline — not found on the network.")
                }
                if d.capabilities.dimmable {
                    section("Brightness", trailing: "\(Int(brightness))%") {
                        Slider(value: $brightness, in: 1...100) { editing in
                            if !editing { send(d, DeviceCommand(brightness: Int(brightness))) { $0.brightness = Int(brightness); $0.on = true } }
                        }
                    }
                }
                if d.capabilities.colorTemp {
                    section("White temperature") {
                        TemperatureSlider(kelvin: $kelvin, range: d.ctRange) {
                            send(d, DeviceCommand(colorTemp: Int(kelvin))) { $0.colorTemp = Int(kelvin); $0.color = Color.kelvin(kelvin).hexString; $0.on = true }
                        }
                    }
                }
                if d.capabilities.color {
                    section("Color") {
                        HStack(spacing: 10) {
                            SwatchRow(selected: d.color) { hex in
                                color = Color(hex: hex) ?? color
                                send(d, DeviceCommand(color: hex)) { $0.color = hex; $0.colorTemp = nil; $0.on = true }
                            }
                            ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                                .onChange(of: color) { _, new in debouncedColor(d, new) }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device ID").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    Text(d.id).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                    Text("Hardware-based and permanent — presets keep working if you rename the device.")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .frame(width: 330)
            .onAppear { load(d) }
            .onChange(of: d) { _, new in load(new, keepName: true) }
        } else {
            Text("Device not found").padding()
        }
    }

    @State private var colorTask: Task<Void, Never>?

    private func debouncedColor(_ d: Device, _ c: Color) {
        let hex = c.hexString
        guard hex != d.color else { return }
        colorTask?.cancel()
        colorTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.send(d.id, DeviceCommand(color: hex), optimistic: { $0.color = hex; $0.colorTemp = nil; $0.on = true })
        }
    }

    private func section<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
            }
            c()
        }
    }

    private func load(_ d: Device, keepName: Bool = false) {
        if !keepName || name.isEmpty { name = d.name }
        brightness = Double(d.brightness ?? 100)
        kelvin = min(max(Double(d.colorTemp ?? 2700), d.ctRange.lowerBound), d.ctRange.upperBound)
        if let c = Color(hex: d.color), d.colorTemp == nil { color = c }
    }

    private func rename(_ d: Device) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != d.name else { name = d.name; return }
        send(d, DeviceCommand(name: n)) { $0.name = n }
    }

    private func send(_ d: Device, _ cmd: DeviceCommand, optimistic: @escaping (inout Device) -> Void) {
        Task { await model.send(d.id, cmd, optimistic: optimistic) }
    }
}
