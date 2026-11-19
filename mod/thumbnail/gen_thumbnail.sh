#!/usr/bin/env bash
# Regenerate thumbnail.svg next to this script, from the Lean geometry. Run it from anywhere.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out="$here/thumbnail.svg"
out2="$root/mod/track_geometry/_metadata/0.png"
out3="$root/mod/track_geometry/_metadata/1.png"

# Write to a temp file and move it into place only on success, so a failed run
# leaves the previous thumbnail.svg alone instead of truncating it.
tmp=$(mktemp "$out.XXXXXX")
trap 'rm -f "$tmp"' EXIT

cd "$root"
lake env lean --run "$here/Thumbnail.lean" | python3 "$here/thumbnail.py" >"$tmp"
chmod 644 "$tmp" # mktemp makes it 600
mv "$tmp" "$out"
rsvg-convert "$out" -o "$out2"
cp "$out2" "$out3"
echo "wrote $out"
echo "wrote $out2"
echo "wrote $out3"
