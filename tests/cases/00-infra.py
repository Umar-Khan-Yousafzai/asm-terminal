import ptytest as T

s = T.Sess()
s.settle()
s.run("echo infra-ok")
T.check("cases: pty session runs a command", "infra-ok" in s.screen(), s.screen())
s.close()
out, err, st = T.run_script("echo piped\nexit 3\n")
T.check("cases: run_script returns status", st == 3 and "piped" in out, (out, st))
T.cleanup()
