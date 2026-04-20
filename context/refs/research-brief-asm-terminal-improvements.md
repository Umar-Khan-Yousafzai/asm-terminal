# Research Brief: asm-terminal Improvements & Feature Landscape

**Generated:** 2026-04-20
**Agents:** 2 codebase + 3 web
**Sources consulted:** ~35 unique URLs (dumped in Sources section below)

## Summary

asm-terminal is a 30+ builtin dual-platform NASM shell sitting between "hobby toy" and "real shell" — it already has history, Ctrl+R, tab completion, job control, and themes, but the Linux file (`terminal_linux.asm`, 7,851 lines) ships **three reachable buffer overflows**, a broken `ls` dotfile filter, a `fg` that hangs on stopped processes, and a Windows port missing 9 commands. Meanwhile, in April 2026 isene shipped "Bare" — a single-file 126 KB NASM shell with autosuggestions, direct-read git branch, Kitty keyboard protocol, and plugins — which is now the reference bar. The high-leverage work is: fix the security bugs (days), add OSC 133 / OSC 7 / NO_COLOR / SIGWINCH / bracketed paste to reach 2025 terminal-integration table stakes (weeks), then layer autosuggestions + segment-based prompt + larger history with metadata to match Bare/Fish/Atuin (months).

## Key Findings

### Architecture & Patterns (codebase)

- **HIGH** — **Dual dispatch table** (`cmd_table_exact` 12 entries + `cmd_table_prefix` 22 entries) walked in order by `dispatch_command` at `terminal_linux.asm:2375`. No registration macro — adding a builtin touches two places. Evidence: `terminal_linux.asm:397-438`.
- **HIGH** — **Monolithic files, zero modularity**: `terminal_linux.asm` 7,851 lines + `terminal.asm` 2,690 lines, zero `%include`. `str_copy`, `str_len`, `print_number` duplicated across platforms.
- **HIGH** — **~120 KB fixed .bss memory**: `input_buf`/`line_buf` 512 B each, `history_buf` 16 KB (32×512), `alias_table` 10 KB (32×320), `env_overlay` 32 KB (64×512), `dir_stack` 64 KB (16×4096), `tab_dirent_buf`/`dirent_buf` 8 KB each. All compile-time.
- **HIGH** — **~35% of syscalls unchecked** out of ~102 total. Notable misses: `TCGETS`/`TCSETS` in `setup_raw_mode` (`terminal_linux.asm:981, 1012`), `rt_sigaction` in `setup_sigint` (line 1064), `SYS_WRITE` in `handler_copy` (line 3811 — partial writes = silent corruption).
- **HIGH** — **Stack alignment is correct** across `handler_uptime`, `handler_calc`, `handler_grep`, `execute_compound`, `dispatch_command`. Alignment pattern is understood and consistently applied.
- **HIGH** — **No test infrastructure at all**. No `tests/`, `.bats`, `.py`, CI workflow. Makefile = `all` + `clean`. README suggests `echo -e "...\nexit" | ./terminal`. Biggest maintenance liability.
- **HIGH** — **External command reliance**: all pipes and externals delegate to `/bin/sh -c input_buf` at `execute_external` (line 4298-4314). No native pipe. **`saved_envp` passed unmodified** at line 4312 — so `set FOO=bar` on Linux is **invisible to children**, a silent POSIX-semantic violation. Windows uses real Win32 env API, so platforms diverge here.

### Concrete Bugs (codebase, actionable)

#### Security

- **HIGH** — **`env_expand_buf` overflow**. End-guard `r14 = env_expand_buf + 1000` defined at line 2505 but never compared inside the value copy loop (2610-2619). `env_expand_buf` is 1,024 bytes; long `$VAR` value overflows into `env_var_name` (256 B) and `env_var_value` (1,024 B). Attacker-controlled env var → OOB write. **Fix**: compare `r13` vs `r14` before every byte write. (file:`terminal_linux.asm:2494-2635`)
- **HIGH** — **`source` / `run_autoexec` line-copy overflow**. `handler_source` (5728-5755) and `run_autoexec` (5172-5190) copy byte-by-byte into `input_buf` (512 B) with no `cmp ecx, MAX_INPUT`. A single line >511 bytes in `~/.asmrc` overflows into `line_buf`, `line_len`, `line_cursor`, `path_buf`. **Fix**: bound copy like `history_add` already does (lines 1887-1897: `mov ecx, HISTORY_ENTRY_SIZE - 1`).
- **HIGH** — **`setenv_internal` unbounded writes into 512 B overlay slot**. `.se_cp_name` / `.se_cp_value` loops (lines 5028-5054) have no `ENV_OVERLAY_SIZE` check. Long `set NAME=VALUE` corrupts adjacent entries.
- **HIGH** — **`source` no recursion depth limit**. `source_read_buf` is global. File that sources itself = unbounded stack growth → crash.
- **MEDIUM** — **`alias_table` name/value unbounded `str_copy`**. Lines 4155-4166. Alias name >63 B or value >255 B corrupts adjacent slot. Safe in normal use but no enforced contract.

#### Correctness

- **HIGH** — **`ls` dotfile hiding broken**. `.ls_check_hidden` at line 6208 is an empty fall-through. Without `-a`, all dotfiles still display. Immediate UX bug.
- **HIGH** — **`ls -l` hardcoded permission strings** at lines 546-548 (three static strings `drwxr-xr-x`, `-rw-r--r--`, `-rwxr-xr-x`). Real stat mode bits never rendered. No owner/group/nlink/mtime.
- **HIGH** — **`ls -l` file sizes truncate at 4 GB**. Line 6239 `mov eax, [stat_buf + STAT_ST_SIZE]` reads only low 32 bits of 64-bit `st_size`.
- **HIGH** — **`calc` truncates 64-bit result to 32-bit** at line 6932 (`mov eax, r13d`). `calc 3000000000 * 2` prints 1,705,032,704 instead of 6,000,000,000.
- **HIGH** — **`calc` no operator precedence** — strictly left-to-right. `calc 2 + 3 * 4` returns 20.
- **HIGH** — **`handler_time` is just `jmp handler_date`** (lines 3073-3074). Functionally identical output.
- **HIGH** — **`handler_fg` missing SIGCONT**. Will wait4 on a stopped process and hang forever. (`handler_fg` 7520-7621)
- **HIGH** — **ISIG stays set in raw mode** → Ctrl+Z suspends the shell itself; no SIGTSTP interception.
- **HIGH** — **`handler_jobs` truncates PID to 32-bit** at line 7418 (`mov eax, eax`).
- **HIGH** — **Timezone hardcoded to PKT (UTC+5)** via `%define TZ_OFFSET_SECONDS 18000`. `date`/`time` are wrong everywhere else on earth.
- **HIGH** — **`handler_cd` no-args prints cwd** instead of going to `$HOME`. No `~` expansion anywhere except `~/.asm_history`, `~/.asmrc`.
- **HIGH** — **History file load capped at 4,095 bytes** — single `SYS_READ` in `load_history` 5241-5250 truncates.

#### Cross-platform parity

- **HIGH** — **Windows missing 9 Linux commands**: `source`, `ls`, `grep`, `uptime`, `free`, `calc`, `theme`, `jobs`, `fg`. Also missing: compound commands, `.asmrc`, persistent history, Ctrl+R, Ctrl+W/U, bg jobs, env overlay, syntax highlighting.
- **HIGH** — **Linux `set` not exported to children; Windows `set` is**. Different POSIX semantics per platform.

### Library Landscape (what the rest of the world uses)

- **Modern shells worth studying**
  - **HIGH** — Fish 4.0 (Feb 2025): core rewritten C++ → Rust, no breakage. Ncurses dropped for direct terminfo. Kitty keyboard protocol + XTerm modifyOtherKeys. OSC 133 + OSC 7 on every prompt. As-you-type syntax highlight, ghost autosuggestions, tab completion from man pages. [source: https://fishshell.com/blog/rustport/]
  - **HIGH** — Nushell: typed pipelines via `Value` enum + `PipelineData`. Three command categories (sources/filters/sinks). Not POSIX-compatible by design. [source: https://github.com/nushell/nushell, https://deepwiki.com/nushell/]
  - **MEDIUM** — Elvish, Murex, Oils/OSH+YSH, Xonsh — each with one or two distinctive traits.
- **Line-editor reference designs**
  - **HIGH** — linenoise (antirez, ~1,100 LOC C): only basic VT100 seqs. Used by Redis/MongoDB/Android. Proof of concept that a 1 KLOC line editor is enough.
  - **HIGH** — isocline (daanx, <8 KLOC C, zero deps): 24-bit color, history, completion, UTF-8, undo/redo, inc search, hints, brace match, auto-indent. Best target feature set for a small line editor.
  - **MEDIUM** — replxx (linenoise + UTF-8 + syntax highlight, used by ClickHouse), bestline, rustyline.
- **History systems (Atuin-style)**
  - **HIGH** — Atuin (29.4k★): SQLite `~/.local/share/atuin/history.db`. Per-cmd metadata: cwd, exit, duration, host, session, timestamp. E2E-encrypted optional sync. Ctrl+R full-screen with session/dir/global filter. [source: Atuin repo]
  - **HIGH** — McFly (7.3k★): neural net ranks suggestions on cwd + recent + exit. SQLite backend.
  - **MEDIUM** — hstr (4.5k★, C): fuzzy overlay on Ctrl+R, simpler than Atuin.
- **Prompt frameworks**
  - **HIGH** — Starship (51k★ Rust): per-prompt subprocess, TOML config, 1-10 ms render via async modules + caching. 80+ modules.
  - **HIGH** — oh-my-posh (22.2k★ Go): JSON/TOML/YAML config, block/segment model.
  - **Key pattern**: segment model = loop over config-driven function table. ~10-20 lines of NASM.
- **The "Bare" asm shell (isene, April 2026)** — **HIGH confidence, the bar asm-terminal must match or exceed** [source: https://isene.org/2026/04/Bare.html]
  - Single NASM file, 126 KB binary, no libc, no dynamic link, no malloc (BSS only).
  - 8µs startup (27× faster than Rust equivalent).
  - Features: raw mode via TCSETS, ANSI line editing, tab completion via opendir+getdents64, **git branch + dirty by reading `.git/HEAD` directly (no fork)**, Ctrl-R history, inline autosuggestions, multi-pipe, redirections, command chaining, brace expansion, glob, job control, color themes with syntax highlight, plugin system (`~/.bare/plugins/`).
  - Proves every feature on asm-terminal's wishlist is implementable in NASM.

### Best Practices (POSIX + 2025 table stakes)

- **HIGH** — **Signal handling canonical pattern**: block SIGWINCH at startup; unblock only during `pselect()`, OR use self-pipe trick (signal handler writes a byte → main poll loop reads it). Always unblock signals before `execve()`. [source: sitepoint.com/self-pipe-trick-explained, ldpreload.com/signalfd-is-useless]
- **HIGH** — **POSIX expansion order** (canonical, reorder at your peril): (1) brace → (2) tilde → (3) parameter → (4) command substitution → (5) arithmetic → (6) word splitting on $IFS → (7) pathname/glob → (8) quote removal. Breakage: tilde after parameter loses `~/$VAR`; brace must be first or `{$A,$B}` doesn't expand; word-split after glob causes double-quoted globbing.
- **HIGH** — **Accessibility chain**: `NO_COLOR` (any non-empty) → `CLICOLOR_FORCE` → `CLICOLOR=0` → `isatty(stdout)` → `COLORTERM=truecolor|24bit` → `$TERM *256color*` → default 8/16. `TERM=dumb` triggers full fallback (no ANSI, no OSC, no DECSCUSR, cooked mode). [source: no-color.org]
- **HIGH** — **Emacs keybinding canonical set** (readline): movement Ctrl-A/E/F/B + Alt-F/B; history Ctrl-P/N + Alt-</>/ Ctrl-R/S + Alt-P/N + Alt-./_ ; editing Ctrl-D/T/K/U/W/Y + Alt-T/U/L/C/D/Del + Ctrl-_; macros Ctrl-X (; Ctrl-V/Q quoted-insert; Ctrl-G abort; Alt-Space set mark; Ctrl-X Ctrl-X exchange. **Vi mode** needed for power-user cohort: hjkl, wbWB/eE, 0/$, iIaA, xX, dw/db/dd, cw/cb/cc, yy/p/P, u, r, f/F.
- **HIGH** — **OSC 133 semantic markers**: `ESC]133;A` prompt start, `B` cmd start, `C` output start, `D;exit` end. Enables jump-to-prompt, re-run, select-output in iTerm2, Warp, WezTerm, Ghostty. tmux 3.6+ forwards.
- **HIGH** — **OSC 7 cwd**: emit `\e]7;file://host/cwd\a` on every prompt → new-tab-same-dir + breadcrumbs in iTerm2/Warp/WezTerm/Ghostty/kitty.
- **HIGH** — **Bracketed paste**: enable `\e[?2004h` at startup, disable `\e[?2004l` at exit. Paste wrapped in `\e[200~...\e[201~`. Without it, paste that contains `\n` auto-executes → security hole. fish 4.0 pattern: strip/replace embedded newlines.
- **HIGH** — **DECSET 2026 synchronized output**: `\x1b[?2026h` / `\x1b[?2026l` atomic redraw on tmux 3.4+, Windows Terminal, iTerm2, Alacritty, kitty, foot.
- **HIGH** — **Kitty keyboard protocol (CSI u)**: emit `ESC[>1u` → resolves Tab ≠ Ctrl+I, Shift+Enter ≠ Enter. Adopted by kitty, WezTerm, foot, Alacritty, iTerm2, Rio, Ghostty, Windows Terminal 1.25+, Claude Code 2.1. [source: https://sw.kovidgoyal.net/kitty/keyboard-protocol/]
- **HIGH** — **POSIX filename safety**: only NUL and `/` forbidden — newlines/tabs/ctrl/spaces/leading-dash all legal. Rules: always quote, `./*` for globs, NUL-delimited `find -print0 | xargs -0`, strip ctrl chars <0x20/0x7F/0x80-0x9F before display.
- **HIGH** — **pipefail standardized in POSIX.1-2024**. Also standardized: `find -print0`, `xargs -0`, `read -d ''`. `set -e` canonical gotcha: does NOT exit in if-test, while/until cond, `&&`/`||` list (except final), `!`-inverted.

### Pitfalls to Avoid

- **HIGH** — **CVE-2014-6271 Shellshock**: bash auto-imported env-var function defs and failed to stop at `}`. **Lesson: never auto-evaluate env content as code.**
- **HIGH** — **CVE-2023-49284 fish (Dec 2023)**: PUA non-characters used as internal sentinels leaked from command substitution output; re-parse executed attacker-chosen code. **Lesson: internal sentinels must be scrubbed from external input at entry gate.**
- **HIGH** — **CVE-2021-45444 zsh**: PROMPT_SUBST + VCS_Info expanded attacker-controlled git branch name `$(evil)`. **Lesson: external data in prompt = quote as text, never re-expand.**
- **HIGH** — **CVE-2024-27822 (macOS zsh, Jun 2024)**: PackageKit ran PKG scripts with user's `.zshenv` loaded, root privileges. **Lesson: never source user config when privileged; asm-terminal should only load `~/.asmrc` when `isatty(stdin)` is true.**
- **HIGH** — **CVE-2025-61984 (bash/fish/csh, Oct 2025)**: SSH `ProxyCommand` `%r` expanded newline-containing usernames → command injection. Bash/fish/csh continued after arithmetic error on line 1; zsh exited correctly. **Lesson: arithmetic errors abort current command, don't fall through; strip ctrl chars (incl. newlines) from all external input.**
- **HIGH** — **Termios ioctl traps**: `TCGETA`/`TCSETA` use old SVR4 `struct termio` (don't use). `TCGETS2`/`TCSETS2` use incompatible `struct termios2` with custom baud rates (don't mix with standard `termios`). Use **`TCGETS=0x5401`, `TCSETS=0x5402`, `TIOCGWINSZ=0x5413`** in asm-terminal. POSIX `TCSAFLUSH = Linux TCSETSF`; `TCSETS = TCSANOW`. Wrong choice = keystroke-during-mode-switch race.
- **HIGH** — **SIGIO abandoned**: edge-triggered (misses state on partial read), doesn't work with regular files, non-deterministic under fork/threads. Use `poll()`/`epoll()` + self-pipe for SIGWINCH instead.
- **HIGH** — **signalfd fork trap**: child processes inherit masked signals unless explicitly reset before `execve()`.
- **HIGH** — **Cursor-position miscount classics**:
  - Invisible ANSI in prompt → wrap `\[...\]` (or raw `\001...\002`) around escapes or readline-style width counting breaks line wrap.
  - U+FE0F variation selector (e.g. cloud emoji ☁️) makes a narrow char render 2 cols wide but `wcwidth` returns 1. fish #10461. fish 4.6 switched default emoji width 1→2.
  - Multi-codepoint graphemes (family emoji = 7 codepoints, 2 cols) — only UAX #29 grapheme segmentation is correct; most shells approximate.
- **HIGH** — **Startup traps**: <50 ms target ("indistinguishable from zero"). zsh4humans ~25 ms; stock oh-my-zsh 500-2000 ms. Don't fork to eval config. fish 4.6 found macOS terminal DA1/DA2 responses stall startup — terminal queries need timeout fallback.
- **HIGH** — **Bracketed paste security hole**: without bracketed paste mode, pasted text with embedded `\n` auto-executes.
- **HIGH** — **Alias expansion re-entry**: bash/fish classic. `alias foo="cmd $VAR"` (double-quote) vs `alias foo='cmd $VAR'` (single-quote) = expand at definition vs use time. Trailing-space alias (`sudo '`) makes next token also alias-checked. Fish dropped aliases entirely in favor of functions. **If asm-terminal keeps aliases: substitute then RE-PARSE from start of expansion pipeline, not string-replace.**
- **HIGH** — **Glob DoS**: zsh `**` in deep tree = millions of results in minutes. `setopt GLOB_LIMIT` caps. Bash has no equivalent. **Defense: cap results (~10,000) before sort/dedup; warn on truncation.**
- **HIGH** — **Terminal injection via filenames**: `\x1b[2J`, OSC8 `\x1b]8;;evil.com\x1b\\`, `\x1b[?25l`, OSC52 clipboard-write, OSC5113 kitty file-transfer — all weaponized when `ls` prints raw bytes. **Defense: before printing any filename, replace bytes <0x20, 0x7F, 0x80-0x9F with `?` or `\xNN`** (match GNU ls `--quoting-style=shell-escape`).
- **MEDIUM** — **fish 4.1.0**: `set_color --background=COLOR` silently activated bold; fixed 4.2. Lesson: reset color state to known at each prompt redraw.
- **MEDIUM** — **fish 4.3.0**: crash on bad color variable. Defensive color parsing.
- **MEDIUM** — **bash 5.3-beta**: redirections underwent word expansion twice (double-sub). Lesson: each expansion stage = distinct pass, no re-entry.
- **MEDIUM** — **fish #12496 (2025)**: `write()` EINTR from SIGWINCH permanently set errored flag. Retry on any EINTR; detect cancellation separately.
- **MEDIUM** — **Cursor shape not restored on exit**: universally regretted (helix, neovim, yazi). Emit `\e[0 q` or `\e[ q` (no param) in SIGTERM/SIGINT/SIGHUP handler before `_exit()`, and on normal exit.
- **MEDIUM** — **8-bit cleanliness**: track explicit lengths, never null-term as sentinel for data in pipes. Clear IXON in raw termios or XON/XOFF (0x11/0x13) vanish silently.
- **MEDIUM** — **tmux title**: `\e]0;T\a` is safe on any terminal. `\ek...\e\\` is screen/tmux-only — garbage elsewhere. Check `$TERM=screen*/tmux*` before using.
- **MEDIUM** — **SIGPIPE handling**: shell should NOT treat child SIGPIPE as fatal; child should `SIGPIPE=SIG_DFL` before execve; shell's own EPIPE on output → exit current cmd with status 141 (128+13), not shell.
- **MEDIUM** — **Blocking read on SSH disconnect**: some terminals send EIO instead of EOF. Handle EIO as graceful exit.

### Existing Art — Key Reference Implementations

- **HIGH** — **Bare (isene 2026)**: 126 KB single-file NASM, everything wired up. Specific techniques to borrow:
  - **Git branch via direct `.git/HEAD` read** (`readlinkat` / open+read, ~10µs vs ~50 ms for `git branch --show-current`). Parse `ref: refs/heads/NAME\n` or bare SHA.
  - ANSI line editing without any library.
  - `opendir` + `getdents64` for tab completion.
  - Plugin system in `~/.bare/plugins/`.
- **HIGH** — **linenoise** (1.1 KLOC C): proves a tiny line editor is enough for Redis/MongoDB/Android.
- **HIGH** — **isocline** (<8 KLOC C): feature set to aim for (UTF-8, 24-bit color, undo/redo, brace match, auto-indent).
- **HIGH** — **Fish 4.x**: autosuggestions (right-arrow / Ctrl-F accepts), abbreviations (expand live on Space/Enter, full stored in history), multi-line input, OSC 133 + OSC 7 on every prompt.
- **HIGH** — **Atuin**: SQLite history with exit/cwd/duration/host/session/timestamp; E2E-encrypted sync; filter by dir/session/host.
- **HIGH** — **gitstatus (romkatv)**: persistent daemon for git prompt at ~31 ms vs ~295 ms for `git status` (10× faster). Alternative: cheap direct read of `.git/HEAD`.

## Contradictions & Open Questions

- **No direct contradictions** between agents — findings are complementary.
- **Open: UTF-8 grapheme segmentation depth**. Library agent says "most shells approximate"; pitfalls agent says "only UAX #29 is correct". Debatable trade-off: asm-terminal can approximate per-codepoint `wcwidth` for v1 and accept emoji-width bugs the rest of the industry lived with until 2025; full UAX #29 is large for NASM.
- **Open: alias vs function model**. Library agent notes fish dropped aliases; best-practices agent documents classic alias gotchas. If asm-terminal keeps aliases, bug class returns; if it moves to functions, it's a larger architectural change.
- **Open: history backend**. Atuin's SQLite is the reference, but SQLite-in-NASM is not realistic short-term. Flat append-only with metadata fields (as Atuin used for its first year) is a reasonable intermediate.
- **Open: `GLOB_LIMIT` equivalent cap**. 10,000 is pitfalls agent's suggestion but not a standard — pick based on `dir_stack` / available BSS.

## Codebase Context

- **Architecture**: dual dispatch table + single monolithic file per platform. `terminal_linux.asm` 7,851 lines, `terminal.asm` 2,690 lines, zero `%include`.
- **Memory**: ~120 KB fixed `.bss`. All limits compile-time (32 history entries, 32 aliases, 64 env overlays, 16 dir-stack slots).
- **Dependencies**: all externals + pipes delegated to `/bin/sh -c input_buf` (Linux) / `cmd.exe /c` (Windows). No native pipe implementation.
- **Test state**: zero tests, zero CI. README suggests `echo -e "cmd\nexit" | ./terminal`.
- **Parity**: Linux ahead of Windows by 9 commands (`source`, `ls`, `grep`, `uptime`, `free`, `calc`, `theme`, `jobs`, `fg`) plus compound commands, `.asmrc`, Ctrl+R, Ctrl+W/U, bg jobs, env overlay, syntax highlighting. Linux `set` broken (not exported); Windows `set` correct (Win32 API). Opposite direction of most parity.

## Implications for Design

### Priority 1 — Fix Critical Bugs (security + crash) — Low effort

1. `env_expand_buf` overflow (`terminal_linux.asm:2505` end-guard never checked against r13)
2. `source` / `autoexec` line-copy overflow (lines 5172-5190, 5728-5755)
3. `setenv_internal` unbounded write (lines 5028-5054)
4. `ls` dotfile hiding broken (empty fall-through at line 6208)
5. `handler_fg` missing `kill(pid, SIGCONT)`
6. ISIG set in raw mode → Ctrl+Z suspends shell; clear ISIG + add software SIGTSTP handler
7. Unchecked `SYS_WRITE` in `handler_copy` (line 3811)
8. `source` no recursion depth limit

### Priority 2 — Table-Stakes Modernization — Medium effort

1. `NO_COLOR` + `CLICOLOR` + `CLICOLOR_FORCE` + `TERM=dumb` + `COLORTERM` detection chain on every ANSI emit
2. `SIGWINCH` handler + `TIOCGWINSZ` (the struct exists at `winsize_buf` line 722 but ioctl is never called)
3. OSC 133 semantic markers (`A`/`B`/`C`/`D;exit`) around prompt + command + output
4. OSC 7 cwd emission on every prompt and every `cd`
5. Bracketed paste mode (`\e[?2004h` / `\e[?2004l`, parse `\e[200~...\e[201~`, strip newlines per fish 4.0 pattern)
6. DECSCUSR cursor-shape reset on all exit paths (SIGTERM/SIGINT/SIGHUP handler + normal exit)
7. Kitty keyboard protocol opt-in (`ESC[>1u` on startup, parse CSI u responses)
8. TTY-aware output: gate ANSI/color/prompt/syntax-highlight on `isatty(stdout)`, prompt on `isatty(stdin)`

### Priority 3 — Built-in Quality + Missing Commands — Medium effort

1. `ls -l` real permissions from stat mode bits; 64-bit size; owner/group/nlink/mtime
2. `calc` operator precedence (Shunting-yard or recursive descent) + full 64-bit output
3. `grep -i` / `-n` / `-v` / `-r`
4. `cd` no-args → `$HOME`; `~` expansion in tilde-expansion stage
5. `echo -n` / `-e` with escape interpretation (`\n`, `\t`, `\x`)
6. `mkdir -p`, `rmdir -p`, `del -f`, `copy -r`
7. `export`, `unset`, `unalias`, `bg`
8. Timezone from `$TZ` / `/etc/localtime` parsing (not hardcoded PKT)
9. `help <cmd>` per-command help

### Priority 4 — New User-Facing Features — Medium/High effort

1. Ghost-text autosuggestions from history (Fish-style: longest prefix match, right-arrow or Ctrl-F accepts, render dim ANSI after cursor). Bare demo'd feasible in NASM.
2. Extended syntax highlighting: pipes/redirectors cyan, quoted strings yellow, `$VAR` magenta, path args green (exists) / red (missing).
3. Configurable PS1-style prompt (segment-based, Starship/oh-my-posh model). Loop over config-driven function table.
4. Git branch in prompt via direct `.git/HEAD` read (~10µs, no fork).
5. History bump 32 → 500+ entries with metadata (exit code, cwd, timestamp, duration). Flat append-only `~/.asm_history_v2` as Atuin-intermediate.
6. Ctrl-R filter by cwd / session / exit-code.
7. Kill-ring: Ctrl+K, Ctrl+U, Ctrl+Y, Ctrl+W, Alt-Y rotate, Alt-D kill-word.
8. Word motion: Alt+B / Alt+F (requires UTF-8 grapheme segmentation first).
9. Ctrl+A / Ctrl+E (home/end aliases).
10. Ctrl+D (EOF on empty / delete-char).
11. Multi-line editing for unclosed quotes / trailing backslash → `>` continuation prompt.
12. Vi mode (full second keymap).
13. `!!` / `!n` / `!prefix` history expansion.

### Priority 5 — Shell Semantics Upgrades — High effort

1. Quoting (single-quote literal, double-quote with `$VAR`, backslash escape) with proper re-parse semantics.
2. Redirection: `2>`, `2>&1`, `&>`, here-docs.
3. POSIX expansion pipeline in canonical order: brace → tilde → parameter → cmd-sub → arith → word-split → glob → quote-removal.
4. `$?` and other special vars (`$$`, `$!`, `$#`, `$@`, `$0`-`$9`).
5. `||` logical-or in compound commands (currently only `;` and `&&`).
6. `set -e` / `set -o pipefail` / `set -o xtrace` (POSIX.1-2024 baseline).
7. UTF-8 cursor tracking + grapheme-aware width (at minimum per-codepoint wcwidth).
8. Scripting: if/then/else, while, for, functions, local vars, return, break, continue.

### Priority 6 — Cross-Platform Parity — High effort

1. Port Linux-only 9 commands to Windows (`source`, `ls`, `grep`, `uptime`, `free`, `calc`, `theme`, `jobs`, `fg`).
2. Add compound commands, `.asmrc`, Ctrl+R history search, job control, env overlay, syntax highlighting to Windows.
3. Use Windows Job Objects (`CreateJobObject` + `AssignProcessToJobObject`) for process-group equivalent → reliable Ctrl+C + kill-tree.
4. Unified env overlay propagation: Linux must rebuild envp from `saved_envp + env_overlay` before `execve` (currently passes `saved_envp` unmodified at line 4312).

### Priority 7 — Infrastructure — Medium effort

1. Test harness: BATS suite driven from `echo -e ... | ./terminal`, diff against bash for common commands.
2. Differential testing against bash for compat subset.
3. Fuzz harness on `input_buf` (random bytes, long lines, control chars) — immediately finds Priority 1 overflow bugs.
4. `%macro PRINT msg, len` / `%macro REGISTER_CMD name, handler` — cuts ~165 boilerplate sites, adds registration ergonomics.
5. Split monolithic files into `%include`'d modules (e.g. `io.inc`, `strings.inc`, `dispatch.inc`, `termios.inc`, `parse.inc`).
6. Packaging: `make install` target, `.deb` via fpm, `PKGBUILD` for Arch, GitHub Releases with static ELF binary + `.exe`.
7. GitHub Actions CI: `make` on Linux, `nasm + ld.lld` on Windows runner, run BATS suite.
8. README + CLAUDE.md kept current (CLAUDE.md already good; README may need refresh).

### Implementation Order (from pitfalls agent's dependency graph)

```
raw syscalls → buffers → UTF-8 (+ width) → quoting → redirection
    → $VAR expansion → tilde → brace+glob → alias → execve+job-control
    → tab completion → Ctrl-R → bracketed paste → OSC 133/7 → vi mode
    → DECSET 2026 synchronized output
```

Key hard rules:
- **UTF-8 grapheme handling BEFORE word motion (Alt+B/F)** — otherwise offsets wrong.
- **Quoting BEFORE tab completion AND glob** — otherwise `"*"` globs incorrectly and tab completes inside strings badly.
- **SIGWINCH handler BEFORE vi mode** — vi uses dimensions for scroll.
- **Bracketed paste AFTER redraw is stable** — paste floods redraw, masks flicker bugs.
- **OSC sequences AFTER functional features tested** — cosmetic layer.
- **Alias expansion must RE-PARSE from pipeline start, not string-replace** — otherwise `alias foo='echo $VAR'` gotcha returns.

## Sources

- https://fishshell.com/blog/rustport/ — Fish 4.0 Rust port, Feb 2025, drop ncurses, adopt Kitty proto + OSC 133/7
- https://github.com/nushell/nushell — Nushell typed-pipeline architecture
- https://github.com/elves/elvish — Elvish structured-value shell
- https://github.com/lmorg/murex — Murex typed pipelines, test framework
- https://oilshell.org — Oils/OSH+YSH bash-compat + new typed lang
- https://github.com/emersion/mrsh — POSIX shell as C library
- https://github.com/leto/asmutils — 138+ Unix utils in NASM x86 (asmutils)
- https://dev.to/viz-x/ — KolibriOS/MenuetOS asm-shell overview
- https://github.com/kittrz9/assembly-shell — minimal x86-64 NASM shell (1★)
- https://isene.org/2026/04/Bare.html — **"Bare" single-file NASM shell, April 2026, full features, 126 KB — the bar to match**
- https://sw.kovidgoyal.net/kitty/keyboard-protocol/ — Kitty keyboard protocol (CSI u) reference
- https://deepwiki.com/fish-shell/ — Fish syntax highlighting algorithm (5-stage highlight_shell)
- https://deepwiki.com/nushell/ — Nushell PipelineData & Value enum
- https://deepwiki.com/zsh-users/zsh/ — Zsh completion architecture (compcore, compadd, _main_complete)
- https://gnu.org/s/libc/manual/ — POSIX job control signals (setpgid/tcsetpgrp/SIGCONT/SIGTSTP)
- https://learn.microsoft.com/ — Windows Job Objects (CreateJobObject), no-signals model
- https://blog.toast.cafe/posix2024-xcu — POSIX.1-2024 shell additions (pipefail, -print0, xargs -0, read -d '')
- https://mgree.github.io/papers/popl2020_smoosh.pdf — Smoosh formal POSIX shell semantics (Greenberg POPL 2020)
- https://no-color.org — NO_COLOR environment-variable convention, 200+ tools
- https://sitepoint.com/self-pipe-trick-explained — canonical self-pipe pattern for SIGWINCH
- https://ldpreload.com/signalfd-is-useless — signalfd fork/execve pitfalls
- GNU Readline manual — canonical emacs + vi keybinding sets
- invisible-island.net XTerm Control Sequences — definitive VT100/VT220/ECMA-48 reference
- VTTEST — terminal conformance test suite
- Joey Hess 2019 "typed pipes in every shell" blog — MIME-header structured pipes
- Atuin repo — SQLite history + E2E sync (29.4k★)
- McFly repo — neural-net ranked history (7.3k★)
- hstr repo — fuzzy-overlay history (4.5k★)
- Starship repo — Rust per-prompt subprocess, 80+ modules (51k★)
- oh-my-posh repo — Go block/segment prompt (22.2k★)
- fish-shell GitHub Wiki — UX innovations, abbreviations, universal vars
- zsh-bench (romkatv) — first-prompt/first-cmd methodology + measurements
- gitstatus (romkatv) — persistent daemon for 10× git-prompt speedup
- yash-rs issue #422 — POSIX.1-2024 impl tracker
- dwheeler.com "Filenames in Shell" — canonical ref for POSIX filename safety
- CVE-2014-6271 (Shellshock) — env-var function-def injection in bash
- CVE-2023-49284 (fish) — PUA sentinel leak from command substitution, Dec 2023
- CVE-2021-45444 (zsh) — VCS_Info git branch RCE via PROMPT_SUBST
- CVE-2024-27822 (macOS zsh) — ~/.zshenv loaded at privileged invocation
- CVE-2025-61984 (bash/fish/csh) — SSH ProxyCommand %r newline injection, Oct 2025
