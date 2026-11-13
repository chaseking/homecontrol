import AppKit
import Foundation
import ServiceManagement
import UserNotifications

enum Connection: Equatable {
    case connecting
    case online
    case offline(String)
}

enum RunState: Equatable {
    case running
    case succeeded(Date)
    case failed([String])
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var config: AppConfig {
        didSet { if config != oldValue { configChanged(from: oldValue) } }
    }
    private(set) var devices: [Device] = []
    private(set) var providerErrors: [String: String] = [:]
    private(set) var connection: Connection = .connecting
    private(set) var lastRefresh: Date?
    private(set) var health: Health?
    var pending: Set<String> = []
    var runStates: [UUID: RunState] = [:]
    /// Transient error shown in the menu bar popover.
    var banner: String?

    let local = LocalBackend()
    /// Snapshot/dev mode: never write config.json.
    var readOnly = false
    var menuVisible = false
    var settingsVisible = false

    private var saveTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var refreshing = false
    private var lastSavedMtime: Date?

    var client: BackendClient { BackendClient(config: config.backend) }

    private init() {
        config = ConfigStore.load()
        lastSavedMtime = ConfigStore.modificationDate()
    }

    // MARK: lifecycle

    func start() {
        Notifier.setup()
        applyAppearance()
        scheduleSave()  // write out the full schema (with defaults) on launch
        Updater.shared.startChecking()
        Task {
            if config.backend.isLocal { await local.start(port: config.backend.port) }
            await refresh()
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let visible = self.menuVisible || self.settingsVisible
                let wait = visible ? max(3, self.config.refreshInterval) : 60
                try? await Task.sleep(for: .seconds(wait))
                self.reloadIfEditedExternally()
                await self.refresh()
            }
        }
    }

    func shutdown() {
        local.stop()
    }

    // MARK: config

    private func configChanged(from old: AppConfig) {
        scheduleSave()
        if old.appearance != config.appearance { applyAppearance() }
        if old.backend != config.backend {
            Task {
                if config.backend.isLocal {
                    if !old.backend.isLocal || old.backend.port != config.backend.port {
                        await local.start(port: config.backend.port)
                    }
                } else {
                    local.stop()
                }
                connection = .connecting
                await refresh()
            }
        }
        if old.integrations != config.integrations {
            // The backend re-reads config.json on its next request; refresh once the save landed.
            Task { try? await Task.sleep(for: .milliseconds(700)); await refresh() }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard !readOnly else { return }
        do {
            try ConfigStore.save(config)
            lastSavedMtime = ConfigStore.modificationDate()
        } catch {
            banner = "Could not save config.json: \(error.localizedDescription)"
        }
    }

    /// Picks up hand edits to config.json.
    func reloadIfEditedExternally() {
        guard let m = ConfigStore.modificationDate(), let last = lastSavedMtime, m > last.addingTimeInterval(0.5) else { return }
        reloadConfigFromDisk()
    }

    func reloadConfigFromDisk() {
        lastSavedMtime = ConfigStore.modificationDate()
        let loaded = ConfigStore.load()
        if loaded != config { config = loaded }
    }

    func applyAppearance() {
        switch config.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: devices

    var visibleMenuDevices: [Device] {
        devices.filter { config.menu.showOffline || $0.online }
    }

    func device(_ id: String) -> Device? { devices.first { $0.id == id } }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let c = client
        do {
            let list = try await c.devices()
            devices = list.devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            providerErrors = list.errors
            connection = .online
            lastRefresh = Date()
            health = try? await c.health()
            syncStepNames()
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    /// Keep the cached device names in presets current (ids never change, names may).
    private func syncStepNames() {
        let names = Dictionary(devices.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        var presets = config.presets
        for pi in presets.indices {
            for si in presets[pi].steps.indices {
                if let n = names[presets[pi].steps[si].deviceId], n != presets[pi].steps[si].deviceName {
                    presets[pi].steps[si].deviceName = n
                    changed = true
                }
            }
        }
        if changed { config.presets = presets }
    }

    func toggle(_ d: Device) async {
        await send(d.id, DeviceCommand(on: !d.on), optimistic: { $0.on.toggle() })
    }

    func setPower(_ d: Device, _ on: Bool) async {
        await send(d.id, DeviceCommand(on: on), optimistic: { $0.on = on })
    }

    func send(_ id: String, _ cmd: DeviceCommand, optimistic: ((inout Device) -> Void)? = nil) async {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        let before = devices[idx]
        if let optimistic { optimistic(&devices[idx]) }
        pending.insert(id)
        defer { pending.remove(id) }
        do {
            let updated = try await client.set(id, cmd)
            if let i = devices.firstIndex(where: { $0.id == id }) { devices[i] = updated }
            if cmd.name != nil { devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }; syncStepNames() }
        } catch {
            if let i = devices.firstIndex(where: { $0.id == id }) { devices[i] = before }
            let msg = error.localizedDescription
            banner = "\(before.name): \(msg)"
            Notifier.post(title: "Couldn’t control \(before.name)", body: msg)
        }
    }

    // MARK: presets

    func run(_ preset: Preset) async {
        guard runStates[preset.id] != .running else { return }
        guard !preset.steps.isEmpty else {
            runStates[preset.id] = .failed(["This preset has no steps"]); return
        }
        runStates[preset.id] = .running
        do {
            let res = try await client.run(preset)
            for r in res.results {
                if let d = r.device, let i = devices.firstIndex(where: { $0.id == d.id }) { devices[i] = d }
            }
            let failures = res.results.filter { !$0.ok }.map { r -> String in
                let name = preset.steps.first { $0.id.uuidString == r.stepId }?.deviceName ?? r.deviceId ?? "Device"
                return "\(name): \(r.error ?? "failed")"
            }
            if failures.isEmpty {
                runStates[preset.id] = .succeeded(Date())
            } else {
                runStates[preset.id] = .failed(failures)
                let head = failures.count == preset.steps.count ? "All \(failures.count) steps failed" : "\(failures.count) of \(preset.steps.count) steps failed"
                Notifier.post(title: "“\(preset.name)” — \(head)", body: failures.prefix(4).joined(separator: "\n"))
            }
        } catch {
            runStates[preset.id] = .failed([error.localizedDescription])
            Notifier.post(title: "“\(preset.name)” didn’t run", body: error.localizedDescription)
        }
        // Clear the success checkmark after a moment.
        if case .succeeded = runStates[preset.id] {
            let id = preset.id
            Task { try? await Task.sleep(for: .seconds(4)); if case .succeeded = runStates[id] { runStates[id] = nil } }
        }
    }

    // MARK: misc

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                banner = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    func openInEditor(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", url.path]  // default text editor; .env has no file-type association
        try? p.run()
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

// MARK: - Notifications

enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }
    private static let delegate = Delegate()

    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }

    static func setup() {
        guard available else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { NSLog("HomeControl: \(title) — \(body)"); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
