#!/usr/bin/env python3
"""Print open file descriptors, one "N -> target" line each.

    fdlist.py        the descriptors this program got from its parent
    fdlist.py PID    the descriptors of process PID

Linux reads /proc. macOS has no /proc: its own descriptors are named with
fcntl(F_GETPATH) and another process's come from lsof.
"""
import os, sys, stat, fcntl, subprocess

F_GETPATH = 50          # macOS
LINUX = sys.platform.startswith('linux')


def own():
    out = []
    for fd in range(1024):
        try:
            st = os.fstat(fd)
        except OSError:
            continue
        if LINUX:
            t = os.readlink('/proc/self/fd/%d' % fd)
        else:
            try:
                t = fcntl.fcntl(fd, F_GETPATH, bytes(1024)).split(b'\0')[0].decode('utf-8', 'replace')
            except OSError:
                t = 'pipe' if stat.S_ISFIFO(st.st_mode) else 'socket' if stat.S_ISSOCK(st.st_mode) else '?'
        out.append((fd, t))
    return out


def other(pid):
    if LINUX:
        d = '/proc/%d/fd' % pid
        out = []
        for n in sorted(os.listdir(d), key=int):
            try:
                out.append((int(n), os.readlink(os.path.join(d, n))))
            except OSError:
                pass
        return out
    p = subprocess.run(['lsof', '-n', '-P', '-a', '-p', str(pid), '-d', '0-65535', '-F', 'fn'],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    out, fd = [], None
    for line in p.stdout.decode('utf-8', 'replace').splitlines():
        if line.startswith('f') and line[1:].isdigit():
            fd = int(line[1:])
            out.append((fd, '?'))
        elif line.startswith('n') and fd is not None and out and out[-1][0] == fd:
            out[-1] = (fd, line[1:])
    return out


for fd, t in (other(int(sys.argv[1])) if len(sys.argv) > 1 else own()):
    print('%d -> %s' % (fd, t))
