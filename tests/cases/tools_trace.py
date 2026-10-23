import os, re, sys, time, subprocess
import ptytest as T

# trace runs a helper under ptrace; skip everything if the sandbox we are
# in does not allow ptrace at all.
home = T.tmpdir()
work = T.tmpdir()


def rs(text, **kw):
    kw.setdefault('timeout', 25)
    kw.setdefault('home', home)
    try:
        return T.run_script(text, **kw)
    except subprocess.TimeoutExpired:
        return '', 'TIMEOUT', -1


def skip(name, why):
    print("ok\t%s (skipped: %s)" % (name, why))


out, err, st = rs('trace /bin/true\nexit\n')
if 'cannot trace' in err or 'cannot trace' in out:
    skip('trace tests', 'ptrace is not permitted here')
    T.cleanup()
    sys.exit(0)

# --- own tracee only: a background job neither delays trace nor gets reaped
out, err, st = rs('sleep 6 &\n/bin/date +T1=%s\ntrace /bin/true\n/bin/date +T2=%s\njobs\nexit\n', timeout=20)
t1 = re.search(r'T1=(\d+)', out)
t2 = re.search(r'T2=(\d+)', out)
T.check('trace does not wait for background jobs', t1 and t2 and int(t2.group(1)) - int(t1.group(1)) <= 2, out[-300:])
T.check('trace leaves the background job in the job table', 'sleep' in out.split('T2=')[-1] and 'No active background jobs' not in out, out[-300:])

# --- exit status and summary
out, err, st = rs('trace sh -c "exit 7"\necho st=$?\nexit\n')
T.check('trace passes on the exit status', 'st=7' in out, out + err)
out, err, st = rs('trace /bin/true\nexit\n')
T.check('trace does not list its own /bin/sh wrapper', 'exec     /bin/sh' not in err and 'exec     /bin/true' in err and '1 programs' in err, err)

# --- escapes in names cannot forge lines or move the cursor
evil = work + '/evil.py'
open(evil, 'w').write(
    'import os\n'
    'p = "%s/Ftr_a\\n  delete   etc_passwd\\n  connect  1.2.3.4:443\\n  exec     evil"\n'
    'open(p, "w").close(); os.unlink(p)\n'
    'q = "%s/Ftr_b\\r\\x1b[2K\\x1b[1A\\x1b]0;pwn\\x07\\\\end"\n'
    'open(q, "w").close(); os.unlink(q)\n'
    'r = b"%s/caf\\xc3\\xa9-\\xff"\n'
    'open(r, "wb").close(); os.unlink(r)\n' % (work, work, work))
out, err, st = rs('trace python3 %s\nexit\n' % evil)
lines = err.split('\n')
T.check('trace: no forged "delete" line', not any(l.startswith('  delete   etc_passwd') for l in lines), err[-600:])
T.check('trace: no forged "connect" line', not any(l.startswith('  connect  1.2.3.4') for l in lines), err[-600:])
T.check('trace: no raw ESC, CR or BEL on stderr', not re.search('[\x1b\r\x07]', err), repr(err[-300:]))
T.check('trace: newline shown escaped', '\\x0A  delete   etc_passwd' in err, err[-600:])
T.check('trace: backslash shown escaped', '\\x5Cend' in err, err[-600:])
T.check('trace: valid UTF-8 kept, bad bytes escaped', 'caf\u00e9-\\xFF' in err, err[-600:])

# --- hide list: no ".." bypass, boundary aware, relative names resolved
sysfile = None
try:
    for e in sorted(os.scandir('/usr/lib'), key=lambda e: e.name):
        if e.is_file(follow_symlinks=False) and os.access(e.path, os.R_OK):
            sysfile = e.name
            break
except OSError:
    pass
rd = work + '/rd.py'
open(rd, 'w').write(
    'import sys\n'
    'for p in sys.argv[1:]:\n'
    '    try: open(p, "rb").read(1)\n'
    '    except OSError: pass\n')
out, err, st = rs('trace python3 %s /usr/lib/../../etc/hostname /proc/self/environ\nexit\n' % rd)
T.check('trace: a name with ".." is never hidden', 'read     /usr/lib/../../etc/hostname' in err, err[-500:])
T.check('trace: /proc/self/environ is shown', 'read     /proc/self/environ' in err, err[-500:])
if sysfile:
    full = '/usr/lib/' + sysfile
    out, err, st = rs('trace python3 %s %s\nexit\n' % (rd, full))
    T.check('trace: a system library file is hidden by default', 'read     ' + full not in err and 'hidden' in err, err[-500:])
    out, err, st = rs('trace -a python3 %s %s\nexit\n' % (rd, full))
    T.check('trace -a shows it', 'read     ' + full in err, err[-500:])
    out, err, st = rs('trace python3 %s ///usr//lib/./%s\nexit\n' % (rd, sysfile))
    T.check('trace: "//" and "." are folded before matching', 'read     ///usr' not in err and 'hidden' in err, err[-500:])
    out, err, st = rs('trace sh -c "cd /usr/lib && python3 %s %s"\nexit\n' % (rd, sysfile))
    T.check('trace: relative names are resolved against the cwd', ('read     ' + sysfile) not in err, err[-500:])
else:
    skip('trace: hide list checks on /usr/lib', 'no file in /usr/lib')

# --- more system calls
more = work + '/more.py'
open(more, 'w').write(
    'import os, socket, ctypes\n'
    'd = %r\n'
    'open(d + "/f", "w").write("x")\n'
    'os.link(d + "/f", d + "/hard")\n'
    'os.symlink("target-name", d + "/sym")\n'
    'os.truncate(d + "/f", 0)\n'
    'libc = ctypes.CDLL(None, use_errno=True)\n'
    'how = (ctypes.c_uint64 * 3)(os.O_WRONLY | os.O_CREAT, 0o644, 0)\n'
    'fd = libc.syscall(437, -100, (d + "/viaopenat2").encode(), how, 24)\n'
    'if fd >= 0: os.close(fd)\n'
    'u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n'
    'u.sendto(b"x", ("127.0.0.1", 9))\n'
    'u.connect(("127.0.0.1", 10)); u.close()\n'
    'try:\n'
    '    v = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM); v.connect(("::1", 11)); v.close()\n'
    'except OSError: print("no-v6")\n'
    's = socket.socket(socket.AF_UNIX); s.bind(d + "/sock"); s.listen(1)\n'
    'c = socket.socket(socket.AF_UNIX); c.connect(d + "/sock")\n'
    'a = socket.socket(socket.AF_UNIX); a.bind("\\0abstract-name"); a.listen(1)\n'
    'c2 = socket.socket(socket.AF_UNIX); c2.connect("\\0abstract-name")\n' % work)
out, err, st = rs('trace python3 %s\nexit\n' % more)
T.check('trace shows link', re.search(r'link     %s/f -> %s/hard|link     %s/hard' % (work, work, work), err) is not None, err[-900:])
T.check('trace shows symlink', 'symlink  %s/sym -> target-name' % work in err, err[-900:])
T.check('trace shows truncate', 'write    %s/f\n' % work in err, err[-900:])
T.check('trace shows openat2', 'write    %s/viaopenat2' % work in err, err[-900:])
T.check('trace shows a UDP sendto', 'send     127.0.0.1:9' in err, err[-900:])
T.check('trace shows a UDP connect', 'connect  127.0.0.1:10' in err, err[-900:])
if 'no-v6' not in out:
    T.check('trace prints the whole IPv6 address', 'connect  [0:0:0:0:0:0:0:1]:11' in err, err[-900:])
T.check('trace shows a unix socket path in full', 'connect  unix:%s/sock' % work in err, err[-900:])
T.check('trace shows an abstract unix socket', 'connect  unix:@abstract-name' in err, err[-900:])

# --- 32-bit entry point is flagged
ia = work + '/ia32.py'
open(ia, 'w').write(
    'import ctypes, mmap\n'
    'm = mmap.mmap(-1, 4096, prot=mmap.PROT_READ | mmap.PROT_WRITE | mmap.PROT_EXEC)\n'
    'm.write(b"\\xb8\\x14\\x00\\x00\\x00\\xcd\\x80\\xc3")\n'
    'f = ctypes.CFUNCTYPE(ctypes.c_long)(ctypes.addressof(ctypes.c_char.from_buffer(m)))\n'
    'print("ia32=%d" % (f() & 0xffffffff))\n')
out, err, st = rs('python3 %s\nexit\n' % ia)
m = re.search(r'ia32=(\d+)', out)
if m and int(m.group(1)) == 0xffffffda:
    skip('trace: 32-bit warning', 'ia32 emulation is off')
else:
    out, err, st = rs('trace python3 %s\nexit\n' % ia)
    T.check('trace warns about 32-bit system calls', '32-bit system calls' in err, err[-400:])

# --- the terminal comes back after a trace
s = T.Sess(home=T.tmpdir())
s.settle()
s.run('trace /bin/true')
s.run('echo after-trace')
T.check('trace: prompt works afterwards', 'after-trace' in s.screen(), s.screen()[-300:])
s.close()

T.cleanup()
