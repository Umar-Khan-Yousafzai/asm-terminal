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

# --- packaging scripts and the Makefile, on a throwaway copy of the tree ----
REL_ROOT="$HERE/.."
rel_tree() {   # rel_tree DIR: just what the install/packaging scripts need
    mkdir -p "$1"
    cp -r "$REL_ROOT/packaging/linux" "$REL_ROOT/packaging/debian" "$1/" 2>/dev/null
    mkdir -p "$1/packaging"; mv "$1/linux" "$1/debian" "$1/packaging/"
    cp "$REL_ROOT/Makefile" "$REL_ROOT/version.inc" "$REL_ROOT/README.md" "$1/"
    [[ -f "$REL_ROOT/LICENSE" ]] && cp "$REL_ROOT/LICENSE" "$1/"
    cp "$BIN" "$1/terminal"
}
rel_syntax_ok() {
    local f ok=1
    for f in "$REL_ROOT"/packaging/linux/*.sh "$REL_ROOT"/packaging/debian/*.sh "$REL_ROOT"/packaging/rpm/*.sh \
             "$REL_ROOT"/packaging/appimage/*.sh "$REL_ROOT"/packaging/release-notes.sh \
             "$REL_ROOT"/packaging/linux/asm-terminal-launch; do
        bash -n "$f" 2>/dev/null || { ok=0; echo "bash -n failed: $f"; }
    done
    for f in "$REL_ROOT"/packaging/linux/install-release.sh "$REL_ROOT"/packaging/linux/asm-terminal-launch; do
        sh -n "$f" 2>/dev/null || { ok=0; echo "sh -n failed: $f"; }
    done
    [[ $ok = 1 ]]
}
rel_ok "packaging scripts parse (bash -n, sh -n)" 'rel_syntax_ok'

if command -v make >/dev/null; then
    RT=$(mktemp -d); rel_tree "$RT"
    make -s -C "$RT" -o terminal install-desktop PREFIX="$RT/prefix" DESTDIR="$RT/stage" >/dev/null 2>&1
    rel_ok "make install honours DESTDIR"  '[[ -x "$RT/stage$RT/prefix/bin/asm-terminal" && ! -e "$RT/prefix" ]]'
    rel_ok "make install: asm link created" '[[ "$(readlink "$RT/stage$RT/prefix/bin/asm")" == asm-terminal ]]'
    rel_ok "make install: Exec is quoted"   'grep -q "^Exec=\"$RT/prefix/bin/asm-terminal-launch\"$" "$RT/stage$RT/prefix/share/applications/asm-terminal.desktop"'
    make -s -C "$RT" -o terminal uninstall PREFIX="$RT/prefix" DESTDIR="$RT/stage" >/dev/null 2>&1
    rel_ok "make uninstall honours DESTDIR" '[[ ! -e "$RT/stage$RT/prefix/bin/asm-terminal" && ! -L "$RT/stage$RT/prefix/bin/asm" ]]'

    mkdir -p "$RT/p2/bin"; printf '#!/bin/sh\necho foreign\n' > "$RT/p2/bin/asm"
    rel_out=$(make -s -C "$RT" -o terminal install PREFIX="$RT/p2" 2>&1)
    rel_ok "make install keeps another program named asm" \
        '[[ "$(sed -n 2p "$RT/p2/bin/asm")" == "echo foreign" && ! -L "$RT/p2/bin/asm" && -x "$RT/p2/bin/asm-terminal" && "$rel_out" == *"left alone"* ]]'
    make -s -C "$RT" -o terminal uninstall PREFIX="$RT/p2" >/dev/null 2>&1
    rel_ok "make uninstall keeps another program named asm" '[[ -f "$RT/p2/bin/asm" && ! -e "$RT/p2/bin/asm-terminal" ]]'
    ln -s pwn-asm "$RT/p2/bin/asm2"
    make -s -C "$RT" -o terminal install PREFIX="$RT/p2" INSTALL_NAME=asm2 >/dev/null 2>&1
    rel_ok "make install keeps a foreign asm symlink" '[[ "$(readlink "$RT/p2/bin/asm2")" == pwn-asm ]]'
    mkdir -p "$RT/p3/bin"; cp "$BIN" "$RT/p3/bin/asm"
    make -s -C "$RT" -o terminal install PREFIX="$RT/p3" >/dev/null 2>&1
    rel_ok "make install replaces an older ASM Terminal copy" '[[ "$(readlink "$RT/p3/bin/asm")" == asm-terminal ]]'

    make -s -C "$RT" -o terminal dist VERSION=0.0.0 >/dev/null 2>&1
    rel_ok "make dist ships LICENSE" 'tar tzf "$RT/dist/asm-terminal-0.0.0-linux-x86_64.tar.gz" | grep -q "/LICENSE$"'
    rm -rf "$RT/dist" "$RT/LICENSE"
    rel_ok "make dist fails without LICENSE" '! make -s -C "$RT" -o terminal dist VERSION=0.0.0 >/dev/null 2>&1'
    rm -rf "$RT"
fi

# install.sh (GUI-less) and uninstall.sh
RT=$(mktemp -d); rel_tree "$RT"
rel_out=$(ASM_NOGUI=1 ASM_SCOPE=user ASM_PREFIX="$RT/pre fix" ASM_TERMINAL_BIN="$BIN" bash "$RT/packaging/linux/install.sh" 2>&1)
rel_ok "install.sh text mode prints real newlines" '[[ "$rel_out" != *\\n* && "$(wc -l <<<"$rel_out")" -ge 5 ]]'
rel_ok "install.sh quotes Exec for a prefix with a space" \
    'grep -q "^Exec=\"$RT/pre fix/bin/asm-terminal-launch\"$" "$RT/pre fix/share/applications/asm-terminal.desktop"'
rel_out=$(ASM_NOGUI=1 ASM_TERMINAL_BIN="$RT/missing" bash "$RT/packaging/linux/install.sh" 2>&1)
rel_ok "install.sh error text has real newlines"  '[[ "$rel_out" == *"Binary not found"* && "$rel_out" != *\\n* ]]'
mkdir -p "$RT/f/bin"; printf '#!/bin/sh\necho foreign\n' > "$RT/f/bin/asm"
rel_out=$(ASM_NOGUI=1 ASM_SCOPE=user ASM_PREFIX="$RT/f" ASM_TERMINAL_BIN="$BIN" bash "$RT/packaging/linux/install.sh" 2>&1)
rel_ok "install.sh keeps another program named asm" \
    '[[ ! -L "$RT/f/bin/asm" && "$(sed -n 2p "$RT/f/bin/asm")" == "echo foreign" && -x "$RT/f/bin/asm-terminal" && "$rel_out" == *"left alone"* ]]'
ASM_PREFIX="$RT/f" bash "$RT/packaging/linux/uninstall.sh" >/dev/null 2>&1
rel_ok "uninstall.sh keeps another program named asm" '[[ -f "$RT/f/bin/asm" && ! -e "$RT/f/bin/asm-terminal" ]]'
ASM_PREFIX="$RT/pre fix" bash "$RT/packaging/linux/uninstall.sh" >/dev/null 2>&1
rel_ok "uninstall.sh removes our asm link" '[[ ! -L "$RT/pre fix/bin/asm" && ! -e "$RT/pre fix/bin/asm-terminal" ]]'
rm -rf "$RT"

# install-release.sh against a local file:// mirror
if command -v curl >/dev/null; then
    RT=$(mktemp -d); rel_tree "$RT"
    mkdir -p "$RT/rel"
    cp "$BIN" "$RT/rel/asm-terminal-linux-x86_64"
    tar -C "$RT/packaging/linux" -czf "$RT/rel/asm-terminal-linux-desktop.tar.gz" \
        asm-terminal-launch asm-terminal.desktop asm-terminal.svg icons
    (cd "$RT/rel" && sha256sum asm-terminal-linux-x86_64 asm-terminal-linux-desktop.tar.gz > SHA256SUMS)
    IR="$RT/packaging/linux/install-release.sh"
    rel_out=$(ASM_PREFIX="$RT/pre fix" ASM_RELEASE_BASE="file://$RT/rel" sh "$IR" 2>&1)
    rel_ok "install-release.sh installs from a mirror"  '[[ -x "$RT/pre fix/bin/asm-terminal" && "$(readlink "$RT/pre fix/bin/asm")" == asm-terminal ]]'
    rel_ok "install-release.sh quotes Exec for a prefix with a space" \
        'grep -q "^Exec=\"$RT/pre fix/bin/asm-terminal-launch\"$" "$RT/pre fix/share/applications/asm-terminal.desktop"'
    ASM_PREFIX="$RT/pre fix" sh "$IR" --uninstall >/dev/null 2>&1
    rel_ok "install-release.sh --uninstall removes everything" '[[ ! -e "$RT/pre fix/bin/asm-terminal" && ! -L "$RT/pre fix/bin/asm" ]]'

    mkdir -p "$RT/f/bin"; printf '#!/bin/sh\necho foreign\n' > "$RT/f/bin/asm"
    rel_out=$(ASM_PREFIX="$RT/f" ASM_RELEASE_BASE="file://$RT/rel" sh "$IR" 2>&1)
    rel_ok "install-release.sh keeps another program named asm" \
        '[[ ! -L "$RT/f/bin/asm" && "$(sed -n 2p "$RT/f/bin/asm")" == "echo foreign" && -x "$RT/f/bin/asm-terminal" && "$rel_out" == *"left alone"* ]]'
    ASM_PREFIX="$RT/f" sh "$IR" --uninstall >/dev/null 2>&1
    rel_ok "install-release.sh --uninstall keeps another program named asm" '[[ -f "$RT/f/bin/asm" && ! -e "$RT/f/bin/asm-terminal" ]]'

    cp "$RT/rel/SHA256SUMS" "$RT/rel/SHA256SUMS.good"
    printf '%064d  asm-terminal-linux-x86_64\n' 0 > "$RT/rel/SHA256SUMS"
    rel_out=$(ASM_PREFIX="$RT/bad" ASM_RELEASE_BASE="file://$RT/rel" sh "$IR" 2>&1); rel_st=$?
    rel_ok "install-release.sh refuses a wrong checksum" '[[ $rel_st -ne 0 && "$rel_out" == *"checksum mismatch"* && ! -e "$RT/bad/bin/asm-terminal" ]]'
    mv "$RT/rel/SHA256SUMS.good" "$RT/rel/SHA256SUMS"

    rel_out=$(ASM_PREFIX="$RT/bad" ASM_VERSION='v1/../../x' sh "$IR" 2>&1); rel_st=$?
    rel_ok "install-release.sh rejects a malformed ASM_VERSION" '[[ $rel_st -ne 0 && "$rel_out" == *"ASM_VERSION must look like"* ]]'

    # a download cut off half way must not run its first half
    head -c $(( $(wc -c < "$IR") / 2 )) "$IR" | ASM_PREFIX="$RT/cut" ASM_RELEASE_BASE="file://$RT/rel" sh >/dev/null 2>&1
    rel_ok "install-release.sh: truncated script installs nothing" '[[ ! -e "$RT/cut" ]]'
    rm -rf "$RT"
fi

# build-deb.sh: restrictive umask, version from version.inc, copyright file
if command -v dpkg-deb >/dev/null; then
    RT=$(mktemp -d); rel_tree "$RT"
    RVER=$(sed -n 's/.*ASM_VERSION "\(.*\)".*/\1/p' "$RT/version.inc")
    rel_out=$( (umask 077; cd "$RT" && env -u APP_VERSION bash packaging/debian/build-deb.sh) 2>&1 )
    rel_ok "build-deb.sh builds under umask 077, version from version.inc" '[[ -f "$RT/dist/asm-terminal_${RVER}_amd64.deb" ]]'
    rel_ok "deb ships a copyright file with the MIT text" \
        'dpkg-deb --fsys-tarfile "$RT"/dist/*.deb | tar -xO ./usr/share/doc/asm-terminal/copyright | grep -q "^License: MIT"'
    rel_ok "deb description has no stale size claim" '! dpkg-deb -I "$RT"/dist/*.deb | grep -q "73 KB"'
    rm -rf "$RT"
fi
