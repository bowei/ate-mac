"""Prints the guest's health and resource use as JSON for the app's status window.

The app pipes this script to `sudo python3 -` in the guest on every poll.
Exits 0 when every pod in ate-system is healthy and 1 otherwise, so a status
other than 0 or 1 means the script never ran.

A pod is healthy when Kubernetes reports it Ready and the node runs a ready
sandbox for it. Right after the VM boots, pod status still shows the state from
before shutdown, so Ready alone isn't enough.

Besides pods, it reports components (the Deployment, DaemonSet or StatefulSet
that owns each pod, or the pod itself when nothing does), each container's
state, recent warning events and WorkerPools. Timestamps are Unix seconds.
"""

import calendar
import json
import os
import subprocess
import time

NODE = "kind-control-plane"
SYSTEM_NAMESPACE = "ate-system"
KUBECTL = ["kubectl", "--kubeconfig=/etc/kubernetes/admin.conf"]
MAX_EVENTS = 50
FAILING_REASONS = {
    "CrashLoopBackOff",
    "CreateContainerConfigError",
    "CreateContainerError",
    "ErrImagePull",
    "ImagePullBackOff",
    "InvalidImageName",
    "RunContainerError",
}
COMPONENT_KINDS = ("Deployment", "DaemonSet", "StatefulSet")


def node_json(*args):
    out = subprocess.run(
        ["docker", "exec", NODE, *args], capture_output=True, check=True, timeout=10
    ).stdout
    return json.loads(out)


def timestamp(s):
    """Converts a Kubernetes timestamp, with or without fractional seconds, to Unix seconds."""
    if not s:
        return 0
    return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))


def cpu_times():
    with open("/proc/stat") as f:
        fields = [int(v) for v in f.readline().split()[1:]]
    idle = fields[3] + fields[4]
    return idle, sum(fields)


def vm_stats():
    idle0, total0 = cpu_times()
    time.sleep(0.5)
    idle1, total1 = cpu_times()
    busy = 1 - (idle1 - idle0) / max(total1 - total0, 1)
    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, value = line.split(":")
            mem[key] = int(value.split()[0]) * 1024
    with open("/proc/cpuinfo") as f:
        cpus = sum(1 for line in f if line.startswith("processor"))
    with open("/proc/uptime") as f:
        uptime = float(f.read().split()[0])
    disk = os.statvfs("/")
    return {
        "cpus": cpus,
        "cpuPercent": round(busy * 100, 1),
        "memoryUsedBytes": mem["MemTotal"] - mem["MemAvailable"],
        "memoryTotalBytes": mem["MemTotal"],
        "uptimeSeconds": int(uptime),
        "diskUsedBytes": (disk.f_blocks - disk.f_bfree) * disk.f_frsize,
        "diskTotalBytes": disk.f_blocks * disk.f_frsize,
    }


def usage_by_pod():
    usage = {}
    for s in node_json("crictl", "statsp", "-o", "json").get("stats", []):
        meta = s["attributes"]["metadata"]
        linux = s.get("linux", {})
        cpu = linux.get("cpu", {}).get("usageNanoCores", {}).get("value", 0)
        mem = linux.get("memory", {}).get("workingSetBytes", {}).get("value", 0)
        usage[(meta["namespace"], meta["name"])] = (int(cpu) // 1_000_000, int(mem))
    return usage


def pod_health(pod, live):
    status = pod.get("status", {})
    if status.get("phase") == "Succeeded":
        return "completed", ""
    if pod["metadata"].get("deletionTimestamp"):
        return "terminating", ""
    for c in status.get("containerStatuses", []) + status.get("initContainerStatuses", []):
        reason = c.get("state", {}).get("waiting", {}).get("reason", "")
        if reason in FAILING_REASONS:
            return "failing", reason
    ready = any(
        c["type"] == "Ready" and c["status"] == "True" for c in status.get("conditions", [])
    )
    if ready and live:
        return "healthy", ""
    return "starting", status.get("reason", "")


def component_of(pod, replicasets):
    """Returns (kind, name) of what runs the pod: a Deployment found through its
    ReplicaSet, a DaemonSet or StatefulSet, or ("Pod", name) for anything else,
    such as static pods and Jobs.

    replicasets maps (namespace, name) to the ReplicaSet's owning Deployment
    name, or None.
    """
    meta = pod["metadata"]
    for ref in meta.get("ownerReferences", []):
        if ref["kind"] == "ReplicaSet":
            deployment = replicasets.get((meta["namespace"], ref["name"]))
            if deployment:
                return "Deployment", deployment
        elif ref["kind"] in ("DaemonSet", "StatefulSet"):
            return ref["kind"], ref["name"]
    return "Pod", meta["name"]


def container_states(pod):
    """Each container's readiness, state and last termination, init containers first."""
    status = pod.get("status", {})
    out = []
    for c in status.get("initContainerStatuses", []) + status.get("containerStatuses", []):
        state_name, state = next(iter(c.get("state", {}).items()), ("unknown", {}))
        last = c.get("lastState", {}).get("terminated")
        out.append(
            {
                "name": c["name"],
                "ready": bool(c.get("ready")),
                "restarts": c.get("restartCount", 0),
                "state": state_name,
                "reason": state.get("reason", ""),
                "message": state.get("message", ""),
                "lastTermination": {
                    "reason": last.get("reason", ""),
                    "exitCode": last.get("exitCode", 0),
                    "finishedAt": timestamp(last.get("finishedAt")),
                }
                if last
                else None,
            }
        )
    return out


def warning_events(events, now):
    """The newest MAX_EVENTS warning events, newest first."""
    out = []
    for e in events:
        if e.get("type") != "Warning":
            continue
        obj = e.get("involvedObject", {})
        series = e.get("series") or {}
        last = (
            timestamp(series.get("lastObservedTime"))
            or timestamp(e.get("lastTimestamp"))
            or timestamp(e.get("eventTime"))
            or timestamp(e.get("firstTimestamp"))
            or now
        )
        out.append(
            {
                "namespace": obj.get("namespace") or e["metadata"].get("namespace", ""),
                "kind": obj.get("kind", ""),
                "object": obj.get("name", ""),
                "reason": e.get("reason", ""),
                "message": e.get("message", ""),
                "count": series.get("count") or e.get("count") or 1,
                "lastSeen": last,
            }
        )
    out.sort(key=lambda e: e["lastSeen"], reverse=True)
    return out[:MAX_EVENTS]


def problem(pod, events):
    """Describes why a pod isn't healthy, as specifically as the data allows."""
    for c in pod["containers"]:
        if c["ready"] or (c["state"] == "terminated" and c["reason"] == "Completed"):
            continue
        why = c["reason"] or ("not ready" if c["state"] == "running" else c["state"])
        # A running container that isn't ready is failing its readiness probe;
        # the kubelet's Unhealthy event says how.
        if c["state"] == "running":
            for e in events:
                if e["object"] == pod["name"] and e["reason"] == "Unhealthy":
                    why += ": " + e["message"]
                    break
        return f"{c['name']} {why}"
    return pod["detail"] or pod["health"]


def component_health(desired, ready, pods):
    """Healthy when every wanted replica is ready and every pod is healthy;
    failing when any pod is; starting otherwise."""
    live = [p for p in pods if p["health"] != "completed"]
    if any(p["health"] == "failing" for p in live):
        return "failing"
    if ready >= desired and all(p["health"] == "healthy" for p in live):
        return "healthy"
    return "starting"


def components(workloads, pods, events):
    """One entry per Deployment, DaemonSet and StatefulSet, plus one per pod
    that none of them owns. Pods are the already-built pod entries."""
    by_component = {}
    for p in pods:
        by_component.setdefault((p["namespace"], p["componentKind"], p["component"]), []).append(p)

    rows = []
    seen = set()
    for w in workloads:
        kind, meta = w["kind"], w["metadata"]
        spec, status = w.get("spec", {}), w.get("status", {})
        if kind == "DaemonSet":
            desired = status.get("desiredNumberScheduled", 0)
            ready = status.get("numberReady", 0)
            updated = status.get("updatedNumberScheduled", 0)
        else:
            desired = spec.get("replicas", 1)
            ready = status.get("readyReplicas", 0)
            updated = status.get("updatedReplicas", 0)
        key = (meta["namespace"], kind, meta["name"])
        seen.add(key)
        rows.append((key, desired, ready, updated, timestamp(meta.get("creationTimestamp"))))
    for key, members in by_component.items():
        if key not in seen and key[1] == "Pod":
            p = members[0]
            if p["health"] == "completed":
                continue
            rows.append((key, 1, 1 if p["health"] == "healthy" else 0, 1, p["created"]))

    result = []
    for (ns, kind, name), desired, ready, updated, created in rows:
        members = by_component.get((ns, kind, name), [])
        health = component_health(desired, ready, members)
        detail = ""
        if health != "healthy":
            sick = [p for p in members if p["health"] not in ("healthy", "completed")]
            if sick:
                detail = problem(sick[0], events)
            elif ready < desired:
                detail = f"{ready} of {desired} ready"
        result.append(
            {
                "namespace": ns,
                "kind": kind,
                "name": name,
                "desired": desired,
                "ready": ready,
                "updated": updated,
                "created": created,
                "health": health,
                "detail": detail,
            }
        )
    return result


def worker_pools(items):
    out = []
    for w in items:
        status = w.get("status", {})
        classes = status.get("sandboxClasses", [])
        config = next((c.get("configRef", {}).get("name", "") for c in classes), "")
        resolved = all(
            cond.get("status") == "True"
            for c in classes
            for cond in c.get("conditions", [])
            if cond.get("type") == "Resolved"
        )
        out.append(
            {
                "namespace": w["metadata"]["namespace"],
                "name": w["metadata"]["name"],
                "desired": w.get("spec", {}).get("replicas", 0),
                "ready": status.get("readyReplicas", 0),
                "sandboxConfig": config,
                "resolved": resolved and bool(classes),
            }
        )
    return out


def main():
    result = {
        "ready": False,
        "summary": "",
        "vm": vm_stats(),
        "pods": [],
        "components": [],
        "events": [],
        "workerPools": [],
    }
    try:
        pods = node_json(*KUBECTL, "get", "pods", "-A", "-o", "json")["items"]
        usage = usage_by_pod()
    except (subprocess.SubprocessError, json.JSONDecodeError):
        result["summary"] = "starting Kubernetes"
        print(json.dumps(result))
        return 1

    # Everything besides pods is extra detail: without it the window loses
    # components and events, but health and the summary still work.
    try:
        others = node_json(
            *KUBECTL, "get",
            "deployments,daemonsets,statefulsets,replicasets,workerpools.ate.dev,events",
            "-A", "-o", "json",
        )["items"]
    except (subprocess.SubprocessError, json.JSONDecodeError):
        others = []
    replicasets = {}
    for rs in (o for o in others if o["kind"] == "ReplicaSet"):
        owner = next(
            (r["name"] for r in rs["metadata"].get("ownerReferences", []) if r["kind"] == "Deployment"),
            None,
        )
        replicasets[(rs["metadata"]["namespace"], rs["metadata"]["name"])] = owner
    events = warning_events([o for o in others if o["kind"] == "Event"], int(time.time()))

    waiting = []
    for pod in pods:
        ns, name = pod["metadata"]["namespace"], pod["metadata"]["name"]
        live = (ns, name) in usage
        health, detail = pod_health(pod, live)
        cpu, mem = usage.get((ns, name), (0, 0))
        restarts = sum(
            c.get("restartCount", 0) for c in pod.get("status", {}).get("containerStatuses", [])
        )
        kind, component = component_of(pod, replicasets)
        result["pods"].append(
            {
                "namespace": ns,
                "name": name,
                "health": health,
                "detail": detail,
                "restarts": restarts,
                "cpuMillicores": cpu,
                "memoryBytes": mem,
                "componentKind": kind,
                "component": component,
                "node": pod.get("spec", {}).get("nodeName", ""),
                "created": timestamp(pod["metadata"].get("creationTimestamp")),
                "containers": container_states(pod),
            }
        )
        if ns == SYSTEM_NAMESPACE and health in ("starting", "failing"):
            waiting.append(name)

    result["components"] = components(
        [o for o in others if o["kind"] in COMPONENT_KINDS], result["pods"], events
    )
    result["events"] = events
    result["workerPools"] = worker_pools([o for o in others if o["kind"] == "WorkerPool"])

    system = [p for p in result["pods"] if p["namespace"] == SYSTEM_NAMESPACE]
    if not system:
        result["summary"] = "waiting for ate-system"
    elif waiting:
        result["summary"] = "waiting for " + ", ".join(sorted(waiting))
    else:
        result["ready"] = True
        result["summary"] = "ready"
    print(json.dumps(result))
    return 0 if result["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
