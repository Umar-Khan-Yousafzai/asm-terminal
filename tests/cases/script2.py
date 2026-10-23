# Script engine, second round: "$@" as separate words, "." for source, native case/esac.
import os, re, subprocess, sys
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
    kw.setdefault('timeout', 20)
    try:
        o, e, st = T.run_script(script, **kw)
    except subprocess.TimeoutExpired:
        return ['<timeout>'], '<timeout>', -1
    return clean(o).split('\n'), clean(e), st


def out(script, **kw):
    lines, err, st = run(script, **kw)
    return [l for l in lines if l != '']


# --- "$@" --------------------------------------------------------------------------
ARGC = 'argc() { echo n=$#; }\n'
o = out(ARGC + 'f() { argc "$@"; }\nf a "b c" d\nf\nf ""\nf "" ""')
T.check('at: "$@" is one word per parameter, nothing when there are none',
        o == ['n=3', 'n=0', 'n=1', 'n=2'], o)
o = out(ARGC + 'f() { argc "$*"; argc $@; argc x"$@"y; argc "$@" "$@"; }\nf a "b c"\nf')
T.check('at: "$*" is one word, $@ splits on blanks, x"$@"y glues the ends on',
        o == ['n=1', 'n=3', 'n=2', 'n=4', 'n=1', 'n=0', 'n=1', 'n=0'], o)
o = out('f() { for x in "$@"; do echo "[$x]"; done; echo end; }\nf a "b c" d\nf\nf ""')
T.check('at: for x in "$@" loops once per parameter and not at all without any',
        o == ['[a]', '[b c]', '[d]', 'end', 'end', '[]', 'end'], o)
o = out('f() { for x in $@; do echo "[$x]"; done; }\nf a "b c"\nf')
T.check('at: unquoted $@ splits, empty gives no iteration', o == ['[a]', '[b]', '[c]'], o)
o = out('show() { for x in "$@"; do echo "<$x>"; done; }\n'
        'f() { show "$@"; }\nf \'it"s\' \'a$b\' \'`x`\' \'*\' \'a;b\' \'c|d\' \'e&f\' \'g>h\' "i\'j" \'back\\slash\'')
T.check('at: parameters with quotes, $, backticks, globs and operators arrive intact',
        o == ['<it"s>', '<a$b>', '<`x`>', '<*>', '<a;b>', '<c|d>', '<e&f>', '<g>h>', "<i'j>", '<back\\slash>'], o)
o = out('inner() { echo "$#:$1:$2"; }\nouter() { inner "$@" z; inner x "$@"; }\nouter "p q" r')
T.check('at: parameters pass through two function levels with more words around them',
        o == ['3:p q:r', '3:x:p q'], o)
o = out('f() { echo "[$@]"; echo "pre$@post"; echo $#; }\nf a b\nf')
T.check('at: "$@" inside a longer string glues the first and last parameter',
        o == ['[a b]', 'prea bpost', '2', '[]', 'prepost', '0'], o)
o = out(ARGC + 'argc "$@"\nargc a "$@" b')
T.check('at: "$@" outside a function is empty', o == ['n=0', 'n=2'], o)
o = out('f() { test "$@" && echo yes; [ "$@" ] || echo no-args-false; }\nf a\nf')
T.check('at: "$@" works as the arguments of test', o == ['yes', 'no-args-false'], o)
o = out('f() { echo "$@" | tr a-z A-Z; echo \'$@\' "\\$@"; }\nf x y')
T.check('at: "$@" in a pipeline; quoted and escaped $@ stay literal', o == ['X Y', '$@ $@'], o)
o = out('f() { x="$@"; echo "[$x]"; }\nf a b')
T.check('at: an assignment still joins the parameters with blanks', o == ['[a b]'], o)
o = out('f() { g "$@"; }\ng() { echo "$#"; shift; echo "$#/$1"; }\nf a b c')
T.check('at: shift in the callee does not disturb the caller', o == ['3', '2/b'], o)
long_args = ' '.join('w%02d' % i for i in range(40))
o = out(ARGC + 'f() { argc "$@"; }\nf ' + long_args)
T.check('at: 40 parameters (about 160 bytes) expand', o == ['n=40'], o)
big = ' '.join(['y' * 60] * 12)
lines, err, st = run(ARGC + 'f() { argc "$@"; }\nf ' + ' '.join(['x' * 30] * 5) + '\nf2() { f "$@" "$@" "$@" "$@"; }\nf2 ' + big + '\necho after')
T.check('at: a line that grows past the input limit is refused, the shell goes on',
        'n=5' in lines and 'after' in lines and 'too long' in err, (lines, err))

# --- "." ------------------------------------------------------------------------------
d = T.tmpdir()
lib = os.path.join(d, 'lib.sh')
with open(lib, 'w') as f:
    f.write('DOTVAR=from-lib\ncd %s\nhelper() { echo helper-ran; }\n' % d)
o = out('. %s\necho $DOTVAR\npwd\nhelper' % lib)
T.check('dot: ". file" runs in this shell: assignments, cd and functions stay',
        o == ['from-lib', d, 'helper-ran'], o)
o = out('source %s\necho $DOTVAR\npwd' % lib)
T.check('dot: source does the same (baseline for the dot form)', o == ['from-lib', d], o)
la, ea, _ = run('. /nonexistent_zz\necho st=$?')
lb, eb, _ = run('source /nonexistent_zz\necho st=$?')
T.check('dot: a missing file gives the same error and status as source',
        ea == eb and 'could not open' in ea and la == lb, (ea, eb, la, lb))
la, ea, _ = run('.\necho st=$?')
lb, eb, _ = run('source\necho st=$?')
T.check('dot: no file name gives the same error as source', ea == eb and 'missing filename' in ea and la == lb, (ea, eb))
o = out('f() { . %s; echo in-f:$DOTVAR; }\nf\ntrue && . %s && echo chained' % (lib, lib))
T.check('dot: works inside a function and after &&', o == ['in-f:from-lib', 'chained'], o)
o = out('x=%s\n. "$x"\necho $DOTVAR\n. %s > %s/dotout.txt\ncat %s/dotout.txt' % (lib, lib, d, d))
T.check('dot: the file name is expanded; redirection of ". file" is accepted', o == ['from-lib'], o)
lines, err, st = run('./nonexistent_zz\n.hidden_zz\n..\necho end')
T.check('dot: ./x, .x and .. are not the dot command',
        'end' in lines and err.count('not found') + err.count('No such') + err.count('Is a directory') >= 3, (lines, err))
with open(os.path.join(d, 'ret.sh'), 'w') as f:
    f.write('echo before\nreturn 3\necho never\n')
o = out('. %s/ret.sh\necho rc=$?' % d)
T.check('dot: return ends the sourced file', o == ['before', 'rc=3'], o)

# --- case/esac ---------------------------------------------------------------------------
o = out('x=hello\ncase $x in a|b) echo no;; hel?o) echo q;; *) echo d;; esac\n'
        'case $x in h*) echo star;; esac\ncase $x in *l*o) echo mid;; esac')
T.check('case: * ? and | alternation, on one line', o == ['q', 'star', 'mid'], o)
o = out('x=hello\ncase $x in\n  [a-g]*) echo ag ;;\n  [h-z]ello)\n    echo hz\n    echo second\n    ;;\n  *) echo other ;;\nesac\necho st=$?')
T.check('case: several lines, ;; on its own line, several commands in a clause',
        o == ['hz', 'second', 'st=0'], o)
o = out('case a in a) echo A\nesac\ncase b in a) echo A;; b) echo B\nesac\ncase c in\n(c) echo paren;;\nesac')
T.check('case: the last ;; is optional, a leading ( is allowed', o == ['A', 'B', 'paren'], o)
o = out('case a in a) echo one;;esac\ncase a in a) echo two\n;;\nesac')
T.check('case: ;;esac and ;; on the next line', o == ['one', 'two'], o)
o = out('case "*" in "*") echo lit;; esac\ncase abc in "*") echo BAD;; *) echo quoted-star-not-glob;; esac\n'
        'case "a b" in "a b") echo space;; esac\ncase "a b" in a\\ b) echo bs;; esac\n'
        "case 'x*' in 'x*') echo sq;; esac\ncase 'a)b' in 'a)b') echo paren-in-pattern;; esac\n"
        "case ';;' in ';;') echo semis;; esac")
T.check('case: quoted pattern parts are literal, ) and ;; inside quotes do not end a clause',
        o == ['lit', 'quoted-star-not-glob', 'space', 'bs', 'sq', 'paren-in-pattern', 'semis'], o)
o = out('v=wor*\ncase word in $v) echo glob;; esac\ncase wor* in "$v") echo dq;; esac\n'
        'case word in "$v") echo BAD;; *) echo dq-nomatch;; esac\nw="a|b"\ncase a in $w) echo BAD;; *) echo bar-literal;; esac')
T.check('case: an unquoted $var is a pattern, a quoted one and a | in a value are literal',
        o == ['glob', 'dq', 'dq-nomatch', 'bar-literal'], o)
o = out('case b in a | b ) echo spaced;; esac\ncase "a b" in "a b" | c) echo q-space;; esac\nv="x y"\ncase "x y" in $v) echo var-space;; esac\n'
        'case a in a| b) echo l;; esac\ncase b in a |b) echo r;; esac\n'
        'case "a b" in $(echo "a b")|zz) echo subst;; esac\ncase "a b" in `echo "a b"`) echo bq;; esac')
T.check('case: blanks around | are ignored, blanks in quotes, values and $( ) are data',
        o == ['spaced', 'q-space', 'var-space', 'l', 'r', 'subst', 'bq'], o)
o = out('case 5 in [[:digit:]]) echo digit;; esac\ncase X in [[:upper:]]) echo upper;; esac\n'
        'case x in [[:upper:]]) echo BAD;; [[:alpha:][:digit:]]) echo two-classes;; esac\n'
        'case "!" in [[:punct:]]) echo punct;; esac\ncase " " in [[:space:]]) echo space;; esac\n'
        'case f in [[:xdigit:]]) echo xdigit;; esac\ncase g in [[:xdigit:]]) echo BAD;; *) echo not-xdigit;; esac')
T.check('case: [[:class:]] in a bracket expression',
        o == ['digit', 'upper', 'two-classes', 'punct', 'space', 'xdigit', 'not-xdigit'], o)
o = out('case x in [!a-w]) echo neg;; esac\ncase x in [^x]) echo BAD;; *) echo caret;; esac\n'
        'case "a]" in a[]]) echo rb;; esac\ncase - in [a-]) echo dash;; esac\n'
        'case b in [abc]) echo set;; esac\ncase "[" in "[") echo lb;; esac\ncase "[" in [) echo bare-lb;; esac')
T.check('case: [!x] [^x] []] [a-] and an unclosed [',
        o == ['neg', 'caret', 'rb', 'dash', 'set', 'lb', 'bare-lb'], o)
o = out('case ab in *a*b*) echo m1;; esac\ncase aXXb in a*b) echo m2;; esac\ncase ab in a*b*c) echo BAD;; *) echo no-c;; esac\n'
        'case "" in "") echo empty;; esac\ncase a in "") echo BAD;; *) echo nonempty;; esac\n'
        'case "a*b" in a\\*b) echo esc;; esac\ncase axb in a\\*b) echo BAD;; *) echo esc-no;; esac\n'
        'case aaab in a*a*b) echo backtrack;; esac\ncase abcabd in *abd) echo tail;; esac\ncase a in ?) echo one;; esac\ncase ab in ?) echo BAD;; ??) echo two;; esac')
T.check('case: stars backtrack, empty word, escaped star, ? counts bytes',
        o == ['m1', 'm2', 'no-c', 'empty', 'nonempty', 'esc', 'esc-no', 'backtrack', 'tail', 'one', 'two'], o)
o = out('false\ncase a in a) echo st=$?;; esac\ncase a in b) true;; esac\necho none=$?\ncase a in a) ;; esac\necho empty=$?\n'
        'case b in a) true;; b) false;; esac\necho last=$?\nfalse\ncase a in a) ;; esac\necho empty-after-false=$?\n'
        'false\ncase $? in 1) echo subject-sees-status;; esac')
T.check('case: $? inside, after a match, with no match and with an empty clause',
        o == ['st=1', 'none=0', 'empty=0', 'last=1', 'empty-after-false=0', 'subject-sees-status'], o)
o = out('x=0\ncase a in a) x=7; cd /;; esac\necho $x\npwd\nf() { case $1 in go) y=set-in-f;; esac; }\nf go\necho $y')
T.check('case: assignments and cd made in a clause stay (no /bin/sh subshell)', o == ['7', '/', 'set-in-f'], o)
o = out('case a in a) echo A;; esac && echo and\ncase a in b) echo B;; esac || echo or-skipped\n'
        'case a in a) false;; esac || echo or-ran\nfalse && case a in a) echo BAD;; esac\necho skipped-ok')
T.check('case: && and || before and after a case', o == ['A', 'and', 'or-ran', 'skipped-ok'], o)
script = ('for w in apple banana cherry 42 x y; do\n  case $w in\n    a*) echo "$w: A";;\n'
          '    b*|c*) if [ $w = banana ]; then echo "$w: bee"; else echo "$w: sea"; fi;;\n'
          '    [0-9]*) echo "$w: num"; continue;;\n    x) echo "$w: stop"; break;;\n  esac\n  echo after-$w\ndone\necho out')
o = out(script)
T.check('case: inside for, with if in a clause, continue and break',
        o == ['apple: A', 'after-apple', 'banana: bee', 'after-banana', 'cherry: sea', 'after-cherry', '42: num', 'x: stop', 'out'], o)
o = out('i=0\nwhile [ $i -lt 4 ]; do case $i in 1|3) echo odd$i;; *) echo even$i;; esac; i=$((i+1)); done\n'
        'if true; then case 1 in 1) echo in-if;; esac; fi\n'
        'case x in x) case y in y) echo deep;; z) echo BAD;; esac;; esac\n'
        'case a in a) for i in 1 2; do echo l$i; done;; esac\ncase a in a) while false; do :; done; echo wh;; esac\n'
        'case a in a) if true; then echo ifc; fi;; esac\ncase a in a) { echo brace; };; esac')
T.check('case: nested in while/if/case and holding for/while/if/{} blocks',
        o == ['even0', 'odd1', 'even2', 'odd3', 'in-if', 'deep', 'l1', 'l2', 'wh', 'ifc', 'brace'], o)
o = out('f() { case $1 in\n  one) case $2 in x) echo one-x;; *) echo one-other;; esac;;\n  two) return 7;;\n  *) echo dflt;;\n  esac\n  echo end-f\n}\n'
        'f one x\nf one y\nf two\necho rc=$?\nf zzz')
T.check('case: in a function, nested, with return inside a clause',
        o == ['one-x', 'end-f', 'one-other', 'end-f', 'rc=7', 'dflt', 'end-f'], o)
o = out('f() { case $1 in 0) echo bottom;; *) f $(($1-1)); echo up$1;; esac; }\nf 3')
T.check('case: recursion through a clause', o == ['bottom', 'up1', 'up2', 'up3'], o)
o = out('case a in a) echo hi;; esac | tr a-z A-Z\ncase a in a) echo f;; esac > %s/case_out.txt\ncat %s/case_out.txt' % (d, d))
T.check('case: a case that is piped or redirected still works (handed to /bin/sh)', o == ['HI', 'f'], o)
o = out('f() { case $1 in a) echo A;; esac | cat; }\nf a')
T.check('case: a piped case inside a function still works', o == ['A'], o)
o = out('case $(echo "a b") in "a b") echo cmdsubst;; esac\ncase x in x) echo $(echo ")") ;; esac\ncase x in x) echo "a;;b" ;; esac\n'
        'case x in x) echo \'esac\' ;; esac\ncase esac in esac) echo word;; esac\necho esac')
T.check('case: ) ;; and esac inside quotes, substitutions and as words',
        o == ['cmdsubst', ')', 'a;;b', 'esac', 'word', 'esac'], o)
lines, err, st = run('case $UNSETVAR_ZZ in "") echo empty-word;; esac\ncase "$UNSETVAR_ZZ" in "") echo empty-dq;; esac\ncase a b in a) echo x;; esac\necho next')
T.check('case: empty word is fine, two words before "in" are a syntax error',
        [l for l in lines if l][:2] == ['empty-word', 'empty-dq'] and 'syntax error' in err and 'next' in lines, (lines, err))
for bad in ('esac', ';;', 'echo a;; echo b', 'case x in ) echo;; esac', 'case x in a) echo;; ;; esac',
            'if true; then ;; fi', 'case x in a) if true;; esac', 'case x y in a) echo;; esac'):
    lines, err, st = run(bad + '\necho next')
    T.check('case: syntax error, shell goes on (%s)' % bad, 'syntax error' in err and 'next' in lines,
            (lines, err))
lines, err, st = run('case x in a echo;; esac\n')
T.check('case: a clause without ) is a syntax error', 'syntax error' in err or 'unexpected' in err, (lines, err))
lines, err, st = run('case x in a) echo hi')
T.check('case: unterminated case at the end of a script is an error', 'unexpected end' in err, (lines, err))
lines, err, st = run('echo before\ncase x in\na) echo a;;\n')
T.check('case: unterminated multi-line case at EOF', 'unexpected end' in err and 'before' in lines, (lines, err))
lines, err, st = run('case x in x) echo $(echo hi ;; esac\necho next')
T.check('case: an unterminated $( in a clause is reported', ('unterminated' in err or 'syntax' in err or 'unexpected' in err), (lines, err))

# limits
n = 1500
script = 'case c%d in\n' % (n - 1) + ''.join('c%d) echo hit%d;;\n' % (i, i) for i in range(n)) + 'esac'
o = out(script)
T.check('case: 1500 clauses', o == ['hit%d' % (n - 1)], o[-3:])
deep = 120
script = ''.join('case a in a)\n' for _ in range(deep)) + 'echo deep\n' + ''.join(';;\nesac\n' for _ in range(deep))
o = out(script)
T.check('case: 120 levels of nesting', o == ['deep'], o[-3:])
script = ''.join('case a in a)\n' for _ in range(140)) + 'echo deep\n' + ''.join(';;\nesac\n' for _ in range(140)) + 'echo next'
lines, err, st = run(script)
T.check('case: nesting beyond the block limit is a syntax error, not a crash',
        'syntax error' in err and 'next' in lines, (lines[-3:], err[:100]))
longp = 'a' * 400
o = out('case %s in\n%s) echo longmatch;;\nesac' % (longp, longp))
T.check('case: a 400 byte word and pattern', o == ['longmatch'], o)
lines, err, st = run('case ' + 'a' * 600 + ' in a) echo x;; esac\necho next')
T.check('case: a word past the line limit is refused', 'too long' in err and 'next' in lines, (lines, err))
o = out('f() { case $1 in 0) echo bottom;; *) f $(($1-1));; esac; }\nf 150')
T.check('case: recursion 150 deep through a clause', o == ['bottom'], o)
lines, err, st = run('f() { case $1 in 0) echo bottom;; *) f $(($1-1));; esac; }\nf 250\necho next')
T.check('case: runaway recursion through a clause ends with an error', 'nested too deeply' in err and 'next' in lines, (lines, err))
o = out('case a in a) echo a1;; esac; case b in b) echo b1;; esac\ncase a in a) echo x;; esac; echo y')
T.check('case: two statements on a line', o == ['a1', 'b1', 'x', 'y'], o)

# interactive: continuation prompt and history
s = T.Sess()
s.settle()
s.run('case foo in')
scr = s.screen()
T.check('case: the continuation prompt after "case x in"', scr.rstrip().endswith('>') or '> ' in scr.split('\n')[-1] or '>' in scr.split('\n')[-2], scr[-200:])
s.run('foo|bar) echo matched-foo ;;')
s.run('*) echo other ;;')
s.run('esac')
T.check('case: a typed multi-line case runs when closed', 'matched-foo' in s.screen(), s.screen()[-300:])
s.run('case q in q) cd /; esac')
s.run('pwd')
T.check('case: cd in a typed clause stays', s.screen().rstrip().split('\n')[-2].strip() == '/', s.screen()[-200:])
s.close()

T.cleanup()
