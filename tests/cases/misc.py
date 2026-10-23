#!/usr/bin/env python3
"""Builtin behaviour: exit statuses, stderr, environment overlay, aliases,
cd/pushd/popd, cat/ls/grep/calc/color/title/date and rc/source loading."""
import os, re, ptytest as T

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

T.cleanup()
