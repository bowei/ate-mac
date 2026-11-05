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
        try GuestStats.decode(Data(sample.utf8))
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
            try GuestStats.decode(Data(bad.utf8))
        }
    }

    @Test func oldOutputDefaultsTheNewFields() throws {
        let s = try decode()
        #expect(s.components.isEmpty && s.events.isEmpty && s.workerPools.isEmpty)
        #expect(s.vm.uptimeSeconds == 0)
        #expect(s.pods[0].componentKind == "Pod")
        #expect(s.pods[0].component == "postgres-0")
        #expect(s.pods[0].containers.isEmpty)
    }
}

/// Trimmed output of the current ate-mac-stats.py, with atenet-router's
/// envoy sidecar failing its readiness probe.
private let detailed = """
    {"ready": false, "summary": "waiting for atenet-router-7b7ff88c-kj2c5",
     "vm": {"cpus": 4, "cpuPercent": 7.6, "memoryUsedBytes": 2170404864, "memoryTotalBytes": 6188003328,
            "uptimeSeconds": 13669, "diskUsedBytes": 8282828800, "diskTotalBytes": 40483942400},
     "pods": [
      {"namespace": "ate-system", "name": "atenet-router-7b7ff88c-kj2c5", "health": "starting",
       "detail": "", "restarts": 3, "cpuMillicores": 4, "memoryBytes": 50000000,
       "componentKind": "Deployment", "component": "atenet-router", "node": "kind-control-plane",
       "created": 1793741523,
       "containers": [
        {"name": "atenet-router", "ready": true, "restarts": 3, "state": "running", "reason": "",
         "message": "", "lastTermination": {"reason": "Error", "exitCode": 2, "finishedAt": 1793831823}},
        {"name": "envoy", "ready": false, "restarts": 0, "state": "running", "reason": "",
         "message": "", "lastTermination": null}]},
      {"namespace": "ate-system", "name": "ate-api-server-6798d4b897-fhhlv", "health": "healthy",
       "detail": "", "restarts": 1, "cpuMillicores": 12, "memoryBytes": 124780544,
       "componentKind": "Deployment", "component": "ate-api-server", "node": "kind-control-plane",
       "created": 1793741523, "containers": []},
      {"namespace": "ate-system", "name": "ate-api-server-6798d4b897-xxxxx", "health": "healthy",
       "detail": "", "restarts": 2, "cpuMillicores": 8, "memoryBytes": 100000000,
       "componentKind": "Deployment", "component": "ate-api-server", "node": "kind-control-plane",
       "created": 1793741523, "containers": []},
      {"namespace": "kube-system", "name": "etcd-kind-control-plane", "health": "healthy",
       "detail": "", "restarts": 1, "cpuMillicores": 15, "memoryBytes": 88080384,
       "componentKind": "Pod", "component": "etcd-kind-control-plane", "node": "kind-control-plane",
       "created": 1793741523, "containers": []}
     ],
     "components": [
      {"namespace": "ate-system", "kind": "Deployment", "name": "ate-api-server", "desired": 2, "ready": 2,
       "updated": 2, "created": 1793741523, "health": "healthy", "detail": ""},
      {"namespace": "ate-system", "kind": "Deployment", "name": "atenet-router", "desired": 1, "ready": 0,
       "updated": 1, "created": 1793741523, "health": "starting",
       "detail": "envoy not ready: Readiness probe failed: HTTP probe failed with statuscode: 503"},
      {"namespace": "kube-system", "kind": "Pod", "name": "etcd-kind-control-plane", "desired": 1,
       "ready": 1, "updated": 1, "created": 1793741523, "health": "healthy", "detail": ""}
     ],
     "events": [
      {"namespace": "ate-system", "kind": "Pod", "object": "atenet-router-7b7ff88c-kj2c5",
       "reason": "Unhealthy", "message": "Readiness probe failed: HTTP probe failed with statuscode: 503",
       "count": 2072, "lastSeen": 1793837876},
      {"namespace": "ate-hello", "kind": "Pod", "object": "hello-7778f6b77-blpjs", "reason": "Unhealthy",
       "message": "Readiness probe failed", "count": 1, "lastSeen": 1793837000}
     ],
     "workerPools": [
      {"namespace": "ate-hello", "name": "hello", "desired": 1, "ready": 1,
       "sandboxConfig": "gvisor-default", "resolved": true}
     ]}
    """

struct DetailedStatsTests {
    private func decode() throws -> GuestStats {
        try GuestStats.decode(Data(detailed.utf8))
    }

    @Test func decodesTheDetail() throws {
        let s = try decode()
        #expect(s.vm.uptimeSeconds == 13669)
        #expect(s.vm.diskTotalBytes == 40_483_942_400)
        #expect(s.components.count == 3)
        #expect(s.workerPools.first?.sandboxConfig == "gvisor-default")
        #expect(s.events.first?.lastSeen == Date(timeIntervalSince1970: 1_793_837_876))
        let envoy = s.pods[0].containers[1]
        #expect(envoy.name == "envoy" && !envoy.ready && envoy.lastTermination == nil)
        #expect(s.pods[0].containers[0].lastTermination?.exitCode == 2)
    }

    @Test func listsComponentsWorstFirst() throws {
        let s = try decode()
        #expect(s.components(in: .substrate).map(\.name) == ["atenet-router", "ate-api-server"])
        #expect(s.components(in: .kubernetes).map(\.name) == ["etcd-kind-control-plane"])
        #expect(s.components(in: .workers).isEmpty)
    }

    @Test func gathersAComponentsPodsEventsAndUsage() throws {
        let s = try decode()
        let api = try #require(s.components.first { $0.name == "ate-api-server" })
        #expect(s.pods(of: api).count == 2)
        #expect(s.restarts(of: api) == 3)
        #expect(s.usage(of: api).cpuMillicores == 20)
        #expect(s.events(for: api).isEmpty)

        let router = try #require(s.components.first { $0.name == "atenet-router" })
        #expect(s.events(for: router).map(\.reason) == ["Unhealthy"])
    }
}
