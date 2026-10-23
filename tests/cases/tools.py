import os, stat, time, subprocess
import ptytest as T


def sh(script, home=None, cwd=None, timeout=30):
    return T.run_script(script, home=home, cwd=cwd, timeout=timeout)


def rd(p):
    try:
        with open(p, 'rb') as f:
            return f.read()
    except OSError:
        return None


def trash_files(home):
    d = os.path.join(home, '.asm_trash')
    try:
        return sorted(n for n in os.listdir(d) if not n.startswith('.'))
    except OSError:
        return []


# ---------------------------------------------------------------- copy
d = T.tmpdir()
h = T.tmpdir()
open(d + '/a', 'w').write('hello\n')
out, err, st = sh('copy a a\nexit\n', home=h, cwd=d)
T.check('copy a a keeps the file', rd(d + '/a') == b'hello\n', rd(d + '/a'))
T.check('copy a a says same file', 'same file' in out, out)
T.check('copy a a leaves the trash alone', trash_files(h) == [], trash_files(h))
out, err, st = sh('copy a a\necho st=$?\nexit\n', home=h, cwd=d)
T.check('copy a a fails with status 1', 'st=1' in out, out)

# same file through a hard link and through ./
os.link(d + '/a', d + '/hard')
out, err, st = sh('copy a hard\ncopy a ./a\nexit\n', home=h, cwd=d)
T.check('copy onto a hard link keeps data', rd(d + '/a') == b'hello\n' and rd(d + '/hard') == b'hello\n', out)

# mode is preserved
open(d + '/key', 'w').write('secret\n')
os.chmod(d + '/key', 0o600)
open(d + '/run.sh', 'w').write('#!/bin/sh\n')
os.chmod(d + '/run.sh', 0o755)
sh('copy key key.bak\ncopy run.sh run2.sh\nexit\n', home=h, cwd=d)
T.check('copy keeps 0600', os.path.exists(d + '/key.bak') and stat.S_IMODE(os.stat(d + '/key.bak').st_mode) == 0o600)
T.check('copy keeps the exec bit', os.path.exists(d + '/run2.sh') and stat.S_IMODE(os.stat(d + '/run2.sh').st_mode) == 0o755)

# directories
os.mkdir(d + '/dd')
out, err, st = sh('copy a dd\necho st=$?\nexit\n', home=h, cwd=d)
T.check('copy onto a folder reports an error', 'st=1' in out and out.count('\n') > 3 and ('folder' in out or 'Is a' in out or 'directory' in out.lower()), out)
open(d + '/newfile', 'w').write('keepme\n')
out, err, st = sh('copy dd newfile\necho st=$?\nexit\n', home=h, cwd=d)
T.check('copy of a folder fails with status 1', 'st=1' in out, out)
T.check('copy of a folder leaves the destination alone', rd(d + '/newfile') == b'keepme\n', rd(d + '/newfile'))
out, err, st = sh('copy dd brandnew\nexit\n', home=h, cwd=d)
T.check('copy of a folder creates no stub', not os.path.exists(d + '/brandnew'))

# error texts and statuses
out, err, st = sh('copy nonexist b\necho st=$?\nexit\n', home=h, cwd=d)
T.check('copy missing source: clean message', '\0' not in out and 'st=1' in out and 'nonexist' not in out.replace('copy nonexist b', ''), repr(out))
T.check('copy missing source: no stub', not os.path.exists(d + '/b'))
out, err, st = sh('copy a /nonexistent_dir_x/b\necho st=$?\nexit\n', home=h, cwd=d)
T.check('copy to a bad destination fails loudly', 'st=1' in out and 'Error' in out, out)
out, err, st = sh('copy a\necho st=$?\nexit\n', home=h, cwd=d)
T.check('copy without destination: status 1', 'st=1' in out, out)

# big file crosses the chunk size
big = os.urandom(300000)
open(d + '/big', 'wb').write(big)
sh('copy big big2\nexit\n', home=h, cwd=d)
T.check('copy of a 300 kB file is exact', rd(d + '/big2') == big)

# overwrite goes to the trash and undo brings it back
open(d + '/old', 'w').write('old\n')
open(d + '/new', 'w').write('new\n')
h2 = T.tmpdir()
out, err, st = sh('copy new old\nexit\n', home=h2, cwd=d)
T.check('copy overwrite replaces', rd(d + '/old') == b'new\n')
T.check('copy overwrite keeps old in trash', len(trash_files(h2)) == 1 and trash_files(h2)[0].endswith('.old'), trash_files(h2))
out, err, st = sh('undo\nexit\n', home=h2, cwd=d)
T.check('undo copy restores the old file', rd(d + '/old') == b'old\n', out)

# ---------------------------------------------------------------- del / trash
d = T.tmpdir()
h = T.tmpdir()
open(d + '/f', 'w').write('one\n')
sh('del f\nexit\n', home=h, cwd=d)
tf = trash_files(h)
T.check('del moves to the trash', not os.path.exists(d + '/f') and len(tf) == 1, tf)
T.check('trash name keeps the base name', tf and tf[0].endswith('.f'), tf)
T.check('journal is on disk', os.path.exists(h + '/.asm_trash/.journal'))
out, err, st = sh('undo\nexit\n', home=h, cwd=d)       # a new process: journal survives
T.check('undo works after a restart', rd(d + '/f') == b'one\n', out)

# collisions: two files with the same name deleted in two sessions
open(d + '/f', 'w').write('first\n')
sh('del f\nexit\n', home=h, cwd=d)
open(d + '/f', 'w').write('second\n')
sh('del f\nexit\n', home=h, cwd=d)
T.check('two sessions, two trash files', len(trash_files(h)) == 2, trash_files(h))
sh('undo\nexit\n', home=h, cwd=d)
T.check('undo gives back the newest', rd(d + '/f') == b'second\n', rd(d + '/f'))
os.unlink(d + '/f')
sh('undo\nexit\n', home=h, cwd=d)
T.check('second undo gives back the older', rd(d + '/f') == b'first\n', rd(d + '/f'))

# many deletes in one session never collide
for i in range(20):
    open(d + '/m%d' % i, 'w').write('x%d\n' % i)
sh(''.join('del m%d\n' % i for i in range(20)) + 'exit\n', home=h, cwd=d)
T.check('20 deletes, 20 trash files', len(trash_files(h)) >= 20, trash_files(h))

# refusal when the trash cannot be used
d3 = T.tmpdir()
open(d3 + '/keep', 'w').write('precious\n')
out, err, st = sh('del keep\necho st=$?\nexit\n', home='/nonexistent-home', cwd=d3)
T.check('del refuses without a usable trash', os.path.exists(d3 + '/keep') and 'st=1' in out, out + err)
out, err, st = sh('del -f keep\necho st=$?\nexit\n', home='/nonexistent-home', cwd=d3)
T.check('del -f deletes for real', not os.path.exists(d3 + '/keep') and 'st=0' in out, out + err)
out, err, st = sh('del nosuchfile\necho st=$?\nexit\n', home=h, cwd=d3)
T.check('del of a missing file: status 1', 'st=1' in out, out)

# a failed restore keeps the journal entry
d4 = T.tmpdir()
h4 = T.tmpdir()
open(d4 + '/g', 'w').write('g1\n')
sh('del g\nexit\n', home=h4, cwd=d4)
open(d4 + '/g', 'w').write('in the way\n')
out, err, st = sh('undo\necho st=$?\nexit\n', home=h4, cwd=d4)
T.check('undo onto an existing file fails', 'st=1' in out and rd(d4 + '/g') == b'in the way\n', out)
os.unlink(d4 + '/g')
out, err, st = sh('undo\nexit\n', home=h4, cwd=d4)
T.check('the entry survived the failed undo', rd(d4 + '/g') == b'g1\n', out)
out, err, st = sh('undo\necho st=$?\nexit\n', home=h4, cwd=d4)
T.check('undo with nothing left: status 1', 'nothing to undo' in out and 'st=1' in out, out)

# trash listing and emptying
open(d4 + '/t1', 'w').write('t\n')
sh('del t1\nexit\n', home=h4, cwd=d4)
out, err, st = sh('trash\nexit\n', home=h4, cwd=d4)
T.check('trash lists entries', 't1' in out and '1 entries' in out, out)
out, err, st = sh('trash empty\nexit\n', home=h4, cwd=d4)
T.check('trash empty removes files', trash_files(h4) == [] and 'emptied' in out, (out, trash_files(h4)))
out, err, st = sh('undo\nexit\n', home=h4, cwd=d4)
T.check('undo after trash empty: nothing', 'nothing to undo' in out, out)

# ---------------------------------------------------------------- move
d = T.tmpdir()
h = T.tmpdir()
open(d + '/a', 'w').write('A\n')
open(d + '/b', 'w').write('B\n')
out, err, st = sh('move a a\necho st=$?\nexit\n', home=h, cwd=d)
T.check('move a a is a no-op, not ENOENT', rd(d + '/a') == b'A\n' and 'No such' not in out and 'st=0' in out, out)
out, err, st = sh('move a b\nexit\n', home=h, cwd=d)
T.check('move overwrite saves the old file', rd(d + '/b') == b'A\n' and len(trash_files(h)) == 1, trash_files(h))
sh('undo\nexit\n', home=h, cwd=d)
T.check('undo move restores both', rd(d + '/a') == b'A\n' and rd(d + '/b') == b'B\n', (rd(d + '/a'), rd(d + '/b')))
out, err, st = sh('move nosuch zz\necho st=$?\nexit\n', home=h, cwd=d)
T.check('move of a missing file: status 1', 'st=1' in out, out)

# folders are journaled too
os.mkdir(d + '/dir1')
open(d + '/dir1/inner', 'w').write('in\n')
sh('move dir1 dir2\nexit\n', home=h, cwd=d)
T.check('folder moved', os.path.isdir(d + '/dir2') and not os.path.exists(d + '/dir1'))
sh('undo\nexit\n', home=h, cwd=d)
T.check('undo moves the folder back', os.path.isdir(d + '/dir1') and not os.path.exists(d + '/dir2'))

# unusable trash: refuse an overwrite unless -f
open(d + '/c', 'w').write('C\n')
out, err, st = sh('move a c\necho st=$?\nexit\n', home='/nonexistent-home', cwd=d)
T.check('move refuses to overwrite without a trash', rd(d + '/c') == b'C\n' and rd(d + '/a') == b'A\n' and 'st=1' in out, out + err)
out, err, st = sh('move -f a c\nexit\n', home='/nonexistent-home', cwd=d)
T.check('move -f overwrites anyway', rd(d + '/c') == b'A\n')
out, err, st = sh('move b freshname\nexit\n', home='/nonexistent-home', cwd=d)
T.check('move to a new name needs no trash', rd(d + '/freshname') == b'B\n', out + err)

# ---------------------------------------------------------------- undo of a copy
d = T.tmpdir()
h = T.tmpdir()
open(d + '/s', 'w').write('src\n')
sh('copy s t\nexit\n', home=h, cwd=d)
open(d + '/t', 'w').write('edited since\n')
out, err, st = sh('undo\necho st=$?\nexit\n', home=h, cwd=d)
T.check('undo of an edited copy keeps its content', not os.path.exists(d + '/t') and any(rd(h + '/.asm_trash/' + n) == b'edited since\n' for n in trash_files(h)), (out, trash_files(h)))
sh('copy s u\nexit\n', home=h, cwd=d)
out, err, st = sh('undo\nexit\n', home=h, cwd=d)
T.check('undo of an untouched copy removes it', not os.path.exists(d + '/u'), out)

# ---------------------------------------------------------------- retention
d = T.tmpdir()
h = T.tmpdir()
hugef = d + '/huge'
with open(hugef, 'wb') as f:
    f.truncate(600 * 1024 * 1024)
out, err, st = sh('del huge\necho st=$?\nexit\n', home=h, cwd=d)
T.check('del refuses a file over the trash limit', os.path.exists(hugef) and 'st=1' in out, out + err)
os.unlink(hugef)

# ---------------------------------------------------------------- bench
out, err, st = sh('bench bench -n 2 true\necho STILL-VISIBLE\nexit\n')
T.check('nested bench keeps stdout', 'STILL-VISIBLE' in out, out)
out, err, st = sh('bench -n 4294967297 true\nexit\n')
T.check('bench -n huge is rejected', '1 and 100000' in out + err and '(1 run' not in out, out + err)
out, err, st = sh('bench -n 0 true\nexit\n')
T.check('bench -n 0 says why', '1 and 100000' in out + err, out + err)
out, err, st = sh('bench -n 100001 true\nexit\n')
T.check('bench -n 100001 says why', '1 and 100000' in out + err, out + err)
out, err, st = sh('bench -n 1 true\nexit\n')
T.check('bench 1 run is singular', '(1 run)' in out, out)
out, err, st = sh('bench -n 20 ls /nonexistent_dir_q\nexit\n')
T.check('bench hides stderr of the command', out.count('nonexistent_dir_q') <= 1 and err.count('nonexistent_dir_q') == 0, (out, err))
out, err, st = sh('bench -n 3 cat\necho after\nexit\n')
T.check('bench gives the command an empty stdin', 'after' in out and 'mean' in out, out)

T.cleanup()
