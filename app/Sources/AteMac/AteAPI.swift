import Foundation

/// Reads Substrate objects (actors and actor templates) through the bundled
/// kubectl-ate, which reaches ate-api-server by port-forwarding through the
/// kube API server.
struct AteAPI {
    struct Actor: Identifiable, Equatable {
        let atespace: String
        let name: String
        let template: String
        /// RUNNING, SUSPENDED and so on, without the ACTOR_STATE_ prefix.
        let state: String
        let worker: String
        let created: Date?

        var id: String { "\(atespace)/\(name)" }
    }

    struct Template: Identifiable, Equatable {
        let atespace: String
        let name: String
        let images: [String]
        let goldenReady: Bool
        let error: String
        let created: Date?

        var id: String { "\(atespace)/\(name)" }
    }

    let paths: Paths

    func actors() async -> [Actor]? {
        guard let json = await get("actors"), let list = json["actors"] as? [[String: Any]] else { return nil }
        return list.map { a in
            let meta = a["metadata"] as? [String: Any] ?? [:]
            let status = a["status"] as? [String: Any] ?? [:]
            let template = a["actorTemplate"] as? [String: Any] ?? [:]
            let assignment = status["workerAssignment"] as? [String: Any] ?? [:]
            let state = status["state"] as? String ?? "UNKNOWN"
            return Actor(
                atespace: meta["atespace"] as? String ?? "",
                name: meta["name"] as? String ?? "",
                template: template["name"] as? String ?? "",
                state: state.replacingOccurrences(of: "ACTOR_STATE_", with: ""),
                worker: AteAPI.workerName(assignment),
                created: AteAPI.date(meta["createTime"]))
        }
        .sorted { ($0.atespace, $0.name) < ($1.atespace, $1.name) }
    }

    func templates() async -> [Template]? {
        guard let json = await get("actor-templates"),
              let list = json["actorTemplates"] as? [[String: Any]] else { return nil }
        return list.map { t in
            let meta = t["metadata"] as? [String: Any] ?? [:]
            let status = t["status"] as? [String: Any] ?? [:]
            let golden = status["goldenSnapshotStatus"] as? [String: Any] ?? [:]
            let containers = t["containers"] as? [[String: Any]] ?? []
            return Template(
                atespace: meta["atespace"] as? String ?? "",
                name: meta["name"] as? String ?? "",
                images: containers.compactMap { $0["image"] as? String },
                goldenReady: golden["goldenTag"] != nil,
                error: (golden["error"] as? String) ?? (status["error"] as? String) ?? "",
                created: AteAPI.date(meta["createTime"]))
        }
        .sorted { ($0.atespace, $0.name) < ($1.atespace, $1.name) }
    }

    /// Runs `kubectl-ate get <what> -A -o json`. stderr, which carries a
    /// warning about the shared identity on every call, is dropped.
    private func get(_ what: String) async -> [String: Any]? {
        let r = await Command.run(paths.kubectlAte, ["get", what, "-A", "-o", "json"],
                                  environment: ["KUBECONFIG": paths.kubeconfig.path],
                                  timeout: 10, discardStderr: true)
        guard r.status == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(r.output.utf8))) as? [String: Any]
    }

    /// The worker pod a running actor is assigned to, or "" when suspended.
    private static func workerName(_ assignment: [String: Any]) -> String {
        assignment["workerPod"] as? String ?? ""
    }

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
