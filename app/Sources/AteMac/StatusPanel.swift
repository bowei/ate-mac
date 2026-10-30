import AppKit
import SwiftUI

/// The panel the menu bar icon opens: overall state, VM resource use, each
/// pod's health and usage, and the actions.
struct StatusPanel: View {
    @ObservedObject var controller: Controller
    @State private var showKubernetes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if controller.newImage {
                Label("A new image is bundled. Reset to use it.", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let stats = controller.stats {
                Divider()
                ResourceBar(
                    title: "CPU",
                    fraction: stats.vm.cpuPercent / 100,
                    text: String(format: "%.0f%% of %d cores", stats.vm.cpuPercent, stats.vm.cpus))
                ResourceBar(
                    title: "Memory",
                    fraction: Double(stats.vm.memoryUsedBytes) / Double(max(stats.vm.memoryTotalBytes, 1)),
                    text: "\(bytes(stats.vm.memoryUsedBytes)) of \(bytes(stats.vm.memoryTotalBytes))")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        PodSection(group: .substrate, pods: stats.pods(in: .substrate))
                        PodSection(group: .workers, pods: stats.pods(in: .workers))
                        DisclosureGroup(isExpanded: $showKubernetes) {
                            PodRows(pods: stats.pods(in: .kubernetes))
                        } label: {
                            SectionTitle(group: .kubernetes, pods: stats.pods(in: .kubernetes))
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Divider()
            actions
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 420)
        .onAppear { controller.panelVisible = true }
        .onDisappear { controller.panelVisible = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(overallColor).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Substrate").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private var actions: some View {
        HStack {
            switch controller.phase {
            case .notCreated, .stopped, .failed:
                Button("Start") { controller.start() }
            case .running:
                Button("Stop") { controller.stop() }
                Button("Restart") { controller.restart() }
            default:
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Reset…") { confirmReset() }
                .disabled(controller.phase == .starting || controller.phase == .stopping)
        }
    }

    private var footer: some View {
        HStack {
            Button("Copy Shell Setup") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.shellSetup, forType: .string)
            }
            Button("Show Log") { NSWorkspace.shared.open(controller.paths.log) }
            SettingsLink { Text("Settings…") }
            Spacer()
            Menu("Quit") {
                Button("Quit") { NSApp.terminate(nil) }
                if controller.phase == .running {
                    Button("Stop and Quit") { controller.stop { NSApp.terminate(nil) } }
                }
            }
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var statusText: String {
        switch controller.phase {
        case .unknown: return "…"
        case .notCreated: return "not installed"
        case .stopped: return "stopped"
        case .starting: return "starting VM"
        case .stopping: return "stopping"
        case .failed: return controller.detail
        case .running: return controller.detail.isEmpty ? "running" : controller.detail
        }
    }

    private var overallColor: Color {
        switch controller.phase {
        case .running: return controller.ready ? .green : .yellow
        case .starting, .stopping: return .yellow
        case .failed: return .red
        case .unknown, .notCreated, .stopped: return .gray
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset Substrate?"
        alert.informativeText = "This deletes the VM and everything in the cluster, then recreates it from the bundled image."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            controller.reset()
        }
    }
}

private struct ResourceBar: View {
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

private struct SectionTitle: View {
    let group: GuestStats.Group
    let pods: [GuestStats.Pod]

    var body: some View {
        HStack {
            Text(group.rawValue).font(.caption.bold())
            Text("\(pods.filter { $0.health == .healthy }.count)/\(pods.count) healthy")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct PodSection: View {
    let group: GuestStats.Group
    let pods: [GuestStats.Pod]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle(group: group, pods: pods)
                Text("CPU").frame(width: 48, alignment: .trailing)
                Text("Memory").frame(width: 64, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if pods.isEmpty {
                Text("none").font(.caption).foregroundStyle(.secondary)
            } else {
                PodRows(pods: pods, showNamespace: group == .workers)
            }
        }
    }
}

private struct PodRows: View {
    let pods: [GuestStats.Pod]
    var showNamespace = false

    var body: some View {
        ForEach(pods) { pod in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color(pod.health)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pod.name)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = note(pod) {
                        Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(pod.health == .healthy ? millicores(pod.cpuMillicores) : "–")
                    .frame(width: 48, alignment: .trailing)
                Text(pod.health == .healthy ? bytes(pod.memoryBytes) : "–")
                    .frame(width: 64, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .help("\(pod.namespace)/\(pod.name): \(pod.health.rawValue)")
        }
    }

    private func note(_ pod: GuestStats.Pod) -> String? {
        var parts: [String] = []
        if showNamespace { parts.append(pod.namespace) }
        // Every VM restart counts as a pod restart, so the count only helps
        // explain a pod that isn't healthy.
        if pod.health != .healthy {
            parts.append(pod.detail.isEmpty ? pod.health.rawValue : pod.detail)
            if pod.restarts > 0 { parts.append("\(pod.restarts) restart\(pod.restarts == 1 ? "" : "s")") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func color(_ h: GuestStats.Pod.Health) -> Color {
        switch h {
        case .healthy: return .green
        case .starting: return .yellow
        case .failing: return .red
        case .completed, .terminating: return .gray
        }
    }
}

private func millicores(_ m: Int) -> String {
    m >= 1000 ? String(format: "%.1f", Double(m) / 1000) : "\(m)m"
}

private func bytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .memory)
}
