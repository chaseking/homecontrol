import Foundation

// MARK: - API models

struct Capabilities: Codable, Equatable, Hashable {
    var dimmable = false
    var color = false
    var colorTemp = false
    var colorTempRange: [Int]?
    var rename = false
}

struct Device: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var provider: String
    var name: String
    var kind: String
    var model: String?
    var online: Bool
    var on: Bool
    var brightness: Int?
    var color: String?
    var colorTemp: Int?
    var capabilities: Capabilities
    var nativeId: String?

    var providerLabel: String { provider == "hue" ? "Philips Hue" : provider == "kasa" ? "Kasa" : provider.capitalized }
    var kindLabel: String {
        switch kind {
        case "lightstrip": return "Light strip"
        case "outlet": return "Outlet"
        default: return kind.capitalized
        }
    }
    var isLight: Bool { ["bulb", "lightstrip", "dimmer"].contains(kind) || capabilities.dimmable }
    var symbol: String {
        switch kind {
        case "bulb": return on ? "lightbulb.fill" : "lightbulb"
        case "lightstrip": return "light.strip.2"
        case "plug", "outlet": return on ? "powerplug.fill" : "powerplug"
        case "switch", "dimmer": return "lightswitch.on"
        default: return "bolt.circle"
        }
    }
    var ctRange: ClosedRange<Double> {
        let r = capabilities.colorTempRange ?? [2200, 6500]
        return Double(r.first ?? 2200)...Double(r.last ?? 6500)
    }
}

struct DeviceList: Codable { var devices: [Device]; var errors: [String: String] }

struct Health: Codable {
    struct Integ: Codable { var enabled: Bool; var configured: Bool?; var hasCredentials: Bool?; var bridgeIp: String? }
    var service: String
    var version: String
    var uptimeS: Int
    var authRequired: Bool
    var authorized: Bool
    var integrations: [String: Integ]
}

struct StepResult: Codable { var stepId: String?; var deviceId: String?; var ok: Bool; var error: String?; var device: Device?; var ms: Int? }
struct RunResponse: Codable { var ok: Bool; var results: [StepResult]; var ms: Int }

struct HueTest: Codable { var ok: Bool; var latencyMs: Int; var bridgeName: String?; var apiVersion: String?; var lightCount: Int; var unreachable: Int }
struct HuePair: Codable { var paired: Bool; var message: String }
struct KasaTest: Codable { var ok: Bool; var hasCredentials: Bool; var latencyMs: Int; var deviceCount: Int; var onlineCount: Int; var devices: [String]; var error: String? }

/// Partial device update sent to POST /devices/{id}. nil fields are omitted.
struct DeviceCommand: Encodable {
    var on: Bool?
    var toggle: Bool?
    var brightness: Int?
    var color: String?
    var colorTemp: Int?
    var name: String?
}

// MARK: - HTTP client

enum BackendError: LocalizedError {
    case unreachable(String)
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let m): return "Backend unreachable: \(m)"
        case .http(_, let m): return m
        case .decoding(let m): return "Unexpected response from backend: \(m)"
        }
    }
}

struct BackendClient {
    let baseURL: URL
    let token: String

    init(config: AppConfig.Backend) {
        let host = config.isLocal ? "127.0.0.1" : config.host.trimmingCharacters(in: .whitespaces)
        // Accept "host", "host:port" or a full URL in the host field.
        if host.hasPrefix("http://") || host.hasPrefix("https://"), let u = URL(string: host) {
            baseURL = u
        } else if host.contains(":") && !host.contains("::") {
            baseURL = URL(string: "http://\(host)")!
        } else {
            let h = host.contains(":") ? "[\(host)]" : host  // bare IPv6
            baseURL = URL(string: "http://\(h):\(config.port)") ?? URL(string: "http://127.0.0.1:8790")!
        }
        token = config.token
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }()

    func request<T: Decodable>(_ method: String, _ path: String, body: Encodable? = nil, timeout: TimeInterval = 15) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try Self.encoder.encode(AnyEncodable(body))
        }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw BackendError.unreachable(error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw BackendError.http(status, msg ?? "HTTP \(status)")
        }
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw BackendError.decoding(String(describing: error)) }
    }

    func health(timeout: TimeInterval = 3) async throws -> Health { try await request("GET", "health", timeout: timeout) }
    func devices() async throws -> DeviceList { try await request("GET", "devices", timeout: 20) }
    func set(_ id: String, _ cmd: DeviceCommand) async throws -> Device { try await request("POST", "devices/\(id)", body: cmd) }

    func run(_ preset: Preset) async throws -> RunResponse {
        struct Step: Encodable { var id: String; var deviceId: String; var action: String; var brightness: Int?; var color: String?; var colorTemp: Int? }
        struct Body: Encodable { var mode: String; var delayMs: Int; var steps: [Step] }
        let steps = preset.steps.map { s in
            Step(id: s.id.uuidString, deviceId: s.deviceId, action: s.action.rawValue,
                 brightness: s.action == .on ? s.brightness : nil,
                 color: s.action == .on ? s.color : nil,
                 colorTemp: s.action == .on && s.color == nil ? s.colorTemp : nil)
        }
        let timeout = 30 + Double(preset.steps.count) * (Double(preset.delayMs) / 1000 + 12)
        return try await request("POST", "run", body: Body(mode: preset.mode.rawValue, delayMs: preset.delayMs, steps: steps), timeout: timeout)
    }

    func hueTest() async throws -> HueTest { try await request("GET", "integrations/hue/test") }
    func huePair(ip: String) async throws -> HuePair {
        struct B: Encodable { var bridgeIp: String }
        return try await request("POST", "integrations/hue/pair", body: B(bridgeIp: ip))
    }
    func kasaTest() async throws -> KasaTest { try await request("GET", "integrations/kasa/test", timeout: 40) }
    func reload() async throws { let _: [String: Bool] = try await request("POST", "reload") }
    func shutdown() async { let _: [String: Bool]? = try? await request("POST", "shutdown", timeout: 2) }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

// MARK: - Local backend process

/// Runs backend/server.py as a child process when no remote host is configured,
/// restarting it if it crashes. The backend also exits on its own if the app dies.
@MainActor
@Observable
final class LocalBackend {
    enum Status: Equatable {
        case stopped, starting, running(pid: Int32), failed(String)
        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running(let pid): return "Running (pid \(pid))"
            case .failed(let m): return m
            }
        }
    }

    private(set) var status: Status = .stopped {
        didSet { if status != oldValue { NSLog("HomeControl backend: \(status.label)") } }
    }
    private var process: Process?
    private var port = 8790
    private var wantRunning = false
    private var crashTimes: [Date] = []

    func start(port: Int) async {
        if wantRunning, self.port == port, process?.isRunning == true { return }
        stop()
        self.port = port
        wantRunning = true
        crashTimes = []
        await launch()
    }

    func restart() async {
        let p = port
        stop()
        await start(port: p)
    }

    func stop() {
        wantRunning = false
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        status = .stopped
    }

    private func launch() async {
        guard wantRunning else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.python.path) else {
            status = .failed("Backend not installed — run scripts/setup-backend.sh")
            return
        }
        status = .starting
        // A backend left over from a previous run (or started by hand) would hold the port.
        let probe = BackendClient(config: .init(host: "", port: port))
        if (try? await probe.health(timeout: 1)) != nil {
            await probe.shutdown()
            try? await Task.sleep(for: .milliseconds(600))
        }
        guard wantRunning else { return }
        if !Self.portIsFree(port) {
            status = .failed("Port \(port) is used by another program — pick another port in Advanced")
            wantRunning = false
            return
        }

        try? fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        rotateLogIfNeeded()
        if !fm.fileExists(atPath: Paths.backendLog.path) { fm.createFile(atPath: Paths.backendLog.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: Paths.backendLog)
        log?.seekToEndOfFile()

        let p = Process()
        p.executableURL = Paths.python
        p.arguments = ["-u", Paths.backendScript.path, "--port", String(port),
                       "--config", ConfigStore.url.path, "--env", Paths.env.path,
                       "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        p.currentDirectoryURL = Paths.root
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.terminated(proc) }
        }
        do {
            try p.run()
            process = p
            // Wait for it to answer.
            for _ in 0..<40 {
                if (try? await probe.health(timeout: 0.5)) != nil { break }
                try? await Task.sleep(for: .milliseconds(150))
                if !p.isRunning { return }
            }
            if p.isRunning { status = .running(pid: p.processIdentifier) }
        } catch {
            status = .failed("Could not start backend: \(error.localizedDescription)")
        }
    }

    private func terminated(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        guard wantRunning else { status = .stopped; return }
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashTimes.count > 4 {
            status = .failed("Backend keeps crashing — see logs/backend.log")
            wantRunning = false
            return
        }
        status = .failed("Backend exited (code \(proc.terminationStatus)); restarting…")
        Task {
            try? await Task.sleep(for: .seconds(Double(crashTimes.count)))
            await launch()
        }
    }

    static func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        // Same as the backend (aiohttp binds with SO_REUSEADDR): ignore TIME_WAIT leftovers, only real listeners count.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return r == 0
    }

    private func rotateLogIfNeeded() {
        let url = Paths.backendLog
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
    }
}
