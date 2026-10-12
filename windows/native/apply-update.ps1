# Applies an already-downloaded, already-verified NOTCH for Windows update.
# Started (detached) by the running app, which then quits. Never touches anything outside AppDir / NewDir.
#   -ParentPid  process id of the running NOTCH (we wait for it to exit)
#   -AppDir     the install folder that currently holds NOTCH.exe
#   -NewDir     the unpacked, validated new version
#   -Exe        file name to start afterwards (NOTCH.exe)
#   -Log        path of update.log
param(
    [Parameter(Mandatory = $true)][int]$ParentPid,
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$NewDir,
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Log
)
$ErrorActionPreference = 'Stop'

function Log($m) {
    try { Add-Content -LiteralPath $Log -Value ('[' + (Get-Date -Format 's') + '] ' + $m) } catch {}
}
function Start-App($dir) {
    $p = Join-Path $dir $Exe
    if (Test-Path -LiteralPath $p) { Start-Process -FilePath $p -WorkingDirectory $dir }
}

$bak = $AppDir.TrimEnd('\', '/') + '.old'
$swapped = $false
try {
    Log ('update started; waiting for process ' + $ParentPid + ' to exit')
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
        if ($null -eq $p) { break }
        Start-Sleep -Milliseconds 300
    }
    Start-Sleep -Milliseconds 800

    if (-not (Test-Path -LiteralPath $NewDir)) { throw 'new version folder is missing' }
    if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Recurse -Force }

    # Rename the old folder out of the way. Retry: antivirus or a closing helper process can hold it for a moment.
    $ok = $false
    for ($i = 0; $i -lt 40 -and -not $ok; $i++) {
        try { Move-Item -LiteralPath $AppDir -Destination $bak -ErrorAction Stop; $ok = $true }
        catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $ok) { throw 'could not move the old version aside (files in use)' }

    try {
        Move-Item -LiteralPath $NewDir -Destination $AppDir -ErrorAction Stop
        $swapped = $true
    } catch {
        Log ('could not move the new version into place: ' + $_.Exception.Message + ' - rolling back')
        Move-Item -LiteralPath $bak -Destination $AppDir -ErrorAction Stop
        throw
    }

    Log 'update applied; starting NOTCH'
    try { Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    Start-App $AppDir
}
catch {
    Log ('UPDATE FAILED: ' + $_.Exception.Message)
    # make sure the previous version is back and running
    try {
        if (-not (Test-Path -LiteralPath $AppDir) -and (Test-Path -LiteralPath $bak)) { Move-Item -LiteralPath $bak -Destination $AppDir }
    } catch { Log ('rollback failed: ' + $_.Exception.Message) }
    try { Start-App $AppDir } catch {}
    exit 1
}
exit 0
