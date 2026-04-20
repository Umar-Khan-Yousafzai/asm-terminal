# Findings Board: Improvements & features for asm-terminal (x86-64 NASM shell, Linux + Windows)

## Wave 1 Summary (4 agents: 2 codebase, 2 web)

### From codebase-arch-patterns-deps agent

- Dispatch: dual table (exact 12 + prefix 22 entries). No macro for cmd registration.
- Monolithic single-file per platform. No %include. str_copy/str_len/print_number duplicated.
- BSS ~120KB fixed. All limits compile-time.
- **Bugs with security impact**:
  - `env_expand_buf` end-guard `r14` defined but never compared → 1KB buffer overflow via long $VAR.
  - `source`/`autoexec` line-copy into `input_buf` unchecked → overflow via line >511B in ~/.asmrc.
  - `setenv_internal` unbounded into 512B slot.
- **Bugs non-security**:
  - 35% of syscalls unchecked (TCGETS, rt_sigaction, SYS_WRITE in handler_copy).
  - `execute_external` passes `saved_envp` unmodified → env overlay invisible to children (Linux only; Windows uses real Win32 API so parity mismatch).
  - `calc` truncates 64-bit result to 32-bit (`mov eax, r13d` at 6932).
  - `calc` no operator precedence.
  - `ls -l` fake permissions (three hardcoded strings at 546-548).
  - `ls -l` 32-bit size (files >4GB wrap).
  - `ls` dotfile hiding broken — `.ls_check_hidden` at 6208 is empty fall-through → all dotfiles always shown.
  - `handler_time` = `jmp handler_date`.
  - `errno_table` in .data dead code.
  - `TIOCGWINSZ` + `winsize_buf` defined but never used → `ls` doesn't adapt to width.
  - No SIGWINCH handler.
  - `source` no recursion depth check → crash on self-source.
  - `handler_jobs` truncates PID to 32-bit (`mov eax, eax` at 7418).
  - `handler_fg` does NOT send SIGCONT → hangs on truly stopped procs.
  - Timezone hardcoded PKT (UTC+5).
- **Windows parity gap**: 9 missing commands (source, ls, grep, uptime, free, calc, theme, jobs, fg); no compound cmds, no .asmrc, no Ctrl+R/W/U, no bg jobs, no syntax highlight.
- **Tests**: ZERO. Biggest maintenance liability.

### From codebase-features-tests agent

Completeness matrix of 30+ commands: see raw-codebase-features.md. Most partial. Notable gaps:
- cd no-args = cwd, not $HOME. No `~` expansion.
- echo no -n/-e. whoami just reads $USER.
- mkdir no -p. rmdir no -p. copy always 0644. move no cross-device.
- set no export/unset/readonly. No unalias.
- source 4KB cap, no if/for/while/functions.
- ls no sort/owner/group/mtime.
- grep no flags, no regex, single file.
- free just raw dump of /proc/meminfo 6 lines.
- theme 3 hardcoded.

**Line editor missing**: Alt+B/F (word jump), Ctrl+K (kill-line), Ctrl+Y (yank), Ctrl+T (transpose), Ctrl+X Ctrl+E (edit in $EDITOR), Ctrl+D, Ctrl+A/E, Ctrl+P/N. ESC alone discarded → Alt-* sequences broken.

**History**: 32 entries × 512B; persistent load caps at 4KB. No !! !n expansion.

**Tab completion**: files only. No commands/aliases/$VAR/~ completion. No quote-aware.

**Prompt**: not customizable. No PS1. No git/exit_code/time.

**Redirection**: no 2>, 2>&1, here-docs, process substitution. Breaks on quoted filenames with spaces.

**Job control**: fg no SIGCONT. ISIG stays set → Ctrl+Z suspends the shell itself. No bg.

**Quoting**: NONE. No `~` expansion. No `$?`.

**i18n**: byte-only. UTF-8 cursor corrupts. **Accessibility**: no NO_COLOR. **Packaging**: no install/deb/rpm/PKGBUILD/AppImage/Dockerfile/Releases.

### From library-landscape + existing-art agent

- **Modern shells**: Fish 4.0 (Feb 2025, Rust rewrite). Nushell (typed pipelines). Elvish. Murex. Oils (OSH+YSH). Xonsh.
- **Hobby assembly shells**: **"Bare" by isene (April 2026)** is most complete NASM shell — single file, 126KB, 8µs startup, raw-mode termios, ANSI editing, tab completion via opendir+getdents64, git branch from reading .git/HEAD directly (no fork!), Ctrl-R, inline suggestions, multi-pipe, redirections, brace expansion, glob, job control, themes, syntax highlight, plugin system. [https://isene.org/2026/04/Bare.html] — this is the BAR asm-terminal should match.
- **Line editor libs (reference designs)**: linenoise 1.1K LOC, replxx, isocline (<8K LOC, 24-bit color, undo/redo, brace match, auto-indent).
- **Kitty Keyboard Protocol (CSI u)**: emit `ESC[>1u` → resolves Tab≠Ctrl+I, Shift+Enter.
- **OSC 133** markers + **OSC 7** cwd → free integration with Ghostty/WezTerm/iTerm2/Warp.
- **Atuin** (29.4k★) history model: SQLite + per-cmd exit/cwd/session/dur. E2E encrypted sync.
- **Fish syntax highlighting**: parse AST → HighlightRole per char → validate cmd/path on background thread.
- **Prompt frameworks**: Starship (modules, TOML, Rust async, 1-10ms render), oh-my-posh (segments).
- **Top 8 things to steal**: Atuin-style history; ghost autosuggestions; extended syntax highlight; Kitty keyboard proto; OSC 133; segment-based prompt; 500+ history with cwd/session filter; multi-line editing.
- **Windows bonus**: Job Objects for terminal.asm process-group equivalent.

### From best-practices agent

- **POSIX.1-2024** adds: pipefail standardized, find -print0, xargs -0, read -d ''.
- **set -e gotchas**: doesn't exit in if-tests, `&&`/`||`, while/until conds, `!`-inverted.
- **Readline emacs keys**: full list — Ctrl+A/E/F/B, Alt+F/B word; Ctrl+P/N history; Alt-< Alt-> first/last; Ctrl-R/S; Alt-P/N non-inc; Alt-. Alt-_ last-arg; Ctrl-K/U/W/D; Alt-D kill-word; Ctrl-Y yank; Alt-Y rotate; Ctrl-T/Alt-T transpose; Alt-U/L/C case; Ctrl-V/Q quoted-insert; Ctrl-G abort.
- **Vi mode** keys listed.
- **Table-stakes prompt**: cwd, git, exit code, duration (>2s), virtualenv, SSH indicator, job count.
- **Signals**:
  - SIGINT: shell catches, doesn't exit. fg child gets it direct from driver.
  - SIGTERM: interactive = ignore.
  - SIGHUP: send to all jobs.
  - SIGTSTP: job-control shell ignores, sent to fg pgroup. tcsetpgrp handoff.
  - **SIGWINCH: ioctl TIOCGWINSZ → update COLUMNS/LINES → redraw**.
  - Raw termios: clear ICANON+ECHO, VMIN=1 VTIME=0.
  - Job-control sequence: setpgid(pid,pid) per child → tcsetpgrp(STDIN, pgid).
- **POSIX filename safety**: only NUL+`/` forbidden. Use "$var", `./*`, NUL pipelines, strip ctrl on display.
- **NO_COLOR chain**: NO_COLOR → CLICOLOR_FORCE → CLICOLOR=0 → isatty → COLORTERM for depth.
- **PS1 escapes**: `\u\h\H\w\W\$\t\T\@\A\d\j\l\n\r\s\v\V\!\#\\\[\]`. `\[` `\]` wrap ANSI or cursor breaks.
- **Tab completion UX**: 1st Tab = common prefix, 2nd = list. Case-insens default. Fuzzy expected.
- **Large history**: SQLite (Atuin). Index required at 100k+.
- **Fish UX innovations**: autosuggestions, abbreviations (expand live on Space/Enter, full stored in history), right prompt, universal vars, web config, OSC 7 every prompt.
- **Starship arch**: Rust binary, modules in parallel, TOML, cross-shell via `starship prompt` subprocess.

## Wave 2 Summary (pitfalls agent)

Top callouts:
- **Fish #12496 (2025)**: write() EINTR from SIGWINCH permanently set errored flag. Any EINTR → retry, don't set error.
- **fish CVE-2023-49284**: internal PUA sentinels leaked from cmd-sub → expansion of $HOME. Scrub external input at entry gate.
- **bash 5.3-beta**: redirections expanded TWICE (double-subst). Each expansion stage = distinct pass.
- **CVE-2021-45444 zsh**: PROMPT_SUBST + VCS_Info git branch `$(evil)` → RCE. External data in prompt = quote as text, don't re-expand.
- **CVE-2025-61984 (Oct 2025)**: newline in SSH %r injected into bash commands. Strip ctrl chars from all external input; arithmetic errors abort cmd, don't fall through.
- **CVE-2024-27822**: ~/.zshenv loaded when privileged. Skip user config on elevated privs. asm-terminal should load ~/.asmrc only when isatty(STDIN).
- **Termios ioctls**: stick to TCGETS=0x5401, TCSETS=0x5402, TIOCGWINSZ=0x5413. Don't use TCGETA/TCSETA (old SVR4) or TCGETS2 (incompatible struct).
- **SIGIO abandoned**: edge-triggered, regular-file-incompatible, thread-non-deterministic. Use poll()/epoll() + self-pipe for SIGWINCH.
- **Cursor miscount**: wrap ANSI in `\001\002`. Emoji width: U+FE0F variation selector changes width; wcwidth is per-codepoint not per-grapheme (UAX #29 grapheme segmentation needed for perfect; most shells approximate).
- **Startup budget**: <50ms target. Don't fork for config. Don't send terminal queries (DA1/DA2) without timeout fallback.
- **Git branch without fork**: `readlinkat(".git/HEAD")` ~10µs vs `git branch` ~50ms. Parse `ref: refs/heads/NAME\n` directly.
- **Redraw optimization**: DECSET 2026 synchronized output (`\x1b[?2026h`/`l`) on tmux 3.4+/WT/iTerm2/Alacritty/kitty/foot. Diff-based cell compare. For printable chars, just append + advance — reserve full redraw for editing ops.
- **TTY gate list**: isatty(STDIN) for prompt; isatty(STDOUT) for color; isatty(STDERR) for progress; NO_COLOR regardless; TERM=dumb = full fallback (no ANSI/OSC/DECSCUSR; cooked or basic editing).
- **SIGPIPE**: shell ≠ fatal on child SIGPIPE. In child, SIGPIPE=SIG_DFL before execve. On own EPIPE, exit current cmd status 141 (128+13).
- **tmux title**: `\e]0;T\a` safe everywhere. `\ek...\e\\` only if $TERM=screen/tmux, else garbage.
- **OSC 133 markers**: A (prompt start), B (cmd start), C (output start), D;exitcode (end). tmux 3.6+ forwards.
- **OSC 7**: emit on every cd. `\e]7;file://host/path\a`.
- **DECSCUSR reset on exit**: emit `\e[0 q` in SIGTERM/SIGINT/SIGHUP handler before _exit(), also in normal exit path.
- **8-bit cleanliness**: track explicit lengths, not null-term sentinel, for data passing through pipes. Clear IXON in raw mode or XON/XOFF vanish.
- **Bracketed paste**: `\e[?2004h`/`l`. Strip newlines from paste (fish 4.0 pattern). Prevents "paste + \n = exec" security hole.
- **Alias expansion bug class**: fish replaces with functions. If asm-terminal keeps aliases: substitute + RE-PARSE from start, don't just string-replace.
- **Glob DoS defense**: cap results (10,000) before sort/dedup.
- **Terminal injection via filenames**: before printing, replace bytes <0x20, 0x7F, 0x80-0x9F with `?` or `\xNN`. Critical for OSC8 hyperlink attacks.
- **ls to pipe**: always isatty(STDOUT) before color.
- **Implementation-order dependency graph** (critical): raw syscalls → buffers → UTF-8 → quoting → redirection → variable expansion → tilde → glob → alias → execve → completion → Ctrl-R → bracketed paste → OSC 133/7 → vi mode → DECSET 2026. Key rules: UTF-8 before word-movement, quoting before tab completion, quoting before glob, SIGWINCH before vi mode.

## Gaps / Unanswered Questions (none — coverage sufficient for synthesis)

1. What are COMMON MISTAKES shell authors make when implementing line editing (termios race conditions, SIGWINCH during read, partial UTF-8 reads)?
2. What are KNOWN VULNERABILITIES in shell implementations historically (CVE-Shellshock bash function injection, glob DoS, PATH confusion, TOCTOU on .profile)?
3. What are DEPRECATED practices (old termios BSD ioctls, SIGIO, readline hardcoded bindings) vs modern?
4. What are PERFORMANCE PITFALLS (slow startup, fork-per-prompt, redraw-per-keystroke, unbounded history scan)?
5. What are UX PITFALLS others regret (forced interactivity, ANSI codes counted in cursor position, no fallback for dumb terms, breaking pipes when piped)?
6. What IDE / TUI integration breaks if shell does X (tmux window title, ctrl-flow, 8-bit char handling, cursor shape not restored)?
7. Any specific bugs or anti-patterns documented in fish/zsh/bash changelogs worth avoiding?
8. What assumptions about ~/.asmrc loading / env expansion / alias resolution order are common sources of bugs?
9. What's the right order to implement features to minimize regressions (which depends on which)?
