import SwiftUI

private struct RemoteNote: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if !model.config.backend.isLocal {
            StatusMessage(kind: .info, text: "You're using a remote backend (\(model.config.backend.host)). It reads integration settings from its own config.json and .env; these settings only affect the local copy.")
        }
    }
}

// MARK: - Philips Hue

struct HuePane: View {
    @Environment(AppModel.self) private var model
    @State private var ip = ""
    @State private var test: (StatusMessage.Kind, String)?
    @State private var pairing: (StatusMessage.Kind, String)?
    @State private var pairTask: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model
        Group {
        PaneHeader(title: "Philips Hue", subtitle: "Control Hue bulbs through your Hue Bridge on the local network.")
        RemoteNote()

        Card {
            Row(title: "Enabled", divider: true) {
                Toggle("", isOn: $model.config.integrations.hue.enabled).toggleStyle(.switch).labelsHidden()
            }
            Row(title: "Bridge IP address", subtitle: "Find it in the Hue app under Settings → Bridges.", divider: true) {
                TextField("192.168.1.2", text: $ip)
                    .textFieldStyle(.roundedBorder).frame(width: 160).multilineTextAlignment(.trailing)
                    .onSubmit(commitIP)
            }
            Row(title: "Pairing", subtitle: pairedSubtitle, divider: false) {
                Button(pairTask == nil ? "Pair Bridge…" : "Cancel") { pairTask == nil ? pair() : cancelPair() }
                    .disabled(ip.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if let pairing { StatusMessage(kind: pairing.0, text: pairing.1) }

        Card {
            Row(title: "Connection", subtitle: "Pings the bridge through the backend.", divider: false) {
                Button("Test Connection") { runTest() }.disabled(test?.0 == .working)
            }
        }
        if let test { StatusMessage(kind: test.0, text: test.1) }

        if let err = model.providerErrors["hue"] { StatusMessage(kind: .error, text: err) }
        }
        .onAppear { ip = model.config.integrations.hue.bridgeIP }
        .onDisappear { commitIP(); cancelPair() }
    }

    private var pairedSubtitle: String {
        guard let h = model.health?.integrations["hue"] else { return "Press the bridge's link button, then click Pair." }
        return (h.configured ?? false) ? "Paired — the bridge key is stored in .env as HUE_USERNAME." : "Not paired yet. Press the round link button on the bridge, then click Pair."
    }

    private func commitIP() {
        let v = ip.trimmingCharacters(in: .whitespaces)
        if v != model.config.integrations.hue.bridgeIP { model.config.integrations.hue.bridgeIP = v }
    }

    private func runTest() {
        commitIP()
        test = (.working, "Contacting bridge…")
        Task {
            try? await Task.sleep(for: .milliseconds(400)) // let a just-saved IP reach the backend
            do {
                let r = try await model.client.hueTest()
                var s = "Connected to “\(r.bridgeName ?? "Hue Bridge")” · \(r.lightCount) lights · \(r.latencyMs) ms"
                if r.unreachable > 0 { s += " · \(r.unreachable) unreachable" }
                test = (.ok, s)
            } catch { test = (.error, error.localizedDescription) }
        }
    }

    private func pair() {
        commitIP()
        let target = ip.trimmingCharacters(in: .whitespaces)
        pairing = (.working, "Press the round link button on the bridge… (waiting up to 30 s)")
        pairTask = Task {
            defer { pairTask = nil }
            try? await Task.sleep(for: .milliseconds(400))
            for _ in 0..<15 {
                if Task.isCancelled { return }
                do {
                    let r = try await model.client.huePair(ip: target)
                    if r.paired {
                        pairing = (.ok, "Paired with the bridge.")
                        await model.refresh()
                        return
                    }
                } catch {
                    pairing = (.error, error.localizedDescription)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            pairing = (.error, "Timed out — the link button wasn't pressed.")
        }
    }

    private func cancelPair() {
        guard let t = pairTask else { return }
        t.cancel(); pairTask = nil
        pairing = nil
    }
}

// MARK: - Kasa

struct KasaPane: View {
    @Environment(AppModel.self) private var model
    @State private var test: (StatusMessage.Kind, String)?

    var body: some View {
        @Bindable var model = model
        PaneHeader(title: "Kasa", subtitle: "TP-Link Kasa / Tapo plugs, switches and bulbs, discovered on the local network.")
        RemoteNote()

        Card {
            Row(title: "Enabled") {
                Toggle("", isOn: $model.config.integrations.kasa.enabled).toggleStyle(.switch).labelsHidden()
            }
            Row(title: "TP-Link account", subtitle: credentialSubtitle) {
                HStack {
                    Button("Reveal") { model.reveal(Paths.env) }
                    Button("Open .env") { model.openInEditor(Paths.env) }
                }
            }
            Row(title: "Discovery timeout", subtitle: "How long to listen for devices on the network.", divider: false) {
                Stepper(value: $model.config.integrations.kasa.discoveryTimeout, in: 2...30) {
                    Text("\(model.config.integrations.kasa.discoveryTimeout) s").monospacedDigit()
                }
            }
        }

        Card {
            Row(title: "Connection", subtitle: "Rediscovers devices on the network and checks they respond.", divider: false) {
                Button("Test Connection") { runTest() }.disabled(test?.0 == .working)
            }
        }
        if let test { StatusMessage(kind: test.0, text: test.1) }
        if let err = model.providerErrors["kasa"] { StatusMessage(kind: .error, text: err) }

        Card(title: ".env format") {
            Text("KASA_USERNAME=you@example.com\nKASA_PASSWORD=your-tplink-password")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        Text("Newer devices (KLAP/Tapo firmware) need your TP-Link cloud credentials for local control; nothing is sent to the cloud. The backend picks up .env changes automatically.")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
    }

    private var credentialSubtitle: String {
        guard let h = model.health?.integrations["kasa"] else { return "Credentials are read from .env." }
        return (h.hasCredentials ?? false) ? "Credentials found in .env." : "No credentials in .env — add KASA_USERNAME and KASA_PASSWORD."
    }

    private func runTest() {
        test = (.working, "Discovering devices…")
        Task {
            do {
                let r = try await model.client.kasaTest()
                if r.ok {
                    test = (.ok, "\(r.onlineCount) of \(r.deviceCount) devices responding · discovery took \(String(format: "%.1f", Double(r.latencyMs) / 1000)) s" + (r.error.map { "\n\($0)" } ?? ""))
                } else {
                    test = (.error, r.error ?? (r.hasCredentials ? "No devices responded." : "No devices responded — credentials are missing from .env."))
                }
                await model.refresh()
            } catch { test = (.error, error.localizedDescription) }
        }
    }
}
