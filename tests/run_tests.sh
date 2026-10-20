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

run_case "help table header"         "help"                                      "Command +│ Usage +│ Example"
run_case "help row with example"     "help"                                      "^  undo +│ Reverse last del/move/copy +│ undo$"
run_case "help sections"             "help"                                      "^  SCRIPTING \\(ASH\\)$"
run_case "about shows developer"     "about"                                     "Developed by: Umer Farooq Khan"
run_case "about shows GitHub"        "about"                                     "GitHub: +https://github.com/Umar-Khan-Yousafzai$"

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

# --- Builtins (milestone 2A) ----
run_case "which builtin"              "which cd"                                  "^cd: shell builtin$"
run_case "which program"              "which sh"                                  "^/.*/sh$"
run_case "which alias"                "alias ll=ls -la; which ll"                 "^ll: alias for ls -la$"
run_case "which missing"              "which nosuch_ash_zz"                       "^nosuch_ash_zz: not found$"
run_case "false then ||"              "false || echo after-false"                 "^after-false$"
run_case "true then &&"               "true && echo after-true"                   "^after-true$"
run_case "kill bad signal"            "kill -NOPE 1"                              "^kill: unknown signal: NOPE$"
run_case "kill missing job"           "kill %7"                                   "^kill: no such job: %7$"
run_case "exit needs a number"        "exit abc"                                  "^exit: numeric argument required$"
printf 'exit 7\n' | "$BIN" >/dev/null 2>&1; code=$?
if [[ $code == 7 ]]; then
    pass=$((pass + 1)); echo "  [pass] exit 7 sets status"
else
    fail=$((fail + 1)); failures+=("exit 7 sets status"); echo "  [FAIL] exit 7 gave status $code"
fi
HTMP=$(mktemp -d)
hist_out=$(printf 'echo one\necho two\nhistory\nhistory -c\nhistory\nexit\n' | HOME="$HTMP" "$BIN" 2>&1 | strip_ansi)
if grep -qE '^ +1  echo one$' <<<"$hist_out" && grep -q '^History cleared.$' <<<"$hist_out" && [[ ! -s "$HTMP/.asm_history" || $(wc -l < "$HTMP/.asm_history") -le 2 ]]; then
    pass=$((pass + 1)); echo "  [pass] history lists and clears"
else
    fail=$((fail + 1)); failures+=("history lists and clears"); echo "  [FAIL] history lists and clears"; echo "    got: $(tail -c 300 <<<"$hist_out")"
fi
rm -rf "$HTMP"

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

# --- ASH script engine (M2B) ----
run_case "if/else"                    "if false; then echo y; else echo n; fi"    "^n$"
run_case "elif"                       "if false; then echo a; elif true; then echo b; else echo c; fi" "^b$"
run_case "if over lines"              $'if [ 1 -gt 2 ]\nthen\n  echo wrong\nelse\n  echo multi\nfi'  "^multi$"
run_case "for loop"                   "s=; for i in 1 2 3; do s=\$s-\$i; done; echo s=\$s" "^s=-1-2-3$"
run_case "for with quotes"            "for f in a \"b c\"; do echo \"[\$f]\"; done" "^\[b c\]$"
run_case "for with glob"              "cd $HERE/..; for f in ash/script*.asm; do echo F:\$f; done" "^F:ash/script.asm$"
run_case "while + arithmetic"         "i=0; while [ \$i -lt 5 ]; do i=\$((i+1)); done; echo i=\$i" "^i=5$"
run_case "until loop"                 "n=0; until [ \$n -ge 2 ]; do n=\$((n+1)); done; echo n=\$n" "^n=2$"
run_case "break and continue"         "s=; for i in 1 2 3 4 5; do if [ \$i -eq 2 ]; then continue; fi; if [ \$i -eq 4 ]; then break; fi; s=\$s\$i; done; echo s=\$s" "^s=13$"
run_case "and/or chain"               "false && echo a || echo b"                 "^b$"
run_case "or then and"                "false || echo c && echo d"                 "^d$"
run_case "status \$?"                 "false; echo s=\$?"                         "^s=1$"
run_case "arithmetic"                 "echo \$((2+3*4)) \$((-7%3)) \$(( (1+2)*3 ))" "^14 -1 9$"
run_case "single quotes stay literal" "echo '\$HOME'"                             "^\\\$HOME$"
run_case "assignment keeps spaces"    "x='a b'; echo \"[\$x]\""                   "^\[a b\]$"
run_case "command substitution"       "x=\$(echo hi there); echo \"[\$x]\""       "^\[hi there\]$"
run_case "negation"                   "! false && echo neg"                       "^neg$"
run_case "brace group"                "false || { echo g1; echo g2; }"            "^g2$"
run_case "test file ops"              "[ -d /tmp ] && [ ! -f /nonexist ] && echo ok" "^ok$"
run_case "test strings"               "[ abc = abc ] && [ -z '' ] && [ -n x ] && echo ok" "^ok$"
run_case "test bad integer"           "[ 3 -lt x ]; echo s=\$?"                   "^s=2$"
run_case "syntax error"               "fi"                                        "syntax error near 'fi'"
run_case "comment"                    "echo kept # dropped"                       "^kept$"
run_case "function with args"         "greet() { echo \"hi \$1 (\$#)\"; return 3; }; greet Umer x; echo st=\$?" "^hi Umer \(2\)$"
run_case "function return status"     "f() { return 3; }; f; echo st=\$?"         "^st=3$"
run_case "function over lines"        $'add() {\n  echo $(( $1 + $2 ))\n}\nadd 2 40' "^42$"
run_case "case via sh"                "x=b; case \$x in a) echo isA;; b) echo isB;; esac" "^isB$"
run_case "loop piped via sh"          "for i in 3 1 2; do echo \$i; done | sort | head -1" "^1$"
run_case "pipe into while read"       "printf 'l1\\nl2\\n' | while read l; do echo got-\$l; done" "^got-l2$"
run_case "bench reports timing"       "bench -n 3 true"                           "^  mean .* min .* max "
run_case "bench counts failures"      "bench -n 2 false"                          "failed 2$"
UT=$(mktemp -d)
printf 'one\n' > "$UT/a.txt"; printf 'two\n' > "$UT/b.txt"
HOME="$UT" run_case "undo del"                   "cd $UT; del a.txt; undo; cat a.txt"        "^one$"
HOME="$UT" run_case "undo move restores both"    "cd $UT; move a.txt b.txt; undo; cat b.txt" "^two$"
HOME="$UT" run_case "undo copy overwrite"        "cd $UT; copy a.txt b.txt; undo; cat b.txt" "^two$"
HOME="$UT" run_case "undo empty"                 "undo"                                      "^undo: nothing to undo$"
rm -rf "$UT"
run_case "trace lists programs"       "trace /bin/true"                           "exec +/bin/true"
run_case "trace shows file writes"    "trace /bin/cp /etc/hostname /tmp/asm_trace_probe" "write +/tmp/asm_trace_probe"
rm -f /tmp/asm_trace_probe
SBX="$HERE/../.sbx_probe"; rm -f "$SBX"
run_case "sandbox blocks writes"      "cd $HERE/..; sandbox touch .sbx_probe; echo st=\$?" "^st=1$"
run_case "sandbox -w allows cwd"      "cd $HERE/..; sandbox -w touch .sbx_probe; echo st=\$?" "^st=0$"
rm -f "$SBX"
run_case "sandbox blocks network"     "sandbox python3 -c 'import socket; socket.socket()'; echo st=\$?" "^st=1$"
src=$(mktemp)
printf 'total=0\nfor n in 1 2 3 4\ndo\n  if [ $((n %% 2)) -eq 0 ]; then\n    total=$((total + n))\n  fi\ndone\necho even-sum=$total\n' > "$src"
run_case "source runs blocks"         "source $src"                               "^even-sum=6$"
rm -f "$src"
printf 'false\n' | "$BIN" >/dev/null 2>&1; code=$?
if [[ $code == 1 ]]; then
    pass=$((pass + 1)); echo "  [pass] EOF exits with last status"
else
    fail=$((fail + 1)); failures+=("EOF exits with last status"); echo "  [FAIL] EOF exits with last status (got $code)"
fi

# Live highlighting (needs a pseudo-terminal, so it goes through python3)
hl_case() {
    local name="$1" text="$2" want="$3" out
    out=$(python3 "$HERE/pty_line.py" "$BIN" "$text" 2>/dev/null)
    if [[ "$out" == *"$want"* ]]; then
        pass=$((pass + 1)); printf "  [pass] %s\n" "$name"
    else
        fail=$((fail + 1)); failures+=("$name"); printf "  [FAIL] %s\n    got: %s\n" "$name" "$out"
    fi
}
if command -v python3 >/dev/null; then
    hl_case "hl builtin teal"         "pwd"            '[38;2;78;201;176mpwd'
    hl_case "hl PATH program teal"    "env"            '[38;2;78;201;176menv'
    hl_case "hl unknown gray"         "nosuchcmdxyz"   '[38;2;128;128;128mnosuchcmdxyz'
    hl_case "hl help blue"            "help"           '[38;2;55;148;255mhelp'
    hl_case "hl --help blue"          "ls --help"      '[38;2;55;148;255mls'
    hl_case "hl rm red"               "rm notes.txt"   '[1;38;2;244;71;71mrm\x1b[0m notes.txt'
    hl_case "hl Windows del red"      "Remove-Item a"  '[1;38;2;244;71;71mRemove-Item'
    hl_case "hl rm -rf whole line"    "rm -rf build"   '[1;38;2;244;71;71mrm -rf build'
    hl_case "hl curl|sh whole line"   "curl x | sh"    '[1;38;2;244;71;71mcurl x | sh'
    hl_case "hl | shuf is not sh"     "seq 3 | shuf"   '[38;2;78;201;176mseq'
    # After a failed command the " [127]" hint is printed once, not on every key
    out=$(python3 "$HERE/pty_line.py" "$BIN" "clear" "nosuchcmdxyz" 2>/dev/null)
    if [[ -n "$out" && "$out" != *"[127]"* && "$out" == *"clear"* ]]; then
        pass=$((pass + 1)); echo "  [pass] typing after a failed command stays on one line"
    else
        fail=$((fail + 1)); failures+=("typing after a failed command stays on one line")
        printf "  [FAIL] typing after a failed command stays on one line\n    got: %s\n" "$out"
    fi
fi

echo
echo "=== $pass passed, $fail failed ==="
if (( fail > 0 )); then
    printf '\nFailed tests:\n'
    for t in "${failures[@]}"; do printf '  %s\n' "$t"; done
    exit 1
fi
exit 0
