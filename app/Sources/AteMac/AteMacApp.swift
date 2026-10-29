import AppKit
import SwiftUI

@main
struct AteMacApp: App {
    @StateObject private var controller = Controller()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.ready ? "shippingbox.fill" : "shippingbox")
        }
        Settings {
            SettingsView()
        }
    }
}

struct MenuContent: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Text("Substrate: \(statusText)")
        if controller.newImage {
            Text("A new image is bundled. Reset to use it.")
        }
        Divider()
        switch controller.phase {
        case .notCreated, .stopped, .failed:
            Button("Start") { controller.start() }
        case .running:
            Button("Stop") { controller.stop() }
        default:
            EmptyView()
        }
        Button("Reset…") { confirmReset() }
            .disabled(controller.phase == .starting || controller.phase == .stopping)
        Divider()
        Button("Copy Shell Setup") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(controller.shellSetup, forType: .string)
        }
        Button("Show Log") { NSWorkspace.shared.open(controller.paths.log) }
        SettingsLink { Text("Settings…") }
        Divider()
        if controller.phase == .running {
            Button("Stop and Quit") { controller.stop { NSApp.terminate(nil) } }
        }
        Button("Quit") { NSApp.terminate(nil) }
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

struct SettingsView: View {
    @AppStorage(Prefs.cpus) private var cpus = 6
    @AppStorage(Prefs.memoryGiB) private var memoryGiB = 12
    @AppStorage(Prefs.diskGiB) private var diskGiB = 60

    var body: some View {
        Form {
            Stepper("CPUs: \(cpus)", value: $cpus, in: 2...ProcessInfo.processInfo.processorCount)
            Stepper("Memory: \(memoryGiB) GiB", value: $memoryGiB, in: 4...64)
            Stepper("Disk: \(diskGiB) GiB", value: $diskGiB, in: 40...500, step: 10)
            Text("CPU and memory apply on the next start. Disk size applies on the next reset.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 360)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}
