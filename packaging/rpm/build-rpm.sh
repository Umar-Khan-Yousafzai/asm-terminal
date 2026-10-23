#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build an .rpm for ASM Terminal from the prebuilt binary.
# Output: dist/asm-terminal-<version>-1.x86_64.rpm
# Requires: rpmbuild  (Fedora: dnf install rpm-build, Ubuntu: apt install rpm)
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VERSION="${APP_VERSION:-$(sed -n 's/.*ASM_VERSION "\(.*\)".*/\1/p' "$REPO/version.inc")}"
TOP="$HERE/_rpmbuild"

[ -x "$REPO/terminal" ] || { echo "build terminal first: (cd $REPO && make)" >&2; exit 1; }

rm -rf "$TOP"
mkdir -p "$TOP"/{SOURCES,SPECS,BUILD,RPMS,SRPMS} "$TOP/payload"
cp "$REPO/terminal" "$HERE/../linux/asm-terminal-launch" \
   "$HERE/../linux/asm-terminal.desktop" "$HERE/../linux/asm-terminal.svg" "$TOP/payload/"
cp -r "$HERE/../linux/icons" "$TOP/payload/"
cp "$REPO/LICENSE" "$TOP/payload/"
tar -C "$TOP/payload" -czf "$TOP/SOURCES/asm-terminal-$VERSION-payload.tar.gz" .

rpmbuild -bb "$HERE/asm-terminal.spec" \
    --define "_topdir $TOP" \
    --define "app_version $VERSION" \
    --target x86_64

mkdir -p "$REPO/dist"
find "$TOP/RPMS" -name '*.rpm' -exec cp -v {} "$REPO/dist/" \;
rm -rf "$TOP"
