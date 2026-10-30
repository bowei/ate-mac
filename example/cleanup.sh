#!/usr/bin/env bash
# Removes everything run.sh created: the actor, the template, the atespace,
# and the namespace with its worker pool. Safe to run more than once.
set -o errexit -o nounset -o pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "${DIR}/env.sh"

NS="ate-hello"

ate() {
  kubectl-ate "$@" 2> >(grep -v '^Warning: no --token-file' >&2)
}

if ate get actor hello-1 -a "${NS}" >/dev/null 2>&1; then
  ate delete actor hello-1 -a "${NS}"
fi
if ate get actor-template hello -a "${NS}" >/dev/null 2>&1; then
  ate delete actor-template hello -a "${NS}"
fi
if ate get atespace "${NS}" >/dev/null 2>&1; then
  ate delete atespace "${NS}"
fi
kubectl delete namespace "${NS}" --ignore-not-found
# The image stays in the VM's registry; a Reset clears it.
