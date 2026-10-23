# ASM Terminal — Linux packaging

## Install (GUI)

From the repo root, after `make`:

```bash
bash packaging/linux/install.sh
```

- A zenity dialog asks whether to install for the current user (`~/.local`, no sudo) or system-wide (`/usr/local`, pkexec/sudo).
- Falls back to a text prompt if zenity is missing or `ASM_NOGUI=1` is set.
- Afterwards, **ASM Terminal** appears in your application menu and `asm-terminal` is on your `PATH`, and so is `asm` unless another program of that name is already installed (it is never overwritten; the installer says so).

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
| `<prefix>/bin/asm-terminal` | The shell itself (static ELF64) |
| `<prefix>/bin/asm` | Symlink to `asm-terminal`, only when `asm` is free or already ours |
| `<prefix>/bin/asm-terminal-launch` | Wrapper that opens a terminal emulator running `asm` |
| `<prefix>/share/applications/asm-terminal.desktop` | Desktop entry (shows in app menu) |
| `<prefix>/share/icons/hicolor/scalable/apps/asm-terminal.svg` | Icon (vector) |
| `<prefix>/share/icons/hicolor/<N>x<N>/apps/asm-terminal.png` | Icon, 16 to 512 px |

The `.desktop` file is installed with an absolute `Exec=` path, because the desktop session's `PATH` often lacks `~/.local/bin`.

To change the icon, edit `asm-terminal.svg` and run `sh packaging/linux/render-icons.sh` to regenerate the PNGs.

## How the "app" experience works

`asm` itself is a shell, not a terminal emulator. The `.desktop` file's `Exec=` runs `asm-terminal-launch`, which uses the desktop's own terminal (cosmic-term on COSMIC, Ptyxis or gnome-terminal on GNOME, konsole on KDE), then probes for any other (kitty, alacritty, foot, xterm, …), and runs the shell in it. Set `ASM_TERMINAL_EMULATOR` to force one. The net effect: clicking the icon opens a fresh terminal window running the ASM shell, exactly like launching Terminator or Konsole.
