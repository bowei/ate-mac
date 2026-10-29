#!/usr/bin/env bash
# Packs build/Substrate.app into build/Substrate.dmg, with an Applications
# link to drag it onto.
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/build"
STAGE="${BUILD}/dmg"

if [[ ! -d "${BUILD}/Substrate.app" ]]; then
  echo "error: ${BUILD}/Substrate.app not found; run scripts/build-app.sh first" >&2
  exit 1
fi

rm -rf "${STAGE}" "${BUILD}/Substrate.dmg"
mkdir -p "${STAGE}"
cp -cR "${BUILD}/Substrate.app" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
# The qcow2 image is already compressed, so LZFSE is enough.
hdiutil create -volname Substrate -srcfolder "${STAGE}" -fs APFS -format ULFO "${BUILD}/Substrate.dmg"
rm -rf "${STAGE}"

echo "==> Done: ${BUILD}/Substrate.dmg"
