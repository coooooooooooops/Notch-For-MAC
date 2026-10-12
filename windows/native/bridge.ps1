# NOTCH for Windows - native helper. ONE long-lived hidden PowerShell process (Windows PowerShell 5.1 compatible).
# Protocol: one JSON request per line on stdin  {"id":1,"cmd":"media",...}
#           one JSON reply per line on stdout   {"id":1,"ok":true,"data":...}
# Every feature is initialised separately; if one cannot start (locked-down PC, no battery, desktop monitor...)
# only that feature reports "unavailable". Nothing here can stop the app from working.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

function Send($o) {
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 6))
    [Console]::Out.Flush()
}

$caps = @{ media = $false; volume = $false; brightness = $true; theme = $true; mic = $true; keys = $false; screenOff = $false }

# ---------- Win32 helpers (media keys, monitor off, theme broadcast) ----------
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class NW32 {
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
    $caps.keys = $true
    $caps.screenOff = $true
} catch {}

# ---------- Core Audio (volume / mute) ----------
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    int f(); int g(); int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int j();
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int k(); int l(); int m(); int n();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
    int GetMute(out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref Guid id, int clsCtx, int activationParams, out IAudioEndpointVolume aev);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int f();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
}
[ComImport, Guid("BCDE0395-E52F-46CF-8FF0-C9F6F61B6D43")] class MMDeviceEnumeratorComObject { }
public class NAudio {
    static IAudioEndpointVolume Vol() {
        var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
        IMMDevice dev = null;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
        IAudioEndpointVolume epv = null;
        var epvid = typeof(IAudioEndpointVolume).GUID;
        Marshal.ThrowExceptionForHR(dev.Activate(ref epvid, 23, 0, out epv));
        return epv;
    }
    public static float GetVolume() { float v = -1; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return v; }
    public static void SetVolume(float v) { Marshal.ThrowExceptionForHR(Vol().SetMasterVolumeLevelScalar(v, Guid.Empty)); }
    public static bool GetMute() { bool m = false; Marshal.ThrowExceptionForHR(Vol().GetMute(out m)); return m; }
    public static void SetMute(bool m) { Marshal.ThrowExceptionForHR(Vol().SetMute(m, Guid.Empty)); }
}
'@
    [void][NAudio]::GetVolume()
    $caps.volume = $true
} catch {}

# ---------- Windows media session (now playing) ----------
$script:mgr = $null
$script:asTaskGeneric = $null
$script:thumbKey = ''
$script:thumbData = $null
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
    $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
} catch {}

function Await($op, $type) {
    $m = $script:asTaskGeneric.MakeGenericMethod($type)
    $t = $m.Invoke($null, @($op))
    if (-not $t.Wait(4000)) { throw 'winrt timeout' }
    return $t.Result
}

try {
    if ($null -ne $script:asTaskGeneric) {
        $script:mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        if ($null -ne $script:mgr) { $caps.media = $true }
    }
} catch {}

function Get-Media($haveKey) {
    if ($null -eq $script:mgr) { throw 'media unavailable' }
    $s = $script:mgr.GetCurrentSession()
    if ($null -eq $s) { return @{ has = $false } }
    $props = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    $pb = $s.GetPlaybackInfo()
    $tl = $s.GetTimelineProperties()
    $title = [string]$props.Title
    $artist = [string]$props.Artist
    $app = [string]$s.SourceAppUserModelId
    $key = $app + '|' + $title + '|' + $artist
    $playing = ([int]$pb.PlaybackStatus -eq 4)
    $pos = 0.0
    $dur = 0.0
    try {
        $dur = [double]($tl.EndTime - $tl.StartTime).TotalSeconds
        $pos = [double]$tl.Position.TotalSeconds
        if ($playing -and $dur -gt 0) {
            $age = ([DateTimeOffset]::UtcNow - $tl.LastUpdatedTime).TotalSeconds
            if ($age -gt 0 -and $age -lt 3600) { $pos += $age }
        }
        if ($pos -gt $dur) { $pos = $dur }
        if ($pos -lt 0) { $pos = 0 }
    } catch { $pos = 0.0; $dur = 0.0 }

    if ($key -ne $script:thumbKey) {
        $script:thumbKey = $key
        $script:thumbData = $null
        try {
            if ($null -ne $props.Thumbnail) {
                $st = Await ($props.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
                $net = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($st)
                $ms = New-Object System.IO.MemoryStream
                $net.CopyTo($ms)
                if ($ms.Length -gt 0 -and $ms.Length -lt 3000000) {
                    $ct = [string]$st.ContentType
                    if ([string]::IsNullOrEmpty($ct)) { $ct = 'image/jpeg' }
                    $script:thumbData = 'data:' + $ct + ';base64,' + [Convert]::ToBase64String($ms.ToArray())
                }
                $st.Dispose()
            }
        } catch { $script:thumbData = $null }
    }
    $thumb = $null
    if ($haveKey -ne $key) { $thumb = $script:thumbData }
    return @{ has = $true; title = $title; artist = $artist; app = $app; playing = $playing; pos = $pos; dur = $dur; key = $key; thumb = $thumb }
}

function Press-Key([byte]$vk) {
    [NW32]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
    [NW32]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
}

function Media-Ctl($action) {
    $s = $null
    if ($null -ne $script:mgr) { $s = $script:mgr.GetCurrentSession() }
    if ($null -ne $s) {
        if ($action -eq 'toggle') { $null = Await ($s.TryTogglePlayPauseAsync()) ([bool]) }
        elseif ($action -eq 'next') { $null = Await ($s.TrySkipNextAsync()) ([bool]) }
        elseif ($action -eq 'prev') { $null = Await ($s.TrySkipPreviousAsync()) ([bool]) }
        return $true
    }
    if (-not $caps.keys) { throw 'no media session' }
    if ($action -eq 'toggle') { Press-Key 0xB3 }
    elseif ($action -eq 'next') { Press-Key 0xB0 }
    elseif ($action -eq 'prev') { Press-Key 0xB1 }
    return $true
}

function Media-Seek($seconds) {
    if ($null -eq $script:mgr) { throw 'media unavailable' }
    $s = $script:mgr.GetCurrentSession()
    if ($null -eq $s) { throw 'no media session' }
    $ticks = [long]([double]$seconds * 10000000)
    return [bool](Await ($s.TryChangePlaybackPositionAsync($ticks)) ([bool]))
}

# ---------- brightness (laptop / built-in panel only) ----------
function Get-Bright {
    $b = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $b) { throw 'no built-in display' }
    return [int]$b.CurrentBrightness
}
function Set-Bright($v) {
    $n = [Math]::Max(0, [Math]::Min(100, [int]$v))
    $m = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $m) { throw 'no built-in display' }
    $null = Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]1; Brightness = [byte]$n }
    return $true
}

# ---------- dark mode ----------
$themeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
function Get-Dark {
    $v = (Get-ItemProperty -Path $themeKey -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
    return ($v -eq 0)
}
function Set-Dark($dark) {
    $val = 1
    if ($dark) { $val = 0 }
    Set-ItemProperty -Path $themeKey -Name AppsUseLightTheme -Value $val -Type DWord
    Set-ItemProperty -Path $themeKey -Name SystemUsesLightTheme -Value $val -Type DWord
    if ($caps.keys) {
        $r = [UIntPtr]::Zero
        $null = [NW32]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 200, [ref]$r)
    }
    return $true
}

# ---------- microphone in use (calls) ----------
function Get-MicInUse {
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
    foreach ($k in @($base, ($base + '\NonPackaged'))) {
        if (-not (Test-Path -Path $k)) { continue }
        foreach ($c in (Get-ChildItem -Path $k -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $c.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $p -and $null -ne $p.LastUsedTimeStart -and $null -ne $p.LastUsedTimeStop) {
                if ($p.LastUsedTimeStart -gt 0 -and $p.LastUsedTimeStop -eq 0) { return $true }
            }
        }
    }
    return $false
}

function Handle($req) {
    switch ($req.cmd) {
        'media' { return (Get-Media $req.haveKey) }
        'mediaCtl' { return (Media-Ctl $req.action) }
        'seek' { return (Media-Seek $req.seconds) }
        'getVolume' {
            if (-not $caps.volume) { throw 'volume unavailable' }
            return @{ volume = [int][Math]::Round([NAudio]::GetVolume() * 100); mute = [bool][NAudio]::GetMute() }
        }
        'setVolume' {
            if (-not $caps.volume) { throw 'volume unavailable' }
            $v = [Math]::Max(0, [Math]::Min(100, [double]$req.value))
            [NAudio]::SetVolume([float]($v / 100.0))
            if ($v -gt 0 -and [NAudio]::GetMute()) { [NAudio]::SetMute($false) }
            return $true
        }
        'setMute' {
            if (-not $caps.volume) { throw 'volume unavailable' }
            [NAudio]::SetMute([bool]$req.value)
            return $true
        }
        'getBrightness' { return (Get-Bright) }
        'setBrightness' { return (Set-Bright $req.value) }
        'getDark' { return (Get-Dark) }
        'setDark' { return (Set-Dark ([bool]$req.value)) }
        'mic' { return (Get-MicInUse) }
        'screenOff' {
            if (-not $caps.screenOff) { throw 'unavailable' }
            $null = [NW32]::PostMessage([IntPtr]0xFFFF, 0x112, [IntPtr]0xF170, [IntPtr]2)
            return $true
        }
        default { throw ('unknown command ' + $req.cmd) }
    }
}

Send @{ event = 'caps'; caps = $caps }

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if ($line.Trim().Length -eq 0) { continue }
    $id = 0
    try {
        $req = $line | ConvertFrom-Json
        $id = $req.id
        $out = @(Handle $req)
        $data = $null
        if ($out.Count -gt 0) { $data = $out[$out.Count - 1] }
        Send @{ id = $id; ok = $true; data = $data }
    } catch {
        Send @{ id = $id; ok = $false; error = [string]$_.Exception.Message }
    }
}
