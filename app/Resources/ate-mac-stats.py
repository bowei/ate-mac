"""Prints the guest's health and resource use as JSON for the app's status panel.

The app pipes this script to `sudo python3 -` in the guest on every poll.
Exits 0 when every pod in ate-system is healthy and 1 otherwise, so a status
other than 0 or 1 means the script never ran.

A pod is healthy when Kubernetes reports it Ready and the node runs a ready
sandbox for it. Right after the VM boots, pod status still shows the state from
before shutdown, so Ready alone isn't enough.
"""

import json
import subprocess
import time

NODE = "kind-control-plane"
SYSTEM_NAMESPACE = "ate-system"
FAILING_REASONS = {
    "CrashLoopBackOff",
    "CreateContainerConfigError",
    "CreateContainerError",
    "ErrImagePull",
    "ImagePullBackOff",
    "InvalidImageName",
    "RunContainerError",
}


def node_json(*args):
    out = subprocess.run(
        ["docker", "exec", NODE, *args], capture_output=True, check=True, timeout=10
    ).stdout
    return json.loads(out)


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
    return {
        "cpus": cpus,
        "cpuPercent": round(busy * 100, 1),
        "memoryUsedBytes": mem["MemTotal"] - mem["MemAvailable"],
        "memoryTotalBytes": mem["MemTotal"],
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


def main():
    result = {"ready": False, "summary": "", "vm": vm_stats(), "pods": []}
    try:
        pods = node_json(
            "kubectl", "--kubeconfig=/etc/kubernetes/admin.conf", "get", "pods", "-A", "-o", "json"
        )["items"]
        usage = usage_by_pod()
    except (subprocess.SubprocessError, json.JSONDecodeError):
        result["summary"] = "starting Kubernetes"
        print(json.dumps(result))
        return 1

    waiting = []
    for pod in pods:
        ns, name = pod["metadata"]["namespace"], pod["metadata"]["name"]
        live = (ns, name) in usage
        health, detail = pod_health(pod, live)
        cpu, mem = usage.get((ns, name), (0, 0))
        restarts = sum(
            c.get("restartCount", 0) for c in pod.get("status", {}).get("containerStatuses", [])
        )
        result["pods"].append(
            {
                "namespace": ns,
                "name": name,
                "health": health,
                "detail": detail,
                "restarts": restarts,
                "cpuMillicores": cpu,
                "memoryBytes": mem,
            }
        )
        if ns == SYSTEM_NAMESPACE and health in ("starting", "failing"):
            waiting.append(name)

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
