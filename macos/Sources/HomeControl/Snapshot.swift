import AppKit
import SwiftUI

/// Dev tool: `HomeControl.app/Contents/MacOS/HomeControl --snapshot <dir>` renders the menu and
/// every settings pane (light + dark) to PNGs using live data from an already-running backend.
/// Never writes config.json.
@MainActor
enum Snapshot {
    static func run(_ dir: URL) {
        let model = AppModel.shared
        model.readOnly = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let v = ProcessInfo.processInfo.environment["HC_SNAPSHOT_UPDATE"] { Updater.shared.simulateAvailable(v) }
        Task {
            await model.refresh()
            if model.config.presets.isEmpty, model.devices.count >= 2 {
                // Sample preset (in memory only) so the editor has something to show.
                let ds = model.devices
                model.config.presets = [
                    Preset(name: "Evening", icon: "moon", mode: .sequential, delayMs: 500, steps: [
                        PresetStep(deviceId: ds[0].id, deviceName: ds[0].name, action: .on, brightness: 40, colorTemp: 2400),
                        PresetStep(deviceId: ds[1].id, deviceName: ds[1].name, action: .off),
                    ] + (ds.first { $0.capabilities.color }.map { [PresetStep(deviceId: $0.id, deviceName: $0.name, action: .on, color: "#ff9500")] } ?? [])),
                    Preset(name: "All Off", icon: "power", steps: ds.map { PresetStep(deviceId: $0.id, deviceName: $0.name, action: .off) }),
                ]
            }
            for dark in [false, true] {
                let suffix = dark ? "dark" : "light"
                await render(MenuBarView(), size: nil, width: 320, dark: dark, to: dir.appendingPathComponent("menu-\(suffix).png"))
                for pane in Pane.allCases {
                    SettingsRouter.shared.pane = pane
                    await render(SettingsView(), size: CGSize(width: 900, height: 620), dark: dark,
                                 to: dir.appendingPathComponent("settings-\(pane.rawValue)-\(suffix).png"))
                }
                await render(IconGrid(icon: .constant("moon")), size: nil, width: 280, dark: dark, to: dir.appendingPathComponent("icon-grid-\(suffix).png"))
                if let d = model.devices.first(where: { $0.capabilities.color }) ?? model.devices.first {
                    await render(DeviceDetail(deviceId: d.id), size: nil, width: 330, dark: dark, to: dir.appendingPathComponent("device-detail-\(suffix).png"))
                }
            }
            print("snapshots written to \(dir.path)")
            exit(0)
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize?, width: CGFloat = 0, dark: Bool, to url: URL) async {
        let host = NSHostingView(rootView: view.environment(AppModel.shared).background(Color(nsColor: .windowBackgroundColor)))
        let win = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: size?.width ?? width, height: size?.height ?? 600),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        win.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        if size == nil {
            let fit = host.fittingSize
            win.setContentSize(CGSize(width: width, height: fit.height))
            try? await Task.sleep(for: .milliseconds(300))
        }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        win.orderOut(nil)
    }
}
