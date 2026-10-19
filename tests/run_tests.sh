#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ASM Terminal smoke test harness
# Runs a battery of non-interactive commands through the built binary and
# checks that their output matches expected strings. Exits 0 on success,
# 1 on any failure. No external deps beyond bash + grep.
# ---------------------------------------------------------------------------
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../terminal}"
if [[ ! -x "$BIN" ]]; then
    echo "FAIL: binary not found at $BIN (run 'make' first)" >&2
    exit 1
fi

pass=0
fail=0
failures=()

strip_ansi() {
    # CSI sequences with optional intermediate bytes (e.g. DECSCUSR "0 q"),
    # OSC 7 and OSC 133 markers, and stray BEL (0x07) terminators.
    sed -E '
        s/\x1b\[[0-9;?]*[ ]*[@A-Za-z~]//g;
        s/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g;
        s/\x07//g
    '
}

run_case() {
    local name="$1" input="$2" pattern="$3"
    local out
    out=$(printf '%s\nexit\n' "$input" | "$BIN" 2>&1 | strip_ansi)
    if grep -qE "$pattern" <<<"$out"; then
        pass=$((pass + 1))
        printf "  [pass] %s\n" "$name"
    else
        fail=$((fail + 1))
        failures+=("$name")
        printf "  [FAIL] %s\n" "$name"
        printf "    expected pattern: %s\n" "$pattern"
        printf "    got: %s\n" "$(head -c 200 <<<"$out")"
    fi
}

echo "=== ASM Terminal smoke tests ==="

# --- Basic commands ----
run_case "echo prints arg"            "echo hello world"              "hello world"
run_case "pwd prints cwd"             "pwd"                           "^/"
run_case "cd + pwd roundtrip"         "cd /tmp; pwd"                  "^/tmp$"
run_case "whoami returns something"   "whoami"                        "\S+"

# --- Variable expansion ----
run_case "set + echo var"             "set FOO=bar; echo \$FOO"       "^bar$"
run_case "tilde expands to HOME"      "cd /tmp; cd ~; pwd"            "^/"
run_case "cd no-args -> HOME"         "cd /tmp; cd; pwd"              "^/"

# --- Compound commands ----
run_case "semi runs both"             "echo a; echo b"                "^a$"
run_case "&& runs on success"         "echo ok && echo yes"           "^yes$"
run_case "|| skipped on success"      "echo ok || echo nope"          "^ok$"

# --- calc ----
run_case "calc 2+3"                   "calc 2 + 3"                    "^5$"
run_case "calc 64-bit"                "calc 3000000000 * 2"           "^6000000000$"

# --- ls / mkdir ----
rm -rf /tmp/asm-test-tree
run_case "mkdir -p nested"            "mkdir -p /tmp/asm-test-tree/a/b; pwd" "^/"
if [[ -d /tmp/asm-test-tree/a/b ]]; then
    pass=$((pass + 1)); echo "  [pass] mkdir -p created nested dirs"
else
    fail=$((fail + 1)); failures+=("mkdir -p side effect"); echo "  [FAIL] mkdir -p didn't create dirs"
fi
rm -rf /tmp/asm-test-tree

# --- echo flags ----
run_case "echo -n no newline"         "echo -n hi; echo after"        "^hiafter$"
run_case "echo -e \\\\n expansion"    "echo -e 'a\\nb'"               "^a$"

# --- Export propagation ----
run_case "export propagates"          "set X=propagated; /bin/sh -c 'echo \$X'" "^propagated$"

# --- Unset ----
run_case "unset clears"               "set Y=1; unset Y; /bin/sh -c 'echo Y=\$Y'" "^Y=$"

# --- Unalias ----
run_case "unalias removes"            "alias pp=echo aa; pp; unalias pp" "^aa$"

# --- Timezone env ----
run_case "ASM_TZ=0 shows UTC-ish"     "set ASM_TZ=0; date"            "[0-9]+"

run_case "about shows developer"     "about"                                     "Developed by: Omar Farooq Khan"

# --- ASH native executor (no /bin/sh) ----
run_case "ash pipeline"               "printf 'b\\na\\nc\\n' | sort | head -1"   "^a$"
run_case "ash quotes"                 "printf '%s|%s\\n' 'x y' \"q \\\"z\\\"\""    '^x y\|q "z"$'
run_case "ash backslash escape"       "printf '%s\\n' a\\ b"                       "^a b$"
run_case "ash command not found"      "nosuchcmd_ash_zz"                           "ash: nosuchcmd_ash_zz: command not found"
run_case "ash 2>&1 into pipe"         "head /nonexist_ash 2>&1 | wc -l"           "^1$"
rm -f /tmp/asm-ash-out.txt
run_case "ash > and >> redirect"      "printf 'a\\n' > /tmp/asm-ash-out.txt; printf 'b\\n' >> /tmp/asm-ash-out.txt; wc -l /tmp/asm-ash-out.txt" "^2 /tmp/asm-ash-out.txt$"
run_case "ash < redirect in pipe"     "tr a-z A-Z < /tmp/asm-ash-out.txt | head -1" "^A$"
rm -f /tmp/asm-ash-out.txt
run_case "ash glob falls back to sh"  "ls -d /bin/s* | head -1"                   "^/bin/s"
if command -v strace >/dev/null 2>&1; then
    sh_execs=$(printf "printf 'x\\\\n' | sort | head -1\nexit\n" | strace -f -e trace=execve "$BIN" 2>&1 >/dev/null | grep -c '"/bin/sh"')
    if [[ "$sh_execs" == "0" ]]; then
        pass=$((pass + 1)); echo "  [pass] ash pipeline spawns no /bin/sh"
    else
        fail=$((fail + 1)); failures+=("ash pipeline spawns no /bin/sh"); echo "  [FAIL] ash pipeline spawned /bin/sh $sh_execs time(s)"
    fi
fi

# --- Version + update (fake curl, no network) ----
VER=$(sed -n 's/.*ASM_VERSION "\(.*\)".*/\1/p' "$HERE/../version.inc")
run_case "ver shows version.inc"      "ver"                                       "v$VER "
UPD=$(mktemp -d)
mkdir -p "$UPD/bin" "$UPD/srv" "$UPD/inst"
cp "$BIN" "$UPD/srv/asm-terminal-linux-x86_64"; printf X >> "$UPD/srv/asm-terminal-linux-x86_64"
(cd "$UPD/srv" && sha256sum asm-terminal-linux-x86_64 > SHA256SUMS)
echo '{"tag_name": "v99.0.0"}' > "$UPD/srv/latest"
cat > "$UPD/bin/curl" <<CURL
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift;; --max-time|-H) shift;; -*) ;; *) url="\$1";; esac; shift; done
f="$UPD/srv/\$(basename "\$url")"
[ -f "\$f" ] || exit 22
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
CURL
chmod +x "$UPD/bin/curl"
upd_out=$(printf 'update\nexit\n' | env PATH="$UPD/bin:$PATH" HOME="$UPD" "$BIN" 2>&1 | strip_ansi)
if grep -q "Update available: v$VER -> v99.0.0" <<<"$upd_out"; then
    pass=$((pass + 1)); echo "  [pass] update detects newer release"
else
    fail=$((fail + 1)); failures+=("update detects newer release"); echo "  [FAIL] update detects newer release"; echo "    got: $(tail -c 200 <<<"$upd_out")"
fi
# install: run a copy so the real binary is untouched
cp "$BIN" "$UPD/inst/asm"
printf 'update install\nexit\n' | env PATH="$UPD/bin:$PATH" HOME="$UPD" "$UPD/inst/asm" >/dev/null 2>&1
if cmp -s "$UPD/inst/asm" "$UPD/srv/asm-terminal-linux-x86_64" && [[ ! -e "$UPD/inst/asm.new" ]]; then
    pass=$((pass + 1)); echo "  [pass] update install replaces binary"
else
    fail=$((fail + 1)); failures+=("update install replaces binary"); echo "  [FAIL] update install replaces binary"
fi
rm -rf "$UPD"

echo
echo "=== $pass passed, $fail failed ==="
if (( fail > 0 )); then
    printf '\nFailed tests:\n'
    for t in "${failures[@]}"; do printf '  %s\n' "$t"; done
    exit 1
fi
exit 0
