## Agent: codebase-architecture-patterns-dependencies

---

## 1. Architecture: Dispatch, Entry Points, Memory Layout, Modularity

**Finding: Dual dispatch table design — exact-match + prefix-match**
- Evidence: `/home/umer/asm-terminal/terminal_linux.asm:397-438`. The `cmd_table_exact` is a flat array of `[name_ptr, handler_ptr]` pairs (16 bytes each), terminated by `[0, 0]`. The `cmd_table_prefix` is `[name_ptr, handler_ptr, name_len]` triples (24 bytes each). Both tables are in `.data`.
- Exact table (12 entries): `help`, `cls`, `exit`, `ver`, `date`, `time`, `pwd`, `whoami`, `popd`, `uptime`, `free`, `jobs`.
- Prefix table (22 entries): `echo`, `cd`, `ls`, `grep`, `calc`, `alias`, `fg`, etc.
- `dispatch_command` (line 2375) walks exact table first, then prefix table, then falls through to `execute_external`.
- Implication: Adding a new built-in requires touching BOTH the dispatch table AND writing the handler. No registration macro exists. Easy win for `%macro REGISTER_CMD`.
- Confidence: HIGH

**Finding: Entry point and calling convention**
- Evidence: `_start` at line 864 — parses kernel stack for `argc/argv/envp`, saves `envp` to `saved_envp`, aligns stack with `and rsp, -16`, calls `main`.
- Confidence: HIGH

**Finding: Memory layout — .bss is large and flat (~120KB)**
- `input_buf` / `line_buf`: 512 bytes each
- `history_buf`: 32 × 512 = 16,384 bytes
- `alias_table`: 32 × 320 = 10,240 bytes
- `env_overlay`: 64 × 512 = 32,768 bytes
- `dir_stack`: 16 × 4096 = 65,536 bytes
- `tab_dirent_buf` / `dirent_buf`: 8,192 bytes each
- `job_pids`: 64 bytes; `job_cmds`: 1,024 bytes
- Confidence: HIGH

**Finding: One monolithic file per platform — zero modularity**
- `terminal_linux.asm`: 7,851 lines; `terminal.asm`: 2,690 lines. No `%include` directives. Any shared utility (str_copy, str_len, print_number) is duplicated.
- Confidence: HIGH

## 2. Patterns: Error Handling, Buffer Bounds, Stack Alignment

**Finding: Syscall error handling inconsistent — ~35% of syscalls have no immediate check**
- Of ~102 `syscall` invocations, 35 are immediately followed by check (`test rax, rax` / `js .label`). Unchecked examples: `setup_raw_mode` TCGETS/TCSETS (981, 1012); `setup_sigint` rt_sigaction (1064); `SYS_WRITE` in `handler_copy` (3811) — partial writes cause silent data corruption.
- Confidence: HIGH

**Finding: `env_expand_buf` end-guard defined but NEVER checked — overflow risk**
- Line 2505: `lea r14, [env_expand_buf + 1000]` sets rough end guard. Nowhere in `expand_env_vars` (2494–2635) is `r13` compared to `r14`. Value copy loop (2610–2619) writes to `[r13]` without bounds check. `env_expand_buf` is 1,024 bytes; long `$VAR` value overflows into `env_var_name` (256) and `env_var_value` (1,024).
- Security-relevant. Requires attacker control of environment.
- Confidence: HIGH

**Finding: `source` and `run_autoexec` line-copy into `input_buf` has no length guard**
- `handler_source` at 5728–5755 and `run_autoexec` at 5172–5190. Both copy byte-by-byte with no `cmp ecx, MAX_INPUT` check. A sourced line > 511 bytes overflows into `line_buf` then `line_len/line_cursor` then `path_buf`.
- Real buffer overflow reachable via `~/.asmrc` or any sourced file.
- Confidence: HIGH

**Finding: `setenv_internal` unbounded copy into 512-byte slot**
- Lines 5028–5054. Neither `.se_cp_name` nor `.se_cp_value` loops check against `ENV_OVERLAY_SIZE` (512). Long `set NAME=VALUE` corrupts adjacent overlay entries.
- Confidence: HIGH

**Finding: Stack alignment is consistently correct across all analyzed handlers**
- `handler_uptime`, `handler_calc`, `handler_grep`, `execute_compound`, `dispatch_command` all satisfy `(N_after_rbp * 8 + sub_amount) % 16 == 0`.
- Confidence: HIGH

**Finding: `history_add` correctly bounds copy to HISTORY_ENTRY_SIZE-1**
- Lines 1887–1897: `mov ecx, HISTORY_ENTRY_SIZE - 1`. This pattern should be replicated in source/autoexec.
- Confidence: HIGH

**Finding: `alias_table` name stored with `str_copy` — no size bound check**
- Lines 4155–4166. An alias name > 63 bytes or command > 255 bytes silently corrupts adjacent slot.
- Confidence: HIGH

## 3. Dependencies: External Process Reliance

**Finding: ALL external commands and pipes delegate to `/bin/sh -c <input_buf>`**
- `execute_external` at 4298–4314. Pipes (`|`) detected in `dispatch_command` at 2399–2401 route to /bin/sh.
- Shell has no native pipe implementation. Cannot introspect pipe state. On busybox/hardened containers, behavior may differ.
- Confidence: HIGH

**Finding: `execute_external` passes `saved_envp` directly — env overlay NOT visible to children**
- Line 4312: `mov rdx, [saved_envp]` — passes original kernel envp, not modified version including `env_overlay`. So `set FOO=bar` is invisible to external programs. Inconsistent with POSIX shell semantics.
- Confidence: HIGH

**Finding: fork+wait4 pattern correctly implemented with background job support**
- `fork()` at 4272, child builds argv and calls execve, parent either `wait4()` or stores PID in `job_pids`. Background jobs reaped by `reap_finished_jobs`. Correct POSIX semantics.
- Confidence: HIGH

## 4. Cross-Platform Parity

**Finding: Windows version is significantly behind — missing 9 built-in commands**
- Linux handlers not in Windows: `source`, `ls`, `grep`, `uptime`, `free`, `calc`, `theme`, `jobs`, `fg`.
- Windows missing: no compound commands, no persistent history, no `.asmrc`, no reverse history search, no Ctrl+W/Ctrl+U, no background jobs, no env overlay, no syntax highlighting.
- Confidence: HIGH

**Finding: Windows uses real Win32 environment API; Linux uses custom env overlay**
- `set FOO=bar` propagates to children on Windows but NOT on Linux. Hidden parity bug.
- Confidence: HIGH

## 5. Code Smells / Weaknesses

**Finding: Zero macros — every print is 2–3 lines of boilerplate, 165 times**
- `call print_string_len`: 76 hits; `call print_cstring`: 89 hits. A single `%macro PRINT msg, len` cuts hundreds of lines.
- Confidence: HIGH

**Finding: `errno_table` in `.data` is dead code — never referenced**
- Defined at line 466 with 9 entries. `print_last_error` (7768) re-implements same mapping as inline cmp/je chain.
- Confidence: HIGH

**Finding: `handler_dir` and `handler_ls` duplicate ~80% of getdents64 iteration logic**
- Both at 3442 and 6082 share structure. A common `dir_iterate(rdi=path, rsi=callback)` would eliminate duplication.
- Confidence: HIGH

**Finding: `handler_time` is just a `jmp handler_date`**
- Line 3073–3074. Both commands output identically.
- Confidence: HIGH

**Finding: `calc` truncates 64-bit result to 32-bit before printing**
- Line 6932: `mov eax, r13d` drops high 32 bits. `calc 3000000000 * 2` prints 1,705,032,704 instead of 6,000,000,000.
- Confidence: HIGH

**Finding: No operator precedence in `calc` — strictly left-to-right**
- `calc 2 + 3 * 4` returns 20, not 14.
- Confidence: HIGH

**Finding: `ls -l` shows hardcoded permission strings, not real stat permissions**
- Lines 546–548 define three static strings `drwxr-xr-x`, `-rw-r--r--`, `-rwxr-xr-x`. Used unconditionally — actual mode bits never rendered.
- Confidence: HIGH

**Finding: `ls -l` file sizes truncate files >4GB**
- Line 6239: `mov eax, [stat_buf + STAT_ST_SIZE]` — reads only 32 bits of 64-bit `st_size`.
- Confidence: HIGH

**Finding: `grep` is case-sensitive literal substring only — no regex, no -i**
- `grep_memcmp` (6609) is byte-by-byte.
- Confidence: HIGH

**Finding: `TIOCGWINSZ` defined and `winsize_buf` allocated but never used**
- `%define TIOCGWINSZ 0x5413` (47); `winsize_buf resb 8` (722). No ioctl call uses it. `ls` does not adapt to width.
- Confidence: HIGH

**Finding: No SIGWINCH handler — terminal resize not handled**
- Only SIGINT registered via `setup_sigint`.
- Confidence: HIGH

**Finding: `source` has no recursion depth protection**
- `source_read_buf` is global. If a file sources itself, stack grows until crash.
- Confidence: HIGH

## 6. Security-Sensitive Code Paths

**Finding: Env var expansion has defined-but-ignored overflow guard — real overflow risk**
- Security issue if running untrusted commands. Fix: compare `r13` against `r14` before each write.
- Confidence: HIGH

**Finding: Alias expansion writes unchecked to `env_expand_buf` (1,024 bytes)**
- `check_alias` (2688) copies alias value (max 256) then appends rest of input_buf (max 512) = max 768 < 1024. Safe in practice but no enforced contract.
- Confidence: MEDIUM

**Finding: External command injection via env expansion — standard POSIX semantics, not a bug**
- If `$VAR` contains `;rm -rf`, it runs. Same threat model as any POSIX shell.
- Confidence: HIGH

## 7. Testing Infrastructure

**Finding: Zero formal test infrastructure**
- No `.sh`, `.py`, `.rb`, `.bats` test files. Makefile has only `all` and `clean`. README suggests only: `echo -e "ver\npwd\nls\nexit" | ./terminal`.
- Biggest maintenance liability.
- Confidence: HIGH

**Finding: Testing approaches that would work**
1. Differential smoke testing: pipe commands to `./terminal` and compare with bash
2. NASM unit test harness: assemble small `.asm` test files calling individual functions
3. Fuzz input buffer: random bytes, check for crashes (would immediately find overflow bugs)
4. Strace-based: verify syscall sequence
5. AFL/libFuzzer with a thin C wrapper

## 8. Built-in Command Implementation Quality

- `calc`: real multi-operand parser. Left-to-right only, 32-bit output, no parens/floats.
- `grep`: real substring search with highlighting, not regex. No -i/-n/-r.
- `ls -l`: real stat calls but hardcoded/fake permissions. No owner/group/link count/timestamp.
- `jobs`/`fg`: fully functional. `fg` does NOT send SIGCONT (would hang on stopped processes).
- `source`: fully functional with comments. 4 KB file size cap (single read).
- `theme`: 3 presets via table. Cannot add at runtime.
- `uptime`/`free`: parse /proc text, real but fragile (format-dependent).
- `date`/`time`: real but timezone hardcoded to PKT (UTC+5).

## Top Priorities Table

| # | Issue | Type | Effort |
|---|---|---|---|
| 1 | source/autoexec line-copy overflow into input_buf | Security/crash | Low |
| 2 | env_expand_buf end-guard defined but never checked | Security | Low |
| 3 | setenv_internal unbounded write into 512-byte slot | Security | Low |
| 4 | ls -l shows hardcoded permissions, not real mode | Correctness | Medium |
| 5 | calc truncates 64-bit result to 32-bit | Bug | Low |
| 6 | write() return not checked in handler_copy | Data integrity | Low |
| 7 | env_overlay not passed to children via execve | Feature gap | Medium |
| 8 | No test infrastructure whatsoever | Maintenance | High |
| 9 | No PRINT macro — 165 boilerplate sites | Code quality | Low |
| 10 | errno_table in .data is dead code | Smell | Low |
| 11 | Windows missing 9 commands | Parity | High |
| 12 | grep case-sensitive only, no regex | Feature gap | Low (-i) / High (regex) |
| 13 | TIOCGWINSZ defined but never used | Feature gap | Low |
| 14 | No || operator in compound commands | Feature gap | Medium |
| 15 | Timezone hardcoded to PKT | Portability | Medium |
| 16 | source no recursion depth limit | Crash | Low |
| 17 | Symlinks not distinguished in ls | Correctness | Medium |
