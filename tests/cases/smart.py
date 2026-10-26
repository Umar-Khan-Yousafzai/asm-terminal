import os, re
import ptytest as T

# Smart typing (ash/smart.asm): grey history suggestions, history notes with
# folder and exit status, `history .`


def prompt_line(s):
    """The last screen line that holds a prompt."""
    lines = [l for l in s.screen().split("\n") if "$ " in l]
    return lines[-1].rstrip() if lines else ""


home = T.tmpdir()
a = T.tmpdir()
b = T.tmpdir()

s = T.Sess(home=home, cwd=a, cols=120)
s.settle()
s.run("echo hello-sugg")
s.send("echo hel"); s.settle()
T.check("suggestion shows the rest of a history entry", prompt_line(s).endswith("echo hello-sugg"), prompt_line(s))
T.check("cursor stays behind the typed text", s.vt.c == prompt_line(s).index("echo hel") + len("echo hel"), (s.vt.c, prompt_line(s)))
s.send("\r"); s.settle()
T.check("Enter runs only what was typed", re.search(r"^hel$", s.screen(), re.M) is not None, s.screen()[-300:])
T.check("Enter leaves no grey text behind", "$ echo hello-sugg" not in s.screen().split("$ echo hel\n")[-1] and
        any(l.rstrip().endswith("$ echo hel") for l in s.screen().split("\n")), s.screen()[-300:])

s.send("echo hel\x1b[C"); s.settle()
T.check("Right arrow accepts the suggestion", prompt_line(s).endswith("echo hello-sugg"), prompt_line(s))
s.send("\r"); s.settle()
T.check("accepted suggestion runs", s.screen().count("hello-sugg") >= 3, s.screen()[-300:])

s.send("\x05"); s.settle()
s.send("echo hel\x05"); s.settle()
T.check("End / Ctrl+E accepts the suggestion", prompt_line(s).endswith("echo hello-sugg"), prompt_line(s))
s.send("\x15"); s.settle()

# a command that worked beats a newer one that failed
s.run("ls /tmp")
s.run("ls /nonexistent-asm-zz")
s.send("ls /"); s.settle()
T.check("suggestion prefers a command that worked", prompt_line(s).endswith("ls /tmp"), prompt_line(s))
s.send("\x15"); s.settle()

# the same folder beats a newer entry from another folder
s.run("echo pick-here")
s.run("cd " + b)
s.run("echo pick-there")
s.run("cd " + a)
s.send("echo pick-"); s.settle()
T.check("suggestion prefers this folder", prompt_line(s).endswith("echo pick-here"), prompt_line(s))
s.send("\x15"); s.settle()

s.run("history")
T.check("history marks a failed command", re.search(r"ls /nonexistent-asm-zz  \[[1-9][0-9]*\]", s.screen()) is not None, s.screen()[-400:])
s.run("cd " + b)
s.send("\x0c"); s.settle()
s.run("history .")
scr = s.screen()
T.check("history . lists commands run here", "echo pick-there" in scr, scr[-400:])
T.check("history . leaves out other folders", "pick-here" not in scr and "hello-sugg" not in scr, scr[-400:])
s.close()

data = open(home + "/.asm_history").read()
T.check("history file keeps notes", re.search(r"^ls /nonexistent-asm-zz\n#asm:[0-9a-f]{8}:[1-9][0-9]*$", data, re.M) is not None, data[-300:])

# notes survive a restart
s = T.Sess(home=home, cwd=a, cols=120)
s.settle()
s.send("ls /"); s.settle()
T.check("notes are loaded again", prompt_line(s).endswith("ls /tmp"), prompt_line(s))
s.send("\x15"); s.settle()
s.run("history")
T.check("notes are not listed as commands", "#asm:" not in s.screen(), s.screen()[-400:])
s.close()

T.cleanup()
