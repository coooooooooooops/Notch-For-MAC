# Removes NOTCH for Windows (program files, Start-menu shortcut, Launch-at-Login entry).
# Your notes, settings and clipboard pins live in %APPDATA%\NOTCH and are kept unless you answer Y.
$ErrorActionPreference = 'Continue'
$dst = Join-Path $env:LOCALAPPDATA 'Programs\NOTCH'
Get-Process -Name 'NOTCH' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800
try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'NOTCH' -ErrorAction SilentlyContinue } catch {}
try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'electron.app.NOTCH' -ErrorAction SilentlyContinue } catch {}
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\NOTCH.lnk'
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
$data = Join-Path $env:APPDATA 'NOTCH'
if (Test-Path -LiteralPath $data) {
    $a = Read-Host 'Also delete your NOTCH data (notes, settings, pins)? Y/N'
    if ($a -match '^[Yy]') { Remove-Item -LiteralPath $data -Recurse -Force }
}
Write-Host 'NOTCH has been removed.'
