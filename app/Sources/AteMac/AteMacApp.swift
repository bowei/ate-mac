import AppKit
import SwiftUI

@main
struct AteMacApp: App {
    @StateObject private var controller = Controller()

    var body: some Scene {
        MenuBarExtra {
            StatusPanel(controller: controller)
        } label: {
            Image(systemName: controller.ready ? "shippingbox.fill" : "shippingbox")
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.cpus) private var cpus = 4
    @AppStorage(Prefs.memoryGiB) private var memoryGiB = 6
    @AppStorage(Prefs.diskGiB) private var diskGiB = 40

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
