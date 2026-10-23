# ASM Terminal

The version lives in `version.inc` (see `CHANGELOG.md`); `make version` prints it.

A fully-featured terminal/shell written entirely in x86-64 assembly (NASM). Cross-platform: Windows and Linux.

## Project Structure

```
asm-terminal/
  terminal.asm          # Windows version (about 2,700 lines, a smaller command set than Linux)
  terminal_linux.asm    # Linux version (about 9,400 lines, plus about 9,000 in ash/)
  ash/ash_exec.asm      # ASH native executor (%included by terminal_linux.asm)
  ash/builtins.asm      # builtins that run inside ASH: exit, true/false, which, history, kill, ...
  ash/script.asm        # ASH script engine: if/while/for, && ||, test, $((...)), functions
  ash/tools.asm         # bench, undo (+ safe del/move/copy, ~/.asm_trash), trace, sandbox
  ash/highlight.asm     # live command colors (Dark+ palette, danger list for Linux + Windows)
  ash/update.asm        # update / update install, background update check (curl + sha256sum)
  version.inc           # the one place the version is written
  CHANGELOG.md          # release notes source (the release workflow requires an entry)
  LICENSE               # MIT
  build.bat             # Windows build script (NASM + MinGW ld)
  Makefile              # Linux build, install, packaging, tests (targets are listed at the top)
  tests/                # tests/run_tests.sh (make test), tests/cases/*.sh|py, pty helper
  packaging/            # .deb, .rpm, AppImage, install scripts, Windows installers, release notes
  .github/workflows/    # ci.yml (build + tests), release.yml (automatic release)
  terminal              # build output, not committed: Linux binary (about 170 KB, static ELF64)
  terminal.exe          # build output, not committed: Windows binary
```

## Build

### Linux
```bash
make                    # Requires: nasm, ld (binutils)
```
`make install` puts `asm-terminal` in `~/.local/bin` (honours `PREFIX`, `BINDIR`, `DESTDIR`) and links
`asm` to it unless another program already uses that name (pwntools does). `make install-desktop` adds
the launcher, menu entry and icons. `make test` runs `tests/run_tests.sh`.

### Windows
```bat
build.bat               # Requires: NASM, MinGW ld
```

## Architecture

### Linux Version (`terminal_linux.asm`)
- **Target**: Linux x86-64, ELF64, pure syscalls (no libc dependency)
- **Calling convention**: System V AMD64 (args: rdi, rsi, rdx, rcx, r8, r9)
- **Syscall convention**: rdi, rsi, rdx, r10, r8, r9 (number in rax, clobbers rcx/r11)
- **Callee-saved registers**: rbx, rbp, r12-r15
- **Terminal control**: termios via ioctl (TCGETS/TCSETS) for raw mode
- **Colors/cursor**: ANSI escape sequences
- **External commands**: ASH (`ash/ash_exec.asm`) parses the line and runs commands/pipelines natively (PATH lookup, pipe2, dup2, fork, execve). Control flow (`if`, `while`, `for`, `&&`, `||`) runs in `ash/script.asm`. Lines it does not understand yet (globs, `$(...)`, here-docs, `&`) fall back to fork + execve(/bin/sh -c)
- **Signals**: sigaction for SIGINT (Ctrl+C)
- **Update**: `ash/update.asm` runs `curl` and `sha256sum` (argv arrays, never a shell string). The startup check calls api.github.com in a detached process at most once a day; opt out with `ASM_NO_UPDATE_CHECK=1` in the environment or `set ASM_NO_UPDATE_CHECK=1` in `~/.asmrc` (empty or `0` does not opt out). `update install` verifies the binary against the release's `SHA256SUMS` and never installs an older version. That file is fetched from the same release, so it detects corruption, not a hostile release
- **Entry point**: `_start` → parses kernel stack for envp → `call main`

### Windows Version (`terminal.asm`)
- **Target**: Windows x64, PE, linked with kernel32.dll + user32.dll
- **Calling convention**: Microsoft x64 (args: rcx, rdx, r8, r9 + 32-byte shadow space)
- **Console API**: WriteConsoleA, ReadConsoleInputA, SetConsoleTextAttribute, etc.
- **External commands**: CreateProcessA(cmd.exe /c) + WaitForSingleObject
- **Entry point**: `main`
- **Feature set**: much smaller than Linux. Builtins: `help cls exit ver date time pwd whoami cd pushd popd echo title color dir type mkdir rmdir del copy move rename set alias`. The Linux-only features below (everything under "All Commands" and "Shell Features" that is not in that list, including `;`/`&&`/`||`, `ls`, `grep`, `calc`, `theme`, jobs, history, `~/.asmrc`, ASH, `update`, `bench`/`undo`/`trace`/`sandbox`) do not exist on Windows, where such lines go to `cmd.exe /c`

## Key Internal Functions (Linux)

### I/O
- `print_string_len(rdi=buf, esi=len)` — write to stdout or redirect file
- `print_cstring(rdi=str)` — print null-terminated string
- `print_newline()` — print LF
- `print_number(eax)` — print decimal integer
- `print_number_2digit(eax)` — print 2-digit with leading zero
- `print_number_9pad(eax)` — right-align in 9-char field

### String Operations
- `str_copy(rdi=dest, rsi=src)` — copy null-terminated
- `str_len(rdi=str) -> eax` — return length
- `str_icompare(rdi=s1, rsi=s2) -> eax=0 if equal` — case-insensitive
- `str_icompare_n(rdi=s1, rsi=s2, edx=n) -> eax=0` — first N chars
- `skip_spaces(rdi=str) -> rax` — skip leading spaces
- `parse_two_args(rdi=input) -> rax=arg1, rdx=arg2` — split at first space

### Environment
- `getenv_internal(rdi=name) -> rax=value_ptr or 0` — checks overlay then envp
- `setenv_internal(rdi=name, rsi=value)` — stores in overlay table

### Command Dispatch
- `dispatch_command()` — expand env vars, check aliases, parse redirection, match against exact/prefix tables, fallback to execute_external
- `ash_eval(rdi=text, esi=final)` — ASH script engine (ash/script.asm): tokenize, link blocks, run; returns 1 when a block is still open
- `ash_feed_line()` — main loop entry: appends input_buf to the pending script, shows `> ` while incomplete
- All handlers: `handler_*(rdi=args)` — args pointer or NULL

## All Commands (30+)

### Navigation
- `cd <path>` / `cd -` / `cd ..` — change directory
- `pwd` — print working directory
- `pushd <path>` / `popd` — directory stack

### Files
- `ls [-la] [dir]` — colored listing with long format support
- `dir [path]` — classic directory listing with sizes
- `cat <file>` / `type <file>` — display file contents
- `copy <src> <dst>` — copy file
- `move <src> <dst>` / `rename <src> <dst>` — move/rename
- `del <file>` — delete file
- `mkdir <dir>` / `rmdir <dir>` — create/remove directory
- `grep <pattern> <file>` — search with highlighted matches

### Environment
- `set` / `set VAR` / `set VAR=value` — environment variables
- `whoami` — current username

### Display
- `echo <text>` — print text (supports `$VAR` expansion)
- `cls` — clear screen
- `color <hex>` — set color (Windows-style hex, e.g., `0A` = green on black)
- `title <text>` — set terminal window title

### System
- `ver` — version info
- `date` / `time` — formatted: `Fri Apr  3 08:14:01 PM PKT 2026`
- `uptime` — system uptime from /proc/uptime
- `free` — memory info from /proc/meminfo
- `calc <expr>` — integer math (`calc 10 + 5 * 2`)
- `source <file>` — execute commands from file
- `help` — full command reference with examples
- `exit [N]`: exit terminal
- `about`: developer credit
- `update` / `update install`: check for, and install, a newer release (Linux)
- `true` / `false` / `clear` / `which NAME` / `history [-c]` / `kill [-SIG] PID|%JOB`: Linux builtins
- `bench`, `undo`, `trace`, `sandbox`: ASH tools (`ash/tools.asm`, Linux)

### Customization
- `alias <name>=<cmd>` — create aliases (e.g., `alias ll=ls -la`)
- `theme [name]` — switch theme: `default`, `minimal`, `classic`

### Job Control
- `<cmd> &` — run in background
- `jobs` — list background jobs
- `fg <n>` — bring job to foreground

## Shell Features
- **Compound commands**: `cmd1 ; cmd2` and `cmd1 && cmd2`
- **I/O redirection**: `>`, `>>`, `<`
- **Piping**: `cmd1 | cmd2` (native pipes in ASH; `/bin/sh` only for syntax ASH does not handle)
- **Environment variable expansion**: `$VAR` and `${VAR}`
- **Tab completion**: file/directory name completion with cycling
- **Command history**: Up/Down arrows, 500-entry circular buffer
- **Persistent history**: `~/.asm_history` (saved across sessions)
- **Reverse search**: Ctrl+R (incremental backward search)
- **Line editing**: Backspace, Delete, Left/Right, Home/End
- **Keyboard shortcuts**: Ctrl+L (clear), Ctrl+W (delete word), Ctrl+U (clear line)
- **Config file**: `~/.asmrc` executed at startup
- **Autoexec**: `autoexec.txt` in binary directory
- **Syntax highlighting**: command word colored as you type (`ash/highlight.asm`): teal = known/on PATH, blue = help, gray = unknown, red = destroys data
- **Prompt**: `user@host:path$` format with theme colors
- **Wildcard expansion**: `*` and `?` handled via /bin/sh for external commands

## Data Layout

### .data Section
- ANSI escape strings, prompt strings, welcome/help messages
- Command name strings (`cmd_s_*`) and dispatch tables (`cmd_table_exact`, `cmd_table_prefix`)
- Day/month name tables (`dow_names`, `month_names`), color mapping (`win_to_ansi`)
- Theme tables (3 presets, 64 bytes each)

### .bss Section (about 1.1 MB total; zero-filled, not stored in the ELF file)
- Terminal state: `orig_termios`, `raw_termios` (60 bytes each)
- Line editor: `input_buf`, `line_buf` (512 each), `line_len`, `line_cursor`
- History: `history_buf` (250KB), circular buffer with 500 entries; `history_read_buf` (256KB) for loading the file
- ASH, script and tool buffers (`ash/*.asm`): the rest
- Aliases: `alias_table` (10KB), 32 entries
- Directory stack: `dir_stack` (64KB), 16 entries
- Environment overlay: `env_overlay` (32KB), 64 entries
- Tab completion: `tab_dirent_buf` (8KB), prefix/match tracking
- Job table: `job_pids` (8 slots), `job_cmds` (1KB)

## Timezone
Currently hardcoded to PKT (UTC+5) via `%define TZ_OFFSET_SECONDS 18000`. Change this value and rebuild for different timezone.

## Key Syscalls Used (partial list)
```
SYS_READ=0, SYS_WRITE=1, SYS_OPEN=2, SYS_CLOSE=3, SYS_STAT=4,
SYS_LSEEK=8, SYS_IOCTL=16, SYS_PIPE=22, SYS_DUP2=33, SYS_FORK=57,
SYS_EXECVE=59, SYS_EXIT=60, SYS_WAIT4=61, SYS_UNAME=63, SYS_GETCWD=79,
SYS_CHDIR=80, SYS_RENAME=82, SYS_MKDIR=83, SYS_RMDIR=84, SYS_UNLINK=87,
SYS_READLINK=89, SYS_RT_SIGACTION=13, SYS_GETDENTS64=217,
SYS_CLOCK_GETTIME=228, SYS_NEWFSTATAT=262
```

## Development Notes
- Always rebuild after changes: `make clean && make`
- Update installed binary: `make install` (or `cp terminal ~/.local/bin/asm-terminal`)
- Run the tests: `bash tests/run_tests.sh` (uses a temporary HOME)
- Test non-interactively: `echo -e "cmd1\ncmd2\nexit" | ./terminal`
- NASM might need manual install if not in PATH — extracted version at `/tmp/nasm-extracted/usr/bin/nasm`
- Stack must be 16-byte aligned before every `call` instruction
- After `push rbp` + N callee-saved pushes: if N is odd, add `sub rsp, 8` for alignment
