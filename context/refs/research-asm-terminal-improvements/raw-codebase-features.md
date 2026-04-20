## Agent: codebase-features-tests

**Project:** `/home/umer/asm-terminal/terminal_linux.asm` — 7,851 lines, ELF64, pure syscalls

## 1. Built-in Command Completeness

### handler_help — Minimal stub. Prints static `help_msg`. No `help <cmd>`. (2906–2916)
### handler_cls — Full. (2919–2927)
### handler_exit — Partial. No `exit <code>`. (2930–2937)
### handler_ver — Minimal stub, static string. (2941–2951)
### handler_date/time — Full but TZ hardcoded PKT (UTC+5). `handler_time` is `jmp handler_date`. (2955–3076)
### handler_echo — Partial. No `-n`/`-e` flags, no `\n \t \x` escapes. (3077–3092)
### handler_title — Full. (3096–3124)
### handler_color — Full. Windows hex → ANSI mapping via `win_to_ansi`. (3131–3305)
### handler_cd — Partial. `cd` with no args prints cwd, does NOT go to $HOME. No `~` expansion. (3306–3400)
### handler_pwd — Full. (3403–3419)
### handler_whoami — Partial. Reads $USER env var; no getuid fallback. (3422–3438)
### handler_dir — Partial. No sort, no timestamps, Windows-style header. (3442–3599)
### handler_cat/type — Partial. No -n, no pager, no binary detect. (3600–3657)
### handler_mkdir — Partial. No `-p` flag. (3660–3690)
### handler_rmdir — Partial. No `-p`, empty dirs only. (3693–3721)
### handler_del — Partial. No `-f`, no recursion, no glob. (3724–3751)
### handler_copy — Partial. Always 0644 perms, no metadata preserve, no recursion. (3756–3843)
### handler_move/rename — Partial. No cross-device fallback, no overwrite confirm. (3847–3885)
### handler_set — Partial. Overlay NOT propagated to children. No `export`, `unset`, `readonly`. (3892–3994)
### handler_pushd/popd — Full. No `dirs` command. (3997–4087)
### handler_alias — Full within 32-entry limits. No `unalias`. (4091–4206)
### handler_source — Partial. Single 4KB read (truncates large files). No if/while/functions. (5676–5784)
### handler_ls — Partial. HARDCODED perm strings (drwxr-xr-x etc); dotfile logic broken (empty fall-through at `.ls_check_hidden` line 6208 means ALL dotfiles always shown). No owner/group/nlink/mtime. No sort, no `-h`, `-R`, `-1`. (6082–6353)
### handler_grep — Partial. Substring only, case-sensitive, single file. No flags. (6359–6490)
### handler_uptime — Full. Missing load avgs. (6622–6743)
### handler_free — Partial. Raw /proc/meminfo dump, no alignment/`-h`. (6749–6820)
### handler_calc — Partial. Left-to-right signed 64-bit. No precedence, floats, %, **, hex. (6827–6956)
### handler_theme — Full for 3 presets. No user themes, no 24-bit color. (7290–7366)
### handler_jobs — Partial. PID display truncated to 32-bit (`mov eax, eax`). (7372–7467)
### handler_fg — Partial. Does NOT send SIGCONT. Will hang on truly stopped processes. (7520–7621)

## 2. Line Editor Keys

**Supported:** Backspace (127), Delete (ESC[3~), Left/Right, Home, End, Up/Down history, Tab, Ctrl+C, Ctrl+L, Ctrl+W, Ctrl+U, Ctrl+R.

**Missing:** Alt+B/F (word jump), Ctrl+K (kill-line), Ctrl+Y (yank), Ctrl+T (transpose), Ctrl+X Ctrl+E (edit in $EDITOR), Ctrl+D (EOF/delete), Ctrl+A/Ctrl+E (most users expect these), Ctrl+P/Ctrl+N (history without arrows). ESC alone discarded (1177–1181), so Alt-sequences don't work.

## 3. History

- 32 entries × 512 bytes = 16 KB buffer. Persistent to `~/.asm_history`. Dedup consecutive only.
- Ctrl+R incremental substring search, case-insensitive.
- NO `!!`, `!n`, `!prefix`, `^old^new` expansion.
- Persistent file LOAD truncates at 4095 bytes (single SYS_READ in `load_history` 5241–5250).
- Implication: Bump to ≥500 entries, add HISTSIZE/HISTFILESIZE env vars, add !! expansion, fix file load loop.

## 4. Tab Completion

- Files and directories only. No command/alias/env-var/tilde completion.
- Cycles via `tab_dir_fd` + `tab_dirent_offset`. Case-insensitive prefix match.
- Does not handle quoted names (spaces break).
- Implication: Add PATH command completion for word 0, $VAR completion, ~ expansion, space-escaping.

## 5. Prompt

- NOT customizable. 3 hardcoded themes. No PS1. No git branch, no exit code indicator, no time.
- `last_exit_status` is stored (line 810) but never displayed in prompt.
- Implication: Add PS1-style substitutions (%exit_status%, %git_branch%). Git branch via reading .git/HEAD directly.

## 6. Redirection

- Supports `>`, `>>`, `<`.
- No `2>`, `2>&1`, `&>`, here-docs, process substitution.
- Redirection parser breaks on space in filename (no quote awareness).

## 7. Job Control

- `&` background works. `fg <n>` waits but does NOT send SIGCONT — hangs on stopped.
- No SIGTSTP (Ctrl+Z) interception. ISIG stays enabled so Ctrl+Z suspends the SHELL.
- No `bg` command.
- Implication: Add kill(pid, SIGCONT) in fg; add bg; clear ISIG + software SIGTSTP handler; tcsetpgrp for proper terminal handoff.

## 8. Scripting

- `source` line-by-line via dispatch_command. `#` comments skipped. CRLF handled. 4KB file cap.
- Compound (`;`, `&&`) works in scripts.
- NO if/then/else, for, while, until, functions, local vars, return, break, continue.

## 9. Quoting

- NO quote support. Single/double quotes/backslash have no special meaning in built-in arg parsing.
- `$VAR` and `${VAR}` work. `$?` NOT implemented.
- `~` NOT expanded anywhere except internal `~/.asm_history`, `~/.asmrc`.

## 10. Tests

- Zero test infrastructure. No test/, tests/, spec/, .github/, ci/ dirs.
- README suggests: `echo -e "cmd1\ncmd2\nexit" | ./terminal`
- Implication: Add BATS suite + GitHub Actions CI.

## 11. Config `~/.asmrc`

- Identical to `handler_source`. No directives. Silent on errors. 4KB cap.

## 12. i18n / Unicode

- ABSENT. Single byte at a time. line_cursor counts bytes, not codepoints. Multi-byte UTF-8 cursor positioning corrupts.
- Filenames with non-ASCII print OK (raw bytes), but cursor wrong when typed.

## 13. Accessibility

- No NO_COLOR support. Only "minimal" theme removes ANSI from prompt + ls.

## 14. Packaging

- No install target. No .deb, .rpm, PKGBUILD, AppImage, Dockerfile, Releases workflow.

## Completeness Matrix

| Command | Status | Biggest Gap |
|---|---|---|
| help | Stub | No per-cmd help |
| cls | Full | None |
| exit | Partial | No exit code |
| ver | Stub | Static string |
| date/time | Partial | TZ hardcoded; time==date |
| echo | Partial | No -n/-e |
| title | Full | None |
| color | Full | None |
| cd | Partial | No args = cwd, not HOME; no ~ |
| pwd | Full | None |
| whoami | Partial | $USER only |
| dir | Partial | No sort/mtime |
| cat/type | Partial | No -n/pager |
| mkdir | Partial | No -p |
| rmdir | Partial | No -p |
| del | Partial | Files only |
| copy | Partial | Always 0644 |
| move/rename | Partial | No cross-device |
| set | Partial | No export to children |
| pushd | Full | No dirs |
| popd | Full | None |
| alias | Partial | No unalias; 32-limit |
| source | Partial | 4KB cap; no scripting |
| ls | Partial | Fake perms; dotfile bug |
| grep | Partial | No flags, no regex |
| uptime | Full | No load avg |
| free | Partial | Raw dump |
| calc | Partial | No precedence |
| theme | Full | Hardcoded 3 |
| jobs | Partial | 32-bit PID |
| fg | Partial | No SIGCONT |
| bg | MISSING | — |
| unalias | MISSING | — |
| export | MISSING | — |
| unset | MISSING | — |

## Critical Missing Pieces (Summary)

1. Test harness — zero tests
2. `ls` bugs — fake perms + broken dotfile hiding
3. `fg` SIGCONT missing
4. `cd` no-arg ≠ HOME
5. `set` overlay not exported
6. UTF-8 cursor broken
7. No quoting
8. History = 32 entries
9. No `2>` / `2>&1`
10. No scripting constructs
