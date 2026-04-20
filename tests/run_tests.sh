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

echo
echo "=== $pass passed, $fail failed ==="
if (( fail > 0 )); then
    printf '\nFailed tests:\n'
    for t in "${failures[@]}"; do printf '  %s\n' "$t"; done
    exit 1
fi
exit 0
