# Packaging

Everything needed to turn `terminal` / `terminal.exe` into a recognizable
installed application on both major desktops.

## Linux

Everything in `packaging/linux/` is glued together by `install.sh`:

- `install.sh`              — zenity GUI installer (falls back to text prompts)
- `uninstall.sh`            — mirrors the above
- `asm-terminal.desktop`    — application menu entry
- `asm-terminal.svg`        — icon
- `asm-terminal-launch`     — wrapper that opens a terminal emulator running `asm`

See `packaging/linux/README.md` for details.

Two more Linux artifacts live under separate subdirs because they need
extra tooling:

- `packaging/debian/build-deb.sh`    — builds `.deb` via `dpkg-deb`
- `packaging/appimage/build-appimage.sh` — builds an AppImage

From the repo root:

```bash
make install-gui    # run the GUI installer
make install-desktop # non-interactive, honours PREFIX / BINDIR / ...
make deb            # dist/asm-terminal_2.0.0_amd64.deb
make appimage       # asm-terminal-2.0.0-x86_64.AppImage
```

## Windows

Everything in `packaging/windows/`:

- `install.bat` / `uninstall.bat` — batch installer that creates Start Menu
  shortcut, `App Paths` entry (Win+R `asm`), and Add/Remove Programs entry.
  Works on a blank Windows 10/11 install without dependencies.
- `installer.nsi` — NSIS script for a proper `setup.exe`. Build with
  `makensis installer.nsi` (NSIS available on Linux via `apt install nsis`).

See `packaging/windows/README.md` for details.

## CI build matrix

`.github/workflows/release.yml` runs on tag push and builds:

- Linux tarball
- Linux `.deb`
- Linux AppImage
- Windows `.zip` with `install.bat`
- NSIS `setup.exe` (if the NSIS toolchain is available)

All assets get attached to the GitHub Release corresponding to the tag.
