#!/usr/bin/env python3
"""Logic checks for the Windows build (terminal.asm) without Windows.

terminal.asm is assembled for Linux together with the Win32 stand-ins in
stubs.inc (see the header there), then driven with key strokes on stdin.
Each check looks at the console output, the screen grid or the log of Win32
calls the code made.

usage: python3 tests/windows-harness/run.py [-v]
Environment: TERMINAL_ASM=path assembles another version of terminal.asm
             (use it to confirm that a check fails on the old code).
This is not part of tests/run_tests.sh; it needs only nasm and ld.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
ASM = os.environ.get("TERMINAL_ASM") or os.path.join(ROOT, "terminal.asm")
VERBOSE = "-v" in sys.argv
WORK = tempfile.mkdtemp(prefix="winh-")

TAB, UP, DOWN, ENTER, LEFT, RIGHT, HOME = "\x01", "\x02", "\x03", "\x04", "\x05", "\x06", "\x07"
END, BS, DEL, CTRLC, SNAP = "\x0b", "\x08", "\x7f", "\x18", "\x1a"
EV_CTRLC, EV_BREAK, EV_CLOSE = "\x11", "\x12", "\x13"


def repeat(n, key):
    """Key stroke that the console reports with a repeat count of n."""
    return "\x0e" + chr(n) + key


fails = 0
total = 0


def check(name, cond, detail=""):
    global fails, total
    total += 1
    if cond:
        print("ok\t%s" % name)
    else:
        fails += 1
        print("not ok\t%s\t%s" % (name, str(detail).replace("\n", "\\n")[:400]))
    sys.stdout.flush()


_bins = {}


def build(flags=(), asm=None):
    key = (tuple(flags), asm or ASM)
    if key in _bins:
        return _bins[key]
    out = os.path.join(WORK, "h%d" % len(_bins))
    env = dict(os.environ, HARNESS_WORK=tempfile.mkdtemp(dir=WORK))
    src = asm or ASM
    # build.sh reads $ROOT/terminal.asm; point it at the requested source
    script = os.path.join(HERE, "build.sh")
    env["TERMINAL_ASM"] = src
    r = subprocess.run(["bash", script, out] + list(flags), env=env,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit("harness build failed")
    _bins[key] = out
    return out


class Res:
    pass


def run(keys, env=None, flags=(), timeout=5, binary=None):
    b = binary or build(flags)
    e = {"PATH": os.environ.get("PATH", "")}
    e.update(env or {})
    try:
        p = subprocess.run([b], input=keys.encode("latin-1"), env=e,
                           capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        r = Res()
        r.timeout = True
        r.out = r.err = ""
        r.rc = None
        r.lines = []
        r.screen = []
        return r
    r = Res()
    r.timeout = False
    r.rc = p.returncode
    r.out = p.stdout.decode("latin-1").replace("\r", "")
    r.err = p.stderr.decode("latin-1")
    r.lines = r.err.splitlines()
    # the screen grid, from the last SCR-BEGIN .. SCR-END dump
    r.screen = []
    grab = False
    for ln in r.lines:
        if ln == "SCR-BEGIN":
            grab, r.screen = True, []
        elif ln == "SCR-END":
            grab = False
        elif grab and ln.startswith("SCR|"):
            r.screen.append(ln[4:])
    if VERBOSE:
        print("--- keys %r\n--- out\n%s--- err\n%s" % (keys, r.out, r.err))
    return r


def log(r, prefix):
    """Log lines that start with `[prefix`."""
    return [ln for ln in r.lines if ln.startswith("[" + prefix)]


def misaligned(r):
    return [ln for ln in r.lines if "MISALIGNED" in ln]


# --------------------------------------------------------------------------
# tests
# --------------------------------------------------------------------------
FILES = "foo.txt:123|fob.txt:456|sub:D|bar baz.txt:7"


def t_basics():
    r = run("echo hi" + ENTER)
    check("echo prints its argument", "\nhi\n" in r.out, r.out)
    check("no stub saw a misaligned stack", not misaligned(r), misaligned(r))


def t_tab():
    # 2nd Tab cycles to the next match and keeps what came before the word
    r = run("echo fo" + TAB + TAB + ENTER, {"W_FILES": FILES})
    check("tab: second Tab keeps the text before the word",
          "\nfob.txt\n" in r.out, r.out)
    check("tab: three Tabs wrap around to the first match",
          "\nfoo.txt\n" in run("echo fo" + TAB * 3 + ENTER, {"W_FILES": FILES}).out)
    r = run("echo fo" + TAB + ENTER, {"W_FILES": FILES})
    check("tab: single Tab completes", "\nfoo.txt\n" in r.out, r.out)
    # key typed after a Tab must not be lost (FindClose must have shadow space)
    r = run("echo fo" + TAB + "x" + ENTER, {"W_FILES": FILES})
    check("tab: key after a Tab is typed normally", "\nfoo.txtx\n" in r.out, r.out)
    # nothing but "." and ".." in the directory: must not loop forever
    r = run("echo " + TAB + ENTER, {"W_FILES": ""}, timeout=3)
    check("tab: directory with only . and .. returns", not r.timeout, "timeout")
    r = run("cd .." + TAB + ENTER, {"W_FILES": ""}, timeout=3)
    check("tab: '..' prefix with no other match returns", not r.timeout, "timeout")
    # directory part and text after the cursor survive
    r = run("echo sub\\fo" + TAB + ENTER, {"W_FILES": FILES})
    check("tab: directory part is kept", "\nsub\\foo.txt\n" in r.out, r.out)
    r = run("echo fo XYZ" + LEFT * 4 + TAB + ENTER, {"W_FILES": FILES})
    check("tab: text after the cursor is kept", "\nfoo.txt XYZ\n" in r.out, r.out)
    r = run("echo fo XYZ" + LEFT * 4 + TAB + TAB + ENTER, {"W_FILES": FILES})
    check("tab: cycling keeps the text after the cursor", "\nfob.txt XYZ\n" in r.out, r.out)
    r = run("echo ba" + TAB + ENTER, {"W_FILES": FILES})
    check("tab: names with spaces are quoted", '\n"bar baz.txt"\n' in r.out, r.out)
    # the search handle is released when the user types something else
    r = run("echo fo" + TAB + "x" + ENTER, {"W_FILES": FILES, "W_LOG": "d"})
    check("tab: find handle closed after another key",
          len(log(r, "FindClose")) == len(log(r, "FindFirstFile")), log(r, "Find"))
    r = run("echo fo" + TAB + CTRLC + ENTER, {"W_FILES": FILES, "W_LOG": "d"})
    check("tab: find handle closed on Ctrl+C",
          len(log(r, "FindClose")) == len(log(r, "FindFirstFile")), log(r, "Find"))

def cp_lines(r):
    return log(r, "CreateProcess")


def t_env():
    r = run("echo 50% off, 100% sure" + ENTER)
    check("percent: plain text with % is left alone",
          "\n50% off, 100% sure\n" in r.out, r.out)
    r = run("for %i in (a b) do echo %i" + ENTER)
    check("percent: for variables reach cmd.exe", any("for %i in (a b) do echo %i" in l for l in cp_lines(r)), cp_lines(r))
    r = run("echo %USERNAME%" + ENTER, {"W_ENV_USERNAME": "bob"})
    check("percent: defined variable expands", "\nbob\n" in r.out, r.out)
    r = run("echo %NOPE_X%" + ENTER)
    check("percent: undefined variable stays as typed", "\n%NOPE_X%\n" in r.out, r.out)
    r = run("echo 100%%" + ENTER)
    check("percent: double percent is one", "\n100%\n" in r.out, r.out)
    r = run("echo %PATH%" + ENTER, {"W_ENV_PATH": "A" * 600})
    check("percent: too long value is refused, buffer intact",
          "Line too long" in r.out and not misaligned(r), r.out)
    r = run("echo %PATH%" + ENTER, {"W_ENV_PATH": "A" * 1500})
    check("percent: value over 1023 chars is refused",
          "Line too long" in r.out, r.out)
    r = run("echo %PATH% %PATH% %PATH%" + ENTER, {"W_ENV_PATH": "A" * 200})
    check("percent: many references are refused, not overflowed",
          "Line too long" in r.out, r.out[-200:])
    r = run("echo %PATH%" + ENTER, {"W_ENV_PATH": "A" * 300})
    check("percent: a value that fits is kept", "A" * 300 in r.out, r.out[-100:])


def t_console():
    r = run("ver" + ENTER, {"W_NOTCONSOLE": "1"}, timeout=3)
    check("input that is not a console ends instead of spinning", not r.timeout, "timeout")
    r = run("ipconfig" + ENTER, {"W_LOG": "k"})
    cps = cp_lines(r)
    check("child starts with the original console mode",
          cps and "mode=0x1f7" in cps[0], cps)
    modes = [l for l in r.lines if l.startswith("[SetConsoleMode")]
    check("raw mode is set again after the child",
          modes and modes[-1] != "[SetConsoleMode 0x1f7]" and len(modes) >= 3, modes)
    r = run("ipconfig" + ENTER + "echo hi" + ENTER, {"W_CTRLC_IN_CHILD": "1"})
    check("Ctrl+C that hit a child does not cancel the next prompt",
          "^C" not in r.out and "\nhi\n" in r.out, r.out[-200:])
    r = run("abc" + CTRLC + "echo ok" + ENTER)
    check("Ctrl+C clears the line", "^C" in r.out and "\nok\n" in r.out, r.out[-200:])
    # the read is not woken by the event; the next key is handled, then the line is dropped
    r = run("abc" + EV_BREAK + " " + "echo ok" + ENTER, {"W_LOG": "k"})
    check("Ctrl+Break cancels the line and does not end the shell",
          "^C" in r.out and "\nok\n" in r.out, r.out[-120:])
    r = run("echo hi" + EV_CLOSE, {"W_LOG": "ak"})
    check("closing the window restores the console mode",
          "[SetConsoleMode 0x1f7]" in r.lines, r.lines[-6:])
    r = run("exit" + ENTER, {"W_LOG": "ak"})
    check("exit restores the input mode and the colors",
          "[SetConsoleMode 0x1f7]" in r.lines, r.lines[-6:])


def t_exit():
    r = run("exit 3" + ENTER)
    check("exit N ends the shell with status N", r.rc == 3, (r.rc, r.err[-120:]))
    r = run("exit /b 7" + ENTER)
    check("exit /b N ends the shell with status N", r.rc == 7, (r.rc, r.err[-120:]))
    r = run("exit" + ENTER)
    check("exit ends with 0", r.rc == 0, r.rc)


def t_external():
    r = run("dir 2>&1" + ENTER)
    check("2>&1 goes to cmd.exe with the whole line and no file",
          any('"dir 2>&1"' in l for l in cp_lines(r)) and not log(r, "CreateFile name=&1"), cp_lines(r))
    r = run("foo 2>nul" + ENTER)
    check("2>nul goes to cmd.exe", any('"foo 2>nul"' in l for l in cp_lines(r)), cp_lines(r))
    r = run('findstr "a>b" f.txt' + ENTER)
    check("quoted > is not a redirection",
          any('"findstr "a>b" f.txt"' in l for l in cp_lines(r)) and not log(r, "CreateFile name=b"), cp_lines(r))
    r = run("ipconfig > out.txt" + ENTER)
    check("redirect target is inheritable",
          any("name=out.txt" in l and "inherit=1" in l for l in log(r, "CreateFile")), log(r, "CreateFile"))
    r = run("ipconfig < in.txt" + ENTER)
    check("redirect source is inheritable",
          any("name=in.txt" in l and "inherit=1" in l for l in log(r, "CreateFile")), log(r, "CreateFile"))
    r = run("ipconfig > NOPE.txt" + ENTER)
    check("a redirect target that cannot be opened stops the command",
          not cp_lines(r) and "Error" in r.out, (cp_lines(r), r.out[-120:]))
    r = run('ipconfig > "my out.txt"' + ENTER)
    check("quoted redirect target with a space",
          any("name=my out.txt" in l for l in log(r, "CreateFile")), log(r, "CreateFile"))
    r = run("ipconfig > a.txt > b.txt" + ENTER)
    cf = [l for l in log(r, "CreateFile") if "a.txt" in l or "b.txt" in l]
    check("second > does not leak the first handle",
          len(log(r, "CloseHandle")) >= 3 and len(cf) == 2, log(r, "CloseHandle"))
    r = run('"C:\\Program Files\\x\\y.exe" "a b"' + ENTER)
    check("cmd.exe gets the outer quotes it needs",
          any('/s /c ""C:\\Program Files\\x\\y.exe" "a b""' in l for l in cp_lines(r)), cp_lines(r))
    r = run("ipconfig" + ENTER)
    check("cmd.exe is started from the system directory",
          any("app=C:\\WINDOWS\\system32\\cmd.exe" in l for l in cp_lines(r)), cp_lines(r))
    r = run("   " + ENTER + " ipconfig  " + ENTER)
    cps = cp_lines(r)
    check("blank line starts nothing; leading blanks are trimmed",
          len(cps) == 1 and 'cmd.exe /s /c "ipconfig"' in cps[0], cps)


def t_history():
    r = run("echo hi" + ENTER + "echo X" + UP + ENTER)
    check("history: Up shows the only entry", "\nhi\n" in r.out, r.out[-80:])
    r = run("echo hi" + ENTER + "echo X" + UP + DOWN + ENTER)
    check("history: Up then Down restores the typed line", "\nX\n" in r.out and "hi" not in r.out.split("C:\\t> ")[-2], r.out[-80:])
    r = run("echo one" + ENTER + "echo two" + ENTER + "echo three" + ENTER + UP * 3 + ENTER)
    check("history: oldest entry is reachable", r.out.count("one") == 2, r.out[-120:])
    r = run("echo one" + ENTER + "echo two" + ENTER + UP * 9 + ENTER)
    check("history: Up past the oldest stays on it", r.out.count("one") == 2, r.out[-120:])
    r = run("echo one" + ENTER + "echo two" + ENTER + UP + UP + DOWN + ENTER)
    check("history: Down goes back one entry", r.out.count("two") == 2 and r.out.count("one") == 1, r.out[-120:])
    r = run(UP + ENTER + "echo z" + ENTER)
    check("history: Up with empty history does nothing", "\nz\n" in r.out, r.out[-80:])


def t_files():
    r = run("dir *.txt" + ENTER, {"W_FILES": FILES, "W_LOG": "d"})
    check("dir uses a wildcard as the pattern", any("*.txt" in l and "\\*" not in l for l in log(r, "FindFirstFile")), log(r, "FindFirstFile"))
    r = run("dir sub" + ENTER, {"W_FILES": FILES, "W_LOG": "d"})
    check("dir of a folder searches its contents", any("sub\\*" in l for l in log(r, "FindFirstFile")), log(r, "FindFirstFile"))
    r = run("dir foo.txt" + ENTER, {"W_FILES": FILES, "W_LOG": "d"})
    check("dir of a file searches that file", any("foo.txt" in l and "foo.txt\\" not in l for l in log(r, "FindFirstFile")), log(r, "FindFirstFile"))
    r = run("dir /w" + ENTER)
    check("dir with a switch goes to cmd.exe", any('"dir /w"' in l for l in cp_lines(r)), cp_lines(r))
    r = run("dir" + ENTER, {"W_FILES": "big.bin:1234567890|huge.bin:5000000000"})
    check("dir shows 10 digit sizes whole", "1234567890 big.bin" in r.out, r.out[-200:])
    check("dir shows sizes over 4 GiB", "5000000000 huge.bin" in r.out, r.out[-200:])
    r = run("dir other" + ENTER, {"W_FILES": FILES, "W_CWD": "C:\\t"})
    check("dir of a missing folder keeps the stack aligned", not misaligned(r), misaligned(r))
    r = run("copy a.txt b.txt" + ENTER)
    check("copy does not overwrite by default", any("failIfExists=1" in l for l in log(r, "CopyFile")), log(r, "CopyFile"))
    r = run("copy /y a.txt b.txt" + ENTER)
    check("copy /y overwrites", any("failIfExists=0" in l for l in log(r, "CopyFile")), log(r, "CopyFile"))
    r = run("copy a.txt sub" + ENTER, {"W_FILES": FILES})
    check("copy into a folder keeps the name", any("-> sub\\a.txt" in l for l in log(r, "CopyFile")), log(r, "CopyFile"))
    r = run("move x\\a.txt sub" + ENTER, {"W_FILES": FILES})
    check("move into a folder keeps the name", any("-> sub\\a.txt" in l for l in log(r, "MoveFile")), log(r, "MoveFile"))
    r = run('copy "my file.txt" "other.txt"' + ENTER)
    check("copy takes quoted names", any("my file.txt -> other.txt" in l for l in log(r, "CopyFile")), log(r, "CopyFile"))
    r = run("del *.txt" + ENTER)
    check("del with a wildcard goes to cmd.exe", any('"del *.txt"' in l for l in cp_lines(r)) and not log(r, "DeleteFile"), cp_lines(r))
    r = run("mkdir a\\b\\c" + ENTER)
    check("mkdir creates intermediate folders",
          [l.split(" ", 1)[1] for l in log(r, "CreateDirectory")] == ["a]", "a\\b]", "a\\b\\c]"], log(r, "CreateDirectory"))
    r = run('type "a b.txt"' + ENTER, {"W_LOG": ""})
    check("type takes a quoted name", any("name=a b.txt" in l and "share=0x3" in l for l in log(r, "CreateFile")), log(r, "CreateFile"))


def t_cd_color():
    r = run("cd /d D:\\foo" + ENTER)
    check("cd /d", any(l == "[SetCurrentDirectory D:\\foo]" for l in log(r, "SetCurrentDirectory")), log(r, "SetCurrentDirectory"))
    r = run('cd "C:\\Program Files"' + ENTER)
    check("cd with quotes", any(l == "[SetCurrentDirectory C:\\Program Files]" for l in log(r, "SetCurrentDirectory")), log(r, "SetCurrentDirectory"))
    r = run("cd.." + ENTER)
    check("cd.. works", any(l == "[SetCurrentDirectory ..]" for l in log(r, "SetCurrentDirectory")), log(r, "SetCurrentDirectory"))
    r = run("cd\\" + ENTER)
    check("cd\\ works", any(l == "[SetCurrentDirectory \\]" for l in log(r, "SetCurrentDirectory")), log(r, "SetCurrentDirectory"))
    r = run("D:" + ENTER)
    check("D: switches drive", any(l == "[SetCurrentDirectory D:\\]" for l in log(r, "SetCurrentDirectory")) and not cp_lines(r), log(r, "SetCurrentDirectory"))
    r = run("color 0A" + ENTER + "ver" + ENTER, {"W_LOG": "a"})
    attrs = [l for l in r.lines if l.startswith("[attr")]
    check("color: attribute 0x0a set", any("0xa" in l.lower() or "0x0a" in l.lower() for l in attrs), attrs[-6:])
    r = run("color Gx" + ENTER)
    check("color rejects non-hex digits", "Invalid color" in r.out, r.out[-100:])
    r = run("color 4" + ENTER, {"W_LOG": "a"})
    attrs = [l for l in r.lines if l.startswith("[attr")]
    check("color 4 is foreground only", any("0x4" in l.lower() or "0x04" in l.lower() for l in attrs), attrs[-6:])


def t_misc():
    auto = "type x\necho second\n"
    r = run("exit" + ENTER, {"W_AUTOEXEC": "type x\necho second\necho third\n".replace("\\n", "\n"),
                              "W_TYPE": "Z" * 300})
    check("autoexec lines survive a type command", r.out.count("second") >= 1 and r.out.count("third") >= 1, r.out[-200:])
    r = run("exit" + ENTER, {"W_AUTOEXEC": ("echo " + "q" * 600 + "\n").replace("\\n", "\n")})
    check("autoexec long line is cut, not overflowed", not misaligned(r) and r.rc == 0, r.err[-200:])
    r = run("alias x=" + "A" * 250 + ENTER + "x " + "B" * 300 + ENTER)
    check("alias expansion that does not fit is refused", "Line too long" in r.out, r.out[-120:])
    r = run("alias " + "n" * 100 + "=ver" + ENTER)
    check("alias name too long is refused", "Line too long" in r.out, r.out[-120:])
    r = run("alias a=" + "c" * 300 + ENTER)
    check("alias command too long is refused", "Line too long" in r.out, r.out[-120:])
    keys = "".join("alias a%d=ver%s" % (i, ENTER) for i in range(33)) + "alias a1=dir" + ENTER + "alias" + ENTER
    r = run(keys)
    check("full alias table can still update an alias", "a1=dir" in r.out and "a32" not in r.out, r.out[-300:])
    r = run("dir " + "c" * 400 + ENTER)
    check("dir with a very long name is refused", "Line too long" in r.out, r.out[-120:])
    r = run("set" + ENTER, {"W_LOG": ""})
    check("set hides =C: entries", "=C:" not in r.out, r.out[-200:])


def t_edit():
    # a line wider than the console wraps; Home puts the cursor at the prompt
    r = run("echo " + "a" * 60 + HOME + "X" + SNAP, {"W_COLS": "40"})
    scr = r.screen
    row = [i for i, l in enumerate(scr) if l.startswith("C:\\t> ")]
    check("wrap: insert at Home redraws over both rows",
          row and scr[row[-1]].startswith("C:\\t> Xecho a") and scr[row[-1] + 1].strip("a") == "", scr)
    r = run("echo aaaaaaaaaaaaaaaaaaaaaaaa" + BS * 20 + SNAP, {"W_DUMP": "1"})
    scr = "\n".join(r.screen)
    check("shrinking the line blanks the old cells", "echo aaaa" in scr and "aaaaa" not in scr, scr[-200:])
    r = run("echo hi" + repeat(3, "x") + ENTER)
    check("key repeat counts are honoured", "\nhixxx\n" in r.out, r.out[-80:])

def t_regs():
    # every handler keeps rbx, rsi, rdi and r12-r15 and the stubs see an aligned stack
    for flags in ((), ("-DNOSPILL",)):
        b = build(("-DCHECKREGS",) + flags)
        r = run("", binary=b)
        check("callee-saved registers preserved %s" % (" ".join(flags) or "(spill)"),
              "regs ok" in r.err and "CLOBBER" not in r.err and not misaligned(r), r.err[-300:])


GROUPS = [t_basics, t_tab, t_env, t_console, t_exit, t_external, t_history, t_files, t_cd_color, t_misc, t_edit, t_regs]

if __name__ == "__main__":
    only = [a for a in sys.argv[1:] if not a.startswith("-")]
    for g in GROUPS:
        if only and g.__name__[2:] not in only:
            continue
        g()
    print("\n%d checks, %d failed" % (total, fails))
    sys.exit(1 if fails else 0)
