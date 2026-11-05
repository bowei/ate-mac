import SwiftUI

/// The status window: a sidebar of sections, the selected section, and an
/// inspector for the selected component.
struct StatusWindow: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case components = "Components"
        case workers = "Workers"
        case actors = "Actors"
        case kubernetes = "Kubernetes"
        case events = "Events"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.33percent"
            case .components: return "square.stack.3d.up"
            case .workers: return "cpu"
            case .actors: return "theatermasks"
            case .kubernetes: return "server.rack"
            case .events: return "exclamationmark.bubble"
            }
        }

        /// The component group a section lists, if it lists components.
        var group: GuestStats.Group? {
            switch self {
            case .components: return .substrate
            case .workers: return .workers
            case .kubernetes: return .kubernetes
            default: return nil
            }
        }
    }

    @ObservedObject var controller: Controller
    @State private var section: Section = .overview
    @State private var selection: GuestStats.Component.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .inspector(isPresented: inspectorShown) {
                inspector
                    .inspectorColumnWidth(min: 320, ideal: 420, max: 720)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: section) { selection = nil }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) {
            ForEach(Section.allCases) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .badge(badge(for: s))
                    .tag(s)
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func badge(for section: Section) -> Int {
        guard let stats = controller.stats else { return 0 }
        if let group = section.group {
            return stats.components(in: group).filter { $0.health != .healthy }.count
        }
        if section == .events {
            return stats.events.filter { Date().timeIntervalSince($0.lastSeen) < 3600 }.count
        }
        return 0
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Button { controller.copyShellSetup() } label: { Label("Copy Shell Setup", systemImage: "doc.on.clipboard") }
                .help("Copies the KUBECONFIG and PATH exports for kubectl and kubectl-ate")
            Button { controller.showLog() } label: { Label("Show Log", systemImage: "doc.text") }
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
            Button { controller.confirmReset() } label: { Label("Reset…", systemImage: "arrow.counterclockwise") }
                .disabled(controller.phase == .starting || controller.phase == .stopping)
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding([.horizontal, .bottom], 12)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(color: controller.statusColor, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.rawValue).font(.title3.bold())
                Text(controller.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(controller.statusText)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actions: some View {
        switch controller.phase {
        case .notCreated, .stopped, .failed:
            Button("Start") { controller.start() }.keyboardShortcut("r", modifiers: [.command, .shift])
        case .running:
            Button("Restart") { controller.restart() }
            Button("Stop") { controller.stop() }
        default:
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview:
            OverviewView(controller: controller) { component in
                section = .components
                // Set after the section change clears the selection.
                DispatchQueue.main.async { selection = component.id }
            }
        case .components, .kubernetes:
            if let stats = controller.stats {
                ComponentTable(stats: stats, components: stats.components(in: section.group!),
                               showNamespace: true, selection: $selection)
            } else {
                NotRunningView(controller: controller)
            }
        case .workers:
            if let stats = controller.stats {
                WorkersView(stats: stats, selection: $selection)
            } else {
                NotRunningView(controller: controller)
            }
        case .actors:
            ActorsView(controller: controller)
        case .events:
            if let stats = controller.stats {
                EventsTable(events: stats.events)
            } else {
                NotRunningView(controller: controller)
            }
        }
    }

    // MARK: Inspector

    private var selectedComponent: GuestStats.Component? {
        guard let selection else { return nil }
        return controller.stats?.components.first { $0.id == selection }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { selectedComponent != nil }, set: { if !$0 { selection = nil } })
    }

    @ViewBuilder
    private var inspector: some View {
        if let component = selectedComponent, let stats = controller.stats {
            ComponentDetail(controller: controller, stats: stats, component: component)
        } else {
            Text("Select a component").foregroundStyle(.secondary)
        }
    }
}
