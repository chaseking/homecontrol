import SwiftUI

// MARK: - Customize

struct CustomizePane: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = AppModel.shared.launchAtLogin

    private let icons = ["house", "house.fill", "lightbulb", "lightbulb.2", "lightswitch.on", "powerplug", "sparkles", "switch.2"]

    var body: some View {
        @Bindable var model = model
        PaneHeader(title: "Customize", subtitle: "Appearance and menu bar behavior.")

        Card(title: "Appearance") {
            HStack(spacing: 14) {
                ForEach(Appearance.allCases) { a in
                    AppearanceSwatch(appearance: a, selected: model.config.appearance == a) { model.config.appearance = a }
                }
                Spacer()
            }
            .padding(14)
        }

        Card(title: "Menu bar") {
            Row(title: "Menu bar icon") {
                HStack(spacing: 4) {
                    ForEach(icons, id: \.self) { icon in
                        Button { model.config.menu.icon = icon } label: {
                            Image(systemName: icon).frame(width: 26, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6).fill(model.config.menu.icon == icon ? Color.accentColor.opacity(0.18) : .clear))
                                .foregroundStyle(model.config.menu.icon == icon ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Row(title: "Default view", subtitle: "What the menu shows when it opens.") {
                Picker("", selection: $model.config.menu.defaultView) { ForEach(MenuView.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Row(title: "Show offline devices in menu", divider: false) {
                Toggle("", isOn: $model.config.menu.showOffline).toggleStyle(.switch).labelsHidden()
            }
        }

        Card(title: "General") {
            Row(title: "Refresh interval", subtitle: "How often device state is polled while a HomeControl window is open.") {
                Picker("", selection: $model.config.refreshInterval) {
                    Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0); Text("1 minute").tag(60.0)
                }
                .labelsHidden().fixedSize()
            }
            Row(title: "Launch at login", divider: false) {
                Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                    .onChange(of: launchAtLogin) { _, v in model.launchAtLogin = v; launchAtLogin = model.launchAtLogin }
            }
        }
    }
}

private struct AppearanceSwatch: View {
    let appearance: Appearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    switch appearance {
                    case .light: mini(bg: .white, fg: Color(white: 0.85))
                    case .dark: mini(bg: Color(white: 0.16), fg: Color(white: 0.32))
                    case .system:
                        HStack(spacing: 0) {
                            mini(bg: .white, fg: Color(white: 0.85))
                            mini(bg: Color(white: 0.16), fg: Color(white: 0.32))
                        }
                    }
                }
                .frame(width: 96, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                Text(appearance.label).font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func mini(bg: Color, fg: Color) -> some View {
        ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(fg).frame(width: 30, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(fg).frame(width: 46, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: 22, height: 5)
            }
            .padding(10)
        }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var port = 8790
    @State private var token = ""
    @State private var test: (StatusMessage.Kind, String)?

    private var dirty: Bool {
        host.trimmingCharacters(in: .whitespaces) != model.config.backend.host || port != model.config.backend.port || token != model.config.backend.token
    }

    var body: some View {
        Group {
            PaneHeader(title: "Advanced", subtitle: "Updates, and where the backend that talks to your devices runs.")

            UpdateCard()

            Card(title: "Backend") {
                Row(title: "Host", subtitle: "Leave blank to run the backend locally with the app. Otherwise the hostname or IP of a machine running backend/server.py --host 0.0.0.0.") {
                    TextField("Local", text: $host)
                        .textFieldStyle(.roundedBorder).frame(width: 200).multilineTextAlignment(.trailing)
                        .onSubmit(apply)
                }
                Row(title: "Port") {
                    TextField("8790", value: $port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                        .onSubmit(apply)
                }
                Row(title: "Access token", subtitle: "Optional. Must match HOMECONTROL_TOKEN in the backend's .env.", divider: false) {
                    SecureField("None", text: $token)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit(apply)
                }
            }
            HStack(spacing: 10) {
                if dirty {
                    Button("Apply") { apply() }.buttonStyle(.borderedProminent)
                    Button("Revert") { load() }
                }
                Button("Test Connection") { runTest() }.disabled(test?.0 == .working)
                Spacer()
            }
            if let test { StatusMessage(kind: test.0, text: test.1) }

            if model.config.backend.isLocal {
                Card(title: "Local backend") {
                    Row(title: "Status", subtitle: model.local.status.label) {
                        HStack {
                            Button("Restart") { Task { await model.local.restart(); await model.refresh() } }
                            Button("View Log") { model.openInEditor(Paths.backendLog) }
                        }
                    }
                    Row(title: "Python environment", subtitle: Paths.python.path, divider: false) { EmptyView() }
                }
            }

            Card(title: "Files") {
                fileRow("config.json", "Everything in these settings, including presets.", ConfigStore.url)
                fileRow(".env", "Secrets: Kasa credentials, Hue bridge key, optional token.", Paths.env)
                Row(title: "Reload config.json", subtitle: "Picks up edits made by hand (also happens automatically).", divider: false) {
                    Button("Reload") { model.reloadConfigFromDisk(); load() }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func fileRow(_ name: String, _ subtitle: String, _ url: URL) -> some View {
        Row(title: name, subtitle: subtitle + "\n" + url.path) {
            HStack {
                Button("Reveal") { model.reveal(url) }
                Button("Open") { model.openInEditor(url) }
            }
        }
    }

    private func load() {
        host = model.config.backend.host
        port = model.config.backend.port
        token = model.config.backend.token
    }

    private func apply() {
        guard dirty else { return }
        model.config.backend.host = host.trimmingCharacters(in: .whitespaces)
        model.config.backend.port = min(max(port, 1), 65535)
        model.config.backend.token = token
        test = nil
    }

    private func runTest() {
        let client = BackendClient(config: .init(host: host.trimmingCharacters(in: .whitespaces), port: port, token: token))
        let target = client.baseURL.absoluteString
        test = (.working, "Pinging \(target)…")
        Task {
            var times: [Double] = []
            var health: Health?
            do {
                for _ in 0..<4 {
                    let t0 = Date()
                    health = try await client.health(timeout: 4)
                    times.append(Date().timeIntervalSince(t0) * 1000)
                }
                guard let h = health else { return }
                let ping = times.dropFirst().min() ?? times[0]  // first request includes connection setup
                var msg = String(format: "Connected to %@ · backend v%@ · ping %.1f ms", target, h.version, ping)
                if h.authRequired && !h.authorized {
                    test = (.error, msg + "\nThe backend requires an access token and this one doesn't match.")
                } else {
                    msg += " · up \(formatUptime(h.uptimeS))"
                    test = (.ok, msg)
                }
            } catch {
                test = (.error, "\(target): \(error.localizedDescription)")
            }
        }
    }

    private func formatUptime(_ s: Int) -> String {
        s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
