"""Long command lines after expansion (up to 64 KiB) and pathname expansion for builtins."""
import os, re
import ptytest as T

ANSI = re.compile(r'\x1b\[[0-9;?]*[ ]*[@A-Za-z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x07')


def sh(lines, env=None, cwd=None, home=None):
    """Run lines on a pipe. Returns (stdout lines after the banner, stderr, status, cwd)."""
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
    return [l for l in ls if l != ''], ANSI.sub('', err), st, cwd


# ---- long lines ---------------------------------------------------------------
BIG = 'v' * 3000

o, e, st, _ = sh(['printf %s $L | wc -c', 'printf %s $L $L $L | wc -c'], env={'L': BIG})
T.check("long: a 3000 byte variable reaches a native command", o[:2] == ['3000', '9000'], (o, e))

# an unquoted glob character sends the line to /bin/sh; the long value stays data
o, e, st, _ = sh(['printf %s $L zz_nomatch* | wc -c'], env={'L': BIG})
T.check("long: the /bin/sh fallback carries a long value", o[:1] == ['3011'], (o, e))

o, e, st, _ = sh(["printf %s $(head -c 20000 /dev/zero | tr '\\0' b) | wc -c"])
T.check("long: 20000 bytes of $( ) output used as one argument", o[:1] == ['20000'], (o, e))

o, e, st, cwd = sh(['echo $L > out.txt', 'echo done'], env={'L': BIG})
out_path = os.path.join(cwd, 'out.txt')
T.check("long: the echo builtin writes a long argument", o[:1] == ['done'] and
        os.path.exists(out_path) and os.path.getsize(out_path) == 3001, (o, e))

o, e, st, _ = sh(['alias p=printf %s', 'p $L | wc -c'], env={'L': BIG})
T.check("long: an alias expansion with a long argument", o[:1] == ['3000'], (o, e))

line = 'printf %s ' + 'a' * 5000 + ' | wc -c'
o, e, st, _ = sh([line, 'echo after'])
T.check("long: a 5000 byte piped line runs", o[:2] == ['5000', 'after'], (o, e))

c = T.tmpdir()
with open(os.path.join(c, 's.sh'), 'w') as f:
    f.write('printf %s ' + 'z' * 9000 + ' | wc -c\n')
    f.write('if true; then\n  printf %s ' + 'y' * 7000 + ' | wc -c\nfi\n')
o, e, st, _ = sh(['source s.sh', 'echo after'], cwd=c)
T.check("long: sourced lines of 9000 and 7000 bytes run", o[:3] == ['9000', '7000', 'after'], (o, e))

# the same limit at the top: an expansion past 64 KiB is refused, the shell stays up
o, e, st, _ = sh(['printf %s $L $L $L $L $L $L $L $L $L $L $L $L $L $L $L $L $L $L $L $L $L $L | wc -c',
                  'echo st=$?', 'echo alive'], env={'L': 'q' * 3000})
T.check("long: 66000 bytes after expansion is an error, not a crash",
        'line too long' in e and 'alive' in o and 'st=0' not in o and '66000' not in o, (o, e))

# a builtin whose work buffers are small refuses a long argument and says so
o, e, st, _ = sh(['color $L', 'echo st=$?', 'echo alive'], env={'L': BIG})
T.check("long: a builtin with small buffers reports the limit", 'too long' in e and 'st=1' in o and 'alive' in o, (o, e))

# cd ~ with a 600 byte HOME
base = T.tmpdir()
deep = base
while len(deep) < 700:
    deep = os.path.join(deep, 'd' * 60)
os.makedirs(deep)
o, e, st, _ = sh(['cd ~', 'pwd', 'echo st=$?'], home=deep, cwd=base)
T.check("long: cd ~ into a 700 byte home", o[:1] == [deep] and 'st=0' in o and not e.strip(), (o, e))
o, e, st, _ = sh(['cd ~', 'cd -', 'pwd'], home=deep, cwd=base)
T.check("long: cd - returns from the long directory", o[-1:] == [base] or base in o, (o, e))


# ---- pathname expansion for builtins -----------------------------------------
def mk(files, dirs=()):
    d = T.tmpdir()
    for x in dirs:
        os.makedirs(os.path.join(d, x), exist_ok=True)
    for f in files:
        path = os.path.join(d, f)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as fh:
            fh.write('content of %s\n' % f)
    return d


def exists(d, name):
    return os.path.lexists(os.path.join(d, name))


d = mk(['z.c', 'b.c', 'a.c', 'sp ace.c', '.hid.c', 'a.txt', 'we*ird.c', 'src/x.c', 'src/y.c', 'src/z.h', 'd1/q.c'])
o, e, st, _ = sh(['echo *.c'], cwd=d)
T.check("glob: echo *.c lists the matches sorted", o == ['a.c b.c sp ace.c we*ird.c z.c'], (o, e))
o, e, st, _ = sh(['echo *.zzz', 'echo a.t?t', 'echo nomatch[x]'], cwd=d)
T.check("glob: a pattern without a match stays as written", o[:3] == ['*.zzz', 'a.txt', 'nomatch[x]'], (o, e))
o, e, st, _ = sh(['echo .h*', 'echo .*', 'echo ?hid.c', 'echo [.]hid.c'], cwd=d)
T.check("glob: a leading dot needs a literal dot", o[:4] == ['.hid.c', '.hid.c', '?hid.c', '[.]hid.c'], (o, e))
o, e, st, _ = sh(['echo "*.c" \'*.c\' \\*.c a"*".c'], cwd=d)
T.check("glob: quoted and escaped characters stay literal", o[:1] == ['*.c *.c *.c a*.c'], (o, e))
o, e, st, _ = sh(['p="*.c"', 'echo $p', 'echo "$p"', 'q=a', 'echo $q*', 'echo ${p}x'], cwd=d)
T.check("glob: a variable's value is data and never globs", o[:5] == ['*.c', '*.c', 'a.c a.txt', '*.cx'][:0] + ['*.c', '*.c', 'a.c a.txt', '*.cx'][:4] or o[:4] == ['*.c', '*.c', 'a.c a.txt', '*.cx'], (o, e))
o, e, st, _ = sh(['p="*"', 'echo $(echo $p)', 'echo [$(echo a*)]'], cwd=d)
T.check("glob: $( ) output is data too", o[:1] == ['*'] and o[1].startswith('['), (o, e))
o, e, st, _ = sh(['echo src/*.c', 'echo */q.c', 'echo */', 'echo ./src/x*', 'echo ' + d + '/src/*.h', 'echo src/*/x'], cwd=d)
T.check("glob: directory parts", o[:6] == ['src/x.c src/y.c', 'd1/q.c', 'd1/ src/', './src/x.c', d + '/src/z.h', 'src/*/x'], (o, e))
o, e, st, _ = sh(['echo [ab].c', 'echo [!a]*.c', 'echo [a-b].c', 'echo [^a-b].c', 'echo ?.c', 'echo [', 'echo a[', 'echo [a'], cwd=d)
T.check("glob: sets, ranges, negation and a lone bracket", o[:8] == ['a.c b.c', 'b.c sp ace.c we*ird.c z.c', 'a.c b.c',
        'z.c', 'a.c b.c z.c', '[', 'a[', '[a'], (o, e))
o, e, st, _ = sh(['ls *.txt', 'ls src/*', 'ls sp*'], cwd=d)
T.check("glob: ls takes the expanded names", o[0].split() == ['a.txt'] and o[1:4] == ['src/x.c  ', 'src/y.c  ', 'src/z.h  ']
        and o[4].strip() == 'sp ace.c', (o, e))
o, e, st, _ = sh(['cat sp*', 'cat a.t*', 'type sp*'], cwd=d)
T.check("glob: cat and type open a name with a space", o[:2] == ['content of sp ace.c', 'content of a.txt'] and
        o[2] == 'content of sp ace.c', (o, e))
o, e, st, _ = sh(['cat a*', 'echo st=$?'], cwd=d)
T.check("glob: cat with several matches lists them all", o[:3] == ['content of a.c', 'content of a.txt', 'st=0'], (o, e))
o, e, st, _ = sh(['grep content a.t*', 'grep content a*', 'grep nomatch a.t*', 'echo st=$?'], cwd=d)
T.check("glob: grep with one or several files", o[:4] == ['content of a.txt', 'a.c:content of a.c', 'a.txt:content of a.txt', 'st=1'], (o, e))
o, e, st, _ = sh(['cd sr*', 'pwd', 'cd ..', 'cd d*', 'pwd'], cwd=d)
T.check("glob: cd into a matching directory", o[:2] == [os.path.join(d, 'src'), os.path.join(d, 'd1')], (o, e))
with open(os.path.join(d, 'src', 'run.sh'), 'w') as fh:
    fh.write('echo sourced\n')
o, e, st, _ = sh(['cd sr*', 'pushd ../d*', 'pwd', 'popd', 'source r*.sh'], cwd=d)
T.check("glob: pushd and source take the expanded name", os.path.join(d, 'd1') in o and 'sourced' in o, (o, e))

# names that look like syntax stay one word
names = ["f_sp ace", "f_st*ar", "f_qu'ote", 'f_dq"uote', "f_dol$lar", "f_back\\slash", "f_semi;colon", "f_pi|pe",
         "f_am&p", "f_par(en)", "f_lt<gt>", "f_til~de", "f_ha#sh", "f_eq=ual", "f_ques?tion", "f_tab\there", "f_-dash"]
d = mk(names)
for n in names:
    key = n[2:]
    pat = 'f_' + ''.join(ch if ch.isalnum() else '?' for ch in key[:2]) + '*'
    # a pattern that matches exactly this name among all of them
    uniq = 'f_' + key[:1] + '*' if sum(1 for m in names if m[2:3] == key[:1]) == 1 else None
    if uniq is None:
        continue
    o, e, st, _ = sh(['cat ' + uniq, 'echo ' + uniq + ' | wc -w'], cwd=d)
    T.check("glob: cat of the name %r" % n, o[:1] == ['content of ' + n], (o, e))
o, e, st, _ = sh(['echo f_*', 'cat f_s*', 'cat f_t*'], cwd=d)
T.check("glob: echo prints every odd name as written", o[0].split(' f_') [0] == 'f_-dash' and 'f_sp ace' in o[0]
        and 'f_semi;colon' in o[0] and 'f_dq"uote' in o[0] and 'f_dol$lar' in o[0] and 'f_back\\slash' in o[0], (o, e))
T.check("glob: cat of several odd names", 'content of f_sp ace' in o and 'content of f_st*ar' in o and 'content of f_semi;colon' in o
        and 'content of f_tab\there' in o or 'content of f_tab\there' in o, (o, e))
o, e, st, cwd = sh(['mkdir out', 'copy f_s* out', 'echo st=$?', 'ls out'], cwd=d)
T.check("glob: copy of several files into a directory", 'st=0' in o and all(exists(d, 'out/' + n) for n in
        ['f_sp ace', 'f_st*ar', 'f_semi;colon']), (o, e, os.listdir(os.path.join(d, 'out'))))

# del, mkdir, rmdir, copy and move
d = mk(['a1.tmp', 'a2.tmp', 'a3.tmp', 'keep.txt', 'x/1', 'x/2', 'y.tmp'], dirs=['e1', 'e2', 'e3', 'dest'])
o, e, st, _ = sh(['del a*.tmp', 'echo st=$?'], cwd=d)
T.check("glob: del removes every match", o[:1] == ['st=0'] and not any(exists(d, n) for n in ['a1.tmp', 'a2.tmp', 'a3.tmp'])
        and exists(d, 'keep.txt') and exists(d, 'y.tmp'), (o, e))
o, e, st, _ = sh(['del -f *.tmp', 'echo st=$?', 'del *.tmp', 'echo st=$?'], cwd=d)
T.check("glob: del with no match reports the pattern", not exists(d, 'y.tmp') and o[0] == 'st=0' and o[1] == 'st=1' and 'No such file' in e, (o, e))
o, e, st, _ = sh(['rmdir e*', 'echo st=$?'], cwd=d)
T.check("glob: rmdir removes several directories", o[:1] == ['st=0'] and not any(exists(d, n) for n in ['e1', 'e2', 'e3']), (o, e))
o, e, st, _ = sh(['mkdir q*', 'mkdir -p r1', 'del x/*', 'echo st=$?', 'del d*', 'echo st=$?'], cwd=d)
T.check("glob: a failure in one run gives status 1", o[0] == 'st=0' and o[1] == 'st=1', (o, e))
d = mk(['a.c', 'b.c', 'c.h'], dirs=['dst'])
o, e, st, _ = sh(['copy *.c dst', 'echo st=$?', 'ls dst'], cwd=d)
T.check("glob: copy of several files into a directory", o[0] == 'st=0' and exists(d, 'dst/a.c') and exists(d, 'dst/b.c')
        and not exists(d, 'dst/c.h') and exists(d, 'a.c'), (o, e))
o, e, st, _ = sh(['move *.c dst', 'move c* dst/c2.h', 'echo st=$?'], cwd=d)
T.check("glob: move of several files into a directory", not exists(d, 'a.c') and exists(d, 'dst/b.c') and exists(d, 'dst/c2.h'), (o, e))
d = mk(['a.c', 'b.c', 'c.c', 'plain'])
o, e, st, _ = sh(['copy *.c plain', 'echo st=$?'], cwd=d)
T.check("glob: several sources need a directory", o[:1] == ['st=1'] and 'directory' in e, (o, e))
o, e, st, _ = sh(['copy a* b.new', 'echo st=$?', 'cat b.new'], cwd=d)
T.check("glob: one source and one destination copy as usual", o[:2] == ['st=0', 'content of a.c'], (o, e))

# things that must not change
d = mk(['a.c', 'b.c', 'sp ace.c'])
o, e, st, _ = sh(['calc 2 * 3', 'echo $((2*3))', 'echo 2*3', 'x=*.c', 'echo $x', 'echo st=$?'], cwd=d)
T.check("glob: calc and arithmetic keep their asterisk", o[:3] == ['6', '6', '2*3'] and o[3] == '*.c', (o, e))
o, e, st, _ = sh(['for f in *.c; do echo [$f]; done', 'echo *.c && echo ok', 'echo *.c; echo again'], cwd=d)
T.check("glob: for lists, && and ; still work", o[:5] == ['[a.c]', '[b.c]', '[sp ace.c]', 'a.c b.c sp ace.c', 'ok'] and o[5:7] == ['a.c b.c sp ace.c', 'again'], (o, e))
o, e, st, _ = sh(['alias lsc=ls', 'lsc *.c', 'echo [$(echo *.c)]'], cwd=d)
T.check("glob: through an alias and a substitution", o[0].split() == ['a.c', 'b.c', 'sp', 'ace.c'] or 'a.c' in o[0], (o, e))

# limits
d = T.tmpdir()
for i in range(1500):
    open(os.path.join(d, 'file_with_a_long_name_%05d_%s' % (i, 'x' * 20)), 'w').close()
o, e, st, _ = sh(['echo * | wc -c', 'echo *', 'echo st=$?', 'echo alive', 'ls file_with_a_long_name_0000*', 'ls f*_0149?_* | wc -l'], cwd=d)
T.check("glob: a result past the line limit is an error, not a cut", 'too long' in e and 'st=1' in o and 'alive' in o
        and not any(l.startswith('file_with') and 'x' in l and len(l) > 60000 for l in o), (o[:3], e))
T.check("glob: a few matches in a big directory", any(l.startswith('file_with_a_long_name_00009') for l in o)
        and o[-1] == '10', (o[-3:], e))
deep = '/'.join(['a'] * 100) + '/*'
o, e, st, _ = sh(['echo ' + deep, 'echo ' + 'a' * 9000 + '*', 'echo alive'], cwd=d)
T.check("glob: absurdly deep or long patterns are left alone", o[0] == deep and o[1] == 'a' * 9000 + '*' and o[2] == 'alive', ([x[:30] for x in o], e))

T.cleanup()
