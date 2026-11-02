#!/bin/sh
# Copy the mod into TF3's staging area. Steam runs in a guix container that
# only sees ~/.local/share/guix-sandbox-home, so a symlink can't reach the repo.
set -eu
src="$(dirname "$0")/track_geometry/"
dst="$HOME/.local/share/guix-sandbox-home/.local/share/Steam/userdata/75515556/3493540/local/staging_area/track_geometry/"
mkdir -p "$dst"
rsync -a --delete "$src" "$dst"
echo "synced to $dst"
