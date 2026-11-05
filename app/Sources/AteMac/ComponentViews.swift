import SwiftUI

/// A selectable table of components, worst health first.
struct ComponentTable: View {
    let stats: GuestStats
    let components: [GuestStats.Component]
    var showNamespace = false
    @Binding var selection: GuestStats.Component.ID?

    var body: some View {
        if components.isEmpty {
            ContentUnavailableView("No components", systemImage: "square.stack.3d.up.slash")
        } else {
            Table(components, selection: $selection) {
                TableColumn("Status") { c in
                    HStack(spacing: 6) {
                        StatusDot(color: c.health.color)
                        Text(c.health.rawValue).foregroundStyle(.secondary)
                    }
                    .help(c.detail.isEmpty ? c.health.rawValue : c.detail)
                }
                .width(min: 80, ideal: 90, max: 110)
                TableColumn("Name") { c in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(.body.monospaced())
                        if !c.detail.isEmpty {
                            Text(c.detail)
                                .font(.caption)
                                .foregroundStyle(c.health == .failing ? .red : .orange)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .help(c.detail)
                }
                .width(min: 160, ideal: 260)
                TableColumn("Namespace") { c in Text(c.namespace).foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 140)
                    .defaultVisibility(showNamespace ? .visible : .hidden)
                TableColumn("Kind") { c in Text(c.kind).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90, max: 110)
                TableColumn("Ready") { c in
                    Text("\(c.ready)/\(c.desired)").monospacedDigit()
                        .foregroundStyle(c.ready < c.desired ? .orange : .primary)
                }
                .width(min: 44, ideal: 50, max: 70)
                TableColumn("Restarts") { c in Text("\(stats.restarts(of: c))").monospacedDigit() }
                    .width(min: 50, ideal: 60, max: 70)
                TableColumn("CPU") { c in Text(millicores(stats.usage(of: c).cpuMillicores)).monospacedDigit() }
                    .width(min: 50, ideal: 60, max: 80)
                TableColumn("Memory") { c in Text(bytes(stats.usage(of: c).memoryBytes)).monospacedDigit() }
                    .width(min: 60, ideal: 80, max: 100)
                TableColumn("Age") { c in Text(age(c.created)).monospacedDigit() }
                    .width(min: 40, ideal: 50, max: 60)
            }
        }
    }
}

/// The inspector for one component: its pods and their containers, its
/// warning events, and a container's logs.
struct ComponentDetail: View {
    @ObservedObject var controller: Controller
    let stats: GuestStats
    let component: GuestStats.Component

    var body: some View {
        let pods = stats.pods(of: component)
        let events = stats.events(for: component)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summary
                section("Pods (\(pods.count))") {
                    if pods.isEmpty {
                        Text("No pods").foregroundStyle(.secondary)
                    }
                    ForEach(pods) { PodCard(pod: $0) }
                }
                section("Warning events (\(events.count))") {
                    if events.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(events) { EventRow(event: $0, showObject: true) }
                }
                section("Logs") {
                    LogsView(controller: controller, pods: pods)
                }
            }
            .padding(14)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(color: component.health.color, size: 10)
                Text(component.name).font(.title3.bold().monospaced()).textSelection(.enabled)
            }
            Text("\(component.kind) in \(component.namespace)").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow { label("Ready"); Text("\(component.ready) of \(component.desired)") }
                GridRow { label("Up to date"); Text("\(component.updated)") }
                GridRow { label("Restarts"); Text("\(stats.restarts(of: component))") }
                GridRow { label("Age"); Text(age(component.created)) }
            }
            .font(.callout.monospacedDigit())
            if !component.detail.isEmpty {
                Text(component.detail)
                    .font(.callout)
                    .foregroundStyle(component.health == .failing ? .red : .orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}

private struct PodCard: View {
    let pod: GuestStats.Pod

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    StatusDot(color: pod.health.color)
                    Text(pod.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Text(age(pod.created)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text(pod.health.rawValue + (pod.detail.isEmpty ? "" : ": \(pod.detail)"))
                    if pod.health == .healthy {
                        Text("CPU \(millicores(pod.cpuMillicores))")
                        Text("Mem \(bytes(pod.memoryBytes))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                ForEach(pod.containers) { ContainerRow(container: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ContainerRow: View {
    let container: GuestStats.Container

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StatusDot(color: color, size: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(container.name).font(.caption.monospaced().bold())
                    Text(stateText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if container.restarts > 0 {
                        Text("\(container.restarts) restart\(container.restarts == 1 ? "" : "s")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !container.message.isEmpty {
                    Text(container.message).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(4).textSelection(.enabled)
                }
                if let t = container.lastTermination {
                    Text("Last exit: \(t.reason.isEmpty ? "terminated" : t.reason) (code \(t.exitCode)), \(age(t.finishedAt)) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateText: String {
        var s = container.state
        if !container.reason.isEmpty { s += ": \(container.reason)" }
        if container.state == "running" && !container.ready { s += ", not ready" }
        return s
    }

    private var color: Color {
        if container.ready { return .green }
        if container.state == "terminated" && container.reason == "Completed" { return .gray }
        if container.state == "waiting" && !container.reason.isEmpty
            && !["ContainerCreating", "PodInitializing"].contains(container.reason) {
            return .red
        }
        return .yellow
    }
}

struct EventRow: View {
    let event: GuestStats.Event
    var showObject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event.reason).font(.caption.bold())
                if showObject {
                    Text(event.object).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("\(event.count > 1 ? "×\(event.count) · " : "")\(age(event.lastSeen)) ago")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(event.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// Shows the last lines one of the pods' containers logged.
private struct LogsView: View {
    @ObservedObject var controller: Controller
    let pods: [GuestStats.Pod]

    private struct Target: Hashable {
        let namespace, pod, container: String
        var label: String { "\(pod) / \(container)" }
    }

    @State private var target: Target?
    @State private var previous = false
    @State private var text = ""
    @State private var loading = false

    private var targets: [Target] {
        pods.flatMap { p in p.containers.map { Target(namespace: p.namespace, pod: p.name, container: $0.name) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Container", selection: $target) {
                    ForEach(targets, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .labelsHidden()
                Toggle("Previous", isOn: $previous)
                    .help("Logs from the container's previous run, before its last restart")
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(target == nil || loading)
                .help("Refresh")
            }
            .controlSize(.small)
            ScrollView([.vertical, .horizontal]) {
                Text(loading && text.isEmpty ? "Loading…" : text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(minHeight: 160, idealHeight: 280, maxHeight: 400)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
        .onAppear { pickDefault() }
        .onChange(of: targets) { pickDefault() }
        .task(id: LoadKey(target: target, previous: previous)) { await load() }
    }

    private struct LoadKey: Equatable {
        let target: Target?
        let previous: Bool
    }

    /// Keeps the current choice while it exists; otherwise the first
    /// container that isn't ready, or the first container.
    private func pickDefault() {
        if let target, targets.contains(target) { return }
        let unready = pods.flatMap { p in
            p.containers.filter { !$0.ready }.map { Target(namespace: p.namespace, pod: p.name, container: $0.name) }
        }
        target = unready.first ?? targets.first
    }

    private func load() async {
        guard let target else {
            text = ""
            return
        }
        loading = true
        text = await controller.logs(namespace: target.namespace, pod: target.pod,
                                     container: target.container, previous: previous)
        loading = false
    }
}
