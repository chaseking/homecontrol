import AppKit
import SwiftUI

@main
struct HomeControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.config.menu.icon)
        }
        .menuBarExtraStyle(.window)

        Window("HomeControl Settings", id: "settings") {
            SettingsView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "homecontrol-snapshots"
            MainActor.assumeIsolated { Snapshot.run(URL(fileURLWithPath: dir)) }
            return
        }
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { if !AppModel.shared.readOnly { AppModel.shared.shutdown() } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Shows the settings window and brings the (normally Dock-less) app to the front.
@MainActor
func showSettings(_ openWindow: OpenWindowAction) {
    NSApp.setActivationPolicy(.regular)
    openWindow(id: "settings")
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
        NSApp.windows.first { $0.identifier?.rawValue == "settings" }?.makeKeyAndOrderFront(nil)
    }
}
