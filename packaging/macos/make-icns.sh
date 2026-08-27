#!/usr/bin/env bash
# make-icns.sh SOURCE.png OUT.icns — build a macOS icon from a square master.
# iconutil is Apple's own packer, so the container it writes is correct by
# construction; the only contract to get right is the file names below, which
# it accepts and no others.
set -euo pipefail

src="$1"
out="$2"
work="$(mktemp -d)/qub.iconset"
mkdir -p "$work"

for spec in 16:icon_16x16      32:icon_16x16@2x \
            32:icon_32x32      64:icon_32x32@2x \
            128:icon_128x128   256:icon_128x128@2x \
            256:icon_256x256   512:icon_256x256@2x \
            512:icon_512x512   1024:icon_512x512@2x; do
    px="${spec%%:*}"
    name="${spec#*:}"
    sips -z "$px" "$px" "$src" --out "$work/$name.png" >/dev/null
done

iconutil -c icns "$work" -o "$out"
rm -rf "$(dirname "$work")"
