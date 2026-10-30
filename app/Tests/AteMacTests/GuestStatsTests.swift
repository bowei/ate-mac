import Foundation
import Testing

@testable import AteMac

/// Trimmed output of ate-mac-stats.py from a running VM.
private let sample = """
    {"ready": false, "summary": "waiting for atenet-router-58db49bf6b-hkgdt",
     "vm": {"cpus": 4, "cpuPercent": 6.5, "memoryUsedBytes": 2249715712, "memoryTotalBytes": 8297721856},
     "pods": [
      {"namespace": "ate-system", "name": "postgres-0", "health": "healthy", "detail": "",
       "restarts": 1, "cpuMillicores": 29, "memoryBytes": 102760448},
      {"namespace": "ate-system", "name": "atenet-router-58db49bf6b-hkgdt", "health": "starting",
       "detail": "NodeShutdown", "restarts": 0, "cpuMillicores": 0, "memoryBytes": 0},
      {"namespace": "ate-system", "name": "ate-api-server-567c8fff64-7c942", "health": "healthy",
       "detail": "", "restarts": 1, "cpuMillicores": 12, "memoryBytes": 124780544},
      {"namespace": "ate-system", "name": "rustfs-bucket-init-9fflr", "health": "completed",
       "detail": "", "restarts": 0, "cpuMillicores": 0, "memoryBytes": 0},
      {"namespace": "otel-system", "name": "jaeger-fb9948ddf-mspk7", "health": "healthy",
       "detail": "", "restarts": 1, "cpuMillicores": 0, "memoryBytes": 89128960},
      {"namespace": "ate-demo-counter", "name": "counter-65899f454c-f5bwq", "health": "failing",
       "detail": "CrashLoopBackOff", "restarts": 4, "cpuMillicores": 0, "memoryBytes": 0},
      {"namespace": "kube-system", "name": "etcd-kind-control-plane", "health": "healthy",
       "detail": "", "restarts": 1, "cpuMillicores": 15, "memoryBytes": 88080384}
     ]}
    """

struct GuestStatsTests {
    private func decode() throws -> GuestStats {
        try JSONDecoder().decode(GuestStats.self, from: Data(sample.utf8))
    }

    @Test func decodesScriptOutput() throws {
        let s = try decode()
        #expect(!s.ready)
        #expect(s.vm.cpus == 4)
        #expect(s.vm.memoryTotalBytes == 8_297_721_856)
        #expect(s.pods.count == 7)
        #expect(s.pods[5].health == .failing)
        #expect(s.pods[5].detail == "CrashLoopBackOff")
    }

    @Test(arguments: [
        ("ate-system", GuestStats.Group.substrate),
        ("podcertificate-controller-system", .substrate),
        ("otel-system", .substrate),
        ("kube-system", .kubernetes),
        ("local-path-storage", .kubernetes),
        ("ate-demo-counter", .workers),
        ("my-actors", .workers),
    ])
    func groupsNamespaces(namespace: String, want: GuestStats.Group) {
        #expect(GuestStats.group(of: namespace) == want)
    }

    @Test func listsUnhealthyFirstAndLeavesOutCompleted() throws {
        let s = try decode()
        #expect(s.pods(in: .substrate).map(\.name) == [
            "atenet-router-58db49bf6b-hkgdt",
            "ate-api-server-567c8fff64-7c942",
            "jaeger-fb9948ddf-mspk7",
            "postgres-0",
        ])
        #expect(s.pods(in: .workers).map(\.name) == ["counter-65899f454c-f5bwq"])
        #expect(s.pods(in: .kubernetes).map(\.name) == ["etcd-kind-control-plane"])
    }

    @Test func rejectsUnknownHealth() {
        let bad = sample.replacingOccurrences(of: "\"failing\"", with: "\"exploded\"")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GuestStats.self, from: Data(bad.utf8))
        }
    }
}
