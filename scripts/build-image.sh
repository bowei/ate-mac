#!/usr/bin/env bash
# Builds the guest disk image the app boots.
#
# Starts a Lima VM with rootful Docker, then runs the Substrate kind dev flow
# from SUBSTRATE_SRC against that Docker: hack/create-kind-cluster.sh and
# ate-setup deploy. ko builds the images on this Mac and pushes them to the
# registry inside the VM. Finally it stops the VM and exports its disk.
#
# The Mac needs no container CLI: scripts/shim/docker goes on PATH and runs
# docker in the VM, which is where the daemon has always been. The VM mounts
# SUBSTRATE_SRC at its host path so build contexts resolve there, and the mount
# is undone before the export.
#
# Outputs, in build/:
#   substrate.qcow2   the disk image
#   kubeconfig        admin kubeconfig for the cluster, context "ate-mac"
#   image.env         API_PORT, SUBSTRATE_REV, and IMAGE_ID, which the app uses
#                     to tell that the bundled image changed
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
# Set to 1 to keep kind's observability stack (otel collector, Prometheus,
# Jaeger). It costs about 600MB of memory.
WITH_OBSERVABILITY="${WITH_OBSERVABILITY:-0}"
# Set to 1 to keep the build VM around for debugging.
KEEP_VM="${KEEP_VM:-0}"
# Overrides the build VM's memory in lima/build.yaml, which is sized for a
# 16GiB Mac. Raise it on a Mac with more to spare.
BUILD_MEMORY="${BUILD_MEMORY:-}"

for tool in limactl kubectl go; do
  if ! command -v "${tool}" >/dev/null; then
    echo "error: ${tool} not found" >&2
    exit 1
  fi
done

mkdir -p "${BUILD}"
export LIMA_HOME="${BUILD}/lima"

echo "==> Creating build VM '${VM}'"
limactl delete --force "${VM}" >/dev/null 2>&1 || true
# SUBSTRATE_SRC is mounted at its host path, read-only, so a build context the
# shim passes through means the same thing on both sides. It is set here rather
# than in build.yaml to keep the exported disk's template free of mounts.
vm_set=".mounts = [{\"location\": \"${SUBSTRATE_SRC}\", \"mountPoint\": \"${SUBSTRATE_SRC}\", \"writable\": false}]"
if [[ -n "${BUILD_MEMORY}" ]]; then
  vm_set+=" | .memory = \"${BUILD_MEMORY}\""
fi
limactl start --name="${VM}" --tty=false --set "${vm_set}" "${ROOT}/lima/build.yaml"

# Everything below, and everything the Substrate flow shells out to, reaches
# the VM's daemon through scripts/shim/docker. DOCKER_HOST is deliberately not
# set: the shim's docker runs in the guest, where the forwarded host socket
# path does not exist. The VM still forwards it to
# "${LIMA_HOME}/${VM}/sock/docker.sock" for a Docker API client on the Mac.
export ATE_SHIM_VM="${VM}" ATE_SHIM_ROOT="${SUBSTRATE_SRC}"
export PATH="${ROOT}/scripts/shim:${PATH}"
export KUBECONFIG="${BUILD}/kubeconfig"
rm -f "${KUBECONFIG}"

echo "==> Creating kind cluster"
cd "${SUBSTRATE_SRC}"
KIND_REGISTRY_PORT="${REGISTRY_PORT}" hack/create-kind-cluster.sh

echo "==> Installing Substrate"
export ATE_INSTALL_KIND=true
export KO_DOCKER_REPO="localhost:${REGISTRY_PORT}"
export NO_DEV_ENV=true
# This image only ever boots on Apple Silicon, so build one architecture. The
# VM's buildkit offers only linux/arm64 anyway: nothing registers a QEMU binfmt
# handler in it, so an amd64 stage of the envoy-dataplane Dockerfile cannot run.
export KO_DEFAULTPLATFORMS=linux/arm64
# --ingress-allowed-spiffe-ids is gone from ate-setup; the router takes its
# allowed IDs from manifests/ate-install/atenet-router.yaml, and only
# --ingress-auth-mode=static-mtls requires any. The default mode,
# deprecated-insecure, is what this install has always ended up with.
go run ./cmd/ate-setup deploy ate-system --credential-provider='{"name":"k8s.io"}'

echo "==> Slimming the cluster"
# Prints the image IDs the matching pods run, such as
# docker.io/amazon/aws-cli@sha256:..., one per line.
pod_image_ids() {
  kubectl get pods "$@" \
    -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' | sort -u
}
# Removes images from the kind node by exact ID, skipping any a remaining pod
# still runs.
rmi_node() {
  local id in_use
  in_use="$(pod_image_ids -A)"
  for id in "$@"; do
    if grep -qxF "${id}" <<<"${in_use}"; then
      echo "keeping ${id}: still in use"
      continue
    fi
    docker exec kind-control-plane crictl rmi "${id}"
  done
}
if [[ "${WITH_OBSERVABILITY}" != "1" ]]; then
  # Turn telemetry export off, so nothing retries the missing collector. Logs
  # still go to the console. ate-controller passes the ATE_WORKER_ values to
  # worker pods, which is why this runs before the demo is deployed.
  kubectl -n ate-system patch configmap ate-otel-config --type merge -p '{"data": {
    "OTEL_EXPORTER_OTLP_ENDPOINT": "",
    "OTEL_TRACES_EXPORTER": "none",
    "OTEL_METRICS_EXPORTER": "none",
    "OTEL_LOGS_EXPORTER": "console",
    "ATE_WORKER_OTEL_TRACES_EXPORTER": "none",
    "ATE_WORKER_OTEL_METRICS_EXPORTER": "none",
    "ATE_WORKER_OTEL_LOGS_EXPORTER": "console"}}'
  read -ra otel_images <<<"$(pod_image_ids -n otel-system | tr '\n' ' ')"
  kubectl delete namespace otel-system
  rmi_node ${otel_images[@]+"${otel_images[@]}"}
fi
# The second replicas only matter for availability on a real cluster. Substrate
# no longer installs ate-idp-server, and currently ships every ate-system
# deployment at one replica already, so this is belt and braces.
kubectl -n ate-system scale deployment ate-api-server --replicas=1
# The bucket-init job ran once at install.
read -ra job_images <<<"$(pod_image_ids -n ate-system -l batch.kubernetes.io/job-name=rustfs-bucket-init | tr '\n' ' ')"
kubectl -n ate-system delete job rustfs-bucket-init --cascade=foreground
rmi_node ${job_images[@]+"${job_images[@]}"}
# Pods read ate-otel-config only when they start.
kubectl -n ate-system rollout restart deployment
kubectl -n ate-system rollout restart daemonset
for w in $(kubectl -n ate-system get deployment,daemonset -o name); do
  kubectl -n ate-system rollout status "${w}" --timeout=5m
done

if [[ "${WITH_DEMO}" == "1" ]]; then
  go run ./cmd/ate-setup deploy demo counter
fi
SUBSTRATE_REV="$(git -C "${SUBSTRATE_SRC}" describe --always --dirty)"

echo "==> Installing boot service"
for f in ate-ctr ate-mac-boot.sh ate-mac-boot.service wait-online-any.conf; do
  limactl copy "${ROOT}/guest/${f}" "${VM}:/tmp/${f}"
done
limactl shell --workdir / "${VM}" sudo bash -c '
  set -o errexit
  install -m 0755 /tmp/ate-ctr /usr/local/bin/ate-ctr
  install -m 0755 /tmp/ate-mac-boot.sh /usr/local/bin/ate-mac-boot
  install -m 0644 /tmp/ate-mac-boot.service /etc/systemd/system/ate-mac-boot.service
  install -D -m 0644 /tmp/wait-online-any.conf /etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf
  systemctl daemon-reload
  systemctl enable ate-mac-boot.service
'
docker update --restart=no kind-control-plane kind-registry >/dev/null

server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
API_PORT="${server##*:}"
kubectl config rename-context kind-kind ate-mac >/dev/null
printf 'API_PORT=%s\nSUBSTRATE_REV=%s\nIMAGE_ID=%s\n' "${API_PORT}" "${SUBSTRATE_REV}" \
  "$(date -u +%Y%m%dT%H%M%SZ)" > "${BUILD}/image.env"

echo "==> Removing build leftovers"
# The build cache and images from building envoy-dataplane, and the probe's
# busybox. Only the kind node and registry images are in use.
docker builder prune --all --force
docker image prune --all --force
# Pod logs from the install, and the space etcd freed but still holds.
docker exec kind-control-plane sh -c '
  find /var/log/pods -name "*.log" -exec truncate -s 0 {} +
  crictl exec "$(crictl ps -q --name "^etcd$")" etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key defrag
'
# The VM needs no hardware firmware, kernel headers, docs or other locales.
limactl shell --workdir / "${VM}" sudo bash -c '
  set -o errexit
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y "linux-headers-*"
  if dpkg -s linux-firmware >/dev/null 2>&1; then apt-get purge -y linux-firmware; fi
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  printf "%s\n" "path-exclude=/usr/share/doc/*" "path-exclude=/usr/share/man/*" \
    "path-exclude=/usr/share/locale/*" "path-include=/usr/share/locale/en*" \
    > /etc/dpkg/dpkg.cfg.d/01-ate-mac-slim
  rm -rf /usr/share/doc/* /usr/share/man/*
  find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en*" -exec rm -rf {} +
  journalctl --vacuum-size=1M
'

echo "==> Removing the Substrate mount"
# Puts the disk back to the "no host mounts" lima/build.yaml describes, since
# the app's VM does not have this one. The mount point goes too, so the image
# keeps no trace of where it was built. Nothing may reach the guest's docker
# after this: the build context is no longer there to read.
limactl shell --workdir / "${VM}" sudo bash -c '
  set -o errexit
  src="$1"
  if grep -qF "${src}" /etc/fstab; then
    # errexit stops here rather than installing an empty fstab if the filtered
    # file somehow comes out with no lines left.
    grep -vF "${src}" /etc/fstab > /tmp/fstab.new
    install -m 0644 /tmp/fstab.new /etc/fstab
    rm -f /tmp/fstab.new
  fi
  systemctl daemon-reload
  umount -l "${src}" 2>/dev/null || true
  rmdir -p "${src}" 2>/dev/null || true
' bash "${SUBSTRATE_SRC}"

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
