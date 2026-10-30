import Foundation

/// The JSON that ate-mac-stats.py prints.
struct GuestStats: Decodable, Equatable {
    struct VM: Decodable, Equatable {
        let cpus: Int
        let cpuPercent: Double
        let memoryUsedBytes: Int64
        let memoryTotalBytes: Int64
    }

    struct Pod: Decodable, Equatable, Identifiable {
        enum Health: String, Decodable {
            case healthy, starting, failing, completed, terminating
        }

        let namespace: String
        let name: String
        let health: Health
        let detail: String
        let restarts: Int
        let cpuMillicores: Int
        let memoryBytes: Int64

        var id: String { "\(namespace)/\(name)" }
    }

    let ready: Bool
    let summary: String
    let vm: VM
    let pods: [Pod]

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
}
