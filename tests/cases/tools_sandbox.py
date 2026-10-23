import os, sys, subprocess, ctypes, struct, tempfile, mmap
import ptytest as T

# Escape attempts run inside "sandbox"; each prints name=RESULT. The victim
# directory must lie outside /tmp, which the sandbox may write to.

PROBE = r"""
import ctypes, os, sys, socket, errno
libc = ctypes.CDLL(None, use_errno=True)
out = sys.argv[1]
def r(name, fn):
    try:
        v = fn()
        print("%s=ok" % name)
    except OSError as e:
        print("%s=%s" % (name, errno.errorcode.get(e.errno, e.errno)))
def sc(nr, *a):
    ctypes.set_errno(0)
    v = libc.syscall(nr, *[ctypes.c_long(x) for x in a])
    if v < 0:
        raise OSError(ctypes.get_errno(), "")
    return v
victim = out + "/victim"
r("open_w", lambda: os.close(os.open(victim, os.O_WRONLY)))
r("creat", lambda: os.close(os.open(out + "/new", os.O_CREAT | os.O_WRONLY, 0o644)))
r("truncate", lambda: os.truncate(victim, 0))
r("chmod", lambda: os.chmod(victim, 0o777))
r("chown", lambda: os.chown(victim, 1234, 1234))
r("utime_explicit", lambda: os.utime(victim, (1000, 1000)))
r("utime_now", lambda: os.utime(victim, None))
r("setxattr", lambda: os.setxattr(victim, "user.x", b"y"))
r("link", lambda: os.link(victim, out + "/l"))
r("rename", lambda: os.rename(victim, out + "/v3"))
r("unlink", lambda: os.unlink(victim))
def fchmod_ro():
    fd = os.open(victim, os.O_RDONLY)
    try:
        os.fchmod(fd, 0o777)
    finally:
        os.close(fd)
r("fchmod_rdonly_fd", fchmod_ro)
for nm, fam in (("inet", socket.AF_INET), ("inet6", socket.AF_INET6), ("unix", socket.AF_UNIX), ("netlink", 16), ("packet", 17), ("vsock", 40)):
    r("sock_" + nm, lambda fam=fam: socket.socket(fam, socket.SOCK_STREAM if fam in (2, 10, 1, 40) else socket.SOCK_RAW).close())
r("socketpair", lambda: [s.close() for s in socket.socketpair()])
r("io_uring_setup", lambda: sc(425, 8, 0))
r("ptrace_parent", lambda: sc(101, 16, os.getppid(), 0, 0))
r("process_vm_readv", lambda: sc(310, os.getppid(), 0, 0, 0, 0, 0))
r("unshare_user", lambda: sc(272, 0x10000000))
r("mount", lambda: sc(165, 0, 0, 0, 0, 0))
def tiocsti():
    import fcntl
    fcntl.ioctl(0, 0x5412, b"X")
if os.isatty(0):
    r("tiocsti", tiocsti)
r("dev_null_w", lambda: os.close(os.open("/dev/null", os.O_WRONLY)))
r("dev_zero_w", lambda: os.close(os.open("/dev/zero", os.O_WRONLY)))
r("dev_full_w", lambda: os.close(os.open("/dev/full", os.O_WRONLY)))
r("dev_shm_creat", lambda: os.close(os.open("/dev/shm/asm_sbx_probe_%d" % os.getpid(), os.O_CREAT | os.O_WRONLY)))
r("tmp_creat", lambda: os.close(os.open("/tmp/asm_sbx_ok_%d" % os.getpid(), os.O_CREAT | os.O_WRONLY)))
try: os.unlink("/tmp/asm_sbx_ok_%d" % os.getpid())
except OSError: pass
r("kill_shell", lambda: os.kill(int(sys.argv[2]), 17))
r("fork", lambda: os.waitpid(os.fork() or os._exit(0), 0))
"""

IA32 = r"""
import ctypes, mmap
m = mmap.mmap(-1, 4096, prot=mmap.PROT_READ | mmap.PROT_WRITE | mmap.PROT_EXEC)
m.write(b"\xb8\x14\x00\x00\x00\xcd\x80\xc3")
f = ctypes.CFUNCTYPE(ctypes.c_long)(ctypes.addressof(ctypes.c_char.from_buffer(m)))
print("ia32=%d" % (f() & 0xffffffff))
"""


def rs(text, **kw):
    # run_script that reports a hung shell (for instance one stopped by a
    # ptrace attach) as a failure instead of aborting the file
    kw.setdefault('timeout', 12)
    try:
        return T.run_script(text, **kw)
    except subprocess.TimeoutExpired:
        return '', 'TIMEOUT', -1


def skip(name, why):
    print("ok\t%s (skipped: %s)" % (name, why))


def parse(out):
    d = {}
    for ln in out.replace('\r', '').split('\n'):
        ln = ln.strip()
        if '=' in ln and ' ' not in ln:
            k, v = ln.rsplit('=', 1)
            d[k.split(']')[-1].split('\x07')[-1]] = v
    return d


def outside_tmp_dir():
    try:
        d = tempfile.mkdtemp(prefix='asmsbx-', dir='/var/tmp')
    except OSError:
        return None
    T._tmp.append(d)
    if os.path.realpath(d).startswith('/tmp/'):
        return None
    return d


def landlock_abi():
    libc = ctypes.CDLL(None, use_errno=True)
    return libc.syscall(444, 0, 0, 1)


work = T.tmpdir()
open(work + '/probe.py', 'w').write(PROBE)
open(work + '/ia32.py', 'w').write(IA32)
vic = outside_tmp_dir()
abi = landlock_abi()
home = T.tmpdir()


def fresh_victim():
    open(vic + '/victim', 'w').write('victim-data')
    os.chmod(vic + '/victim', 0o644)
    for n in os.listdir(vic):
        if n != 'victim':
            os.unlink(vic + '/' + n)


def probe(opts='', extra=''):
    fresh_victim()
    out, err, st = rs('sandbox %spython3 %s/probe.py %s $$\nexit\n' % (opts, work, vic), home=home)
    return parse(out), out + err, st


if vic is None or abi < 1:
    skip('sandbox escape attempts', 'no Landlock or no folder outside /tmp')
else:
    # Baseline: the same calls succeed without the sandbox, so the checks mean something
    fresh_victim()
    out, err, st = rs('python3 -c "import os, socket; os.chmod(\'%s/victim\', 0o600); socket.socket().close(); print(\'base-ok\')"\nexit\n' % vic, home=home)
    T.check('sandbox baseline: chmod and sockets work unsandboxed', 'base-ok' in out, out + err)
    fresh_victim()

    r, raw, st = probe()
    ok = lambda n, c, d='': T.check('sandbox: ' + n, c, d)
    ok('probe ran', 'open_w' in r, raw)
    ok('no write open outside /tmp', r.get('open_w') == 'EACCES', r.get('open_w'))
    ok('no file creation outside /tmp', r.get('creat') == 'EACCES' and not os.path.exists(vic + '/new'))
    ok('victim content untouched', open(vic + '/victim').read() == 'victim-data')
    ok('no link/rename/unlink outside', r.get('link') == r.get('rename') == r.get('unlink') == 'EACCES', r)
    ok('truncate(2) denied', r.get('truncate') == 'EPERM', r.get('truncate'))
    ok('chmod denied', r.get('chmod') == 'EPERM' and os.stat(vic + '/victim').st_mode & 0o777 == 0o644, r.get('chmod'))
    ok('chown denied', r.get('chown') == 'EPERM', r.get('chown'))
    ok('explicit utimes denied', r.get('utime_explicit') == 'EPERM', r.get('utime_explicit'))
    ok('setxattr denied', r.get('setxattr') == 'EPERM', r.get('setxattr'))
    ok('fchmod on a read-only fd denied', r.get('fchmod_rdonly_fd') == 'EPERM', r.get('fchmod_rdonly_fd'))
    ok('touch-style utimensat(NULL) still works', r.get('utime_now') == 'ok', r.get('utime_now'))
    for fam in ('inet', 'inet6', 'unix', 'netlink', 'packet', 'vsock'):
        ok('socket(%s) denied' % fam, r.get('sock_' + fam) == 'EPERM', r.get('sock_' + fam))
    ok('socketpair stays usable', r.get('socketpair') == 'ok', r.get('socketpair'))
    ok('io_uring denied', r.get('io_uring_setup') == 'EPERM', r.get('io_uring_setup'))
    ok('ptrace denied', r.get('ptrace_parent') == 'EPERM', r.get('ptrace_parent'))
    ok('process_vm_readv denied', r.get('process_vm_readv') == 'EPERM', r.get('process_vm_readv'))
    ok('unshare denied', r.get('unshare_user') == 'EPERM', r.get('unshare_user'))
    ok('mount denied', r.get('mount') == 'EPERM', r.get('mount'))
    ok('/dev/null and /dev/zero writable', r.get('dev_null_w') == 'ok' and r.get('dev_zero_w') == 'ok', r)
    if os.path.exists('/dev/full'):
        ok('rest of /dev not writable', r.get('dev_full_w') == 'EACCES', r.get('dev_full_w'))
    ok('/dev/shm not writable', r.get('dev_shm_creat') == 'EACCES', r.get('dev_shm_creat'))
    ok('/tmp stays writable', r.get('tmp_creat') == 'ok', r.get('tmp_creat'))
    ok('fork works', r.get('fork') == 'ok', r.get('fork'))
    if abi >= 6:
        ok('signals to the shell denied', r.get('kill_shell') == 'EPERM', r.get('kill_shell'))
    else:
        skip('sandbox: signals to the shell denied', 'Landlock ABI %d < 6' % abi)

    # -n keeps IPv4/IPv6 only
    r, raw, st = probe('-n ')
    ok('-n allows AF_INET', r.get('sock_inet') == 'ok', r.get('sock_inet'))
    ok('-n still denies AF_UNIX', r.get('sock_unix') == 'EPERM', r.get('sock_unix'))
    ok('-n still denies AF_NETLINK/PACKET/VSOCK', r.get('sock_netlink') == r.get('sock_packet') == r.get('sock_vsock') == 'EPERM', r)
    ok('-n still denies io_uring', r.get('io_uring_setup') == 'EPERM', r.get('io_uring_setup'))
    r, raw, st = probe('-wnb ')
    ok('combined flags -wnb accepted', 'open_w' in r, raw)
    r, raw, st = probe('-n -- ')
    ok('-- ends the options', 'open_w' in r, raw)
    out, err, st = rs('sandbox -z true\necho st=$?\nexit\n', home=home)
    ok('unknown option is an error', 'unknown option' in out + err and 'st=2' in out, out + err)

    # -w opens the current folder only
    out, err, st = rs('sandbox touch here1\necho st=$?\nsandbox -w touch here2\necho st=$?\nexit\n', home=home, cwd=vic)
    ok('touch in cwd denied without -w', not os.path.exists(vic + '/here1') and 'st=1' in out, out + err)
    ok('touch in cwd works with -w', os.path.exists(vic + '/here2') and 'st=0' in out, out + err)
    out, err, st = rs('sandbox -w python3 -c "import os; os.rename(\'here2\', \'/var/tmp/asmsbx-moved\')"\nexit\n', home=home, cwd=vic)
    ok('-w does not allow moving out of cwd', os.path.exists(vic + '/here2') and not os.path.exists('/var/tmp/asmsbx-moved'), out + err)

    # 32-bit entry (int 0x80) must not reach the kernel's compat syscalls
    out, err, st = rs('python3 %s/ia32.py\nsandbox python3 %s/ia32.py\nexit\n' % (work, work), home=home)
    import re
    v = re.findall(r'ia32=(\d+)', out)
    if len(v) == 2 and int(v[0]) == 0xffffffda:
        skip('sandbox: 32-bit syscall entry', 'ia32 emulation is off')
    elif len(v) == 2:
        ok('32-bit syscall entry denied', int(v[1]) == 0xffffffff and int(v[0]) != 0xffffffff, v)
    else:
        ok('32-bit syscall probe ran', False, out + err)

    # TIOCSTI through the real terminal must not inject anything
    s = T.Sess(home=T.tmpdir())
    s.settle()
    s.run('sandbox python3 %s/probe.py %s $$' % (work, vic), maxt=10)
    scr = s.screen()
    ok('TIOCSTI denied on the tty', 'tiocsti=EPERM' in scr, scr[-400:])
    s.run('echo marker-after')
    ok('nothing was typed into the shell', 'XXX' not in s.screen() and 'marker-after' in s.screen(), s.screen()[-300:])
    s.close()

    # Fails closed: if Landlock or seccomp cannot be installed nothing runs
    def blocked_run(nr, cmd):
        libc = ctypes.CDLL(None, use_errno=True)
        # ld nr; jeq nr -> ERRNO(ENOSYS); ret ALLOW
        prog = [(0x20, 0, 0, 0), (0x15, 0, 1, nr), (0x06, 0, 0, 0x00050026), (0x06, 0, 0, 0x7fff0000)]
        arr = (ctypes.c_ubyte * (8 * len(prog)))()
        for i, (c, jt, jf, k) in enumerate(prog):
            struct.pack_into('<HBBI', arr, i * 8, c, jt, jf, k)

        class Fprog(ctypes.Structure):
            _fields_ = [('len', ctypes.c_ushort), ('filter', ctypes.c_void_p)]
        fp = Fprog(len(prog), ctypes.addressof(arr))

        def pre():
            libc.prctl(38, 1, 0, 0, 0)
            libc.prctl(22, 2, ctypes.byref(fp))
        p = subprocess.run([T.BIN], input=(cmd + '\necho st=$?\nexit\n').encode(), stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, preexec_fn=pre, timeout=20,
                           env={'PATH': '/usr/bin:/bin', 'HOME': home, 'ASM_NO_UPDATE_CHECK': '1'}, cwd=home)
        return p.stdout.decode('utf-8', 'replace')
    out = blocked_run(444, 'sandbox echo RAN-UNSANDBOXED')
    ok('no Landlock: command is not run', 'RAN-UNSANDBOXED' not in out and 'st=126' in out, out[-300:])
    out = blocked_run(444, 'sandbox -b echo RAN-BESTEFFORT')
    ok('no Landlock: -b runs it with a warning', 'RAN-BESTEFFORT' in out and 'not available' in out, out[-300:])
    out = blocked_run(317, 'sandbox echo RAN-UNSANDBOXED')
    ok('no seccomp: command is not run', 'RAN-UNSANDBOXED' not in out and 'st=126' in out, out[-300:])
    out = blocked_run(317, 'sandbox -b echo RAN-BESTEFFORT')
    ok('no seccomp: -b runs it', 'RAN-BESTEFFORT' in out, out[-300:])

out, err, st = rs('sandbox\necho st=$?\nexit\n', home=home)
T.check('sandbox usage states what is not blocked', 'Not blocked' in out and 'st=2' in out, out)

T.cleanup()
