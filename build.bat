@echo off
rem ===========================================================================
rem ASM Terminal - Windows build
rem Requires: NASM on PATH (or C:\Program Files\NASM\nasm.exe)
rem Requires: MinGW-w64 ld on PATH (or common choco / msys install paths)
rem Honours env overrides: set NASM_EXE=... or set LD_EXE=... before calling.
rem ===========================================================================
setlocal enabledelayedexpansion

set "NASM_EXE="
if not "%NASM_EXE%"=="" goto :have_nasm
for %%P in (
    "nasm.exe"
    "C:\Program Files\NASM\nasm.exe"
    "C:\ProgramData\chocolatey\bin\nasm.exe"
) do (
    if exist "%%~P"     set "NASM_EXE=%%~fP"
)
if "%NASM_EXE%"=="" (
    where nasm.exe >nul 2>nul && for /f "delims=" %%F in ('where nasm.exe') do set "NASM_EXE=%%F"
)
:have_nasm
if not exist "%NASM_EXE%" (
    echo [!] nasm.exe not found. Install NASM or set NASM_EXE=path\to\nasm.exe
    exit /b 2
)

set "LD_EXE="
if not "%LD_EXE%"=="" goto :have_ld
for %%P in (
    "ld.exe"
    "C:\ProgramData\chocolatey\lib\mingw\tools\install\mingw64\bin\ld.exe"
    "C:\tools\mingw64\bin\ld.exe"
    "C:\msys64\mingw64\bin\ld.exe"
    "C:\Program Files\mingw-w64\x86_64-8.1.0-win32-seh-rt_v6-rev0\mingw64\bin\ld.exe"
) do (
    if exist "%%~P" set "LD_EXE=%%~fP"
)
if "%LD_EXE%"=="" (
    where ld.exe >nul 2>nul && for /f "delims=" %%F in ('where ld.exe') do set "LD_EXE=%%F"
)
:have_ld
if not exist "%LD_EXE%" (
    echo [!] MinGW ld.exe not found. Install mingw-w64 or set LD_EXE=path\to\ld.exe
    exit /b 3
)

rem Derive MinGW lib dir from ld.exe path if -L isn't forced
if "%LD_LIBDIR%"=="" for %%F in ("%LD_EXE%") do (
    for %%D in ("%%~dpF..") do set "LD_LIBDIR=%%~fD\lib"
)

echo [*] NASM : %NASM_EXE%
echo [*] LD   : %LD_EXE%
echo [*] LIB  : %LD_LIBDIR%
echo.
echo [*] Assembling terminal.asm ...
"%NASM_EXE%" -f win64 terminal.asm -o terminal.obj
if errorlevel 1 (
    echo [!] Assembly failed!
    exit /b 1
)

echo [*] Linking terminal.obj ...
"%LD_EXE%" terminal.obj -o terminal.exe -e main --subsystem console -L "%LD_LIBDIR%" -lkernel32 -luser32
if errorlevel 1 (
    echo [!] Linking failed!
    exit /b 1
)

echo [+] Build successful: terminal.exe
endlocal
exit /b 0
