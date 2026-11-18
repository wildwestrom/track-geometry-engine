#!/bin/sh
# Type-check the mod's Teal files and run the offline tests.
# The game resolves require("<modId>::/dir/file.script.tl"); tl turns the dots into slashes and
# looks for <include_dir>/<modId>::/dir/file/script/tl.tl, so .tlpath/ holds links of that shape.
set -eu
cd "$(dirname "$0")"
modId=$(sed -n 's/.*"modId": *"\([^"]*\)".*/\1/p' track_geometry/mod.json)
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) sep=__ ;; *) sep=:: ;; esac # see tlconfig.lua
rm -rf .tlpath
find track_geometry/content -name '*.script.tl' | while read -r f; do
	rel=${f#track_geometry/content/}
	link=".tlpath/$modId$sep/${rel%.script.tl}/script/tl.tl"
	mkdir -p "$(dirname "$link")"
	ln -s "$PWD/$f" "$link"
done
status=0
for f in $(find track_geometry/content -name '*.tl'); do
	out=$(tl check "$f" 2>&1) || { echo "$out"; status=1; }
done
for t in test/*_test.lua; do
	echo "== $t"
	lua "$t" || status=1
done
exit $status
