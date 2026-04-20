@echo off
setlocal enabledelayedexpansion
rem ===========================================================================
rem ASM Terminal - Windows uninstaller (batch, Win10/11)
rem Flags:  /S  = silent (no prompts)
rem ===========================================================================

set "APP_NAME=ASM Terminal"
set "EXE_NAME=terminal.exe"
set "INSTALL_DIR=%LOCALAPPDATA%\Programs\ASM-Terminal"
set "START_MENU=%APPDATA%\Microsoft\Windows\Start Menu\Programs"
set "SILENT=0"

if /I "%~1"=="/S" set "SILENT=1"

if "%SILENT%"=="0" (
    echo.
    echo === Uninstalling %APP_NAME% ===
    echo.
)

rem --- Shortcut ---
if exist "%START_MENU%\%APP_NAME%.lnk" del /F /Q "%START_MENU%\%APP_NAME%.lnk"

rem --- Registry ---
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe"      /f >nul 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" /f >nul 2>nul

rem --- Files ---
if exist "%INSTALL_DIR%\%EXE_NAME%"       del /F /Q "%INSTALL_DIR%\%EXE_NAME%"       2>nul
if exist "%INSTALL_DIR%\asm-terminal.ico" del /F /Q "%INSTALL_DIR%\asm-terminal.ico" 2>nul
if exist "%INSTALL_DIR%\README.md"        del /F /Q "%INSTALL_DIR%\README.md"        2>nul
if exist "%INSTALL_DIR%\INSTALL.md"       del /F /Q "%INSTALL_DIR%\INSTALL.md"       2>nul

rem --- Can't delete running .bat; schedule self-delete after we exit ---
set "SELF_DELETE=%TEMP%\asm-terminal-cleanup-%RANDOM%.cmd"
> "%SELF_DELETE%" echo @echo off
>>"%SELF_DELETE%" echo ping 127.0.0.1 -n 2 ^>nul
>>"%SELF_DELETE%" echo del /F /Q "%INSTALL_DIR%\uninstall.bat" 2^>nul
>>"%SELF_DELETE%" echo rmdir /Q   "%INSTALL_DIR%"              2^>nul
>>"%SELF_DELETE%" echo del /F /Q  "%%~f0"                      2^>nul
start "" /B cmd /C "%SELF_DELETE%"

if "%SILENT%"=="0" (
    echo Done. Install directory cleaned up shortly.
    pause
)
exit /b 0
