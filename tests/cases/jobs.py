# Job control, signals, exit statuses and exec failures (external commands).
import os, sys, time, subprocess, signal
import ptytest as T


def pstat(pid):
    """(state, ppid, pgrp) of a process, or None when it is gone."""
    try:
        st = open('/proc/%d/stat' % pid).read()
    except OSError:
        return None
    rest = st[st.rindex(')') + 2:].split()
    if rest[0] == 'Z':
        return None
    return rest[0], int(rest[1]), int(rest[2])


def find(tag, under=None):
    """Pids of live processes whose argv contains the exact word `tag`."""
    out = []
    for d in os.listdir('/proc'):
        if not d.isdigit():
            continue
        try:
            argv = open('/proc/%s/cmdline' % d, 'rb').read().split(b'\0')
        except OSError:
            continue
        if tag.encode() in argv and pstat(int(d)):
            out.append(int(d))
    return sorted(out)


def waitfor(fn, t=3.0):
    end = time.time() + t
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    return fn()


def reap(tags):
    for t in tags:
        for p in find(t):
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass


def cooked(s):
    """True when the tty of the session is in the shell's raw mode (no ISIG)."""
    import termios
    a = termios.tcgetattr(s.slave)
    return bool(a[3] & termios.ISIG)


# ---------------------------------------------------------------- process groups
s = T.Sess()
s.settle()
shell_pgid = os.getpgid(s.p.pid)
s.run("sleep 7771 &")
bg = waitfor(lambda: find("7771"))
s.run("sleep 7772")
fg = waitfor(lambda: find("7772"))
T.check("fg job runs in its own process group", fg and pstat(fg[0])[2] != shell_pgid, (fg, shell_pgid))
T.check("bg job is not in the shell's group", bg and all(pstat(p)[2] != shell_pgid for p in bg), bg)
s.send(b"\x03")
s.settle()
T.check("ctrl-c kills the foreground job", not find("7772"), s.screen())
T.check("ctrl-c leaves the background job alone", bool(find("7771")), s.screen())
T.check("ctrl-c: status 130 shown once", s.screen().count("[130]") == 1 and s.screen().count("^C") == 1, s.screen())
s.run("echo st=$?")
T.check("ctrl-c: shell takes next command, no stale abort", "st=130" in s.screen() and s.screen().count("^C") == 1, s.screen())
s.run("jobs")
T.check("jobs lists the background job as running", "Running  sleep 7771 &" in s.screen() or "Running  sleep 7771" in s.screen(), s.screen())
reap(["7771", "7772"])
s.close()

# ---------------------------------------------------------------- stdin of bg jobs
s = T.Sess()
s.settle()
s.run("/bin/cat &")
for i in range(3):
    s.run("echo line%d" % i)
scr = s.screen()
T.check("bg job does not steal the shell's keystrokes",
        all(("line%d" % i) in scr.replace("echo line%d" % i, "") for i in range(3)), scr)
s.close()

# ---------------------------------------------------------------- Ctrl+Z, bg, fg
s = T.Sess()
s.settle()
s.run("sleep 7773")
pid = waitfor(lambda: find("7773"))
s.send(b"\x1a")
s.settle()
T.check("ctrl-z stops the job, not the shell", s.alive() and pstat(s.p.pid)[0] != 'T'
        and pid and pstat(pid[0]) and pstat(pid[0])[0] == 'T', (pid, s.screen()))
T.check("ctrl-z announces the stopped job", "Stopped" in s.screen() and "sleep 7773" in s.screen(), s.screen())
s.run("echo shell-ok")
T.check("shell answers after ctrl-z", "shell-ok" in s.screen(), s.screen())
s.run("jobs")
T.check("jobs shows Stopped", "[1] PID" in s.screen() and "Stopped  sleep 7773" in s.screen(), s.screen())
s.run("bg 1")
T.check("bg prints the job number", "[bg] resumed job 1" in s.screen(), s.screen())
T.check("bg resumes the job", waitfor(lambda: pid and pstat(pid[0]) and pstat(pid[0])[0] == 'S'), pid)
s.run("jobs")
T.check("jobs shows Running after bg", "Running  sleep 7773" in s.screen(), s.screen())
s.send("fg 1\r")
s.settle()
s.send(b"\x03")
s.settle()
s.run("echo st=$?")
T.check("fg brings the job back; ctrl-c ends it with 130", "st=130" in s.screen() and not find("7773"), s.screen())
s.run("jobs")
T.check("finished job leaves the table", "No active" in s.screen(), s.screen())
s.send("sleep 7774\r")
waitfor(lambda: find("7774"))
s.send(b"\x1a")
s.settle()
s.run("fg 1")
s.send(b"\x03")
s.settle()
s.run("echo again=$?")
T.check("a job can be stopped and resumed repeatedly", "again=130" in s.screen(), s.screen())
reap(["7773", "7774"])
s.close()

# ---------------------------------------------------------------- pipelines
s = T.Sess()
s.settle()
s.run("sleep 7775 | sleep 7776")
a, b = waitfor(lambda: find("7775")), waitfor(lambda: find("7776"))
T.check("pipeline stages share one group", a and b and pstat(a[0])[2] == pstat(b[0])[2] != os.getpgid(s.p.pid), (a, b))
s.send(b"\x1a")
s.settle()
T.check("ctrl-z stops the whole pipeline", pstat(a[0])[0] == 'T' and pstat(b[0])[0] == 'T' and "Stopped" in s.screen(), s.screen())
s.run("fg 1")
s.send(b"\x03")
s.settle()
T.check("fg + ctrl-c ends the whole pipeline", waitfor(lambda: not find("7775") and not find("7776")), s.screen())
s.run("echo st=$?")
T.check("pipeline status after ctrl-c", "st=130" in s.screen(), s.screen())
reap(["7775", "7776"])
s.close()

# ---------------------------------------------------------------- builtins are interruptible
s = T.Sess()
s.settle()
s.send("while true; do :; done\r")
time.sleep(0.5)
s.send(b"\x03")
s.settle()
s.run("echo loop-over")
T.check("ctrl-c stops a loop of builtins", "loop-over" in s.screen().split("\n") and "[130]" in s.screen(), s.screen())
s.send("type /dev/zero\r")
time.sleep(0.5)
s.send(b"\x03")
s.settle()
s.run("echo type-over")
T.check("ctrl-c stops type on an endless file", "type-over" in s.screen().replace("echo type-over", ""), s.screen()[-300:])
s.close()

# ---------------------------------------------------------------- full job table
s = T.Sess()
s.settle()
for i in range(8):
    s.run("sleep 78%d1 &" % i, quiet=0.1)
s.send("sleep 7899 &\r")
s.settle()
T.check("full job table says so", "full" in s.screen(), s.screen())
s.send(b"\x03")
s.settle()
s.run("echo back")
T.check("full job table: shell stays interruptible", "back" in s.screen().replace("echo back", ""), s.screen())
reap(["78%d1" % i for i in range(8)] + ["7899"])
s.close()

T.cleanup()
