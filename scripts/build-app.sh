#!/usr/bin/env bash
# Assembles build/Substrate.app from the Swift app, the Homebrew limactl,
# kubectl-ate built from SUBSTRATE_SRC, and the outputs of build-image.sh.
# The app is ad-hoc signed, which is enough to run it on this Mac.
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBSTRATE_SRC="$(cd "${SUBSTRATE_SRC:-${ROOT}/../s}" && pwd)"
BUILD="${ROOT}/build"
APP="${BUILD}/Substrate.app"

for f in substrate.qcow2 kubeconfig image.env; do
  if [[ ! -f "${BUILD}/${f}" ]]; then
    echo "error: ${BUILD}/${f} not found; run scripts/build-image.sh first" >&2
    exit 1
  fi
done
# shellcheck source=/dev/null
source "${BUILD}/image.env"

LIMACTL="$(realpath "$(command -v limactl)")"
LIMA_PREFIX="$(cd "$(dirname "${LIMACTL}")/.." && pwd)"

echo "==> Building the Swift app"
swift build -c release --package-path "${ROOT}/app"

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources/lima/bin" \
  "${APP}/Contents/Resources/lima/share/lima" "${APP}/Contents/Resources/bin"
RES="${APP}/Contents/Resources"

cp "$(swift build -c release --package-path "${ROOT}/app" --show-bin-path)/AteMac" "${APP}/Contents/MacOS/Substrate"
sed "s/@VERSION@/${SUBSTRATE_REV}/g" "${ROOT}/app/Resources/Info.plist" > "${APP}/Contents/Info.plist"

# limactl finds the guest agent in ../share/lima relative to itself.
cp "${LIMACTL}" "${RES}/lima/bin/limactl"
chmod u+w "${RES}/lima/bin/limactl"
cp "${LIMA_PREFIX}/share/lima/lima-guestagent.Linux-aarch64.gz" "${RES}/lima/share/lima/"

(cd "${SUBSTRATE_SRC}" && GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" \
  -o "${RES}/bin/kubectl-ate" ./cmd/kubectl-ate)

cp "${ROOT}/lima/runtime.yaml.tmpl" "${ROOT}/app/Resources/ate-mac-stats.py" \
  "${BUILD}/kubeconfig" "${BUILD}/image.env" "${RES}/"
# A clone, so the multi-GB image takes no extra space.
cp -c "${BUILD}/substrate.qcow2" "${RES}/"

ICONSET="${BUILD}/AppIcon.iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
swift "${ROOT}/scripts/make-icon.swift" "${ROOT}/ate-logo-with-border.png" "${BUILD}/icon.png"
for s in 16 32 128 256 512; do
  sips -z "${s}" "${s}" "${BUILD}/icon.png" --out "${ICONSET}/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "${BUILD}/icon.png" --out "${ICONSET}/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${RES}/AppIcon.icns"

echo "==> Signing"
codesign --force --sign - --entitlements "${ROOT}/app/Resources/limactl.entitlements" "${RES}/lima/bin/limactl"
codesign --force --sign - "${RES}/bin/kubectl-ate"
codesign --force --sign - "${APP}"

echo "==> Done: ${APP}"
