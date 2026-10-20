# RELEASE area: updater (fake curl, no network), installers, packaging files.
# Sourced by tests/run_tests.sh, so pass/fail/failures and strip_ansi are shared.

rel_ok() {   # rel_ok NAME 'shell expression that must succeed'
    local name="$1" expr="$2"
    if eval "$expr"; then
        pass=$((pass + 1)); printf "  [pass] %s\n" "$name"
    else
        fail=$((fail + 1)); failures+=("$name"); printf "  [FAIL] %s\n" "$name"
        [[ -n "${rel_out:-}" ]] && printf "    got: %s\n" "$(tail -c 300 <<<"$rel_out")"
    fi
}

# rel_upd_setup DIR: DIR/bin/curl is a fake curl serving DIR/srv, logging its
# argv to DIR/log; DIR/inst/asm is a copy of the binary under test.
rel_upd_setup() {
    local d="$1"
    mkdir -p "$d/bin" "$d/srv" "$d/inst" "$d/home"
    cp "$BIN" "$d/srv/asm-terminal-linux-x86_64"; printf X >> "$d/srv/asm-terminal-linux-x86_64"
    (cd "$d/srv" && sha256sum asm-terminal-linux-x86_64 > SHA256SUMS)
    echo '{"tag_name": "v99.0.0"}' > "$d/srv/latest"
    cat > "$d/bin/curl" <<CURL
#!/bin/bash
PATH=/usr/bin:/bin
out=""; url=""
echo "curl \$*" >> "$d/log"
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift;;
        --max-time|-H|--proto|--proto-redir|--max-filesize) shift;;
        -*) ;;
        *) url="\$1";;
    esac
    shift
done
f="$d/srv/\$(basename "\$url")"
[ -f "\$f" ] || exit 22
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
CURL
    chmod +x "$d/bin/curl"
    cp "$BIN" "$d/inst/asm"
}

# rel_upd_run DIR 'line1\nline2': run the copy in DIR/inst with the fake curl
rel_upd_run() {
    local d="$1" input="$2"
    printf "$input"'exit\n' | env PATH="$d/bin:$PATH" HOME="$d/home" ASM_NO_UPDATE_CHECK=1 \
        timeout 20 "$d/inst/asm" 2>&1 | strip_ansi
}

# --- update: hardened curl, session state, failure paths ----
RU=$(mktemp -d)
rel_upd_setup "$RU"
rel_out=$(rel_upd_run "$RU" 'update\nupdate install\nupdate install\nupdate\n')
rel_ok "update: first install succeeds"        '[[ "$rel_out" == *"Updated to v99.0.0"* ]]'
rel_ok "update: binary replaced"               'cmp -s "$RU/inst/asm" "$RU/srv/asm-terminal-linux-x86_64"'
rel_ok "update: 2nd install says already done" '[[ "$rel_out" == *"Already updated to v99.0.0"* ]]'
rel_ok "update: no stray (deleted) file"       '[[ "$(ls "$RU/inst")" == "asm" ]]'
rel_ok "update: no .new leftovers"             '! compgen -G "$RU/inst/asm.new*" >/dev/null'
rel_ok "update: no re-offer after install"     '[[ "$(grep -c "Update available" <<<"$rel_out")" == 1 ]]'
rel_ok "update: curl ignores .curlrc, https only" \
    'grep -q "^curl -q --proto =https --proto-redir =https -fsSL " "$RU/log" && ! grep -qv "^curl -q --proto =https --proto-redir =https " "$RU/log"'
rel_ok "update: curl calls cap the size"       '! grep -qv -e "--max-filesize" "$RU/log"'
rel_ok "update: url is the last argument"      '! grep -qv -e " https://[^ ]*$" "$RU/log"'
rm -rf "$RU"

# wrong checksum, missing SHA256SUMS, odd SHA256SUMS layouts
RU=$(mktemp -d); rel_upd_setup "$RU"
GOOD=$(cut -d' ' -f1 "$RU/srv/SHA256SUMS")
printf '%064d  asm-terminal-linux-x86_64\n' 0 > "$RU/srv/SHA256SUMS"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: wrong checksum refused"        '[[ "$rel_out" == *"Checksum mismatch"* ]] && cmp -s "$RU/inst/asm" "$BIN"'
rel_ok "update: refused download deleted"      '[[ "$(ls "$RU/inst")" == "asm" ]]'
rm -f "$RU/srv/SHA256SUMS"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: missing SHA256SUMS refused"    '[[ "$rel_out" == *"Could not get checksums"* ]] && cmp -s "$RU/inst/asm" "$BIN"'
printf '%s  asm-terminal-linux-x86_64.sig\n' "$GOOD" > "$RU/srv/SHA256SUMS"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: longer name is not our asset"  '[[ "$rel_out" == *"Could not get checksums"* ]] && cmp -s "$RU/inst/asm" "$BIN"'
printf '%s  asm-terminal-linux-x86_64\r\n' "$GOOD" > "$RU/srv/SHA256SUMS"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: CRLF SHA256SUMS accepted"      '[[ "$rel_out" == *"Updated to v99.0.0"* ]]'
cp "$BIN" "$RU/inst/asm"; rm -f "$RU/home/.asm_update"
printf '%s *asm-terminal-linux-x86_64' "$GOOD" > "$RU/srv/SHA256SUMS"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: '*name', no final LF accepted" '[[ "$rel_out" == *"Updated to v99.0.0"* ]]'
cp "$BIN" "$RU/inst/asm"
printf '%s  asm-terminal-linux-x86_64\n' "${GOOD^^}" > "$RU/srv/SHA256SUMS"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: upper-case hash accepted"      '[[ "$rel_out" == *"Updated to v99.0.0"* ]]'
cp "$BIN" "$RU/inst/asm"
printf '%s  other\n%s  asm-terminal-linux-x86_64\n' "$GOOD" "$GOOD" > "$RU/srv/SHA256SUMS"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: hash found on a later line"    '[[ "$rel_out" == *"Updated to v99.0.0"* ]]'
cp "$BIN" "$RU/inst/asm"
printf 'zz%s  asm-terminal-linux-x86_64\n' "${GOOD:2}" > "$RU/srv/SHA256SUMS"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: non-hex hash refused"          '[[ "$rel_out" == *"Could not get checksums"* ]] && cmp -s "$RU/inst/asm" "$BIN"'
rm -rf "$RU"

# sha256sum not installed: say so, do not claim tampering
RU=$(mktemp -d); rel_upd_setup "$RU"
rel_out=$(printf 'update install\nexit\n' | timeout 20 env PATH="$RU/bin" HOME="$RU/home" ASM_NO_UPDATE_CHECK=1 "$RU/inst/asm" 2>&1 | strip_ansi)
rel_ok "update: missing sha256sum reported"    '[[ "$rel_out" == *"Could not run"*sha256sum* && "$rel_out" != *"Checksum mismatch"* ]] && cmp -s "$RU/inst/asm" "$BIN"'
rm -rf "$RU"

# never downgrade; hostile tags
RU=$(mktemp -d); rel_upd_setup "$RU"
echo '{"tag_name": "v0.0.1"}' > "$RU/srv/latest"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: older release is not installed" '[[ "$rel_out" == *"latest version"* ]] && cmp -s "$RU/inst/asm" "$BIN"'
printf '{"tag_name": "v99.0.0\033[31mRED\033]0;PWNED\007"}\n' > "$RU/srv/latest"
rel_out=$(printf 'update\nexit\n' | env PATH="$RU/bin:$PATH" HOME="$RU/home" ASM_NO_UPDATE_CHECK=1 timeout 20 "$RU/inst/asm" 2>&1)
rel_ok "update: tag with escape codes rejected" '[[ "$rel_out" == *"Could not read the latest release"* && "$rel_out" != *PWNED* && "$rel_out" != *RED* ]]'
echo '{"tag_name": "v99.0.0/../../../evil/x"}' > "$RU/srv/latest"
rel_out=$(rel_upd_run "$RU" 'update install\n')
rel_ok "update: tag with a path rejected"       '[[ "$rel_out" == *"Could not read the latest release"* ]] && ! grep -q "evil" "$RU/log"'
echo '{"tag_name": "v99.0.0-rc.1"}' > "$RU/srv/latest"
rel_out=$(rel_upd_run "$RU" 'update\n')
rel_ok "update: tag with a suffix accepted"     '[[ "$rel_out" == *"Update available: v"*"-> v99.0.0-rc.1"* ]]'
rm -rf "$RU"

# binary on an AppImage mount belongs to the AppImage
RU=$(mktemp -d); rel_upd_setup "$RU"
mkdir -p "$RU/.mount_asmXYZ/usr/bin"; cp "$BIN" "$RU/.mount_asmXYZ/usr/bin/asm-terminal"
rel_out=$(printf 'update install\nexit\n' | env PATH="$RU/bin:$PATH" HOME="$RU/home" ASM_NO_UPDATE_CHECK=1 timeout 20 "$RU/.mount_asmXYZ/usr/bin/asm-terminal" 2>&1 | strip_ansi)
rel_ok "update: AppImage copy is not replaced"  '[[ "$rel_out" == *"package manager or an AppImage"* ]] && cmp -s "$RU/.mount_asmXYZ/usr/bin/asm-terminal" "$BIN"'
rm -rf "$RU"

# binary replaced on disk by someone else after it started
RU=$(mktemp -d); rel_upd_setup "$RU"
rel_out=$(printf 'cp %s/inst/asm %s/inst/asm.swap\nmv %s/inst/asm.swap %s/inst/asm\nupdate install\nexit\n' "$RU" "$RU" "$RU" "$RU" \
           | env PATH="$RU/bin:$PATH" HOME="$RU/home" ASM_NO_UPDATE_CHECK=1 timeout 20 "$RU/inst/asm" 2>&1 | strip_ansi)
rel_ok "update: replaced binary is not named (deleted)" \
    '[[ "$rel_out" == *"replaced on disk"* ]] && [[ "$(ls "$RU/inst")" == "asm" ]]'
rm -rf "$RU"

# --- files the packages ship ----
rel_out=""
rel_ok "LICENSE file exists (MIT)"       'head -n 3 "$HERE/../LICENSE" 2>/dev/null | grep -q "MIT License"'
rel_ok "LICENSE names the author"        'grep -q "Copyright (c) 20[0-9][0-9] Umar Khan Yousafzai" "$HERE/../LICENSE" 2>/dev/null'
