#!/usr/bin/env bash
# Builds the guest disk image the app boots.
#
# Starts a Lima VM with rootful Docker, then runs the Substrate kind dev flow
# from SUBSTRATE_SRC against that Docker: hack/create-kind-cluster.sh and
# ate-setup deploy. ko builds the images on this Mac and pushes them to the
# registry inside the VM. Finally it stops the VM and exports its disk.
#
# Outputs, in build/:
#   substrate.qcow2   the disk image
#   kubeconfig        admin kubeconfig for the cluster, context "ate-mac"
#   image.env         API_PORT and SUBSTRATE_REV
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBSTRATE_SRC="$(cd "${SUBSTRATE_SRC:-${ROOT}/../s}" && pwd)"
BUILD="${ROOT}/build"
VM="ate-mac-build"
CONVERT_VM="ate-mac-convert"
# Not 5001, so the build doesn't collide with a dev registry on this Mac.
REGISTRY_PORT="${REGISTRY_PORT:-5101}"
# Set to 0 to leave out the counter demo.
WITH_DEMO="${WITH_DEMO:-1}"
# Set to 1 to keep the build VM around for debugging.
KEEP_VM="${KEEP_VM:-0}"

for tool in limactl docker kubectl go; do
  if ! command -v "${tool}" >/dev/null; then
    echo "error: ${tool} not found" >&2
    exit 1
  fi
done

mkdir -p "${BUILD}"
export LIMA_HOME="${BUILD}/lima"

echo "==> Creating build VM '${VM}'"
limactl delete --force "${VM}" >/dev/null 2>&1 || true
limactl start --name="${VM}" --tty=false "${ROOT}/lima/build.yaml"

export DOCKER_HOST="unix://${LIMA_HOME}/${VM}/sock/docker.sock"
export KUBECONFIG="${BUILD}/kubeconfig"
rm -f "${KUBECONFIG}"

echo "==> Creating kind cluster"
cd "${SUBSTRATE_SRC}"
KIND_REGISTRY_PORT="${REGISTRY_PORT}" hack/create-kind-cluster.sh

echo "==> Installing Substrate"
export ATE_INSTALL_KIND=true
export KO_DOCKER_REPO="localhost:${REGISTRY_PORT}"
export NO_DEV_ENV=true
go run ./cmd/ate-setup deploy ate-system --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
if [[ "${WITH_DEMO}" == "1" ]]; then
  go run ./cmd/ate-setup deploy demo counter
fi
SUBSTRATE_REV="$(git -C "${SUBSTRATE_SRC}" describe --always --dirty)"

echo "==> Installing boot service"
for f in ate-mac-boot.sh ate-mac-status.sh ate-mac-boot.service; do
  limactl copy "${ROOT}/guest/${f}" "${VM}:/tmp/${f}"
done
limactl shell --workdir / "${VM}" sudo bash -c '
  set -o errexit
  install -m 0755 /tmp/ate-mac-boot.sh /usr/local/bin/ate-mac-boot
  install -m 0755 /tmp/ate-mac-status.sh /usr/local/bin/ate-mac-status
  install -m 0644 /tmp/ate-mac-boot.service /etc/systemd/system/ate-mac-boot.service
  systemctl daemon-reload
  systemctl enable ate-mac-boot.service
'
docker update --restart=no kind-control-plane kind-registry >/dev/null

server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
API_PORT="${server##*:}"
kubectl config rename-context kind-kind ate-mac >/dev/null
printf 'API_PORT=%s\nSUBSTRATE_REV=%s\n' "${API_PORT}" "${SUBSTRATE_REV}" > "${BUILD}/image.env"

echo "==> Exporting disk"
limactl shell --workdir / "${VM}" sudo fstrim -av
limactl stop "${VM}"
rm -f "${BUILD}/substrate.qcow2"
# qemu-img runs in a throwaway VM that mounts build/ at the same path.
limactl delete --force "${CONVERT_VM}" >/dev/null 2>&1 || true
limactl start --name="${CONVERT_VM}" --tty=false \
  --set ".mounts = [{\"location\": \"${BUILD}\", \"writable\": true}]" \
  "${ROOT}/lima/convert.yaml"
limactl shell --workdir / "${CONVERT_VM}" \
  qemu-img convert -p -c -O qcow2 "${LIMA_HOME}/${VM}/disk" "${BUILD}/substrate.qcow2"
limactl delete --force "${CONVERT_VM}"

if [[ "${KEEP_VM}" != "1" ]]; then
  limactl delete "${VM}"
fi

echo "==> Done: ${BUILD}/substrate.qcow2 (Substrate ${SUBSTRATE_REV}, API port ${API_PORT})"
