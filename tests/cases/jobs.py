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

# ---------------------------------------------------------------- piped: statuses
import re


def lines(out):
    out = re.sub(r'\x1b\[[0-9;?]*[ ]*[@A-Za-z~]', '', out)
    out = re.sub(r'\x1b\][^\x07]*\x07', '', out)
    return out.replace('\r', '').split('\n')


def sh(text, **kw):
    out, err, st = T.run_script(text, **kw)
    return lines(out), lines(err), st


h = T.tmpdir()
open(os.path.join(h, 'badint'), 'w').write('#!/nonexistent/interp\n')
os.chmod(os.path.join(h, 'badint'), 0o755)
open(os.path.join(h, 'noexec'), 'w').write('x')
os.mkdir(os.path.join(h, 'adir'))

o, e, st = sh("/bin/false\nexit\n")
T.check("bare exit reports the previous status", st == 1, st)
o, e, st = sh("/bin/sh -c 'exit 7'\nexit\n")
T.check("bare exit reports status 7", st == 7, st)
o, e, st = sh("exit abc\necho notreached\n")
T.check("exit abc leaves with status 2", st == 2 and "notreached" not in o, (o, st))
o, e, st = sh("exit -1\n")
T.check("exit -1 leaves with status 255", st == 255, st)
o, e, st = sh("exit 256\n")
T.check("exit 256 wraps to 0", st == 0, st)
o, e, st = sh("/bin/true | exit 4\necho st=$?\nexit\n")
T.check("exit in a pipeline ends that stage only", "st=4" in o, o)
o, e, st = sh("./missing\necho s1=$?\n./badint\necho s2=$?\n./noexec\necho s3=$?\n./adir\necho s4=$?\n"
              "\"\"\necho s5=$?\nnosuchcmd\necho s6=$?\nexit\n", home=h)
blob = "\n".join(o + e)
T.check("missing path: No such file or directory, 127", "ash: ./missing: No such file or directory" in blob and "s1=127" in blob, blob)
T.check("missing interpreter: bad interpreter, 126", "ash: ./badint: bad interpreter" in blob and "s2=126" in blob, blob)
T.check("no x bit: Permission denied, 126", "ash: ./noexec: Permission denied" in blob and "s3=126" in blob, blob)
T.check("directory: Is a directory, 126", "ash: ./adir: Is a directory" in blob and "s4=126" in blob, blob)
T.check("empty command: command not found, 127", "ash: : command not found" in blob and "s5=127" in blob, blob)
T.check("unknown command: command not found, 127", "ash: nosuchcmd: command not found" in blob and "s6=127" in blob, blob)
o, e, st = sh("/bin/sh -c 'kill -9 $$'\necho n=$?\n/bin/sh -c 'kill -9 $$' x*\necho f=$?\nexit\n")
T.check("signalled child: 128+signal on the native path", "n=137" in o, o)
T.check("signalled child: 128+signal on the /bin/sh path", "f=137" in o, o)
o, e, st = sh("which if break\nkill -l\nexit\n")
T.check("which knows shell keywords", "if: shell keyword" in o and "break: shell keyword" in o, o)
T.check("kill -l lists signal names", any(l.startswith("HUP INT QUIT") and "ALRM" in l for l in o), o)

# ---------------------------------------------------------------- kill never wraps a pid
kid = subprocess.Popen(["sleep", "7790"])
for bad in (kid.pid + 2 ** 32, 99999999999, 4194305):
    sh("kill %d\nexit\n" % bad)
T.check("kill rejects pids that do not fit a pid_t", kid.poll() is None, kid.poll())
o, e, st = sh("kill 0\nkill -9 0\nexit\n")
T.check("kill 0 is refused", "\n".join(o + e).count("not a process id") >= 2, o)
o, e, st = sh("kill -s TERM %d\nexit\n" % kid.pid)
T.check("kill -s NAME works", kid.wait() == -signal.SIGTERM, kid.poll())
kid = subprocess.Popen(["sleep", "7791"])
sh("kill -ALRM %d\nexit\n" % kid.pid)
T.check("kill -ALRM knows more signal names", kid.wait() == -signal.SIGALRM, kid.poll())

# ---------------------------------------------------------------- redirects and descriptors
d = T.tmpdir()
o, e, st = sh("/bin/ls /nonexistent_xx 2>&1 >/dev/null | /bin/cat\nexit\n", cwd=d)
T.check("2>&1 before > keeps stderr on the pipe", any("nonexistent_xx" in l for l in o), o)
o, e, st = sh("/bin/ls /nonexistent_xx >/dev/null 2>&1 | /bin/cat\necho end\nexit\n", cwd=d)
T.check("> before 2>&1 sends stderr to the file", not any("nonexistent_xx" in l for l in o), o)
open(os.path.join(d, 'in.txt'), 'w').write('in')
sh("/bin/ls -l /proc/self/fd > out.txt\n/bin/ls -l /proc/self/fd < in.txt > out2.txt\nexit\n", cwd=d)
fds = open(os.path.join(d, 'out.txt')).read() + open(os.path.join(d, 'out2.txt')).read()
T.check("redirect source descriptor is not inherited", 'out.txt' in fds and fds.count('out.txt') == 1 and 'out2.txt' in fds
        and fds.count('out2.txt') == 1 and fds.count('in.txt') == 1, fds)

# ---------------------------------------------------------------- environment size
env = {'V%d' % i: 'x' for i in range(300)}
o, e, st = sh("/usr/bin/env | /usr/bin/wc -l\nexit\n", env=env)
n = [l for l in o if l.strip().isdigit()]
T.check("children get more than 255 variables", n and int(n[0]) > 300, o)

T.cleanup()
