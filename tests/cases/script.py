# Script engine (ash/script.asm): control flow, functions, $(( )), test, limits.
import os, re, signal, subprocess, sys, time
import ptytest as T


def clean(s):
    s = re.sub(r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '', s)
    s = re.sub(r'\x1b\[[0-9;?]*[ ]*[@A-Za-z~]', '', s)
    i = s.find("Type 'help'")
    if i >= 0:
        s = s[s.index('\n', i) + 1:]
    return s


def run(script, **kw):
    """Run the script on a pipe; returns (stdout lines, stderr text, status)."""
    if not script.endswith('exit\n'):
        script += '\nexit\n'
    kw.setdefault('timeout', 15)
    try:
        o, e, st = T.run_script(script, **kw)
    except subprocess.TimeoutExpired:
        return ['<timeout>'], '<timeout>', -1
    return clean(o).split('\n'), clean(e), st


def out(script, **kw):
    lines, err, st = run(script, **kw)
    return [l for l in lines if l != '']


# --- $? of a command substitution -------------------------------------------
o = out('x=$(false); echo st=$?\nx=$(exit 3); echo st=$?\nx=$(echo hi); echo st=$? $x')
T.check("script: x=$(false) keeps status 1, exit 3 gives 3, success 0",
        o == ['st=1', 'st=3', 'st=0 hi'], o)
o = out('if ! v=$(false); then echo caught; else echo missed; fi\n'
        'out=$(ls /nonexistent_dir_zz 2>/dev/null) || echo FAILED')
T.check("script: if ! v=$(cmd) and v=$(cmd) || handler see the failure",
        o == ['caught', 'FAILED'], o)

# --- functions ---------------------------------------------------------------
o = out('f() { case $1 in a) echo A;; *) echo other;; esac; }\nf a\nf b')
T.check("script: function with case/esac is defined", o == ['A', 'other'], o)
o = out('f() { echo one; }\nf() { for i in 1 2; do echo $i; done > /dev/null; echo two; }\nf')
T.check("script: redefinition replaces the old body", o == ['two'], o)
o = out('f() { echo hi; }\nf | tr a-z A-Z\nf > out.txt\ncat out.txt\nf $(echo x)')
T.check("script: function calls take pipes and redirections", o == ['HI', 'hi', 'hi'], o)
o = out('f() { shift; echo $1 $#; shift 2; echo [$1] $#; }\nf a b c d')
T.check("script: shift drops positional parameters", o == ['b 3', '[d] 1'], o)
lines, err, st = run('f() { shift 5; echo after-$?; }\nf a')
T.check("script: shift past the end is an error", 'shift count' in err and 'after-1' in ''.join(lines), (lines, err))
name = 'n' * 40
lines, err, st = run('%s() { echo hi; }\necho st=$?' % name)
T.check("script: function name of 40 characters is rejected", 'name too long' in err and 'st=1' in ''.join(lines), (lines, err))
n31 = 'b' * 31
o = out('%s() { echo ok31; }\n%s' % (n31, n31))
T.check("script: function name of 31 characters works", o == ['ok31'], o)
o = out('f() { x=1; case a in a) echo y=$x;; esac; }\nf\n'
        'g() { echo $1-$2; }\ng a b | cat\n'
        'h() { echo in-h; }\ncase a in a) h;; esac')
T.check("script: delegated statements see functions and positional parameters",
        o == ['y=1', 'a-b', 'in-h'], o)

o = out('f() { echo hi; }\nfalse\ncase a in a) echo st=$?;; esac\nf() { case a in a) echo "[$1]";; esac; }\nf "it\'s here"')
T.check("script: delegated statements get $? and quoted parameters intact", o == ['st=1', "[it's here]"], o)

for bad in ('while do echo x; done', 'until do echo x; done', 'if then echo x; fi', 'if false; then :; elif then echo x; fi'):
    lines, err, st = run(bad + '\necho next')
    T.check("script: empty condition is a syntax error, not a loop (%s)" % bad.split(';')[0],
            'syntax error' in err and 'next' in lines and lines.count('x') == 0, (lines[:5], err))

# --- recursion ---------------------------------------------------------------
o = out('fact() { if [ $1 -le 1 ]; then r=1; else fact $(($1-1)); r=$(($1*r)); fi; }\nfact 20\necho $r')
T.check("script: recursion 20 levels deep (factorial 20)", o == ['2432902008176640000'], o)
o = out('f() { echo $1; if [ $1 -gt 0 ]; then f $(($1-1)); fi; }\nf 30')
T.check("script: recursion 30 levels deep", o[0] == '30' and o[-1] == '0' and len(o) == 31, o)
lines, err, st = run('f() { f; }\nf\necho st=$?\ng() { while true; do g; done; }\ng\necho st=$?\necho alive')
T.check("script: runaway recursion ends with an error, not a crash",
        'nested too deeply' in err and lines.count('st=2') == 2 and 'alive' in lines and st == 0, (lines, err, st))

# --- loops -------------------------------------------------------------------
o = out('for i in 1 2; do for j in a b; do echo $i$j; break 2; done; done\necho end')
T.check("script: break 2 leaves two loops", o == ['1a', 'end'], o)
o = out('for i in 1 2 3; do for j in a b; do echo $i$j; continue 2; done; echo no; done')
T.check("script: continue 2 continues the outer loop", o == ['1a', '2a', '3a'], o)
lines, err, st = run('for i in 1; do break 0; done\necho w')
T.check("script: break 0 is an error", 'loop count' in err and 'w' in lines, (lines, err))
lines, err, st = run('echo a\nreturn 3\necho b')
T.check("script: return outside a function is an error and does not end the script",
        'can only return' in err and 'b' in lines, (lines, err))
o = out('f() { echo x; return 4; echo y; }\nf\necho st=$?')
T.check("script: return inside a function still works", o == ['x', 'st=4'], o)

# for word lists are not truncated
d = T.tmpdir()
names = ['file_number_%04d_abcdefghij' % i for i in range(400)]
for nm in names:
    open(os.path.join(d, nm), 'w').close()
o = out('n=0; for f in *; do n=$((n+1)); done; echo $n', cwd=d)
T.check("script: for over 400 files sees all of them", o == ['400'], o)
long_names = ['f%04d_%s' % (i, 'x' * 33) for i in range(300)]
d2 = T.tmpdir()
for nm in long_names:
    open(os.path.join(d2, nm), 'w').close()
o = out('for f in *; do last=$f; done; echo $last', cwd=d2)
T.check("script: for keeps the last long name whole", o == [long_names[-1]], o)
o = out('n=0; for i in $(seq 1 3000); do n=$((n+1)); done; echo $n')
T.check("script: for over $(seq 1 3000) runs 3000 times", o == ['3000'], o)

# --- scripts that are large -----------------------------------------------------
o = out('\n'.join([':'] * 400) + '\necho done400')
T.check("script: 400 commands in one piped script", o == ['done400'], o)
body = '\n'.join('echo p%d_xxxxxxxxxx' % i for i in range(300))
lines, err, st = run('if false; then\n' + body + '\nfi\necho after')
T.check("script: a long block with a false condition runs nothing of its body",
        'after' in lines and not any(l.startswith('p') for l in lines), (len(lines), err))
big = '\n'.join('echo q%d_%s' % (i, 'y' * 40) for i in range(20000))
lines, err, st = run('if true; then\n' + big + '\nfi\necho end', timeout=60)
T.check("script: a block over the pending limit aborts the piped script",
        st == 2 and 'too long' in err and 'end' not in lines and not any(l.startswith('q') for l in lines),
        (st, err, len(lines)))
o = out('echo one \\\r\n two\r\necho three\r\n')
T.check("script: CRLF with a backslash continuation joins the lines", o == ['one two', 'three'], o)
o = out('# a comment ending in a backslash \\\necho kept')
T.check("script: a comment ending in a backslash does not swallow the next line", o == ['kept'], o)
o = out("echo 'a\\\nb'")
T.check("script: backslash-newline inside single quotes is kept", o == ['a\\', 'b'], o)
lines, err, st = run('echo "a\n\nb"\necho c')
T.check("script: blank line inside open quotes is kept", lines[1:5] == ['a', '', 'b', 'c'], lines)

# --- source ------------------------------------------------------------------------
sd = T.tmpdir()
open(os.path.join(sd, 'many.sh'), 'w').write(':\n' * 600 + 'echo many-done\n')
open(os.path.join(sd, 'crlf.sh'), 'wb').write(b'echo one \\\r\n two\r\necho three\r\n')
open(os.path.join(sd, 'bad.sh'), 'w').write('echo before\ndone\necho after\n')
open(os.path.join(sd, 'open.sh'), 'w').write('echo first\nif true; then\necho in\n')
open(os.path.join(sd, 'ret.sh'), 'w').write('echo a\nreturn 5\necho b\n')
lines, err, st = run('source many.sh\necho st=$?', cwd=sd)
T.check("script: source runs 600 commands", 'many-done' in lines and 'st=0' in lines, (lines, err))
lines, err, st = run('source crlf.sh', cwd=sd)
T.check("script: source of a CRLF file with a continuation", 'one two' in lines and 'three' in lines, (lines, err))
lines, err, st = run('source bad.sh\necho next', cwd=sd)
T.check("script: source with a syntax error reports it, runs nothing of the file and goes on",
        'syntax error' in err and 'next' in lines and 'before' not in lines, (lines, err))
lines, err, st = run('source open.sh\necho next', cwd=sd)
T.check("script: source of a file with an open block reports it and goes on",
        err != '' and 'next' in lines and 'first' not in lines, (lines, err))
lines, err, st = run('source ret.sh\necho st=$?', cwd=sd)
T.check("script: return ends a sourced file with its status", 'a' in lines and 'b' not in lines and 'st=5' in lines, (lines, err))

# --- & between commands ---------------------------------------------------------
o = out('sleep 0.05 & echo b\nwait')
T.check("script: & separates commands", 'b' in o and any('[bg]' in l for l in o), o)
o = out('ls /nonexistent_dir_zz 2>&1 | cat\necho f')
T.check("script: 2>&1 is not a background marker", 'f' in o and any('nonexistent_dir_zz' in l for l in o), o)

# --- arithmetic -----------------------------------------------------------------
o = out('echo $((10 != 7 <= 0)) $((0 == 0 < 0)) $((1 < 2 == 2 > 1))')
T.check("script: comparison binds tighter than equality", o == ['1 1 1'], o)
o = out('echo $((1<<3)) $((5&3)) $((6|1)) $((6^3)) $((-8>>1)) $((0x10)) $((010)) $((0xFf)) $(( ))')
T.check("script: shifts, bitwise operators, hex and octal", o == ['8 1 7 5 -4 16 8 255 0'], o)
o = out('echo $((1?2:3)) $((0?2:3)) $((1?0?4:5:6)) $((2+3*4)) $((7%3))')
T.check("script: ternary and precedence", o == ['2 3 5 14 1'], o)
o = out('b=0; echo $((b != 0 && 10 / b > 2)) $((b == 0 || 10 / b > 2)) $((1 ? 5 : 1/0)) $((0 ? 1/0 : 6))')
T.check("script: && || and ?: skip the side that is not evaluated", o == ['0 1 5 6'], o)
lines, err, st = run('echo $((5/0))\necho st=$?\necho $((5%0)) x\necho st=$?')
T.check("script: division by zero cancels the command and sets status 1",
        'division by zero' in err and lines.count('st=1') == 2 and 'x' not in lines, (lines, err))
lines, err, st = run('x=$((1/0))\necho st=$? [$x]\nfor i in $((1/0)); do echo no; done')
T.check("script: division by zero in an assignment and a for list",
        'st=1 []' in lines and 'no' not in lines, (lines, err))
lines, err, st = run('echo $((99999999999999999999)) x\necho $((0x)) y\necho $((09)) z')
T.check("script: numbers that do not fit or are malformed are errors",
        err.count('arithmetic syntax error') == 3, (lines, err))
o = out('echo $((9223372036854775807 + 1)) $((-9223372036854775807 - 2))')
T.check("script: arithmetic wraps like 64-bit integers", o == ['-9223372036854775808 9223372036854775807'], o)
lines, err, st = run('[ 18446744073709551617 -eq 1 ]\necho st=$?\n[ 9223372036854775808 -gt 0 ]\necho st=$?')
T.check("script: [ ] rejects integers that do not fit",
        lines.count('st=2') == 2 and 'integer expected' in err, (lines, err))

# --- test / [ -------------------------------------------------------------------
o = out('[ -f /etc/passwd -a -r /etc/passwd ]; echo $?\n'
        '[ 1 = 2 -o 3 = 3 ]; echo $?\n'
        '[ a -a b ]; echo $?\n'
        '[ ! -f /nonexistent_zz -a 1 -lt 2 ]; echo $?\n'
        '[ 1 = 1 -a 2 = 3 ]; echo $?')
T.check("script: test -a and -o", o == ['0', '0', '0', '0', '1'], o)
o = out('[ \\( 1 = 1 -o 1 = 2 \\) -a 2 = 2 ]; echo $?\n'
        '[ \\( 1 = 2 -o 1 = 2 \\) -a 2 = 2 ]; echo $?\n'
        '[ ! 1 = 2 -a x ]; echo $?\n'
        '[ 1 -eq 1 -a -z "" -a -n x -o 5 -gt 9 ]; echo $?\n'
        'test "(" x ")"; echo $?')
T.check("script: test parentheses, ! and more than three words", o == ['0', '1', '0', '0', '0'], o)
lines, err, st = run('[ 1 = 1 -a "(" 2 = 2 ]; echo $?\n[ ]; echo $?\n[ -n ]; echo $?')
T.check("script: malformed test expressions report an error",
        lines[1:4] == ['2', '1', '0'] and 'argument expected' in err, (lines, err))
w = ' '.join(str(i) for i in range(1, 36))
lines, err, st = run('[ %s ]; echo st=$?' % w)
T.check("script: more than 31 words in [ ] is an error, not a silent cut",
        'too many arguments' in err and 'st=2' in lines, (lines, err))

# --- variables ---------------------------------------------------------------------
lines, err, st = run('v=$(seq 1 300)\necho st=$?')
T.check("script: a value that is too long is refused", 'too long' in err and 'st=1' in lines, (lines, err))

# --- interrupt -----------------------------------------------------------------------
def interrupt(cmd, how):
    s = T.Sess()
    s.settle()
    s.send(cmd + "\r")
    s.settle(0.5, 1)
    t0 = time.time()
    if how == 'key':
        s.send("\x03")
    else:
        os.kill(s.p.pid, signal.SIGINT)
    s.settle(0.5, 3)
    s.send("echo back-again\r")
    s.settle(0.5, 2)
    ok = 'back-again' in s.screen() and s.alive()
    el = time.time() - t0
    s.close()
    return ok, el


ok, el = interrupt('x=$(sleep 8; echo done)', 'key')
T.check("script: Ctrl+C stops x=$(long command)", ok and el < 6, (ok, el))
ok, el = interrupt('while true; do :; done', 'sig')
T.check("script: SIGINT stops a loop of builtins", ok, ok)
ok, el = interrupt('f() { while true; do x=$((x+1)); done; }; f', 'sig')
T.check("script: SIGINT stops a loop inside a function", ok, ok)

T.cleanup()
