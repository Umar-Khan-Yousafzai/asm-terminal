#!/usr/bin/env python3
"""Builtin behaviour: exit statuses, stderr, environment overlay, aliases,
cd/pushd/popd, cat/ls/grep/calc/color/title/date and rc/source loading."""
import os, re, shutil, subprocess, ptytest as T

CLEAN = re.compile(r'\x1b\[[0-9;?]*[ ]*[@A-Za-z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x07')


def run(lines, env=None, cwd=None, home=None):
    """Run lines through the shell on a pipe. Returns (stdout, stderr, status)
    with terminal escape sequences removed from stdout."""
    if isinstance(lines, str):
        lines = [lines]
    out, err, st = T.run_script("\n".join(lines) + "\nexit\n", env=env, cwd=cwd, home=home)
    return CLEAN.sub('', out), err, st


def body(out):
    """Output lines after the welcome banner."""
    return out.split("Type 'help' for available commands\n", 1)[-1].lstrip("\n").split("\n")


d = T.tmpdir()

# ---- error text: whole message, stderr, failure status ----------------------
out, err, st = run("cat /nonexistent_misc_zz")
T.check("err: cat missing file prints one clean message on stderr",
        err == "Error: Could not open file.\n", repr(err))
T.check("err: no error text or NUL bytes on stdout", "Error" not in out and "\0" not in out, repr(out[-120:]))

out, err, st = run("cat /nonexistent_misc_zz > %s/o.txt" % d)
T.check("err: redirect does not capture the message",
        os.path.getsize("%s/o.txt" % d) == 0 and "Could not open" in err, (err,))

for name, line in (("cd", "cd /nonexistent_misc_zz"), ("mkdir", "mkdir %s" % d),
                   ("rmdir", "rmdir /nonexistent_misc_zz"), ("pushd", "pushd /nonexistent_misc_zz"),
                   ("popd", "popd"), ("unalias", "unalias nosuchalias"), ("set", "set NOSUCHVAR_ZZ"),
                   ("source", "source /nonexistent_misc_zz")):
    out, err, st = run([line, "echo st=$?"])
    T.check("status: %s failure sets $?=1" % name, "st=1" in out, repr(body(out)[-4:]))
    T.check("status: %s failure reports on stderr" % name, err.strip() != "" and "Error" not in out.replace("st=1", ""),
            (err, out[-80:]))

out, err, st = run("cd /nonexistent_misc_zz && echo SHOULD-NOT-PRINT")
T.check("status: cd failure stops &&", "SHOULD-NOT-PRINT" not in out, out[-80:])
out, err, st = run("cd /nonexistent_misc_zz || echo no-such-dir")
T.check("status: cd failure runs ||", "no-such-dir" in out, out[-80:])
out, err, st = run("if cd /nonexistent_misc_zz; then echo CD-OK; else echo CD-FAILED; fi")
T.check("status: if sees a failing cd", "CD-FAILED" in out and "CD-OK" not in out, out[-80:])
out, err, st = run("if mkdir /proc/misc_zz; then echo MK-OK; else echo MK-FAILED; fi")
T.check("status: if sees a failing mkdir", "MK-FAILED" in out, out[-80:])

# ---- environment overlay ----------------------------------------------------
out, err, st = run(["set path=/nonexistent_misc_zz", "echo hi | cat", "echo [$home]"])
T.check("env: lowercase name does not clobber PATH", "hi" in body(out) and "[]" in body(out), body(out))
out, err, st = run(["x=1", "X=2", "echo $x $X"])
T.check("env: names are case-sensitive", "1 2" in body(out), body(out))

out, err, st = run(["unset FOO_MISC", "echo [$FOO_MISC]", "sh -c 'echo child=[$FOO_MISC]'"], env={"FOO_MISC": "inherited"})
T.check("env: unset hides an inherited variable from the shell", "[]" in body(out), body(out))
T.check("env: unset hides an inherited variable from children", "child=[]" in body(out), body(out))
out, err, st = run(["unset FOO_MISC", "set FOO_MISC=again", "echo $FOO_MISC", "env | grep -c ^FOO_MISC="],
                   env={"FOO_MISC": "inherited"})
T.check("env: set after unset brings it back once", "again" in body(out) and "1" in body(out), body(out))
out, err, st = run(["set FOO_MISC=over", "env | grep ^FOO_MISC="], env={"FOO_MISC": "inherited"})
T.check("env: overridden variable is passed once", body(out).count("FOO_MISC=over") == 1
        and "FOO_MISC=inherited" not in out, body(out))
out, err, st = run(["set FOO_MISC=over", "set"], env={"FOO_MISC": "inherited"})
T.check("env: set lists an overridden variable once", body(out).count("FOO_MISC=over") == 1
        and "FOO_MISC=inherited" not in out, [l for l in body(out) if "FOO_MISC" in l])

cmds = []
for i in range(300):
    cmds += ["set U=%d" % i, "unset U"]
out, err, st = run(cmds + ["set LAST_MISC=ok", "echo LAST=$LAST_MISC"])
T.check("env: unset frees the slot for reuse", "LAST=ok" in body(out), body(out)[-3:])
out, err, st = run(["set V%d=x" % i for i in range(300)] + ["echo st=$?"])
T.check("env: a full table is reported, not silent", "environment full" in err, err[:120])
T.check("env: many variables fit", "V250=" not in out and err.count("environment full") == 300 - 256, err.count("environment full"))
out, err, st = run(["set LONG=" + "x" * 600, "echo st=$?", "echo [$LONG]"])
T.check("env: over-long value is rejected with a message", "too long" in err and "[]" in body(out), (err, body(out)[-3:]))
out, err, st = run(["f() { echo arg=$1; }", "f one", "env | grep -c '^[0-9#@]='"])
lines = body(out)
T.check("env: function arguments are not exported",
        "arg=one" in lines and lines[lines.index("arg=one") + 1] == "0", lines[-4:])

# ---- cd / pushd / popd ------------------------------------------------------
w = T.tmpdir()
os.makedirs(w + "/one")
os.makedirs(w + "/two")
out, err, st = run(["cd %s/one" % w, "cd %s/two" % w, "cd /nonexistent_misc_zz", "cd -", "pwd"])
T.check("cd: a failed cd keeps cd - working", w + "/one" in body(out)[-4:], body(out)[-4:])
out, err, st = run(["cd %s/one" % w, "echo $PWD", "cd ../two", "echo $PWD $OLDPWD"])
T.check("cd: PWD and OLDPWD follow the directory",
        "%s/one" % w in body(out) and "%s/two %s/one" % (w, w) in body(out), body(out)[-4:])
out, err, st = run(["cd %s/one" % w, "sh -c 'echo child=$PWD'"])
T.check("cd: children see the new PWD", "child=%s/one" % w in body(out), body(out)[-3:])
os.makedirs(w + "/gone")
out, err, st = run(["cd %s/gone" % w, "rmdir %s/gone" % w, "pushd /tmp", "popd", "popd", "echo st=$?"])
T.check("popd: an entry whose directory vanished is dropped", "Directory stack empty" in err, err)

# ---- color ------------------------------------------------------------------
s = T.Sess()
s.settle()
s.run("color 0A")
raw = s.vt.raw
T.check("color: 0A sends a valid SGR sequence", b"\x1b[92;40m" in raw, raw[-80:])
n = len(raw)
s.run("color GG")
T.check("color: a non-hex digit is refused", b"Usage: color" in s.vt.raw[n:] or "Usage: color" in s.screen(), s.screen()[-200:])
T.check("color: no byte above 0x7f in the output", all(b < 0x80 for b in s.vt.raw[n:]), s.vt.raw[n:][-80:])
s.close()
out, err, st = T.run_script("color 0A\nexit\n")
T.check("color: nothing is written to a pipe", not re.search(r"\x1b\[[0-9;]*m", out), repr(out[-60:]))
out, err, st = T.run_script("color 0A\necho st=$?\ncolor ZZ\necho st=$?\nexit\n")
T.check("color: bad argument sets status 1", "st=0" in out and "st=1" in out, out[-60:])

# ---- title ------------------------------------------------------------------
s = T.Sess(env={"EVIL": "x\x07\x1b[31mINJECTED"})
s.settle()
n = len(s.vt.raw)
s.run("title $EVIL")
new = s.vt.raw[n:]
T.check("title: control bytes are dropped from the title",
        b"\x1b]0;x[31mINJECTED\x07" in new and b"\x1b[31m" not in new, new)
s.close()
out, err, st = T.run_script("title hello\nexit\n")
T.check("title: nothing is written to a pipe", "]0;hello" not in out, repr(out[-60:]))

# ---- date -------------------------------------------------------------------
def date(env=None, cmd="date"):
    out, err, st = T.run_script(cmd + "\nexit\n", env=env)
    m = re.search(r"\w{3} \w{3} [ \d]\d (\d\d):(\d\d):\d\d (AM|PM) (\S+) \d{4}", CLEAN.sub('', out))
    return m
m0 = date({"ASM_TZ": "0"})
m1 = date({"ASM_TZ": "19800"})
m2 = date({"ASM_TZ": "-18000"})
T.check("date: ASM_TZ shows the numeric offset", m0 and m0.group(4) == "+0000" and m1 and m1.group(4) == "+0530"
        and m2 and m2.group(4) == "-0500", (m0 and m0.groups(), m1 and m1.groups(), m2 and m2.groups()))
m = date({"TZ": "EST5"})
T.check("date: TZ=EST5 is UTC-5 and named EST", m and m.group(4) == "EST", m and m.groups())
m = date({"TZ": "<+0530>-5:30"})
T.check("date: quoted TZ name", m and m.group(4) == "+0530", m and m.groups())
m = date({"ASM_TZ": "5:30"})
T.check("date: ASM_TZ with trailing text is ignored, not half used", m and m.group(4) == "PKT", m and m.groups())
m = date({"ASM_TZ": "0", "TZ": "EST5"})
T.check("date: ASM_TZ wins over TZ", m and m.group(4) == "+0000", m and m.groups())
m = date({"TZ": "Europe/Paris"})
T.check("date: an unsupported TZ falls back to the build default", m and m.group(4) == "PKT", m and m.groups())
out, err, st = T.run_script("set ASM_TZ=3600\ndate\nset ASM_TZ=7200\ndate\nexit\n")
z = re.findall(r" (\+\d{4}) ", CLEAN.sub('', out))
T.check("date: changing ASM_TZ takes effect at once", z == ["+0100", "+0200"], z)
out, err, st = T.run_script("time\nexit\n", env={"ASM_TZ": "0"})
T.check("time: same as date", "+0000" in out, out[-60:])

# ---- alias ------------------------------------------------------------------
cmds = []
for i in range(40):
    cmds += ["alias n%d=echo %d" % (i, i), "unalias n%d" % i]
out, err, st = run(cmds + ["alias zz=echo ok", "zz"])
T.check("alias: unalias frees the slot", "ok" in body(out) and "table full" not in err, (err, body(out)[-3:]))
out, err, st = run(["alias a=echo A", "alias b=echo B", "unalias a", "alias"])
T.check("alias: listing skips removed entries", "b=echo B" in body(out) and "=echo A" not in out, body(out)[-4:])
out, err, st = run(["alias k%d=echo %d" % (i, i) for i in range(32)] + ["alias k1=echo CHANGED", "k1"])
T.check("alias: redefining works with a full table", "CHANGED" in body(out), (err, body(out)[-3:]))
out, err, st = run(["alias last=" + "w" * 450, "echo st=$?", "alias q=echo fine", "q"])
T.check("alias: over-long value is refused and nothing is corrupted",
        "too long" in err and "st=1" in out and "fine" in body(out), (err, body(out)[-4:]))
out, err, st = run(["alias q=echo fine", "alias x=echo " + "A" * 240, "x " + "B" * 300, "alias", "q"])
T.check("alias: an expansion past the line limit is refused", "q=echo fine" in body(out) and "BBBB=" not in out
        and body(out)[-2] == "fine", (err, [l[:40] for l in body(out)[-4:]]))
out, err, st = run(["alias q=echo fine", "alias", "alias q"])
T.check("alias: alias NAME shows only that alias", body(out).count("q=echo fine") == 2, body(out)[-4:])

# ---- calc -------------------------------------------------------------------
def calc(expr):
    out, err, st = run("calc " + expr)
    return body(out)[0], err
r, e = calc("-9223372036854775808 / -1")
T.check("calc: INT64_MIN / -1 is an error, not SIGFPE", "overflow" in e.lower(), (r, e))
r, e = calc("5 % 3")
T.check("calc: unsupported operator is rejected", "Usage" in e, (r, e))
r, e = calc("1 + 2 abc")
T.check("calc: trailing garbage is rejected", "Usage" in e and r != "3", (r, e))
r, e = calc("99999999999999999999")
T.check("calc: a number past 64 bits is an error", "overflow" in e.lower(), (r, e))
r, e = calc("9223372036854775807 + 1")
T.check("calc: addition overflow is an error", "overflow" in e.lower(), (r, e))
r, e = calc("9223372036854775807 * 2")
T.check("calc: multiplication overflow is an error", "overflow" in e.lower(), (r, e))
r, e = calc("10 + 5 * 2")
T.check("calc: left to right as documented", r == "30", (r, e))
r, e = calc("-7 / 2")
T.check("calc: negative division", r == "-3", (r, e))
r, e = calc("1 / 0")
T.check("calc: division by zero", "ivision by zero" in e, (r, e))

# ---- grep -------------------------------------------------------------------
g = T.tmpdir()
open(g + "/g.txt", "w").write("hello world\nnothing\nsay hello again\n")
open(g + "/bin.dat", "wb").write(b"abc\x00hello\x00def\n")
open(g + "/long.txt", "w").write("x" * 70000 + " NEEDLE\n" + "NEEDLE short\n")
out, err, st = run(["grep hello g.txt", "echo st=$?", "grep nomatch g.txt", "echo st=$?"], cwd=g)
T.check("grep: matches print and set status 0, none sets 1",
        "hello world" in body(out) and "say hello again" in body(out) and "st=0" in body(out) and "st=1" in body(out), body(out))
out, err, st = run(["grep " + "A" * 400 + " g.txt", "echo st=$?", "whoami"], cwd=g, env={"USER": "bob"})
T.check("grep: over-long pattern is refused", "too long" in err and "st=2" in out, (err, body(out)))
out, err, st = run(["grep hello /tmp", "echo st=$?"], cwd=g)
T.check("grep: a directory is an error", "Is a directory" in err and "st=2" in out, (err, body(out)))
out, err, st = run(["grep hello nosuchfile", "echo st=$?"], cwd=g)
T.check("grep: missing file is an error", "Could not open" in err and "st=2" in out, (err, body(out)))
out, err, st = run(["grep hello bin.dat"], cwd=g)
T.check("grep: binary file is reported, not dumped", "Binary file bin.dat matches" in out and "\0" not in out, repr(out[-60:]))
out, err, st = run(["grep NEEDLE long.txt | wc -l", "grep NEEDLE long.txt", "echo st=$?"], cwd=g)
T.check("grep: very long lines are cut with a message", "truncated" in err and "NEEDLE short" in out, (err, out[-80:]))
# one write per run of text, not per character
big = g + "/many.txt"
open(big, "w").write(("NEEDLE " + "z" * 300 + "\n") * 200)
p = subprocess.run(["strace", "-c", "-e", "trace=write", "-o", g + "/st.txt", T.BIN],
                   input=b"grep NEEDLE many.txt\nexit\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                   cwd=g, env={"PATH": "/usr/bin:/bin", "HOME": g, "ASM_NO_UPDATE_CHECK": "1"}) if shutil.which("strace") else None
if p is not None and os.path.exists(g + "/st.txt"):
    m = re.search(r"^\s*[\d.]+\s+[\d.]+\s+\d+\s+(\d+)\s+(?:\d+\s+)?write$", open(g + "/st.txt").read(), re.M)
    T.check("grep: output is written in bulk", m and int(m.group(1)) < 2000, m and m.group(1))

# ---- ls ---------------------------------------------------------------------
l = T.tmpdir()
os.makedirs(l + "/zdir")
open(l + "/b.txt", "w").write("bb")
open(l + "/a.txt", "w").write("a")
os.symlink("/nonexistent_misc_zz", l + "/dangling")
os.symlink("a.txt", l + "/link")
open(l + "/.hid", "w").write("")
bad = "bad\x1bname"
open(os.path.join(l, bad), "w").write("")
out, err, st = run(["ls"], cwd=l)
names = body(out)[0].split()
T.check("ls: entries are sorted", names == sorted(names) and "a.txt" in names, names)
T.check("ls: hidden files need -a", ".hid" not in names, names)
out, err, st = run(["ls -a"], cwd=l)
T.check("ls: -a shows hidden files", ".hid" in body(out)[0].split(), body(out)[0])
out, err, st = run(["ls -l"], cwd=l)
lines = body(out)
T.check("ls: dangling link is shown as a link, not with stale data",
        any(x.startswith("l") and "dangling -> /nonexistent_misc_zz" in x for x in lines), lines)
T.check("ls: link to a file shows its target", any(x.startswith("l") and "link -> a.txt" in x for x in lines), lines)
T.check("ls: sizes of regular files", any(x.startswith("-") and x.rstrip().endswith("b.txt") and " 2 " in x for x in lines), lines)
out, err, st = run(["ls > %s/out.txt" % l], cwd=l)
T.check("ls: no colour codes in redirected output", "\x1b" not in open(l + "/out.txt", errors="replace").read().replace(bad, ""), "")
out, err, st = run(["ls a.txt b.txt"], cwd=l)
T.check("ls: several files", "a.txt" in out and "b.txt" in out, body(out))
out, err, st = run(["ls zdir a.txt"], cwd=l)
T.check("ls: a directory and a file together", "a.txt" in out and "zdir:" in out, body(out))
out, err, st = run(["ls nosuch_zz a.txt", "echo st=$?"], cwd=l)
T.check("ls: a missing path is reported and the rest listed", "a.txt" in out and "No such file" in err and "st=1" in out, (err, body(out)))
out, err, st = run(["ls -x", "echo st=$?"], cwd=l)
T.check("ls: unknown option is refused", "Usage" in err and "st=2" in out, (err, body(out)))
out, err, st = run(["ls a.txt -l"], cwd=l)
T.check("ls: options may follow the path", any(x.startswith("-") and "a.txt" in x for x in body(out)), body(out))
s = T.Sess(cwd=l)
s.settle()
s.run("ls")
T.check("ls: control bytes in names are shown as ? on a terminal", "bad?name" in s.screen() and b"bad\x1bname" not in s.vt.raw, s.screen()[-200:])
s.close()

# ---- cat / type -------------------------------------------------------------
out, err, st = run(["cat a.txt b.txt"], cwd=l)
T.check("cat: several files", "a" in out and "bb" in out and not err, (out[-30:], err))
out, err, st = run(["cat -n a.txt"], cwd=l)
T.check("cat: options go to /bin/cat", "1\ta" in out, repr(out[-40:]))
out, err, st = run(["cat < b.txt"], cwd=l)
T.check("cat: reads redirected stdin", "bb" in out, repr(out[-40:]))
out, err, st = run(["type zdir", "echo st=$?"], cwd=l)
T.check("type: a directory is an error", "Is a directory" in err and "st=1" in out, (err, body(out)))
out, err, st = run(["cat a.txt > %s/c.txt" % l, "echo st=$?"], cwd=l)
T.check("cat: redirect works", open(l + "/c.txt").read() == "a" and "st=0" in out, out[-30:])

# ---- dir / mkdir / whoami ---------------------------------------------------
dd = T.tmpdir()
with open(dd + "/big", "wb") as f:
    f.truncate(5 * 1024 ** 3)
with open(dd + "/exact4g", "wb") as f:
    f.truncate(4 * 1024 ** 3)
out, err, st = run(["dir"], cwd=dd)
T.check("dir: sizes of 4 GiB and more", "5368709120 big" in out and "4294967296 exact4g" in out, out[-100:])
out, err, st = run(["dir /nonexistent_misc_zz", "echo st=$?"], cwd=dd)
T.check("dir: a missing directory is an error without a header", "Directory of" not in out and "st=1" in out and err, (err, body(out)))
out, err, st = run(["mkdir -p", "echo st=$?"], cwd=dd)
T.check("mkdir: -p alone is a missing argument", "st=1" in out and not os.path.exists(dd + "/-p"), (err, os.listdir(dd)))
out, err, st = run(["mkdir -p x/y/z", "echo st=$?", "mkdir -p x/y/z", "echo st=$?"], cwd=dd)
T.check("mkdir: -p is idempotent on directories", os.path.isdir(dd + "/x/y/z") and out.count("st=0") == 2, (err, body(out)))
out, err, st = run(["mkdir -p big", "echo st=$?"], cwd=dd)
T.check("mkdir: -p onto a file is an error", "File exists" in err and "st=1" in out, (err, body(out)))
out, err, st = run(["whoami"], env={"USER": "mallory"})
import pwd
T.check("whoami: uses the real uid, not $USER", body(out)[0] == pwd.getpwuid(os.geteuid()).pw_name, body(out)[0])

# ---- script files -----------------------------------------------------------
rc = T.tmpdir()
open(rc + "/.asmrc", "w").write("#" * 4076 + "\nset MYPATH=/usr/local/bin:/usr/bin:/bin\n")
out, err, st = T.run_script("echo MYPATH=[$MYPATH]\nexit\n", home=rc)
T.check("asmrc: a file past 4095 bytes is read whole", "MYPATH=[/usr/local/bin:/usr/bin:/bin]" in out, out[-80:])
open(rc + "/big.rc", "w").write("echo first\n" + "#" * 6000 + "\necho marker-at-end\n")
out, err, st = T.run_script("source %s/big.rc\nexit\n" % rc, home=rc)
T.check("source: a file past 4095 bytes runs to the end", "marker-at-end" in out, out[-80:])
open(rc + "/huge.rc", "w").write("echo toobig\n" * 8000)
out, err, st = T.run_script("source %s/huge.rc\necho st=$?\nexit\n" % rc, home=rc)
T.check("source: an oversized file is refused, nothing runs", "toobig" not in out and "larger than" in err and "st=1" in out, (err, out[-60:]))
open(rc + "/nul.rc", "wb").write(b"echo before\n\x00echo after\n")
out, err, st = T.run_script("source %s/nul.rc\nexit\n" % rc, home=rc)
T.check("source: a NUL byte is refused, nothing runs", "before" not in out and "NUL" in err, (err, out[-60:]))
out, err, st = T.run_script("source %s/nosuch.rc\necho st=$?\nexit\n" % rc, home=rc)
T.check("source: missing file", "st=1" in out and err, (err, out[-40:]))
open(rc + "/ok.rc", "w").write("echo one\necho partial")
out, err, st = T.run_script("source %s/ok.rc\nexit\n" % rc, home=rc)
T.check("source: a last line without a newline still runs", "one" in out and "partial" in out, out[-60:])

# ---- environment passed to children -----------------------------------------
big = {"V%d" % i: "x" for i in range(1, 701)}
big["ZLAST"] = "found"
out, err, st = run(["set A=1", "sh -c 'echo ZLAST=$ZLAST; env | wc -l'"], env=big)
T.check("env: a large inherited environment reaches children whole",
        "ZLAST=found" in body(out) and any(l.strip().isdigit() and int(l) >= 700 for l in body(out)), body(out)[-3:])

# ---- autoexec.txt -----------------------------------------------------------
ax = T.tmpdir()
shutil.copy(T.BIN, ax + "/asm")
os.chmod(ax + "/asm", 0o755)
open(ax + "/autoexec.txt", "w").write("echo from-autoexec\n")
os.chmod(ax + "/autoexec.txt", 0o644)
home = T.tmpdir()
def run_ax():
    p = subprocess.run([ax + "/asm"], input=b"exit\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=home,
                       env={"PATH": "/usr/bin:/bin", "HOME": home, "ASM_NO_UPDATE_CHECK": "1"})
    return p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace")
o, e = run_ax()
T.check("autoexec: a private file next to the binary runs", "from-autoexec" in o, (o[-60:], e))
os.chmod(ax + "/autoexec.txt", 0o666)
o, e = run_ax()
T.check("autoexec: a world-writable file is ignored with a message", "from-autoexec" not in o and "autoexec.txt" in e, (o[-60:], e))
os.chmod(ax + "/autoexec.txt", 0o644)
open(ax + "/autoexec.txt", "w").write("#" * 5000 + "\necho late-line\n")
o, e = run_ax()
T.check("autoexec: a file past 4095 bytes runs to the end", "late-line" in o, (o[-60:], e))

T.cleanup()
