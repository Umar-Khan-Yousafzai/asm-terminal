@echo off
rem ===========================================================================
rem ASM Terminal — Windows installer (batch fallback / unattended)
rem Installs terminal.exe into %LOCALAPPDATA%\Programs\ASM-Terminal and creates
rem a Start Menu shortcut that opens it in Windows Terminal (or cmd.exe).
rem Run this from the folder containing terminal.exe.
rem ===========================================================================
setlocal

set INSTALL_DIR=%LOCALAPPDATA%\Programs\ASM-Terminal
set START_MENU=%APPDATA%\Microsoft\Windows\Start Menu\Programs
set EXE_NAME=terminal.exe
set APP_NAME=ASM Terminal

echo.
echo Installing %APP_NAME% to "%INSTALL_DIR%" ...

if not exist "%~dp0%EXE_NAME%" (
    echo [error] %EXE_NAME% not found next to install.bat.
    pause
    exit /b 1
)

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
copy /Y "%~dp0%EXE_NAME%"      "%INSTALL_DIR%\%EXE_NAME%"      >nul
if exist "%~dp0asm-terminal.ico" copy /Y "%~dp0asm-terminal.ico" "%INSTALL_DIR%\asm-terminal.ico" >nul
if exist "%~dp0uninstall.bat"    copy /Y "%~dp0uninstall.bat"    "%INSTALL_DIR%\uninstall.bat"    >nul

rem --- Create Start Menu shortcut via PowerShell ---
set SHORTCUT="%START_MENU%\%APP_NAME%.lnk"
set TARGET="%INSTALL_DIR%\%EXE_NAME%"
set ICON="%INSTALL_DIR%\asm-terminal.ico"

powershell -NoProfile -Command ^
    "$s=(New-Object -COM WScript.Shell).CreateShortcut(%SHORTCUT%); $s.TargetPath=%TARGET%; $s.WorkingDirectory='%INSTALL_DIR%'; if(Test-Path %ICON%){$s.IconLocation=%ICON%}; $s.Description='%APP_NAME%'; $s.Save()"

rem --- Register under App Paths so user can run `asm` from Win+R ---
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe" /ve /t REG_SZ /d "%INSTALL_DIR%\%EXE_NAME%" /f >nul 2>nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe" /v "Path" /t REG_SZ /d "%INSTALL_DIR%" /f >nul 2>nul

rem --- Register uninstall entry in Add/Remove Programs ---
set UNINST_KEY=HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal
reg add "%UNINST_KEY%" /v "DisplayName"    /t REG_SZ /d "%APP_NAME%"                     /f >nul
reg add "%UNINST_KEY%" /v "DisplayVersion" /t REG_SZ /d "2.0.0"                          /f >nul
reg add "%UNINST_KEY%" /v "Publisher"      /t REG_SZ /d "Umar Khan Yousafzai"            /f >nul
reg add "%UNINST_KEY%" /v "InstallLocation"/t REG_SZ /d "%INSTALL_DIR%"                  /f >nul
reg add "%UNINST_KEY%" /v "UninstallString"/t REG_SZ /d "%INSTALL_DIR%\uninstall.bat"    /f >nul
reg add "%UNINST_KEY%" /v "DisplayIcon"    /t REG_SZ /d "%INSTALL_DIR%\asm-terminal.ico" /f >nul

echo.
echo Done.
echo - Start Menu shortcut: %APP_NAME%
echo - Win+R command:       asm
echo - Install dir:         %INSTALL_DIR%
echo.
pause
endlocal
