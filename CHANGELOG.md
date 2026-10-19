# Changelog

All notable changes to ASM Terminal. Versions follow [Semantic Versioning](https://semver.org/):
MAJOR for breaking changes, MINOR for new features, PATCH for fixes.
The version lives in one place: `version.inc`.

## [2.1.0] - unreleased

### Added
- **ASH (Assembly Shell)** native executor: commands and pipelines run without `/bin/sh`
  (quotes, escapes, `|`, `<`, `>`, `>>`, `2>`, `2>>`, `2>&1`). Unknown syntax still falls back to `/bin/sh`.
- `about` command with developer credit (Omar Farooq Khan).
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

### Fixed
- `echo` printed quote characters (`echo -e 'a\nb'` now prints two lines).

## [2.0.0] - 2026-04-20

First public release: line editor, history, tab completion, Ctrl+R, aliases, themes,
job control, 35+ builtins, Linux and Windows builds, .deb / AppImage / Windows installer.
