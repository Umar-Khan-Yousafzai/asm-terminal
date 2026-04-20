@echo off
rem ===========================================================================
rem ASM Terminal — Windows uninstaller
rem ===========================================================================
setlocal

set INSTALL_DIR=%LOCALAPPDATA%\Programs\ASM-Terminal
set START_MENU=%APPDATA%\Microsoft\Windows\Start Menu\Programs
set APP_NAME=ASM Terminal

echo Removing %APP_NAME% ...

if exist "%START_MENU%\%APP_NAME%.lnk" del /F /Q "%START_MENU%\%APP_NAME%.lnk"

reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe" /f >nul 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" /f >nul 2>nul

if exist "%INSTALL_DIR%" (
    rem Delete after start so the running uninstall.bat isn't locked on itself
    start "" /B cmd /C "ping 127.0.0.1 -n 2 > nul && rmdir /S /Q \"%INSTALL_DIR%\""
)

echo Done.
pause
endlocal
