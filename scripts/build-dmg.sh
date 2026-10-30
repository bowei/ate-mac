#!/usr/bin/env bash
# Packs build/Substrate.app into build/Substrate.dmg. The DMG window shows the
# app and an Applications link on a background with an arrow between them.
#
# Finder stores the window layout in the volume's .DS_Store, so this builds a
# writable DMG, has Finder lay out the window, then compresses it.
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/build"
STAGE="${BUILD}/dmg"
RW="${BUILD}/Substrate-rw.dmg"
# Finder only saves the layout for a volume mounted under /Volumes, and the
# script finds the volume by name.
MNT="/Volumes/Substrate"

if [[ ! -d "${BUILD}/Substrate.app" ]]; then
  echo "error: ${BUILD}/Substrate.app not found; run scripts/build-app.sh first" >&2
  exit 1
fi

if [[ -e "${MNT}" ]]; then
  echo "error: ${MNT} is already mounted; eject it first" >&2
  exit 1
fi

cleanup() {
  hdiutil detach -quiet "${MNT}" 2>/dev/null || true
  rm -rf "${STAGE}" "${RW}"
}
trap cleanup EXIT
rm -rf "${STAGE}" "${RW}" "${BUILD}/Substrate.dmg"

mkdir -p "${STAGE}/.background"
cp -cR "${BUILD}/Substrate.app" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
swift "${ROOT}/scripts/make-dmg-background.swift" "${BUILD}/background.png" 1
swift "${ROOT}/scripts/make-dmg-background.swift" "${BUILD}/background@2x.png" 2
tiffutil -cathidpicheck "${BUILD}/background.png" "${BUILD}/background@2x.png" \
  -out "${STAGE}/.background/background.tiff"
rm -f "${BUILD}/background.png" "${BUILD}/background@2x.png"

hdiutil create -volname Substrate -srcfolder "${STAGE}" -fs APFS -format UDRW "${RW}"
hdiutil attach -readwrite -noverify -noautoopen "${RW}"

# The window is 640x400 points, matching the background. The icon positions
# match make-dmg-background.swift.
osascript <<EOF
tell application "Finder"
  repeat 30 times
    if exists disk "Substrate" then exit repeat
    delay 1
  end repeat
  set d to disk "Substrate"
  open d
  set w to container window of d
  set current view of w to icon view
  set toolbar visible of w to false
  set statusbar visible of w to false
  set bounds of w to {200, 120, 840, 520}
  set o to icon view options of w
  set arrangement of o to not arranged
  set icon size of o to 128
  set text size of o to 13
  set background picture of o to file ".background:background.tiff" of d
  set position of item "Substrate.app" of d to {160, 180}
  set position of item "Applications" of d to {480, 180}
  update d without registering applications
end tell
EOF

# Finder saves the layout to .DS_Store while the window is open, and resets the
# view options when the window closes. So wait for the background to be saved,
# then eject with the window still open.
layout_saved() {
  python3 - "${MNT}/.DS_Store" <<'PY'
import plistlib, sys
try:
    d = open(sys.argv[1], "rb").read()
except FileNotFoundError:
    sys.exit(1)
i = d.find(b"icvpblob")
if i < 0:
    sys.exit(1)
n = int.from_bytes(d[i + 8:i + 12], "big")
sys.exit(0 if plistlib.loads(d[i + 12:i + 12 + n]).get("backgroundType") == 2 else 1)
PY
}
for _ in $(seq 1 30); do
  layout_saved && break
  sleep 1
done
layout_saved || { echo "error: Finder did not save the window layout" >&2; exit 1; }
hdiutil detach "${MNT}"

# The qcow2 image is already compressed, so LZFSE is enough.
hdiutil convert "${RW}" -format ULFO -o "${BUILD}/Substrate.dmg"

echo "==> Done: ${BUILD}/Substrate.dmg"
