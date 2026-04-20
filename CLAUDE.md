# ASM Terminal v2.0

A fully-featured terminal/shell written entirely in x86-64 assembly (NASM). Cross-platform: Windows and Linux.

## Project Structure

```
asm-terminal/
  terminal.asm          # Windows version (2,691 lines, original)
  terminal_linux.asm    # Linux version (7,700+ lines, full-featured port)
  build.bat             # Windows build script (NASM + MinGW ld)
  Makefile              # Linux build: make / make clean
  terminal.exe          # Windows binary (38KB)
  terminal              # Linux binary (73KB, statically linked ELF64)
```

## Build

### Linux
```bash
make                    # Requires: nasm, ld (binutils)
```
Binary installs to `~/.local/bin/asm` — run with just `asm` from any terminal.

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
- **External commands**: fork + execve(/bin/sh -c) + wait4
- **Signals**: sigaction for SIGINT (Ctrl+C)
- **Entry point**: `_start` → parses kernel stack for envp → `call main`

### Windows Version (`terminal.asm`)
- **Target**: Windows x64, PE, linked with kernel32.dll + user32.dll
- **Calling convention**: Microsoft x64 (args: rcx, rdx, r8, r9 + 32-byte shadow space)
- **Console API**: WriteConsoleA, ReadConsoleInputA, SetConsoleTextAttribute, etc.
- **External commands**: CreateProcessA(cmd.exe /c) + WaitForSingleObject
- **Entry point**: `main`

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
- `execute_compound()` — split on `;` and `&&`, dispatch each segment
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
- `exit` — exit terminal

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
- **Piping**: `cmd1 | cmd2` (via /bin/sh)
- **Environment variable expansion**: `$VAR` and `${VAR}`
- **Tab completion**: file/directory name completion with cycling
- **Command history**: Up/Down arrows, 32-entry circular buffer
- **Persistent history**: `~/.asm_history` (saved across sessions)
- **Reverse search**: Ctrl+R (incremental backward search)
- **Line editing**: Backspace, Delete, Left/Right, Home/End
- **Keyboard shortcuts**: Ctrl+L (clear), Ctrl+W (delete word), Ctrl+U (clear line)
- **Config file**: `~/.asmrc` executed at startup
- **Autoexec**: `autoexec.txt` in binary directory
- **Syntax highlighting**: first word colored green (valid) or red (invalid)
- **Prompt**: `user@host:path$` format with theme colors
- **Wildcard expansion**: `*` and `?` handled via /bin/sh for external commands

## Data Layout

### .data Section
- ANSI escape strings, prompt strings, welcome/help messages
- Command name strings (`cmd_s_*`) and dispatch tables (`cmd_table_exact`, `cmd_table_prefix`)
- Day/month name tables (`dow_names`, `month_names`), color mapping (`win_to_ansi`)
- Theme tables (3 presets, 64 bytes each)

### .bss Section (~120KB total)
- Terminal state: `orig_termios`, `raw_termios` (60 bytes each)
- Line editor: `input_buf`, `line_buf` (512 each), `line_len`, `line_cursor`
- History: `history_buf` (16KB), circular buffer with 32 entries
- Aliases: `alias_table` (10KB), 32 entries
- Directory stack: `dir_stack` (64KB), 16 entries
- Environment overlay: `env_overlay` (32KB), 64 entries
- Tab completion: `tab_dirent_buf` (8KB), prefix/match tracking
- Job table: `job_pids` (8 slots), `job_cmds` (1KB)

## Timezone
Currently hardcoded to PKT (UTC+5) via `%define TZ_OFFSET_SECONDS 18000`. Change this value and rebuild for different timezone.

## Key Syscalls Used
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
- Update installed binary: `cp terminal ~/.local/bin/asm`
- Test non-interactively: `echo -e "cmd1\ncmd2\nexit" | ./terminal`
- NASM might need manual install if not in PATH — extracted version at `/tmp/nasm-extracted/usr/bin/nasm`
- Stack must be 16-byte aligned before every `call` instruction
- After `push rbp` + N callee-saved pushes: if N is odd, add `sub rsp, 8` for alignment
