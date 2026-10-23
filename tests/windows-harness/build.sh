#!/usr/bin/env bash
# Build a Linux executable out of terminal.asm (the real Windows source) and
# the Win32 stubs in stubs.inc.
# usage: build.sh OUT [nasm flags, e.g. -DNOSPILL -DCHECKREGS]
# TERMINAL_ASM=file builds another version of terminal.asm; HARNESS_WORK=dir
# keeps the intermediate files.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
SRC="${TERMINAL_ASM:-$ROOT/terminal.asm}"
OUT="$1"; shift
WORK="${HARNESS_WORK:-$(mktemp -d)}"
# terminal.asm minus its extern lines, plus the stubs appended at the end.
grep -v '^extern ' "$SRC" > "$WORK/h.asm"
echo '%include "stubs.inc"' >> "$WORK/h.asm"
nasm -f elf64 -I"$ROOT/" -I"$HERE/" "$@" "$WORK/h.asm" -o "$WORK/h.o"
ld "$WORK/h.o" -o "$OUT"
