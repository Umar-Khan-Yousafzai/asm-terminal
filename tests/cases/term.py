import os, re, stat, signal, struct, time, fcntl, termios, subprocess
import ptytest as T


def tty_flags(fd):
    a = termios.tcgetattr(fd)
    return a[3] & termios.ICANON, a[3] & termios.ECHO, a[3] & termios.ISIG


def wait_dead(s, t=3):
    end = time.time() + t
    while time.time() < end and s.alive():
        time.sleep(0.05)
    return not s.alive()


def clear(s):
    """Empty the edit line wherever the cursor is."""
    s.send("\x1b[F\x15"); s.settle()


# ---------------------------------------------------------------- piped runs
out, err, st = T.run_script("echo hi\n/bin/true\nexit\n")
T.check("piped output has no escape bytes", "\x1b" not in out, repr(out[:200]))

d = T.tmpdir()
out, err, st = T.run_script("/bin/echo hi > %s/o.txt\nexit\n" % d)
data = open(d + "/o.txt", "rb").read() if os.path.exists(d + "/o.txt") else b""
T.check("extcmd > file holds only the command output", data == b"hi\n", data)

h = T.tmpdir()
T.run_script("echo secret\nexit\n", home=h)
T.check("script run leaves no history file", not os.path.exists(h + "/.asm_history"))

long_line = "echo " + "a" * 70000 + " touch %s/INJ\nexit\n" % d
out, err, st = T.run_script(long_line)
T.check("overlong piped line is dropped, tail not run", not os.path.exists(d + "/INJ"), out[-200:])
T.check("overlong piped line reports an error", "line too long" in err, err)
out, err, st = T.run_script("echo " + "b" * 70000 + "\necho after\nexit\n")
T.check("line after an overlong one still runs", "after" in out, out[-100:])

out, err, st = T.run_script("head -1\nhello\necho after\nexit\n")
T.check("a command can read the lines after its own", "not found" not in out + err and "hello" in out.split("shell")[-1], (out[-150:], err))

# stdin tty, stdout a pipe: the tty must come back unchanged
import pty
m, sl = pty.openpty()
before = termios.tcgetattr(sl)
p = subprocess.Popen([T.BIN], stdin=sl, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     env={'PATH': '/usr/bin:/bin', 'HOME': T.tmpdir(), 'ASM_NO_UPDATE_CHECK': '1'},
                     preexec_fn=os.setsid)
try:
    p.stdin
except Exception:
    pass
os.write(m, b"/bin/true\nexit\n")
try:
    p.communicate(timeout=5)
except Exception:
    p.kill()
after = termios.tcgetattr(sl)
T.check("tty untouched when only stdin is a tty", before == after, (before[3], after[3], before[4], after[4]))
os.close(m); os.close(sl)

# ---------------------------------------------------------------- prompt
s = T.Sess()
s.settle()
s.run("nosuchcmd_zz")
lines_before = s.vt.scroll_count
s.send("abc"); s.settle()
scr = s.screen()
T.check("failed command: typing keeps one prompt line", scr.count("[127]") == 1 and scr.rstrip().endswith("abc"), scr)
clear(s)

# cursor/column in a prompt with a git branch
g = T.tmpdir()
os.makedirs(g + "/.git")
open(g + "/.git/HEAD", "w").write("ref: refs/heads/feature-branch-name\n")
s.run("cd " + g)
s.send("xyz"); s.settle()
line = [l for l in s.vt.dump() if l.endswith("xyz")][-1]
T.check("git branch shown in prompt", "(feature-branch-name)" in line, line)
T.check("cursor column follows git prompt", s.vt.c == len(line), (s.vt.c, len(line)))
clear(s)

# detached HEAD and non-heads ref
open(g + "/.git/HEAD", "w").write("ref: refs/tags/v1.2\n")
s.run("")
T.check("tag ref shows last component", "(v1.2)" in s.screen(), s.screen())
open(g + "/.git/HEAD", "w").write("0123456789abcdef0123\n")
s.run("")
T.check("detached HEAD shows 8 chars", "(01234567)" in s.screen(), s.screen())
s.close()

# a .git file (worktree) is followed
w = T.tmpdir()
os.makedirs(w + "/real/wt1")
open(w + "/real/wt1/HEAD", "w").write("ref: refs/heads/wtbranch\n")
os.makedirs(w + "/proj")
open(w + "/proj/.git", "w").write("gitdir: ../real/wt1\n")
os.makedirs(w + "/.git")
open(w + "/.git/HEAD", "w").write("ref: refs/heads/outer\n")
s = T.Sess(cwd=w + "/proj")
s.settle()
T.check("worktree .git file followed", "(wtbranch)" in s.screen() and "(outer)" not in s.screen(), s.screen())
s.close()

# escape injection through the directory name
e = T.tmpdir()
bad = e + "/x\x1b]0;PWNED\x07y"
os.makedirs(bad)
s = T.Sess(cwd=bad)
s.settle()
T.check("cwd control bytes not sent raw", b"\x1b]0;PWNED" not in s.vt.raw, s.vt.raw[:200])
s.close()

# long USER does not corrupt the host
s = T.Sess(env={'USER': 'A' * 100})
s.settle()
scr = s.screen()
T.check("long $USER cut, host intact", re.search(r"A{63}@\S+:", scr) is not None, scr)
s.close()

# NO_COLOR / TERM=dumb
s = T.Sess(env={'NO_COLOR': '1'})
s.settle(); s.send("echo hi"); s.settle()
T.check("NO_COLOR: no SGR color codes", re.search(rb"\x1b\[[0-9;]*m", s.vt.raw) is None, s.vt.raw[:300])
s.close()
s = T.Sess(env={'TERM': 'dumb'})
s.settle(); s.send("echo hi"); s.settle()
T.check("TERM=dumb: no color, no OSC", re.search(rb"\x1b\[[0-9;]*m", s.vt.raw) is None and b"\x1b]" not in s.vt.raw, s.vt.raw[:300])
s.close()

# ---------------------------------------------------------------- wrapping
s = T.Sess(cols=40)
s.settle()
s.send("echo " + "a" * 60 + "bcd"); s.settle()
scr = s.screen()
T.check("wrapped line drawn once", scr.count("user@") <= 1 or scr.count("@") == 1, scr)
s.send("\x1b[D" * 30); s.settle()
T.check("Left over a wrapped row stays consistent", s.screen().count("@") == 1, s.screen())
s.send("\x1b[H"); s.settle()
first = [i for i, l in enumerate(s.vt.dump()) if "@" in l][0]
T.check("Home goes to the first prompt row", s.vt.r == first, (s.vt.r, first))
s.send("\x1b[F"); s.settle()
T.check("End goes to the last row", s.vt.r == first + 2, (s.vt.r, first))
s.close()

# ---------------------------------------------------------------- keys
s = T.Sess()
s.settle()
for name, seq, expect in [
    ("Ctrl+Right", "\x1b[1;5C", "ab"), ("Shift+Left", "\x1b[1;2D", "ab"),
    ("F5", "\x1b[15~", "ab"), ("PgUp", "\x1b[5~", "ab"), ("Ctrl+Del", "\x1b[3;5~", "ab"),
    ("F1 SS3", "\x1bOP", "ab"), ("Alt+f", "\x1bf", "ab"),
]:
    s.send("ab" + seq); s.settle(0.35)
    cur = [l for l in s.vt.dump() if "@" in l][-1]
    T.check("key %s leaves no garbage" % name, cur.endswith("$ ab"), cur)
    clear(s)
s.send("ab\x1bOH" + "X"); s.settle(0.35)
cur = [l for l in s.vt.dump() if "@" in l][-1]
T.check("SS3 Home moves the cursor", cur.endswith("Xab"), cur)
clear(s)
s.send("\x1b[20~"); s.send("echo hello"); s.settle(0.35)
T.check("F9 does not swallow later input", s.screen().rstrip().endswith("echo hello"), s.screen())
clear(s)
s.send("ab\x1bx"); s.settle(0.35)
cur = [l for l in s.vt.dump() if "@" in l][-1]
T.check("lone ESC then key: no crash", cur.endswith("ab") or cur.endswith("abx"), cur)
clear(s)

# bracketed paste
s.send("\x1b[200~echo first\necho second\x1b[201~"); s.settle(0.4)
scr = s.screen()
T.check("paste does not run its newline", "first" not in scr.replace("echo first", ""), scr)
T.check("paste newline becomes a space", scr.rstrip().endswith("echo first echo second"), scr)
clear(s)

# UTF-8
s.send("café".encode() if False else "café"); s.settle()
cur = [l for l in s.vt.dump() if "@" in l][-1]
T.check("non-ASCII input accepted", cur.endswith("café"), cur)
s.send("\x7f"); s.settle()
cur = [l for l in s.vt.dump() if "@" in l][-1]
T.check("backspace removes a whole UTF-8 char", cur.endswith("$ caf"), cur)
s.send("中文"); s.settle()
s.send("\x1b[D"); s.send("X"); s.settle()
cur = [l for l in s.vt.dump() if "@" in l][-1]
T.check("Left steps over a wide char", "中X文" in cur, cur)
clear(s)

# Ctrl+D at the continuation prompt does not close the shell
s.run("if true; then")
s.send("\x04"); s.settle()
T.check("Ctrl+D inside a block keeps the shell", s.alive(), s.screen())
s.run("echo still")
T.check("shell usable after Ctrl+D in block", "still" in s.screen(), s.screen())
s.close()

# Ctrl+D exits with the last status
s = T.Sess()
s.settle(); s.run("false")
s.send("\x04"); wait_dead(s)
T.check("Ctrl+D exits with last status", s.p.poll() == 1, s.p.poll())
s.close()

# ---------------------------------------------------------------- history
s = T.Sess()
s.settle()
s.run("echo one")
s.send("\x1b[A"); s.settle()
T.check("Up recalls the only entry", s.screen().rstrip().endswith("echo one"), s.screen())
clear(s)
s.run("echo two"); s.run("echo three")
for _ in range(5):
    s.send("\x1b[A")
s.settle()
T.check("Up reaches the oldest entry", s.screen().rstrip().endswith("echo one"), s.screen())
s.send("\x03"); s.settle()
s.send("\x1b[A"); s.settle()
T.check("Up after Ctrl+C starts at the newest", s.screen().rstrip().endswith("echo three"), s.screen())
clear(s)
s.run("echo A"); s.run("echo a"); s.run("history")
scr = s.screen()
T.check("history keeps case variants", "echo A" in scr and "echo a" in scr, scr)
s.close()

# history file: mode 0600, tail loading
h = T.tmpdir()
hf = h + "/.asm_history"
with open(hf, "w") as f:
    for i in range(1, 40001):
        f.write("echo command_%06d\n" % i)
os.chmod(hf, 0o644)
s = T.Sess(home=h)
s.settle()
s.send("\x1b[A"); s.settle()
T.check("history loads the newest entries", s.screen().rstrip().endswith("echo command_040000"), s.screen())
s.close()
sz = os.path.getsize(hf)
T.check("big history file is trimmed", sz < 300000, sz)
T.check("history file is 0600", stat.S_IMODE(os.stat(hf).st_mode) == 0o600, oct(os.stat(hf).st_mode))
h2 = T.tmpdir()
s = T.Sess(home=h2); s.settle(); s.run("echo x"); s.close()
T.check("new history file is 0600", stat.S_IMODE(os.stat(h2 + "/.asm_history").st_mode) == 0o600)

# ---------------------------------------------------------------- tab
td = T.tmpdir()
for n in ("alpha", "alpine", "beta"):
    open("%s/%s" % (td, n), "w").close()
s = T.Sess(cwd=td)
s.settle()
s.send("ls zzz\t"); s.settle(0.5)
T.check("Tab without match returns", s.alive() and "zzz" in s.screen())
try:
    st = open("/proc/%d/stat" % s.p.pid).read().split(")")[1].split()[0]
except Exception:
    st = "?"
T.check("Tab without match does not spin", st != "R", st)
clear(s)
s.send("cat be\t"); s.settle()
T.check("Tab completes", s.screen().rstrip().endswith("cat beta"), s.screen())
clear(s)
s.send("cat bar baz"); s.send("\x1b[D" * 8); s.send("\x1b[D" * 0)
clear(s)
s.send("cat be bar baz" + "\x1b[D" * 8 + "\t"); s.settle(0.4)
T.check("Tab keeps text after the cursor", s.screen().rstrip().endswith("cat beta bar baz"), s.screen())
clear(s)
fds_before = len(os.listdir("/proc/%d/fd" % s.p.pid))
for _ in range(5):
    s.send("al\tx\x15"); s.settle(0.3)
fds_after = len(os.listdir("/proc/%d/fd" % s.p.pid))
T.check("abandoned Tab cycles leak no fd", fds_after == fds_before, (fds_before, fds_after))
s.send("al\t\t"); s.settle(0.4)
T.check("Tab cycles through matches", re.search(r"(cat |\$ )al(pha|pine)$", s.screen().rstrip(), re.M) is not None, s.screen())
T.check("Tab lists every match under the line", re.search(r"^  .*alpha.*alpine|^  .*alpine.*alpha", s.screen(), re.M) is not None, s.screen())
s.send("x"); s.settle(0.3)
T.check("another key closes the Tab list", "alpha  " not in s.screen() and "alpine  " not in s.screen(), s.screen())
s.close()

# big directory: the entry past the first 8 KB of dirents completes
bd = T.tmpdir()
for i in range(600):
    open("%s/file_with_a_long_name_%04d" % (bd, i), "w").close()
names = sorted(os.listdir(bd))
s = T.Sess(cwd=bd)
s.settle()
s.send("ls file_with_a_long_name_059\t"); s.settle(0.8)
T.check("Tab in a big directory completes", re.search(r"_059\d$", s.screen().rstrip()) is not None, s.screen()[-200:])
s.close()

# overflow guard
od = T.tmpdir()
deep = od
for _ in range(2):
    deep += "/" + "d" * 200
os.makedirs(deep)
open(deep + "/" + "f" * 200, "w").close()
s = T.Sess(cwd=od)
s.settle()
s.send("x " + deep[len(od) + 1:] + "/f\t"); s.settle(0.5)
s.send("\r"); s.settle(0.5)
T.check("Tab overflow leaves shell alive", s.alive())
s.run("echo alive-after-overflow")
T.check("shell works after Tab overflow", "alive-after-overflow" in s.screen(), s.screen()[-200:])
s.close()

# ---------------------------------------------------------------- highlight
def hl(line, first=None):
    s = T.Sess(env={'PATH': '/usr/bin:/bin'})
    s.settle()
    if first:
        s.run(first)
        s.vt.raw = b''
    s.send(line); s.settle(0.35)
    raw = s.vt.raw.split(b"\r")[-1]       # the last redraw only
    s.close()
    return raw

T.check("hl: dd of=/dev/null only colours the word", hl("dd if=/dev/zero of=/dev/null bs=1M").count(b"244;71;71") == 1)
T.check("hl: cat mkfs.txt not danger", b"244;71;71" not in hl("cat mkfs.txt"))
T.check("hl: df -h is not help", b"55;148;255" not in hl("df -h /"))
T.check("hl: rm -rf still danger", b"244;71;71" in hl("rm -rf x"))
T.check("hl: alias is known", b"128;128;128" not in hl("ll", "alias ll=ls"))
T.check("hl: VAR=x cmd judged by cmd", b"128;128;128" not in hl("FOO=bar ls"))

# ---------------------------------------------------------------- signals
for name, sig in (("SIGTERM", signal.SIGTERM), ("SIGHUP", signal.SIGHUP)):
    s = T.Sess()
    s.settle()
    s.p.send_signal(sig)
    wait_dead(s)
    ic, ec, isg = tty_flags(s.master)
    T.check("tty restored after %s" % name, not s.alive() and ic and ec and isg, (s.alive(), ic, ec, isg))
    s.close()

# terminal gone: no spin
m, sl = pty.openpty()
p = subprocess.Popen([T.BIN], stdin=sl, stdout=sl, stderr=sl,
                     env={'PATH': '/usr/bin:/bin', 'HOME': T.tmpdir(), 'ASM_NO_UPDATE_CHECK': '1'},
                     preexec_fn=os.setsid, close_fds=True)
time.sleep(0.4)
os.close(m); os.close(sl)
try:
    p.wait(timeout=3)
    T.check("shell exits when its terminal vanishes", True)
except Exception:
    p.kill(); p.wait()
    T.check("shell exits when its terminal vanishes", False)

# child changing termios does not become the saved state
s = T.Sess()
s.settle()
s.run("stty -echo")
s.run("exit")
wait_dead(s)
ic, ec, isg = tty_flags(s.master)
T.check("stty -echo in a child is not made permanent", ec != 0, (ic, ec, isg))
s.close()

# ctrl+c aimed at a child does not abort the next prompt
s = T.Sess()
s.settle()
s.send("sleep 5\r"); s.settle(0.4)
s.send("\x03"); s.settle(0.6)
n_prompts = s.screen().count("@")
T.check("^C on a child: one prompt follows", n_prompts == 2, s.screen())
s.close()

# ---------------------------------------------------------------- startup order and editing keys
rc = T.tmpdir()
open(rc + "/.asmrc", "w").write("theme classic\nsleep 1 &\n")
s = T.Sess(home=rc)
s.settle()
s.run("jobs")
T.check("rc job survives prompt init", "No active background jobs" not in s.screen(), s.screen())
s.run("theme")
T.check("rc theme survives prompt init", "classic" in s.screen().split("jobs")[-1], s.screen())
s.close()

s = T.Sess()
s.settle()
s.run("echo before-clear")
s.send("echo kept"); s.send("\x0c"); s.settle()
dump = s.vt.dump()
T.check("Ctrl+L clears and redraws the line", len(dump) == 1 and dump[0].endswith("$ echo kept"), dump)
clear(s)
s.send("echo one two\x17"); s.settle()
T.check("Ctrl+W deletes a word", s.screen().rstrip().endswith("echo one"), s.screen())
clear(s)
s.run("echo findme")
s.run("echo other")
s.send("\x12findme"); s.settle()
T.check("Ctrl+R shows the match", "findme" in s.screen().split("\n")[-1], s.screen())
s.send("\r"); s.settle()
T.check("Ctrl+R Enter runs the match", s.screen().count("findme") >= 3, s.screen())
s.close()

# highlighting of paths and programs
hd = T.tmpdir()
open(hd + "/x", "w").write("#!/bin/sh\n"); os.chmod(hd + "/x", 0o755)
T.check("hl: /bin/ls is valid", b"78;201;176" in hl("/bin/ls"))
s = T.Sess(cwd=hd); s.settle(); s.vt.raw = b""; s.send("./x"); s.settle(0.4)
T.check("hl: ./x executable is valid", b"78;201;176" in s.vt.raw.split(b"\r")[-1], s.vt.raw[-80:])
s.close()

# external command redirected under a pty
s = T.Sess(); s.settle(); s.run("/bin/echo hi > %s/pty.txt" % hd)
T.check("pty: extcmd > file holds only the output", open(hd + "/pty.txt", "rb").read() == b"hi\n")
s.close()

# a resize is picked up for the next redraw
s = T.Sess(cols=80); s.settle()
fcntl.ioctl(s.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 40, 0, 0)); time.sleep(0.3)
s.vt.cols = 40
s.vt.grid = [r[:40] for r in s.vt.grid]
s.send("echo " + "w" * 50); s.settle()
T.check("resize: wrapped line drawn once", s.screen().count("@") == 1, s.screen())
s.close()

T.cleanup()
