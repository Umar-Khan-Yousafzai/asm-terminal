# ASM Terminal — Linux packaging

## Install (GUI)

From the repo root, after `make`:

```bash
bash packaging/linux/install.sh
```

- A zenity dialog asks whether to install for the current user (`~/.local`, no sudo) or system-wide (`/usr/local`, pkexec/sudo).
- Falls back to a text prompt if zenity is missing or `ASM_NOGUI=1` is set.
- Afterwards, **ASM Terminal** appears in your application menu and `asm` is on your `PATH`.

### Headless / scripted install

```bash
ASM_NOGUI=1 ASM_SCOPE=user   PREFIX=$HOME/.local bash packaging/linux/install.sh
ASM_NOGUI=1 ASM_SCOPE=system PREFIX=/usr/local    sudo bash packaging/linux/install.sh
```

## Uninstall

```bash
bash packaging/linux/uninstall.sh
```

## What gets installed

| Path | Purpose |
|------|---------|
| `<prefix>/bin/asm` | The shell itself (~73 KB, static ELF64) |
| `<prefix>/bin/asm-terminal-launch` | Wrapper that opens a terminal emulator running `asm` |
| `<prefix>/share/applications/asm-terminal.desktop` | Desktop entry (shows in app menu) |
| `<prefix>/share/icons/hicolor/scalable/apps/asm-terminal.svg` | Icon |

## How the "app" experience works

`asm` itself is a shell, not a terminal emulator. The `.desktop` file's `Exec=` runs `asm-terminal-launch`, which probes for an installed terminal emulator (gnome-terminal, konsole, kitty, alacritty, foot, xterm, …) and launches it with `asm` as the command. The net effect: clicking the icon opens a fresh terminal window running the ASM shell, exactly like launching Terminator or Konsole.
