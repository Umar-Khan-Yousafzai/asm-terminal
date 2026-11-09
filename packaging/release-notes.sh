#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# release-notes.sh VERSION [SHA256SUMS] [PREVIOUS_TAG]
#
# Print the GitHub release notes for VERSION (e.g. 2.2.0).
# The body comes from that version's section in CHANGELOG.md
# ("## [2.2.0] - YYYY-MM-DD" up to the next "## ["). Fails if the section
# is missing or empty, so a release can never ship without notes.
#
# Around it: install and update commands, supported platforms, the
# download list, checksums (when SHA256SUMS is given) and a link to the
# full diff since PREVIOUS_TAG.
# ---------------------------------------------------------------------------
set -euo pipefail

VERSION="${1:?usage: release-notes.sh VERSION [SHA256SUMS] [PREVIOUS_TAG]}"
VERSION="${VERSION#v}"
SUMS="${2:-}"
PREV="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CHANGELOG="$HERE/../CHANGELOG.md"
REPO_URL="https://github.com/Umar-Khan-Yousafzai/asm-terminal"

section="$(awk -v v="$VERSION" '
    index($0, "## [" v "]") == 1 { on = 1; next }
    on && /^## \[/               { exit }
    on                            { print }
' "$CHANGELOG")"

if [ -z "$(printf '%s' "$section" | tr -d '[:space:]')" ]; then
    echo "error: CHANGELOG.md has no entry for $VERSION." >&2
    echo "Add a '## [$VERSION] - YYYY-MM-DD' section describing the release." >&2
    exit 1
fi

cat <<EOF
# ASM Terminal $VERSION

A shell written entirely in x86-64 assembly. No libc, one static binary.

$section

## Install

**Linux, any distro (x86-64):**
\`\`\`bash
curl -fsSL $REPO_URL/releases/latest/download/install.sh | sh
\`\`\`
Installs \`asm-terminal\` (also \`asm\`), the app-menu entry and icons into \`~/.local\`, after checking SHA-256.
Remove with \`curl -fsSL $REPO_URL/releases/latest/download/install.sh | sh -s -- --uninstall\`.

**Packages:**
| System | File | Command |
|---|---|---|
| Fedora / RHEL / openSUSE | \`asm-terminal-$VERSION-1.x86_64.rpm\` | \`sudo dnf install ./asm-terminal-$VERSION-1.x86_64.rpm\` |
| Debian / Ubuntu / Mint | \`asm-terminal_${VERSION}_amd64.deb\` | \`sudo apt install ./asm-terminal_${VERSION}_amd64.deb\` |
| Any Linux | \`asm-terminal-$VERSION-x86_64.AppImage\` | \`chmod +x\` it, then run it |
| Windows 10/11 | \`asm-terminal-$VERSION-windows-x86_64-setup.exe\` | run the installer |
| macOS 11+ (Intel, Apple Silicon via Rosetta 2) | \`asm-terminal-macos-x86_64\` | \`chmod +x\` it; the first run may need \`xattr -d com.apple.quarantine\` because it is not notarized |

## Update

Already installed? Run \`update install\` inside ASM Terminal, or run the install command again.
Package installs update through their package manager.

## Supported platforms

- Linux x86-64: any distribution. Static binary with no libc. The update check and \`update install\` use \`curl\` and \`sha256sum\`.
- macOS 11 or later, x86-64 (Apple Silicon runs it through Rosetta 2). \`trace\` and \`sandbox\` need Linux and say so; \`update install\` checks with \`shasum -a 256\`.
- Windows 10/11 x64.
- Not yet: native ARM64, 32-bit.
EOF

if [ -n "$SUMS" ] && [ -f "$SUMS" ]; then
    printf '\n## Checksums (SHA-256)\n\n```\n'
    cat "$SUMS"
    printf '```\n'
    printf '\nThese catch a corrupted download. They are published with the files, so they do not prove who built them.\n'
fi

if [ -n "$PREV" ]; then
    printf '\n**Full changelog:** %s/compare/%s...v%s\n' "$REPO_URL" "$PREV" "$VERSION"
else
    printf '\n**Full changelog:** %s/blob/v%s/CHANGELOG.md\n' "$REPO_URL" "$VERSION"
fi
