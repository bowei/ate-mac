import Charts
import SwiftUI

/// The first section: the VM, a tile per Substrate component, and counts of
/// workers, actors and recent warnings.
struct OverviewView: View {
    @ObservedObject var controller: Controller
    /// Called when a component tile is clicked.
    let select: (GuestStats.Component) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if controller.newImage {
                    Label("A new image is bundled. Reset to use it.", systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                }
                if let stats = controller.stats {
                    HStack(alignment: .top, spacing: 16) {
                        VMCard(controller: controller, vm: stats.vm)
                        SummaryCard(controller: controller, stats: stats)
                    }
                    componentGrid(stats)
                } else {
                    NotRunningView(controller: controller)
                        .frame(minHeight: 240)
                    ImageCard(controller: controller)
                }
            }
            .padding(16)
        }
    }

    private func componentGrid(_ stats: GuestStats) -> some View {
        let components = stats.components(in: .substrate)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Substrate components").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                ForEach(components) { c in
                    Button { select(c) } label: { ComponentTile(component: c) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ComponentTile: View {
    let component: GuestStats.Component

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: component.health.color, size: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(component.detail.isEmpty ? "\(component.ready)/\(component.desired) ready · \(component.kind)"
                                              : component.detail)
                    .font(.caption)
                    .foregroundStyle(component.detail.isEmpty ? Color.secondary : .orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(component.health == .healthy ? .clear
                                                                 : component.health.color.opacity(0.6)))
        .contentShape(Rectangle())
        .help(component.detail.isEmpty ? component.name : component.detail)
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text(title).font(.headline)
        }
    }
}

private struct VMCard: View {
    @ObservedObject var controller: Controller
    let vm: GuestStats.VM

    var body: some View {
        Card(title: "VM") {
            ResourceBar(
                title: "CPU",
                fraction: vm.cpuPercent / 100,
                text: String(format: "%.0f%% of %d cores", vm.cpuPercent, vm.cpus))
            ResourceBar(
                title: "Memory",
                fraction: Double(vm.memoryUsedBytes) / Double(max(vm.memoryTotalBytes, 1)),
                text: "\(bytes(vm.memoryUsedBytes)) of \(bytes(vm.memoryTotalBytes))")
            if vm.diskTotalBytes > 0 {
                ResourceBar(
                    title: "Disk",
                    fraction: Double(vm.diskUsedBytes) / Double(vm.diskTotalBytes),
                    text: "\(bytes(vm.diskUsedBytes)) of \(bytes(vm.diskTotalBytes))")
            }
            if controller.history.count > 1 {
                HistoryChart(history: controller.history)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                if vm.uptimeSeconds > 0 {
                    GridRow { Text("Uptime").foregroundStyle(.secondary); Text(duration(TimeInterval(vm.uptimeSeconds))) }
                }
                ImageRows(controller: controller)
            }
            .font(.caption.monospacedDigit())
        }
    }
}

/// The image details, for when the VM isn't running.
private struct ImageCard: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Card(title: "Image") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                ImageRows(controller: controller)
            }
            .font(.caption.monospacedDigit())
        }
    }
}

private struct ImageRows: View {
    @ObservedObject var controller: Controller
    @AppStorage(Prefs.cpus) private var cpus = 4
    @AppStorage(Prefs.memoryGiB) private var memoryGiB = 6

    var body: some View {
        GridRow { Text("Image").foregroundStyle(.secondary); Text(controller.imageInfo["IMAGE_ID"] ?? "?").textSelection(.enabled) }
        GridRow { Text("Substrate").foregroundStyle(.secondary); Text(controller.imageInfo["SUBSTRATE_REV"] ?? "?").textSelection(.enabled) }
        GridRow { Text("API port").foregroundStyle(.secondary); Text(controller.imageInfo["API_PORT"] ?? "?") }
        GridRow { Text("Settings").foregroundStyle(.secondary); Text("\(cpus) CPUs, \(memoryGiB) GiB memory") }
    }
}

private struct HistoryChart: View {
    let history: [Controller.Sample]

    var body: some View {
        Chart {
            ForEach(history) { s in
                LineMark(x: .value("Time", s.time), y: .value("Percent", s.cpuPercent))
                    .foregroundStyle(by: .value("Series", "CPU"))
                LineMark(x: .value("Time", s.time), y: .value("Percent", s.memoryFraction * 100))
                    .foregroundStyle(by: .value("Series", "Memory"))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel() } }
        .chartXAxis(.hidden)
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 70)
    }
}

private struct SummaryCard: View {
    @ObservedObject var controller: Controller
    let stats: GuestStats

    var body: some View {
        Card(title: "Cluster") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(GuestStats.Group.allCases, id: \.self) { group in
                    let cs = stats.components(in: group)
                    let healthy = cs.filter { $0.health == .healthy }.count
                    GridRow {
                        Text(group.rawValue).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            StatusDot(color: healthy == cs.count ? .green : cs.contains { $0.health == .failing } ? .red : .yellow)
                            Text("\(healthy)/\(cs.count) healthy")
                        }
                    }
                }
                GridRow {
                    Text("Worker pools").foregroundStyle(.secondary)
                    Text(stats.workerPools.map { "\($0.name) \($0.ready)/\($0.desired)" }.joined(separator: ", ")
                        .ifEmpty("none"))
                        .lineLimit(2)
                }
                GridRow {
                    Text("Actors").foregroundStyle(.secondary)
                    Text(actorSummary)
                }
                GridRow {
                    Text("Warnings").foregroundStyle(.secondary)
                    Text("\(stats.events.filter { Date().timeIntervalSince($0.lastSeen) < 3600 }.count) in the last hour")
                }
            }
            .font(.callout.monospacedDigit())
        }
    }

    private var actorSummary: String {
        guard let actors = controller.actors else { return "–" }
        if actors.isEmpty { return "none" }
        let counts = Dictionary(grouping: actors, by: \.state).mapValues(\.count)
        return counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key.lowercased())" }.joined(separator: ", ")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
