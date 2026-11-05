import Foundation

/// The JSON that ate-mac-stats.py prints. Fields added after the first version
/// default when missing, so output from an older script still decodes.
struct GuestStats: Decodable, Equatable {
    struct VM: Decodable, Equatable {
        let cpus: Int
        let cpuPercent: Double
        let memoryUsedBytes: Int64
        let memoryTotalBytes: Int64
        let uptimeSeconds: Int
        let diskUsedBytes: Int64
        let diskTotalBytes: Int64

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cpus = try c.decode(Int.self, forKey: .cpus)
            cpuPercent = try c.decode(Double.self, forKey: .cpuPercent)
            memoryUsedBytes = try c.decode(Int64.self, forKey: .memoryUsedBytes)
            memoryTotalBytes = try c.decode(Int64.self, forKey: .memoryTotalBytes)
            uptimeSeconds = try c.decode(Int.self, forKey: .uptimeSeconds, default: 0)
            diskUsedBytes = try c.decode(Int64.self, forKey: .diskUsedBytes, default: 0)
            diskTotalBytes = try c.decode(Int64.self, forKey: .diskTotalBytes, default: 0)
        }

        private enum CodingKeys: String, CodingKey {
            case cpus, cpuPercent, memoryUsedBytes, memoryTotalBytes, uptimeSeconds, diskUsedBytes,
                 diskTotalBytes
        }
    }

    enum Health: String, Decodable, Comparable {
        case healthy, starting, failing, completed, terminating

        /// Worst first, for sorting.
        private var rank: Int {
            switch self {
            case .failing: return 0
            case .starting: return 1
            case .terminating: return 2
            case .healthy: return 3
            case .completed: return 4
            }
        }

        static func < (a: Health, b: Health) -> Bool { a.rank < b.rank }
    }

    struct Container: Decodable, Equatable, Identifiable {
        struct Termination: Decodable, Equatable {
            let reason: String
            let exitCode: Int
            let finishedAt: Date
        }

        let name: String
        let ready: Bool
        let restarts: Int
        /// running, waiting or terminated.
        let state: String
        let reason: String
        let message: String
        let lastTermination: Termination?

        var id: String { name }
    }

    struct Pod: Decodable, Equatable, Identifiable {
        typealias Health = GuestStats.Health

        let namespace: String
        let name: String
        let health: Health
        let detail: String
        let restarts: Int
        let cpuMillicores: Int
        let memoryBytes: Int64
        let componentKind: String
        let component: String
        let node: String
        let created: Date?
        let containers: [Container]

        var id: String { "\(namespace)/\(name)" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            namespace = try c.decode(String.self, forKey: .namespace)
            name = try c.decode(String.self, forKey: .name)
            health = try c.decode(Health.self, forKey: .health)
            detail = try c.decode(String.self, forKey: .detail)
            restarts = try c.decode(Int.self, forKey: .restarts)
            cpuMillicores = try c.decode(Int.self, forKey: .cpuMillicores)
            memoryBytes = try c.decode(Int64.self, forKey: .memoryBytes)
            componentKind = try c.decode(String.self, forKey: .componentKind, default: "Pod")
            component = try c.decode(String.self, forKey: .component, default: name)
            node = try c.decode(String.self, forKey: .node, default: "")
            created = try c.decodeIfPresent(Date.self, forKey: .created)
            containers = try c.decode([Container].self, forKey: .containers, default: [])
        }

        private enum CodingKeys: String, CodingKey {
            case namespace, name, health, detail, restarts, cpuMillicores, memoryBytes, componentKind,
                 component, node, created, containers
        }
    }

    /// A Deployment, DaemonSet or StatefulSet, or a pod nothing owns.
    struct Component: Decodable, Equatable, Identifiable, Hashable {
        let namespace: String
        let kind: String
        let name: String
        let desired: Int
        let ready: Int
        let updated: Int
        let created: Date
        let health: Health
        /// Why it isn't healthy, such as "envoy not ready: Readiness probe failed: …".
        let detail: String

        var id: String { "\(namespace)/\(kind)/\(name)" }
    }

    struct Event: Decodable, Equatable, Identifiable {
        let namespace: String
        let kind: String
        let object: String
        let reason: String
        let message: String
        let count: Int
        let lastSeen: Date

        var id: String { "\(namespace)/\(kind)/\(object)/\(reason)/\(message)" }
    }

    struct WorkerPool: Decodable, Equatable, Identifiable {
        let namespace: String
        let name: String
        let desired: Int
        let ready: Int
        let sandboxConfig: String
        let resolved: Bool

        var id: String { "\(namespace)/\(name)" }
    }

    let ready: Bool
    let summary: String
    let vm: VM
    let pods: [Pod]
    let components: [Component]
    let events: [Event]
    let workerPools: [WorkerPool]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ready = try c.decode(Bool.self, forKey: .ready)
        summary = try c.decode(String.self, forKey: .summary)
        vm = try c.decode(VM.self, forKey: .vm)
        pods = try c.decode([Pod].self, forKey: .pods)
        components = try c.decode([Component].self, forKey: .components, default: [])
        events = try c.decode([Event].self, forKey: .events, default: [])
        workerPools = try c.decode([WorkerPool].self, forKey: .workerPools, default: [])
    }

    private enum CodingKeys: String, CodingKey {
        case ready, summary, vm, pods, components, events, workerPools
    }

    /// Decodes the script's output. Timestamps are Unix seconds.
    static func decode(_ data: Data) throws -> GuestStats {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(GuestStats.self, from: data)
    }

    enum Group: String, CaseIterable {
        case substrate = "Substrate"
        case workers = "Workers"
        case kubernetes = "Kubernetes"
    }

    static func group(of namespace: String) -> Group {
        switch namespace {
        case "ate-system", "podcertificate-controller-system", "otel-system":
            return .substrate
        case "kube-system", "local-path-storage":
            return .kubernetes
        default:
            return .workers
        }
    }

    /// Pods in the group, unhealthy first, then by name. Completed pods are left out.
    func pods(in group: Group) -> [Pod] {
        pods.filter { GuestStats.group(of: $0.namespace) == group && $0.health != .completed }
            .sorted { ($0.health == .healthy ? 1 : 0, $0.name) < ($1.health == .healthy ? 1 : 0, $1.name) }
    }

    /// Components in the group, worst health first, then by namespace and name.
    func components(in group: Group) -> [Component] {
        components.filter { GuestStats.group(of: $0.namespace) == group }
            .sorted { ($0.health, $0.namespace, $0.name) < ($1.health, $1.namespace, $1.name) }
    }

    /// The component's pods, completed ones left out.
    func pods(of component: Component) -> [Pod] {
        pods.filter {
            $0.namespace == component.namespace && $0.componentKind == component.kind
                && $0.component == component.name && $0.health != .completed
        }
        .sorted { ($0.health, $0.name) < ($1.health, $1.name) }
    }

    /// Warning events about the component or any of its pods, newest first.
    func events(for component: Component) -> [Event] {
        let pods = Set(pods(of: component).map(\.name))
        return events.filter {
            $0.namespace == component.namespace
                && ($0.object == component.name || pods.contains($0.object))
        }
    }

    /// Restarts across the component's pods.
    func restarts(of component: Component) -> Int {
        pods(of: component).reduce(0) { $0 + $1.restarts }
    }

    /// CPU and memory across the component's pods.
    func usage(of component: Component) -> (cpuMillicores: Int, memoryBytes: Int64) {
        pods(of: component).reduce((0, 0)) { ($0.0 + $1.cpuMillicores, $0.1 + $1.memoryBytes) }
    }
}

extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key, default value: T) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? value
    }
}
