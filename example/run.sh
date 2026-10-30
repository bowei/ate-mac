#!/usr/bin/env bash
# Builds the hello actor from hello/Dockerfile and runs it on the Substrate
# app's cluster:
#
#   1. builds the image inside the VM and pushes it to the VM's registry
#   2. creates the ate-hello namespace and its WorkerPool
#   3. creates the ate-hello atespace and the hello ActorTemplate
#   4. waits for the template's golden snapshot, then creates actor hello-1
#
# Safe to rerun after editing hello/: it replaces the template and the actor.
set -o errexit -o nounset -o pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "${DIR}/env.sh"

NS="ate-hello"
TEMPLATE="hello"
ACTOR="hello-1"

# kubectl-ate warns on every call that it uses the shared identity; that is
# expected here, so drop the warning.
ate() {
  kubectl-ate "$@" 2> >(grep -v '^Warning: no --token-file' >&2)
}

for tool in docker kubectl kubectl-ate; do
  if ! command -v "${tool}" >/dev/null; then
    echo "error: ${tool} not found" >&2
    exit 1
  fi
done
if [[ ! -S "${DOCKER_HOST#unix://}" ]]; then
  echo "error: no Docker socket at ${DOCKER_HOST#unix://}; start Substrate from the menu bar" >&2
  exit 1
fi

echo "==> Building the image"
# The registry container publishes its port 5000 on the VM's localhost.
port="$(docker port kind-registry 5000/tcp | head -n1)"
port="${port##*:}"
tag="localhost:${port}/hello:latest"
docker build -t "${tag}" "${DIR}/hello"
docker push "${tag}"
# Templates need a digest-pinned reference, such as
# localhost:5101/hello@sha256:...
image="$(docker inspect --format '{{index .RepoDigests 0}}' "${tag}")"
echo "image: ${image}"

echo "==> Creating the worker pool"
# Reuse the gVisor worker image the bundled cluster was built with.
worker_image="$(kubectl get workerpools -A -o jsonpath='{range .items[*]}{.spec.workerImage}{"\n"}{end}' \
  | grep '/ateworker-gvisor@' | head -n1 || true)"
if [[ -z "${worker_image}" ]]; then
  echo "error: no gVisor WorkerPool to copy the worker image from; the image was built with WITH_DEMO=0" >&2
  exit 1
fi
sed "s|@WORKER_IMAGE@|${worker_image}|" "${DIR}/workerpool.yaml" | kubectl apply -f -
if ! kubectl -n "${NS}" rollout status "deployment/${TEMPLATE}" --timeout=5m; then
  echo "error: the worker didn't start. If its pod is Pending, the VM is out of memory:" >&2
  echo "raise Memory in Settings, or run: kubectl delete namespace ate-demo-counter" >&2
  exit 1
fi

echo "==> Creating the actor template"
if ! ate get atespace "${NS}" >/dev/null 2>&1; then
  ate create atespace "${NS}"
fi
# Templates are immutable, so a rerun deletes the old actor and template.
if ate get actor "${ACTOR}" -a "${NS}" >/dev/null 2>&1; then
  ate delete actor "${ACTOR}" -a "${NS}"
fi
if ate get actor-template "${TEMPLATE}" -a "${NS}" >/dev/null 2>&1; then
  ate delete actor-template "${TEMPLATE}" -a "${NS}"
fi
sed "s|@IMAGE@|${image}|" "${DIR}/actor-template.yaml" | ate create actor-template -f -

echo "==> Waiting for the golden snapshot"
# Substrate boots the template once and snapshots it; actors start from that.
deadline=$((SECONDS + 300))
until ate get actor-template "${TEMPLATE}" -a "${NS}" -o json 2>/dev/null | grep -q goldenTag; do
  if ((SECONDS > deadline)); then
    echo "error: no golden snapshot after 5 minutes; see kubectl -n ${NS} logs deployment/${TEMPLATE}" >&2
    exit 1
  fi
  sleep 3
done

echo "==> Creating actor ${ACTOR}"
ate create actor "${ACTOR}" -a "${NS}" --template "${TEMPLATE}"

cat <<EOF

Done. To talk to it:

  source ${DIR}/env.sh
  kubectl ate proxy actor ${ACTOR} -a ${NS}     # serves localhost:8000
  curl localhost:8000                           # in another terminal

To clean up: ${DIR}/cleanup.sh
EOF
