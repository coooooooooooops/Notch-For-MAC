# Installs NOTCH for Windows for the current user (no admin needed).
#   Copies this folder to %LOCALAPPDATA%\Programs\NOTCH, adds a Start-menu shortcut and starts it.
param([string]$Root = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($Root)) { $Root = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.FullName }
$src = $Root.TrimEnd('\', '/')                  # the folder that holds NOTCH.exe
$exeName = 'NOTCH.exe'
$dst = Join-Path $env:LOCALAPPDATA 'Programs\NOTCH'

if (-not (Test-Path -LiteralPath (Join-Path $src $exeName))) {
    Write-Host ('Could not find ' + $exeName + ' next to this installer. Unzip the whole download first, then run Install.bat again.')
    exit 1
}

# files that came from the internet carry a "blocked" mark that triggers extra warnings
try { Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch {}

# stop a running copy
Get-Process -Name 'NOTCH' -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.CloseMainWindow() | Out-Null } catch {}
}
Start-Sleep -Milliseconds 700
Get-Process -Name 'NOTCH' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 700

if ((Resolve-Path -LiteralPath $src).Path.TrimEnd('\') -ne $dst.TrimEnd('\')) {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    & robocopy.exe $src $dst /E /NFL /NDL /NJH /NJS /NP /R:3 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ('Copy failed (robocopy code ' + $LASTEXITCODE + ')') }
}

$exe = Join-Path $dst $exeName
$ico = Join-Path $dst 'resources\app\assets\icon.ico'
$menu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$sh = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut((Join-Path $menu 'NOTCH.lnk'))
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $dst
if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = $ico }
$lnk.Description = 'NOTCH'
$lnk.Save()

Write-Host ''
Write-Host 'NOTCH is installed.'
Write-Host ('  Location : ' + $dst)
Write-Host '  Start    : it is starting now. Look for a thin bar at the top-centre of your screen and hover over it.'
Write-Host '  Later    : find NOTCH in the Start menu, or use the tray icon (bottom-right) for Launch at Login.'
Start-Process -FilePath $exe -WorkingDirectory $dst
exit 0
