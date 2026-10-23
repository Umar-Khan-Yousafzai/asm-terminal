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

T.cleanup()
