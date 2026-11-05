import AppKit
import SwiftUI

extension Controller {
    var statusText: String {
        switch phase {
        case .unknown: return "…"
        case .notCreated: return "Not installed"
        case .stopped: return "Stopped"
        case .starting: return "Starting VM"
        case .stopping: return "Stopping"
        case .failed: return detail
        case .running: return detail.isEmpty ? "Running" : detail.prefix(1).uppercased() + detail.dropFirst()
        }
    }

    var statusColor: Color {
        switch phase {
        case .running: return ready ? .green : .yellow
        case .starting, .stopping: return .yellow
        case .failed: return .red
        case .unknown, .notCreated, .stopped: return .gray
        }
    }

    func copyShellSetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellSetup, forType: .string)
    }

    func showLog() {
        NSWorkspace.shared.open(paths.log)
    }

    /// Asks before deleting the VM, then resets it.
    func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset Substrate?"
        alert.informativeText = "This deletes the VM and everything in the cluster, then recreates it from the bundled image."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            reset()
        }
    }
}

extension GuestStats.Health {
    var color: Color {
        switch self {
        case .healthy: return .green
        case .starting: return .yellow
        case .failing: return .red
        case .completed, .terminating: return .gray
        }
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct ResourceBar: View {
    let title: String
    let fraction: Double
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fraction > 0.9 ? Color.red : fraction > 0.7 ? .orange : .accentColor)
                        .frame(width: g.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 6)
        }
    }
}

/// A placeholder for views that need the cluster when it isn't up.
struct NotRunningView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        ContentUnavailableView {
            Label(controller.statusText, systemImage: "shippingbox")
        } description: {
            Text(controller.phase == .running ? "Waiting for the cluster to report its status."
                                              : "Start Substrate to see its components.")
        } actions: {
            if [.notCreated, .stopped, .failed].contains(controller.phase) {
                Button("Start") { controller.start() }
            }
        }
    }
}

func millicores(_ m: Int) -> String {
    m >= 1000 ? String(format: "%.1f", Double(m) / 1000) : "\(m)m"
}

func bytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .memory)
}

/// A short age, such as "45s", "12m", "5h" or "3d".
func age(_ date: Date?, now: Date = Date()) -> String {
    guard let date, date.timeIntervalSince1970 > 0 else { return "–" }
    return duration(now.timeIntervalSince(date))
}

func duration(_ seconds: TimeInterval) -> String {
    let s = Int(max(seconds, 0))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}
