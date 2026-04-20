@echo off
setlocal enabledelayedexpansion
rem ===========================================================================
rem ASM Terminal - Windows installer (batch, Win10/11)
rem
rem Installs terminal.exe to %LOCALAPPDATA%\Programs\ASM-Terminal and creates:
rem   - Start Menu shortcut ("ASM Terminal")
rem   - Win+R "asm" via App Paths registration
rem   - Add/Remove Programs entry
rem
rem Runs without admin (writes only to HKCU and %LOCALAPPDATA%).
rem ===========================================================================

set "APP_NAME=ASM Terminal"
set "APP_VERSION=2.0.0"
set "APP_PUBLISHER=Umar Khan Yousafzai"
set "APP_URL=https://github.com/Umar-Khan-Yousafzai/asm-terminal"
set "EXE_NAME=terminal.exe"
set "INSTALL_DIR=%LOCALAPPDATA%\Programs\ASM-Terminal"
set "START_MENU=%APPDATA%\Microsoft\Windows\Start Menu\Programs"
set "SRC_DIR=%~dp0"
if "%SRC_DIR:~-1%"=="\" set "SRC_DIR=%SRC_DIR:~0,-1%"

echo.
echo === Installing %APP_NAME% %APP_VERSION% ===
echo Target: "%INSTALL_DIR%"
echo.

if not exist "%SRC_DIR%\%EXE_NAME%" (
    echo [ERROR] %EXE_NAME% not found next to install.bat.
    echo Expected: "%SRC_DIR%\%EXE_NAME%"
    pause
    exit /b 1
)

rem --- Create install + Start Menu dirs (Start Menu sometimes missing) ---
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%" 2>nul
if not exist "%START_MENU%"  mkdir "%START_MENU%"  2>nul
if not exist "%INSTALL_DIR%" (
    echo [ERROR] Could not create install directory.
    pause
    exit /b 1
)

rem --- Copy payload ---
copy /Y "%SRC_DIR%\%EXE_NAME%"                "%INSTALL_DIR%\%EXE_NAME%"                >nul || goto :copy_fail
if exist "%SRC_DIR%\asm-terminal.ico" copy /Y "%SRC_DIR%\asm-terminal.ico" "%INSTALL_DIR%\asm-terminal.ico" >nul
if exist "%SRC_DIR%\uninstall.bat"    copy /Y "%SRC_DIR%\uninstall.bat"    "%INSTALL_DIR%\uninstall.bat"    >nul
if exist "%SRC_DIR%\README.md"        copy /Y "%SRC_DIR%\README.md"        "%INSTALL_DIR%\README.md"        >nul
if exist "%SRC_DIR%\INSTALL.md"       copy /Y "%SRC_DIR%\INSTALL.md"       "%INSTALL_DIR%\INSTALL.md"       >nul

rem --- Create Start Menu shortcut via a temp .ps1 (avoids nested-quote hell) ---
set "PS1_FILE=%TEMP%\asm-terminal-shortcut-%RANDOM%.ps1"
> "%PS1_FILE%" echo $ErrorActionPreference = 'Stop'
>>"%PS1_FILE%" echo $wsh = New-Object -ComObject WScript.Shell
>>"%PS1_FILE%" echo $lnkPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ASM Terminal.lnk'
>>"%PS1_FILE%" echo $s = $wsh.CreateShortcut($lnkPath)
>>"%PS1_FILE%" echo $s.TargetPath = Join-Path $env:LOCALAPPDATA 'Programs\ASM-Terminal\terminal.exe'
>>"%PS1_FILE%" echo $s.WorkingDirectory = Join-Path $env:LOCALAPPDATA 'Programs\ASM-Terminal'
>>"%PS1_FILE%" echo $ico = Join-Path $env:LOCALAPPDATA 'Programs\ASM-Terminal\asm-terminal.ico'
>>"%PS1_FILE%" echo if (Test-Path $ico) { $s.IconLocation = $ico }
>>"%PS1_FILE%" echo $s.Description = 'ASM Terminal - x86-64 assembly shell'
>>"%PS1_FILE%" echo $s.WindowStyle = 1
>>"%PS1_FILE%" echo $s.Save()

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_FILE%"
if errorlevel 1 (
    echo [WARN] Shortcut creation failed. Continuing anyway.
) else (
    echo [ok] Start Menu shortcut created.
)
del /F /Q "%PS1_FILE%" >nul 2>nul

rem --- Register App Paths so Win+R / 'asm' works from any cmd ---
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe" /ve /t REG_SZ /d "%INSTALL_DIR%\%EXE_NAME%" /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe" /v "Path" /t REG_SZ /d "%INSTALL_DIR%" /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe" /v "UseUrl" /t REG_DWORD /d 0 /f >nul
echo [ok] App Paths registered (Win+R: asm)

rem --- Add/Remove Programs entry ---
set "UNINST_KEY=HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal"
reg add "%UNINST_KEY%" /v "DisplayName"          /t REG_SZ    /d "%APP_NAME%"                              /f >nul
reg add "%UNINST_KEY%" /v "DisplayVersion"       /t REG_SZ    /d "%APP_VERSION%"                           /f >nul
reg add "%UNINST_KEY%" /v "Publisher"            /t REG_SZ    /d "%APP_PUBLISHER%"                         /f >nul
reg add "%UNINST_KEY%" /v "URLInfoAbout"         /t REG_SZ    /d "%APP_URL%"                               /f >nul
reg add "%UNINST_KEY%" /v "InstallLocation"      /t REG_SZ    /d "%INSTALL_DIR%"                           /f >nul
reg add "%UNINST_KEY%" /v "DisplayIcon"          /t REG_SZ    /d "\"%INSTALL_DIR%\asm-terminal.ico\""      /f >nul
reg add "%UNINST_KEY%" /v "UninstallString"      /t REG_SZ    /d "\"%INSTALL_DIR%\uninstall.bat\""         /f >nul
reg add "%UNINST_KEY%" /v "QuietUninstallString" /t REG_SZ    /d "\"%INSTALL_DIR%\uninstall.bat\" /S"      /f >nul
reg add "%UNINST_KEY%" /v "NoModify"             /t REG_DWORD /d 1                                         /f >nul
reg add "%UNINST_KEY%" /v "NoRepair"             /t REG_DWORD /d 1                                         /f >nul

rem --- Installed-size estimate (KB) for Add/Remove Programs display ---
for %%F in ("%INSTALL_DIR%\%EXE_NAME%") do set "SIZE_BYTES=%%~zF"
set /a "SIZE_KB=%SIZE_BYTES% / 1024"
reg add "%UNINST_KEY%" /v "EstimatedSize"        /t REG_DWORD /d %SIZE_KB% /f >nul

echo [ok] Registered in Add/Remove Programs.

rem --- Refresh Start Menu so icon shows without sign-out ---
ie4uinit.exe -show >nul 2>nul

echo.
echo === Install complete ===
echo.
echo Launch options:
echo   - Start Menu : "%APP_NAME%"
echo   - Win+R      : asm
echo   - PATH       : %INSTALL_DIR%\%EXE_NAME%
echo.
echo To remove: Settings -^> Apps -^> "%APP_NAME%" -^> Uninstall
echo.
pause
exit /b 0

:copy_fail
echo [ERROR] Failed to copy %EXE_NAME% to install directory.
echo This can happen if the target folder is locked by antivirus.
pause
exit /b 2
