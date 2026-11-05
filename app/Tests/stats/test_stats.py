"""Tests for the pod health rules in app/Resources/ate-mac-stats.py."""

import importlib.util
import pathlib
import unittest

_path = pathlib.Path(__file__).parents[2] / "Resources" / "ate-mac-stats.py"
_spec = importlib.util.spec_from_file_location("stats", _path)
stats = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stats)


def pod(phase="Running", ready=True, waiting="", deleting=False, reason=""):
    p = {
        "metadata": {"name": "p", "namespace": "ate-system"},
        "status": {
            "phase": phase,
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
            "containerStatuses": [{"state": {"waiting": {"reason": waiting}} if waiting else {}}],
        },
    }
    if reason:
        p["status"]["reason"] = reason
    if deleting:
        p["metadata"]["deletionTimestamp"] = "2026-10-30T00:00:00Z"
    return p


class PodHealthTest(unittest.TestCase):
    def test_rules(self):
        cases = [
            ("ready with a live sandbox", pod(), True, ("healthy", "")),
            # Right after boot, Ready still shows the state from before shutdown.
            ("ready without a live sandbox", pod(), False, ("starting", "")),
            ("not ready", pod(ready=False), True, ("starting", "")),
            ("crash looping", pod(ready=False, waiting="CrashLoopBackOff"), True,
             ("failing", "CrashLoopBackOff")),
            ("image pull failing", pod(ready=False, waiting="ImagePullBackOff"), False,
             ("failing", "ImagePullBackOff")),
            ("still creating", pod(ready=False, waiting="ContainerCreating"), False,
             ("starting", "")),
            ("completed job", pod(phase="Succeeded", ready=False), False, ("completed", "")),
            ("being deleted", pod(deleting=True), True, ("terminating", "")),
            ("pod reason passed through", pod(ready=False, reason="NodeShutdown"), False,
             ("starting", "NodeShutdown")),
        ]
        for name, p, live, want in cases:
            with self.subTest(name):
                self.assertEqual(stats.pod_health(p, live), want)


def owned(name, kind, owner, namespace="ate-system"):
    return {"metadata": {"name": name, "namespace": namespace,
                         "ownerReferences": [{"kind": kind, "name": owner}]}}


class ComponentOfTest(unittest.TestCase):
    def test_owners(self):
        rs = {("ate-system", "ate-api-server-6798d4b897"): "ate-api-server",
              ("ate-system", "orphan-rs"): None}
        cases = [
            ("deployment via replicaset",
             owned("ate-api-server-6798d4b897-fhhlv", "ReplicaSet", "ate-api-server-6798d4b897"),
             ("Deployment", "ate-api-server")),
            ("daemonset", owned("atelet-x7k2p", "DaemonSet", "atelet"), ("DaemonSet", "atelet")),
            ("statefulset", owned("postgres-0", "StatefulSet", "postgres"), ("StatefulSet", "postgres")),
            ("static pod", owned("etcd-kind-control-plane", "Node", "kind-control-plane"),
             ("Pod", "etcd-kind-control-plane")),
            ("replicaset without a deployment", owned("orphan-rs-abc", "ReplicaSet", "orphan-rs"),
             ("Pod", "orphan-rs-abc")),
            ("job", owned("init-abc", "Job", "init"), ("Pod", "init-abc")),
            ("no owner", {"metadata": {"name": "bare", "namespace": "ate-system"}}, ("Pod", "bare")),
        ]
        for name, p, want in cases:
            with self.subTest(name):
                self.assertEqual(stats.component_of(p, rs), want)


# The atenet-router pod from 2026-11-04: the router container is ready, but
# the envoy sidecar keeps failing its readiness probe.
ROUTER = {
    "metadata": {"name": "atenet-router-7b7ff88c-kj2c5", "namespace": "ate-system"},
    "status": {
        "phase": "Running",
        "conditions": [{"type": "Ready", "status": "False"}],
        "containerStatuses": [
            {"name": "atenet-router", "ready": True, "restartCount": 3,
             "state": {"running": {"startedAt": "2026-11-04T22:37:07Z"}},
             "lastState": {"terminated": {"reason": "Error", "exitCode": 2,
                                          "finishedAt": "2026-11-04T22:37:03Z"}}},
            {"name": "envoy", "ready": False, "restartCount": 0,
             "state": {"running": {"startedAt": "2026-11-04T22:05:29Z"}}},
        ],
    },
}
ROUTER_EVENT = {
    "type": "Warning", "reason": "Unhealthy", "count": 2072,
    "message": "Readiness probe failed: HTTP probe failed with statuscode: 503",
    "lastTimestamp": "2026-11-05T00:17:56Z",
    "involvedObject": {"kind": "Pod", "name": "atenet-router-7b7ff88c-kj2c5", "namespace": "ate-system"},
    "metadata": {"namespace": "ate-system"},
}


class ContainerStatesTest(unittest.TestCase):
    def test_router(self):
        got = stats.container_states(ROUTER)
        self.assertEqual([c["name"] for c in got], ["atenet-router", "envoy"])
        self.assertEqual(got[0]["lastTermination"],
                         {"reason": "Error", "exitCode": 2,
                          "finishedAt": stats.timestamp("2026-11-04T22:37:03Z")})
        self.assertEqual((got[1]["ready"], got[1]["state"], got[1]["lastTermination"]),
                         (False, "running", None))

    def test_init_containers_first(self):
        p = {"status": {
            "initContainerStatuses": [
                {"name": "init", "state": {"terminated": {"reason": "Completed", "exitCode": 0}}}],
            "containerStatuses": [{"name": "main", "ready": True, "state": {"running": {}}}]}}
        self.assertEqual([c["name"] for c in stats.container_states(p)], ["init", "main"])


class TimestampTest(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(stats.timestamp("1970-01-01T00:01:00Z"), 60)
        self.assertEqual(stats.timestamp("1970-01-01T00:01:00.123456Z"), 60)
        self.assertEqual(stats.timestamp(None), 0)


class WarningEventsTest(unittest.TestCase):
    def test_filters_and_sorts(self):
        normal = dict(ROUTER_EVENT, type="Normal")
        older = dict(ROUTER_EVENT, reason="BackOff", lastTimestamp="2026-11-04T00:00:00Z")
        series = dict(ROUTER_EVENT, reason="Series", lastTimestamp=None, count=None,
                      series={"count": 7, "lastObservedTime": "2026-11-05T01:00:00.123456Z"})
        got = stats.warning_events([older, normal, ROUTER_EVENT, series], now=0)
        self.assertEqual([e["reason"] for e in got], ["Series", "Unhealthy", "BackOff"])
        self.assertEqual(got[0]["count"], 7)
        self.assertEqual(got[1]["object"], "atenet-router-7b7ff88c-kj2c5")

    def test_limit(self):
        many = [dict(ROUTER_EVENT, reason=str(i)) for i in range(stats.MAX_EVENTS + 5)]
        self.assertEqual(len(stats.warning_events(many, now=0)), stats.MAX_EVENTS)


def built_pod(name, health, component="atenet-router", kind="Deployment", namespace="ate-system",
              containers=()):
    """A pod entry as main() builds it."""
    return {"namespace": namespace, "name": name, "health": health, "detail": "",
            "componentKind": kind, "component": component, "created": 0,
            "containers": list(containers)}


class ComponentsTest(unittest.TestCase):
    def test_health(self):
        healthy, starting, failing = (built_pod("a", "healthy"), built_pod("b", "starting"),
                                      built_pod("c", "failing"))
        self.assertEqual(stats.component_health(1, 1, [healthy]), "healthy")
        self.assertEqual(stats.component_health(2, 1, [healthy]), "starting")
        self.assertEqual(stats.component_health(1, 1, [healthy, starting]), "starting")
        self.assertEqual(stats.component_health(1, 0, [starting, failing]), "failing")
        self.assertEqual(stats.component_health(0, 0, [built_pod("d", "completed")]), "healthy")

    def test_router_detail_names_the_container_and_probe(self):
        events = stats.warning_events([ROUTER_EVENT], now=0)
        pod = built_pod(ROUTER["metadata"]["name"], "starting",
                        containers=stats.container_states(ROUTER))
        workload = {"kind": "Deployment",
                    "metadata": {"namespace": "ate-system", "name": "atenet-router",
                                 "creationTimestamp": "2026-11-03T21:32:03Z"},
                    "spec": {"replicas": 1}, "status": {"readyReplicas": 0, "updatedReplicas": 1}}
        [c] = stats.components([workload], [pod], events)
        self.assertEqual((c["health"], c["ready"], c["desired"]), ("starting", 0, 1))
        self.assertEqual(
            c["detail"],
            "envoy not ready: Readiness probe failed: HTTP probe failed with statuscode: 503")

    def test_unowned_pods_become_components(self):
        static = built_pod("etcd-kind-control-plane", "healthy", component="etcd-kind-control-plane",
                           kind="Pod", namespace="kube-system")
        done = built_pod("job-x", "completed", component="job-x", kind="Pod")
        got = stats.components([], [static, done], [])
        self.assertEqual([(c["kind"], c["name"], c["health"]) for c in got],
                         [("Pod", "etcd-kind-control-plane", "healthy")])

    def test_daemonset_counts(self):
        ds = {"kind": "DaemonSet", "metadata": {"namespace": "ate-system", "name": "atelet"},
              "status": {"desiredNumberScheduled": 1, "numberReady": 1, "updatedNumberScheduled": 1}}
        [c] = stats.components([ds], [built_pod("atelet-x", "healthy", component="atelet",
                                                kind="DaemonSet")], [])
        self.assertEqual((c["desired"], c["ready"], c["health"]), (1, 1, "healthy"))


class WorkerPoolsTest(unittest.TestCase):
    def test_pool(self):
        wp = {"metadata": {"namespace": "ate-hello", "name": "hello"}, "spec": {"replicas": 1},
              "status": {"readyReplicas": 1, "sandboxClasses": [{
                  "name": "gvisor", "configRef": {"name": "gvisor-default"},
                  "conditions": [{"type": "Resolved", "status": "True"}]}]}}
        self.assertEqual(stats.worker_pools([wp]), [{
            "namespace": "ate-hello", "name": "hello", "desired": 1, "ready": 1,
            "sandboxConfig": "gvisor-default", "resolved": True}])
        # A pool the controller hasn't resolved yet.
        self.assertFalse(stats.worker_pools([{"metadata": wp["metadata"]}])[0]["resolved"])


if __name__ == "__main__":
    unittest.main()
