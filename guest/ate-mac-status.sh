#!/usr/bin/env bash
# Prints "ready" and exits 0 when the API server and every workload in
# ate-system are ready. Otherwise prints what is still starting and exits 1.
set -o nounset -o pipefail

node="kind-control-plane"

kc() {
  docker exec "${node}" kubectl --kubeconfig=/etc/kubernetes/admin.conf "$@"
}

if ! systemctl is-active --quiet ate-mac-boot; then
  echo "starting cluster"
  exit 1
fi
if ! kc get --raw /readyz >/dev/null 2>&1; then
  echo "starting Kubernetes"
  exit 1
fi

not_ready="$(
  {
    kc get deployments,statefulsets -n ate-system \
      -o jsonpath='{range .items[*]}{.metadata.name} {.spec.replicas} {.status.readyReplicas}{"\n"}{end}'
    kc get daemonsets -n ate-system \
      -o jsonpath='{range .items[*]}{.metadata.name} {.status.desiredNumberScheduled} {.status.numberReady}{"\n"}{end}'
  } | awk 'NF && $2 != ($3 == "" ? 0 : $3) { print $1 }' | paste -sd, -
)" || { echo "starting Kubernetes"; exit 1; }

if [[ -n "${not_ready}" ]]; then
  echo "waiting for ${not_ready}"
  exit 1
fi
echo "ready"
