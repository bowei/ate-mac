import SwiftUI

/// WorkerPools and the components that run actors (everything outside the
/// Substrate and Kubernetes namespaces).
struct WorkersView: View {
    let stats: GuestStats
    @Binding var selection: GuestStats.Component.ID?

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Worker pools").font(.headline).padding([.top, .horizontal], 12)
                if stats.workerPools.isEmpty {
                    Text("No worker pools").foregroundStyle(.secondary).padding(12)
                    Spacer()
                } else {
                    Table(stats.workerPools) {
                        TableColumn("Status") { p in
                            StatusDot(color: p.ready >= p.desired && p.resolved ? .green : .yellow)
                        }
                        .width(44)
                        TableColumn("Namespace") { p in Text(p.namespace) }
                        TableColumn("Pool") { p in Text(p.name).font(.body.monospaced()) }
                        TableColumn("Ready") { p in Text("\(p.ready)/\(p.desired)").monospacedDigit() }
                            .width(min: 50, ideal: 60, max: 80)
                        TableColumn("Sandbox config") { p in Text(p.sandboxConfig) }
                        TableColumn("Resolved") { p in
                            Image(systemName: p.resolved ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(p.resolved ? .green : .red)
                        }
                        .width(min: 60, ideal: 70, max: 80)
                    }
                }
            }
            .frame(minHeight: 120, idealHeight: 180)
            VStack(alignment: .leading, spacing: 4) {
                Text("Worker deployments").font(.headline).padding([.top, .horizontal], 12)
                ComponentTable(stats: stats, components: stats.components(in: .workers), showNamespace: true,
                               selection: $selection)
            }
            .frame(minHeight: 160)
        }
    }
}

/// Actor templates and actors, from ate-api-server.
struct ActorsView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        if let actors = controller.actors, let templates = controller.templates {
            VSplitView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Actor templates").font(.headline).padding([.top, .horizontal], 12)
                    Table(templates) {
                        TableColumn("Golden") { t in
                            HStack(spacing: 6) {
                                StatusDot(color: !t.error.isEmpty ? .red : t.goldenReady ? .green : .yellow)
                                Text(!t.error.isEmpty ? "error" : t.goldenReady ? "ready" : "pending")
                                    .foregroundStyle(.secondary)
                            }
                            .help(t.error)
                        }
                        .width(min: 70, ideal: 80, max: 100)
                        TableColumn("Atespace") { t in Text(t.atespace) }
                        TableColumn("Name") { t in Text(t.name).font(.body.monospaced()) }
                        TableColumn("Image") { t in
                            Text(t.images.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(t.images.joined(separator: "\n"))
                        }
                        .width(min: 120, ideal: 280)
                        TableColumn("Age") { t in Text(age(t.created)).monospacedDigit() }
                            .width(min: 40, ideal: 50, max: 60)
                    }
                }
                .frame(minHeight: 120, idealHeight: 180)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Actors").font(.headline).padding([.top, .horizontal], 12)
                    if actors.isEmpty {
                        ContentUnavailableView {
                            Label("No actors", systemImage: "theatermasks")
                        } description: {
                            Text("Create one with kubectl ate create actor. See example/ for building your own.")
                        }
                    } else {
                        Table(actors) {
                            TableColumn("State") { a in
                                HStack(spacing: 6) {
                                    StatusDot(color: color(a.state))
                                    Text(a.state.lowercased()).foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 90, ideal: 110, max: 140)
                            TableColumn("Atespace") { a in Text(a.atespace) }
                            TableColumn("Name") { a in Text(a.name).font(.body.monospaced()) }
                            TableColumn("Template") { a in Text(a.template) }
                            TableColumn("Worker") { a in
                                Text(a.worker.ifEmpty("–")).font(.caption.monospaced())
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            TableColumn("Age") { a in Text(age(a.created)).monospacedDigit() }
                                .width(min: 40, ideal: 50, max: 60)
                        }
                    }
                }
                .frame(minHeight: 160)
            }
        } else if controller.ready {
            ProgressView("Loading actors…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Substrate isn't ready", systemImage: "theatermasks")
            } description: {
                Text("Actors appear once every Substrate component is healthy.")
            }
        }
    }

    private func color(_ state: String) -> Color {
        switch state {
        case "RUNNING": return .green
        case "SUSPENDED": return .gray
        case "FAILED", "ERROR": return .red
        default: return .yellow
        }
    }
}

/// Recent warning events across the cluster.
struct EventsTable: View {
    let events: [GuestStats.Event]

    var body: some View {
        if events.isEmpty {
            ContentUnavailableView("No warning events", systemImage: "checkmark.circle")
        } else {
            Table(events) {
                TableColumn("Last seen") { e in Text("\(age(e.lastSeen)) ago").monospacedDigit() }
                    .width(min: 60, ideal: 70, max: 90)
                TableColumn("Namespace") { e in Text(e.namespace) }
                    .width(min: 80, ideal: 120)
                TableColumn("Object") { e in
                    Text(e.object).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .help("\(e.kind) \(e.object)")
                }
                .width(min: 100, ideal: 200)
                TableColumn("Reason") { e in Text(e.reason).bold() }
                    .width(min: 70, ideal: 100)
                TableColumn("Count") { e in Text("\(e.count)").monospacedDigit() }
                    .width(min: 40, ideal: 50, max: 60)
                TableColumn("Message") { e in
                    Text(e.message).lineLimit(2).help(e.message)
                }
                .width(min: 200, ideal: 400)
            }
        }
    }
}
