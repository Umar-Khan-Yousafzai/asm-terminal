# ----------------------------------------------------------------------------
# ASM Terminal - Windows installer (PowerShell, Win10/11)
# Run:  powershell -ExecutionPolicy Bypass -File install.ps1
# Or:   right-click install.ps1 -> Run with PowerShell
# ----------------------------------------------------------------------------

[CmdletBinding()]
param(
    [switch]$Silent,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\ASM-Terminal')
)

$ErrorActionPreference = 'Stop'

$AppName      = 'ASM Terminal'
$AppVersion   = '2.0.0'
$AppPublisher = 'Umar Khan Yousafzai'
$AppUrl       = 'https://github.com/Umar-Khan-Yousafzai/asm-terminal'
$ExeName      = 'terminal.exe'

$SrcDir = $PSScriptRoot
if (-not $SrcDir) { $SrcDir = (Get-Location).Path }
$SrcExe = Join-Path $SrcDir $ExeName

if (-not (Test-Path $SrcExe)) {
    Write-Host "[ERROR] $ExeName not found next to install.ps1 ($SrcDir)." -ForegroundColor Red
    if (-not $Silent) { Read-Host 'Press Enter to exit' }
    exit 1
}

Write-Host ""
Write-Host "=== Installing $AppName $AppVersion ===" -ForegroundColor Cyan
Write-Host "Target: $InstallDir"
Write-Host ""

# Create directories
$StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $StartMenu  | Out-Null

# Copy files
$payload = @{
    'terminal.exe'        = $true
    'asm-terminal.ico'    = $false
    'uninstall.bat'       = $false
    'uninstall.ps1'       = $false
    'README.md'           = $false
    'INSTALL.md'          = $false
}
foreach ($pair in $payload.GetEnumerator()) {
    $name = $pair.Key
    $required = $pair.Value
    $src = Join-Path $SrcDir $name
    if (Test-Path $src) {
        Copy-Item -Force $src (Join-Path $InstallDir $name)
    } elseif ($required) {
        Write-Host "[ERROR] Missing required file: $name" -ForegroundColor Red
        exit 2
    }
}

# Start Menu shortcut
$lnk    = Join-Path $StartMenu "$AppName.lnk"
$target = Join-Path $InstallDir $ExeName
$icon   = Join-Path $InstallDir 'asm-terminal.ico'
$wsh = New-Object -ComObject WScript.Shell
$s   = $wsh.CreateShortcut($lnk)
$s.TargetPath       = $target
$s.WorkingDirectory = $InstallDir
if (Test-Path $icon) { $s.IconLocation = $icon }
$s.Description      = "$AppName - x86-64 assembly shell"
$s.WindowStyle      = 1
$s.Save()
Write-Host "[ok] Start Menu shortcut: $lnk"

# App Paths (Win+R)
$appPaths = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\asm.exe'
New-Item -Path $appPaths -Force | Out-Null
Set-ItemProperty -Path $appPaths -Name '(default)' -Value $target
Set-ItemProperty -Path $appPaths -Name 'Path'      -Value $InstallDir
New-ItemProperty -Path $appPaths -Name 'UseUrl'    -PropertyType DWord -Value 0 -Force | Out-Null
Write-Host "[ok] App Paths (Win+R: asm) registered"

# Add/Remove Programs entry
$uninst = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ASM-Terminal'
New-Item -Path $uninst -Force | Out-Null
$uninstallCmd = "`"$(Join-Path $InstallDir 'uninstall.bat')`""
Set-ItemProperty -Path $uninst -Name 'DisplayName'         -Value $AppName
Set-ItemProperty -Path $uninst -Name 'DisplayVersion'      -Value $AppVersion
Set-ItemProperty -Path $uninst -Name 'Publisher'           -Value $AppPublisher
Set-ItemProperty -Path $uninst -Name 'URLInfoAbout'        -Value $AppUrl
Set-ItemProperty -Path $uninst -Name 'InstallLocation'     -Value $InstallDir
Set-ItemProperty -Path $uninst -Name 'DisplayIcon'         -Value "`"$icon`""
Set-ItemProperty -Path $uninst -Name 'UninstallString'     -Value $uninstallCmd
Set-ItemProperty -Path $uninst -Name 'QuietUninstallString' -Value "$uninstallCmd /S"
New-ItemProperty -Path $uninst -Name 'NoModify'            -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $uninst -Name 'NoRepair'            -PropertyType DWord -Value 1 -Force | Out-Null

$sizeKb = [math]::Round((Get-Item $target).Length / 1KB)
New-ItemProperty -Path $uninst -Name 'EstimatedSize'       -PropertyType DWord -Value $sizeKb -Force | Out-Null
Write-Host "[ok] Registered in Add/Remove Programs"

# Refresh Start Menu cache
try { & "$env:SystemRoot\System32\ie4uinit.exe" -show | Out-Null } catch {}

Write-Host ""
Write-Host "=== Install complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Launch options:"
Write-Host "  - Start Menu : $AppName"
Write-Host "  - Win+R      : asm"
Write-Host "  - Full path  : $target"
Write-Host ""
Write-Host "To remove: Settings -> Apps -> $AppName -> Uninstall"
Write-Host ""

if (-not $Silent) { Read-Host 'Press Enter to exit' }
