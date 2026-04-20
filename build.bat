@echo off
echo [*] Assembling terminal.asm ...
"C:\Program Files\NASM\nasm.exe" -f win64 terminal.asm -o terminal.obj
if %errorlevel% neq 0 (
    echo [!] Assembly failed!
    pause
    exit /b 1
)

echo [*] Linking terminal.obj ...
"C:\ProgramData\chocolatey\lib\mingw\tools\install\mingw64\bin\ld.exe" terminal.obj -o terminal.exe -e main --subsystem console -L "C:\ProgramData\chocolatey\lib\mingw\tools\install\mingw64\lib" -lkernel32 -luser32
if %errorlevel% neq 0 (
    echo [!] Linking failed!
    pause
    exit /b 1
)

echo [+] Build successful: terminal.exe
echo [*] Run with: terminal.exe
