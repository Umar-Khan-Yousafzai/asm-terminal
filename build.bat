@echo off
rem ===========================================================================
rem ASM Terminal - Windows build
rem Requires: NASM on PATH (or C:\Program Files\NASM\nasm.exe)
rem Requires: MinGW-w64 ld on PATH (or common choco / msys install paths)
rem Honours env overrides: set NASM_EXE=... or set LD_EXE=... before calling.
rem ===========================================================================
setlocal enabledelayedexpansion
rem Build from the script folder so the version.inc include resolves.
rem (setlocal restores the caller's folder on exit.)
cd /d "%~dp0"

if not "%NASM_EXE%"=="" goto :have_nasm
rem A NASM on PATH is the one the user chose; the fixed locations come after
where nasm.exe >nul 2>nul && for /f "delims=" %%F in ('where nasm.exe') do (
    if "!NASM_EXE!"=="" set "NASM_EXE=%%F"
)
if not "%NASM_EXE%"=="" goto :have_nasm
rem Fixed locations: the first one that exists wins
for %%P in (
    "C:\Program Files\NASM\nasm.exe"
    "C:\ProgramData\chocolatey\bin\nasm.exe"
) do (
    if "!NASM_EXE!"=="" if exist "%%~P" set "NASM_EXE=%%~fP"
)
:have_nasm
if not exist "%NASM_EXE%" (
    echo [!] nasm.exe not found. Install NASM or set NASM_EXE=path\to\nasm.exe
    exit /b 2
)

if not "%LD_EXE%"=="" goto :have_ld
rem Known MinGW-w64 locations first: other tools put an ld.exe on PATH that
rem cannot link Windows programs, Strawberry Perl for one
for %%P in (
    "C:\ProgramData\chocolatey\lib\mingw\tools\install\mingw64\bin\ld.exe"
    "C:\tools\mingw64\bin\ld.exe"
    "C:\msys64\mingw64\bin\ld.exe"
    "C:\Program Files\mingw-w64\x86_64-8.1.0-win32-seh-rt_v6-rev0\mingw64\bin\ld.exe"
) do (
    if "!LD_EXE!"=="" if exist "%%~P" set "LD_EXE=%%~fP"
)
if "%LD_EXE%"=="" (
    where ld.exe >nul 2>nul && for /f "delims=" %%F in ('where ld.exe') do (
        if "!LD_EXE!"=="" set "LD_EXE=%%F"
    )
)
:have_ld
if not exist "%LD_EXE%" (
    echo [!] MinGW ld.exe not found. Install mingw-w64 or set LD_EXE=path\to\ld.exe
    exit /b 3
)

rem Derive the import library folder from the ld.exe path unless it is forced.
rem MinGW-w64 keeps libkernel32.a in x86_64-w64-mingw32\lib next to bin,
rem older layouts have a plain lib folder.
if "%LD_LIBDIR%"=="" for %%F in ("%LD_EXE%") do (
    for %%D in ("%%~dpF..") do (
        if exist "%%~fD\x86_64-w64-mingw32\lib\libkernel32.a" (
            set "LD_LIBDIR=%%~fD\x86_64-w64-mingw32\lib"
        ) else (
            set "LD_LIBDIR=%%~fD\lib"
        )
    )
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
"%LD_EXE%" terminal.obj -o terminal.exe -e main --subsystem console -L "%LD_LIBDIR%" -lkernel32
if errorlevel 1 (
    echo [!] Linking failed!
    exit /b 1
)

echo [+] Build successful: terminal.exe
endlocal
exit /b 0
