#!/usr/bin/env python3
# Type a line into the terminal through a pseudo-terminal (no Enter) and
# print the last redraw of that line, escape codes included.
# Usage: pty_line.py BINARY TEXT
import os, pty, sys, time, select
binp, text = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"]="xterm"; os.execv(binp, [binp])
def drain(t=0.4):
    out=b""; end=time.time()+t
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.05)
        if r:
            try: out+=os.read(fd,65536)
            except OSError: break
    return out
drain(0.8)
os.write(fd, text.encode()); out=drain(0.5)
os.write(fd, b"\x15exit\r"); drain(0.4)
try: os.waitpid(pid,0)
except: pass
sys.stdout.write(repr(out.split(b"\r")[-1]))
