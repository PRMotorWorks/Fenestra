#!/bin/bash
# Regenerates Fenestra/Resources/AppIcon.icns and docs/images/icon.png from make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
TMP="$(mktemp -d)"
swift Config/icon/make-icon.swift "$TMP" >/dev/null
SET="$TMP/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Fenestra/Resources/AppIcon.icns
mkdir -p docs/images
sips -z 256 256 "$TMP/icon-1024.png" --out docs/images/icon.png >/dev/null
rm -rf "$TMP"
echo "Wrote Fenestra/Resources/AppIcon.icns and docs/images/icon.png"
