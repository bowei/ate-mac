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


if __name__ == "__main__":
    unittest.main()
