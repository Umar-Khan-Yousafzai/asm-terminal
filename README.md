# ASM Terminal

A terminal/shell written **entirely in x86-64 assembly** (NASM) for Linux and Windows. No libc, no runtime, just raw syscalls (Linux) or Win32 API (Windows). The Linux version is the full-featured one; the Windows version has a smaller command set (see [Windows version](#windows-version)).

![license](https://img.shields.io/badge/license-MIT-blue) ![arch](https://img.shields.io/badge/arch-x86__64-green) ![asm](https://img.shields.io/badge/language-NASM-red) ![platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-lightgrey)

```
 █████╗ ███████╗███╗   ███╗    ████████╗███████╗██████╗ ███╗   ███╗
██╔══██╗██╔════╝████╗ ████║    ╚══██╔══╝██╔════╝██╔══██╗████╗ ████║
███████║███████╗██╔████╔██║       ██║   █████╗  ██████╔╝██╔████╔██║
██╔══██║╚════██║██║╚██╔╝██║       ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║
██║  ██║███████║██║ ╚═╝ ██║       ██║   ███████╗██║ ╚═╝ ██║
╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝       ╚═╝   ╚══════╝╚═╝     ╚═╝
```

---

## Why

Because modern shells are fat. `bash` ships megabytes of C and a libc behind it. This project proves you can build a **real, usable shell** with history, tab completion, reverse search, job control, compound commands, aliases, theming and syntax highlighting in **pure assembly**, statically linked with no libc, in a binary of about 170 KB (Linux).

It is part serious tool, part love letter to the x86-64 ISA and the Linux kernel syscall interface.

---

## Features

### Shell
- **ASH (Assembly Shell)** executor: pipelines, quotes, escapes and `<` `>` `>>` `2>` `2>>` `2>&1` run natively, no `/bin/sh` process.
- **ASH script engine**: `if`/`elif`/`else`, `while`, `until`, `for`, `break`/`continue`, functions, `test` / `[ ]`, `$?`, `$$`, `$((...))`, `NAME=value`, multi-line blocks. Syntax ASH does not handle yet (for example `case`, a loop piped into another command, `$(...)`, here-docs, `&`) is handed to `/bin/sh`, which therefore has to be installed.
- Compound commands: `cmd1 ; cmd2`, `cmd1 && cmd2`, `cmd1 || cmd2`
- I/O redirection: `>`, `>>`, `<`, `2>`, `2>>`, `2>&1`
- Piping: `cmd1 | cmd2`
- Environment variable expansion: `$VAR` and `${VAR}`
- Wildcard expansion (`*`, `?`) for external commands (via `/bin/sh`)

### Line editor
- Tab completion for files and directories (with cycling)
- Command history: Up/Down arrows, 500-entry circular buffer
- **Persistent history** saved to `~/.asm_history`
- Reverse search with Ctrl+R (incremental)
- Line editing: Backspace, Delete, Left/Right, Home/End
- Shortcuts: Ctrl+L (clear), Ctrl+W (delete word), Ctrl+U (clear line)
- Live command colors: the command word is teal when it is a builtin or on `PATH`, blue for help commands, gray when unknown, and red for commands that destroy data (`rm`, `dd`, `mkfs`, `curl ... | sh`, ...)

### Built-in commands (40+, Linux)
| Category | Commands |
|---|---|
| Navigation | `cd`, `pwd`, `pushd`, `popd` |
| Files | `ls [-la]`, `dir`, `cat`/`type`, `copy`, `move`/`rename`, `del`, `mkdir`, `rmdir`, `grep` |
| Env | `set`, `whoami` |
| Display | `echo`, `cls`/`clear`, `color`, `title` |
| System | `ver`, `about`, `update`, `date`, `time`, `uptime`, `free`, `calc`, `source`, `help`, `exit [N]`, `true`, `false`, `which`, `history`, `kill`, `test` / `[ ]` |
| Tools | `bench`, `undo`, `trace`, `sandbox` (`del` keeps files in `~/.asm_trash` so `undo` can restore them) |
| Customization | `alias`, `theme` |
| Jobs | `<cmd> &`, `jobs`, `fg` |

Run `help` inside the shell for the full list with examples.

### Startup
- `~/.asmrc` — user config, executed at launch
- `autoexec.txt` next to the binary — for packaged setups

### Themes
Three presets: `default`, `minimal`, `classic`. Switch with `theme <name>`.

---

## Versioning and updates

The current version is in [`version.inc`](version.inc) (see [CHANGELOG.md](CHANGELOG.md)). Inside the terminal:

```
ver               # ASM Terminal v2.1.0 ...
update            # check GitHub for a newer release
update install    # download it, verify SHA-256, replace the binary
```

When a newer release exists, the terminal says so at startup. Updating needs `curl` and `sha256sum` (present on all mainstream distros). If you installed with a package manager (.deb, .rpm) or run the AppImage, update through that instead; `update install` leaves those copies alone.

### Network use and privacy
The Linux version contacts the network only for updates. At startup it asks `api.github.com` which release is the latest, in a detached background process, at most once a day (a failed check is also not retried until the next day). Nothing else is sent: no identifier, no usage data, only what a plain HTTPS request carries. Opt out with `ASM_NO_UPDATE_CHECK=1`, either in the environment or as `set ASM_NO_UPDATE_CHECK=1` in `~/.asmrc` (an empty value or `0` does not opt out). `update install` downloads only when you run it.

### What the checksum does and does not protect
`update install` and `install.sh` check the download against the `SHA256SUMS` file of the same release. That catches a corrupted or truncated download. It does not prove who built the file, because the checksums are published next to it: anyone who can replace the release assets can replace both. The updater uses `https` only and never installs an older version than the one running. Signed releases (see [`packaging/windows/SIGNING.md`](packaging/windows/SIGNING.md)) would close that gap and are not set up yet.

---

## Install

### Linux (any distro, no build tools)
```bash
curl -fsSL https://github.com/Umar-Khan-Yousafzai/asm-terminal/releases/latest/download/install.sh | sh
```
Downloads the latest release, checks it against the release's `SHA256SUMS`, and installs `asm-terminal` (plus an `asm` symlink when no other program of that name exists), an app-menu entry and the icon into `~/.local`. Uninstall with `... | sh -s -- --uninstall`. To read the script before running it, download `install.sh` from the release page.

### Packages
Every [release](https://github.com/Umar-Khan-Yousafzai/asm-terminal/releases/latest) also has:
- Fedora / RHEL / openSUSE: `sudo dnf install ./asm-terminal-<version>-1.x86_64.rpm` (command: `asm-terminal`)
- Debian / Ubuntu: `sudo apt install ./asm-terminal_<version>_amd64.deb`
- Any distro: the `.AppImage`, or the `asm-terminal-<version>-linux-x86_64.tar.gz` tarball
- Windows: `asm-terminal-<version>-windows-x86_64-setup.exe`, or the `.zip` with `install.bat`

The packages install the command `asm-terminal`; they do not install `asm`.

## Build

### Linux
Requires `nasm` and `ld` (binutils).
```bash
make
```
Produces `terminal`, a statically linked ELF64 binary (about 170 KB).

Install with an app-launcher entry and icon (search "ASM" in GNOME, KDE, COSMIC, etc.):
```bash
make install-desktop        # ~/.local/bin/asm-terminal + asm symlink, .desktop file, icons
```
Or just the binary: `make install`. Run it from anywhere with `asm-terminal` (or `asm`). `make install` and `make uninstall` honour `PREFIX`, `BINDIR` and `DESTDIR`.

If `asm` is already another program (pwntools ships `/usr/bin/asm` on Fedora), the installers leave it alone and say so; use `asm-terminal`, or put `~/.local/bin` first in your `PATH`. `make install` warns when another `asm` shadows ours.

### Releasing
Releases are automatic. To ship one:
1. Bump the version in `version.inc` (e.g. `2.2.0`).
2. Add a `## [2.2.0] - YYYY-MM-DD` section to `CHANGELOG.md` describing what changed.
3. Merge to `main`.

The Release workflow sees that tag `v2.2.0` does not exist yet, runs the test suite, builds every package, and publishes the release with notes built from that CHANGELOG section (plus install commands, platforms and checksums). It fails without a CHANGELOG entry, when a test fails, or when an asset is missing. Preview the notes with `bash packaging/release-notes.sh 2.2.0`.

A release is only published from `main` (or a `v*` tag). Running the workflow by hand from another branch builds and tests but does not publish, and a manual run refuses to touch a version that already has a release unless `replace_existing` is set.

### Windows
Requires NASM and MinGW `ld`.
```bat
build.bat
```
Produces `terminal.exe` (~38 KB, PE64).

### Windows version
The Windows build is a smaller shell than the Linux one. It has the file and directory builtins (`cd`, `dir`, `type`, `copy`, `move`, `rename`, `del`, `mkdir`, `rmdir`, `pushd`, `popd`), `set`, `alias`, `echo`, `cls`, `color`, `title`, `date`, `time`, `ver`, `whoami`, `pwd`, `help` and `exit`, and runs everything else through `cmd.exe /c`. The Linux features listed above are not available on Windows: ASH and scripting, `;` / `&&` / `||`, `ls`, `grep`, `calc`, `theme`, job control, persistent history, Ctrl+R and the other line-editor shortcuts, live command colors, `~/.asmrc`, `update`, `bench`, `undo`, `trace` and `sandbox`. Only `autoexec.txt` next to the exe is read at startup.

---

## Architecture

### Linux version: `terminal_linux.asm` (about 9,400 lines, plus about 9,000 in `ash/`)
- **Target**: Linux x86-64, ELF64
- **Dependencies**: no libc, raw syscalls only. `update` runs `curl` and `sha256sum`, and `/bin/sh` is the fallback for syntax ASH does not handle
- **Calling convention**: System V AMD64 (args in `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`)
- **Syscall convention**: `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9` (number in `rax`, clobbers `rcx`/`r11`)
- **Callee-saved**: `rbx`, `rbp`, `r12`-`r15`
- **Terminal control**: `termios` via `ioctl(TCGETS/TCSETS)` for raw mode
- **Colors/cursor**: ANSI escape sequences
- **External commands**: ASH (`ash/ash_exec.asm`) resolves `PATH`, sets up pipes and redirects, then `fork` + `execve` + `wait4`; lines it cannot run go to `fork` + `execve(/bin/sh -c)`
- **Signals**: `sigaction` for SIGINT (Ctrl+C)
- **Entry**: `_start` → parses kernel stack for `envp` → `call main`

Key syscalls used:
```
SYS_READ=0, SYS_WRITE=1, SYS_OPEN=2, SYS_CLOSE=3, SYS_STAT=4,
SYS_LSEEK=8, SYS_IOCTL=16, SYS_PIPE=22, SYS_DUP2=33, SYS_FORK=57,
SYS_EXECVE=59, SYS_EXIT=60, SYS_WAIT4=61, SYS_UNAME=63, SYS_GETCWD=79,
SYS_CHDIR=80, SYS_RENAME=82, SYS_MKDIR=83, SYS_RMDIR=84, SYS_UNLINK=87,
SYS_READLINK=89, SYS_RT_SIGACTION=13, SYS_GETDENTS64=217,
SYS_CLOCK_GETTIME=228, SYS_NEWFSTATAT=262
```

### Windows version: `terminal.asm` (about 2,700 lines)
- **Target**: Windows x64, PE
- **Linked with**: `kernel32.dll`, `user32.dll`
- **Calling convention**: Microsoft x64 (args in `rcx`, `rdx`, `r8`, `r9` + 32-byte shadow space)
- **Console API**: `WriteConsoleA`, `ReadConsoleInputA`, `SetConsoleTextAttribute`, `FillConsoleOutputCharacterA`, etc.
- **External commands**: `CreateProcessA(cmd.exe /c)` + `WaitForSingleObject`
- **Entry**: `main`

---

## Code layout

```
asm-terminal/
├── terminal_linux.asm   # Linux source (full-featured, about 9,400 lines)
├── ash/                 # ASH executor, script engine, builtins, tools, highlighter, updater
├── terminal.asm         # Windows source (about 2,700 lines)
├── version.inc          # the version, in one place
├── Makefile             # Linux build, install, packaging: make / make clean
├── build.bat            # Windows build script
├── packaging/           # installers, .deb, .rpm, AppImage, release notes
├── tests/               # make test
├── CHANGELOG.md
├── LICENSE              # MIT
├── CLAUDE.md            # Deep internal notes
└── README.md
```

### Internal function groups (Linux)

**I/O**
- `print_string_len(rdi=buf, esi=len)` — write to stdout or redirect file
- `print_cstring(rdi=str)` — null-terminated
- `print_number(eax)` — decimal integer

**Strings**
- `str_copy`, `str_len`, `str_icompare`, `str_icompare_n`, `skip_spaces`, `parse_two_args`

**Environment**
- `getenv_internal(rdi=name) → rax=value_ptr` — overlay table then `envp`
- `setenv_internal(rdi=name, rsi=value)` — stores in overlay

**Dispatch**
- `dispatch_command` — expand env vars, check aliases, parse redirection, match exact/prefix tables, fall back to `execute_external`
- `ash_eval` — ASH script engine (`ash/script.asm`): runs `;` `&&` `||`, `if`, `while`, `for` natively
- Handlers: `handler_*(rdi=args)`

### Memory layout (`.bss`, about 1.1 MB, zero-filled and not stored in the file)
The main regions:
| Region | Size | Purpose |
|---|---|---|
| `orig_termios` / `raw_termios` | 60 B each | terminal state |
| `input_buf` / `line_buf` | 512 B each | line editor |
| `history_buf` | 250 KB | circular, 500 entries |
| `history_read_buf` | 256 KB | loading `~/.asm_history` |
| `alias_table` | 10 KB | 32 entries |
| `dir_stack` | 64 KB | 16 entries |
| `env_overlay` | 32 KB | 64 entries |
| `tab_dirent_buf` | 8 KB | completion |
| `job_pids` / `job_cmds` | 8 + 1 KB | background jobs |

---

## Configuration

### Timezone
Hardcoded to PKT (UTC+5) via `%define TZ_OFFSET_SECONDS 18000` in `terminal_linux.asm`. Change the constant and rebuild for another timezone.

### Startup files
1. `~/.asmrc` — executed line-by-line at startup
2. `autoexec.txt` next to the binary — executed after `.asmrc`

Both accept any valid command the shell understands, including `alias`, `theme`, and `set`.

### Example `~/.asmrc`
```sh
theme classic
alias ll=ls -la
alias gs=git status
set EDITOR=vim
```

---

## Testing

Test suite (it uses a temporary HOME):
```bash
make test        # or: bash tests/run_tests.sh
```

Non-interactive smoke test:
```bash
echo -e "ver\npwd\nls\nexit" | ./terminal
```

Always rebuild after changes:
```bash
make clean && make
```

---

## Development notes

- Stack must be **16-byte aligned** before every `call` instruction.
- After `push rbp` + N callee-saved pushes, if N is odd add `sub rsp, 8` for alignment.
- If `nasm` is not in PATH, a manually extracted copy can be placed at `/tmp/nasm-extracted/usr/bin/nasm`.
- Linux binary is statically linked: no shared libraries. Check with `ldd ./terminal` (should report "not a dynamic executable").

---

## License

MIT, see [LICENSE](LICENSE), do whatever you want, just don't blame me if you learn too much about the System V AMD64 ABI.

---

## Author

Developed by **Umer Farooq Khan** ([@Umar-Khan-Yousafzai](https://github.com/Umar-Khan-Yousafzai)). Run `about` inside the terminal for details.
