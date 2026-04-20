# ASM Terminal

A fully-featured terminal/shell written **entirely in x86-64 assembly** (NASM). Cross-platform: Linux and Windows. No libc, no runtime — just raw syscalls (Linux) or Win32 API (Windows).

![version](https://img.shields.io/badge/version-2.0-blue) ![arch](https://img.shields.io/badge/arch-x86__64-green) ![asm](https://img.shields.io/badge/language-NASM-red) ![platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-lightgrey)

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

Because modern shells are fat. `bash` ships megabytes of C and a libc behind it. This project proves you can build a **real, usable shell** — history, tab completion, reverse search, job control, compound commands, aliases, theming, syntax highlighting — in **pure assembly**, statically linked, zero dependencies, ~73 KB binary.

It is part serious tool, part love letter to the x86-64 ISA and the Linux kernel syscall interface.

---

## Features

### Shell
- Compound commands: `cmd1 ; cmd2` and `cmd1 && cmd2`
- I/O redirection: `>`, `>>`, `<`
- Piping: `cmd1 | cmd2` (delegated to `/bin/sh`)
- Environment variable expansion: `$VAR` and `${VAR}`
- Wildcard expansion (`*`, `?`) for external commands

### Line editor
- Tab completion for files and directories (with cycling)
- Command history — Up/Down arrows, 32-entry circular buffer
- **Persistent history** saved to `~/.asm_history`
- Reverse search with Ctrl+R (incremental)
- Line editing: Backspace, Delete, Left/Right, Home/End
- Shortcuts: Ctrl+L (clear), Ctrl+W (delete word), Ctrl+U (clear line)
- Syntax highlighting — first word green (valid) or red (invalid)

### Built-in commands (30+)
| Category | Commands |
|---|---|
| Navigation | `cd`, `pwd`, `pushd`, `popd` |
| Files | `ls [-la]`, `dir`, `cat`/`type`, `copy`, `move`/`rename`, `del`, `mkdir`, `rmdir`, `grep` |
| Env | `set`, `whoami` |
| Display | `echo`, `cls`, `color`, `title` |
| System | `ver`, `date`, `time`, `uptime`, `free`, `calc`, `source`, `help`, `exit` |
| Customization | `alias`, `theme` |
| Jobs | `<cmd> &`, `jobs`, `fg` |

### Startup
- `~/.asmrc` — user config, executed at launch
- `autoexec.txt` next to the binary — for packaged setups

### Themes
Three presets: `default`, `minimal`, `classic`. Switch with `theme <name>`.

---

## Build

### Linux
Requires `nasm` and `ld` (binutils).
```bash
make
```
Produces `terminal` — a statically linked ELF64 binary (~73 KB).

Install for convenience:
```bash
cp terminal ~/.local/bin/asm
```
Then run from anywhere with `asm`.

### Windows
Requires NASM and MinGW `ld`.
```bat
build.bat
```
Produces `terminal.exe` (~38 KB, PE64).

---

## Architecture

### Linux version — `terminal_linux.asm` (~7,700 lines)
- **Target**: Linux x86-64, ELF64
- **Dependencies**: none — raw syscalls only
- **Calling convention**: System V AMD64 (args in `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`)
- **Syscall convention**: `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9` (number in `rax`, clobbers `rcx`/`r11`)
- **Callee-saved**: `rbx`, `rbp`, `r12`-`r15`
- **Terminal control**: `termios` via `ioctl(TCGETS/TCSETS)` for raw mode
- **Colors/cursor**: ANSI escape sequences
- **External commands**: `fork` + `execve(/bin/sh -c)` + `wait4`
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

### Windows version — `terminal.asm` (~2,691 lines)
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
├── terminal_linux.asm   # Linux source (full-featured, ~7,700 lines)
├── terminal.asm         # Windows source (~2,691 lines)
├── Makefile             # Linux build: make / make clean
├── build.bat            # Windows build script
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
- `execute_compound` — split on `;` and `&&`, dispatch each segment
- Handlers: `handler_*(rdi=args)`

### Memory layout (`.bss`, ~120 KB)
| Region | Size | Purpose |
|---|---|---|
| `orig_termios` / `raw_termios` | 60 B each | terminal state |
| `input_buf` / `line_buf` | 512 B each | line editor |
| `history_buf` | 16 KB | circular, 32 entries |
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
- Linux binary is statically linked — zero shared library dependencies. Check with `ldd ./terminal` (should report "not a dynamic executable").

---

## License

MIT — do whatever you want, just don't blame me if you learn too much about the System V AMD64 ABI.

---

## Author

Built by [Umar Khan Yousafzai](https://github.com/Umar-Khan-Yousafzai).
