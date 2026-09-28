#!/bin/sh
# The source archive an OpenWrt package fetches: openuf-<version>.tar.gz.
#
#   sh tools/release-archive.sh 0.9.0
#
# Runs tools/dist.sh --verify first (tests, and the proof that the
# comment-stripped tree is bytecode-identical to the source), then packs that
# stripped tree under a single top-level directory openuf-<version>/, which is
# what the OpenWrt build system's default unpack expects for PKG_BUILD_DIR
# $(BUILD_DIR)/openuf-<version>. install.sh, setup.sh and update.sh ride along
# so the same archive serves a manual install -- which is why this is gzip, not
# xz: OpenWrt's busybox tar has no xz, and the feed rules accept gz. A .sha256
# is written for the package Makefile's PKG_HASH. The release workflow runs this on every
# tag; PKG_VERSION in package/openuf/Makefile is the same number.
set -e
VER=$1
case "$VER" in
	''|-*) echo "usage: sh tools/release-archive.sh <version>   (e.g. 0.9.0)" >&2; exit 2 ;;
esac
case "$VER" in
	*[!0-9.]*) echo "release-archive: version must be digits and dots, got '$VER'" >&2; exit 2 ;;
esac

sh tools/dist.sh --verify

NAME=openuf-$VER
OUT=build/release/$NAME
rm -rf build/release
mkdir -p "$OUT"
cp -r build/openuf "$OUT/openuf"
printf '%s\n' "$VER" > "$OUT/openuf/VERSION"
cp install.sh setup.sh update.sh LICENSE README.md USAGE.md "$OUT/"

rm -f "$NAME.tar.gz" "$NAME.tar.gz.sha256"
# --owner/--group are GNU tar; a BSD tar (macOS) has no such flags. The
# archive contents are the same either way; the workflow runs GNU tar.
if tar --version 2>/dev/null | grep -q GNU; then
	tar -C build/release --owner=0 --group=0 --sort=name --mtime="@$(date +%s)" \
		-czf "$NAME.tar.gz" "$NAME"
else
	tar -C build/release -czf "$NAME.tar.gz" "$NAME"
fi
if command -v sha256sum >/dev/null 2>&1; then
	sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
else
	shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
fi
echo ""
echo "$NAME.tar.gz  $(wc -c < "$NAME.tar.gz" | tr -d ' ') bytes"
cat "$NAME.tar.gz.sha256"
