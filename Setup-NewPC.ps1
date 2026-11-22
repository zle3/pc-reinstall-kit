<#
.SYNOPSIS
    Guided setup of a freshly installed Windows PC, using the backup made by Backup-OldPC.ps1.

.DESCRIPTION
    Menu-driven. Each step can be run on its own, in any order, and re-run.
    Progress is remembered (in the backup folder) so you can stop, reboot and continue.

      1  Internet & network drivers     restore Wi-Fi networks, install backed-up network driver
      2  Windows Update & activation
      3  Drivers                        chipset / GPU / audio / motherboard links, backed-up drivers
      4  Install apps (winget)          everything from the old PC that winget knows, plus common apps
      5  Apps to install by hand        web search links, Store apps, peripheral software, licenses
      6  Browsers                       bookmarks, history, Firefox profiles, extensions, passwords
      7  Personal files                 copy Desktop / Documents / ... back
      8  Windows settings               theme, Explorer, taskbar, mouse, privacy, power plan, region ...
      9  System extras                  Windows features, fonts, printers, network drives, hosts, tasks
     10  App settings                   VS Code, SSH keys, Outlook signatures, OBS, Sticky Notes ...
     11  Guided checklist               walk through checklist.txt + app-specific reminders
     12  Finish                         final checks, restore point, clean up private files

    Works without a backup too (generic mode): it then uses this PC's hardware and a
    list of common apps, and the checklist.

.PARAMETER BackupPath
    PCBackup_* folder (or the folder containing it). Default: searched next to this script.

.PARAMETER NoGrid
    Use numbered console lists instead of selection windows.
#>
[CmdletBinding()]
param(
    [string]$BackupPath,
    [switch]$NoGrid,
    [switch]$NoElevate
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Test-IsAdmin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
$IsAdmin = Test-IsAdmin
if (-not $IsAdmin -and -not $NoElevate) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-NoElevate')
    if ($BackupPath) { $argList += @('-BackupPath', "`"$BackupPath`"") }
    if ($NoGrid) { $argList += '-NoGrid' }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop; exit }
    catch { Write-Host 'Continuing without admin rights - drivers, features and some settings will be skipped.' -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}
function Write-Sub([string]$Text)  { Write-Host ''; Write-Host "  -- $Text" -ForegroundColor White }
function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "         $Text" -ForegroundColor Gray }
function Write-Todo([string]$Text) { Write-Host "  [TODO] $Text" -ForegroundColor Cyan }
function Write-Warn2([string]$Text){ Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }

function Ask-YesNo([string]$Question, [bool]$Default = $true) {
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = Read-Host "  $Question $suffix"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        switch -Regex ($a.Trim()) { '^(y|yes)$' { return $true } '^(n|no)$' { return $false } }
    }
}
function Wait-Enter([string]$Text = 'Press Enter to continue') { [void](Read-Host "  $Text") }

function Read-JsonFile([string]$Path) {
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}
function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}
function Get-RegValue([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}
function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Open-Target([string]$Target, [string]$Exe) {
    # Opens a URL, ms-settings: page, .cpl/.msc tool, or "program args".
    try {
        if ($Exe -and -not $Target) { Start-Process -FilePath $Exe -ErrorAction Stop; return }
        if ($Exe) { Start-Process -FilePath $Exe -ArgumentList "`"$Target`"" -ErrorAction Stop; return }
        if ($Target -match '^[a-z][a-z0-9+.-]*:' -and $Target -notmatch '^[a-zA-Z]:\\') { Start-Process $Target -ErrorAction Stop; return }
        if ($Target -match '^(\S+)\s+(.+)$') { Start-Process -FilePath $Matches[1] -ArgumentList $Matches[2] -ErrorAction Stop; return }
        Start-Process $Target -ErrorAction Stop
    } catch { Write-Warn2 "Could not open '$Target': $($_.Exception.Message)" }
}

function Search-Web([string]$Query) { Open-Target ('https://www.google.com/search?q=' + [uri]::EscapeDataString($Query)) }

$Script:UseGrid = (-not $NoGrid) -and [bool](Get-Command Out-GridView -ErrorAction SilentlyContinue)
function Select-Items {
    # Lets the user tick items. Uses a selection window if available, otherwise a numbered list.
    param([object[]]$Items, [string]$Title, [string[]]$Property, [switch]$Single, [switch]$PreselectAllHint)
    if (-not $Items -or @($Items).Count -eq 0) { return @() }
    $Items = @($Items)
    if ($Script:UseGrid) {
        Write-Host "  A selection window opened: '$Title'" -ForegroundColor Cyan
        Write-Info 'Select rows (Ctrl+click, Shift+click, Ctrl+A for all) and click OK. Cancel = none.'
        Write-Info '(If you do not see it, it may be behind this window - check the taskbar.)'
        $i = 0
        $rows = foreach ($it in $Items) {
            $i++
            $o = [ordered]@{ '#' = $i }
            foreach ($p in $Property) { $v = $it.$p; if ($v -is [array]) { $v = $v -join ', ' }; $o[$p] = $v }
            [pscustomobject]$o
        }
        $mode = if ($Single) { 'Single' } else { 'Multiple' }
        $picked = @($rows | Out-GridView -Title $Title -OutputMode $mode)
        return @($picked | ForEach-Object { $Items[$_.'#' - 1] })
    }
    Write-Host "  $Title" -ForegroundColor Cyan
    for ($n = 0; $n -lt $Items.Count; $n++) {
        $label = ($Property | ForEach-Object { "$($Items[$n].$_)" } | Where-Object { $_ }) -join '  |  '
        Write-Host ('   {0,3}. {1}' -f ($n + 1), $label)
    }
    $prompt = if ($Single) { 'Enter a number (Enter = none)' } else { 'Numbers (e.g. 1,3,5-7), A = all, Enter = none' }
    $a = Read-Host "  $prompt"
    if ([string]::IsNullOrWhiteSpace($a)) { return @() }
    if (-not $Single -and $a.Trim() -match '^(a|all)$') { return $Items }
    $out = @()
    foreach ($part in ($a -split '[,; ]+')) {
        if ($part -match '^(\d+)-(\d+)$') { for ($k = [int]$Matches[1]; $k -le [int]$Matches[2]; $k++) { if ($k -ge 1 -and $k -le $Items.Count) { $out += $Items[$k - 1] } } }
        elseif ($part -match '^\d+$') { $k = [int]$part; if ($k -ge 1 -and $k -le $Items.Count) { $out += $Items[$k - 1] } }
    }
    if ($Single) { return @($out | Select-Object -First 1) }
    return $out
}

function Confirm-Selection {
    # Easy mode: show what will be done and let Enter accept it.
    #   Enter = do the recommended items   C = choose myself   N = skip
    # -Default: the recommended subset (omit = all items). -NoDefault: nothing recommended (Enter = skip).
    param([object[]]$Items, [string]$Title, [string[]]$Property, [string]$What = 'items', [object[]]$Default, [switch]$NoDefault)
    if (-not $Items -or @($Items).Count -eq 0) { return @() }
    $Items = @($Items)
    if ($NoDefault) { $Default = @() } elseif (-not $PSBoundParameters.ContainsKey('Default')) { $Default = $Items } else { $Default = @($Default) }
    $label = { param($x) (($Property | Select-Object -First 2 | ForEach-Object { "$($x.$_)" } | Where-Object { $_ }) -join '  -  ') }
    Write-Host ''
    if ($Default.Count -gt 0) {
        Write-Host ("  {0} {1}:" -f $Default.Count, $What) -ForegroundColor White
        foreach ($d in ($Default | Select-Object -First 12)) { Write-Host ("     - {0}" -f (& $label $d)) }
        if ($Default.Count -gt 12) { Write-Host ("     ... and {0} more" -f ($Default.Count - 12)) -ForegroundColor Gray }
        $extra = $Items.Count - $Default.Count
        if ($extra -gt 0) { Write-Host ("     ({0} more available if you press C)" -f $extra) -ForegroundColor Gray }
        $a = Read-Host '  Enter = yes, go ahead     C = let me choose     N = skip'
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    } else {
        Write-Host ("  {0} {1} available (none needed by default)." -f $Items.Count, $What) -ForegroundColor White
        $a = Read-Host '  Enter = skip     C = let me choose'
        if ([string]::IsNullOrWhiteSpace($a)) { return @() }
    }
    if ($a.Trim() -match '^[cC]') { return @(Select-Items -Items $Items -Title $Title -Property $Property) }
    if ($a.Trim() -match '^[yY]') { return $Default }
    return @()
}

function Test-Internet {
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop
        return ($r.Content -match 'Microsoft Connect Test')
    } catch {
        try { $null = [System.Net.Dns]::GetHostEntry('www.microsoft.com'); return (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet) } catch { return $false }
    }
}

function Invoke-Robo([string]$Source, [string]$Dest, [string[]]$Extra = @()) {
    $log = Join-Path $Script:LogDir 'restore-robocopy.log'
    $roboArgs = @($Source, $Dest, '/E', '/R:1', '/W:1', '/XJ', '/MT:16', '/NP', '/NFL', '/NDL', "/LOG+:$log") + $Extra
    & robocopy.exe @roboArgs | Out-Null
    return ($LASTEXITCODE -lt 8)
}

function Stop-AppProcess([string[]]$Names, [string]$Label) {
    $procs = @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
    if (-not $procs) { return $true }
    Write-Warn2 "$Label is running and must be closed."
    if (-not (Ask-YesNo "Close $Label now?" $true)) { return $false }
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { } }
    Start-Sleep -Seconds 4
    Get-Process -Name $Names -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    return $true
}

function Get-InstalledProgramNames {
    $names = @()
    foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        $names += Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object { "$($_.DisplayName)".Trim() }
    }
    try { $names += Get-AppxPackage -ErrorAction Stop | ForEach-Object Name } catch { }
    return @($names | Select-Object -Unique)
}
function Test-ProgramInstalled([string]$Name, [string[]]$Installed) {
    $stem = ($Name -replace '\s*[\(\[].*$', '' -replace '\s+v?\d+(\.\d+)+.*$', '' -replace '\s+(x64|x86|64-bit|32-bit)$', '').Trim()
    if ($stem.Length -lt 3) { $stem = $Name }
    foreach ($i in $Installed) { if ($i.StartsWith($stem, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

function Get-KnownFolder([string]$Name) {
    $usf = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    switch ($Name) {
        'Desktop'     { return [Environment]::GetFolderPath('Desktop') }
        'Documents'   { return [Environment]::GetFolderPath('MyDocuments') }
        'Pictures'    { return [Environment]::GetFolderPath('MyPictures') }
        'Videos'      { return [Environment]::GetFolderPath('MyVideos') }
        'Music'       { return [Environment]::GetFolderPath('MyMusic') }
        'Favorites'   { return [Environment]::GetFolderPath('Favorites') }
        'Downloads'   { $v = Get-RegValue $usf '{374DE290-123F-4565-9164-39C4925E467B}'; if ($v) { return [Environment]::ExpandEnvironmentVariables($v) }; return (Join-Path $env:USERPROFILE 'Downloads') }
        'Saved Games' { $v = Get-RegValue $usf '{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}'; if ($v) { return [Environment]::ExpandEnvironmentVariables($v) }; return (Join-Path $env:USERPROFILE 'Saved Games') }
        default       { return (Join-Path $env:USERPROFILE $Name) }
    }
}

function Convert-OldPath([string]$Path) {
    # Re-map a path from the old PC (old user name / %USERPROFILE%) to this PC.
    if (-not $Path) { return $Path }
    $p = $Path -replace '%USERPROFILE%', $env:USERPROFILE
    if ($Script:M -and $Script:M.UserProfile -and $p.StartsWith($Script:M.UserProfile, [StringComparison]::OrdinalIgnoreCase)) {
        $p = $env:USERPROFILE + $p.Substring($Script:M.UserProfile.Length)
    }
    if ($p -match '^(.*?\\(OneDrive[^\\]*\\)?Documents)(\\.*)?$' -and $p.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        $p = [Environment]::GetFolderPath('MyDocuments') + $Matches[3]
    }
    return $p
}

function Get-AppExe([string]$ExeName) {
    $v = Get-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExeName" '(default)'
    if (-not $v) { $v = Get-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExeName" '(default)' }
    if ($v) { $v = $v.Trim('"'); if (Test-Path -LiteralPath $v) { return $v } }
    foreach ($base in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) {
        if (-not $base) { continue }
        $hit = Get-ChildItem -Path $base -Filter $ExeName -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# Win32 helpers: wallpaper, mouse, cursors, display modes
function Initialize-Native {
    if ('PCSetup.Native' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
namespace PCSetup {
public static class Native {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, string vparam, uint winIni);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, IntPtr vparam, uint winIni);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, int[] vparam, uint winIni);
    public static bool SetWallpaper(string path) { return SystemParametersInfo(0x0014, 0, path, 3); }
    public static bool ReloadCursors() { return SystemParametersInfo(0x0057, 0, IntPtr.Zero, 3); }
    public static bool SetMouseSpeed(int speed) { return SystemParametersInfo(0x0071, 0, new IntPtr(speed), 3); }
    public static bool SetMouseAccel(int t1, int t2, int accel) { return SystemParametersInfo(0x0004, 0, new int[] { t1, t2, accel }, 3); }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields; public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
        public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    // Returns "device|monitor|width|height|currentHz|maxHzAtThisResolution"
    public static List<string> Displays() {
        var list = new List<string>();
        for (uint i = 0; i < 32; i++) {
            var d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(d);
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            if ((d.StateFlags & 1) == 0) continue;
            var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(cur);
            if (!EnumDisplaySettings(d.DeviceName, -1, ref cur)) continue;
            int max = cur.dmDisplayFrequency;
            for (int m = 0; m < 2000; m++) {
                var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(dm);
                if (!EnumDisplaySettings(d.DeviceName, m, ref dm)) break;
                if (dm.dmPelsWidth == cur.dmPelsWidth && dm.dmPelsHeight == cur.dmPelsHeight && dm.dmDisplayFrequency > max) max = dm.dmDisplayFrequency;
            }
            var mon = new DISPLAY_DEVICE(); mon.cb = Marshal.SizeOf(mon); string monName = "";
            if (EnumDisplayDevices(d.DeviceName, 0, ref mon, 0)) monName = mon.DeviceString;
            list.Add(d.DeviceName + "|" + monName + "|" + cur.dmPelsWidth + "|" + cur.dmPelsHeight + "|" + cur.dmDisplayFrequency + "|" + max);
        }
        return list;
    }
}
}
'@
}

# ---------------------------------------------------------------------------
# Locate backup
# ---------------------------------------------------------------------------
Clear-Host
Write-Title 'NEW PC SETUP'

$Script:B = $null
$Script:M = $null
function Find-Backup([string]$Start) {
    if (-not $Start -or -not (Test-Path -LiteralPath $Start)) { return @() }
    if (Test-Path -LiteralPath (Join-Path $Start 'manifest.json')) { return @(Get-Item -LiteralPath $Start) }
    return @(Get-ChildItem -LiteralPath $Start -Directory -Filter 'PCBackup_*' -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending)
}
$cands = @()
if ($BackupPath) { $cands = Find-Backup $BackupPath }
if (-not $cands) { $cands = Find-Backup $PSScriptRoot }
if (-not $cands) {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) { $cands += Find-Backup $d.Root }
}
if ($cands.Count -gt 1) {
    $pick = Select-Items -Items $cands -Title 'Several backups found - pick the one to restore from' -Property @('Name', 'FullName') -Single
    if ($pick) { $cands = @($pick) }
}
if (-not $cands) {
    Write-Warn2 'No backup folder (PCBackup_*) found next to this script.'
    $p = Read-Host '  Type the path to a PCBackup_* folder, or press Enter to continue WITHOUT a backup (generic setup)'
    if ($p) { $cands = Find-Backup $p.Trim('"', ' ') }
}
if ($cands) {
    $Script:B = $cands[0].FullName
    $Script:M = Read-JsonFile (Join-Path $Script:B 'manifest.json')
    if (-not $Script:M) { Write-Fail 'manifest.json could not be read - continuing in generic mode.'; $Script:B = $null }
}
$B = $Script:B; $M = $Script:M

$Script:LogDir = if ($B) { Join-Path $B 'Logs' } else { Join-Path $env:TEMP 'PCSetup' }
New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
try { Start-Transcript -Path (Join-Path $Script:LogDir ("setup-transcript-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))) -Force | Out-Null } catch { }

# Progress
$Script:ProgressFile = if ($B) { Join-Path $B "setup-progress-$env:COMPUTERNAME.json" } else { Join-Path $PSScriptRoot 'setup-progress.json' }
$Script:Progress = @{}
$pj = Read-JsonFile $Script:ProgressFile
if ($pj) { foreach ($p in $pj.PSObject.Properties) { $Script:Progress[$p.Name] = $p.Value } }
function Save-Progress { try { $Script:Progress | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:ProgressFile -Encoding UTF8 } catch { } }
function Set-Done([string]$Key) { $Script:Progress[$Key] = (Get-Date).ToString('s'); Save-Progress }
function Test-Done([string]$Key) { return $Script:Progress.ContainsKey($Key) }

# Data from the backup
$Script:WingetIds = @()
if ($B -and $M.WingetExport) {
    $ex = Read-JsonFile (Join-Path $B $M.WingetExport)
    if ($ex) {
        foreach ($s in $ex.Sources) {
            foreach ($pkg in $s.Packages) { $Script:WingetIds += [pscustomobject]@{ Id = $pkg.PackageIdentifier; Source = $s.SourceDetails.Name } }
        }
    }
}
$OldSys = $null; if ($M) { $OldSys = $M.System }

$Catalog = @(
    @{ Name = 'Mozilla Firefox';            Id = 'Mozilla.Firefox';                    Category = 'Browser' }
    @{ Name = 'Google Chrome';              Id = 'Google.Chrome';                      Category = 'Browser' }
    @{ Name = 'Brave';                      Id = 'Brave.Brave';                        Category = 'Browser' }
    @{ Name = '7-Zip';                      Id = '7zip.7zip';                          Category = 'Utility' }
    @{ Name = 'NanaZip (modern 7-Zip)';     Id = 'M2Team.NanaZip';                     Category = 'Utility' }
    @{ Name = 'Everything (file search)';   Id = 'voidtools.Everything';               Category = 'Utility' }
    @{ Name = 'PowerToys';                  Id = 'Microsoft.PowerToys';                Category = 'Utility' }
    @{ Name = 'ShareX (screenshots)';       Id = 'ShareX.ShareX';                      Category = 'Utility' }
    @{ Name = 'Notepad++';                  Id = 'Notepad++.Notepad++';                Category = 'Utility' }
    @{ Name = 'VLC media player';           Id = 'VideoLAN.VLC';                       Category = 'Media' }
    @{ Name = 'Spotify';                    Id = 'Spotify.Spotify';                    Category = 'Media' }
    @{ Name = 'OBS Studio';                 Id = 'OBSProject.OBSStudio';               Category = 'Media' }
    @{ Name = 'Discord';                    Id = 'Discord.Discord';                    Category = 'Chat' }
    @{ Name = 'Telegram';                   Id = 'Telegram.TelegramDesktop';           Category = 'Chat' }
    @{ Name = 'Zoom';                       Id = 'Zoom.Zoom';                          Category = 'Chat' }
    @{ Name = 'Steam';                      Id = 'Valve.Steam';                        Category = 'Games' }
    @{ Name = 'Epic Games Launcher';        Id = 'EpicGames.EpicGamesLauncher';        Category = 'Games' }
    @{ Name = 'Bitwarden';                  Id = 'Bitwarden.Bitwarden';                Category = 'Security' }
    @{ Name = 'KeePassXC';                  Id = 'KeePassXCTeam.KeePassXC';            Category = 'Security' }
    @{ Name = 'SumatraPDF';                 Id = 'SumatraPDF.SumatraPDF';              Category = 'Office' }
    @{ Name = 'LibreOffice';                Id = 'TheDocumentFoundation.LibreOffice';  Category = 'Office' }
    @{ Name = 'Visual Studio Code';         Id = 'Microsoft.VisualStudioCode';         Category = 'Dev' }
    @{ Name = 'Git';                        Id = 'Git.Git';                            Category = 'Dev' }
    @{ Name = '.NET Desktop Runtime 8';     Id = 'Microsoft.DotNet.DesktopRuntime.8';  Category = 'Runtime' }
    @{ Name = 'Visual C++ Redistributable'; Id = 'Microsoft.VCRedist.2015+.x64';       Category = 'Runtime' }
)

# App-specific reminders added to the guided checklist when the app was on the old PC.
$AppHints = @(
    @{ Rx = '^Discord';                Text = 'Discord: sign in; Settings > Notifications, Keybinds (mute/deafen), Voice & Video devices, Windows Settings (start with Windows)' }
    @{ Rx = '^Steam$';                 Text = 'Steam: sign in; Settings > Storage > add existing library folders; Interface > run at startup; Notifications' }
    @{ Rx = 'Epic Games Launcher';     Text = 'Epic: sign in; for games on another drive, start Install and pick the existing folder - it verifies instead of downloading' }
    @{ Rx = '^Spotify';                Text = 'Spotify: sign in; Settings > Startup behavior, audio quality, hardware acceleration' }
    @{ Rx = 'Wallpaper Engine';        Text = 'Wallpaper Engine: re-apply wallpapers (Workshop subscriptions), Settings > start with Windows, desktop icon settings' }
    @{ Rx = 'Lively Wallpaper';        Text = 'Lively Wallpaper: re-add wallpapers, start with Windows' }
    @{ Rx = 'G HUB|Logitech Gaming';   Text = 'Logitech G HUB: sign in or import profiles; DPI levels, button assignments, macros, lighting' }
    @{ Rx = 'Logi Options';            Text = 'Logi Options+: sign in to restore backups; buttons, gestures, Flow' }
    @{ Rx = 'Razer Synapse';           Text = 'Razer Synapse: sign in (profiles sync); DPI, keybinds, lighting' }
    @{ Rx = 'iCUE';                    Text = 'Corsair iCUE: import profiles; DPI, macros, lighting, fan curves' }
    @{ Rx = 'SteelSeries';             Text = 'SteelSeries GG: sign in; device settings, Sonar audio routing' }
    @{ Rx = '8BitDo';                  Text = '8BitDo Ultimate Software: controller profiles and button mapping' }
    @{ Rx = 'Wootility';               Text = 'Wootility: keyboard profiles and actuation points' }
    @{ Rx = 'Armoury Crate';           Text = 'Armoury Crate: fan profiles, lighting, device updates' }
    @{ Rx = 'NVIDIA (App|GeForce Experience|Control Panel)'; Text = 'NVIDIA: Control Panel / NVIDIA App - G-SYNC, color range (Full), power management, overlay/recording' }
    @{ Rx = 'AMD Software';            Text = 'AMD Software: FreeSync, display color, Radeon features, recording' }
    @{ Rx = 'OBS Studio';              Text = 'OBS: restore scenes (step 10), check audio sources, output encoder and paths' }
    @{ Rx = '^Microsoft (Office|365)|Microsoft 365 Apps'; Text = 'Microsoft Office: sign in to activate; Outlook accounts, signatures (step 10)' }
    @{ Rx = 'Adobe Creative Cloud';    Text = 'Adobe Creative Cloud: sign in, reinstall apps, sync settings and fonts' }
    @{ Rx = '^Zoom';                   Text = 'Zoom: sign in; audio/video devices, start with Windows' }
    @{ Rx = 'Microsoft Teams|^Teams';  Text = 'Teams: sign in; notifications, devices, auto-start' }
    @{ Rx = 'Dropbox|Google Drive|iCloud|MEGAsync|pCloud|Sync\.com'; Text = 'Cloud storage app: sign in and choose the sync folder (point it to the existing folder to avoid re-downloading)' }
    @{ Rx = 'Bitwarden|1Password|LastPass|KeePass|Dashlane|Proton Pass'; Text = 'Password manager: sign in to the desktop app and the browser extension' }
    @{ Rx = 'Riot Client|League of Legends|VALORANT'; Text = 'Riot games: install from the Riot Client; Vanguard needs a reboot; check in-game settings and keybinds' }
    @{ Rx = 'HoYoPlay|Genshin|Honkai|Zenless'; Text = 'HoYoPlay games: in HoYoPlay choose "Locate game" for installs on another drive' }
    @{ Rx = 'Battle\.net';             Text = 'Battle.net: sign in; "Locate the game" for installs on other drives' }
    @{ Rx = 'EA app|EA Desktop';       Text = 'EA app: sign in; "Locate game" for existing installs' }
    @{ Rx = 'Ubisoft Connect';         Text = 'Ubisoft Connect: sign in; "Locate installed game" for existing installs' }
    @{ Rx = 'GOG Galaxy';              Text = 'GOG Galaxy: sign in; Add games > Scan folders for GOG games' }
    @{ Rx = 'qBittorrent';             Text = 'qBittorrent: restore torrents/settings (step 10), check download folder, set as default for magnet links' }
    @{ Rx = 'Tiny Nvidia Update|TinyNvidiaUpdateChecker'; Text = 'TinyNvidiaUpdateChecker: run it to keep the NVIDIA driver updated' }
    @{ Rx = 'Edge ?Deflector|MSEdgeRedirect'; Text = 'MSEdgeRedirect: run it and check it redirects Start/Widgets links to your browser' }
    @{ Rx = 'SpotX';                   Text = 'SpotX: re-run the SpotX patch after installing Spotify' }
    @{ Rx = 'Tailscale|ZeroTier|WireGuard|OpenVPN|NordVPN|ProtonVPN|Mullvad|ExpressVPN|Surfshark'; Text = 'VPN app: sign in, check auto-connect / kill switch' }
    @{ Rx = 'Malwarebytes|Norton|McAfee|Kaspersky|Bitdefender|ESET|Avast|AVG'; Text = 'Antivirus: reinstall only if you want it (Windows Security is built in); re-enter license' }
)

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
function Step-Network {
    Write-Title 'Step 1 - Internet and network drivers'
    if (Test-Internet) { Write-Ok 'Internet works.' }
    else {
        Write-Warn2 'No internet connection.'
        try { Get-NetAdapter -ErrorAction Stop | Format-Table Name, InterfaceDescription, Status -AutoSize | Out-String | Write-Host } catch { }
        $bad = @(try { Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -ne 'OK' -and ($_.Class -eq 'Net' -or -not $_.Class) } } catch { })
        foreach ($d in $bad) { Write-Info "Device without driver: $($d.FriendlyName) [$($d.Class)]" }
        $exp = if ($B -and $M.DriverExport) { Join-Path $B $M.DriverExport } else { $null }
        if ($exp -and (Test-Path -LiteralPath $exp)) {
            if (-not $IsAdmin) { Write-Warn2 'Run as administrator to install drivers.' }
            elseif (Ask-YesNo 'Install the NETWORK drivers backed up from the old PC?' $true) {
                $infs = @(Get-ChildItem -LiteralPath $exp -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Where-Object {
                    (Get-Content -LiteralPath $_.FullName -TotalCount 80 -ErrorAction SilentlyContinue) -match '^\s*Class\s*=\s*Net\s*$' })
                Write-Info "$($infs.Count) network driver packages found."
                foreach ($inf in $infs) {
                    Write-Info "Installing $($inf.Directory.Name)..."
                    & pnputil.exe /add-driver "$($inf.FullName)" /install | Out-Null
                }
                Start-Sleep -Seconds 5
            }
        } else {
            Write-Todo 'No driver backup. Options: plug in an Ethernet cable, use USB tethering from a phone, or download the'
            Write-Info 'network driver on another computer from the motherboard / laptop maker''s support page.'
        }
    }

    $wifiDir = if ($B) { Join-Path $B 'Network\WiFi' } else { $null }
    if ($wifiDir -and (Test-Path -LiteralPath $wifiDir)) {
        $files = @(Get-ChildItem -LiteralPath $wifiDir -Filter *.xml | ForEach-Object {
            $ssid = $_.BaseName
            try { $ssid = ([xml](Get-Content -LiteralPath $_.FullName -Raw)).WLANProfile.name } catch { }
            [pscustomobject]@{ Network = $ssid; File = $_.FullName }
        })
        if ($files) {
            Write-Sub 'Saved Wi-Fi networks from the old PC'
            $sel = Confirm-Selection -Items $files -Title 'Wi-Fi networks to add to this PC' -Property @('Network') -What 'saved Wi-Fi networks to add'
            foreach ($f in $sel) {
                $out = & netsh.exe wlan add profile filename="$($f.File)" user=current 2>&1
                if ($LASTEXITCODE -eq 0) { Write-Ok "Added Wi-Fi: $($f.Network)" } else { Write-Warn2 "Wi-Fi '$($f.Network)': $out" }
            }
        }
    }
    Start-Sleep -Seconds 3
    if (Test-Internet) { Write-Ok 'Internet works.' } else { Write-Warn2 'Still no internet - fix this before the app steps.'; return $false }
    return $true
}

function Step-Updates {
    Write-Title 'Step 2 - Windows Update and activation'
    try {
        $prod = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop | Select-Object -First 1
        if ($prod.LicenseStatus -eq 1) { Write-Ok "Windows is activated ($($prod.Description))." }
        else {
            Write-Warn2 'Windows is NOT activated yet.'
            Write-Info 'It usually activates by itself once online (digital license on the same hardware / Microsoft account).'
            if ($M.License.OEMKeyInFirmware) { Write-Info "OEM key from the old install: $($M.License.OEMKeyInFirmware)" }
            if ($M.License.InstalledKeyDecoded -and $M.License.Channel -match 'RETAIL') { Write-Info "Retail key from the old install (may be generic): $($M.License.InstalledKeyDecoded)" }
            Write-Info 'Settings > System > Activation > Troubleshoot can reactivate a digital license linked to your Microsoft account.'
            if (Ask-YesNo 'Open Activation settings?' $true) { Open-Target 'ms-settings:activation' }
        }
    } catch { Write-Warn2 'Could not read activation status.' }

    Write-Sub 'Windows Update'
    Write-Todo 'Click "Check for updates", install everything, restart, and repeat until no updates are left.'
    Write-Todo 'Then Advanced options > Optional updates: install offered driver updates.'
    Write-Todo 'Microsoft Store > Library > "Get updates" (updates App Installer / winget, needed for step 4).'
    Open-Target 'ms-settings:windowsupdate'
    if (Ask-YesNo 'Open Microsoft Store updates too?' $true) { Open-Target 'ms-windows-store://downloadsandupdates' }
    Wait-Enter 'Press Enter when updates are installed (or to continue while they run)'
    if (Ask-YesNo 'Restart now and re-open this setup automatically after sign-in?' $false) {
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($B) { $cmd += " -BackupPath `"$B`"" }
        New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'PCSetupResume' -Value $cmd -PropertyType String -Force | Out-Null
        Set-Done 'updates'
        try { Stop-Transcript | Out-Null } catch { }
        Restart-Computer -Force
    }
    return $true
}

function Step-Drivers {
    Write-Title 'Step 3 - Drivers (chipset, graphics, audio, motherboard)'
    $bad = @(try { Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -in 'Error', 'Degraded', 'Unknown' } } catch { })
    if ($bad) {
        Write-Warn2 "$($bad.Count) devices have no working driver:"
        foreach ($d in $bad) { Write-Info "- $($d.FriendlyName) [$($d.Class)]" }
    } else { Write-Ok 'Device Manager reports no problem devices.' }

    # Hardware: prefer the old PC's record (same hardware), fall back to this PC.
    $cpuVendor = $null; $gpus = @(); $board = $null; $maker = $null; $model = $null
    if ($OldSys) { $cpuVendor = $OldSys.CPUVendor; $gpus = @($OldSys.GPUs | ForEach-Object Name); $board = $OldSys.Motherboard; $maker = $OldSys.Manufacturer; $model = $OldSys.Model }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bb = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if (-not $cpuVendor) { $cpuVendor = if ($cpu.Manufacturer -match 'Intel') { 'Intel' } elseif ($cpu.Manufacturer -match 'AMD') { 'AMD' } else { $cpu.Manufacturer } }
        if (-not $gpus) { $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object Name) }
        if (-not $board) { $board = "$($bb.Manufacturer) $($bb.Product)" }
        if (-not $maker) { $maker = $cs.Manufacturer; $model = $cs.Model }
        if ($OldSys -and "$($bb.Manufacturer) $($bb.Product)" -ne $OldSys.Motherboard) { Write-Warn2 "This is different hardware than the backup ($($OldSys.Motherboard)). Using this PC's hardware for links."; $board = "$($bb.Manufacturer) $($bb.Product)"; $maker = $cs.Manufacturer; $model = $cs.Model; $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object Name) }
    } catch { }

    Write-Info "CPU: $cpuVendor   Motherboard: $board   System: $maker $model"
    Write-Info "Graphics: $($gpus -join ', ')"
    $links = @()
    $isOem = $maker -match 'Dell|HP|Hewlett|Lenovo|ASUS|Acer|MSI|Microsoft|Samsung|Razer|Gigabyte|Alienware|Framework|Huawei|Toshiba|Dynabook|LG' -and $maker -notmatch 'System manufacturer|To Be Filled|Default string'
    if ($isOem) { $links += [pscustomobject]@{ What = "Support page for $maker $model (all drivers)"; Link = 'https://www.google.com/search?q=' + [uri]::EscapeDataString("$maker $model drivers support") } }
    $links += [pscustomobject]@{ What = "Motherboard support page: $board (chipset, audio, LAN, BIOS)"; Link = 'https://www.google.com/search?q=' + [uri]::EscapeDataString("$board support drivers") }
    if ($cpuVendor -eq 'AMD') { $links += [pscustomobject]@{ What = 'AMD chipset driver'; Link = 'https://www.amd.com/en/support/download/drivers.html' } }
    if ($cpuVendor -eq 'Intel') { $links += [pscustomobject]@{ What = 'Intel Driver & Support Assistant (chipset, Wi-Fi, Bluetooth, graphics)'; Link = 'https://www.intel.com/content/www/us/en/support/detect.html' } }
    foreach ($g in $gpus) {
        if ($g -match 'NVIDIA') { $links += [pscustomobject]@{ What = "NVIDIA driver / NVIDIA App ($g)"; Link = 'https://www.nvidia.com/en-us/drivers/' } }
        elseif ($g -match 'AMD|Radeon') { $links += [pscustomobject]@{ What = "AMD Software: Adrenalin ($g)"; Link = 'https://www.amd.com/en/support/download/drivers.html' } }
        elseif ($g -match 'Intel' -and $cpuVendor -ne 'Intel') { $links += [pscustomobject]@{ What = "Intel graphics ($g)"; Link = 'https://www.intel.com/content/www/us/en/support/detect.html' } }
    }
    if ($M.Hardware.AudioDevices) { Write-Info ("Audio hardware on the old PC: {0}" -f (($M.Hardware.AudioDevices | ForEach-Object Name | Select-Object -Unique) -join ', ')) }
    $sel = Confirm-Selection -Items $links -Title 'Driver download pages to open' -Property @('What') -What 'driver download pages to open in your browser'
    foreach ($l in $sel) { Open-Target $l.Link }

    $exp = if ($B -and $M.DriverExport) { Join-Path $B $M.DriverExport } else { $null }
    if ($exp -and (Test-Path -LiteralPath $exp) -and $IsAdmin) {
        Write-Sub 'Drivers backed up from the old PC'
        Write-Info 'Windows only uses these for devices where they match and are the best available driver.'
        Write-Info 'Newer drivers from the links above or Windows Update are preferred.'
        if (Ask-YesNo 'Install backed-up drivers now?' ([bool]$bad)) {
            Write-Info 'Installing (can take several minutes)...'
            & pnputil.exe /add-driver "$exp\*.inf" /subdirs /install 2>&1 | Out-File (Join-Path $Script:LogDir 'pnputil-install.log') -Encoding UTF8
            Write-Ok 'Done (details in Logs\pnputil-install.log).'
            $bad2 = @(try { Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -in 'Error', 'Degraded', 'Unknown' } } catch { })
            Write-Info "Devices still without driver: $($bad2.Count)"
        }
    }
    if (Ask-YesNo 'Open Device Manager to check?' ([bool]$bad)) { Open-Target 'devmgmt.msc' }
    return $true
}

function Initialize-Winget {
    $w = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($w) { return $true }
    Write-Info 'winget not found - trying to register App Installer...'
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { }
    Update-SessionPath
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { return $true }
    $wa = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if (Test-Path (Join-Path $wa 'winget.exe')) { $env:Path += ";$wa"; return $true }
    Write-Warn2 'winget (App Installer) is missing. Install/update "App Installer" from the Microsoft Store.'
    Open-Target 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1'
    Wait-Enter 'Press Enter after App Installer is installed/updated'
    Update-SessionPath
    return [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
}

function Step-AppsWinget {
    Write-Title 'Step 4 - Install apps with winget'
    if (-not (Test-Internet)) { Write-Warn2 'No internet - do step 1 first.'; return $false }
    if (-not (Initialize-Winget)) { return $false }
    & winget.exe source update 2>&1 | Out-Null
    Write-Info 'Checking what is already installed...'
    $prevEnc = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $installedText = (& winget.exe list --accept-source-agreements 2>&1 | Out-String)
    try { [Console]::OutputEncoding = $prevEnc } catch { }

    $rows = @()
    $seen = @{}
    foreach ($w in $Script:WingetIds) {
        if ($seen.ContainsKey($w.Id)) { continue }
        $seen[$w.Id] = $true
        $old = $null
        if ($M.Apps) { $old = $M.Apps | Where-Object { $_.WingetId -eq $w.Id } | Select-Object -First 1 }
        $name = if ($old) { $old.Name } else { $w.Id }
        $cat = if ($old) { $old.Category } else { '' }
        $inst = $installedText -match ('(?m)\s' + [regex]::Escape($w.Id) + '\s')
        $rows += [pscustomobject]@{ Name = $name; Id = $w.Id; Source = $w.Source; Category = $cat; From = 'old PC'; Installed = $inst }
    }
    foreach ($c in $Catalog) {
        if ($seen.ContainsKey($c.Id)) { continue }
        $seen[$c.Id] = $true
        $inst = $installedText -match ('(?m)\s' + [regex]::Escape($c.Id) + '\s')
        $rows += [pscustomobject]@{ Name = $c.Name; Id = $c.Id; Source = 'winget'; Category = $c.Category; From = 'suggestion'; Installed = $inst }
    }
    $todo = @($rows | Where-Object { -not $_.Installed } | Sort-Object @{ Expression = { $_.From -ne 'old PC' } }, Category, Name)
    $already = @($rows | Where-Object Installed).Count
    Write-Info ("{0} apps available ({1} from the old PC), {2} already installed." -f $todo.Count, @($todo | Where-Object From -eq 'old PC').Count, $already)
    if ($M) { Write-Info 'Tip: runtimes (.NET, Visual C++) are usually installed automatically by the apps that need them.' }
    $recommended = @($todo | Where-Object { $_.From -eq 'old PC' -and $_.Category -notin 'Runtime / framework', 'Driver / hardware' })
    $sel = Confirm-Selection -Items $todo -Default $recommended -Title 'Apps to install (from old PC first, then common suggestions)' -Property @('Name', 'Category', 'Id', 'From') -What 'apps from your old PC will be installed automatically'
    if (-not $sel) { Write-Info 'Nothing selected.'; return $true }
    $failed = @(); $ok = @()
    $n = 0
    foreach ($a in $sel) {
        $n++
        Write-Host ("  [{0}/{1}] Installing {2} ({3})..." -f $n, $sel.Count, $a.Name, $a.Id) -ForegroundColor White
        $wargs = @('install', '--id', $a.Id, '-e', '--accept-package-agreements', '--accept-source-agreements')
        if ($a.Source) { $wargs += @('--source', $a.Source) }
        & winget.exe @wargs | Out-Host
        $code = $LASTEXITCODE
        if ($code -eq 0 -or $code -eq -1978335189 -or $code -eq -1978335135) { $ok += $a.Name; Write-Ok $a.Name }
        else { $failed += $a; Write-Fail ("{0} (exit code {1})" -f $a.Name, $code) }
    }
    Update-SessionPath
    Write-Sub 'Result'
    Write-Ok "$($ok.Count) installed."
    if ($failed) {
        Write-Warn2 "$($failed.Count) failed: $(($failed | ForEach-Object Name) -join ', ')"
        $Script:Progress['wingetFailed'] = @($failed | ForEach-Object { "$($_.Name) ($($_.Id))" }); Save-Progress
        if (Ask-YesNo 'Open a web search for the failed ones?' $false) { foreach ($f in $failed) { Search-Web "$($f.Name) download" } }
    }
    return $true
}

function Step-AppsManual {
    Write-Title 'Step 5 - Apps to install by hand, peripherals, licenses'
    if (-not $M) { Write-Info 'No backup - nothing to compare. Use the checklist (step 11) for general reminders.'; return $true }
    $installed = Get-InstalledProgramNames
    $wingetIdSet = @{}; foreach ($w in $Script:WingetIds) { $wingetIdSet[$w.Id] = $true }
    $manual = @($M.Apps | Where-Object {
        $_.Category -in 'Application', 'Peripheral software', 'Game launcher', 'Game' -and
        -not ($_.WingetId -and $wingetIdSet.ContainsKey($_.WingetId)) -and
        -not (Test-ProgramInstalled $_.Name $installed)
    } | Sort-Object Category, Name)
    $page = Join-Path $B 'apps.html'
    if (Test-Path -LiteralPath $page) {
        Write-Info "$($manual.Count) programs from the old PC still need installing by hand."
        Write-Todo 'Your app list opens in the browser: click each app''s button to download it, then tick it off.'
        Open-Target $page
        Wait-Enter 'Press Enter when you are done (you can keep the page open and come back later)'
    } elseif ($manual) {
        # Older backup without apps.html: open web searches instead.
        $sel = Confirm-Selection -Items $manual -NoDefault -Title 'Programs to look up (opens a web search for each official download)' -Property @('Name', 'Publisher', 'Category') -What 'programs that need installing by hand'
        foreach ($a in $sel) { Search-Web "$($a.Name) $($a.Publisher) official download"; Start-Sleep -Milliseconds 300 }
    }
    if ($M.Hardware.Peripherals) {
        $withSw = @($M.Hardware.Peripherals | Where-Object SuggestedSoftware)
        if ($withSw) {
            Write-Sub 'Devices that need their own software'
            foreach ($p in $withSw) { Write-Info ("{0}: {1}" -f $p.Vendor, $p.SuggestedSoftware) }
            Write-Todo 'After installing, set up DPI, buttons, macros and lighting again.'
        }
    }
    if ($M.Hardware.Bluetooth) { Write-Todo ("Re-pair Bluetooth devices: {0}" -f ($M.Hardware.Bluetooth -join ', ')); if (Ask-YesNo 'Open Bluetooth settings?' $false) { Open-Target 'ms-settings:bluetooth' } }

    $games = $M.Games
    if ($games -and ($games.Steam -or $games.Epic)) {
        Write-Sub 'Game libraries'
        $libs = @($games.Steam | Group-Object Library | ForEach-Object { [pscustomobject]@{ Library = $_.Name; Games = $_.Count; Exists = (Test-Path -LiteralPath $_.Name) } })
        foreach ($l in $libs) {
            if ($l.Exists) { Write-Todo "Steam library still here: $($l.Library) ($($l.Games) games). In Steam: Settings > Storage > + Add Drive > choose this folder." }
            else { Write-Info "Steam library gone (was on the wiped drive?): $($l.Library) ($($l.Games) games) - these need re-downloading." }
        }
        foreach ($g in @($games.Epic)) { if ($g.Location -and (Test-Path -LiteralPath $g.Location)) { Write-Todo "Epic: '$($g.Name)' still at $($g.Location) - click Install and choose that folder; it verifies instead of downloading." } }
    }

    $lic = @($M.Apps | Where-Object NeedsLicense)
    if ($lic) {
        Write-Sub 'Programs that need a license key or sign-in'
        foreach ($a in $lic) { Write-Info "- $($a.Name)" }
    }
    return $true
}

$ChromiumMap = @{
    'Chrome'   = @{ Rel = 'Google\Chrome\User Data'; Base = 'Local'; Exe = 'chrome.exe'; Proc = @('chrome') }
    'Edge'     = @{ Rel = 'Microsoft\Edge\User Data'; Base = 'Local'; Exe = 'msedge.exe'; Proc = @('msedge') }
    'Brave'    = @{ Rel = 'BraveSoftware\Brave-Browser\User Data'; Base = 'Local'; Exe = 'brave.exe'; Proc = @('brave') }
    'Vivaldi'  = @{ Rel = 'Vivaldi\User Data'; Base = 'Local'; Exe = 'vivaldi.exe'; Proc = @('vivaldi') }
    'Chromium' = @{ Rel = 'Chromium\User Data'; Base = 'Local'; Exe = 'chrome.exe'; Proc = @('chrome') }
    'Opera'    = @{ Rel = 'Opera Software\Opera Stable'; Base = 'Roaming'; Exe = 'opera.exe'; Proc = @('opera') }
    'Opera GX' = @{ Rel = 'Opera Software\Opera GX Stable'; Base = 'Roaming'; Exe = 'opera.exe'; Proc = @('opera') }
    'Yandex'   = @{ Rel = 'Yandex\YandexBrowser\User Data'; Base = 'Local'; Exe = 'browser.exe'; Proc = @('browser') }
    'Thorium'  = @{ Rel = 'Thorium\User Data'; Base = 'Local'; Exe = 'thorium.exe'; Proc = @('thorium') }
}
$GeckoMap = @{
    'Firefox'     = @{ Rel = 'Mozilla\Firefox'; Exe = 'firefox.exe'; Proc = @('firefox') }
    'Waterfox'    = @{ Rel = 'Waterfox'; Exe = 'waterfox.exe'; Proc = @('waterfox') }
    'LibreWolf'   = @{ Rel = 'librewolf'; Exe = 'librewolf.exe'; Proc = @('librewolf') }
    'Floorp'      = @{ Rel = 'Floorp'; Exe = 'floorp.exe'; Proc = @('floorp') }
    'Zen'         = @{ Rel = 'zen'; Exe = 'zen.exe'; Proc = @('zen') }
    'Thunderbird' = @{ Rel = 'Thunderbird'; Exe = 'thunderbird.exe'; Proc = @('thunderbird') }
}

function Get-GeckoDefaultProfile([string]$Root) {
    $ini = Join-Path $Root 'profiles.ini'
    if (-not (Test-Path -LiteralPath $ini)) { return $null }
    $sections = @(); $cur = $null
    foreach ($line in (Get-Content -LiteralPath $ini)) {
        if ($line -match '^\[(.+)\]$') { $cur = [ordered]@{ Section = $Matches[1] }; $sections += $cur }
        elseif ($cur -and $line -match '^([^=]+)=(.*)$') { $cur[$Matches[1]] = $Matches[2] }
    }
    $rel = ($sections | Where-Object { $_.Section -like 'Install*' -and $_.Default } | Select-Object -First 1).Default
    $prof = $null
    if ($rel) { $prof = $sections | Where-Object { $_.Section -like 'Profile*' -and $_.Path -eq $rel } | Select-Object -First 1 }
    if (-not $prof) { $prof = $sections | Where-Object { $_.Section -like 'Profile*' -and $_.Default -eq '1' } | Select-Object -First 1 }
    if (-not $prof) { $prof = $sections | Where-Object { $_.Section -like 'Profile*' -and $_.Path } | Select-Object -First 1 }
    if (-not $prof) { return $null }
    if ($prof.IsRelative -eq '1') { return (Join-Path $Root ($prof.Path -replace '/', '\')) }
    return $prof.Path
}

function Restore-Chromium($bk) {
    $map = $ChromiumMap[$bk.Browser]
    $src = Join-Path $B $bk.BackupFolder
    if (-not $map) { Write-Warn2 "$($bk.Browser): automatic restore not supported. Import $src\bookmarks.html manually."; return }
    $exe = Get-AppExe $map.Exe
    $baseDir = if ($map.Base -eq 'Local') { $env:LOCALAPPDATA } else { $env:APPDATA }
    $ud = Join-Path $baseDir $map.Rel
    if (-not $exe) {
        Write-Warn2 "$($bk.Browser) is not installed. Install it (step 4) and run this again, or import the HTML file into another browser:"
        Write-Info (Join-Path $src 'bookmarks.html')
        return
    }
    if (-not (Test-Path -LiteralPath $ud)) {
        Write-Todo "$($bk.Browser) has never been started on this PC. It will open now - close it again (you can skip sign-in)."
        Open-Target '' $exe
        Wait-Enter "Press Enter after closing $($bk.Browser)"
    }
    if (-not (Stop-AppProcess $map.Proc $bk.Browser)) { return }
    $isOperaStyle = $bk.Browser -like 'Opera*'
    $targets = @()
    if ($isOperaStyle -and (Test-Path -LiteralPath (Join-Path $ud 'Preferences'))) { $targets += [pscustomobject]@{ Name = '(main profile)'; Path = $ud } }
    $ls = Read-JsonFile (Join-Path $ud 'Local State')
    foreach ($d in (Get-ChildItem -LiteralPath $ud -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
        $nm = $d.Name; try { if ($ls.profile.info_cache.($d.Name).name) { $nm = "$($ls.profile.info_cache.($d.Name).name) ($($d.Name))" } } catch { }
        $targets += [pscustomobject]@{ Name = $nm; Path = $d.FullName }
    }
    if (-not $targets) { $def = Join-Path $ud 'Default'; New-Item -ItemType Directory -Path $def -Force | Out-Null; $targets += [pscustomobject]@{ Name = 'Default'; Path = $def } }
    # Same profile folder as on the old PC if it exists, otherwise the main profile.
    $target = $targets | Where-Object { (Split-Path $_.Path -Leaf) -eq $bk.ProfileFolder } | Select-Object -First 1
    if (-not $target) { $target = $targets | Where-Object { (Split-Path $_.Path -Leaf) -eq 'Default' } | Select-Object -First 1 }
    if (-not $target) { $target = $targets[0] }
    $files = @()
    if ($bk.Files -contains 'Bookmarks') { $files += 'Bookmarks' }
    if ($bk.Files -contains 'Favicons' -and $files) { $files += 'Favicons' }
    if ($bk.Files -contains 'History' -and (Ask-YesNo "Also restore browsing history for $($bk.Browser) '$($bk.ProfileName)'? (replaces this profile's history)" $false)) { $files += @('History', 'Top Sites', 'Shortcuts') }
    if ($bk.Files -contains 'Custom Dictionary.txt') { $files += 'Custom Dictionary.txt' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($f in $files) {
        $s = Join-Path $src $f
        if (-not (Test-Path -LiteralPath $s)) { continue }
        $t = Join-Path $target.Path $f
        if (Test-Path -LiteralPath $t) { Rename-Item -LiteralPath $t -NewName "$f.before-restore-$stamp" -ErrorAction SilentlyContinue }
        foreach ($j in "$t-journal", "$t-wal", "$t-shm") { if (Test-Path -LiteralPath $j) { Remove-Item -LiteralPath $j -Force -ErrorAction SilentlyContinue } }
        Copy-Item -LiteralPath $s -Destination $t -Force
    }
    if ($bk.Files -contains 'Bookmarks') {
        Remove-Item -LiteralPath (Join-Path $target.Path 'Bookmarks.bak') -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "$($bk.Browser) '$($bk.ProfileName)' -> $($target.Name): restored $($files -join ', ')"
    Write-Info "If you sign in to sync later, the browser merges these bookmarks with your synced ones."
    if ($bk.Extensions) {
        $sel = Confirm-Selection -Items @($bk.Extensions) -Default @($bk.Extensions | Where-Object Enabled) -Title "$($bk.Browser) extensions to reinstall (opens each store page)" -Property @('Name', 'Enabled') -What "$($bk.Browser) extensions (each opens its store page - click 'Add')"
        foreach ($e in $sel) { Open-Target $e.StoreUrl $exe; Start-Sleep -Milliseconds 700 }
    }
}

function Restore-Gecko($bk) {
    $map = $GeckoMap[$bk.Browser]
    $src = Join-Path $B $bk.BackupFolder
    if (-not $map) { return }
    $exe = Get-AppExe $map.Exe
    $root = Join-Path $env:APPDATA $map.Rel
    if (-not $exe) { Write-Warn2 "$($bk.Browser) is not installed. Install it (step 4) and run this step again."; return }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'profiles.ini'))) {
        Write-Todo "$($bk.Browser) will open once to create its profile - close it again straight away."
        Open-Target '' $exe
        Wait-Enter "Press Enter after closing $($bk.Browser)"
    }
    $target = Get-GeckoDefaultProfile $root
    if (-not $target) { Write-Fail "Could not find the $($bk.Browser) profile on this PC."; return }
    Write-Host ''
    Write-Host "  Restore $($bk.Browser) profile '$($bk.ProfileName)':" -ForegroundColor White
    Write-Host '    1. Everything (bookmarks, history, passwords, extensions, settings, open tabs)  <- recommended'
    Write-Host '    2. Bookmarks and history only'
    Write-Host '    3. Saved passwords only'
    Write-Host '    4. Skip'
    $c = Read-Host '  Choose 1-4 (Enter = 1)'
    if ([string]::IsNullOrWhiteSpace($c)) { $c = '1' }
    if ($c -notin '1', '2', '3') { return }
    if (-not (Stop-AppProcess $map.Proc $bk.Browser)) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    switch ($c) {
        '1' {
            $old = "$target.before-restore-$stamp"
            Rename-Item -LiteralPath $target -NewName (Split-Path $old -Leaf) -ErrorAction Stop
            if (Invoke-Robo $src $target) { Write-Ok "$($bk.Browser): full profile restored. (Previous empty profile kept as $(Split-Path $old -Leaf))" }
            else { Write-Warn2 "$($bk.Browser): copy reported errors - see Logs\restore-robocopy.log" }
        }
        '2' { $files = @('places.sqlite', 'favicons.sqlite') }
        '3' { $files = @('logins.json', 'key4.db') }
    }
    if ($c -in '2', '3') {
        foreach ($f in $files) {
            $s = Join-Path $src $f
            if (-not (Test-Path -LiteralPath $s)) { Write-Warn2 "$f not in backup"; continue }
            $t = Join-Path $target $f
            if (Test-Path -LiteralPath $t) { Rename-Item -LiteralPath $t -NewName "$f.before-restore-$stamp" -ErrorAction SilentlyContinue }
            foreach ($j in "$t-wal", "$t-shm", "$t-journal") { if (Test-Path -LiteralPath $j) { Remove-Item -LiteralPath $j -Force -ErrorAction SilentlyContinue } }
            Copy-Item -LiteralPath $s -Destination $t -Force
        }
        Write-Ok "$($bk.Browser): restored $($files -join ', ')"
        if ($bk.Extensions -and $bk.Browser -ne 'Thunderbird') {
            $sel = Confirm-Selection -Items @($bk.Extensions) -Default @($bk.Extensions | Where-Object Enabled) -Title "$($bk.Browser) add-ons to reinstall (opens addons.mozilla.org)" -Property @('Name', 'Enabled') -What "$($bk.Browser) add-ons (each opens its add-on page - click 'Add')"
            foreach ($e in $sel) { Open-Target $e.SearchUrl $exe; Start-Sleep -Milliseconds 700 }
        }
    }
}

function Step-Browsers {
    Write-Title 'Step 6 - Browsers: bookmarks, history, profiles, extensions, passwords'
    if (-not $M -or -not $M.Browsers) {
        Write-Info 'No browser backup. Sign in to your browser to sync, or import bookmarks from an HTML file (Bookmarks > Import).'
        if (Ask-YesNo 'Open Default apps to set your browser?' $true) { Open-Target 'ms-settings:defaultapps' }
        return $true
    }
    $list = @($M.Browsers | ForEach-Object {
        $_ | Add-Member -NotePropertyName ExtCount -NotePropertyValue (@($_.Extensions).Count) -Force -PassThru |
             Add-Member -NotePropertyName Sync -NotePropertyValue $(if ($_.SignedInAs) { $_.SignedInAs } else { '' }) -Force -PassThru
    })
    Write-Info 'Tip: if a profile shows a sync account, signing in to the browser brings back passwords and settings too.'
    $mine = @($list | Where-Object IsCurrentUser); if (-not $mine) { $mine = $list }
    $sel = Confirm-Selection -Items $list -Default $mine -Title 'Browser profiles to restore' -Property @('Browser', 'ProfileName', 'User', 'Bookmarks', 'ExtCount', 'Sync') -What 'browser profiles to restore (bookmarks and more)'
    foreach ($bk in $sel) {
        Write-Sub "$($bk.Browser) - $($bk.ProfileName)"
        try { if ($bk.Engine -eq 'Chromium') { Restore-Chromium $bk } else { Restore-Gecko $bk } }
        catch { Write-Fail "$($bk.Browser): $($_.Exception.Message)" }
    }

    $pwDir = Join-Path $B 'Browsers\PasswordExports-PRIVATE'
    $csvs = @(Get-ChildItem -LiteralPath $pwDir -Filter *.csv -ErrorAction SilentlyContinue)
    if ($csvs) {
        Write-Sub 'Exported passwords'
        foreach ($f in $csvs) { Write-Info $f.FullName }
        Write-Todo 'Import the CSV in your browser or password manager:'
        Write-Info 'Chrome:  chrome://password-manager/settings  > Import passwords'
        Write-Info 'Edge:    edge://wallet/passwords  > ... next to Saved passwords > Import passwords'
        Write-Info 'Brave:   brave://password-manager/settings  > Import'
        Write-Info 'Firefox: about:logins  > ... menu > Import from a File'
        Write-Info 'Bitwarden / 1Password / KeePass: Tools / Import > "Chrome (csv)"'
        if (Ask-YesNo 'Open the folder with the CSV?' $true) { Open-Target $pwDir }
        Wait-Enter 'Press Enter when imported'
        if (Ask-YesNo 'Delete the plain-text password CSV(s) from the backup drive now?' $true) { $csvs | Remove-Item -Force; Write-Ok 'Deleted.' }
    }
    if (Ask-YesNo 'Open Default apps to set your default browser?' $true) { Open-Target 'ms-settings:defaultapps' }
    return $true
}

function Step-Files {
    Write-Title 'Step 7 - Personal files'
    $copied = @($M.UserFolders | Where-Object { $_.Copied -and $_.Backup })
    if (-not $copied) { Write-Info 'No personal files were copied into this backup.'; return $true }
    $oldUser = $M.UserName
    $rows = @()
    foreach ($f in $copied) {
        $src = Join-Path $B $f.Backup
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if ($f.Kind -eq 'Known') {
            $dest = Get-KnownFolder $f.Folder
            if ($f.User -ne $oldUser) { $dest = Join-Path $dest "From $($f.User)" }
        } elseif ($f.Kind -like '*:\ folder') { $dest = Join-Path "$env:SystemDrive\" $f.Folder }
        else { $dest = Join-Path $env:USERPROFILE $f.Folder }
        $rows += [pscustomobject]@{ Folder = "$($f.User) - $($f.Folder)"; Size = $f.Size; SizeBytes = [int64]$f.SizeBytes; RestoreTo = $dest; Source = $src }
    }
    $sel = Confirm-Selection -Items $rows -Title 'Folders to copy back onto this PC (existing files are kept; newer backup files overwrite)' -Property @('Folder', 'Size', 'RestoreTo') -What 'folders of your files to copy back'
    if (-not $sel) { return $true }
    $need = ($sel | Measure-Object SizeBytes -Sum).Sum
    $free = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free
    if ($need -gt $free * 0.95) { Write-Warn2 ("Need {0}, only {1} free on {2}." -f (Format-Size $need), (Format-Size $free), $env:SystemDrive); if (-not (Ask-YesNo 'Continue anyway?' $false)) { return $false } }
    foreach ($r in $sel) {
        Write-Info "Copying $($r.Folder) ($($r.Size)) -> $($r.RestoreTo)"
        if (Invoke-Robo $r.Source $r.RestoreTo) { Write-Ok $r.Folder } else { Write-Warn2 "$($r.Folder): some files failed (Logs\restore-robocopy.log)" }
    }
    if ($M.OutlookPST) {
        $pstSrc = Join-Path $B 'AppConfigs\Outlook-PST'
        $pstDest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Outlook Files'
        if ((Test-Path $pstSrc) -and (Ask-YesNo "Copy $(@($M.OutlookPST).Count) Outlook data file(s) to $pstDest ?" $true)) {
            [void](Invoke-Robo $pstSrc $pstDest)
            Write-Todo 'In Outlook: File > Open & Export > Open Outlook Data File, and pick the .pst files there.'
        }
    }
    return $true
}

function Set-RegistryValue([string]$Path, [string]$Name, $Value, [string]$Kind) {
    if ($Path -like 'HKU:*' -and -not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script | Out-Null }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    switch ($Kind) {
        'DWord'  { $v = [int64]$Value; if ($v -gt [int32]::MaxValue) { $v = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$v), 0) }; $Value = [int32]$v }
        'QWord'  { $Value = [int64]$Value }
        'Binary' { $Value = [Convert]::FromBase64String("$Value") }
        'MultiString' { $Value = [string[]]@($Value) }
        default  { $Value = "$Value" }
    }
    if (-not $Kind -or $Kind -eq 'Unknown') { $Kind = 'String' }
    if ($Name -eq '') { Set-Item -LiteralPath $Path -Value "$Value" -ErrorAction Stop; return }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force -ErrorAction Stop | Out-Null
}

function Step-Settings {
    Write-Title 'Step 8 - Windows settings'
    if (-not $M) { Write-Info 'No backup - use the guided checklist (step 11) to go through settings by hand.'; return $true }
    try { Initialize-Native } catch { Write-Warn2 'Native helpers unavailable - some settings apply after sign-out.' }

    # --- Registry-based settings ---
    if ($M.Settings) {
        if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { try { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script | Out-Null } catch { } }
        $diff = @()
        foreach ($t in $M.Settings) {
            $cur = $null
            try { $item = Get-Item -LiteralPath $t.Path -ErrorAction Stop; $cur = $item.GetValue($t.Name, $null, 'DoNotExpandEnvironmentNames'); if ($cur -is [byte[]]) { $cur = [Convert]::ToBase64String($cur) } } catch { }
            $old = $t.Value
            if ($t.Kind -in 'String', 'ExpandString' -and $old) { $old = Convert-OldPath "$old" }
            if ("$cur" -eq "$old") { continue }
            $diff += [pscustomobject]@{ Category = $t.Category; Setting = $t.Description; OldPC = "$old"; Now = $(if ($null -eq $cur) { '(default)' } else { "$cur" }); Path = $t.Path; Name = $t.Name; Kind = $t.Kind; Value = $old }
        }
        if ($diff) {
            Write-Info "$($diff.Count) settings differ from the old PC."
            $sel = Confirm-Selection -Items $diff -Title 'Settings to copy from the old PC (OldPC value will be applied)' -Property @('Category', 'Setting', 'OldPC', 'Now') -What 'Windows settings will be set like on your old PC'
            $applied = 0; $needExplorer = $false; $cursor = $false; $mouse = $false
            foreach ($s in $sel) {
                if ($s.Path -like 'HKLM:*' -and -not $IsAdmin) { Write-Warn2 "Needs admin: $($s.Setting)"; continue }
                if ($s.Category -eq 'Cursor' -and $s.Value -match '\.(cur|ani)$') {
                    $dest = [Environment]::ExpandEnvironmentVariables($s.Value)
                    if (-not (Test-Path -LiteralPath $dest)) {
                        $srcFile = Join-Path $B ("Settings\CursorFiles\" + (Split-Path $dest -Leaf))
                        if (Test-Path -LiteralPath $srcFile) { New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null; Copy-Item -LiteralPath $srcFile -Destination $dest -Force }
                    }
                }
                try {
                    Set-RegistryValue $s.Path $s.Name $s.Value $s.Kind
                    $applied++
                    if ($s.Category -in 'Taskbar', 'File Explorer', 'Start', 'Desktop', 'Multitasking', 'Theme') { $needExplorer = $true }
                    if ($s.Category -eq 'Cursor') { $cursor = $true }
                    if ($s.Category -eq 'Mouse') { $mouse = $true }
                } catch { Write-Warn2 "$($s.Setting): $($_.Exception.Message)" }
            }
            Write-Ok "$applied settings applied."
            try {
                if ($cursor) { [void][PCSetup.Native]::ReloadCursors() }
                if ($mouse) {
                    $ms = Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSensitivity'
                    if ($ms) { [void][PCSetup.Native]::SetMouseSpeed([int]$ms) }
                    $t1 = Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold1'; $t2 = Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold2'; $acc = Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed'
                    if ($null -ne $acc) { [void][PCSetup.Native]::SetMouseAccel([int]$t1, [int]$t2, [int]$acc) }
                }
            } catch { }
            if ($needExplorer -and (Ask-YesNo 'Restart File Explorer now so taskbar/Explorer changes show? (open Explorer windows close)' $true)) {
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
            }
            Write-Info 'Some settings (keyboard, region formats, notifications) fully apply after signing out and in.'
        } else { Write-Ok 'Registry settings already match the old PC.' }
    }

    # --- Wallpaper ---
    if ($M.Wallpaper.Saved) {
        $wpSrc = Join-Path $B $M.Wallpaper.Saved
        if ((Test-Path -LiteralPath $wpSrc) -and (Ask-YesNo 'Set the wallpaper from the old PC?' $true)) {
            $dir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Wallpapers'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $dst = Join-Path $dir ('old-pc-wallpaper' + [IO.Path]::GetExtension($wpSrc))
            Copy-Item -LiteralPath $wpSrc -Destination $dst -Force
            try { if ([PCSetup.Native]::SetWallpaper($dst)) { Write-Ok 'Wallpaper set.' } } catch { Write-Info "Set it manually: $dst" }
        }
    }

    # --- Power plan ---
    if ($M.Power.Export) {
        $pow = Join-Path $B $M.Power.Export
        $cur = "$(& powercfg.exe /getactivescheme)"
        if ((Test-Path -LiteralPath $pow) -and $cur -notmatch [regex]::Escape($M.Power.ActiveName)) {
            if (Ask-YesNo "Import and activate the old power plan '$($M.Power.ActiveName)'?" $true) {
                $out = "$(& powercfg.exe /import "$pow" 2>&1)"
                if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { & powercfg.exe /setactive $Matches[1] | Out-Null; Write-Ok "Power plan '$($M.Power.ActiveName)' active." }
                else { Write-Warn2 "powercfg: $out" }
            }
        } else { Write-Ok "Power plan: $($M.Power.ActiveName)" }
    }

    # --- Region / time / languages ---
    if ($M.Region) {
        try {
            $tz = (Get-TimeZone).Id
            if ($M.Region.TimeZone -and $tz -ne $M.Region.TimeZone -and (Ask-YesNo "Time zone is '$tz', old PC used '$($M.Region.TimeZone)'. Change it?" $true)) { Set-TimeZone -Id $M.Region.TimeZone; Write-Ok 'Time zone set.' }
            $cul = (Get-Culture).Name
            if ($M.Region.Culture -and $cul -ne $M.Region.Culture -and (Ask-YesNo "Regional format is '$cul', old PC used '$($M.Region.Culture)'. Change it?" $true)) { Set-Culture $M.Region.Culture; Write-Ok 'Regional format set (applies after sign-out).' }
            $geo = (Get-WinHomeLocation).GeoId
            if ($M.Region.HomeLocation -and $geo -ne $M.Region.HomeLocation -and (Ask-YesNo 'Set country/region like the old PC?' $true)) { Set-WinHomeLocation -GeoId $M.Region.HomeLocation }
            $curLangs = @(Get-WinUserLanguageList | ForEach-Object LanguageTag)
            $oldLangs = @($M.Region.Languages | ForEach-Object Tag)
            if ($oldLangs -and (Compare-Object $curLangs $oldLangs)) {
                Write-Info "Languages now: $($curLangs -join ', ')   old PC: $($oldLangs -join ', ')"
                if (Ask-YesNo 'Apply the old language/keyboard list?' $true) {
                    $list = New-WinUserLanguageList $oldLangs[0]
                    for ($i = 1; $i -lt $oldLangs.Count; $i++) { $list.Add($oldLangs[$i]) }
                    foreach ($l in $list) {
                        $o = $M.Region.Languages | Where-Object Tag -eq $l.LanguageTag | Select-Object -First 1
                        if ($o -and $o.Keyboards) { $l.InputMethodTips.Clear(); foreach ($k in $o.Keyboards) { $l.InputMethodTips.Add($k) } }
                    }
                    Set-WinUserLanguageList $list -Force
                    Write-Ok 'Languages/keyboards set. Display language packs may still need downloading in Settings > Time & language.'
                }
            }
        } catch { Write-Warn2 "Region: $($_.Exception.Message)" }
    }

    # --- Displays ---
    Write-Sub 'Displays (refresh rate)'
    try {
        $now = @([PCSetup.Native]::Displays() | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ Monitor = $p[1]; Width = [int]$p[2]; Height = [int]$p[3]; Hz = [int]$p[4]; MaxHz = [int]$p[5] } })
        foreach ($d in $now) {
            $old = $M.Displays | Where-Object { $_.Monitor -eq $d.Monitor } | Select-Object -First 1
            $msg = "{0}: {1}x{2} @ {3} Hz (max {4} Hz at this resolution)" -f $d.Monitor, $d.Width, $d.Height, $d.Hz, $d.MaxHz
            if ($old) { $msg += "   old PC: {0}x{1} @ {2} Hz" -f $old.Width, $old.Height, $old.RefreshHz }
            if ($d.Hz -lt $d.MaxHz -or ($old -and $old.RefreshHz -gt $d.Hz)) { Write-Todo $msg } else { Write-Ok $msg }
        }
        if ($now | Where-Object { $_.Hz -lt $_.MaxHz }) {
            Write-Info 'A monitor is below its maximum refresh rate: Settings > Display > Advanced display > Choose a refresh rate.'
            Write-Info '(If the max looks too low, install the graphics driver first - step 3.)'
            if (Ask-YesNo 'Open display settings?' $true) { Open-Target 'ms-settings:display' }
        }
    } catch { Write-Info 'Check refresh rate and scaling in Settings > Display.' }

    # --- Sound ---
    if ($M.Hardware.AudioEndpoints) {
        Write-Sub 'Sound devices used on the old PC'
        foreach ($e in $M.Hardware.AudioEndpoints) { Write-Info ("{0,-9} {1} ({2})" -f $e.Type, $e.Name, $e.Device) }
        Write-Todo 'Set default playback / recording devices, volume levels, enhancements.'
        if (Ask-YesNo 'Open Sound control panel?' $false) { Open-Target 'mmsys.cpl' }
    }

    # --- Default apps ---
    if ($M.DefaultApps) {
        Write-Sub 'Default apps on the old PC'
        $M.DefaultApps | ForEach-Object { Write-Info ("{0,-9} {1}" -f $_.Type, $_.ProgId) }
        Write-Info 'Windows does not allow scripts to change defaults - set them in Settings.'
        if (Ask-YesNo 'Open Default apps?' $false) { Open-Target 'ms-settings:defaultapps' }
    }

    # --- Start menu pins (Windows 11) ---
    $build = [int](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild')
    if ($M.Pins.Start2 -and $build -ge 22000) {
        $s2 = Join-Path $B $M.Pins.Start2
        Write-Sub 'Start menu pins'
        Write-Info 'The old Start menu pin layout can be restored. Do this AFTER installing your apps (pins for missing apps disappear).'
        if ((Test-Path -LiteralPath $s2) -and (Ask-YesNo 'Restore the old Start menu pins now?' $false)) {
            $dir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState'
            if (Test-Path $dir) {
                $t = Join-Path $dir 'start2.bin'
                if (Test-Path $t) { Copy-Item $t "$t.before-restore" -Force }
                Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
                Copy-Item -LiteralPath $s2 -Destination $t -Force
                Write-Ok 'Start pins restored (open Start to check).'
            }
        }
    }
    if ($M.Pins.Taskbar) { Write-Info ("Taskbar pins on the old PC: {0}" -f ($M.Pins.Taskbar -join ', ')) }

    # --- OneDrive ---
    $oldHadOD = [bool]($M.Apps | Where-Object { $_.Name -match '^Microsoft OneDrive' })
    $nowOD = Test-ProgramInstalled 'Microsoft OneDrive' (Get-InstalledProgramNames)
    if (-not $oldHadOD -and $nowOD) {
        Write-Sub 'OneDrive'
        Write-Info 'OneDrive was NOT installed on the old PC but is on this one.'
        Write-Info 'Uninstalling stops syncing; files already in the cloud stay there (onedrive.com).'
        if (Ask-YesNo 'Uninstall OneDrive?' $false) {
            & winget.exe uninstall --id Microsoft.OneDrive -e --accept-source-agreements 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
                foreach ($exe in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") { if (Test-Path $exe) { Start-Process $exe '/uninstall' -Wait; break } }
            }
            Write-Ok 'OneDrive uninstall started.'
        }
    }
    return $true
}

function Step-System {
    Write-Title 'Step 9 - System extras'
    if (-not $M) { Write-Info 'No backup data.'; return $true }

    # Optional features
    if ($M.OptionalFeatures -and $IsAdmin) {
        Write-Sub 'Windows optional features'
        try {
            $now = @{}
            foreach ($f in (Get-WindowsOptionalFeature -Online -ErrorAction Stop)) { $now[$f.FeatureName] = "$($f.State)" }
            $missing = @($M.OptionalFeatures | Where-Object { $now.ContainsKey($_) -and $now[$_] -ne 'Enabled' } | ForEach-Object { [pscustomobject]@{ Feature = $_ } })
            if ($missing) {
                $sel = Confirm-Selection -Items $missing -Title 'Windows features that were ON on the old PC' -Property @('Feature') -What 'Windows features to turn on (they were on before)'
                foreach ($f in $sel) {
                    try { Enable-WindowsOptionalFeature -Online -FeatureName $f.Feature -All -NoRestart -ErrorAction Stop | Out-Null; Write-Ok $f.Feature } catch { Write-Warn2 "$($f.Feature): $($_.Exception.Message)" }
                }
                if ($sel) { Write-Todo 'Restart Windows to finish enabling features.' }
            } else { Write-Ok 'Same features enabled as the old PC.' }
        } catch { Write-Warn2 'Could not read Windows features.' }
    }

    # WSL
    if ($M.WSL) {
        Write-Sub 'WSL (Linux)'
        foreach ($d in $M.WSL) { Write-Info "Old PC distro: $($d.Name) ($($d.Size))$(if ($d.Exported) { ' - exported' })" }
        & wsl.exe --status 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if (Ask-YesNo 'WSL is not set up. Install it now (needs a restart)?' $true) { & wsl.exe --install --no-distribution | Out-Host; Write-Todo 'Restart, then run this step again to import distros.' }
        } else {
            foreach ($d in @($M.WSL | Where-Object Exported)) {
                $tar = Join-Path $B $d.Exported
                if ((Test-Path -LiteralPath $tar) -and (Ask-YesNo "Import WSL distro '$($d.Name)' from the backup?" $true)) {
                    $dir = Join-Path $env:LOCALAPPDATA "WSL\$($d.Name)"
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    & wsl.exe --import $d.Name $dir $tar | Out-Host
                    if ($LASTEXITCODE -eq 0) { Write-Ok "Imported $($d.Name). (Default user may need: /etc/wsl.conf [user] default=<name>)" }
                }
            }
            foreach ($d in @($M.WSL | Where-Object { -not $_.Exported })) { Write-Info "Not exported: $($d.Name) - reinstall with: wsl --install -d <name>   (wsl --list --online shows names)" }
        }
    }

    # Fonts
    if ($M.Fonts) {
        $fdir = Join-Path $B 'Settings\Fonts'
        $files = @(Get-ChildItem -LiteralPath $fdir -File -ErrorAction SilentlyContinue | Where-Object { -not (Test-Path (Join-Path "$env:SystemRoot\Fonts" $_.Name)) -and -not (Test-Path (Join-Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" $_.Name)) })
        if ($files) {
            Write-Sub 'Fonts'
            if (Ask-YesNo "Install $($files.Count) fonts from the old PC?" $true) {
                $shell = New-Object -ComObject Shell.Application
                $ns = $shell.Namespace(0x14)
                foreach ($f in $files) { $ns.CopyHere($f.FullName, 0x14) }
                Write-Ok "$($files.Count) fonts installed."
            }
        }
    }

    # Printers
    if ($M.Printers) {
        Write-Sub 'Printers'
        $existing = @(try { Get-Printer -ErrorAction Stop | ForEach-Object Name } catch { })
        $missing = @($M.Printers | Where-Object { $existing -notcontains $_.Name })
        foreach ($p in $missing) {
            if ($p.Name -like '\\*') {
                if (Ask-YesNo "Re-connect network printer $($p.Name)?" $true) { try { Add-Printer -ConnectionName $p.Name -ErrorAction Stop; Write-Ok $p.Name } catch { Write-Warn2 "$($p.Name): $($_.Exception.Message)" } }
            } elseif ($p.IP) {
                $drv = $null; try { $drv = Get-PrinterDriver -Name $p.Driver -ErrorAction Stop } catch { }
                if ($drv -and (Ask-YesNo "Add printer '$($p.Name)' at $($p.IP)?" $true)) {
                    try {
                        $port = "IP_$($p.IP)"
                        if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) { Add-PrinterPort -Name $port -PrinterHostAddress $p.IP -ErrorAction Stop }
                        Add-Printer -Name $p.Name -DriverName $p.Driver -PortName $port -ErrorAction Stop; Write-Ok $p.Name
                    } catch { Write-Warn2 "$($p.Name): $($_.Exception.Message)" }
                } else { Write-Todo "Printer '$($p.Name)' (IP $($p.IP), driver '$($p.Driver)'): install the maker's driver/software, then add it in Settings." }
            } else { Write-Todo "Printer '$($p.Name)' (driver '$($p.Driver)', port $($p.Port)): reinstall from the maker's website or Settings > Printers." }
        }
        if ($missing -and (Ask-YesNo 'Open Printers & scanners?' $false)) { Open-Target 'ms-settings:printers' }
        if (-not $missing) { Write-Ok 'All printers present.' }
    }

    # Mapped network drives (written to HKCU so normal, non-admin Explorer sees them)
    if ($M.Network.MappedDrives) {
        Write-Sub 'Mapped network drives'
        $rows = @($M.Network.MappedDrives | Where-Object { -not (Test-Path "HKCU:\Network\$($_.Letter)") })
        $sel = Confirm-Selection -Items $rows -Title 'Network drives to map again' -Property @('Letter', 'Path') -What 'network drives to connect again'
        foreach ($d in $sel) {
            $k = "HKCU:\Network\$($d.Letter)"
            New-Item -Path $k -Force | Out-Null
            Set-ItemProperty $k RemotePath $d.Path
            Set-ItemProperty $k UserName ''
            Set-ItemProperty $k ProviderName 'Microsoft Windows Network'
            New-ItemProperty $k -Name ProviderType -Value 0x20000 -PropertyType DWord -Force | Out-Null
            New-ItemProperty $k -Name ConnectionType -Value 1 -PropertyType DWord -Force | Out-Null
            New-ItemProperty $k -Name DeferFlags -Value 4 -PropertyType DWord -Force | Out-Null
            Write-Ok "$($d.Letter): -> $($d.Path) (connects at next sign-in; Windows asks for the password if needed)"
        }
    }

    # Hosts
    if ($M.Network.HostsEntries) {
        $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
        $cur = @(Get-Content $hosts -ErrorAction SilentlyContinue)
        $rows = @($M.Network.HostsEntries | Where-Object { $cur -notcontains $_ } | ForEach-Object { [pscustomobject]@{ Entry = $_ } })
        if ($rows) {
            Write-Sub 'Hosts file'
            $sel = Confirm-Selection -Items $rows -Title 'Custom hosts-file lines to add back' -Property @('Entry') -What 'custom hosts-file lines to add back'
            if ($sel) {
                if (-not $IsAdmin) { Write-Warn2 'Needs admin.' }
                else { Add-Content -Path $hosts -Value (@('', '# restored from old PC') + @($sel | ForEach-Object Entry)) -Encoding ASCII; Write-Ok "$($sel.Count) lines added." }
            }
        }
    }

    # Static IP / DNS
    $static = @($M.Network.Adapters | Where-Object DHCP -eq 'Disabled')
    foreach ($a in $static) { Write-Todo "Old PC used a static IP on '$($a.Name)': $($a.IPv4) gateway $($a.Gateway) DNS $($a.DNS) - set it in Settings > Network if still needed." }
    $customDns = @($M.Network.Adapters | Where-Object { $_.DHCP -ne 'Disabled' -and $_.DNS -and $_.DNS -notmatch '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.|fe80|fec0)' })
    foreach ($a in $customDns) { Write-Info "DNS servers on the old PC ($($a.Name)): $($a.DNS) - set again if you chose them yourself." }
    if ($M.Network.VPN) { Write-Todo ("VPN connections to re-create: {0}" -f (($M.Network.VPN | ForEach-Object { "$($_.Name) ($($_.Server))" }) -join ', ')) }
    if ($M.Network.Proxy.Enabled -eq 1) { Write-Todo "Proxy was on: $($M.Network.Proxy.Server)" }

    # Environment variables
    $envRows = @()
    foreach ($e in $M.EnvironmentUser) {
        if ($e.Name -eq 'Path') {
            $curPath = @(([Environment]::GetEnvironmentVariable('Path', 'User')) -split ';' | Where-Object { $_ })
            foreach ($p in ($e.Value -split ';' | Where-Object { $_ })) {
                $mapped = Convert-OldPath $p
                if ($curPath -notcontains $mapped -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($mapped)))) { $envRows += [pscustomobject]@{ Variable = 'Path (add)'; Value = $mapped; Name = 'Path' } }
            }
        } else {
            $cur = [Environment]::GetEnvironmentVariable($e.Name, 'User')
            $val = Convert-OldPath $e.Value
            if ($cur -ne $val) { $envRows += [pscustomobject]@{ Variable = $e.Name; Value = $val; Name = $e.Name } }
        }
    }
    if ($envRows) {
        Write-Sub 'User environment variables'
        $sel = Confirm-Selection -Items $envRows -Title 'Environment variables / PATH entries to restore' -Property @('Variable', 'Value') -What 'environment variables to restore'
        foreach ($r in $sel) {
            if ($r.Name -eq 'Path') {
                $curP = [Environment]::GetEnvironmentVariable('Path', 'User')
                [Environment]::SetEnvironmentVariable('Path', (($curP.TrimEnd(';') + ';' + $r.Value).TrimStart(';')), 'User')
            } else { [Environment]::SetEnvironmentVariable($r.Name, $r.Value, 'User') }
            Write-Ok "$($r.Variable) = $($r.Value)"
        }
    }

    # Scheduled tasks
    $tasks = @($M.ScheduledTasks | Where-Object { $_.File })
    if ($tasks) {
        Write-Sub 'Scheduled tasks'
        $existing = @(Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object TaskName)
        $rows = @($tasks | Where-Object { $existing -notcontains $_.Name })
        $sel = Confirm-Selection -Items $rows -NoDefault -Title 'Scheduled tasks to re-create (app updaters are usually re-created by the apps)' -Property @('Name', 'Action', 'State') -What 'scheduled tasks from the old PC (apps usually re-create their own)'
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($t in $sel) {
            try {
                $xml = Get-Content -LiteralPath (Join-Path $B $t.File) -Raw
                $xml = $xml -replace 'S-1-5-21-\d+-\d+-\d+-\d+', $sid
                if ($M.UserProfile) { $xml = $xml.Replace($M.UserProfile, $env:USERPROFILE) }
                Register-ScheduledTask -Xml $xml -TaskName $t.Name -TaskPath $t.Path -Force -ErrorAction Stop | Out-Null
                Write-Ok $t.Name
            } catch { Write-Warn2 "$($t.Name): $($_.Exception.Message)" }
        }
    }

    if ($M.SavedCredentialTargets) {
        Write-Sub 'Saved logins (Windows Credential Manager) on the old PC'
        Write-Info ($M.SavedCredentialTargets -join ', ')
        Write-Info 'These are re-saved automatically the next time you sign in to each one.'
    }
    if ($M.Certificates) { Write-Info ("Personal certificates on the old PC: {0}" -f (($M.Certificates | ForEach-Object Subject) -join '; ')) }
    return $true
}

function Step-AppConfigs {
    Write-Title 'Step 10 - App settings and data'
    if (-not $M -or -not $M.AppConfigs) { Write-Info 'No app settings in the backup.'; return $true }
    Write-Info 'Install each app first (and run it once), then close it before restoring its settings.'
    $rows = @($M.AppConfigs | ForEach-Object {
        $t = if ($_.Type -eq 'Registry') { $_.Source } else { Convert-OldPath $_.Source }
        [pscustomobject]@{ Name = $_.Name; RestoreTo = $t; Type = $_.Type; Backup = $_.Backup; Sensitive = $_.Sensitive }
    })
    $sel = Confirm-Selection -Items $rows -Title 'App settings to restore (existing files are backed up as *.before-restore)' -Property @('Name', 'RestoreTo') -What 'app settings to restore'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($c in $sel) {
        $src = Join-Path $B $c.Backup
        try {
            switch ($c.Type) {
                'Registry' {
                    & reg.exe import (Join-Path $src 'settings.reg') 2>&1 | Out-Null
                    Write-Ok $c.Name
                }
                'Folder' {
                    if ($c.Name -eq 'Sticky Notes') { Stop-Process -Name 'Microsoft.Notes' -Force -ErrorAction SilentlyContinue }
                    if ($c.Name -like 'Logitech G HUB*') { [void](Stop-AppProcess @('lghub', 'lghub_agent', 'lghub_updater', 'lghub_system_tray') 'Logitech G HUB') }
                    if ($c.Name -like 'OBS*') { [void](Stop-AppProcess @('obs64') 'OBS') }
                    if ($c.Name -like 'Discord*') { [void](Stop-AppProcess @('Discord') 'Discord') }
                    if (Test-Path -LiteralPath $c.RestoreTo) {
                        $bak = "$($c.RestoreTo).before-restore-$stamp"
                        [void](Invoke-Robo $c.RestoreTo $bak)
                    }
                    if (Invoke-Robo $src $c.RestoreTo) { Write-Ok "$($c.Name) -> $($c.RestoreTo)" } else { Write-Warn2 "$($c.Name): copy errors" }
                    if ($c.Name -like 'SSH*') {
                        & icacls.exe $c.RestoreTo /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" /grant:r 'SYSTEM:(OI)(CI)F' /grant:r '*S-1-5-32-544:(OI)(CI)F' /T 2>&1 | Out-Null
                        Write-Info 'SSH folder permissions locked to your account (required by OpenSSH).'
                    }
                }
                'File' {
                    $f = Get-ChildItem -LiteralPath $src -File | Select-Object -First 1
                    if ($f) {
                        if (Test-Path -LiteralPath $c.RestoreTo) { Copy-Item -LiteralPath $c.RestoreTo "$($c.RestoreTo).before-restore-$stamp" -Force }
                        else { New-Item -ItemType Directory -Path (Split-Path $c.RestoreTo) -Force | Out-Null }
                        Copy-Item -LiteralPath $f.FullName -Destination $c.RestoreTo -Force
                        Write-Ok "$($c.Name) -> $($c.RestoreTo)"
                    }
                }
            }
        } catch { Write-Warn2 "$($c.Name): $($_.Exception.Message)" }
    }
    Update-SessionPath
    foreach ($cli in 'code', 'cursor') {
        $list = Join-Path $B "AppConfigs\$cli-extensions.txt"
        if (-not (Test-Path $list)) { continue }
        $cmd = Get-Command "$cli.cmd" -ErrorAction SilentlyContinue
        if (-not $cmd) { Write-Info "$cli extension list saved, but '$cli' is not installed yet."; continue }
        $exts = @(Get-Content $list | Where-Object { $_ })
        $already = @(& $cmd.Source --list-extensions 2>$null)
        $todo = @($exts | Where-Object { $already -notcontains $_ } | ForEach-Object { [pscustomobject]@{ Extension = $_ } })
        $s2 = Confirm-Selection -Items $todo -Title "$cli extensions to install" -Property @('Extension') -What "$cli extensions to install"
        foreach ($e in $s2) { & $cmd.Source --install-extension $e.Extension 2>&1 | Out-Null; Write-Ok $e.Extension }
    }
    return $true
}

function Get-ChecklistItems {
    $items = @()
    $file = Join-Path $PSScriptRoot 'checklist.txt'
    $section = 'General'
    if (Test-Path -LiteralPath $file) {
        foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
            $l = $line.Trim()
            if (-not $l) { continue }
            if ($l -match '^##\s*(.+)$') { $section = $Matches[1].Trim(); continue }
            if ($l.StartsWith('#')) { continue }
            $text = $l; $link = $null
            if ($l -match '^(.*?)\s+\|\s+(.+)$') { $text = $Matches[1].Trim(); $link = $Matches[2].Trim() }
            $items += [pscustomobject]@{ Section = $section; Text = $text; Link = $link }
        }
    } else { Write-Warn2 'checklist.txt not found next to the script - only app reminders will be shown.' }
    if ($M -and $M.Apps) {
        $names = @($M.Apps | ForEach-Object Name) + @($M.StoreApps | ForEach-Object Name)
        foreach ($h in $AppHints) {
            if ($names | Where-Object { $_ -match $h.Rx } | Select-Object -First 1) { $items += [pscustomobject]@{ Section = 'Your apps (found on the old PC)'; Text = $h.Text; Link = $null } }
        }
        foreach ($brw in @($M.Browsers | Where-Object { $_.Extensions -and $_.IsCurrentUser })) {
            $names2 = @($brw.Extensions | Where-Object Enabled | ForEach-Object Name)
            if ($names2) { $items += [pscustomobject]@{ Section = 'Your apps (found on the old PC)'; Text = ("{0} extensions: {1}" -f $brw.Browser, ($names2 -join ', ')); Link = $null } }
        }
    }
    return $items
}

function Step-Checklist {
    Write-Title 'Step 11 - Guided checklist'
    $items = @(Get-ChecklistItems)
    if (-not $items) { return $true }
    $open = @($items | Where-Object { -not (Test-Done ('chk:' + $_.Text)) })
    Write-Info ("{0} items, {1} still open. Keys:  Enter = done   O = open the setting/link   S = skip for now   B = back to menu" -f $items.Count, $open.Count)
    $lastSection = ''
    $i = 0
    foreach ($it in $open) {
        $i++
        if ($it.Section -ne $lastSection) { Write-Sub $it.Section; $lastSection = $it.Section }
        while ($true) {
            $hint = if ($it.Link) { ' [O]' } else { '' }
            Write-Host ("  ({0}/{1}) {2}{3}" -f $i, $open.Count, $it.Text, $hint) -ForegroundColor White
            $k = Read-Host '        Enter/O/S/B'
            if ($k -match '^[oO]$') { if ($it.Link) { Open-Target $it.Link } else { Write-Info 'Nothing to open for this item.' }; continue }
            if ($k -match '^[sS]$') { break }
            if ($k -match '^[bB]$') { return $false }
            Set-Done ('chk:' + $it.Text); break
        }
    }
    Write-Ok 'Checklist finished.'
    return $true
}

function Step-Finish {
    Write-Title 'Step 12 - Final checks and clean-up'
    try {
        $prod = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop | Select-Object -First 1
        if ($prod.LicenseStatus -eq 1) { Write-Ok 'Windows is activated.' } else { Write-Warn2 'Windows is not activated (Settings > System > Activation).' }
    } catch { }
    $bad = @(try { Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -in 'Error', 'Degraded', 'Unknown' } } catch { })
    if ($bad) { Write-Warn2 ("Devices without driver: {0}" -f (($bad | ForEach-Object FriendlyName) -join ', ')) } else { Write-Ok 'All devices have drivers.' }
    if ($Script:Progress['wingetFailed']) { Write-Warn2 ("Apps that failed to install earlier: {0}" -f ($Script:Progress['wingetFailed'] -join ', ')) }
    $notDone = @($Steps | Where-Object { $_.Id -ne 'finish' -and -not (Test-Done $_.Id) })
    if ($notDone) { Write-Info ("Steps not marked done: {0}" -f (($notDone | ForEach-Object Title) -join ', ')) }
    Write-Todo 'Run Windows Update once more (drivers and apps can pull in new updates).'
    if ($M.BitLocker | Where-Object { $_.Protection -eq 'On' }) { Write-Todo 'The old PC used BitLocker. Turn on Device encryption / BitLocker again and save the new recovery key (Microsoft account or printout).' }

    if ($IsAdmin -and (Ask-YesNo 'Turn on System Protection for C: and create a restore point "Clean setup"?' $true)) {
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
            Checkpoint-Computer -Description 'Clean setup after reinstall' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Write-Ok 'Restore point created.'
        } catch { Write-Warn2 "Restore point: $($_.Exception.Message)" }
    }

    if ($B) {
        $private = @()
        foreach ($rel in 'Network\WiFi', 'Browsers\PasswordExports-PRIVATE', 'System\BitLocker-RecoveryKeys-PRIVATE.txt') {
            $p = Join-Path $B $rel
            if (Test-Path -LiteralPath $p) { $private += [pscustomobject]@{ Item = $rel; Path = $p } }
        }
        foreach ($brw in @($M.Browsers | Where-Object Engine -eq 'Gecko')) { $p = Join-Path $B $brw.BackupFolder; if (Test-Path -LiteralPath $p) { $private += [pscustomobject]@{ Item = "$($brw.BackupFolder) (saved logins inside)"; Path = $p } } }
        if ($private) {
            Write-Sub 'Private data on the backup drive'
            Write-Info 'These contain passwords / keys in readable form. Delete them once everything works, or keep the drive somewhere safe.'
            $sel = Confirm-Selection -Items $private -NoDefault -Title 'Private items to DELETE from the backup drive now (cannot be undone)' -Property @('Item') -What 'private items on the backup drive you can delete'
            foreach ($s in $sel) { Remove-Item -LiteralPath $s.Path -Recurse -Force -ErrorAction SilentlyContinue; Write-Ok "Deleted $($s.Item)" }
        }
    }
    $summary = Join-Path $Script:LogDir ("setup-summary-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
    $lines = @("Setup summary for $env:COMPUTERNAME - $(Get-Date)", '')
    foreach ($s in $Steps) { $lines += ("[{0}] {1}" -f $(if (Test-Done $s.Id) { 'x' } else { ' ' }), $s.Title) }
    if ($Script:Progress['wingetFailed']) { $lines += ''; $lines += 'Failed app installs:'; $lines += $Script:Progress['wingetFailed'] }
    $lines | Set-Content -Path $summary -Encoding UTF8
    Write-Ok "Summary saved: $summary"
    Write-Host ''
    Write-Host '  All done. Enjoy the fresh install!' -ForegroundColor Green
    return $true
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
$Steps = @(
    @{ Id = 'network';    Title = 'Internet and network drivers';        Run = { Step-Network } }
    @{ Id = 'updates';    Title = 'Windows Update and activation';       Run = { Step-Updates } }
    @{ Id = 'drivers';    Title = 'Drivers (chipset, GPU, audio...)';    Run = { Step-Drivers } }
    @{ Id = 'winget';     Title = 'Install apps (automatic, winget)';    Run = { Step-AppsWinget } }
    @{ Id = 'manual';     Title = 'Apps to install by hand, peripherals, licenses'; Run = { Step-AppsManual } }
    @{ Id = 'browsers';   Title = 'Browsers: bookmarks, profiles, extensions, passwords'; Run = { Step-Browsers } }
    @{ Id = 'files';      Title = 'Personal files';                      Run = { Step-Files } }
    @{ Id = 'settings';   Title = 'Windows settings';                    Run = { Step-Settings } }
    @{ Id = 'system';     Title = 'System extras (features, fonts, printers, drives...)'; Run = { Step-System } }
    @{ Id = 'appconfigs'; Title = 'App settings (VS Code, SSH, OBS, signatures...)'; Run = { Step-AppConfigs } }
    @{ Id = 'checklist';  Title = 'Guided checklist';                    Run = { Step-Checklist } }
    @{ Id = 'finish';     Title = 'Finish: final checks and clean-up';   Run = { Step-Finish } }
)

function Invoke-SetupStep($s) {
    $ok = $false
    try { $ok = & $s.Run } catch { Write-Fail "$($s.Title): $($_.Exception.Message)"; $ok = $false }
    if ($ok -is [array]) { $ok = $ok[-1] }
    if ($ok) { Set-Done $s.Id }
    return [bool]$ok
}

try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'PCSetupResume' -ErrorAction SilentlyContinue } catch { }

while ($true) {
    Clear-Host
    Write-Title 'NEW PC SETUP'
    if ($B) {
        Write-Host ("  Backup: {0}" -f $B) -ForegroundColor Gray
        Write-Host ("  From:   {0} ({1} {2}), saved {3}" -f $M.ComputerName, $OldSys.Manufacturer, $OldSys.Model, $M.Created) -ForegroundColor Gray
    } else { Write-Host '  No backup loaded - generic setup.' -ForegroundColor Yellow }
    Write-Host ("  Admin:  {0}" -f $(if ($IsAdmin) { 'yes' } else { 'NO (some steps limited)' })) -ForegroundColor Gray
    Write-Host ''
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $s = $Steps[$i]
        $mark = if (Test-Done $s.Id) { '[done]' } else { '[    ]' }
        $color = if (Test-Done $s.Id) { 'DarkGray' } else { 'White' }
        Write-Host ("   {0,2}. {1} {2}" -f ($i + 1), $mark, $s.Title) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host '    Enter = continue setup (runs the remaining steps in order - recommended)' -ForegroundColor Cyan
    Write-Host '    R. Open the old PC report     L. Open the app download list'
    Write-Host '    Q. Quit (progress is saved)'
    Write-Host ''
    $c = Read-Host '  Press Enter, or type a step number (R = report, Q = quit)'
    if ([string]::IsNullOrWhiteSpace($c)) { $c = 'A' }
    if ($c -match '^[qQ]$') { break }
    if ($c -match '^[rR]$') { if ($B) { Open-Target (Join-Path $B 'report.html') }; continue }
    if ($c -match '^[lL]$') { if ($B -and (Test-Path (Join-Path $B 'apps.html'))) { Open-Target (Join-Path $B 'apps.html') }; continue }
    if ($c -match '^[aA]$') {
        foreach ($s in $Steps) {
            if (Test-Done $s.Id) { continue }
            $ok = Invoke-SetupStep $s
            if (-not $ok) {
                Write-Warn2 "Step '$($s.Title)' did not finish."
                if (-not (Ask-YesNo 'Continue with the next step?' $true)) { break }
            } else { Write-Host ''; Wait-Enter 'Step done - press Enter for the next one' }
        }
        Wait-Enter 'Press Enter to return to the menu'
        continue
    }
    if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $Steps.Count) {
        [void](Invoke-SetupStep $Steps[[int]$c - 1])
        Write-Host ''
        Wait-Enter 'Press Enter to return to the menu'
    }
}
try { Stop-Transcript | Out-Null } catch { }
