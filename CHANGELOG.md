# Changelog

All notable changes to ASM Terminal. Versions follow [Semantic Versioning](https://semver.org/):
MAJOR for breaking changes, MINOR for new features, PATCH for fixes.
The version lives in one place: `version.inc`.

## [2.4.0] - 2026-10-23

The script engine and the builtins lose the limits that 2.3.0 listed: `"$@"`, `. file`, `case`,
wildcards in builtins and long command lines now work. The shell also suggests commands from
history while you type, lists every Tab match, and `help` is a table.

### Added
- `case WORD in pat) ...;; esac` runs natively, so assignments, `cd` and functions made in a clause
  persist. Patterns support `*`, `?`, `[...]`, `[:class:]`, `|` alternation, quoting and `$var`; it
  works inside `if`, `while`, `for` and functions. A `case` that is piped, redirected or put in the
  background is still handed to `/bin/sh`.
- `. file` is a synonym for `source file`.
- `"$@"` expands to one word per parameter (`"$*"` to one word), and to nothing when there are no
  parameters, in commands, function calls and `for` lists.
- Builtins that take file names (`echo`, `ls`, `cat`, `grep`, `cd`, `pushd`, `source`, `del`, `copy`,
  `move`, `rename`, `mkdir`, `rmdir`) expand `*`, `?` and `[...]` like external commands. Results are
  sorted; no match keeps the pattern; names with spaces or special characters stay one word.
  `del`, `mkdir` and `rmdir` run once per match; `copy` and `move` take several sources and a target
  folder.
- **Suggestions while typing**: the rest of a matching command from history shows in grey behind
  the cursor. Right arrow, End, Ctrl+E or Ctrl+F accepts it; Enter runs only what was typed.
  Commands run in the same folder that worked come first, then any that worked, then the rest.
- **Tab lists every match**: while Tab cycles through file names, all matches show under the line
  with the current one highlighted (folders in blue). Any other key closes the list.
- **History remembers folder and result**: each entry keeps the folder it ran in and its exit
  status. `history` marks failed commands with `[N]`, and `history .` lists only the commands run
  in the current folder. The notes are stored in `~/.asm_history` as `#asm:HASH:STATUS` lines
  after each command; older versions read them as comments.

### Changed
- A command line may be up to 65535 bytes after expansion (scripts, sourced files, long variables,
  `$(...)` output). `cd ~` with a very long `HOME` works. The line editor and history entries stay
  at 511 bytes.
- Builtins with small work buffers (`title`, `color`, `calc`, `alias`, `bench`, `trace`, `sandbox`)
  refuse arguments of 512 bytes or more with an error.
- `;;` outside a `case` is a syntax error instead of being skipped.
- `${x:-d}` and similar forms inside a `case` now report "unsupported ${...} expansion", like inside
  an `if`; before, the whole `case` ran in `/bin/sh`.
- `.bss` grew to about 22 MB of address space (line buffers and glob tables; only touched pages
  cost memory).
- `help` is now a table with Command, Usage and Example columns, grouped by section. Each run
  picks a random example per command. Commands that destroy data show in red. On terminals
  narrower than 95 columns the example moves to its own line.

### Fixed
- `cd` no longer prints "variable too long" when the directory does not fit in `PWD`.

### Known limits
- Loops with a redirected or piped `done`, and a piped or redirected `case`, still run in `/bin/sh`
  and lose assignments and `cd`. `local`, `read`, here-docs, `${x:-d}` and `$((x=1))` are not
  supported.
- `"$@"` is not split inside `${...}`, `case WORD` or a `$(...)` nested in double quotes.
  `$(case x in x) ...; esac)` needs parentheses around the patterns.
- Globs in pipelines, background jobs and `for ... in` lists still go through `/bin/sh`; `grep` with
  several matched files needs a `grep` on `PATH`.
- Windows Unicode input and file names are not supported yet. Releases are not signed yet; see
  `SIGNING.md`.

## [2.3.0] - 2026-10-23

A full code review of the shell found about a hundred defects. This release fixes them: command
injection through variable values, a sandbox that did not contain much, data loss in `copy`/`del`,
a terminal left in a broken state, job control that did not exist, and many smaller bugs.

### Highlights
- **Security**: variable values, loop variables and file names are data. They are never run or
  re-parsed as shell syntax, so `for f in *; do echo $f; done` is safe in a folder with hostile
  file names.
- **Job control**: every foreground command and background job gets its own process group.
  Ctrl+C reaches only the foreground job and Ctrl+Z stops it; `fg` and `bg` resume it.
- **No more data loss**: `copy a a` no longer destroys the file, trash names no longer collide, and
  `del`/`move`/`copy` refuse instead of deleting for good when the trash cannot be used.
- **A sandbox that holds**: `sandbox` now blocks sockets, `io_uring`, `ptrace`, `TIOCSTI` and file
  attribute changes, and refuses to run when it cannot be applied.
- **A terminal that recovers**: your terminal is restored after `SIGTERM`, `SIGHUP`, a crash or a
  vanished terminal, and long lines wrap and redraw correctly.

### Added
- Job control: process groups, Ctrl+Z, `fg`/`bg` for stopped jobs, `kill %N`, `kill -s NAME`,
  `kill -l`, and 31 signal names.
- `trash` lists the trash and `trash empty` empties it. The trash keeps original names, has a
  persistent journal (so `undo` works after a restart) and is capped at 512 MiB and 30 days.
- `del`, `move` and `copy` take `-f` to continue when the trash cannot be used.
- `sandbox -n` (allow IPv4/IPv6 sockets), `-b` (best effort when Landlock/seccomp are missing)
  and combined flags with `--` to end them.
- Builtins (`history`, `set`, `alias`, ...) work in pipelines, `$(...)` and backticks.
- Redirections: `N>`, `N<`, `>&N`, `&>` and ordered forms such as `2>&1 >file`; a redirect to a
  file that cannot be opened stops the command with status 1.
- Scripts: `break N`, `continue N`, `shift`, `-a`/`-o`/`!`/`( )` in `test`, and
  `& | ^ << >> ?:` plus hex and octal literals in `$(( ))`; function calls accept pipes and
  redirections; recursion allows 200 levels.
- `ls` sorts, shows symlinks, takes several paths and options anywhere. `cat`/`type` pass
  options and several files to `/bin/cat`.
- `date`/`time` show the zone in use: `ASM_TZ`, a simple POSIX `TZ` such as `EST5`, else the build
  default.
- MIT `LICENSE` file, shipped in every package.
- Word-boundary command colors, `NO_COLOR`/`TERM=dumb` support, aliases and functions count as
  known commands.
- Windows: `exit N`, `copy /y`, copy/move into a folder, `dir` wildcards and large sizes, `cd /d`,
  `mkdir` with parents, and `install.bat /S`.

### Changed
- Builtin error messages go to stderr and set `$?`, so `&&`, `||` and `if` work after a failing
  `cd`, `mkdir`, `cat`, `grep`, `copy` and friends.
- `exit` with no number exits with the last command's status; `exit abc` leaves with 2.
- Environment names are case-sensitive: `path=...` no longer clobbers `PATH`.
- Exec failures report the real reason with status 126 or 127; a signalled child gives 128+signal.
- `~/.asmrc`, `autoexec.txt` and `source` files are read whole (up to 64 KiB). `autoexec.txt` is
  ignored unless you or root own it and it is not world-writable.
- `~/.asm_history` is created 0600, loads the newest 256 KiB and trims big files; scripts do not
  write it.
- Piped input lines over 511 bytes are rejected instead of run in pieces.
- Release workflow: least-privilege token, pinned actions, validated versions, tests and missing
  assets block a release, manual runs from other branches do not publish. AppImage builds use a
  pinned, checksum-verified `appimagetool`.
- Updater: https only, validated tags, no downgrade, private fsynced temp file;
  `ASM_NO_UPDATE_CHECK` is honoured from `~/.asmrc`; package-manager and AppImage copies are left
  alone.
- Windows installers take the version from the build and quote the uninstall command.

### Fixed
- **Injection**: values from the environment, `set`, loop variables, function arguments and file
  names were re-parsed after expansion, so `$(...)`, backticks, `|`, `>` and quotes in them ran.
- **Terminal state**: escape sequences no longer end up in piped output or in the file of
  `cmd > file`; a tty that is only stdin is no longer reset to all zero flags; the terminal is
  restored on `SIGTERM`/`SIGHUP`/crash; a vanished terminal no longer makes the shell spin at 100%.
- **Line editor**: Tab no longer hangs or leaks a file descriptor, keeps text after the cursor and
  is bounded; the oldest history entry is reachable; function keys, Ctrl/Shift arrows and Alt keys
  no longer insert garbage; bracketed paste never runs commands; UTF-8 can be typed and edited;
  wrapped lines redraw correctly; the git branch is counted in the prompt width.
- **Prompt**: one prompt build and one write per keystroke; directory names with control bytes are
  sanitised and OSC 7 is percent-encoded; jobs and themes set in `.asmrc` survive startup.
- **Highlighting**: no false reds for `cat mkfs.txt`, `df -h` or `dd ... of=/dev/null`.
- **Files**: `copy` keeps permissions, refuses a file onto itself and folders, and reports every
  error; `move` works across filesystems and for folders; failed `undo` keeps its entry.
- **Sandbox/trace/bench**: `trace` waits only for its own command, escapes names and no longer hides
  names containing `..`; nested `bench` no longer mutes the terminal.
- **Scripts**: `x=$(cmd)` keeps the status of `cmd`; Ctrl+C stops loops that run only builtins and
  `$(...)`; `for` lists are no longer cut at 4031 bytes; sourced scripts are no longer rejected
  beyond 256 commands or 8 KB; functions containing `case` are defined; `$(( ))` short-circuits
  `&&`/`||`, divides safely and has correct comparison precedence; CRLF line continuations work.
- **Builtins**: `calc` no longer crashes on `INT64_MIN / -1`; `grep` no longer overflows on long
  patterns and writes in bulk; `color` writes valid digits; `cd` keeps `cd -` after a failure and
  maintains `PWD`/`OLDPWD`; alias and environment tables are bounded and reuse slots; `kill`
  rejects pids that do not fit (`kill 4294967295` no longer means `-1`).
- Background jobs no longer steal keystrokes; a full job table says so; `bg N` prints the right
  job number; children get the whole environment (limit 8191 variables).
- Quoted `>`, `<` and `&` are text; `echo` quoting, `\$` and tilde-after-variable behave like `sh`;
  an over-long expanded line is an error, not a silent cut at 511 bytes.
- Windows: Tab loops and a bad register, inheritable redirect handles, raw console mode left on while
  programs ran, `%VAR%` overflow, history, line wrapping, `autoexec.txt` corruption, `cmd.exe`
  quoting and Ctrl+C handling.
- Documentation numbers (binary size, history size, line counts) match the build.
- `$(...)` and backticks no longer capture terminal escape sequences when the shell runs on a
  terminal; newlines in an assignment are kept; a builtin as a pipeline stage no longer hangs;
  `ls` takes quoted paths and Tab escapes blanks; aliases may hold `;`, `&&` and `||`; a builtin
  with a trailing `&` runs in the background.
- `unset` takes several names; `export` and `set` reject names that are not identifiers; `fg` and
  `bg` without an argument use the most recent job.
- `sandbox`, `trace` and `bench` honour the shell's `>`, `>>` and `<` redirections.

### Known limits
- `case`/`esac` and loops with a redirected or piped `done` still run in `/bin/sh` and lose
  assignments and `cd`. `local`, `read`, `${x:-d}`, here-docs and `$((x=1))` are not supported.
- `"$@"` is one word, `. file` is not supported, builtins do not expand globs, and a line longer
  than 511 bytes after expansion is an error (for example `cd ~` with a very long `HOME`).
- `sandbox` cannot stop `kill()` of same-user processes on kernels older than 6.12 and cannot
  restrict reading files; see `sandbox` for the full list.
- Windows Unicode input and file names are not supported yet.
- Releases are not signed yet; see `SIGNING.md`.

## [2.2.0] - 2026-10-20

### Highlights
- **Live command colors** while you type: you see whether a command exists, and commands that
  destroy data show in red before you press Enter.
- **Smoother prompt**: no more scrolling after a failed command, and the cursor stays where you
  type inside git repos.
- **Automatic releases** with full release notes on every version bump.

### Added
- Live command colors while typing (VS Code Dark+ palette): known commands and programs on
  `PATH` in teal, help commands (`help`, `man`, `--help`) in blue, unknown commands in gray,
  and commands that destroy data (`rm`, `dd`, `mkfs`, `del`, `format`, `Remove-Item`,
  `diskpart`, ...) in red. Lines like `rm -rf`, `dd of=/dev/sda` or `curl ... | sh` turn red
  from start to end. The palette is one table at the top of `ash/highlight.asm`.
- `about` now shows the developer, Umer Farooq Khan, and the GitHub link.

### Changed
- Releases are built and published automatically when `version.inc` changes on `main`. The
  release notes come from this file, and a release without a CHANGELOG entry fails.
- Release smoke tests now block a release instead of only being reported.

### Fixed
- After a failed command, each key typed reprinted the " [127]" line, so the prompt
  scrolled one line per key. The hint now prints once.
- Inside a git repo the cursor sat inside the " (branch)" text instead of after the typed
  command.
- The developer credit spelled the name wrong.

## [2.1.0] - 2026-10-19

### Added
- **ASH (Assembly Shell)** native executor: commands and pipelines run without `/bin/sh`
  (quotes, escapes, `|`, `<`, `>`, `>>`, `2>`, `2>>`, `2>&1`). Unknown syntax still falls back to `/bin/sh`.
- `about` command with developer credit.
- `update` command: checks GitHub for a newer release; `update install` downloads it,
  verifies its SHA-256 and replaces the binary.
- Startup notice when a newer version is available (checked in the background at most once a day;
  turn off with `ASM_NO_UPDATE_CHECK=1`).
- `version.inc` as the single version source; `make version` prints it.
- Releases now ship a bare `asm-terminal-linux-x86_64` binary, `asm-terminal-windows-x86_64.exe`
  and a `SHA256SUMS` file.

- New builtins: `exit N`, `true`, `false`, `clear`, `which`, `history` / `history -c`,
  `kill [-SIGNAL] PID|%JOB`.
- Per-command stats: after an external command that ran 1 s or longer, the prompt shows
  `took 2.31s, peak 45.2 MB` (peak RAM from `wait4`). `set ASM_STATS=1` shows it for every command.
- **ASH script engine** (`ash/script.asm`): `if/elif/else/fi`, `while`, `until`,
  `for NAME in WORDS`, `break`, `continue`, `{ ...; }`, `! cmd` and `NAME=value`, all run natively
  so variables and `cd` stick. Blocks can span lines (a `> ` prompt waits for the rest), and
  `source`, `~/.asmrc` and `autoexec.txt` run whole files through the engine.
- `test` and `[ ]` builtins (`-f -d -e -s -r -w -x -L -n -z`, `= == !=`, `-eq -ne -lt -le -gt -ge`, `!`).
- `$?`, `$$` and `$((...))` arithmetic (`+ - * / %`, comparisons, `&& || !`, parentheses).
- Functions: `name() { ...; }` with `$1`..`$9`, `$#`, `$@` and `return [N]`.
- `:` builtin; `#` comments; `\` line continuation.
- `bench [-n N] COMMAND`: runs a command N times (output hidden) and prints mean, min and max
  time, peak memory and the number of failed runs.
- `undo`: reverses the last `del`, `move`/`rename` or `copy`. `del` now moves files into
  `~/.asm_trash` instead of erasing them, and `move`/`copy` first save a file they would
  overwrite. The last 16 operations can be undone.
- `trace [-a] COMMAND`: runs a command and lists the programs it starts, the files it reads,
  writes and deletes, and the network connections it opens (ptrace, no extra tools).
  System library reads are hidden unless `-a` is given. A one-line summary goes to stderr.
- `sandbox [-w] [-n] COMMAND`: runs a command that cannot change files outside `/tmp` and
  cannot open internet connections (Landlock + seccomp). `-w` also allows writes in the
  current directory; `-n` allows network.
- Statements ASH cannot run natively yet (`case`, a loop piped or redirected such as
  `done | sort` or `cmd | while read l`) go to `/bin/sh` as one piece, so they keep working.

- New app icon (chip with a `>_` prompt) in 11 sizes from 16 to 512 px, a scalable SVG and a
  one-color symbolic icon for GNOME and COSMIC panels.
- App-menu entry: search "ASM" in GNOME, KDE, COSMIC, XFCE and others. The launcher opens the
  desktop's own terminal (cosmic-term on COSMIC, Ptyxis or GNOME Terminal on GNOME, Konsole on
  KDE); `ASM_TERMINAL_EMULATOR` picks a different one.
- One-line installer for any Linux distro, published with each release:
  `curl -fsSL https://github.com/Umar-Khan-Yousafzai/asm-terminal/releases/latest/download/install.sh | sh`.
  It verifies the download against `SHA256SUMS` (`sha256sum`, `shasum` or `openssl`), works with
  `curl` or `wget`, installs into `~/.local` (or `/usr/local` as root), and removes everything
  with `--uninstall`. `ASM_VERSION=vX.Y.Z` installs a specific release.
- Fedora / RHEL / openSUSE `.rpm` package (`make rpm`).
- The shell installs as `asm-terminal`, with `asm` as a symlink to it. When another `asm` comes
  first on `PATH` (pwntools ships `/usr/bin/asm`), `asm-terminal` still works, and `make install`
  prints how to fix the order. The `.rpm` installs only `asm-terminal`.

### Fixed
- `echo` printed quote characters (`echo -e 'a\nb'` now prints two lines).
- `a && b || c` now follows sh rules (`false && x || y` runs `y`), and `;`, `&&`, `||` inside
  quotes no longer split the line.
- `$VAR` is no longer expanded inside single quotes.
- `exit` with no number, and end of input, now exit with the last command's status.
- Variable expansion wrote a flag over a saved register, and long expansions could overflow the input buffer.
- The app-menu launcher stopped after the first terminal it could not find, so on Fedora it
  never reached cosmic-term or Ptyxis.
- The app-menu entry pointed at a path the desktop session cannot see, so it did not appear.
- Windows build: `build.bat` passed a broken include path to NASM and ignored the `LD_EXE` and
  `NASM_EXE` overrides.

## [2.0.0] - 2026-04-20

First public release: line editor, history, tab completion, Ctrl+R, aliases, themes,
job control, 35+ builtins, Linux and Windows builds, .deb / AppImage / Windows installer.
