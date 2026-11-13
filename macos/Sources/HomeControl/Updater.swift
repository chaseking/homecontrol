import AppKit
import Foundation

/// Release.major.minor, e.g. 0.1.0.
struct AppVersion: Comparable, CustomStringConvertible, Equatable {
    let parts: [Int]

    init?(_ s: String) {
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard p.count == 3, !p.contains(nil) else { return nil }
        parts = p.compactMap { $0 }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    var description: String { parts.map(String.init).joined(separator: ".") }
}

/// Checks the GitHub repo's VERSION file and, on request, runs scripts/update.sh
/// (git pull, rebuild, relaunch).
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case updating
        case failed(String)
    }

    static let repo = "chaseking/homecontrol"
    static let branch = "main"
    private static let versionURL = URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/VERSION")!

    private(set) var state: State = .idle
    private(set) var latest: AppVersion?
    private(set) var lastChecked: Date?
    /// Set when the last check couldn't reach or parse the repo's VERSION file.
    private(set) var checkError: String?
    let current: AppVersion

    private var timer: Task<Void, Never>?

    private init() {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let file = try? String(contentsOf: Paths.root.appendingPathComponent("VERSION"), encoding: .utf8)
        current = bundled.flatMap(AppVersion.init) ?? file.flatMap(AppVersion.init) ?? AppVersion("0.0.0")!
    }

    /// The newer version on GitHub, if there is one.
    var available: AppVersion? {
        guard let latest, latest > current else { return nil }
        return latest
    }

    var isBusy: Bool { state == .checking || state == .updating }

    /// Checks now, then every few hours.
    func startChecking() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func check() async {
        guard !isBusy else { return }
        state = .checking
        defer { if state == .checking { state = .idle } }
        var req = URLRequest(url: Self.versionURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError("GitHub returned HTTP \(http.statusCode)")
            }
            guard let v = AppVersion(String(decoding: data, as: UTF8.self)) else { throw UpdateError("Unrecognized version file") }
            latest = v
            checkError = nil
        } catch {
            checkError = error.localizedDescription
        }
        lastChecked = Date()
    }

    /// Downloads, builds and relaunches the newer version. The update script ends by restarting the
    /// app, so on success this process is replaced.
    func install() {
        guard available != nil, !isBusy else { return }
        let root = Paths.root
        let script = root.appendingPathComponent("scripts/update.sh")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            state = .failed("This copy of HomeControl isn't a git checkout, so it can't update itself. Clone https://github.com/\(Self.repo) and build it from there.")
            return
        }
        state = .updating
        let log = Paths.updateLog
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)

        let branch = Self.branch
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            p.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.cargo/bin"]
            env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
            env["HOMECONTROL_BRANCH"] = branch
            p.environment = env
            if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
            let failure: String?
            do {
                try p.run()
                p.waitUntilExit()
                failure = p.terminationStatus == 0 ? nil : Self.tail(of: log)
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { Updater.shared.state = failure.map { .failed($0) } ?? .idle }
        }
    }

    /// Snapshot/dev only: pretend GitHub has `version`.
    func simulateAvailable(_ version: String) { latest = AppVersion(version); lastChecked = Date() }

    func dismissFailure() { if case .failed = state { state = .idle } }

    private nonisolated static func tail(of url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").suffix(4).joined(separator: "\n")
        return lines.isEmpty ? "The update script failed. See ~/Library/Logs/HomeControl/update.log." : lines
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }
}
