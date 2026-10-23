#!/usr/bin/env python3
"""Pseudo-terminal test helpers shared by tests/cases/*.py.

A test file imports this module, drives the shell through Sess, and reports
each assertion with check(). tests/run_tests.sh runs every tests/cases/*.py
and counts the `ok` / `not ok` lines that check() prints.

    import ptytest as T
    s = T.Sess()                 # hermetic HOME, 80x24, TERM=xterm
    s.settle()                   # wait for the first prompt
    s.send("echo hi\\r"); s.settle()
    T.check("echo prints hi", "hi" in s.screen())
    s.close()
"""
import os, pty, sys, time, select, fcntl, termios, struct, subprocess, re, tempfile, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.environ.get("BIN") or os.path.join(HERE, "..", "terminal")
_tmp = []


def tmpdir():
    d = tempfile.mkdtemp(prefix="asmt-")
    _tmp.append(d)
    return d


def cleanup():
    for d in _tmp:
        shutil.rmtree(d, ignore_errors=True)
    del _tmp[:]


def check(name, cond, detail=""):
    """Report one assertion; the shell runner counts these lines."""
    if cond:
        print("ok\t%s" % name)
    else:
        print("not ok\t%s\t%s" % (name, str(detail).replace("\n", "\\n")[:300]))
    sys.stdout.flush()


class VT:
    """Small VT100 screen model: cursor moves, erase, scroll, autowrap."""

    def __init__(s, rows=24, cols=80):
        s.rows, s.cols = rows, cols
        s.grid = [[' '] * cols for _ in range(rows)]
        s.r = s.c = 0
        s.wrap_pending = False
        s.raw = b''
        s.scroll_count = 0
        s.pend = b''

    def _lf(s):
        if s.r == s.rows - 1:
            s.grid.pop(0)
            s.grid.append([' '] * s.cols)
            s.scroll_count += 1
        else:
            s.r += 1

    def feed(s, data):
        s.raw += data
        i = 0
        data = s.pend + data
        s.pend = b''
        try:
            txt = data.decode('utf-8')
        except UnicodeDecodeError as e:
            if e.start >= len(data) - 3:
                s.pend = data[e.start:]
                txt = data[:e.start].decode('utf-8', 'replace')
            else:
                txt = data.decode('utf-8', 'replace')
        n = len(txt)
        while i < n:
            ch = txt[i]
            if ch == '\x1b':
                if i + 1 < n and txt[i + 1] == '[':
                    j = i + 2
                    while j < n and not (0x40 <= ord(txt[j]) <= 0x7e):
                        j += 1
                    if j >= n:
                        s.pend = txt[i:].encode() + s.pend
                        break
                    s.csi(txt[i + 2:j], txt[j])
                    i = j + 1
                    continue
                elif i + 1 < n and txt[i + 1] == ']':
                    j = i + 2
                    while j < n and txt[j] != '\x07' and not (txt[j] == '\x1b' and j + 1 < n and txt[j + 1] == '\\'):
                        j += 1
                    if j >= n or (txt[j] == '\x1b' and j + 1 >= n):
                        s.pend = txt[i:].encode() + s.pend
                        break
                    i = j + 1 if txt[j] == '\x07' else j + 2
                    continue
                elif i + 1 >= n:
                    s.pend = txt[i:].encode() + s.pend
                    break
                else:
                    i += 2
                    continue
            elif ch == '\r':
                s.c = 0
                s.wrap_pending = False
            elif ch == '\n':
                s._lf()
                s.wrap_pending = False
            elif ch == '\x08':
                s.c = max(0, s.c - 1)
                s.wrap_pending = False
            elif ch == '\x07':
                pass
            elif ord(ch) >= 32:
                if s.wrap_pending:
                    s.c = 0
                    s._lf()
                    s.wrap_pending = False
                s.grid[s.r][s.c] = ch
                if s.c == s.cols - 1:
                    s.wrap_pending = True
                else:
                    s.c += 1
            i += 1

    def csi(s, p, f):
        pp = p.lstrip('?')
        nums = [int(x) if x else 0 for x in re.split('[;:]', pp)] if pp and pp[0].isdigit() else []
        a = nums[0] if nums else 0
        if f == 'G':
            s.c = min(max(a, 1), s.cols) - 1
            s.wrap_pending = False
        elif f == 'K':
            if a == 0:
                for x in range(s.c, s.cols):
                    s.grid[s.r][x] = ' '
            elif a == 2:
                s.grid[s.r] = [' '] * s.cols
        elif f == 'J':
            if a == 2:
                s.grid = [[' '] * s.cols for _ in range(s.rows)]
            elif a == 0:
                for x in range(s.c, s.cols):
                    s.grid[s.r][x] = ' '
                for y in range(s.r + 1, s.rows):
                    s.grid[y] = [' '] * s.cols
        elif f == 'H':
            r = nums[0] if nums else 1
            c = nums[1] if len(nums) > 1 else 1
            s.r = min(max(r, 1), s.rows) - 1
            s.c = min(max(c, 1), s.cols) - 1
            s.wrap_pending = False
        elif f == 'C':
            s.c = min(s.cols - 1, s.c + max(a, 1))
            s.wrap_pending = False
        elif f == 'D':
            s.c = max(0, s.c - max(a, 1))
            s.wrap_pending = False
        elif f == 'A':
            s.r = max(0, s.r - max(a, 1))
        elif f == 'B':
            s.r = min(s.rows - 1, s.r + max(a, 1))

    def dump(s):
        lines = [''.join(r).rstrip() for r in s.grid]
        while lines and not lines[-1]:
            lines.pop()
        return lines


class Sess:
    """The shell on a pty with its own session, controlling tty and HOME."""

    def __init__(s, argv=None, env=None, cwd=None, rows=24, cols=80, home=None):
        s.vt = VT(rows, cols)
        s.home = home or tmpdir()
        e = {'PATH': '/usr/bin:/bin', 'HOME': s.home, 'TERM': 'xterm', 'ASM_NO_UPDATE_CHECK': '1'}
        if env:
            e.update(env)
        s.master, s.slave = pty.openpty()
        fcntl.ioctl(s.slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

        def pre():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        s.p = subprocess.Popen(argv or [BIN], stdin=s.slave, stdout=s.slave, stderr=s.slave,
                               env=e, cwd=cwd or s.home, preexec_fn=pre, close_fds=True)

    def send(s, b):
        if isinstance(b, str):
            b = b.encode()
        os.write(s.master, b)

    def settle(s, quiet=0.25, maxt=5):
        end = time.time() + maxt
        last = time.time()
        while time.time() < end:
            r, _, _ = select.select([s.master], [], [], 0.05)
            if r:
                try:
                    d = os.read(s.master, 65536)
                except OSError:
                    break
                if not d:
                    break
                s.vt.feed(d)
                last = time.time()
            elif time.time() - last > quiet:
                break

    def run(s, line, quiet=0.25, maxt=5):
        """Type a line, press Enter, wait for output to go quiet."""
        s.send(line + "\r")
        s.settle(quiet, maxt)

    def screen(s):
        return "\n".join(s.vt.dump())

    def alive(s):
        return s.p.poll() is None

    def close(s):
        try:
            s.p.kill()
        except Exception:
            pass
        try:
            s.p.wait(timeout=2)
        except Exception:
            pass
        for fd in (s.master, s.slave):
            try:
                os.close(fd)
            except OSError:
                pass


def run_script(text, env=None, cwd=None, timeout=20, home=None):
    """Feed text to the shell on a pipe (non-interactive). Returns (stdout, stderr, status)."""
    h = home or tmpdir()
    e = {'PATH': '/usr/bin:/bin', 'HOME': h, 'ASM_NO_UPDATE_CHECK': '1'}
    if env:
        e.update(env)
    p = subprocess.run([BIN], input=text.encode() if isinstance(text, str) else text,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e,
                       cwd=cwd or h, timeout=timeout)
    return p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace'), p.returncode
