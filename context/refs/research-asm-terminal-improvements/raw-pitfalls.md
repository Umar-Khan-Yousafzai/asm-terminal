## Agent: pitfalls-deprecated-anti-patterns

### Q1 Termios / SIGWINCH races

- SIGWINCH between select() return and read() → stale dimensions. Fix: pselect() with atomic mask swap, or self-pipe trick. [sitepoint.com/self-pipe-trick-explained]
- signalfd: requires system-wide mask; child processes inherit masked signals unless explicitly reset before execve. [ldpreload.com/signalfd-is-useless]
- **Real fish bug (2025) #12496**: write() EINTR from SIGWINCH permanently set errored flag. Fix: retry on any EINTR; detect cancellation separately.
- Signal coalescing: two SIGWINCHes deliver as one. Always re-query TIOCGWINSZ.
- **fish 4.6 (2025)**: SIGWINCH no longer interrupts builtin output.

Canonical pattern for asm-terminal: block SIGWINCH at start; unblock only during pselect(); OR self-pipe signal→byte→main loop reads via poll(); always unblock before execve().

### Q2 UTF-8 partial reads

- read() returns mid-codepoint → naive wcwidth on continuation byte (0x80-0xBF) gives garbage. Fix: carry buffer; hold incomplete lead byte until next read.
- **bash 5.3-beta fix (2025)**: read builtin skipped delimiter inside invalid multibyte.
- **fish 4.2 change**: assumes UTF-8 always; invalid bytes round-trip but may render differently.
- `read(fd, buf, 1)` correct but must assemble before wcwidth.

### Q3 Bash/Fish changelog anti-patterns 2023-2026

- **fish CVE-2023-49284 (Dec 2023)**: PUA non-characters used as internal sentinels leaked from command substitution → attacker's `\uFDD2HOME` expanded $HOME. Fix 3.6.2: sanitize cmd-subst output before re-parse. **Lesson: internal sentinels must be scrubbed from external input at entry gate.**
- **fish 4.0 (Feb 2025)**: `qmark-noglob` on by default; many users' `?` silently became glob. Lesson: glob enable should be opt-in.
- **bash 5.3-beta (2025)**: redirections underwent word expansion twice (double-substitution). Lesson: each expansion stage = distinct pass, no re-entry.
- **bash 5.3-beta**: off-by-one in printf time; size_t integer overflow fixes. Size arithmetic = most persistent bug class.
- **fish 4.1.0**: `set_color --background=COLOR` silently activated bold. Fixed 4.2. Lesson: always reset color state to known at prompt redraw.
- **fish 4.3.0**: crash on bad color variable. Defensive color parsing required.

### Q4 Cursor-position miscount

- ANSI escapes counted as printable → cursor misalign. Wrap in `\001\002` or strip before width calc.
- **fish #10461**: cloud emoji ☁️ (U+2601 + U+FE0F) — variation selector makes narrow char render wide (2 cols) but wcwidth returns 1.
- **fish 4.6**: default emoji width switched 1→2. Was wrong for years.
- **ZSH CVE-2021-45444**: PROMPT_SUBST + VCS_Info (git branch) → crafted branch name `$(evil)` → RCE. **Lesson: external data in prompt must be quoted, not re-expanded.**
- OSC/DCS in prompts: zero-width IF terminal processes; else raw bytes shift cursor. Bracket with `\001\002` or use tput queries.
- Multi-codepoint grapheme clusters (family emoji = 7 cp, 2 cols). wcwidth is per-codepoint, not per-grapheme. Only correct solution = UAX #29 segmentation.
- bash 5.3-beta readline fix: multiple invisible-char sequences + prompt > screen width broke redisplay.

### Q5 Shellshock + env-function-import

- **CVE-2014-6271 Shellshock**: bash imported env-var function defs, failed to stop at `}`, executed trailing code. Lesson: never auto-evaluate env content as code.
- **CVE-2023-49284 fish**: same lesson via PUA chars.
- **CVE-2025-61984 (bash/fish/csh, Oct 2025)**: SSH ProxyCommand expanded `%r` (remote username). Newlines in usernames injected commands. Bash/fish/csh continued after arithmetic error on line 1; zsh exited → safe. **Lesson: arithmetic errors should abort current command, not fall through. Strip control chars (incl newlines) from external inputs.**

### Q6 PATH confusion / .profile TOCTOU

- **CVE-2024-27822 (macOS/zsh, Jun 2024)**: PackageKit ran PKG scripts with user's .zshenv loaded, root privs. Poisoned ~/.zshenv → root RCE. **Lesson: never source user config when privileged.**
- **CVE-2021-45444 zsh**: TOCTOU on git branch name in VCS_Info prompt; attacker-controlled repo name injected commands.

Defensive: strip ctrl chars from all external data before display/interpolation; never implicitly search `.` in PATH; skip user config on privileged startup; use execve() with explicit envp[].

### Q7 Glob DoS

- zsh `**` + deep tree → millions of results, minutes. Defense: `setopt GLOB_LIMIT` caps results. Bash has NO equivalent.
- `*/../*/../*` — filesystem glob not regex backtracking, but result set can be exponential. Defense: explicit result count cap + wall-clock timeout.

Recommendation: asm-terminal glob implementation should cap results (10,000) before sort/dedup; warn on truncation.

### Q8 Terminal injection via filenames

- Filenames with `\x1b[2J`, OSC8 hyperlink `\x1b]8;;evil.com\x1b\\`, `\x1b[?25l`, repeat seqs → weaponized when ls prints raw.
- OSC8 dangerous: improperly terminated → all following becomes clickable malicious link.
- OSC5113 (Kitty file transfer), OSC52 (clipboard write) → data exfil via crafted filenames viewed with cat/ls.
- GNU ls `--quoting-style=shell-escape|c` quotes non-printable. Default when stdout is TTY + --color=auto.
- **Defense: before printing any filename, replace bytes <0x20, 0x7F, 0x80-0x9F with `?` or `\xNN`.**

### Q9 Deprecated termios ioctls

- `TCGETA/TCSETA` use old SVR4 `struct termio`. Linux compat only. Don't use in new code.
- `TCGETS2/TCSETS2` (Linux 2.6.20+, `<asm/termbits.h>`): incompatible `struct termios2` with custom baud rates. Mixing with standard `<termios.h>` struct reads garbage.
- **For raw ioctl in asm-terminal: use TCGETS=0x5401, TCSETS=0x5402 for standard termios, TIOCGWINSZ=0x5413.**
- POSIX TCSAFLUSH = Linux TCSETSF (flush pending input). TCSETS = TCSANOW (immediate). Wrong choice = keystroke-during-mode-switch race.

### Q10 SIGIO abandoned

- Edge-triggered: fires on state change, not per-byte. Partial-read → no new SIGIO until fresh data. Very tricky.
- Cannot be used with regular files, only terminals/sockets. Immediately limits use in shells mixing terminal + script file.
- Multi-threaded: non-deterministic delivery. fork inherits signal mask.
- **Modern: use poll()/epoll() on terminal fd. epoll_pwait2() not interrupted by signals. For asm-terminal (single-threaded): plain poll() on stdin + SIGWINCH self-pipe.**

### Q11 Hardcoded vs overridable keybindings

- zsh ZLE ignores ~/.inputrc. Users surprised.
- fzf hardcodes, ignores ~/.inputrc. Documented regret.
- fish 4.0 gained new `bind` key notation. Rare bindings silently broke. Lesson: version keybind notation changes; deprecation warnings not silent failure.

### Q12 Blocking read vs poll

- Blocking read on terminal fd blocks forever on SSH disconnect / tmux pane close. Some terminals send EIO instead of EOF. **Handle EIO as graceful exit.**
- After select/poll readable, read can still block if another thread consumed data.
- Pure blocking read with SA_RESTART: signal handler doesn't interrupt, SIGWINCH never processed until next keystroke. **Self-pipe/pselect exists for this reason.**

### Q13 Startup budget 2025

- Target: <50ms first-prompt latency ("indistinguishable from zero"). zsh4humans ~25ms. Stock oh-my-zsh 500-2000ms.
- Biggest culprit: version managers (`nvm init`, `rbenv init`) add 100-500ms each.
- **For asm-terminal: fast parse of ~/.asmrc; never fork to eval config.**
- **fish 4.6**: macOS startup delay from slow terminal responses (DA1/DA2 queries). Lesson: queries requiring terminal responses need timeout fallback.

### Q14 Fork-per-prompt for git

- `gitstatus` daemon (romkatv): persistent bg daemon, pipes. ~31ms vs ~295ms for `git status`. ~10x.
- **Cheap alt: `readlinkat(dirfd, ".git/HEAD", buf)` — ~10µs vs ~50ms for `git branch --show-current`.** Returns `ref: refs/heads/NAME\n` or bare SHA.
- inotify watch on .git/HEAD: cache branch, invalidate on change. Doesn't track dirty.

### Q15 Redraw per keystroke

- Traditional readline: emit `\033[J\033[2K\r` then full redraw. Flicker on SSH/long input.
- **Fix: diff-based rendering (virtual screen buffer, compare old/new cell-by-cell).** Claude Code reduced flicker ~85%.
- **DECSET 2026 (Synchronized Output)**: `\x1b[?2026h` ... `\x1b[?2026l` — atomic redraw on tmux 3.4+, Windows Terminal, iTerm2, Alacritty, kitty, foot. Use with graceful fallback.
- Readline: unconditional `\033[J\033[2K\r` even for printable chars. Redundant — just append + advance cursor for normal input. Reserve full redraw for backspace/movement/paste.

### Q16 Unbounded history scan

- In-memory linear 32 entries: free. 1K-10K: sub-ms. User-noticeable ~50K+ with regex.
- Atuin: unindexed SQLite scan was faster than indexed (dedup overhead).
- Third-party history plugins: 120-180ms per Ctrl-R at moderate sizes. Native in-memory <5ms up to 100K.
- **Switch to indexed (suffix array, trigram, SQLite FTS5) only above ~100K entries.**

### Q17 Forced interactivity when piped

- **Gate list**: (1) isatty(STDIN) → suppress prompt if piped input; (2) isatty(STDOUT) → no ANSI color if piped; (3) isatty(STDERR) → no progress bars; (4) NO_COLOR env regardless.
- asm-terminal already does some TTY detect, but syntax highlighting always emits → bug when piped.
- **Emacs/tramp**: sets TERM=dumb. starship gates on it. **asm-terminal should check TERM=="dumb" as additional suppression trigger.**

### Q18 ls color to pipes

- GNU ls `--color=auto` isatty-checks stdout. Bug is unconditional emission in builtin ls.
- **asm-terminal ls must isatty(STDOUT_FILENO) and suppress `\e[...m` when false.**

### Q19 TERM=dumb fallback

- Minimum: no ANSI seqs; switch to cooked mode or basic editing; no color; plain PS1; no bracketed paste; no OSC; no DECSCUSR. Shell must still function (pipes, redirections, builtins, history).
- **fish 4.5**: stopped reading terminfo db; queries terminals directly. Must check TERM=dumb explicitly before any query.

### Q20 SIGPIPE when piped

- head -n 5 reads 5, closes stdin → upstream gets SIGPIPE / EPIPE.
- **Shell must NOT treat child SIGPIPE as fatal. Set SIGPIPE=SIG_DFL in child before execve. Handle EPIPE in shell's own output by exiting current command, not shell.**
- Shell's own write can SIGPIPE if stdout is broken pipe. Catch, exit cleanly with status 141 (128+13 convention).

### Q21 tmux/screen title

- 3 competing sequences: `\e]0;T\a` (icon+title, xterm default), `\e]2;T\a` (title only), `\ek T\e\\` (screen/tmux hard status).
- tmux intercepts `\e]0;` and `\e]2;` → window name.
- **`\ek\e\\` without checking $TERM for `screen`/`tmux` → garbage in other terminals.**
- OSC 133 required for tmux 3.6+ forwarding. Without, "jump to prev prompt" broken.
- OSC 7 (`\e]7;file://host/path\a`) → open-new-tab-same-dir. Emit on every cd.

### Q22 Cursor shape not restored

- DECSCUSR: `\e[0 q` or `\e[2 q` block, `\e[4 q` underline, `\e[6 q` bar. `\e[0 q` should reset default but xterm.js (VSCode) treats 0 as 1 (blink block).
- **Most portable reset: `\e[ q` (no param) or `\e[0 q`.**
- Universally-regretted bug (helix, neovim, yazi). Fix: signal handler on SIGTERM/SIGINT/SIGHUP emits reset before _exit(); reset in normal exit too; query DECSCUSR via `\e[?12$p` not universal.

### Q23 8-bit clean pipelines

- POSIX pipes 8-bit clean, all 256 byte values must pass unchanged.
- **Danger in asm-terminal: if any path adds null terminator mid-string (C-string discipline), binary data silently truncated. Track explicit lengths, not null-term as sentinel.**
- `0x00` NUL most often breaks. `0x11` (XON) and `0x13` (XOFF) consumed by termios when IXON set. Raw mode must clear IXON or these bytes vanish.

### Q24 Bracketed paste

- Without: pasting `echo hello\n` immediately executes (newline=Enter). Security + UX disaster.
- Enable: `\e[?2004h` at startup. Disable: `\e[?2004l` at exit.
- Paste wrapped in `\e[200~` ... `\e[201~`. Parse markers, either: (a) buffer whole paste as single edit op, or (b) strip newlines to prevent exec.
- bash 5.3 readline fix: null-terminate paste buffer on read error.
- **fish 4.0**: removed complex `paste` bind mode. Now just strips newlines. Lesson: simplest = replace embedded newlines with spaces.

### Q25 Alias expansion order

- bash: alias expansion BEFORE all other expansions.
- `alias foo="cmd $VAR"` (double-quoted) expands $VAR at DEFINITION time. `alias foo='cmd $VAR'` (single) at USE time. Classic gotcha.
- Trailing space: `alias sudo='sudo '` → next token also alias-checked. Non-POSIX. fish doesn't do this.
- **fish solution: no aliases, functions only. Eliminates class of alias-order bugs.**
- **If asm-terminal keeps aliases: treat as function call — substitute, then RE-PARSE from start of expansion pipeline.**

### Q26 Startup file precedence

- bash: login → /etc/profile + first of ~/.bash_profile, ~/.bash_login, ~/.profile (stops at first). Non-login interactive → only ~/.bashrc. Non-interactive → $BASH_ENV only.
- Trap: if ~/.bash_profile AND ~/.profile exist, bash reads ONLY .bash_profile. Users who put config in .profile expecting always-run get surprised.
- **CVE-2024-27822 pattern**: ~/.zshenv loaded for EVERY zsh invocation — including non-interactive privileged. Most dangerous startup file.
- **asm-terminal ~/.asmrc should only load when isatty(STDIN) is true.**

### Q27 Canonical POSIX expansion order

1. Brace `{a,b}`
2. Tilde `~`
3. Parameter `$VAR`
4. Command sub `$(cmd)`
5. Arithmetic `$((...))`
6. Word splitting (on $IFS)
7. Pathname (glob)
8. Quote removal

Breakage when reordered:
- Tilde BEFORE parameter: `~/$VAR` works. Reverse → `$HOME` not expanded where `~` would be.
- Word split BEFORE glob: `*` in quoted var doesn't glob (correct). Reverse → double-quoted "$VAR" globs.
- Brace MUST be first: `{$A,$B}` — `$` literal at brace time. Else brace doesn't expand.
- **Double evaluation** (cmd-sub output re-enters parameter expansion): Shellshock/CVE-2023-49284 class.

### Q28 Implementation-order dependency graph

Core insight: each feature processing strings must be robust to inputs from all later features.

```
[raw syscall wrappers: read, write, open, close]
        |
        v
[buffer management: history ring, line buffer]
        |
        v
[UTF-8 validation + carry buffer at input]
        |
        +-----> [width calc / wcwidth analog]
        |               |
        v               v
[quote parser]     [line redraw + cursor column]
        |               |
        v               v
[redirection + pipe setup]    [SIGWINCH + TIOCGWINSZ]
        |
        v
[$VAR expansion]
        |
        v
[tilde expansion (depends on $HOME)]
        |
        v
[brace + glob (with count cap)]
        |
        v
[alias expansion (pre-pass, re-enters parser)]
        |
        v
[execve + job control]
        |
        +-----> [tab completion (needs quoting + glob)]
        |
        v
[Ctrl-R history search]
        |
        v
[bracketed paste (after redraw stable)]
        |
        v
[OSC 133 / OSC 7 / window title]
        |
        v
[vi mode / Alt+B,F / kill-ring (layered on complete editor)]
        |
        v
[DECSET 2026 synchronized output (cosmetic, last)]
```

Key rules:
- No word-movement (Alt+B/F) before UTF-8 grapheme handling → wrong offsets.
- No tab completion before quoting → completes incorrectly in quoted strings.
- No bracketed paste before redraw stable → floods redraw, masks flicker bugs.
- No glob before quoting → `"*"` must not glob.
- SIGWINCH handler before vi mode (uses dimensions for scroll).
