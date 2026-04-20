## Agent: best-practices-existing-art

### Q1 POSIX Exit / pipefail / exec / trap / set -e

- `pipefail` **standardized in POSIX.1-2024** (not before). [blog.toast.cafe/posix2024-xcu]
- `set -e` does NOT exit in: while/until test, if-test, `&&`/`||` list (except final), any pipeline cmd except last (unless pipefail), `!`-inverted. Often misunderstood.
- `pipefail` runs all commands to completion; exit status = rightmost failing.
- `exec` replaces process image. POSIX.1-2024: SIG_IGN preserved, signal mask inherited, other threads terminated.
- `trap ERR/EXIT`: subshell inherits? Spec mandates reset to defaults. Bash `set -E` lets ERR leak into functions/command-subst (bash extension).
- POSIX.1-2024 also added: `find -print0`, `xargs -0`, `read -d ''`.
- Formal POPL 2020 "Smoosh" paper (Greenberg). [mgree.github.io/papers/popl2020_smoosh.pdf]

### Q2 Readline Canonical Shortcuts

**Emacs mode:**
- Movement: Ctrl-A/E/F/B, Alt-F/B (word), Ctrl-L
- History: Ctrl-P/N, Alt-</>, Ctrl-R/S (inc search), Alt-P/N (non-inc), Alt-./_ (last arg prev), Ctrl-Alt-Y (first arg prev)
- Editing: Ctrl-D, Ctrl-T (transpose ch), Alt-T (transpose words), Alt-U/L/C (case), Ctrl-K (kill EOL), Ctrl-U (kill to start), Alt-D (kill fwd word), Alt-Del/Ctrl-W (kill back word), Alt-\, Ctrl-Y yank, Alt-Y rotate kill
- Completion: Tab, Alt-?, Alt-*, Ctrl-X {~,/,$,@,!}
- Misc: Ctrl-X (/), macro; Ctrl-_ undo; Alt-R revert; Ctrl-V/Q quoted insert; Ctrl-G abort; Alt-Space set mark; Ctrl-X Ctrl-X exchange pt/mark; Ctrl-] char search fwd; Alt-# comment out

**Vi mode:** Insert-mode default, ESC → command. hjkl, wbWB/eE, 0/$, iIaA, xX, dw/db/dd, cw/cb/cc, yy/p/P, u, r<c>, f<c>/F<c>, v (edit $EDITOR), #.

### Q3 Prompt Features Table Stakes 2025

- Cwd (short, ~-subst), git branch + dirty/ahead/behind, exit code, cmd duration (>2s threshold), virtualenv/conda, SSH remote hostname, background job count, `$` vs `#`.
- Starship: 80+ modules (AWS/GCP/Azure/K8s/Docker + 40 runtimes).
- **Right prompt** (fish_right_prompt / zsh RPROMPT) standard for secondary info.
- **OSC 7** (`\e]7;file://host/cwd\a`): new-tab-same-dir + breadcrumbs in iTerm2/Warp/WezTerm/Ghostty/kitty.
- **OSC 133**: `\e]133;{A|B|C|D;exit}\a` → jump between prompts, click-select output.

### Q4 Signals

- SIGINT: shell catches, doesn't exit. fg child gets SIGINT from terminal driver directly. After child dies from signal, shell re-raises SIGINT on itself.
- SIGTERM: interactive bash ignores. Non-interactive does NOT.
- SIGHUP: shell sends SIGHUP to all jobs (stopped → SIGCONT+SIGHUP). `disown` prevents.
- SIGTSTP: with job control on, shell ignores SIGTSTP/SIGTTIN/SIGTTOU. Sent to fg process group. Shell tcsetpgrp to hand off, reclaims on suspend.
- **SIGWINCH**: catch it, re-query `ioctl(fd, TIOCGWINSZ, &ws)`, update COLUMNS/LINES, redraw. Set flag in handler, do work in main loop.
- **Termios raw**: clear ICANON+ECHO, VMIN=1, VTIME=0. Save/restore on exit + abnormal exit.
- **Job control sequence**: setpgid(pid,pid) per child → tcsetpgrp(STDIN, child_pgid). On return, tcsetpgrp back to shell_pgid. tcgetattr save/restore per job.

### Q5 POSIX Filename Safety

- Only NUL and `/` forbidden. Newlines, tabs, ctrl, spaces, leading `-` are permitted.
- Rules: always `"$var"`, use `./*` glob to avoid leading-dash, NUL-delimited pipelines (`find -print0 | xargs -0`), `IFS=$'\n\t'` not space, never rely only on `--`.
- POSIX.1-2024: 70+ utilities now encouraged to error on newline-in-filename creation.
- Display safety: strip ctrl chars before display to prevent terminal injection.

### Q6 Accessibility

- **NO_COLOR** (no-color.org, 200+ tools): present + non-empty → no ANSI color. Bold/underline/italic NOT covered. User config and CLI flags override.
- **Priority chain**: NO_COLOR → CLICOLOR_FORCE → CLICOLOR (0=off) → isatty → default.
- **COLORTERM=truecolor|24bit** → 24-bit RGB. Else `$TERM` ends with `256color` → 256. Else 8/16. VTE/Konsole/iTerm2 all set COLORTERM=truecolor.
- **FORCE_COLOR** (Node.js/Chalk origin, separate from CLICOLOR_FORCE).
- **Screen readers**: TUIs are inaccessible. Never color-only signal; always add text/symbols. Support `--no-color`.

### Q7 PS1 Escape Sequences

- `\u \h \H \w \W \$ \t \T \@ \A \d \j \l \n \r \s \v \V \! \# \\ \[ \]`.
- **Critical**: `\[` / `\]` (or raw `\001`/`\002`) must wrap ANSI escapes or readline miscounts line width → broken wrapping.
- `tput setaf N` more portable than hardcoded codes.
- PS2 (cont), PS3 (select), PS4 (xtrace, `+${BASH_SOURCE}:${LINENO}:` useful).

### Q8 Tab Completion Best Practices

- 1st Tab = common prefix; 2nd Tab = list/pager. Shift-Tab = cycle backward.
- Case-insensitive preferred (`set completion-ignore-case on`). Fish default case-insens.
- Fuzzy (fzf-tab, Nushell `completion_algorithm="fuzzy"`) increasingly expected but not universal.
- Completion **descriptions** (zsh/fish) differentiate.
- Fish pager: Tab opens, arrow nav, Ctrl-S filter, Shift-Tab search. Most ergonomic.

### Q9 Large History

- **Atuin**: SQLite DB (~/.local/share/atuin/history.db). Per-cmd: text, cwd, exit, duration, host, session, ts. Configurable search (full-text/fuzzy), filter by host/dir, stats.
- **Atuin sync v18.2+**: symmetric encryption, key local-only, all data encrypted before upload. Self-hostable server.
- Perf caveat: SQLite index on history table required for 100k+ entries.
- **Fish**: plain text `~/.local/share/fish/fish_history` YAML-like, token search. Not optimized for huge scale.

### Q10 Fish UX Innovations

- **Autosuggestions** (Fish 4.2 extended to multi-line). Right-arrow or Ctrl-F accept.
- **Abbreviations** (`abbr -a gco git checkout`): **expands live on Space/Enter**, full stored in history. Alias stores short; abbr stores long.
- **Right prompt** (`fish_right_prompt`).
- **Universal vars** (`set -U`): persist across sessions instantly, ~/.config/fish/fish_variables.
- **Web config** (`fish_config`): browser UI, no plugins.
- **Syntax highlighting** as-you-type with `fish_color_*` overrides.
- **OSC 7 on every prompt** in Fish 4.x.

### Q11 Zsh Ecosystem

- **oh-my-zsh**: 300+ plugins, 140+ themes. Slow startup.
- **Prezto**: faster, fewer batteries included, modules opt-in.
- **zsh4humans**: turnkey. Instant prompt (P10k), **SSH teleportation** (packages env into self-extracting script, installs zsh on remote without sudo). Sub-50ms startup via lazy loading.
- **Powerlevel10k instant prompt**: renders prompt before plugins load by caching previous state.
- **zsh-bench** (romkatv): first-prompt/first-cmd lag measurement.

### Q12 Starship Architecture

- 1–10ms typical render. 50–200ms for oh-my-zsh themes.
- Single Rust binary. Modules run in parallel (Rust async). No subshell forks. Cached results. TOML config shared across shells.
- Integrations: bash/zsh/fish/PowerShell/Cmd/Nushell/Xonsh/Ion/Elvish. Snippet calls `starship prompt`.
- 80+ modules. Context-sensitive (show only when relevant).

### Q13 Atuin

- SQLite local. E2E encrypted sync (v2 protocol in 18.2). Optional — full offline use works. Self-hostable. bash/zsh/fish/nushell.

### Q14 Nushell

- Typed pipelines via `PipelineData`. Three categories (producers/filters/consumers).
- Plugins: JSON-RPC over stdin/stdout, process-isolated.
- `$env.PATH` is a **list** not a colon-string. Multi-dot paths.
- Not POSIX compatible by design.

### Q15 Architecture Papers / Wikis

- "Executable Formal Semantics for POSIX Shell" (Greenberg, POPL 2020)
- fish-shell GitHub Wiki
- Nushell DeepWiki
- zsh-bench (methodology + measurements)
- yash-rs issue #422 (POSIX.1-2024 impl tracker)
- dwheeler.com "Filenames in Shell" (canonical)

## Table-Stakes Gap List

1. **OSC 133 semantic prompt markers** — without, invisible to Ghostty/WezTerm/iTerm2/Warp integrations.
2. **OSC 7 CWD emission per prompt** — without, new-tab-same-dir breaks.
3. **NO_COLOR / CLICOLOR / COLORTERM chain** — asm-terminal has no logic; always emits ANSI. Breaks piped output + accessibility.
4. **SIGWINCH handler with TIOCGWINSZ + redraw** — without, resize scrambles input line.
5. **pipefail (POSIX.1-2024)** + correct `set -e` semantics.
6. **Vi mode** for line editing (covers significant power-user cohort).
7. **Abbreviations / live-expanding aliases** — strictly better than traditional aliases (history correctness).
8. **Filename safety**: strip ctrl chars, `./` prefix globs, NUL-delimited filename passing.
9. **Right prompt** for exit code / time / git.
10. **trap EXIT/ERR** with correct subshell reset per POSIX.
