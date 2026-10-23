# Packaging

Everything needed to turn `terminal` / `terminal.exe` into a recognizable
installed application on both major desktops.

## Linux

Everything in `packaging/linux/` is glued together by `install.sh`:

- `install.sh`              — zenity GUI installer (falls back to text prompts)
- `uninstall.sh`            — mirrors the above
- `install-release.sh`     : the `curl ... | sh` installer (see below)
- `asm-terminal.desktop`    — application menu entry
- `asm-terminal.svg`        — icon
- `asm-terminal-launch`     — wrapper that opens a terminal emulator running `asm`

See `packaging/linux/README.md` for details.

Two more Linux artifacts live under separate subdirs because they need
extra tooling:

- `packaging/debian/build-deb.sh`    — builds `.deb` via `dpkg-deb`
- `packaging/rpm/build-rpm.sh`       — builds `.rpm` via `rpmbuild` (spec: `asm-terminal.spec`)
- `packaging/linux/install-release.sh` — the `curl ... | sh` installer; published
  as the release asset `install.sh`, with `asm-terminal-linux-desktop.tar.gz`
- `packaging/appimage/build-appimage.sh` — builds an AppImage

From the repo root:

```bash
make install-gui    # run the GUI installer
make install-desktop # non-interactive, honours PREFIX / BINDIR / DESTDIR / ...
make deb            # dist/asm-terminal_<version>_amd64.deb
make rpm            # dist/asm-terminal-<version>-1.x86_64.rpm
make appimage       # asm-terminal-<version>-x86_64.AppImage
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

`.github/workflows/release.yml` runs when `version.inc` changes on `main` (or on a
`v*` tag push, or by hand) and builds:

- Linux tarball and the bare `asm-terminal-linux-x86_64` binary
- Linux `.deb` and `.rpm`
- `install.sh` + `asm-terminal-linux-desktop.tar.gz` for the one-line installer
- Linux AppImage
- Windows `.zip` with `install.bat`
- NSIS `setup.exe`, the Windows `.exe`

The jobs run `tests/run_tests.sh` and fail the run when a test fails or an asset
is missing. The assets plus a `SHA256SUMS` file are attached to the GitHub
Release `vX.Y.Z` only by a run on `main` or a `v*` tag; a manual run from
another branch builds and tests without publishing. The `.AppImage` build
downloads a pinned `appimagetool` and AppImage runtime and checks their
SHA-256 first (see `packaging/appimage/build-appimage.sh` to update the pins).

`SHA256SUMS` is published next to the files it describes, so it catches a
corrupted download but not a tampered release. See
`packaging/windows/SIGNING.md` ("What signing does not cover").
