import SwiftUI

/// Prominent "Update to vX" row shown in the menu bar popover when a newer version exists.
struct UpdateBanner: View {
    @State private var updater = Updater.shared

    var body: some View {
        if let v = updater.available {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(updater.state == .updating ? "Updating…" : "Version \(v.description) available").font(.system(size: 12.5, weight: .medium))
                        Text(updater.state == .updating ? "Downloading and building. HomeControl will restart." : "You have \(updater.current.description)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if updater.state == .updating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Update") { updater.install() }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                if case .failed(let msg) = updater.state {
                    StatusMessage(kind: .error, text: msg).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.10)))
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
    }
}

/// Small sidebar pill in Settings.
struct UpdatePill: View {
    @State private var updater = Updater.shared
    let open: () -> Void

    var body: some View {
        if let v = updater.available {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Update to \(v.description)").font(.system(size: 11.5, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(Color.accentColor)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }
}

/// "About & updates" card for Settings.
struct UpdateCard: View {
    @State private var updater = Updater.shared

    private var subtitle: String {
        if updater.state == .updating { return "Downloading and building. HomeControl will restart when it's done." }
        if let v = updater.available { return "Version \(v.description) is available." }
        if updater.state == .checking { return "Checking…" }
        if let e = updater.checkError { return "Couldn't check for updates: \(e)" }
        if let d = updater.lastChecked { return "You're up to date. Checked \(d.formatted(date: .omitted, time: .shortened))." }
        return "Not checked yet."
    }

    var body: some View {
        Card(title: "Version") {
            Row(title: "HomeControl \(updater.current.description)", subtitle: subtitle, divider: false) {
                HStack(spacing: 8) {
                    if updater.state == .updating || updater.state == .checking {
                        ProgressView().controlSize(.small)
                    }
                    if let v = updater.available, updater.state != .updating {
                        Button("Update to \(v.description)") { updater.install() }.buttonStyle(.borderedProminent)
                    }
                    Button("View Log") { AppModel.shared.openInEditor(Paths.updateLog) }
                    Button("Check for Updates") { Task { await updater.check() } }.disabled(updater.isBusy)
                }
            }
            if case .failed(let msg) = updater.state {
                HStack { StatusMessage(kind: .error, text: "Update failed: \(msg)"); Spacer() }
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }
}
