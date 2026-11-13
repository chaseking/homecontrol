import SwiftUI

struct PresetsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            list
            Divider()
            if let idx = model.config.presets.firstIndex(where: { $0.id == selection }) {
                PresetEditor(preset: $model.config.presets[idx], onDelete: { delete(idx) })
                    .id(model.config.presets[idx].id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(model.config.presets.isEmpty ? "Presets run several device actions with one click." : "Select a preset to edit it.")
                        .foregroundStyle(.secondary)
                    if model.config.presets.isEmpty { Button("New Preset") { add() }.controlSize(.large) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = model.config.presets.first?.id } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Presets").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button { add() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New preset")
            }
            .padding(.horizontal, 16).padding(.top, 40).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.config.presets) { p in
                        let sel = selection == p.id
                        Button { selection = p.id } label: {
                            HStack(spacing: 9) {
                                Image(systemName: p.icon).frame(width: 18).foregroundStyle(sel ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name.isEmpty ? "Untitled" : p.name).font(.system(size: 13, weight: sel ? .medium : .regular)).lineLimit(1)
                                    Text("\(p.steps.count) step\(p.steps.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                runBadge(p)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(sel ? Color.primary.opacity(0.08) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Run") { Task { await model.run(p) } }
                            Button("Duplicate") { duplicate(p) }
                            Button("Move Up") { movePreset(p, -1) }.disabled(model.config.presets.first == p)
                            Button("Move Down") { movePreset(p, 1) }.disabled(model.config.presets.last == p)
                            Divider()
                            Button("Delete", role: .destructive) { if let i = model.config.presets.firstIndex(of: p) { delete(i) } }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(width: 230)
    }

    @ViewBuilder private func runBadge(_ p: Preset) -> some View {
        switch model.runStates[p.id] {
        case .running: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
        case .succeeded: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
        case nil: EmptyView()
        }
    }

    private func add() {
        var n = 1
        while model.config.presets.contains(where: { $0.name == (n == 1 ? "New Preset" : "New Preset \(n)") }) { n += 1 }
        let p = Preset(name: n == 1 ? "New Preset" : "New Preset \(n)")
        model.config.presets.append(p)
        selection = p.id
    }

    private func duplicate(_ p: Preset) {
        var c = p
        c.id = UUID()
        c.name = p.name + " copy"
        c.steps = p.steps.map { var s = $0; s.id = UUID(); return s }
        model.config.presets.append(c)
        selection = c.id
    }

    private func movePreset(_ p: Preset, _ dir: Int) {
        guard let i = model.config.presets.firstIndex(of: p), model.config.presets.indices.contains(i + dir) else { return }
        model.config.presets.swapAt(i, i + dir)
    }

    private func delete(_ idx: Int) {
        let id = model.config.presets[idx].id
        model.config.presets.remove(at: idx)
        model.runStates[id] = nil
        if selection == id { selection = model.config.presets.first?.id }
    }
}

struct PresetEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var preset: Preset
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(presetIcons, id: \.self) { icon in
                            Button { preset.icon = icon } label: { Label(icon, systemImage: icon) }
                        }
                    } label: {
                        Image(systemName: preset.icon).font(.system(size: 17)).foregroundStyle(Color.accentColor)
                            .frame(width: 38, height: 38)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.13)))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Choose icon")
                    TextField("Preset name", text: $preset.name)
                        .textFieldStyle(.plain).font(.system(size: 20, weight: .semibold))
                    Spacer()
                    runButton
                }

                if case .failed(let failures) = model.runStates[preset.id] {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(failures, id: \.self) { StatusMessage(kind: .error, text: $0) }
                    }
                }

                Card(title: "Run mode") {
                    Row(title: "Activation", subtitle: preset.mode == .parallel ? "Every step fires at the same time." : "Steps run one after another, in order.", divider: preset.mode == .sequential) {
                        Picker("", selection: $preset.mode) { ForEach(RunMode.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    if preset.mode == .sequential {
                        Row(title: "Delay between steps", divider: false) {
                            HStack(spacing: 6) {
                                TextField("", value: $preset.delayMs, format: .number).frame(width: 60).multilineTextAlignment(.trailing)
                                Text("ms").foregroundStyle(.secondary)
                                Stepper("", value: $preset.delayMs, in: 0...60_000, step: 250).labelsHidden()
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Steps").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                        Spacer()
                        addMenu
                    }
                    if preset.steps.isEmpty {
                        Text("Add the lights and plugs this preset should control.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 26)
                            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.quaternary))
                    } else {
                        VStack(spacing: 0) {
                            ForEach($preset.steps) { $step in
                                let i = preset.steps.firstIndex { $0.id == step.id } ?? 0
                                StepRow(step: $step, index: i, count: preset.steps.count,
                                        move: { dir in move(step.id, dir) },
                                        remove: { preset.steps.removeAll { $0.id == step.id } })
                                if i < preset.steps.count - 1 { Divider().padding(.leading, 14) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                    }
                }

                HStack {
                    Spacer()
                    Button("Delete Preset", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.borderless).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Delete “\(preset.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var runButton: some View {
        Button { Task { await model.run(preset) } } label: {
            HStack(spacing: 6) {
                switch model.runStates[preset.id] {
                case .running: ProgressView().controlSize(.small)
                case .succeeded: Image(systemName: "checkmark")
                default: Image(systemName: "play.fill")
                }
                Text("Run")
            }
            .frame(minWidth: 60)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(preset.steps.isEmpty || model.runStates[preset.id] == .running)
    }

    private var addMenu: some View {
        Menu {
            let used = Set(preset.steps.map(\.deviceId))
            let available = model.devices.filter { !used.contains($0.id) }
            ForEach(["hue", "kasa"], id: \.self) { prov in
                let ds = available.filter { $0.provider == prov }
                if !ds.isEmpty {
                    Section(prov == "hue" ? "Philips Hue" : "Kasa") {
                        ForEach(ds) { d in Button(d.name + (d.online ? "" : " (offline)")) { add(d) } }
                    }
                }
            }
            if !available.isEmpty {
                Divider()
                Button("Add All Remaining (\(available.count))") { available.forEach(add) }
            }
            if model.devices.isEmpty { Text("No devices available") }
        } label: {
            Label("Add Step", systemImage: "plus")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func add(_ d: Device) {
        preset.steps.append(PresetStep(deviceId: d.id, deviceName: d.name, action: .on))
    }

    private func move(_ id: UUID, _ dir: Int) {
        guard let i = preset.steps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + dir
        guard preset.steps.indices.contains(j) else { return }
        preset.steps.swapAt(i, j)
    }
}

struct StepRow: View {
    @Environment(AppModel.self) private var model
    @Binding var step: PresetStep
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        let device = model.device(step.deviceId)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(index + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).background(Circle().fill(Color.primary.opacity(0.06)))
                deviceMenu(device)
                Spacer(minLength: 8)
                Picker("", selection: $step.action) { ForEach(StepAction.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                HStack(spacing: 2) {
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                    Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index == count - 1)
                    Button(action: remove) { Image(systemName: "trash") }.help("Remove step")
                }
                .buttonStyle(.borderless).font(.system(size: 11))
                .opacity(hover ? 1 : 0.35)
            }
            if step.action == .on, let d = device, d.capabilities.dimmable || d.capabilities.color || d.capabilities.colorTemp {
                options(d).padding(.leading, 30)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .onHover { hover = $0 }
    }

    private func deviceMenu(_ device: Device?) -> some View {
        Menu {
            ForEach(model.devices) { d in
                Button(d.name + (d.online ? "" : " (offline)")) {
                    step.deviceId = d.id; step.deviceName = d.name
                    // Drop options the new device can't do.
                    if !d.capabilities.dimmable { step.brightness = nil }
                    if !d.capabilities.color { step.color = nil }
                    if !d.capabilities.colorTemp { step.colorTemp = nil }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let d = device {
                    Image(systemName: d.symbol).foregroundStyle(.secondary).frame(width: 16)
                    Text(d.name).lineLimit(1)
                    if !d.online { Text("offline").font(.system(size: 10)).foregroundStyle(.orange) }
                } else {
                    Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                    Text(step.deviceName).lineLimit(1)
                    Text(model.connection == .online ? "not found" : "").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    @ViewBuilder private func options(_ d: Device) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if d.capabilities.dimmable {
                HStack(spacing: 10) {
                    Toggle("Brightness", isOn: Binding(get: { step.brightness != nil }, set: { step.brightness = $0 ? (d.brightness ?? 100) : nil }))
                        .toggleStyle(.checkbox).frame(width: 110, alignment: .leading)
                    if let b = step.brightness {
                        Slider(value: Binding(get: { Double(b) }, set: { step.brightness = Int($0) }), in: 1...100).controlSize(.small)
                        Text("\(b)%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                }
            }
            if d.capabilities.color {
                HStack(spacing: 10) {
                    Toggle("Color", isOn: Binding(get: { step.color != nil }, set: { step.color = $0 ? (d.color ?? "#ffb46b") : nil; if $0 { step.colorTemp = nil } }))
                        .toggleStyle(.checkbox).frame(width: 110, alignment: .leading)
                    if let c = step.color {
                        ColorPicker("", selection: Binding(get: { Color(hex: c) ?? .white }, set: { step.color = $0.hexString }), supportsOpacity: false)
                            .labelsHidden()
                        SwatchRow(selected: c) { step.color = $0 }
                    }
                }
            }
            if d.capabilities.colorTemp {
                HStack(spacing: 10) {
                    Toggle("Temperature", isOn: Binding(get: { step.colorTemp != nil }, set: {
                        let initial = Double(d.colorTemp ?? 2700)
                        step.colorTemp = $0 ? Int(min(max(initial, d.ctRange.lowerBound), d.ctRange.upperBound)) : nil
                        if $0 { step.color = nil }
                    }))
                        .toggleStyle(.checkbox).frame(width: 110, alignment: .leading)
                    if step.colorTemp != nil {
                        // Read/write the live step value (not a copy captured at render time), otherwise the
                        // slider's snap-on-release reads a stale value and reverts the drag.
                        TemperatureSlider(
                            kelvin: Binding(
                                get: { Double(step.colorTemp ?? 2700) },
                                set: { step.colorTemp = Int($0.rounded()) }),
                            range: d.ctRange
                        ).controlSize(.small)
                    }
                }
            }
        }
        .font(.system(size: 12))
    }
}
