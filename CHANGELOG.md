# Changelog

All notable changes to ASM Terminal. Versions follow [Semantic Versioning](https://semver.org/):
MAJOR for breaking changes, MINOR for new features, PATCH for fixes.
The version lives in one place: `version.inc`.

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
