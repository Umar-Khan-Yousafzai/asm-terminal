"""RELEASE area: the startup update check, driven on a pty with a fake curl.

The background checker only runs for an interactive shell, so these cases
need a terminal. A fake `curl` earlier on PATH records every call (and the
descriptors its parent holds) and serves a canned release reply.
"""
import os, re, shutil, stat, time
import ptytest as T

HERE = os.path.dirname(os.path.abspath(__file__))
VER = re.search(r'ASM_VERSION "([^"]+)"',
                open(os.path.join(HERE, "..", "..", "version.inc")).read()).group(1)


def fake_env(tag="v99.0.0"):
    """A directory with bin/curl, log and latest; returns (dir, env)."""
    d = T.tmpdir()
    os.makedirs(os.path.join(d, "bin"))
    with open(os.path.join(d, "latest"), "w") as f:
        f.write('{"tag_name": "%s"}\n' % tag)
    sh = os.path.join(d, "bin", "curl")
    with open(sh, "w") as f:
        f.write("""#!/bin/bash
PATH=/usr/bin:/bin
echo "call $*" >> "%(d)s/log"
for n in 0 1 2; do echo "fd$n $(readlink /proc/$PPID/fd/$n)" >> "%(d)s/log"; done
[ -f "%(d)s/fail" ] && exit 22
cat "%(d)s/latest"
""" % {"d": d})
    os.chmod(sh, 0o755)
    env = {"PATH": d + "/bin:/usr/bin:/bin"}
    return d, env


def readlog(d):
    try:
        return open(os.path.join(d, "log")).read()
    except OSError:
        return ""


def calls(d):
    return sum(1 for l in readlog(d).splitlines() if l.startswith("call "))


def readfile(path):
    try:
        return open(path).read()
    except OSError:
        return ""


def wait_for(cond, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return cond()


def start(home, env, binary=None, **kw):
    """Start the shell. Sess sets ASM_NO_UPDATE_CHECK=1 for hermetic runs; unless the
    case sets it itself, `env -u` removes it again so the check is really on."""
    binary = binary or T.BIN
    if "ASM_NO_UPDATE_CHECK" in env:
        argv = [binary]
    else:
        argv = ["/usr/bin/env", "-u", "ASM_NO_UPDATE_CHECK", binary]
    s = T.Sess(argv=argv, env=env, home=home, **kw)
    s.settle()
    return s


# Control: with no opt-out the background check runs, over https only
d, env = fake_env()
home = T.tmpdir()
s = start(home, env)
T.check("startup: check runs by default", wait_for(lambda: calls(d) >= 1))
log = readlog(d)
T.check("startup: check uses hardened curl flags",
        "call -q --proto =https --proto-redir =https -fsSL " in log, log)
T.check("startup: cache written",
        wait_for(lambda: "v99.0.0" in readfile(os.path.join(home, ".asm_update"))))
s.close()

# The next start prints the notice from the cache
s = start(home, env)
T.check("startup: notice from cache",
        re.search(r"Update available: v[0-9.]+ -> v99\.0\.0", s.screen()) is not None, s.screen())
s.close()

# The checker must not keep the user's pty open
fds = [l.split(" ", 1) for l in readlog(d).splitlines() if l.startswith("fd")]
T.check("startup: checker does not hold the tty",
        len(fds) >= 3 and all("/dev/null" in v for _, v in fds[:3]), fds[:3])

# ASM_NO_UPDATE_CHECK=0 or empty do not opt out
d2, env2 = fake_env()
env2["ASM_NO_UPDATE_CHECK"] = "0"
s = start(T.tmpdir(), env2)
T.check("startup: ASM_NO_UPDATE_CHECK=0 keeps the check on", wait_for(lambda: calls(d2) >= 1))
s.close()
d2, env2 = fake_env()
env2["ASM_NO_UPDATE_CHECK"] = ""
s = start(T.tmpdir(), env2)
T.check("startup: empty ASM_NO_UPDATE_CHECK keeps the check on", wait_for(lambda: calls(d2) >= 1))
s.close()

# The documented opt-out works from the environment ...
d3, env3 = fake_env()
env3["ASM_NO_UPDATE_CHECK"] = "1"
s = start(T.tmpdir(), env3)
time.sleep(1.2)
T.check("startup: env opt-out honoured", calls(d3) == 0)
s.close()

# ... and from ~/.asmrc, which is where a user sets it
d4, env4 = fake_env()
home4 = T.tmpdir()
with open(os.path.join(home4, ".asmrc"), "w") as f:
    f.write("set ASM_NO_UPDATE_CHECK=1\n")
s = start(home4, env4)
time.sleep(1.2)
T.check("startup: ~/.asmrc opt-out honoured", calls(d4) == 0, readlog(d4))
s.close()

# A failed check (offline, rate limit) is not retried on every start
d5, env5 = fake_env()
open(os.path.join(d5, "fail"), "w").close()
home5 = T.tmpdir()
s = start(home5, env5)
T.check("startup: failed check ran once", wait_for(lambda: calls(d5) >= 1))
T.check("startup: failed check leaves a cache stamp", wait_for(lambda: os.path.exists(os.path.join(home5, ".asm_update"))))
s.close()
s = start(home5, env5)
time.sleep(1.2)
T.check("startup: failed check not retried at once", calls(d5) == 1, calls(d5))
s.close()

# A cache dated in the future must not switch the check off for good
d6, env6 = fake_env()
home6 = T.tmpdir()
cache = os.path.join(home6, ".asm_update")
with open(cache, "w") as f:
    f.write("v1.0.0\n")
os.utime(cache, (4070908800, 4070908800))     # 2099
s = start(home6, env6)
T.check("startup: future-dated cache is refreshed", wait_for(lambda: calls(d6) >= 1))
s.close()

# A hostile cache file must not reach the screen
d7, env7 = fake_env()
home7 = T.tmpdir()
with open(os.path.join(home7, ".asm_update"), "wb") as f:
    f.write(b"v99.0.0\x1b[31mRED\x1b]0;PWNED\x07\n")
s = start(home7, env7)
T.check("startup: cache with escape codes not printed",
        b"PWNED" not in s.vt.raw and "Update available" not in s.screen(), s.vt.raw[-200:])
s.close()

# A package or AppImage copy is not nagged about updates
d8, env8 = fake_env()
mnt = os.path.join(T.tmpdir(), ".mount_asmQ1w2e3", "usr", "bin")
os.makedirs(mnt)
shutil.copy(T.BIN, os.path.join(mnt, "asm-terminal"))
s = start(T.tmpdir(), env8, binary=os.path.join(mnt, "asm-terminal"))
time.sleep(1.2)
T.check("startup: AppImage copy does not check for updates", calls(d8) == 0)
s.close()

# A very long HOME used to overflow the cache path buffer
d9, env9 = fake_env()
env9["HOME"] = "/" + "a" * 40000
s = start(None, env9)
s.run("echo still-alive")
T.check("startup: 40 KB HOME does not break the shell", "still-alive" in s.screen(), s.screen()[-200:])
s.send("exit\r")
T.check("startup: 40 KB HOME exits cleanly", wait_for(lambda: not s.alive(), 5) and s.p.returncode == 0, s.p.returncode)
s.close()

T.cleanup()
