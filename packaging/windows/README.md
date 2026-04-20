# ASM Terminal — Windows packaging

Two installers are provided:

| File | What it does | Requires |
|------|--------------|----------|
| `install.bat`   | Copies `terminal.exe` to `%LOCALAPPDATA%\Programs\ASM-Terminal`, creates a Start Menu shortcut, registers `asm` under *App Paths*, and adds an entry to *Add/Remove Programs*. Unsigned. | Nothing — runs on any Windows 10/11 |
| `installer.nsi` | NSIS script that produces `asm-terminal-2.0.0-windows-x86_64-setup.exe` — a proper GUI installer. | `makensis` (Windows or Linux) |

## Quick install (batch)

1. Download the Windows release zip from the project's Releases page.
2. Unzip.
3. Double-click `install.bat` (or run it from cmd.exe).
4. Launch **ASM Terminal** from the Start Menu, or press **Win+R** and type `asm`.

## Build the NSIS installer

### On Linux

```bash
sudo apt-get install nsis
cd packaging/windows
cp ../../terminal.exe .                 # ensure exe sits next to installer.nsi
makensis installer.nsi
# produces asm-terminal-2.0.0-windows-x86_64-setup.exe
```

### On Windows

```powershell
choco install nsis
cd packaging\windows
copy ..\..\terminal.exe .
"C:\Program Files (x86)\NSIS\makensis.exe" installer.nsi
```

## Uninstall

- Via Settings → Apps → *ASM Terminal*  (NSIS + batch both register here)
- Or run `uninstall.bat` / `uninstall.exe` from the install directory

## What gets installed

| Path | Purpose |
|------|---------|
| `%LOCALAPPDATA%\Programs\ASM-Terminal\terminal.exe` | The shell binary |
| `%LOCALAPPDATA%\Programs\ASM-Terminal\asm-terminal.ico` | Icon |
| Start Menu → *ASM Terminal* | Launcher shortcut |
| Registry `HKCU\...\App Paths\asm.exe` | Win+R support |
| Registry `HKCU\...\Uninstall\ASM-Terminal` | Add/Remove Programs entry |

## Notes on the Windows experience

`terminal.exe` is a Win32 console app. Double-clicking the Start Menu entry opens it in the default console host (Windows Terminal on recent Windows, conhost on older versions). The shortcut points directly at the binary, so it behaves exactly like cmd.exe or PowerShell shortcuts: a new console window containing the ASM shell.

Because the installer is unsigned, Windows SmartScreen may show a warning the first time you run the NSIS setup.exe. Click *More info* → *Run anyway* (or sign the installer with a code-signing certificate).
