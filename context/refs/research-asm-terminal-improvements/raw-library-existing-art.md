## Agent: library-landscape-existing-art

### Q1 — Leading Modern Shells

**Fish 4.0** (Feb 2025, 33.2k★): Entire core rewritten from C++ to Rust, no breakage. Ncurses dropped; terminfo direct. Kitty keyboard protocol + XTerm modifyOtherKeys. OSC 133 shell integration, OSC 7 CWD. Signature: as-you-type syntax highlight, ghost autosuggestions from history, tab completion from man pages, fish_config web UI, zero-config. [https://fishshell.com/blog/rustport/]

**Nushell** (39.1k★): Pipelines pass typed structured values (tables/records/lists) via `Value` enum + `PipelineData`. Three command categories (sources/filters/sinks). Lazy streaming. Most-starred alt shell. [https://github.com/nushell/nushell]

**Elvish** (6.3k★): Structured values, exception scripting, namespacing, anonymous fns, syntax-checking readline, location-mode navigation. [https://github.com/elves/elvish]

**Murex** (1.9k★): Typed pipelines (JSON/YAML/XML/CSV native), inline spell-check, context-sensitive hints, auto-man-parse completions, try/catch, built-in test framework. [https://github.com/lmorg/murex]

**Oils (OSH+YSH)** (3.2k★): OSH = bash-compat. YSH = new typed language. Core transpiled Python→C++. 8 releases in 6 months 2025. [https://oilshell.org]

**Xonsh**: Python + shell interleaved. Niche for data-science. [source]

### Q2 — Minimal / Hobby / Assembly Shells

**mrsh** (emersion, 519★): POSIX shell as library + `/bin/sh`. C99, MIT. [https://github.com/emersion/mrsh]

**BusyBox ash/hush**: ash.c ~25k LOC. Most complete embedded shell. [source]

**asmutils** (72★): 138+ Unix utilities in NASM x86. Small libc + crypto lib. [https://github.com/leto/asmutils]

**KolibriOS / MenuetOS** (OS in FASM asm, 2004–present): Shell with ls/cp/del/rn/kill/ps/cls/ver/exit/shutdown/echo/help. Entire OS fits 1.44MB floppy. Non-POSIX. [https://dev.to/viz-x/...]

**kittrz9/assembly-shell** (1★): x86-64 NASM. Full-path exec, /bin/ resolution, Ctrl+C, cd, exit. No line editing/history. [https://github.com/kittrz9/assembly-shell]

**"Bare" by isene (April 2026)**: Full login shell in single NASM file. No libc, no dynamic link, no malloc (BSS only). 126 KB binary, 8µs startup (27× faster than Rust equiv). Features: raw-mode via TCSETS, ANSI line editing, tab completion via opendir+getdents64, **git branch/dirty via reading .git/HEAD directly (no fork!)**, Ctrl-R history, inline suggestions, multi-pipe, redirections, command chaining, brace expansion, glob, job control, color themes with syntax highlighting, plugin system (~/.bare/plugins/). [https://isene.org/2026/04/Bare.html]

### Q3 — Line Editor Libraries (reference designs)

- **GNU Readline**: GPL. Canonical. ~30k LOC. vi+emacs keymaps, kill-ring, multi-line, programmable completion.
- **linenoise** (antirez, 4.2k★): ~1,100 LOC C. Only basic VT100 seqs. Single/multi-line, history, tab, hints, mask, UTF-8. Used by Redis/MongoDB/Android.
- **replxx** (AmokHuginnsson, 746★, BSD): Linenoise+UTF-8+syntax highlight+hints+cross-platform. Used by ClickHouse.
- **isocline** (daanx, 324★): <8k LOC C, zero deps. 24-bit color, history, completion, unicode, undo/redo, inc search, hints, highlight, brace match, auto-indent.
- **bestline** (jart): Refinement of linenoise. Minimal size. BSD.
- **rustyline** (1.9k★): Readline in Rust. UTF-8, history search, kill ring, multi-line.

None link directly into NASM. Lesson = feature set they standardize: raw mode, VT100 movement, kill-ring (Ctrl+K/U/Y), word-motion (Alt+F/B), inc search (Ctrl+R), dim hints.

### Q4 — Pipeline / Job Control

**POSIX job control**: setpgid() per pipeline → tcsetpgrp() gives terminal to fg group. Ctrl+Z → SIGTSTP to fg group. `bg` = SIGCONT bg. `fg` = tcsetpgrp + SIGCONT. SIGCHLD handler updates state. Shell ignores SIGTSTP/SIGTTOU. Five signals: SIGCHLD, SIGCONT, SIGSTOP, SIGTSTP, SIGTTOU. [https://gnu.org/s/libc/manual/...Job-Control-Signals]

**Windows**: No process groups/signals. Use Job Objects (CreateJobObject + AssignProcessToJobObject). No SIGTSTP. Closest = CTRL_BREAK_EVENT via GenerateConsoleCtrlEvent(). Windows Terminal Preview 1.25 adds Kitty keyboard protocol. [https://learn.microsoft.com/...]

### Q5 — Terminal UI / Escape Refs

- **XTerm Control Sequences** (invisible-island.net): definitive VT100/VT102/VT220/ECMA-48 reference. Living doc.
- **VTTEST**: conformance test suite.
- **Kitty Keyboard Protocol (CSI u)**: Resolves 48-year ambiguity (Tab≠Ctrl+I, Shift+Enter≠Enter). `ESC [ <cp> ; <mod> u`. Modifier bits: Shift=1,Alt=2,Ctrl=4,Super=8 (+1). Adopted by kitty, WezTerm, foot, Alacritty, iTerm2, Rio, Ghostty, Windows Terminal 1.25+. Claude Code v2.1.0 adopted. [https://sw.kovidgoyal.net/kitty/keyboard-protocol/]
- **OSC 133** (shell integration): `ESC]133;A` prompt, `B` cmd start, `C` output, `D;exit` end. Free jump-to-prompt in iTerm2/Warp/WezTerm/Ghostty.
- **OSC 7** (cwd): `ESC]7;file://host/cwd\a` on each prompt.

### Q6 — Fish Syntax Highlighting Algorithm

5 stages in `highlight_shell()`: parse AST → traverse nodes (Command/Argument/VarAssign) → assign HighlightRole per char → HighlightColorResolver maps role → fish_color_* env → Outputter emits ANSI minimally. Validation: `builtin_exists()` + `path_get_path()` checks first token; invalid = red. Path args validated by FileTester on background thread. [https://deepwiki.com/fish-shell/.../5.3-syntax-highlighting]

**Ghost autosuggestions**: `autosuggest_validate_from_history` matches history prefix against current buffer. Falls back to completion. Renders dim/gray after cursor. Right-arrow or Ctrl+F accepts. Fish 4.2+ extended to multi-line.

### Q7 — Zsh Completion Architecture

Two layers: C core (compcore.c, compmatch.c, compresult.c, complete.c) + shell fn framework via compinit. Entry = `_main_complete`. Iterates completers (`_complete`, `_approximate`...). Completers call `compadd` to register matches. Context string `:completion:<func>:<completer>:<cmd>:<arg>:<tag>` drives zstyle lookups. **Minimal version cost**: (a) detect what's being completed (cmd name vs arg N vs option-arg); (b) call right function (_git, _ssh) which calls compadd. zsh-autocomplete plugin proves real-time as-you-type possible. [https://deepwiki.com/zsh-users/zsh/4.1-completion-architecture]

### Q8 — Nushell Structured Pipelines (ideas to steal)

`Value` enum is sum type of pipeline values. `PipelineData` wraps Value/ListStream/ByteStream. Commands declare I/O types in signature → type errors before execution. Three categories sources→filters→sinks. Joey Hess 2019 "typed pipes in every shell": emit MIME header before pipe content. Adds structure without replacing bytes. [https://deepwiki.com/nushell/.../5.2-pipeline-data-flow]

### Q9 — History Sync (Atuin / McFly / hstr)

- **Atuin** (29.4k★): SQLite DB replaces ~/.bash_history. Per-command: exit code, cwd, host, session, duration. Full-screen Ctrl+R, session/dir/global filter. E2E-encrypted sync. Desktop version uses local-first CRDT; CLI uses encrypted server sync.
- **McFly** (7.3k★): Neural net ranks suggestions on cwd, recent usage, exit codes. SQLite backend.
- **hstr** (4.5k★): C, fuzzy history TUI overlay on Ctrl+R. Fast, simpler.

**Key insight**: All three replace flat text with SQLite + metadata. asm-terminal's 32-entry in-memory buffer is most severe practical limitation.

### Q10 — Prompt Frameworks

- **Starship** (51k★ Rust): Each prompt element = "module" (git_branch, directory, cmd_duration...). TOML config. Shell calls `starship prompt` subprocess per render.
- **oh-my-posh** (22.2k★ Go): JSON/TOML/YAML config. Blocks (left/right/newline) + segments. Segment type, colors, Go template.

Both spawned as subprocesses. Pattern for asm-terminal: **segment model** = loop over config-driven function table. 10–20 lines of NASM. Git branch detection **without fork** (read .git/HEAD directly).

### Q11 — Assembly Shells Comparison

| Project | ★ | Lang | Did well | Skipped |
|---|---|---|---|---|
| kittrz9/assembly-shell | 1 | x86-64 NASM | exec, Ctrl+C, cd/exit | history, line editing, jobs |
| isene/bare (2026) | new | x86-64 NASM | **Everything**: raw mode, ANSI edit, tab comp, git, jobs, themes, plugins in 1 file, 126KB | structured pipes, config lang |
| asmutils (leto) | 72 | x86 NASM | 138+ utilities, small libc | Not a shell per se |
| KolibriOS | OS | FASM | Real login shell on real OS | POSIX compat, signals, scripting |

## What asm-terminal Should Steal (Top 8)

1. **Persist history with metadata (Atuin-style)** — SQLite or flat append-only with timestamp + exit code + cwd. Fix 32-entry limit.
2. **Ghost-text autosuggestions** — scan history for longest prefix match per keystroke, render remainder in dim ANSI after cursor. Right-arrow accepts. "Bare" does this in pure NASM.
3. **Extended syntax highlighting** — color pipes/redirectors cyan, quoted strings yellow, $VAR magenta, path args green/red (exists/not). Simple token-scanner loop.
4. **Kitty Keyboard Protocol** — emit `ESC[>1u` on startup; parse CSI u responses. Gives true Tab vs Ctrl+I, Shift+Enter binding, reliable Alt+key.
5. **OSC 133 markers** — 4 escape sequences per command = free jump-to-prompt/re-run/select output in modern terminals.
6. **Segment-based configurable prompt** — ~/.asmrc gains `prompt_segments=pwd git_branch exit_code duration`. Each segment = fn that writes text+color or nothing. Git branch without fork (read .git/HEAD).
7. **History bump to 500+ with context filters** — fish/Atuin approach. cwd + session filter.
8. **Multi-line editing** — detect unclosed quote/trailing backslash → continuation prompt `>` → append. Huge usability gain for complex commands.

**Windows bonus**: Use Job Objects (CreateJobObject + AssignProcessToJobObject) for terminal.asm to group children → reliable Ctrl+C + kill-tree — Win32 equivalent of POSIX process groups.
