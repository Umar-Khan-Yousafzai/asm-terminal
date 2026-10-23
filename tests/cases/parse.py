"""Expansion, quoting and redirection: values are data, never syntax."""
import os, re
import ptytest as T

ANSI = re.compile(r'\x1b\[[0-9;?]*[ ]*[@A-Za-z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x07')


def sh(lines, env=None, cwd=None, home=None):
    """Run lines through the shell on a pipe. Returns (stdout lines, stderr, status, cwd)."""
    if cwd is None:
        cwd = T.tmpdir()
    text = "\n".join(lines) + "\nexit\n"
    out, err, st = T.run_script(text, env=env, cwd=cwd, home=home)
    out = ANSI.sub('', out)
    ls = out.split('\n')
    for i, l in enumerate(ls):
        if "Type 'help'" in l:
            ls = ls[i + 1:]
            break
    return [l for l in ls], ANSI.sub('', err), st, cwd


def lines_of(lines, **kw):
    out, err, st, cwd = sh(lines, **kw)
    return [l for l in out if l != '']


def has(cwd, name):
    return os.path.lexists(os.path.join(cwd, name))


def write(cwd, name, data=''):
    with open(os.path.join(cwd, name), 'w') as f:
        f.write(data)


def read(cwd, name):
    try:
        with open(os.path.join(cwd, name), 'rb') as f:
            return f.read().decode('utf-8', 'replace')
    except OSError:
        return None


# ---------------------------------------------------------------- injection
d = T.tmpdir()
for label, val in [("subst", "$(touch PWN)"), ("backtick", "`touch PWN`"),
                   ("redirect", "x > PWN"), ("pipe", "a|touch PWN"),
                   ("semicolon", "a;touch PWN"), ("and", "a&&touch PWN"),
                   ("quote", 'a"b'), ("squote", "it's")]:
    for form in ['echo $X', 'echo "$X"', '/bin/echo $X', '/bin/echo "$X"',
                 'echo $X | cat', 'echo $X *.nomatch', 'Y=$X; echo "$Y"']:
        c = T.tmpdir()
        o, e, st, _ = sh([form], env={'X': val}, cwd=c)
        T.check("inject %s via env, %s: no side effect" % (label, form),
                not has(c, 'PWN') and not has(c, 'b') and not any('Syntax' in x for x in o + [e]),
                (o, e, os.listdir(c)))
    c = T.tmpdir()
    o = lines_of(['echo $X'], env={'X': val}, cwd=c)
    exp = val if label not in ("quote", "squote") else val
    T.check("inject %s via env: value printed as is" % label, o == [exp], o)

c = T.tmpdir()
o = lines_of(['x=\'$HOME\'; echo $x $(echo z)', 'x=\'a"b\'; echo $x $(echo z)'], cwd=c)
T.check("value $HOME is not expanded again", o[0] == '$HOME z', o)
T.check("value with a quote does not break $( )", o[1] == 'a"b z', o)

c = T.tmpdir()
write(c, 'a$(touch PWN9)b'); write(c, 'v.txt'); write(c, 'sp ace')
o = lines_of(['for f in *; do echo file: $f; done',
              'for f in *; do echo "file: $f"; done',
              'for f in *; do /bin/echo "[$f]" | cat; done'], cwd=c)
T.check("file named a$(cmd)b is only data in a for loop", not has(c, 'PWN9'), (o, os.listdir(c)))
T.check("for loop prints the hostile name", 'file: a$(touch PWN9)b' in o and '[a$(touch PWN9)b]' in o, o)

c = T.tmpdir()
o = lines_of(["x='$(touch PWN5)'; echo $x", "x='hi > PWN2'; echo $x",
              "x='a | cat > PWN4'; echo $x", "y='a; touch PWN6'; z=$(echo $y); echo [$z]",
              "x='a; touch PWN7'; for i in $x *.nomatch; do echo $i; done",
              "f() { echo [$1]; }; f '$(touch PWN8)'; f 'a b|c'"], cwd=c)
T.check("assignment and for list values are data", not any(has(c, n) for n in
        ('PWN5', 'PWN2', 'PWN4', 'PWN6', 'PWN7', 'PWN8')), (o, os.listdir(c)))
T.check("hostile value text kept", o[:3] == ['$(touch PWN5)', 'hi > PWN2', 'a | cat > PWN4'], o)
T.check("function argument is data", '[$(touch PWN8)]' in o and '[a b|c]' in o, o)

c = T.tmpdir()
write(c, 'ok.txt')
o = lines_of(["x='$(touch PWNg)'; /bin/echo *.txt $x", "y='q\"d'; /bin/echo *.txt \"$y\" '$y' $y",
              "x='a b'; /bin/echo [o]k.txt \"$x\""], cwd=c)
T.check("sh fallback (glob) keeps values as data", o == ['ok.txt $(touch PWNg)', 'ok.txt q"d $y q"d',
                                                       'ok.txt a b'] and not has(c, 'PWNg'), o)

c = T.tmpdir()
for n in ["it's", 'q"d', 'back\\slash', 'semi;colon', '$(touch PWNf)', '`touch PWNf`']:
    write(c, n)
o = lines_of(['for f in *; do /bin/echo "[$f]"; done'], cwd=c)
T.check("odd file names in a glob for loop", sorted(o) == sorted(
    ["[it's]", '[q"d]', '[back\\slash]', '[semi;colon]', '[$(touch PWNf)]', '[`touch PWNf`]']) and not has(c, 'PWNf'), o)

c = T.tmpdir()
o, e, st, _ = sh(['echo $X', '/bin/echo "$X" y'], env={'X': 'a\ntouch PWNnl'}, cwd=c)
T.check("newline in a value does not start a command", not has(c, 'PWNnl'), (o, e))

# ---------------------------------------------------------------- escapes
c = T.tmpdir()
o = lines_of(['echo \\$HOME', 'echo "\\$HOME"', "echo '$HOME'", 'echo "a\\"b"', "echo 'it'\\''s'",
              'echo a\\;b', 'x=5; echo \\$x $x'], cwd=c, env={'HOME': c})
T.check("backslash keeps $ literal", o[0] == '$HOME' and o[1] == '$HOME', o)
T.check("single quotes keep $ literal", o[2] == '$HOME', o)
T.check("escaped quote in double quotes", o[3] == 'a"b', o)
T.check("quote glued with escaped quote", o[4] == "it's", o)
T.check("escaped semicolon", o[5] == 'a;b', o)
T.check("escaped dollar next to a real one", o[6] == '$x 5', o)

# ---------------------------------------------------------------- tilde, names, limits
c = T.tmpdir()
o = lines_of(['set X=a', 'echo $X~/y', 'echo ~/y', 'echo "~"', 'echo a~'], cwd=c, home=c)
T.check("tilde after a variable is literal", o[0] == 'a~/y', o)
T.check("tilde at word start is HOME", o[1] == c + '/y', o)
T.check("tilde in double quotes is literal", o[2] == '~' and o[3] == 'a~', o)

c = T.tmpdir()
long = 'A' * 600
o, e, st, _ = sh(['echo $' + long, 'echo ${' + long + '}', 'echo alive'], cwd=c)
T.check("very long variable names do not crash", 'alive' in o, (o, st))

c = T.tmpdir()
o, e, st, _ = sh(['set A=' + 'x' * 300, 'echo $A $A $A END', 'echo st=$?', 'touch $A$A$A'], cwd=c)
T.check("expansion that does not fit is an error, not a cut", 'line too long' in e and not any('END' in l for l in o)
        and 'st=1' in o and not os.listdir(c), (o, e, os.listdir(c)))

c = T.tmpdir()
o, e, st, _ = sh(['echo ${x:-d}', 'echo st=$?', 'echo after'], cwd=c)
T.check("unsupported ${...} fails loudly", 'unsupported' in e and 'st=1' in o and 'after' in o, (o, e))

# ---------------------------------------------------------------- command substitution
c = T.tmpdir()
o = lines_of(['x=$(false); echo st=$?', 'x=$(exit 3); echo st=$?', 'out=$(/bin/ls /nonexistent_dir 2>/dev/null) || echo FAILED',
              'if ! v=$(false); then echo caught; fi', 'D=$(pwd); echo [$D]', 'cd $(echo /tmp); pwd',
              'set Q=$(echo hi); echo $Q', 'echo $(echo $(echo nested))', 'echo "$(echo "q  r")"',
              'echo "a   b" `echo c   d`', 'x=`echo hi`; echo $x', 'echo $(calc 2 + 3)'], cwd=c)
T.check("x=$(cmd) has the status of cmd", o[0] == 'st=1' and o[1] == 'st=3', o)
T.check("|| after failed substitution", o[2] == 'FAILED' and o[3] == 'caught', o)
T.check("builtins work in $( ) and with cd/set", o[4] == '[%s]' % c and o[5] == '/tmp' and o[6] == 'hi', o)
T.check("nested and quoted substitution", o[7] == 'nested' and o[8] == 'q  r' and o[9] == 'a   b c d', o)
T.check("backticks and calc in substitution", o[10] == 'hi' and o[11] == '5', o)

# ---------------------------------------------------------------- redirection
c = T.tmpdir()
write(c, 'v.txt', 'hello\n')
o, e, st, _ = sh(['echo "a > b" > f1', 'echo \'x<y\'', '/bin/echo "p > q"', '/bin/echo \'p < q\' | cat',
                  'echo hi 1>one.txt', 'echo file2>out', 'echo hi 2> /dev/null', 'set N=2', 'echo $N>out3',
                  '/bin/echo "a > b" > f2', 'echo done'], cwd=c)
T.check("quoted > is text (builtin and external)", read(c, 'f1') == 'a > b\n' and not has(c, 'b"') and 'x<y' in o
        and 'p > q' in o and 'p < q' in o and read(c, 'f2') == 'a > b\n', (o, os.listdir(c)))
T.check("N> redirects, digits are not text", read(c, 'one.txt') == 'hi\n' and read(c, 'out') == 'file2\n'
        and read(c, 'out3') == '2\n' and 'hi' in o, (o, os.listdir(c)))
T.check("2> /dev/null on a builtin", 'hi 2> /dev/null' not in o, o)

c = T.tmpdir()
o, e, st, _ = sh(['echo SECRET > /nonexistent_dir/f', 'echo st=$?', '/bin/echo SECRET2 > /nonexistent_dir/f',
                  'echo st=$?', 'wc -l < missing', 'echo NEXT', 'echo hi >', 'echo after'], cwd=c)
T.check("failed redirect: command does not run, status 1", 'SECRET' not in ''.join(o) and 'SECRET2' not in ''.join(o)
        and o.count('st=1') == 2 and 'No such file' in e, (o, e))
T.check("failed < does not eat the script", 'NEXT' in o and 'after' in o, o)
T.check("missing redirection target is an error", 'redirection' in e, e)

c = T.tmpdir()
o, e, st, _ = sh(['/bin/ls /nonexistent_dir 2>&1 >o2 | /bin/cat', '/bin/ls /nonexistent_dir 2>&1 >o3', '/bin/ls /nonexistent_dir >o4 2>&1',
                  '/bin/ls /nonexistent_dir &> o5', '/bin/echo x 3>f3', 'echo err >&2', 'echo out >&1'], cwd=c)
T.check("2>&1 before > keeps stderr on the old stdout", read(c, 'o2') == '' and read(c, 'o3') == ''
        and 'cannot access' in ''.join(o + [e]), (o, e, read(c, 'o2'), read(c, 'o3')))
T.check(">f 2>&1 sends both to the file", 'cannot access' in read(c, 'o4') and 'cannot access' in read(c, 'o5'), os.listdir(c))
T.check("N>file for other N goes to sh", 'x' in o and 'x 3' not in o and has(c, 'f3'), o)
T.check(">&2 writes builtin output to stderr", 'err' in e and 'err' not in o and 'out' in o, (o, e))

c = T.tmpdir()
write(c, 'sc.txt', 'echo from-script\n/bin/echo from-ext\n')
o = lines_of(['source sc.txt > out.txt', 'echo back', '/bin/true > a1 > a2', 'echo b > f9 > f10',
              '/bin/ls -l /proc/self/fd > fdlist'], cwd=c)
T.check("source with > keeps the outer redirection", ANSI.sub('', read(c, 'out.txt') or '') == 'from-script\nfrom-ext\n'
        and 'from-script' not in o and 'back' in o, (o, read(c, 'out.txt')))
T.check("repeated > creates every file", all(has(c, n) for n in ('a1', 'a2', 'f9', 'f10')), os.listdir(c))
fds = [l for l in (read(c, 'fdlist') or '').split('\n') if '->' in l]
T.check("no stray descriptors reach the child", len(fds) == 4 and sum('fdlist' in l for l in fds) == 1, fds)

c = T.tmpdir()
o = lines_of(['for i in 1 2 3 4 5 6 7 8; do echo x > a$i > b$i; done', '/bin/ls /proc/$$/fd | /usr/bin/wc -l'], cwd=c)
T.check("redirections do not leak descriptors in the shell", o and o[-1].isdigit() and int(o[-1]) < 8, o)

# ---------------------------------------------------------------- builtin arguments
c = T.tmpdir()
os.mkdir(os.path.join(c, 'a b'))
write(c, 'a b.txt', 'spaced\n'); write(c, 'f1', 'one\n'); write(c, 'needle file', 'a b c\nzzz\n')
o = lines_of(['cd "a b"; pwd', 'cd ..', 'mkdir "x y"', 'copy "a b.txt" "c d.txt"', 'cat "c d.txt"', 'copy f1 x y z',
              'move "c d.txt" "e f.txt"', 'del "e f.txt"', 'ls "a b"', 'grep "a b" "needle file"',
              'set A="hello world"', 'echo "[$A]"', "alias ll='echo LONG'", 'll', 'rename f1 "g 1"', 'echo ok'], cwd=c)
T.check("cd with a quoted name", o[0] == c + '/a b', o)
T.check("mkdir with a quoted name has no quote characters", os.path.isdir(os.path.join(c, 'x y')), os.listdir(c))
T.check("copy/move/del with quoted names", read(c, 'c d.txt') is None and read(c, 'e f.txt') is None
        and 'spaced' in o and not has(c, '"c d.txt"'), (o, os.listdir(c)))
T.check("copy with three words is refused", not has(c, 'x y z'), os.listdir(c))
T.check("grep with a quoted pattern", 'a b c' in ''.join(o), o)
T.check("set keeps value, not the quotes", '[hello world]' in o, o)
T.check("alias with quoted value", 'LONG' in o, o)
T.check("rename with quoted target", has(c, 'g 1') and not has(c, 'f1'), os.listdir(c))

# ---------------------------------------------------------------- pipelines and builtins
c = T.tmpdir()
o = lines_of(['echo marker1', 'history | grep marker', 'set ZZ=1', 'set | grep ZZ', "alias lc='ls | wc -l'", 'alias | cat',
              'set RE="a|b"', 'echo $RE', 'title "a|b"', 'cd "/tmp|x"; echo st=$?', 'cd / | cat; pwd'], cwd=c)
T.check("history | grep", any('marker' in l for l in o), o)
T.check("set | grep", 'ZZ=1' in o, o)
T.check("alias with | in its value", 'lc=ls | wc -l' in o, o)
T.check("quoted | does not make a pipeline", 'a|b' in o and not any('command not found' in l for l in o), o)
T.check("builtin as pipeline stage runs in a subshell", c in o, o)

# ---------------------------------------------------------------- alias text is syntax
c = T.tmpdir()
o = lines_of(["alias p='echo $HOME'", 'p', "alias q='echo $(echo sub)'", 'q x'], cwd=c, home=c)
T.check("alias value is expanded when used", o[0] == c and o[1] == 'sub x', o)

# ---------------------------------------------------------------- echo
c = T.tmpdir()
o = lines_of(['echo "it\'s" ok', "echo 'say \"hi\"'", 'echo a     b', 'echo "" z', 'echo -n x; echo y',
              'echo -e "\\x41 \\0101 \\t|"', 'echo -en "a\\nb"; echo', 'echo -- -n', 'echo -e "x\\cy"; echo z'], cwd=c)
T.check("echo keeps inner quotes", o[0] == "it's ok" and o[1] == 'say "hi"', o)
T.check("echo collapses blanks like sh", o[2] == 'a b' and o[3] == ' z', o)
T.check("echo -n and combined flags", o[4] == 'xy' and o[6] == 'a' and o[7] == 'b', o)
T.check("echo -e escapes", o[5] == 'A A \t|', o)
T.check("echo \\c stops output", 'xz' in o or 'x' in o, o)

# ---------------------------------------------------------------- sh -c with quoted redirection (bench/trace use it)
c = T.tmpdir()
o, e, st, _ = sh(['sh -c "echo run >> f"', 'bench -n 2 sh -c "echo run >> g"'], cwd=c)
T.check("quoted >> inside sh -c", read(c, 'f') == 'run\n' and 'Syntax' not in e + ''.join(o) and not has(c, 'f"'), (o, e, os.listdir(c)))

# ---------------------------------------------------------------- background and arithmetic still work
c = T.tmpdir()
o = lines_of(['x=5; echo $((x+1)) $((2*3))', '/bin/sleep 0 &', 'echo "a &"', "echo 'b &'", 'echo c\\&'], cwd=c)
T.check("arithmetic after the change", o[0] == '6 6', o)
T.check("a quoted or escaped & is not a background request", 'a &' in o and 'b &' in o and 'c&' in o, o)

T.cleanup()
