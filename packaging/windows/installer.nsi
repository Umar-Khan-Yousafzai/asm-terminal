; ===========================================================================
; ASM Terminal — NSIS installer script
;
; Build on Windows: makensis installer.nsi
; Build on Linux:   apt-get install nsis && makensis installer.nsi
;
; Produces: asm-terminal-2.0.0-windows-x86_64-setup.exe
; Installs terminal.exe into %LOCALAPPDATA%\Programs\ASM-Terminal, creates
; a Start Menu shortcut that opens the shell, and wires up Add/Remove Programs.
; ===========================================================================

!define APP_NAME        "ASM Terminal"
!define APP_VERSION     "2.0.0"
!define APP_PUBLISHER   "Umar Khan Yousafzai"
!define APP_URL         "https://github.com/Umar-Khan-Yousafzai/asm-terminal"
!define APP_EXE         "terminal.exe"

Name "${APP_NAME}"
OutFile "asm-terminal-${APP_VERSION}-windows-x86_64-setup.exe"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\ASM-Terminal"
ShowInstDetails show
ShowUnInstDetails show
SetCompressor /SOLID lzma

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName"   "${APP_NAME}"
VIAddVersionKey "CompanyName"   "${APP_PUBLISHER}"
VIAddVersionKey "FileVersion"   "${APP_VERSION}"
VIAddVersionKey "FileDescription" "x86-64 assembly shell installer"
VIAddVersionKey "LegalCopyright"  "MIT"

!include "MUI2.nsh"
!define MUI_ICON   "asm-terminal.ico"
!define MUI_UNICON "asm-terminal.ico"
!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Section "Install"
    SetOutPath "$INSTDIR"
    File "${APP_EXE}"
    File /nonfatal "asm-terminal.ico"

    ; Start Menu shortcut
    CreateDirectory "$SMPROGRAMS"
    CreateShortcut "$SMPROGRAMS\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\asm-terminal.ico"

    ; Win+R: user can run 'asm' directly
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe" "" "$INSTDIR\${APP_EXE}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe" "Path" "$INSTDIR"

    ; Add/Remove Programs
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" "DisplayName"     "${APP_NAME}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" "DisplayVersion"  "${APP_VERSION}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" "Publisher"       "${APP_PUBLISHER}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" "URLInfoAbout"    "${APP_URL}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" "DisplayIcon"     "$INSTDIR\asm-terminal.ico"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" "UninstallString" "$INSTDIR\uninstall.exe"
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" "NoModify" 1
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal" "NoRepair" 1

    WriteUninstaller "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
    Delete "$SMPROGRAMS\${APP_NAME}.lnk"
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe"
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal"
    Delete "$INSTDIR\${APP_EXE}"
    Delete "$INSTDIR\asm-terminal.ico"
    Delete "$INSTDIR\uninstall.exe"
    RMDir "$INSTDIR"
SectionEnd
