import Foundation

// MARK: - config.json schema (everything the app persists lives here)

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum MenuView: String, Codable, CaseIterable, Identifiable {
    case all, presets
    var id: String { rawValue }
    var label: String { self == .all ? "All" : "Presets" }
}

enum RunMode: String, Codable, CaseIterable, Identifiable {
    case parallel, sequential
    var id: String { rawValue }
    var label: String { self == .parallel ? "All at once" : "Sequentially" }
}

enum StepAction: String, Codable, CaseIterable, Identifiable {
    case on, off, toggle
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct PresetStep: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    /// Persistent hardware-based id from the backend (`hue:<uniqueid>` / `kasa:<deviceId>`).
    var deviceId: String
    /// Last known display name — only used when the device is not currently visible.
    var deviceName: String
    var action: StepAction = .on
    /// 0-100, only applied for `.on`
    var brightness: Int?
    /// "#rrggbb", only applied for `.on`
    var color: String?
    /// kelvin, only applied for `.on` (ignored if color is set)
    var colorTemp: Int?
}

extension PresetStep {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        deviceId = try c.decode(String.self, forKey: .deviceId)
        deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? deviceId
        action = (try? c.decode(StepAction.self, forKey: .action)) ?? .on
        brightness = try? c.decodeIfPresent(Int.self, forKey: .brightness)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        colorTemp = try? c.decodeIfPresent(Int.self, forKey: .colorTemp)
    }
}

struct Preset: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var icon: String = "sparkles"
    var mode: RunMode = .parallel
    /// pause between steps when running sequentially
    var delayMs: Int = 250
    var steps: [PresetStep] = []
}

extension Preset {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        icon = (try? c.decode(String.self, forKey: .icon)) ?? "sparkles"
        mode = (try? c.decode(RunMode.self, forKey: .mode)) ?? .parallel
        delayMs = (try? c.decode(Int.self, forKey: .delayMs)) ?? 250
        steps = (try? c.decode([PresetStep].self, forKey: .steps)) ?? []
    }
}

struct AppConfig: Codable, Equatable {
    struct Menu: Codable, Equatable {
        var defaultView: MenuView = .all
        var showOffline: Bool = true
        var icon: String = "house"
    }
    struct Backend: Codable, Equatable {
        /// blank = run the backend locally alongside the app
        var host: String = ""
        var port: Int = 8790
        var token: String = ""
        var isLocal: Bool { host.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    struct Hue: Codable, Equatable {
        var enabled = true
        var bridgeIP = ""
    }
    struct Kasa: Codable, Equatable {
        var enabled = true
        var discoveryTimeout = 5
    }
    struct Integrations: Codable, Equatable {
        var hue = Hue()
        var kasa = Kasa()
    }

    var version = 1
    var appearance: Appearance = .system
    var menu = Menu()
    var refreshInterval: Double = 10
    var backend = Backend()
    var integrations = Integrations()
    var presets: [Preset] = []
}

// MARK: - Loading / saving

enum ConfigStore {
    static var url: URL { Paths.config }

    /// Decodes config.json on top of the defaults, so missing keys (older files, hand edits) get default values.
    static func load() -> AppConfig {
        let defaults = AppConfig()
        guard let data = try? Data(contentsOf: url),
              let fileObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              let defObj = try? JSONSerialization.jsonObject(with: defData) as? [String: Any]
        else { return defaults }
        let merged = deepMerge(defObj, fileObj)
        do {
            let mergedData = try JSONSerialization.data(withJSONObject: merged)
            return try JSONDecoder().decode(AppConfig.self, from: mergedData)
        } catch {
            // Keep a copy so a later save can't silently destroy a hand-edited file.
            let backup = url.deletingPathExtension().appendingPathExtension("invalid.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            NSLog("HomeControl: config.json could not be decoded (\(error)); using defaults, backup at \(backup.path)")
            return defaults
        }
    }

    static func save(_ config: AppConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(config).write(to: url, options: .atomic)
    }

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] {
                out[k] = deepMerge(b, o)
            } else {
                out[k] = v
            }
        }
        return out
    }
}

// MARK: - Locations

enum Paths {
    /// The source folder (git checkout): backend/, its .venv, scripts/, VERSION.
    static let root: URL = {
        if let env = ProcessInfo.processInfo.environment["HOMECONTROL_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let p = Bundle.main.object(forInfoDictionaryKey: "HCProjectRoot") as? String,
           FileManager.default.fileExists(atPath: p + "/backend/server.py") {
            return URL(fileURLWithPath: p)
        }
        // Walk up from the executable looking for backend/server.py
        var dir = Bundle.main.bundleURL
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("backend/server.py").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return Bundle.main.bundleURL.deletingLastPathComponent()
    }()

    /// Your settings and secrets: ~/Library/Application Support/HomeControl (config.json, .env).
    static let support: URL = {
        if let env = ProcessInfo.processInfo.environment["HOMECONTROL_DATA"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HomeControl")
    }()
    /// ~/Library/Logs/HomeControl
    static let logs: URL = {
        if let env = ProcessInfo.processInfo.environment["HOMECONTROL_DATA"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("logs")
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/HomeControl")
    }()

    static var config: URL { support.appendingPathComponent("config.json") }
    static var env: URL { support.appendingPathComponent(".env") }
    static var backendScript: URL { root.appendingPathComponent("backend/server.py") }
    static var python: URL { root.appendingPathComponent("backend/.venv/bin/python") }
    static var backendLog: URL { logs.appendingPathComponent("backend.log") }
    static var updateLog: URL { logs.appendingPathComponent("update.log") }

    /// Creates the data folders and, on first run after upgrading from 0.1.0/0.1.1 (when config.json and .env
    /// lived in the source folder), copies them over. The old copies are left in place.
    static func prepareDataFolders() {
        let fm = FileManager.default
        try? fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: config.path), !fm.fileExists(atPath: env.path) else { return }
        for name in ["config.json", ".env"] {
            let old = root.appendingPathComponent(name)
            if fm.fileExists(atPath: old.path) { try? fm.copyItem(at: old, to: support.appendingPathComponent(name)) }  // keeps .env's 0600
        }
        let oldLog = root.appendingPathComponent("logs/backend.log")
        if fm.fileExists(atPath: oldLog.path), !fm.fileExists(atPath: backendLog.path) { try? fm.copyItem(at: oldLog, to: backendLog) }
    }
}
