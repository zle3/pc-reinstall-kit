<#
.SYNOPSIS
    Inventories and backs up an old / broken Windows install before a reinstall.

.DESCRIPTION
    Run this ON THE OLD PC, ideally from a USB drive or external disk.
    It creates a folder  PCBackup_<COMPUTER>_<date>  next to this script (or in -OutputPath) with:
      - report.html        human readable report (apps, drivers, settings, licenses, warnings)
      - CHECKLIST.txt      things to do BEFORE wiping the drive
      - manifest.json      machine readable data used by Setup-NewPC.ps1
      - Apps\              installed programs (CSV), Store apps, winget export
      - Drivers\           third party driver export (gets network working after reinstall)
      - Network\           Wi-Fi profiles, IP/DNS, hosts file, mapped drives, VPN, printers
      - Settings\          Windows settings, power plan, wallpaper, scheduled tasks, fonts ...
      - Browsers\          bookmarks (+ HTML export), history, extension lists, Firefox/Thunderbird profiles
      - AppConfigs\        config of common apps (VS Code, SSH, Outlook signatures, OBS ...)
      - UserFiles\         copies of Desktop / Documents / Pictures ... (optional)

    Every section is independent: if part of Windows is corrupted, that section is
    logged as failed and the rest still runs.

.PARAMETER OutputPath
    Folder to write the backup into. Default: the folder this script is in.
    Must NOT be on the drive that will be wiped.

.PARAMETER Unattended
    Do not ask questions; use defaults (no user file copy, no WSL export).

.EXAMPLE
    Right-click 1-BACKUP-OLD-PC.bat > Run as administrator
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$Unattended,
    [switch]$NoElevate
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '1.0'

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

$IsAdmin = Test-IsAdmin
if (-not $IsAdmin -and -not $NoElevate) {
    Write-Host 'Requesting administrator rights (needed for drivers, Wi-Fi passwords, BitLocker keys, other users)...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-NoElevate')
    if ($OutputPath) { $argList += @('-OutputPath', "`"$OutputPath`"") }
    if ($Unattended) { $argList += '-Unattended' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        exit
    } catch {
        Write-Host 'Elevation was declined. Continuing WITHOUT admin rights (some sections will be skipped).' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------
$Script:Warnings = New-Object System.Collections.ArrayList
$Script:Errors = New-Object System.Collections.ArrayList
$Script:StepNo = 0
$Script:StepTotal = 10

function Write-Section([string]$Text) {
    $Script:StepNo++
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $Script:StepNo, $Script:StepTotal, $Text) -ForegroundColor Cyan
    Write-Host ('-' * 70) -ForegroundColor DarkCyan
}
function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "         $Text" -ForegroundColor Gray }
function Write-Warn2([string]$Text) {
    Write-Host "  [WARN] $Text" -ForegroundColor Yellow
    [void]$Script:Warnings.Add($Text)
}
function Write-Fail([string]$Text) {
    Write-Host "  [FAIL] $Text" -ForegroundColor Red
    [void]$Script:Errors.Add($Text)
}

function Ask-YesNo([string]$Question, [bool]$Default = $true) {
    if ($Unattended) { return $Default }
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = Read-Host "  $Question $suffix"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        switch -Regex ($a.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
        }
    }
}

function Invoke-Step([string]$Name, [scriptblock]$Block) {
    try { & $Block }
    catch {
        Write-Fail "$Name failed: $($_.Exception.Message)"
        Add-Content -Path $Script:ErrLog -Value ("[{0}] {1}: {2}`r`n{3}`r`n" -f (Get-Date), $Name, $_.Exception.Message, $_.ScriptStackTrace) -ErrorAction SilentlyContinue
    }
}

function Save-Json($Object, [string]$Path) {
    $Object | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Read-JsonFile([string]$Path) {
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DirSize([string]$Path) {
    # Fast recursive size that skips junctions and keeps going on access errors.
    $total = [int64]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo($d)
            foreach ($f in $di.EnumerateFiles()) { $total += $f.Length }
            foreach ($s in $di.EnumerateDirectories()) {
                if (-not ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) }
            }
        } catch { }
    }
    return $total
}

function Get-SafeName([string]$Name) {
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Name.ToCharArray()) { if ($invalid -contains $c) { [void]$sb.Append('_') } else { [void]$sb.Append($c) } }
    return $sb.ToString().Trim()
}

function Invoke-Robo([string]$Source, [string]$Dest, [string[]]$Extra = @()) {
    $roboArgs = @($Source, $Dest, '/E', '/R:1', '/W:1', '/XJ', '/MT:16', '/NP', '/NFL', '/NDL', "/LOG+:$Script:RoboLog") + $Extra
    & robocopy.exe @roboArgs | Out-Null
    return ($LASTEXITCODE -lt 8)
}

function Select-FromList {
    # Console multi-select. Enter = the -Default items. Returns the chosen items.
    param([object[]]$Items, [scriptblock]$Label, [string]$Prompt = 'Enter numbers (e.g. 1,3,5-7), A = all, Enter = none', [object[]]$Default = @())
    if (-not $Items -or $Items.Count -eq 0) { return @() }
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("   {0,3}. {1}" -f ($i + 1), (& $Label $Items[$i])) }
    if ($Unattended) { return @() }
    $a = Read-Host "  $Prompt"
    if ([string]::IsNullOrWhiteSpace($a)) { return @($Default) }
    if ($a.Trim() -match '^(n|no|none)$') { return @() }
    if ($a.Trim() -match '^(a|all)$') { return $Items }
    $picked = @()
    foreach ($part in ($a -split '[,; ]+')) {
        if ($part -match '^(\d+)-(\d+)$') { $from = [int]$Matches[1]; $to = [int]$Matches[2]; for ($n = $from; $n -le $to; $n++) { if ($n -ge 1 -and $n -le $Items.Count) { $picked += $Items[$n - 1] } } }
        elseif ($part -match '^\d+$') { $n = [int]$part; if ($n -ge 1 -and $n -le $Items.Count) { $picked += $Items[$n - 1] } }
    }
    return $picked
}

function Get-RegValue([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

# ---------------------------------------------------------------------------
# Display info (resolution / refresh rate per monitor) via user32
# ---------------------------------------------------------------------------
function Get-DisplayModes {
    if (-not ('PCMig.DisplayInfo' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
namespace PCMig {
public static class DisplayInfo {
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
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    public static List<string> Get() {
        var list = new List<string>();
        for (uint i = 0; i < 32; i++) {
            var d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(d);
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            if ((d.StateFlags & 1) == 0) continue;
            var m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(m);
            if (!EnumDisplaySettings(d.DeviceName, -1, ref m)) continue;
            var mon = new DISPLAY_DEVICE(); mon.cb = Marshal.SizeOf(mon); string monName = "";
            if (EnumDisplayDevices(d.DeviceName, 0, ref mon, 0)) monName = mon.DeviceString;
            list.Add(d.DeviceName + "|" + monName + "|" + d.DeviceString + "|" + m.dmPelsWidth + "|" + m.dmPelsHeight + "|" +
                     m.dmDisplayFrequency + "|" + m.dmBitsPerPel + "|" + ((d.StateFlags & 4) != 0) + "|" + m.dmPositionX + "|" + m.dmPositionY);
        }
        return list;
    }
}
}
'@
    }
    $out = @()
    foreach ($line in [PCMig.DisplayInfo]::Get()) {
        $p = $line -split '\|'
        $out += [pscustomobject]@{
            Device = $p[0]; Monitor = $p[1]; Adapter = $p[2]
            Width = [int]$p[3]; Height = [int]$p[4]; RefreshHz = [int]$p[5]; BitsPerPixel = [int]$p[6]
            Primary = ($p[7] -eq 'True'); PosX = [int]$p[8]; PosY = [int]$p[9]
        }
    }
    return $out
}

function Get-KeyFromDigitalProductId([byte[]]$Id) {
    # Classic Windows 8+ product key decode. On digitally licensed PCs this is often a generic key.
    if (-not $Id -or $Id.Length -lt 67) { return $null }
    $key = New-Object byte[] 15
    [Array]::Copy($Id, 52, $key, 0, 15)
    $isWin8 = [int]([math]::Floor($key[14] / 6)) -band 1
    $key[14] = [byte](($key[14] -band 0xF7) -bor (($isWin8 -band 2) * 4))
    $chars = 'BCDFGHJKMPQRTVWXY2346789'
    $out = ''
    $last = 0
    for ($i = 24; $i -ge 0; $i--) {
        $cur = 0
        for ($j = 14; $j -ge 0; $j--) {
            $cur = $cur * 256 + $key[$j]
            $key[$j] = [byte][math]::Floor($cur / 24)
            $cur = $cur % 24
        }
        $out = "$($chars[$cur])" + $out
        $last = $cur
    }
    if ($isWin8 -eq 1) {
        $rest = $out.Substring(1)
        if ($last -eq 0) { $out = 'N' + $rest }
        else {
            $part = $out.Substring(1, $last)
            $idx = $rest.IndexOf($part)
            $out = $rest.Substring(0, $idx) + $part + 'N' + $rest.Substring($idx + $part.Length)
        }
    }
    return ($out.Substring(0, 5) + '-' + $out.Substring(5, 5) + '-' + $out.Substring(10, 5) + '-' + $out.Substring(15, 5) + '-' + $out.Substring(20, 5))
}

# ---------------------------------------------------------------------------
# Output location
# ---------------------------------------------------------------------------
Clear-Host
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host '  OLD PC BACKUP & INVENTORY  (before reinstalling Windows)' -ForegroundColor Cyan
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host "  Computer : $env:COMPUTERNAME"
Write-Host "  User     : $env:USERNAME   ($env:USERPROFILE)"
Write-Host ("  Admin    : {0}" -f $(if ($IsAdmin) { 'yes' } else { 'NO - limited backup' }))
Write-Host ''

if (-not $OutputPath) { $OutputPath = $PSScriptRoot }
if (-not $OutputPath) { $OutputPath = (Get-Location).Path }

function Get-OtherDrives {
    try {
        Get-CimInstance Win32_LogicalDisk -ErrorAction Stop |
            Where-Object { $_.DriveType -in 2, 3, 4 -and $_.DeviceID -ne $env:SystemDrive -and $_.FreeSpace } |
            ForEach-Object { '{0}  {1,-20} free {2}' -f $_.DeviceID, $_.VolumeName, (Format-Size $_.FreeSpace) }
    } catch { }
}

while ($true) {
    $qual = $null
    try { $qual = Split-Path -Path $OutputPath -Qualifier -ErrorAction Stop } catch { }
    if ($qual -and $qual -ieq $env:SystemDrive) {
        Write-Host ''
        Write-Host "  WARNING: The backup location ($OutputPath) is on $env:SystemDrive - the drive Windows is installed on." -ForegroundColor Red
        Write-Host '  Reinstalling Windows will most likely ERASE it. Use a USB stick / external drive / other disk.' -ForegroundColor Red
        Write-Host '  Other drives found:' -ForegroundColor Yellow
        Get-OtherDrives | ForEach-Object { Write-Host "     $_" }
        if ($Unattended) { Write-Host '  (Unattended: continuing anyway - copy the folder off this drive afterwards!)' -ForegroundColor Yellow; break }
        $new = Read-Host '  Type a different folder (e.g. E:\) or press Enter to continue anyway'
        if ([string]::IsNullOrWhiteSpace($new)) { [void]$Script:Warnings.Add("Backup was saved on the system drive ($OutputPath). Copy it to another drive before reinstalling!"); break }
        $OutputPath = $new.Trim('"', ' ')
        continue
    }
    break
}

if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$B = Join-Path $OutputPath ("PCBackup_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd_HHmm'))
$Dirs = @{}
foreach ($d in 'Apps', 'Drivers', 'Network', 'Settings', 'Browsers', 'AppConfigs', 'UserFiles', 'Logs', 'System') {
    $Dirs[$d] = Join-Path $B $d
    New-Item -ItemType Directory -Path $Dirs[$d] -Force | Out-Null
}
$Script:ErrLog = Join-Path $Dirs.Logs 'errors.log'
$Script:RoboLog = Join-Path $Dirs.Logs 'robocopy.log'
try { Start-Transcript -Path (Join-Path $Dirs.Logs 'backup-transcript.txt') -Force | Out-Null } catch { }

Write-Host "  Backup folder: $B" -ForegroundColor Green

$M = [ordered]@{
    ScriptVersion = $ScriptVersion
    Created       = (Get-Date).ToString('s')
    ComputerName  = $env:COMPUTERNAME
    UserName      = $env:USERNAME
    UserProfile   = $env:USERPROFILE
    RanAsAdmin    = $IsAdmin
}

# ---------------------------------------------------------------------------
# Close browsers / mail apps so their files can be copied
# ---------------------------------------------------------------------------
$lockApps = @{ chrome = 'Chrome'; msedge = 'Edge'; brave = 'Brave'; vivaldi = 'Vivaldi'; opera = 'Opera'; firefox = 'Firefox'; thunderbird = 'Thunderbird'; outlook = 'Outlook'; Code = 'VS Code'; obs64 = 'OBS' }
$running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $lockApps.ContainsKey($_.ProcessName) } | Select-Object -ExpandProperty ProcessName -Unique
if ($running) {
    Write-Host ''
    Write-Host ("  These apps are running and lock files that need to be copied: {0}" -f (($running | ForEach-Object { $lockApps[$_] }) -join ', ')) -ForegroundColor Yellow
    if (Ask-YesNo 'Close them now? (save any open work first)' (-not $Unattended)) {
        foreach ($pn in $running) {
            Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object { try { [void]$_.CloseMainWindow() } catch { } }
        }
        Start-Sleep -Seconds 5
        foreach ($pn in $running) { Get-Process -Name $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        Write-Ok 'Closed.'
    }
}

# ---------------------------------------------------------------------------
# 1. System information
# ---------------------------------------------------------------------------
Write-Section 'System information'
Invoke-Step 'System info' {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $bb = Get-CimInstance Win32_BaseBoard
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $productName = $cv.ProductName
    if ([int]$cv.CurrentBuild -ge 22000) { $productName = $productName -replace 'Windows 10', 'Windows 11' }

    $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; DriverVersion = $_.DriverVersion; VRAM = $(if ($_.AdapterRAM) { Format-Size ([double][uint32]$_.AdapterRAM) } else { '' }) }
    })
    $disks = @()
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Model = $_.FriendlyName; Type = "$($_.MediaType) $($_.BusType)"; Size = Format-Size $_.Size; Health = "$($_.HealthStatus)" } })
    } catch {
        $disks = @(Get-CimInstance Win32_DiskDrive | ForEach-Object { [pscustomobject]@{ Model = $_.Model; Type = $_.InterfaceType; Size = Format-Size $_.Size; Health = $_.Status } })
    }
    $vols = @(Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -in 2, 3 } | ForEach-Object {
        [pscustomobject]@{
            Drive = $_.DeviceID; Label = $_.VolumeName; FileSystem = $_.FileSystem
            Size = Format-Size $_.Size; Free = Format-Size $_.FreeSpace
            Note = $(if ($_.DeviceID -eq $env:SystemDrive) { 'WINDOWS - will be wiped by a clean install' } elseif ($_.DriveType -eq 2) { 'Removable' } else { 'Data drive - keep this partition when reinstalling' })
        }
    })

    $M.System = [ordered]@{
        Manufacturer  = $cs.Manufacturer
        Model         = $cs.Model
        SerialNumber  = $bios.SerialNumber
        Motherboard   = "$($bb.Manufacturer) $($bb.Product)"
        BIOS          = "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"
        CPU           = $cpu.Name.Trim()
        CPUVendor     = $(if ($cpu.Manufacturer -match 'Intel') { 'Intel' } elseif ($cpu.Manufacturer -match 'AMD') { 'AMD' } else { $cpu.Manufacturer })
        RAM           = Format-Size $cs.TotalPhysicalMemory
        OS            = $productName
        Edition       = $cv.EditionID
        Version       = $cv.DisplayVersion
        Build         = "$($cv.CurrentBuild).$($cv.UBR)"
        Architecture  = $os.OSArchitecture
        InstallDate   = $os.InstallDate.ToString('s')
        LastBoot      = $os.LastBootUpTime.ToString('s')
        GPUs          = $gpus
        Disks         = $disks
        Volumes       = $vols
        FirmwareType  = $(try { if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType -eq 2) { 'UEFI' } else { 'Legacy BIOS' } } catch { 'Unknown' })
        SecureBoot    = $(try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { 'Unknown' })
        TPM           = $(try { $t = Get-Tpm -ErrorAction Stop; "Present=$($t.TpmPresent) Ready=$($t.TpmReady)" } catch { 'Unknown' })
    }
    Write-Ok "$($M.System.Manufacturer) $($M.System.Model) - $($M.System.OS) $($M.System.Version) build $($M.System.Build)"
    Write-Info "CPU: $($M.System.CPU) | RAM: $($M.System.RAM) | GPU: $(($gpus | ForEach-Object Name) -join ', ')"
    foreach ($v in $vols) { Write-Info ("{0} {1,-16} {2,10} free of {3,10}  {4}" -f $v.Drive, $v.Label, $v.Free, $v.Size, $v.Note) }

    try {
        $M.Displays = @(Get-DisplayModes)
        foreach ($d in $M.Displays) { Write-Info ("Display: {0} {1}x{2} @ {3} Hz{4}" -f $d.Monitor, $d.Width, $d.Height, $d.RefreshHz, $(if ($d.Primary) { ' (primary)' } else { '' })) }
    } catch { Write-Warn2 'Could not read display modes.' }
    try {
        $M.DisplayScaling = [ordered]@{
            LogPixels = Get-RegValue 'HKCU:\Control Panel\Desktop' 'LogPixels'
            Win8DpiScaling = Get-RegValue 'HKCU:\Control Panel\Desktop' 'Win8DpiScaling'
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# 2. Windows activation, product keys, BitLocker, accounts
# ---------------------------------------------------------------------------
Write-Section 'Windows license, BitLocker and accounts'
Invoke-Step 'Activation' {
    $lic = [ordered]@{}
    try {
        $sls = Get-CimInstance SoftwareLicensingService -ErrorAction Stop
        $lic.OEMKeyInFirmware = $sls.OA3xOriginalProductKey
    } catch { }
    try {
        $prod = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop | Select-Object -First 1
        $statusNames = @{ 0 = 'Unlicensed'; 1 = 'Licensed (activated)'; 2 = 'OOB grace'; 3 = 'OOT grace'; 4 = 'Non-genuine grace'; 5 = 'Notification'; 6 = 'Extended grace' }
        $lic.Status = $statusNames[[int]$prod.LicenseStatus]
        $lic.Channel = $prod.Description
        $lic.PartialKey = $prod.PartialProductKey
    } catch { }
    try {
        $dpid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name DigitalProductId -ErrorAction Stop).DigitalProductId
        $lic.InstalledKeyDecoded = Get-KeyFromDigitalProductId $dpid
    } catch { }
    $M.License = $lic
    Write-Ok ("Windows: {0}  channel: {1}" -f $lic.Status, $lic.Channel)
    if ($lic.OEMKeyInFirmware) { Write-Info "OEM key stored in firmware: $($lic.OEMKeyInFirmware) (Windows will use it automatically)" }
    if ($lic.Channel -match 'RETAIL') { Write-Info "Retail license. Installed key (may be generic if digital license): $($lic.InstalledKeyDecoded)" }

    # Microsoft accounts
    try {
        $msa = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.PrincipalSource -eq 'MicrosoftAccount' } | Select-Object -ExpandProperty Name)
        $M.Accounts = [ordered]@{
            LocalUsers = @(Get-LocalUser | Where-Object Enabled | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Source = "$($_.PrincipalSource)"; LastLogon = "$($_.LastLogon)" } })
            MicrosoftAccounts = $msa
        }
        if ($msa) { Write-Info "Microsoft account(s) in use: digital license is probably linked - Windows reactivates after reinstall on the same hardware." }
    } catch { }
}

Invoke-Step 'BitLocker' {
    if (-not $IsAdmin) { Write-Warn2 'BitLocker status skipped (needs admin).'; return }
    $bl = @()
    try {
        foreach ($v in Get-BitLockerVolume -ErrorAction Stop) {
            $rp = @($v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
            $bl += [pscustomobject]@{ Drive = $v.MountPoint; Protection = "$($v.ProtectionStatus)"; Encryption = "$($v.VolumeStatus)"; Percent = $v.EncryptionPercentage; Recovery = $rp }
        }
    } catch {
        $txt = & manage-bde.exe -status 2>&1 | Out-String
        $txt | Set-Content (Join-Path $Dirs.System 'bitlocker-status.txt') -Encoding UTF8
    }
    $encrypted = @($bl | Where-Object { $_.Protection -eq 'On' -or $_.Encryption -ne 'FullyDecrypted' })
    $M.BitLocker = @($bl | ForEach-Object { [pscustomobject]@{ Drive = $_.Drive; Protection = $_.Protection; Encryption = $_.Encryption; Percent = $_.Percent } })
    if ($encrypted) {
        $lines = @('BITLOCKER RECOVERY KEYS - KEEP THIS FILE PRIVATE, DELETE IT WHEN NO LONGER NEEDED', "Computer: $env:COMPUTERNAME   Saved: $(Get-Date)", '')
        foreach ($v in $encrypted) {
            foreach ($k in $v.Recovery) { $lines += "Drive $($v.Drive)  Key ID: $($k.KeyProtectorId)  Recovery password: $($k.RecoveryPassword)" }
        }
        $lines | Set-Content (Join-Path $Dirs.System 'BitLocker-RecoveryKeys-PRIVATE.txt') -Encoding UTF8
        Write-Warn2 ("BitLocker is enabled on {0}. Recovery keys saved to System\BitLocker-RecoveryKeys-PRIVATE.txt (keep private)." -f (($encrypted | ForEach-Object Drive) -join ', '))
    } else { Write-Ok 'No BitLocker-encrypted drives.' }
}

# ---------------------------------------------------------------------------
# 3. Installed applications
# ---------------------------------------------------------------------------
Write-Section 'Installed applications'
$LicenseKeywords = 'Adobe|Microsoft Office|Microsoft 365|Office 16|Visio|Project Professional|Autodesk|AutoCAD|Revit|SolidWorks|Fusion 360|CorelDRAW|Affinity|DaVinci|Camtasia|Snagit|FL Studio|Ableton|Cubase|Pro Tools|Native Instruments|iLok|Waves Central|Serato|Rekordbox|JetBrains|IntelliJ|PyCharm|Rider|WinRAR|Acronis|Macrium|Malwarebytes|Norton|McAfee|Kaspersky|Bitdefender|ESET|Avast|AVG|Quicken|QuickBooks|TurboTax|Sage|Parallels|VMware Workstation|Nero|CyberLink|PowerDVD|Topaz|Capture One|Lightroom|Photoshop|Premiere|Sketchup|Rhino|ZBrush|Substance|Wallpaper Engine|Directory Opus|Beyond Compare|Sublime|Paragon|EaseUS|AOMEI|Revo Uninstaller|IObit|Bandicam|Vegas|Filmora|Steinberg|Reason|Bitwig|Studio One|Guitar Pro|Avid|Plex'
$Categories = @(
    @{ Name = 'Runtime / framework'; Rx = 'Visual C\+\+.*Redist|Microsoft Visual C\+\+ 20|\.NET (Desktop |Core )?Runtime|\.NET Framework|ASP\.NET Core|Windows Desktop Runtime|DirectX|Edge WebView2|XNA Framework|OpenAL|Vulkan Run|PhysX|Java\(TM\)|Java \d+ Update|Microsoft Update Health|Windows SDK|Windows Software Development Kit|Microsoft GameInput|Windows App Runtime|VS_?Redist|Microsoft ODBC|Microsoft OLE DB|SQL Server .*(LocalDB|Native Client|Compact)|Python Launcher|Universal CRT' }
    @{ Name = 'Driver / hardware'; Rx = 'Driver|Chipset|NVIDIA (Graphics|HD Audio|PhysX|FrameView|USBC)|AMD Software|Radeon|Realtek|Intel\(R\)|Intel .*(Management|Graphics|Serial IO|Rapid Storage|Bluetooth|Wireless|Optane)|Synaptics|\bELAN\b|Dolby|\bDTS\b|Nahimic|Sonic Studio|Thunderbolt|Killer|Qualcomm|MediaTek|Armoury|ASUS|MSI Center|Dragon Center|GIGABYTE|AORUS|ASRock|Lenovo Vantage|Dell (Update|SupportAssist|Command)|HP (Support|Smart|Audio)|MyASUS|Alienware' }
    @{ Name = 'Peripheral software'; Rx = 'Logitech|G HUB|Razer|Synapse|iCUE|Corsair|SteelSeries|HyperX|NGENUITY|ROCCAT|Glorious|8BitDo|Keychron|Wooting|\bVIA\b|QMK|Elgato|Stream Deck|Wacom|XP-PEN|Huion|Focusrite|Scarlett|GoXLR|Wave Link|\bRode\b|Shure|Turtle Beach|Astro|Xbox Accessories|DS4Windows|Tobii|Qwertykeys|Endgame|Pulsar|Lamzu|Zowie|Fantech|Redragon|Cooler Master|NZXT|Lian Li|SignalRGB|OpenRGB|Mouse|Keyboard' }
    @{ Name = 'Game launcher'; Rx = '^Steam$|Epic Games Launcher|Riot Client|Battle\.net|EA app|EA Desktop|Origin|Ubisoft Connect|Uplay|GOG Galaxy|HoYoPlay|Genshin Impact Launcher|Rockstar Games Launcher|Xbox$|Amazon Games|^itch|Playnite|Bethesda\.net|Wargaming|Garena|Minecraft Launcher|CurseForge|Overwolf|Prism Launcher' }
    @{ Name = 'Game'; Rx = 'League of Legends|VALORANT|Genshin Impact|Honkai|Zenless|Wuthering|Minecraft|Fortnite|Overwatch|Counter-Strike|Apex|Roblox|osu!' }
)

Invoke-Step 'Installed programs' {
    $uninstallPaths = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine (64-bit)' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine (32-bit)' }
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Current user' }
    )
    $apps = @{}
    foreach ($up in $uninstallPaths) {
        foreach ($e in (Get-ItemProperty -Path $up.Path -ErrorAction SilentlyContinue)) {
            $name = "$($e.DisplayName)".Trim()
            if (-not $name) { continue }
            if ($e.SystemComponent -eq 1) { continue }
            if ($e.ParentKeyName) { continue }
            if ($e.ReleaseType -match 'Update|Hotfix') { continue }
            if ($name -match '^(Update for|Security Update|Hotfix|Service Pack)|\(KB\d{6,}\)') { continue }
            $key = "$name|$($e.DisplayVersion)"
            if ($apps.ContainsKey($key)) { continue }
            $cat = 'Application'
            foreach ($c in $Categories) { if ($name -match $c.Rx -or ($c.Name -eq 'Game' -and $e.PSChildName -match '^Steam App \d+')) { $cat = $c.Name; break } }
            if ($cat -eq 'Application' -and ($e.PSChildName -match '^Steam App \d+' -or "$($e.Publisher)" -match 'Riot Games|miHoYo|COGNOSPHERE|HoYoverse|Valve|Epic Games, Inc\.|Blizzard|Electronic Arts|Ubisoft|Mojang|Kuro Games' -and $name -notmatch 'Launcher|Client|Steam$|Battle\.net|EA app')) { $cat = 'Game' }
            $sizeMB = $null
            if ($e.EstimatedSize) { $sizeMB = [math]::Round($e.EstimatedSize / 1024, 1) }
            $apps[$key] = [pscustomobject]@{
                Name            = $name
                Version         = "$($e.DisplayVersion)"
                Publisher       = "$($e.Publisher)"
                Category        = $cat
                InstallDate     = "$($e.InstallDate)"
                SizeMB          = $sizeMB
                Scope           = $up.Scope
                InstallLocation = "$($e.InstallLocation)"
                NeedsLicense    = [bool]($name -match $LicenseKeywords)
                WingetId        = ''
            }
        }
    }
    $Script:AppList = @($apps.Values | Sort-Object Category, Name)
    Write-Ok ("{0} programs found ({1} apps, {2} runtimes, {3} drivers/hardware, {4} games/launchers)" -f $Script:AppList.Count,
        @($Script:AppList | Where-Object Category -eq 'Application').Count,
        @($Script:AppList | Where-Object Category -eq 'Runtime / framework').Count,
        @($Script:AppList | Where-Object { $_.Category -in 'Driver / hardware', 'Peripheral software' }).Count,
        @($Script:AppList | Where-Object { $_.Category -in 'Game', 'Game launcher' }).Count)
}

Invoke-Step 'Store apps' {
    $store = @()
    try {
        $store = @(Get-AppxPackage -ErrorAction Stop | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -eq 'Store' } | ForEach-Object {
            $inbox = $_.Name -match '^(Microsoft\.|MicrosoftWindows\.|MicrosoftCorporationII\.|Windows\.|Clipchamp\.|MSTeams$)'
            $dn = $null
            if (-not $inbox) { try { $dn = "$((Get-AppxPackageManifest $_ -ErrorAction Stop).Package.Properties.DisplayName)" } catch { } }
            if (-not $dn -or $dn -like 'ms-resource*') { $dn = $_.Name -replace '^[^.]+\.', '' }
            [pscustomobject]@{ Name = $_.Name; DisplayName = $dn; Version = "$($_.Version)"; Publisher = ($_.Publisher -replace '^CN=([^,]+).*', '$1'); Family = $_.PackageFamilyName; Inbox = $inbox }
        } | Sort-Object Inbox, Name)
    } catch { Write-Warn2 'Could not list Microsoft Store apps.' }
    $M.StoreApps = $store
    $store | Export-Csv (Join-Path $Dirs.Apps 'store-apps.csv') -NoTypeInformation -Encoding UTF8
    Write-Ok ("{0} Store apps ({1} not built into Windows)" -f $store.Count, @($store | Where-Object { -not $_.Inbox }).Count)
}

Invoke-Step 'winget' {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { Write-Warn2 'winget is not available on this PC - app reinstall list will be manual only.'; $M.WingetExport = $null; return }
    $prevEnc = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $exportFile = Join-Path $Dirs.Apps 'winget-export.json'
    & winget.exe export -o $exportFile --accept-source-agreements --disable-interactivity 2>&1 | Out-File (Join-Path $Dirs.Logs 'winget-export.log') -Encoding UTF8
    if (-not (Test-Path $exportFile)) {
        # older winget builds do not know --disable-interactivity
        & winget.exe export -o $exportFile --accept-source-agreements 2>&1 | Out-File (Join-Path $Dirs.Logs 'winget-export.log') -Append -Encoding UTF8
    }
    $listText = & winget.exe list --accept-source-agreements 2>&1
    try { [Console]::OutputEncoding = $prevEnc } catch { }
    $listText | Out-File (Join-Path $Dirs.Apps 'winget-list.txt') -Encoding UTF8

    if (Test-Path $exportFile) {
        $M.WingetExport = 'Apps\winget-export.json'
        $ex = Read-JsonFile $exportFile
        $n = 0; foreach ($s in $ex.Sources) { $n += @($s.Packages).Count }
        Write-Ok "$n apps can be reinstalled automatically with winget"
    } else { Write-Warn2 'winget export failed (see Logs\winget-export.log).' }

    # Best effort: map installed program names to winget IDs using the "winget list" table.
    try {
        $lines = @($listText | ForEach-Object { "$_" -replace "`r", '' })
        $hdrIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Name\s+Id\s+Version') { $hdrIdx = $i; break } }
        if ($hdrIdx -ge 0) {
            # progress-spinner characters can precede the header text; data rows start at column 0
            $hdr = $lines[$hdrIdx] -replace '^.*?(?=Name\s+Id\s+Version)', ''
            $idCol = $hdr.IndexOf(' Id ') + 1
            $verCol = $hdr.IndexOf(' Version ') + 1
            $srcCol = $hdr.LastIndexOf(' Source')
            if ($srcCol -ge 0) { $srcCol++ }
            $map = @{}
            for ($i = $hdrIdx + 2; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                if ($idCol -le 0 -or $verCol -le $idCol -or $l.Length -le $verCol) { continue }
                $nm = $l.Substring(0, $idCol).Trim()
                $id = $l.Substring($idCol, $verCol - $idCol).Trim()
                $src = ''
                if ($srcCol -gt 0 -and $l.Length -gt $srcCol) { $src = $l.Substring($srcCol).Trim() }
                if ($src -and $id -and $id -notmatch '^(ARP|MSIX)\\' -and $id -notmatch '\s') { $map[$nm.TrimEnd([char]0x2026, '.')] = $id }
            }
            foreach ($a in $Script:AppList) {
                foreach ($k in $map.Keys) {
                    if ($k.Length -ge 4 -and $a.Name.StartsWith($k, [StringComparison]::OrdinalIgnoreCase)) { $a.WingetId = $map[$k]; break }
                }
            }
        }
    } catch { }
}

Invoke-Step 'Save app list' {
    $M.Apps = $Script:AppList
    $Script:AppList | Export-Csv (Join-Path $Dirs.Apps 'installed-programs.csv') -NoTypeInformation -Encoding UTF8
    $lic = @($Script:AppList | Where-Object NeedsLicense)
    if ($lic) { Write-Warn2 ("{0} programs may need a license key / sign-in / deactivation: {1}" -f $lic.Count, (($lic | Select-Object -First 8 | ForEach-Object Name) -join ', ')) }
}

Invoke-Step 'App download links' {
    # Builds the list for apps.html: official site (from winget) where known, otherwise a download search.
    $online = $false
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { try { $null = [System.Net.Dns]::GetHostEntry('cdn.winget.microsoft.com'); $online = $true } catch { } }
    $cache = @{}
    function Get-WingetInfo([string]$Id) {
        if ($cache.ContainsKey($Id)) { return $cache[$Id] }
        $info = @{ Name = $null; Url = $null }
        if ($online) {
            $txt = @(& winget.exe show --id $Id -e --accept-source-agreements 2>$null | ForEach-Object { "$_" })
            foreach ($l in $txt) {
                if (-not $info.Name -and $l -match '^\s*Found (.+?) \[(.+)\]\s*$') { $info.Name = $Matches[1].Trim() }
                if (-not $info.Url -and $l -match '^\s*Homepage:\s*(https?://\S+)') { $info.Url = $Matches[1] }
            }
            if (-not $info.Url) { foreach ($l in $txt) { if ($l -match '^\s*Publisher Url:\s*(https?://\S+)') { $info.Url = $Matches[1]; break } } }
        }
        $cache[$Id] = $info
        return $info
    }
    $exportIds = @{}
    if ($M.WingetExport) {
        $ex = Read-JsonFile (Join-Path $B $M.WingetExport)
        foreach ($src in $ex.Sources) { foreach ($pkg in $src.Packages) { $exportIds[$pkg.PackageIdentifier] = $src.SourceDetails.Name } }
    }
    $apps = @($Script:AppList | Where-Object { $_.Category -in 'Application', 'Peripheral software', 'Game launcher', 'Game' })
    $mapped = @{}; foreach ($a in $Script:AppList) { if ($a.WingetId) { $mapped[$a.WingetId] = $true } }
    $extraIds = @($exportIds.Keys | Where-Object { -not $mapped.ContainsKey($_) })
    $total = $apps.Count + $extraIds.Count
    $links = New-Object System.Collections.ArrayList
    $i = 0
    if ($online) { Write-Info "Looking up official download pages for $total apps (about $([math]::Ceiling($total / 60)) min)..." }
    foreach ($a in $apps) {
        $i++
        if ($online -and $a.WingetId) { Write-Host ("`r         {0}/{1}  " -f $i, $total) -NoNewline -ForegroundColor DarkGray }
        $link = $null; $type = 'search'
        $auto = [bool]($a.WingetId -and $exportIds.ContainsKey($a.WingetId))
        if ($a.WingetId) {
            if ($exportIds[$a.WingetId] -eq 'msstore') { $link = "https://apps.microsoft.com/detail/$($a.WingetId)"; $type = 'store' }
            else { $inf = Get-WingetInfo $a.WingetId; if ($inf.Url) { $link = $inf.Url; $type = 'site' } }
        }
        if (-not $link) { $link = 'https://www.google.com/search?q=' + [uri]::EscapeDataString(("{0} {1} download" -f $a.Name, ($a.Publisher -replace ',.*$', '')).Trim()) }
        [void]$links.Add([pscustomobject]@{ Name = $a.Name; Publisher = $a.Publisher; Category = $a.Category; Link = $link; LinkType = $type; Auto = $auto })
    }
    foreach ($id in $extraIds) {
        $i++
        if ($online) { Write-Host ("`r         {0}/{1}  " -f $i, $total) -NoNewline -ForegroundColor DarkGray }
        $inf = Get-WingetInfo $id
        $name = if ($inf.Name) { $inf.Name } else { $id }
        if ($name -match $Categories[0].Rx -or $name -match $Categories[1].Rx) { continue }
        if ($exportIds[$id] -eq 'msstore') { $link = "https://apps.microsoft.com/detail/$id"; $type = 'store' }
        elseif ($inf.Url) { $link = $inf.Url; $type = 'site' }
        else { $link = 'https://www.google.com/search?q=' + [uri]::EscapeDataString("$name download"); $type = 'search' }
        [void]$links.Add([pscustomobject]@{ Name = $name; Publisher = ''; Category = 'Application'; Link = $link; LinkType = $type; Auto = $true })
    }
    if ($online) { Write-Host '' }
    $M.AppLinks = @($links | Sort-Object Name)
    Write-Ok ("Download links ready: {0} official sites, {1} Store pages, {2} searches" -f @($links | Where-Object LinkType -eq 'site').Count, @($links | Where-Object LinkType -eq 'store').Count, @($links | Where-Object LinkType -eq 'search').Count)
}

# ---------------------------------------------------------------------------
# 4. Drivers and hardware (incl. peripherals)
# ---------------------------------------------------------------------------
Write-Section 'Drivers, hardware and peripherals'
$VendorMap = @{
    '046D' = @('Logitech', 'Logitech G HUB (gaming) or Logi Options+ (office)')
    '1532' = @('Razer', 'Razer Synapse')
    '1B1C' = @('Corsair', 'Corsair iCUE')
    '1038' = @('SteelSeries', 'SteelSeries GG')
    '2DC8' = @('8BitDo', '8BitDo Ultimate Software')
    '3434' = @('Keychron', 'Keychron Launcher (web) / VIA')
    '31E3' = @('Wooting', 'Wootility')
    '0951' = @('HyperX (Kingston)', 'HyperX NGENUITY')
    '03F0' = @('HP / HyperX', 'HyperX NGENUITY / HP software')
    '1E7D' = @('ROCCAT / Turtle Beach', 'Turtle Beach Swarm')
    '0B05' = @('ASUS / ROG', 'Armoury Crate')
    '0FD9' = @('Elgato', 'Stream Deck / Camera Hub / Wave Link')
    '056A' = @('Wacom', 'Wacom tablet driver')
    '28BD' = @('XP-Pen', 'XP-Pen tablet driver')
    '256C' = @('Huion', 'Huion tablet driver')
    '1235' = @('Focusrite', 'Focusrite Control / driver')
    '28DE' = @('Valve', 'Steam (controller / Index)')
    '045E' = @('Microsoft', 'Xbox Accessories app (controllers)')
    '054C' = @('Sony', 'Works with Steam Input / DS4Windows')
    '057E' = @('Nintendo', 'Works with Steam Input')
    '2833' = @('Meta / Oculus', 'Meta Quest Link app')
    '0BB4' = @('HTC', 'VIVE / SteamVR')
    '1A86' = @('QinHeng (generic chip)', 'Often a generic keyboard/mouse - check maker website')
    '258A' = @('Sinowealth (generic chip)', 'Often a generic keyboard/mouse - check maker website')
    '3554' = @('Compx (Lamzu/ATK/VXE...)', 'Vendor web driver / app')
    '373B' = @('Compx / ATK', 'Vendor web driver / app')
    '093A' = @('Pixart (generic chip)', 'Often a generic mouse - check maker website')
    '3151' = @('YICHIP (generic chip)', 'Often a generic keyboard - check maker website')
    '0C45' = @('Microdia (generic chip)', 'Often a generic keyboard/webcam - check maker website')
    '19F5' = @('NuvoTon / generic', 'Check maker website')
    '320F' = @('Glorious / Evision', 'Glorious Core')
    '1EA7' = @('SHARKOON / generic', 'Check maker website')
    '0E8D' = @('MediaTek', 'Wi-Fi/Bluetooth driver')
    '8087' = @('Intel', 'Intel Bluetooth / Wireless driver')
    '0BDA' = @('Realtek', 'Realtek driver (Wi-Fi / Bluetooth / card reader / audio)')
}
$BuiltInVids = @('8087', '0BDA', '0E8D', '1D6B', '05E3', '2109', '1A40', '0424', '8086', '1022', '04F2', '13D3', '0489', '27C6', '138A', '06CB', '04CA', '0BC2', '0781', '090C')

Invoke-Step 'Driver list' {
    $drv = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' -and $_.DeviceName } |
        ForEach-Object { [pscustomobject]@{ Device = $_.DeviceName; Class = $_.DeviceClass; Provider = $_.DriverProviderName; Version = $_.DriverVersion; Date = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { '' }); Inf = $_.InfName } } |
        Sort-Object Class, Device -Unique)
    $drv | Export-Csv (Join-Path $Dirs.Drivers 'third-party-drivers.csv') -NoTypeInformation -Encoding UTF8
    $M.Drivers = $drv
    Write-Ok "$($drv.Count) third-party drivers listed"
    $net = @($drv | Where-Object { $_.Class -eq 'NET' })
    foreach ($n in $net) { Write-Info "Network: $($n.Device) ($($n.Provider) $($n.Version))" }
}

Invoke-Step 'Hardware summary' {
    $hw = [ordered]@{}
    $hw.NetworkAdapters = @(try { Get-NetAdapter -Physical -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Description = $_.InterfaceDescription; Status = "$($_.Status)"; Speed = $_.LinkSpeed; MAC = $_.MacAddress } } } catch { })
    $hw.AudioDevices = @(Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Manufacturer = $_.Manufacturer } })
    # Active playback / recording endpoints
    $endpoints = @()
    foreach ($kind in 'Render', 'Capture') {
        $base = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$kind"
        foreach ($k in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
            $state = Get-RegValue $k.PSPath 'DeviceState'
            if ($state -ne 1) { continue }
            $props = Join-Path $k.PSPath 'Properties'
            $friendly = Get-RegValue $props '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
            $iface = Get-RegValue $props '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
            $endpoints += [pscustomobject]@{ Type = $(if ($kind -eq 'Render') { 'Playback' } else { 'Recording' }); Name = "$friendly"; Device = "$iface" }
        }
    }
    $hw.AudioEndpoints = $endpoints
    $hw.UserDucking = Get-RegValue 'HKCU:\Software\Microsoft\Multimedia\Audio' 'UserDuckingPreference'

    # USB / HID peripherals by vendor ID
    $periph = @{}
    foreach ($d in (Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -match '^(USB|HID)\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})' })) {
        if ($d.DeviceID -notmatch 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { continue }
        $vid = $Matches[1]; $pid2 = $Matches[2]
        if ($BuiltInVids -contains $vid) { continue }
        $k = "$vid`:$pid2"
        $nm = "$($d.Name)"
        if ($periph.ContainsKey($k)) {
            if ($periph[$k].Names -notcontains $nm) { $periph[$k].Names += $nm }
            continue
        }
        $vendor = ''; $sw = ''
        if ($VendorMap.ContainsKey($vid)) { $vendor = $VendorMap[$vid][0]; $sw = $VendorMap[$vid][1] }
        $periph[$k] = [pscustomobject]@{ VID = $vid; PID = $pid2; Vendor = $vendor; Names = @($nm); SuggestedSoftware = $sw; Manufacturer = "$($d.Manufacturer)" }
    }
    $hw.Peripherals = @($periph.Values | Where-Object { $_.Names -match 'mouse|keyboard|game|controller|headset|audio|tablet|pen|webcam|camera|xbox|hid|input|wireless|receiver|usb' -or $_.Vendor } |
        ForEach-Object { [pscustomobject]@{ VID = $_.VID; PID = $_.PID; Vendor = $_.Vendor; Device = (($_.Names | Where-Object { $_ -notmatch '^(USB Input Device|HID-compliant (vendor-defined|consumer control|system controller) device|USB Composite Device)$' } | Select-Object -First 3) -join '; '); SuggestedSoftware = $_.SuggestedSoftware } } |
        Sort-Object Vendor, Device)
    foreach ($p in $hw.Peripherals) { Write-Info ("USB {0}:{1}  {2,-22} {3}" -f $p.VID, $p.PID, $p.Vendor, $p.Device) }

    $hw.Bluetooth = @(try { Get-PnpDevice -Class Bluetooth -ErrorAction Stop | Where-Object { $_.FriendlyName -and $_.InstanceId -match '^BTHENUM|^BTHLE|^BTH' -and $_.FriendlyName -notmatch 'Service|Enumerator|Protocol|Transport|Generic Attribute|Generic Access|Device Identification|RFCOMM|Avrcp|Hands-Free|Audio Gateway' } | Select-Object -ExpandProperty FriendlyName -Unique } catch { })
    if ($hw.Bluetooth) { Write-Info ("Paired Bluetooth: {0}" -f ($hw.Bluetooth -join ', ')) }

    $hw.ProblemDevices = @(try { Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -in 'Error', 'Degraded', 'Unknown' } | ForEach-Object { [pscustomobject]@{ Name = $_.FriendlyName; Class = $_.Class; Status = "$($_.Status)" } } } catch { })
    $M.Hardware = $hw
    Write-Ok ("{0} peripherals, {1} audio endpoints, {2} Bluetooth devices" -f $hw.Peripherals.Count, $endpoints.Count, $hw.Bluetooth.Count)
}

Invoke-Step 'Driver export' {
    if (-not $IsAdmin) { Write-Warn2 'Driver export skipped (needs admin).'; return }
    Write-Info 'Exporting third-party drivers lets you get network/Wi-Fi working on the new install even without internet.'
    if (-not (Ask-YesNo 'Export all third-party drivers now? (usually 0.5-3 GB, a few minutes)' $true)) { return }
    $dest = Join-Path $Dirs.Drivers 'Export'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Write-Info 'Exporting... (please wait)'
    $ok = $false
    try { Export-WindowsDriver -Online -Destination $dest -ErrorAction Stop | Out-Null; $ok = $true } catch {
        & pnputil.exe /export-driver * $dest 2>&1 | Out-File (Join-Path $Dirs.Logs 'pnputil-export.log') -Encoding UTF8
        $ok = ($LASTEXITCODE -eq 0)
    }
    $count = @(Get-ChildItem $dest -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count
    if ($count -gt 0) { Write-Ok ("Exported {0} driver packages ({1})" -f $count, (Format-Size (Get-DirSize $dest))); $M.DriverExport = 'Drivers\Export' }
    else { Write-Warn2 'Driver export produced no files (DISM may be damaged on this install).' }
}

# ---------------------------------------------------------------------------
# 5. Network
# ---------------------------------------------------------------------------
Write-Section 'Network: Wi-Fi, IP/DNS, hosts, mapped drives, VPN'
Invoke-Step 'Network' {
    $net = [ordered]@{}
    $wifiDir = Join-Path $Dirs.Network 'WiFi'
    New-Item -ItemType Directory -Path $wifiDir -Force | Out-Null
    if ($IsAdmin) {
        & netsh.exe wlan export profile key=clear folder="$wifiDir" 2>&1 | Out-Null
    } else {
        & netsh.exe wlan export profile folder="$wifiDir" 2>&1 | Out-Null
        Write-Warn2 'Wi-Fi passwords not exported (needs admin) - profiles saved without keys.'
    }
    $wifi = @(Get-ChildItem $wifiDir -Filter *.xml -ErrorAction SilentlyContinue)
    $net.WiFiProfiles = @($wifi | ForEach-Object { try { ([xml](Get-Content -LiteralPath $_.FullName -Raw)).WLANProfile.name } catch { $_.BaseName } })
    if ($wifi) { Write-Ok ("{0} Wi-Fi networks saved{1}" -f $wifi.Count, $(if ($IsAdmin) { ' (with passwords - Network\WiFi is PRIVATE)' } else { '' })) }

    try {
        $net.Adapters = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.NetAdapter.Status -eq 'Up' } | ForEach-Object {
            $dhcp = (Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
            [pscustomobject]@{
                Name = $_.InterfaceAlias; Description = $_.InterfaceDescription
                IPv4 = (($_.IPv4Address | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', ')
                Gateway = (($_.IPv4DefaultGateway | ForEach-Object NextHop) -join ', ')
                DNS = (($_.DNSServer | Where-Object AddressFamily -eq 2 | ForEach-Object ServerAddresses) -join ', ')
                DHCP = "$dhcp"
            }
        })
        foreach ($a in $net.Adapters) {
            if ($a.DHCP -eq 'Disabled') { Write-Warn2 "Static IP on '$($a.Name)': $($a.IPv4) gw $($a.Gateway) dns $($a.DNS) - re-enter manually on the new install." }
        }
    } catch { }

    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path $hosts) {
        Copy-Item $hosts (Join-Path $Dirs.Network 'hosts.txt') -Force -ErrorAction SilentlyContinue
        $net.HostsEntries = @(Get-Content $hosts -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*[^#\s]' })
        if ($net.HostsEntries) { Write-Info "$($net.HostsEntries.Count) custom hosts-file entries saved" }
    }

    $net.MappedDrives = @(Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ Letter = $_.PSChildName; Path = (Get-RegValue $_.PSPath 'RemotePath'); User = (Get-RegValue $_.PSPath 'UserName') }
    })
    foreach ($d in $net.MappedDrives) { Write-Info "Mapped drive $($d.Letter): $($d.Path)" }

    $vpn = @()
    try { $vpn += Get-VpnConnection -ErrorAction Stop } catch { }
    try { $vpn += Get-VpnConnection -AllUserConnection -ErrorAction Stop } catch { }
    $net.VPN = @($vpn | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Server = $_.ServerAddress; Type = "$($_.TunnelType)"; Auth = "$($_.AuthenticationMethod)" } })
    $net.Proxy = [ordered]@{
        Enabled = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyEnable'
        Server  = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyServer'
        AutoConfigURL = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'AutoConfigURL'
    }
    $M.Network = $net
}

Invoke-Step 'Printers' {
    $printers = @()
    try {
        $ports = @{}
        foreach ($p in (Get-PrinterPort -ErrorAction Stop)) { $ports[$p.Name] = $p.PrinterHostAddress }
        $default = (Get-CimInstance Win32_Printer -Filter 'Default=TRUE' -ErrorAction SilentlyContinue).Name
        $printers = @(Get-Printer -ErrorAction Stop | Where-Object { $_.Name -notmatch 'Microsoft Print to PDF|Microsoft XPS|OneNote|^Fax$|Send To OneNote|Adobe PDF|PDF24|CutePDF' } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Driver = $_.DriverName; Port = $_.PortName; IP = $ports[$_.PortName]; Type = "$($_.Type)"; Shared = $_.Shared; Default = ($_.Name -eq $default) }
        })
    } catch { Write-Warn2 'Could not list printers (Print Spooler may be broken).' }
    $M.Printers = $printers
    foreach ($p in $printers) { Write-Info ("Printer: {0}  driver: {1}  {2}" -f $p.Name, $p.Driver, $(if ($p.IP) { "IP $($p.IP)" } else { $p.Port })) }
    if ($printers) { Write-Ok "$($printers.Count) printers listed" }
}

# ---------------------------------------------------------------------------
# 6. Windows settings
# ---------------------------------------------------------------------------
Write-Section 'Windows settings'
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$TweakDefs = @(
    # Category, Description, Path, Name, Hint
    ,@('Theme', 'App mode (0 = dark, 1 = light)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'AppsUseLightTheme')
    ,@('Theme', 'Windows mode (0 = dark, 1 = light)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'SystemUsesLightTheme')
    ,@('Theme', 'Transparency effects', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'EnableTransparency')
    ,@('Theme', 'Accent color on title bars', 'HKCU:\Software\Microsoft\Windows\DWM', 'ColorPrevalence')
    ,@('Theme', 'Accent color on Start/taskbar', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'ColorPrevalence')
    ,@('File Explorer', 'Hide file extensions (0 = show)', $adv, 'HideFileExt')
    ,@('File Explorer', 'Hidden files (1 = show, 2 = hide)', $adv, 'Hidden')
    ,@('File Explorer', 'Open Explorer to (1 = This PC, 2 = Home/Quick access)', $adv, 'LaunchTo')
    ,@('File Explorer', 'Show recently used files', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer', 'ShowRecent')
    ,@('File Explorer', 'Show frequently used folders', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer', 'ShowFrequent')
    ,@('File Explorer', 'Compact view', $adv, 'UseCompactMode')
    ,@('Taskbar', 'Taskbar alignment (0 = left, 1 = center)', $adv, 'TaskbarAl')
    ,@('Taskbar', 'Search box (0 hidden, 1 icon, 2 box, 3 icon+label)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'SearchboxTaskbarMode')
    ,@('Taskbar', 'Task View button', $adv, 'ShowTaskViewButton')
    ,@('Taskbar', 'Widgets button', $adv, 'TaskbarDa')
    ,@('Taskbar', 'Chat / Teams button', $adv, 'TaskbarMn')
    ,@('Taskbar', 'Copilot button', $adv, 'ShowCopilotButton')
    ,@('Taskbar', 'Combine taskbar buttons (0 always, 1 when full, 2 never)', $adv, 'TaskbarGlomLevel')
    ,@('Taskbar', 'Show taskbar on all displays', $adv, 'MMTaskbarEnabled')
    ,@('Taskbar', 'Show seconds in clock', $adv, 'ShowSecondsInSystemClock')
    ,@('Taskbar', 'Small taskbar icons (Win10)', $adv, 'TaskbarSmallIcons')
    ,@('Start', 'Track recently opened files (recent files)', $adv, 'Start_TrackDocs')
    ,@('Start', 'Track app launches (most used apps)', $adv, 'Start_TrackProgs')
    ,@('Start', 'Start layout (0 default, 1 more pins, 2 more recommendations)', $adv, 'Start_Layout')
    ,@('Start', 'Show recommendations / tips in Start', $adv, 'Start_IrisRecommendations')
    ,@('Start', 'Show account notifications in Start', $adv, 'Start_AccountNotifications')
    ,@('Multitasking', 'Alt+Tab shows (0 = 20 Edge tabs, 1 = 5, 2 = 3, 3 = windows only)', $adv, 'MultiTaskingAltTabFilter')
    ,@('Multitasking', 'Snap windows', 'HKCU:\Control Panel\Desktop', 'WindowArrangementActive')
    ,@('Multitasking', 'Snap assist suggestions', $adv, 'SnapAssist')
    ,@('Multitasking', 'Snap layouts on maximize hover', $adv, 'EnableSnapAssistFlyout')
    ,@('Mouse', 'Pointer speed (1-20, default 10)', 'HKCU:\Control Panel\Mouse', 'MouseSensitivity')
    ,@('Mouse', 'Enhance pointer precision (1 = on)', 'HKCU:\Control Panel\Mouse', 'MouseSpeed')
    ,@('Mouse', 'Acceleration threshold 1', 'HKCU:\Control Panel\Mouse', 'MouseThreshold1')
    ,@('Mouse', 'Acceleration threshold 2', 'HKCU:\Control Panel\Mouse', 'MouseThreshold2')
    ,@('Mouse', 'Double-click speed (ms)', 'HKCU:\Control Panel\Mouse', 'DoubleClickSpeed')
    ,@('Mouse', 'Swap left/right buttons', 'HKCU:\Control Panel\Mouse', 'SwapMouseButtons')
    ,@('Mouse', 'Scroll lines per notch', 'HKCU:\Control Panel\Desktop', 'WheelScrollLines')
    ,@('Keyboard', 'Key repeat delay (0-3)', 'HKCU:\Control Panel\Keyboard', 'KeyboardDelay')
    ,@('Keyboard', 'Key repeat rate (0-31)', 'HKCU:\Control Panel\Keyboard', 'KeyboardSpeed')
    ,@('Keyboard', 'Sticky Keys shortcut flags (506 = shortcut off)', 'HKCU:\Control Panel\Accessibility\StickyKeys', 'Flags')
    ,@('Keyboard', 'Filter Keys flags (122 = shortcut off)', 'HKCU:\Control Panel\Accessibility\Keyboard Response', 'Flags')
    ,@('Keyboard', 'Toggle Keys flags (58 = shortcut off)', 'HKCU:\Control Panel\Accessibility\ToggleKeys', 'Flags')
    ,@('Keyboard', 'Clipboard history (Win+V)', 'HKCU:\Software\Microsoft\Clipboard', 'EnableClipboardHistory')
    ,@('Notifications', 'App notifications (toasts) enabled', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications', 'ToastEnabled')
    ,@('Notifications', 'Notifications on lock screen', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications', 'LockScreenToastEnabled')
    ,@('Notifications', '"Get tips and suggestions" notifications', $cdm, 'SubscribedContent-338389Enabled')
    ,@('Notifications', '"Welcome experience" after updates', $cdm, 'SubscribedContent-310093Enabled')
    ,@('Notifications', 'Suggest ways to finish setting up device', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement', 'ScoobeSystemSettingEnabled')
    ,@('Privacy', 'Advertising ID', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled')
    ,@('Privacy', 'Tailored experiences', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy', 'TailoredExperiencesWithDiagnosticDataEnabled')
    ,@('Privacy', 'Suggested content in Settings', $cdm, 'SubscribedContent-338393Enabled')
    ,@('Privacy', 'Suggested content in Settings (2)', $cdm, 'SubscribedContent-353694Enabled')
    ,@('Privacy', 'Suggestions in Start', $cdm, 'SystemPaneSuggestionsEnabled')
    ,@('Privacy', 'Silently installed suggested apps', $cdm, 'SilentInstalledAppsEnabled')
    ,@('Privacy', 'Let websites access language list', 'HKCU:\Control Panel\International\User Profile', 'HttpAcceptLanguageOptOut')
    ,@('Privacy', 'Location access (Allow/Deny)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location', 'Value')
    ,@('Privacy', 'Camera access (Allow/Deny)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam', 'Value')
    ,@('Privacy', 'Microphone access (Allow/Deny)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone', 'Value')
    ,@('Privacy', 'Bing web results in Start search (0 = off)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled')
    ,@('Gaming', 'Game Mode', 'HKCU:\Software\Microsoft\GameBar', 'AutoGameModeEnabled')
    ,@('Gaming', 'Game Bar / Xbox capture (Game DVR)', 'HKCU:\System\GameConfigStore', 'GameDVR_Enabled')
    ,@('Gaming', 'Background recording', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled')
    ,@('Gaming', 'Open Game Bar with controller button', 'HKCU:\Software\Microsoft\GameBar', 'UseNexusForGameBarEnabled')
    ,@('Sound', 'Communications activity (0 mute, 1 -80%, 2 -50%, 3 do nothing)', 'HKCU:\Software\Microsoft\Multimedia\Audio', 'UserDuckingPreference')
    ,@('Desktop', 'Desktop icon: This PC (0 = shown)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel', '{20D04FE0-3AEA-1069-A2D8-08002B30309D}')
    ,@('Desktop', 'Desktop icon: Recycle Bin (0 = shown)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel', '{645FF040-5081-101B-9F08-00AA002F954E}')
    ,@('Desktop', 'Desktop icon: User folder (0 = shown)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel', '{59031a47-3f72-44a7-89c5-5595fe6b30ee}')
    ,@('Desktop', 'Desktop icon: Network (0 = shown)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel', '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}')
    ,@('Desktop', 'Desktop icon: Control Panel (0 = shown)', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel', '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}')
    ,@('Desktop', 'Wallpaper fit style (10 fill, 6 fit, 2 stretch, 0 center/tile, 22 span)', 'HKCU:\Control Panel\Desktop', 'WallpaperStyle')
    ,@('Region', 'Short date format', 'HKCU:\Control Panel\International', 'sShortDate')
    ,@('Region', 'Long date format', 'HKCU:\Control Panel\International', 'sLongDate')
    ,@('Region', 'Short time format', 'HKCU:\Control Panel\International', 'sShortTime')
    ,@('Region', 'Long time format', 'HKCU:\Control Panel\International', 'sTimeFormat')
    ,@('Region', 'First day of week (0 = Monday, 6 = Sunday)', 'HKCU:\Control Panel\International', 'iFirstDayOfWeek')
    ,@('Region', 'Measurement (0 metric, 1 US)', 'HKCU:\Control Panel\International', 'iMeasure')
    ,@('Region', 'Decimal symbol', 'HKCU:\Control Panel\International', 'sDecimal')
    ,@('Region', 'Digit grouping symbol', 'HKCU:\Control Panel\International', 'sThousand')
    ,@('Region', 'Currency symbol', 'HKCU:\Control Panel\International', 'sCurrency')
    ,@('Power', 'Fast startup (HiberbootEnabled, 0 = off)', 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power', 'HiberbootEnabled')
    ,@('Updates', 'Get latest updates as soon as available', 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings', 'IsContinuousInnovationOptedIn')
    ,@('Updates', 'Delivery Optimization: download from other PCs (0 off, 1 LAN, 3 internet)', 'HKU:\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings', 'DownloadMode')
)

Invoke-Step 'Settings snapshot' {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { try { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script | Out-Null } catch { } }
    $tweaks = @()
    foreach ($t in $TweakDefs) {
        $path = $t[2]; $name = $t[3]
        try {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            $val = $item.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
            if ($null -eq $val) { continue }
            $kind = "$($item.GetValueKind($name))"
            if ($val -is [byte[]]) { $val = [Convert]::ToBase64String($val) }
            $tweaks += [pscustomobject]@{ Category = $t[0]; Description = $t[1]; Path = $path; Name = $name; Kind = $kind; Value = $val }
        } catch { }
    }
    # Cursor scheme (whole key)
    try {
        $ck = Get-Item 'HKCU:\Control Panel\Cursors' -ErrorAction Stop
        $cursorFiles = Join-Path $Dirs.Settings 'CursorFiles'
        foreach ($vn in $ck.GetValueNames()) {
            $raw = $ck.GetValue($vn, $null, 'DoNotExpandEnvironmentNames')
            $tweaks += [pscustomobject]@{ Category = 'Cursor'; Description = $(if ($vn -eq '') { 'Cursor scheme name' } else { "Cursor: $vn" }); Path = 'HKCU:\Control Panel\Cursors'; Name = $vn; Kind = "$($ck.GetValueKind($vn))"; Value = $raw }
            if ($raw -is [string] -and $raw -match '\.(cur|ani)$') {
                $exp = [Environment]::ExpandEnvironmentVariables($raw)
                if ((Test-Path -LiteralPath $exp) -and ($exp -notlike "$env:SystemRoot\*")) {
                    New-Item -ItemType Directory -Path $cursorFiles -Force | Out-Null
                    Copy-Item -LiteralPath $exp -Destination $cursorFiles -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch { }
    $M.Settings = $tweaks
    $tweaks | Export-Csv (Join-Path $Dirs.Settings 'windows-settings.csv') -NoTypeInformation -Encoding UTF8
    Write-Ok "$($tweaks.Count) Windows setting values recorded (theme, Explorer, taskbar, mouse, privacy, notifications ...)"
}

Invoke-Step 'Wallpaper' {
    $wp = Get-RegValue 'HKCU:\Control Panel\Desktop' 'WallPaper'
    $dest = Join-Path $Dirs.Settings 'Wallpaper'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $saved = $null
    if ($wp -and (Test-Path -LiteralPath $wp)) {
        $saved = Join-Path $dest ('wallpaper' + [IO.Path]::GetExtension($wp))
        Copy-Item -LiteralPath $wp -Destination $saved -Force
    } else {
        $tw = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
        if (Test-Path $tw) { $saved = Join-Path $dest 'wallpaper.jpg'; Copy-Item $tw $saved -Force }
    }
    # Slideshow / theme folder
    $themes = Join-Path $env:APPDATA 'Microsoft\Windows\Themes'
    if (Test-Path $themes) { Copy-Item (Join-Path $themes '*.theme') $dest -Force -ErrorAction SilentlyContinue }
    $M.Wallpaper = [ordered]@{ OriginalPath = $wp; Saved = $(if ($saved) { 'Settings\Wallpaper\' + (Split-Path $saved -Leaf) } else { $null }) }
    $wpe = @($Script:AppList | Where-Object { $_.Name -match 'Wallpaper Engine|Lively Wallpaper' })
    if ($wpe) { Write-Info "Animated wallpaper app in use: $(($wpe | ForEach-Object Name) -join ', ') - wallpapers come back after reinstalling it (Workshop subscriptions)." }
    if ($saved) { Write-Ok 'Wallpaper saved' }
}

Invoke-Step 'Power plan' {
    $pw = [ordered]@{}
    $active = & powercfg.exe /getactivescheme 2>$null
    if ("$active" -match '([0-9a-fA-F-]{36})\s+\((.+)\)') {
        $pw.ActiveGuid = $Matches[1]; $pw.ActiveName = $Matches[2]
        $file = Join-Path $Dirs.Settings 'power-plan.pow'
        & powercfg.exe /export "$file" $pw.ActiveGuid 2>&1 | Out-Null
        if (Test-Path $file) { $pw.Export = 'Settings\power-plan.pow' }
    }
    (& powercfg.exe /list 2>&1) | Out-File (Join-Path $Dirs.Settings 'power-plans.txt') -Encoding UTF8
    (& powercfg.exe /query 2>&1) | Out-File (Join-Path $Dirs.Settings 'power-plan-details.txt') -Encoding UTF8
    $pw.HibernateEnabled = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    $M.Power = $pw
    Write-Ok "Active power plan: $($pw.ActiveName)"
}

Invoke-Step 'Region and language' {
    $r = [ordered]@{}
    try { $r.TimeZone = (Get-TimeZone).Id } catch { }
    try { $r.Culture = (Get-Culture).Name } catch { }
    try { $r.SystemLocale = (Get-WinSystemLocale).Name } catch { }
    try { $r.HomeLocation = (Get-WinHomeLocation).GeoId } catch { }
    try { $r.Languages = @(Get-WinUserLanguageList | ForEach-Object { [pscustomobject]@{ Tag = $_.LanguageTag; Name = $_.Autonym; Keyboards = @($_.InputMethodTips) } }) } catch { }
    $r.AutoTimeZone = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate' 'Start'
    $M.Region = $r
    Write-Ok ("Time zone {0}, format {1}, languages {2}" -f $r.TimeZone, $r.Culture, (($r.Languages | ForEach-Object Tag) -join ', '))
}

Invoke-Step 'Default apps' {
    $assoc = @()
    foreach ($ext in '.htm', '.html', '.pdf', '.txt', '.jpg', '.png', '.gif', '.webp', '.mp4', '.mkv', '.avi', '.mp3', '.flac', '.wav', '.zip', '.7z', '.rar', '.docx', '.xlsx', '.json', '.xml', '.md', '.log', '.torrent', '.eml') {
        $pid1 = Get-RegValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice" 'ProgId'
        if ($pid1) { $assoc += [pscustomobject]@{ Type = $ext; ProgId = $pid1 } }
    }
    foreach ($proto in 'http', 'https', 'mailto', 'magnet', 'tel', 'steam', 'discord') {
        $pid1 = Get-RegValue "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$proto\UserChoice" 'ProgId'
        if ($pid1) { $assoc += [pscustomobject]@{ Type = $proto; ProgId = $pid1 } }
    }
    $M.DefaultApps = $assoc
    if ($IsAdmin) { & dism.exe /Online /Export-DefaultAppAssociations:"$(Join-Path $Dirs.Settings 'default-app-associations.xml')" 2>&1 | Out-Null }
    $browser = ($assoc | Where-Object Type -eq 'https').ProgId
    Write-Ok "Default browser ProgId: $browser"
}

Invoke-Step 'Startup apps and scheduled tasks' {
    $st = @()
    foreach ($rk in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        try {
            $k = Get-Item $rk -ErrorAction Stop
            foreach ($vn in $k.GetValueNames()) { if ($vn) { $st += [pscustomobject]@{ Name = $vn; Command = "$($k.GetValue($vn))"; Location = $rk } } }
        } catch { }
    }
    foreach ($sf in ([Environment]::GetFolderPath('Startup')), ([Environment]::GetFolderPath('CommonStartup'))) {
        Get-ChildItem $sf -ErrorAction SilentlyContinue | ForEach-Object { $st += [pscustomobject]@{ Name = $_.BaseName; Command = $_.FullName; Location = 'Startup folder' } }
    }
    $M.Startup = $st
    Write-Ok "$($st.Count) startup entries recorded"

    $taskDir = Join-Path $Dirs.Settings 'ScheduledTasks'
    New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
    $tasks = @()
    try {
        foreach ($t in (Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.TaskName -notmatch '^(GoogleUpdate|MicrosoftEdgeUpdate|OneDrive|User_Feed_Synchronization|CreateExplorerShellUnelevatedTask|npcapwatchdog|Opera scheduled|BraveSoftwareUpdate|Firefox Default Browser Agent|Firefox Background Update|Adobe Acrobat Update|MicrosoftEdgeUpdateBrowserReplacement)' })) {
            $file = Join-Path $taskDir ((Get-SafeName ($t.TaskPath.Trim('\') + '_' + $t.TaskName)).TrimStart('_') + '.xml')
            try { Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Set-Content -Path $file -Encoding Unicode } catch { $file = $null }
            $tasks += [pscustomobject]@{
                Name = $t.TaskName; Path = $t.TaskPath; State = "$($t.State)"; Author = $t.Author
                Action = (($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; ')
                File = $(if ($file) { 'Settings\ScheduledTasks\' + (Split-Path $file -Leaf) } else { $null })
            }
        }
    } catch { }
    $M.ScheduledTasks = $tasks
    Write-Ok "$($tasks.Count) non-Microsoft scheduled tasks exported"
}

Invoke-Step 'Environment variables' {
    $userEnv = @()
    try {
        $k = Get-Item 'HKCU:\Environment' -ErrorAction Stop
        foreach ($vn in $k.GetValueNames()) {
            if ($vn -in 'TEMP', 'TMP', 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial') { continue }
            $userEnv += [pscustomobject]@{ Name = $vn; Value = "$($k.GetValue($vn, $null, 'DoNotExpandEnvironmentNames'))"; Kind = "$($k.GetValueKind($vn))" }
        }
    } catch { }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ -and $_ -notmatch '^%?SystemRoot%?|^C:\\WINDOWS|WindowsPowerShell|OpenSSH|\\WindowsApps$|Windows Kits|NVIDIA Corporation\\PhysX|\\dotnet\\?$' }
    $M.EnvironmentUser = $userEnv
    $M.MachinePathExtra = @($machinePath)
    Write-Ok "$($userEnv.Count) user environment variables, $(@($machinePath).Count) extra system PATH entries"
}

Invoke-Step 'Windows features and WSL' {
    if ($IsAdmin) {
        try {
            $M.OptionalFeatures = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object State -eq 'Enabled' | Select-Object -ExpandProperty FeatureName)
            Write-Ok "$($M.OptionalFeatures.Count) optional Windows features enabled"
        } catch { Write-Warn2 'Could not read optional features (DISM error).' }
    }
    $wslDistros = @()
    foreach ($k in (Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue)) {
        $name = Get-RegValue $k.PSPath 'DistributionName'
        $base = Get-RegValue $k.PSPath 'BasePath'
        if (-not $name) { continue }
        $base = $base -replace '^\\\\\?\\', ''
        $vhd = Join-Path $base 'ext4.vhdx'
        $size = $(if (Test-Path -LiteralPath $vhd) { (Get-Item -LiteralPath $vhd).Length } else { 0 })
        $wslDistros += [pscustomobject]@{ Name = $name; BasePath = $base; Size = Format-Size $size; SizeBytes = $size; Exported = $null }
    }
    if ($wslDistros) {
        Write-Info ("WSL distros: {0}" -f (($wslDistros | ForEach-Object { "$($_.Name) ($($_.Size))" }) -join ', '))
        $wslDir = Join-Path $B 'WSL'
        foreach ($d in $wslDistros) {
            if (Ask-YesNo "Export WSL distro '$($d.Name)' ($($d.Size)) to the backup? (can take a while)" $false) {
                New-Item -ItemType Directory -Path $wslDir -Force | Out-Null
                $tar = Join-Path $wslDir ((Get-SafeName $d.Name) + '.tar')
                Write-Info "Exporting $($d.Name)..."
                & wsl.exe --export $d.Name $tar
                if (Test-Path $tar) { $d.Exported = 'WSL\' + (Split-Path $tar -Leaf); Write-Ok "Exported $($d.Name)" } else { Write-Warn2 "WSL export of $($d.Name) failed." }
            }
        }
    }
    $M.WSL = $wslDistros
}

Invoke-Step 'Credentials and certificates' {
    $creds = @(& cmdkey.exe /list 2>$null | Where-Object { $_ -match '^\s*(Target|Ziel|Cible|Destino)\s*:\s*(.+)$' } | ForEach-Object { ($_ -replace '^\s*[^:]+:\s*', '').Trim() })
    $M.SavedCredentialTargets = @($creds | Where-Object { $_ -notmatch 'MicrosoftAccount:|WindowsLive:|virtualapp/didlogical|SSO_POP|OneDrive Cached|XblGrts|Xbl\|' })
    $certs = @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object HasPrivateKey | ForEach-Object {
        [pscustomobject]@{ Subject = $_.Subject; Issuer = $_.Issuer; Expires = $_.NotAfter.ToString('yyyy-MM-dd'); Thumbprint = $_.Thumbprint; Purpose = (($_.EnhancedKeyUsageList | ForEach-Object FriendlyName) -join ', ') }
    })
    $M.Certificates = $certs
    if ($certs | Where-Object Purpose -match 'Encrypting File System') { Write-Warn2 'An EFS (file encryption) certificate exists. If any files are EFS-encrypted, export it (certmgr.msc > Personal > Export with private key) or those files become unreadable!' }
    Write-Ok ("{0} saved Windows credentials (names only), {1} personal certificates" -f $M.SavedCredentialTargets.Count, $certs.Count)
}

Invoke-Step 'Fonts' {
    $fontDir = Join-Path $Dirs.Settings 'Fonts'
    $copied = @()
    $userFonts = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $candidates = @()
    if (Test-Path $userFonts) { $candidates += Get-ChildItem $userFonts -File -ErrorAction SilentlyContinue }
    try {
        $installDate = (Get-CimInstance Win32_OperatingSystem).InstallDate.AddDays(2)
        $candidates += Get-ChildItem (Join-Path $env:SystemRoot 'Fonts') -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '\.(ttf|otf|ttc)$' -and $_.CreationTime -gt $installDate }
    } catch { }
    if ($candidates) {
        New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
        foreach ($f in $candidates) { try { Copy-Item -LiteralPath $f.FullName -Destination $fontDir -Force -ErrorAction Stop; $copied += $f.Name } catch { } }
    }
    $M.Fonts = $copied
    Write-Ok "$($copied.Count) user-installed fonts saved"
}

Invoke-Step 'Start menu and taskbar pins' {
    $pins = [ordered]@{}
    $tb = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    if (Test-Path $tb) {
        $dest = Join-Path $Dirs.Settings 'TaskbarPins'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item (Join-Path $tb '*') $dest -Force -ErrorAction SilentlyContinue
        $pins.Taskbar = @(Get-ChildItem $tb -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object BaseName)
    }
    $start2 = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin'
    if (Test-Path $start2) { Copy-Item $start2 (Join-Path $Dirs.Settings 'start2.bin') -Force; $pins.Start2 = 'Settings\start2.bin' }
    $M.Pins = $pins
    if ($pins.Taskbar) { Write-Ok ("Taskbar pins: {0}" -f ($pins.Taskbar -join ', ')) }
}

# ---------------------------------------------------------------------------
# 7. Browsers
# ---------------------------------------------------------------------------
Write-Section 'Browsers: bookmarks, history, extensions, profiles'

function Get-UserProfileList {
    $list = @()
    try {
        foreach ($p in (Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and $_.LocalPath })) {
            $leaf = Split-Path $p.LocalPath -Leaf
            if ($leaf -match '^(defaultuser\d*|WDAGUtilityAccount|Public|Default)$') { continue }
            if (-not (Test-Path -LiteralPath $p.LocalPath)) { continue }
            $isCur = ($p.LocalPath -ieq $env:USERPROFILE)
            if (-not $IsAdmin -and -not $isCur) { continue }
            $list += [pscustomobject]@{ Name = $leaf; Path = $p.LocalPath; IsCurrent = $isCur }
        }
    } catch { }
    if (-not ($list | Where-Object IsCurrent)) { $list += [pscustomobject]@{ Name = $env:USERNAME; Path = $env:USERPROFILE; IsCurrent = $true } }
    return $list
}

function ConvertTo-BookmarkHtml($BookmarksJson, [string]$Title) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE NETSCAPE-Bookmark-file-1>')
    [void]$sb.AppendLine('<!-- Created by Backup-OldPC.ps1. Import this file in any browser (Bookmarks > Import). -->')
    [void]$sb.AppendLine('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">')
    [void]$sb.AppendLine("<TITLE>Bookmarks</TITLE>`r`n<H1>$([System.Net.WebUtility]::HtmlEncode($Title))</H1>`r`n<DL><p>")
    $script:bmCount = 0
    function Add-Node($node, [int]$depth) {
        $ind = '    ' * $depth
        $date = 0
        try { if ($node.date_added) { $date = [int64]([int64]$node.date_added / 1000000 - 11644473600) } } catch { }
        if ($node.type -eq 'folder') {
            [void]$sb.AppendLine("$ind<DT><H3 ADD_DATE=`"$date`">$([System.Net.WebUtility]::HtmlEncode($node.name))</H3>")
            [void]$sb.AppendLine("$ind<DL><p>")
            foreach ($c in $node.children) { Add-Node $c ($depth + 1) }
            [void]$sb.AppendLine("$ind</DL><p>")
        } elseif ($node.type -eq 'url') {
            $script:bmCount++
            [void]$sb.AppendLine("$ind<DT><A HREF=`"$([System.Net.WebUtility]::HtmlEncode($node.url))`" ADD_DATE=`"$date`">$([System.Net.WebUtility]::HtmlEncode($node.name))</A>")
        }
    }
    foreach ($rootName in 'bookmark_bar', 'other', 'synced') {
        $r = $BookmarksJson.roots.$rootName
        if (-not $r -or -not $r.children -or @($r.children).Count -eq 0) { continue }
        if ($rootName -eq 'bookmark_bar') {
            [void]$sb.AppendLine("    <DT><H3 PERSONAL_TOOLBAR_FOLDER=`"true`">$([System.Net.WebUtility]::HtmlEncode($r.name))</H3>`r`n    <DL><p>")
            foreach ($c in $r.children) { Add-Node $c 2 }
            [void]$sb.AppendLine('    </DL><p>')
        } else { Add-Node $r 1 }
    }
    [void]$sb.AppendLine('</DL><p>')
    return @{ Html = $sb.ToString(); Count = $script:bmCount }
}

function Get-ChromiumExtensions([string]$ProfileDir, [string]$Browser) {
    $exts = @()
    $skip = 'nmmhkkegccagdldgiimedpiccmgmieda|pkedcjkdefgpdelpbcmbmeomcjbeemfm|ghbmnnjooekpmoecnnnilnnbdlolhkhi|mhjfbmdgcfjbbpaeojofohoefgiehjai|neajdppkdcdipfabeoofebfddakdcjhd|aapocclcgogkmnckokdopfmhonfmgoek|felcaaldnbdncclmgdcncolpebgiejap|apdfllckaahabafndbhieahigkjlhalf|blpcfgokakmgnkcojhhkbfbldkacnbeo|pjkljhegncpnkpknbcohdijeoejaedia|coobgpohoikkiipiblmjeljniedjpjpf|jmjflgjpcpepeafmmgdpfkogkghcpiha|ihmafllikibpmigkcoadcmckbfhibefp|kmendfapggjehodndflmmgagdbamhnfd|fikbjbembnmfhppjfnmfkahdhfohhjmg|ncbjelpjchkpbikbpkcchkhkblodoama|mfehgcgbbipciphmccgaenjidiccnmng|dgiklkfkllikcanfonkcabmbdfmgleag'
    $prefs = $null
    try { $prefs = Get-Content -LiteralPath (Join-Path $ProfileDir 'Secure Preferences') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { }
    if (-not $prefs -or -not $prefs.extensions) { try { $prefs = Get-Content -LiteralPath (Join-Path $ProfileDir 'Preferences') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { } }
    $extRoot = Join-Path $ProfileDir 'Extensions'
    foreach ($idDir in (Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($idDir.Name -match "^($skip)$" -or $idDir.Name -eq 'Temp') { continue }
        $verDir = Get-ChildItem -LiteralPath $idDir.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $verDir) { continue }
        $man = Read-JsonFile (Join-Path $verDir.FullName 'manifest.json')
        if (-not $man) { continue }
        $name = "$($man.name)"
        if ($name -match '^__MSG_(.+)__$') {
            $msgKey = $Matches[1]
            foreach ($loc in @($man.default_locale, 'en', 'en_US') | Where-Object { $_ }) {
                $msgs = Read-JsonFile (Join-Path $verDir.FullName "_locales\$loc\messages.json")
                if ($msgs) {
                    $prop = $msgs.PSObject.Properties | Where-Object { $_.Name -ieq $msgKey } | Select-Object -First 1
                    if ($prop) { $name = $prop.Value.message; break }
                }
            }
        }
        $enabled = $true
        try {
            $s = $prefs.extensions.settings.($idDir.Name)
            if ($s) {
                if ($s.state -eq 0 -or ($s.disable_reasons -and @($s.disable_reasons).Count -gt 0 -and "$($s.disable_reasons)" -ne '0')) { $enabled = $false }
                if ($s.location -in 5, 10) { continue }  # component / external component
            }
        } catch { }
        $update = "$($man.update_url)"
        $store = "https://chromewebstore.google.com/detail/$($idDir.Name)"
        if ($update -match 'edge\.microsoft\.com') { $store = "https://microsoftedge.microsoft.com/addons/detail/$($idDir.Name)" }
        elseif ($update -match 'opera\.com') { $store = "https://addons.opera.com/extensions/details/app_id/$($idDir.Name)" }
        $exts += [pscustomobject]@{ Name = $name; Id = $idDir.Name; Version = $verDir.Name -replace '_\d+$', ''; Enabled = $enabled; StoreUrl = $store }
    }
    return @($exts | Sort-Object Name)
}

$Script:BrowserBackups = @()
$Chromium = @(
    @{ Name = 'Chrome';       Rel = 'AppData\Local\Google\Chrome\User Data' }
    @{ Name = 'Edge';         Rel = 'AppData\Local\Microsoft\Edge\User Data' }
    @{ Name = 'Brave';        Rel = 'AppData\Local\BraveSoftware\Brave-Browser\User Data' }
    @{ Name = 'Vivaldi';      Rel = 'AppData\Local\Vivaldi\User Data' }
    @{ Name = 'Chromium';     Rel = 'AppData\Local\Chromium\User Data' }
    @{ Name = 'Opera';        Rel = 'AppData\Roaming\Opera Software\Opera Stable' }
    @{ Name = 'Opera GX';     Rel = 'AppData\Roaming\Opera Software\Opera GX Stable' }
    @{ Name = 'Arc';          Rel = 'AppData\Local\Packages\TheBrowserCompany.Arc_ttt1ap7aakyb4\LocalCache\Local\Arc\User Data' }
    @{ Name = 'Yandex';       Rel = 'AppData\Local\Yandex\YandexBrowser\User Data' }
    @{ Name = 'Thorium';      Rel = 'AppData\Local\Thorium\User Data' }
)
$Gecko = @(
    @{ Name = 'Firefox';     Rel = 'AppData\Roaming\Mozilla\Firefox' }
    @{ Name = 'Waterfox';    Rel = 'AppData\Roaming\Waterfox' }
    @{ Name = 'LibreWolf';   Rel = 'AppData\Roaming\librewolf' }
    @{ Name = 'Floorp';      Rel = 'AppData\Roaming\Floorp' }
    @{ Name = 'Zen';         Rel = 'AppData\Roaming\zen' }
    @{ Name = 'Thunderbird'; Rel = 'AppData\Roaming\Thunderbird' }
)

$Profiles = @(Get-UserProfileList)
if ($Profiles.Count -gt 1) {
    Write-Info ("User accounts on this PC: {0}" -f (($Profiles | ForEach-Object Name) -join ', '))
    if (-not (Ask-YesNo 'Back up browser data for ALL these accounts (not just yours)?' $true)) { $Profiles = @($Profiles | Where-Object IsCurrent) }
}

foreach ($up in $Profiles) {
    # --- Chromium family ---
    foreach ($br in $Chromium) {
        Invoke-Step "$($br.Name) ($($up.Name))" {
            $ud = Join-Path $up.Path $br.Rel
            if (-not (Test-Path -LiteralPath $ud)) { return }
            $localState = Read-JsonFile (Join-Path $ud 'Local State')
            $profDirs = @()
            if (Test-Path -LiteralPath (Join-Path $ud 'Preferences')) { $profDirs += Get-Item -LiteralPath $ud }
            $profDirs += Get-ChildItem -LiteralPath $ud -Directory -ErrorAction SilentlyContinue | Where-Object { ($_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -like '_side_profiles*') -and (Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences')) }
            foreach ($pd in $profDirs) {
                $display = $pd.Name
                $signedIn = ''
                try { $info = $localState.profile.info_cache.($pd.Name); if ($info.name) { $display = $info.name }; if ($info.user_name) { $signedIn = $info.user_name } } catch { }
                $dest = Join-Path $Dirs.Browsers ("{0}\{1}\{2}" -f (Get-SafeName $up.Name), (Get-SafeName $br.Name), (Get-SafeName $pd.Name))
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                $files = @()
                foreach ($f in 'Bookmarks', 'Bookmarks.bak', 'History', 'Favicons', 'Top Sites', 'Shortcuts', 'Preferences', 'Custom Dictionary.txt', 'Web Data') {
                    $src = Join-Path $pd.FullName $f
                    if (Test-Path -LiteralPath $src) {
                        try { Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop; $files += $f } catch { Write-Warn2 "$($br.Name): could not copy '$f' (browser still running?)" }
                    }
                }
                $bmCount = 0
                $bmFile = Join-Path $pd.FullName 'Bookmarks'
                if (Test-Path -LiteralPath $bmFile) {
                    $bm = Read-JsonFile $bmFile
                    if ($bm) {
                        $res = ConvertTo-BookmarkHtml $bm "$($br.Name) - $display"
                        $bmCount = $res.Count
                        $res.Html | Set-Content -LiteralPath (Join-Path $dest 'bookmarks.html') -Encoding UTF8
                    }
                }
                $exts = @(Get-ChromiumExtensions $pd.FullName $br.Name)
                $exts | Export-Csv (Join-Path $dest 'extensions.csv') -NoTypeInformation -Encoding UTF8
                $Script:BrowserBackups += [pscustomobject]@{
                    User = $up.Name; IsCurrentUser = $up.IsCurrent; Browser = $br.Name; Engine = 'Chromium'; ProfileFolder = $pd.Name; ProfileName = $display
                    SignedInAs = $signedIn; Bookmarks = $bmCount; Files = $files; Extensions = $exts
                    BackupFolder = $dest.Substring($B.Length + 1)
                }
                Write-Ok ("{0} [{1}] {2}: {3} bookmarks, {4} extensions{5}" -f $br.Name, $up.Name, $display, $bmCount, $exts.Count, $(if ($signedIn) { ", signed in as $signedIn (sync)" } else { '' }))
            }
        }
    }

    # --- Firefox family / Thunderbird ---
    foreach ($br in $Gecko) {
        Invoke-Step "$($br.Name) ($($up.Name))" {
            $root = Join-Path $up.Path $br.Rel
            $ini = Join-Path $root 'profiles.ini'
            if (-not (Test-Path -LiteralPath $ini)) { return }
            $bdest = Join-Path $Dirs.Browsers ("{0}\{1}" -f (Get-SafeName $up.Name), (Get-SafeName $br.Name))
            New-Item -ItemType Directory -Path $bdest -Force | Out-Null
            Copy-Item -LiteralPath $ini -Destination $bdest -Force
            $installs = Join-Path $root 'installs.ini'
            if (Test-Path -LiteralPath $installs) { Copy-Item -LiteralPath $installs -Destination $bdest -Force }

            # parse profiles.ini
            $sections = @(); $cur = $null
            foreach ($line in (Get-Content -LiteralPath $ini)) {
                if ($line -match '^\[(.+)\]$') { $cur = [ordered]@{ Section = $Matches[1] }; $sections += $cur }
                elseif ($cur -and $line -match '^([^=]+)=(.*)$') { $cur[$Matches[1]] = $Matches[2] }
            }
            $defaultPaths = @($sections | Where-Object { $_.Section -like 'Install*' -and $_.Default } | ForEach-Object { $_.Default })
            foreach ($s in ($sections | Where-Object { $_.Section -like 'Profile*' -and $_.Path })) {
                $pPath = if ($s.IsRelative -eq '1') { Join-Path $root ($s.Path -replace '/', '\') } else { $s.Path }
                if (-not (Test-Path -LiteralPath $pPath)) { continue }
                $isDefault = ($defaultPaths -contains $s.Path) -or ($s.Default -eq '1')
                $folder = Split-Path $pPath -Leaf
                $size = Get-DirSize $pPath
                $dest = Join-Path $bdest (Get-SafeName $folder)
                Write-Info ("{0} [{1}] profile '{2}' ({3}) - copying..." -f $br.Name, $up.Name, $s.Name, (Format-Size $size))
                $ok = Invoke-Robo $pPath $dest @('/XD', 'cache2', 'startupCache', 'thumbnails', 'crashes', 'minidumps', 'datareporting', 'saved-telemetry-pings', 'shader-cache', 'safebrowsing', '/XF', 'parent.lock', 'lock', '.parentlock')
                # extensions
                $exts = @()
                $ej = Read-JsonFile (Join-Path $pPath 'extensions.json')
                if ($ej) {
                    $exts = @($ej.addons | Where-Object { $_.type -eq 'extension' -and $_.location -eq 'app-profile' } | ForEach-Object {
                        $nm = $_.defaultLocale.name
                        [pscustomobject]@{ Name = $nm; Id = $_.id; Version = $_.version; Enabled = [bool]$_.active
                            StoreUrl = "https://addons.mozilla.org/firefox/addon/$([uri]::EscapeDataString($_.id))/"
                            SearchUrl = "https://addons.mozilla.org/firefox/search/?q=$([uri]::EscapeDataString($nm))" }
                    } | Sort-Object Name)
                    $exts | Export-Csv (Join-Path $bdest ((Get-SafeName $folder) + '-extensions.csv')) -NoTypeInformation -Encoding UTF8
                }
                # latest bookmark backup (restorable in Firefox: Bookmarks > Manage > Import and Backup > Restore > Choose File)
                $bmb = Get-ChildItem -LiteralPath (Join-Path $pPath 'bookmarkbackups') -Filter *.jsonlz4 -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($bmb) { Copy-Item -LiteralPath $bmb.FullName -Destination (Join-Path $bdest ((Get-SafeName $folder) + '-bookmarks-backup.jsonlz4')) -Force }
                $Script:BrowserBackups += [pscustomobject]@{
                    User = $up.Name; IsCurrentUser = $up.IsCurrent; Browser = $br.Name; Engine = 'Gecko'; ProfileFolder = $folder; ProfileName = $s.Name
                    IsDefault = $isDefault; SizeBytes = $size; FullProfileCopied = $ok; Extensions = $exts
                    BackupFolder = $dest.Substring($B.Length + 1)
                }
                if ($ok) { Write-Ok ("{0} [{1}] '{2}': full profile copied (bookmarks, history, passwords, extensions, settings), {3} extensions" -f $br.Name, $up.Name, $s.Name, $exts.Count) }
                else { Write-Warn2 "$($br.Name) profile '$($s.Name)' copy had errors (see Logs\robocopy.log)" }
            }
        }
    }
}
$M.Browsers = $Script:BrowserBackups

# Chromium passwords are encrypted to this Windows install and can't be moved as files.
Invoke-Step 'Browser passwords' {
    $chromiumHere = @($Script:BrowserBackups | Where-Object { $_.Engine -eq 'Chromium' -and $_.IsCurrentUser } | Select-Object -ExpandProperty Browser -Unique)
    if (-not $chromiumHere -or $Unattended) { return }
    Write-Host ''
    Write-Host '  Saved passwords in Chrome/Edge/Brave/Opera are encrypted to THIS Windows install.' -ForegroundColor Yellow
    Write-Host '  They will be lost unless (a) the browser is signed in with sync turned on, or (b) you export them now.' -ForegroundColor Yellow
    $synced = @($Script:BrowserBackups | Where-Object { $_.Engine -eq 'Chromium' -and $_.SignedInAs })
    foreach ($s in $synced) { Write-Info "$($s.Browser) '$($s.ProfileName)' is signed in as $($s.SignedInAs) - passwords sync if 'Passwords' sync is on." }
    if (-not (Ask-YesNo 'Export browser passwords to a CSV file now (guided)?' (-not $synced))) { return }
    $pages = @{
        Chrome     = @{ Exe = 'chrome.exe';  Url = 'chrome://password-manager/settings';  Steps = 'Settings tab > "Export passwords" > Export > confirm with your Windows PIN/password > save.' }
        Edge       = @{ Exe = 'msedge.exe';  Url = 'edge://wallet/passwords';             Steps = 'Wallet > Passwords: click the "..." (More options) next to Saved passwords > "Export passwords" > confirm with your Windows PIN/password > save. (Older Edge: Settings > Profiles > Passwords > ... > Export passwords.)' }
        Brave      = @{ Exe = 'brave.exe';   Url = 'brave://password-manager/settings';   Steps = 'Settings tab > "Export passwords" > confirm > save.' }
        Vivaldi    = @{ Exe = 'vivaldi.exe'; Url = 'vivaldi://password-manager/settings'; Steps = 'Settings tab > "Export passwords" > confirm > save.' }
        Opera      = @{ Exe = 'opera.exe';   Url = 'opera://settings/passwords';          Steps = 'Click "..." next to Saved passwords > "Export passwords" > confirm > save.' }
        'Opera GX' = @{ Exe = 'opera.exe';   Url = 'opera://settings/passwords';          Steps = 'Click "..." next to Saved passwords > "Export passwords" > confirm > save.' }
    }
    $started = Get-Date
    foreach ($brw in $chromiumHere) {
        if (-not $pages.ContainsKey($brw)) { continue }
        $pg = $pages[$brw]
        Write-Host ''
        Write-Host "  -> $brw" -ForegroundColor Cyan
        # Browsers may ignore internal pages (edge://, chrome://) given on the command line,
        # so the address also goes on the clipboard to paste into the address bar.
        $clip = $false
        try { Set-Clipboard -Value $pg.Url -ErrorAction Stop; $clip = $true } catch { }
        try { Start-Process -FilePath $pg.Exe -ArgumentList $pg.Url -ErrorAction Stop } catch { Write-Info "Could not start $brw - open it yourself." }
        Write-Info "If the password page did not open: click the address bar, $(if ($clip) { 'press Ctrl+V (already copied)' } else { "type $($pg.Url)" }) and press Enter."
        Write-Info "Address: $($pg.Url)"
        Write-Info "Then: $($pg.Steps)"
        Write-Info 'Save the CSV to Downloads, Desktop or Documents so it is picked up automatically.'
        if (-not $Unattended) { [void](Read-Host '     Press Enter when the export is saved (or to skip)') }
    }
    $pwDir = Join-Path $Dirs.Browsers 'PasswordExports-PRIVATE'
    $found = @()
    foreach ($dir in ([Environment]::GetFolderPath('Desktop')), ([Environment]::GetFolderPath('MyDocuments')), (Join-Path $env:USERPROFILE 'Downloads')) {
        $found += Get-ChildItem -LiteralPath $dir -Filter '*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $started.AddMinutes(-1) -and $_.Name -match 'pass|login|credential' }
    }
    if ($found) {
        New-Item -ItemType Directory -Path $pwDir -Force | Out-Null
        foreach ($f in $found) { Copy-Item -LiteralPath $f.FullName -Destination $pwDir -Force; Write-Ok "Saved $($f.Name) to Browsers\PasswordExports-PRIVATE" }
        if (Ask-YesNo 'Delete the original CSV(s) from this PC? (they are plain-text passwords)' $true) { $found | Remove-Item -Force -ErrorAction SilentlyContinue }
        Write-Warn2 'Password CSV files are PLAIN TEXT. Keep the backup drive private and delete them after importing on the new install.'
        $M.PasswordExports = @($found | ForEach-Object { 'Browsers\PasswordExports-PRIVATE\' + $_.Name })
    } else { Write-Info 'No exported password CSV found in Desktop/Documents/Downloads.' }
}

# ---------------------------------------------------------------------------
# 8. App configuration files
# ---------------------------------------------------------------------------
Write-Section 'App settings and data files'
$Docs = [Environment]::GetFolderPath('MyDocuments')
$AppConfigs = @(
    @{ Name = 'SSH keys and config';          Path = "$env:USERPROFILE\.ssh";        Sensitive = $true }
    @{ Name = 'Git config';                   Path = "$env:USERPROFILE\.gitconfig" }
    @{ Name = 'AWS CLI config';               Path = "$env:USERPROFILE\.aws";        Sensitive = $true }
    @{ Name = 'Kubernetes config';            Path = "$env:USERPROFILE\.kube";       Sensitive = $true }
    @{ Name = 'npm config';                   Path = "$env:USERPROFILE\.npmrc";      Sensitive = $true }
    @{ Name = 'VS Code settings';             Path = "$env:APPDATA\Code\User";       Exclude = @('workspaceStorage', 'History', 'globalStorage', 'logs', 'CachedData') }
    @{ Name = 'Cursor editor settings';       Path = "$env:APPDATA\Cursor\User";     Exclude = @('workspaceStorage', 'History', 'globalStorage', 'logs') }
    @{ Name = 'Windows Terminal settings';    Path = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState" }
    @{ Name = 'PowerShell profile (5.1)';     Path = "$Docs\WindowsPowerShell";      Exclude = @('Modules') }
    @{ Name = 'PowerShell profile (7)';       Path = "$Docs\PowerShell";             Exclude = @('Modules') }
    @{ Name = 'Outlook signatures';           Path = "$env:APPDATA\Microsoft\Signatures" }
    @{ Name = 'Office templates (Normal.dotm)'; Path = "$env:APPDATA\Microsoft\Templates" }
    @{ Name = 'Office custom dictionaries';   Path = "$env:APPDATA\Microsoft\UProof" }
    @{ Name = 'Office Quick Parts / AutoText'; Path = "$env:APPDATA\Microsoft\Document Building Blocks" }
    @{ Name = 'Sticky Notes';                 Path = "$env:LOCALAPPDATA\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState" }
    @{ Name = 'Notepad++ settings';           Path = "$env:APPDATA\Notepad++";       Exclude = @('backup', 'updater') }
    @{ Name = 'OBS Studio scenes/profiles';   Path = "$env:APPDATA\obs-studio";      Exclude = @('logs', 'crashes', 'updates', 'plugin_config\obs-browser\Cache') }
    @{ Name = 'Minecraft worlds and options'; Path = "$env:APPDATA\.minecraft";      Include = @('saves', 'screenshots', 'resourcepacks', 'shaderpacks', 'options.txt', 'servers.dat') }
    @{ Name = 'FileZilla sites';              Path = "$env:APPDATA\FileZilla";       Sensitive = $true }
    @{ Name = 'qBittorrent settings';         Path = "$env:APPDATA\qBittorrent" }
    @{ Name = 'qBittorrent torrents';         Path = "$env:LOCALAPPDATA\qBittorrent\BT_backup" }
    @{ Name = 'mpv config';                   Path = "$env:APPDATA\mpv" }
    @{ Name = 'MPC-HC/BE settings';           Path = "$env:APPDATA\MPC-HC" }
    @{ Name = 'foobar2000';                   Path = "$env:APPDATA\foobar2000-v2" }
    @{ Name = 'ShareX settings/history';      Path = "$Docs\ShareX";                 Exclude = @('Screenshots', 'Logs') }
    @{ Name = 'AutoHotkey scripts (Documents)'; Path = "$Docs\AutoHotkey" }
    @{ Name = 'Rainmeter skins/settings';     Path = "$env:APPDATA\Rainmeter" }
    @{ Name = 'Everything search settings';   Path = "$env:APPDATA\Everything" }
    @{ Name = 'PowerToys settings';           Path = "$env:LOCALAPPDATA\Microsoft\PowerToys";  Exclude = @('Logs', 'Updates', 'PowerToys Run\Logs') }
    @{ Name = 'KeePass database config';      Path = "$env:APPDATA\KeePass" }
    @{ Name = 'PuTTY sessions';               Reg = 'HKCU\Software\SimonTatham' }
    @{ Name = 'WinSCP sessions';              Reg = 'HKCU\Software\Martin Prikryl'; Sensitive = $true }
    @{ Name = 'Logitech G HUB settings';      Path = "$env:LOCALAPPDATA\LGHUB";      Include = @('settings.db', 'settings.json') }
    @{ Name = 'Discord settings (local)';     Path = "$env:APPDATA\discord";         Include = @('settings.json') }
)

Invoke-Step 'App configs' {
    $done = @()
    foreach ($c in $AppConfigs) {
        $dest = Join-Path $Dirs.AppConfigs (Get-SafeName $c.Name)
        if ($c.Reg) {
            $regTest = 'Registry::' + ($c.Reg -replace '^HKCU', 'HKEY_CURRENT_USER')
            if (-not (Test-Path $regTest)) { continue }
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            & reg.exe export $c.Reg (Join-Path $dest 'settings.reg') /y 2>&1 | Out-Null
            $done += [pscustomobject]@{ Name = $c.Name; Source = $c.Reg; Type = 'Registry'; Backup = $dest.Substring($B.Length + 1); Sensitive = [bool]$c.Sensitive }
            Write-Ok $c.Name
            continue
        }
        if (-not $c.Path -or -not (Test-Path -LiteralPath $c.Path)) { continue }
        $item = Get-Item -LiteralPath $c.Path -Force
        if ($item.PSIsContainer) {
            if ($c.Include) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                foreach ($inc in $c.Include) {
                    $src = Join-Path $c.Path $inc
                    if (-not (Test-Path -LiteralPath $src)) { continue }
                    if ((Get-Item -LiteralPath $src).PSIsContainer) { [void](Invoke-Robo $src (Join-Path $dest $inc)) } else { Copy-Item -LiteralPath $src -Destination $dest -Force -ErrorAction SilentlyContinue }
                }
            } else {
                $extra = @()
                if ($c.Exclude) { $extra = @('/XD') + $c.Exclude }
                [void](Invoke-Robo $c.Path $dest $extra)
            }
        } else {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Copy-Item -LiteralPath $c.Path -Destination $dest -Force -ErrorAction SilentlyContinue
        }
        $rel = $c.Path
        if ($rel.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { $rel = '%USERPROFILE%' + $rel.Substring($env:USERPROFILE.Length) }
        $done += [pscustomobject]@{ Name = $c.Name; Source = $rel; Type = $(if ($item.PSIsContainer) { 'Folder' } else { 'File' }); Backup = $dest.Substring($B.Length + 1); Sensitive = [bool]$c.Sensitive }
        Write-Ok ("{0}{1}" -f $c.Name, $(if ($c.Sensitive) { '  (contains secrets - keep private)' } else { '' }))
    }
    # VS Code extensions
    foreach ($cli in 'code', 'cursor') {
        $cmd = Get-Command "$cli.cmd" -ErrorAction SilentlyContinue
        if ($cmd) {
            $list = & $cmd.Source --list-extensions 2>$null
            if ($list) { $list | Set-Content (Join-Path $Dirs.AppConfigs "$cli-extensions.txt") -Encoding UTF8; Write-Ok "$cli extensions: $(@($list).Count)" }
        }
    }
    $M.AppConfigs = $done
}

Invoke-Step 'Outlook data files' {
    $pst = @()
    foreach ($root in (Join-Path $env:LOCALAPPDATA 'Microsoft\Outlook'), $Docs, (Join-Path $env:USERPROFILE 'Documents')) {
        $pst += Get-ChildItem -LiteralPath $root -Filter *.pst -Recurse -ErrorAction SilentlyContinue
    }
    $pst = @($pst | Sort-Object FullName -Unique)
    if (-not $pst) { return }
    $dest = Join-Path $Dirs.AppConfigs 'Outlook-PST'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $M.OutlookPST = @()
    foreach ($p in $pst) {
        try { Copy-Item -LiteralPath $p.FullName -Destination $dest -Force -ErrorAction Stop; $M.OutlookPST += [pscustomobject]@{ File = $p.Name; Original = $p.FullName; Size = Format-Size $p.Length }; Write-Ok "Outlook data file $($p.Name) ($(Format-Size $p.Length))" }
        catch { Write-Warn2 "Could not copy $($p.FullName) (close Outlook and run again)" }
    }
}

Invoke-Step 'Game libraries' {
    $games = [ordered]@{ Steam = @(); Epic = @(); Other = @() }
    $steamPath = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    if ($steamPath) {
        $vdf = Join-Path ($steamPath -replace '/', '\') 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            $libs = [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
            foreach ($lib in $libs) {
                foreach ($acf in (Get-ChildItem (Join-Path $lib 'steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
                    $t = Get-Content $acf.FullName -Raw
                    $nm = if ($t -match '"name"\s+"([^"]+)"') { $Matches[1] } else { $acf.BaseName }
                    $sz = if ($t -match '"SizeOnDisk"\s+"(\d+)"') { [int64]$Matches[1] } else { 0 }
                    $games.Steam += [pscustomobject]@{ Name = $nm; Library = $lib; Size = Format-Size $sz; OnSystemDrive = ($lib.StartsWith($env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)) }
                }
            }
        }
    }
    foreach ($item in (Get-ChildItem 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests' -Filter *.item -ErrorAction SilentlyContinue)) {
        $j = Read-JsonFile $item.FullName
        if ($j) { $games.Epic += [pscustomobject]@{ Name = $j.DisplayName; Location = $j.InstallLocation; Size = Format-Size ([double]$j.InstallSize); OnSystemDrive = ("$($j.InstallLocation)".StartsWith($env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)) } }
    }
    $games.Other = @($Script:AppList | Where-Object { $_.Category -eq 'Game' -and $_.Name -notin $games.Steam.Name } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Location = $_.InstallLocation; Publisher = $_.Publisher } })
    $M.Games = $games
    $sysSteam = @($games.Steam | Where-Object OnSystemDrive)
    if ($games.Steam) { Write-Ok ("Steam: {0} games ({1} on {2})" -f $games.Steam.Count, $sysSteam.Count, $env:SystemDrive) }
    if ($games.Epic) { Write-Ok "Epic: $($games.Epic.Count) games" }
    if ($sysSteam) { Write-Info "Games on other drives can be re-added in Steam (Settings > Storage) without downloading again. Games on $env:SystemDrive must be re-downloaded unless copied." }
    $Saved = Join-Path $env:USERPROFILE 'Saved Games'
    if (Test-Path $Saved) { Write-Info "Some game saves live in '$Saved' and Documents\My Games - included if you back up user folders below." }
}

# ---------------------------------------------------------------------------
# 9. User files
# ---------------------------------------------------------------------------
Write-Section 'User files (Desktop, Documents, Pictures ...)'
$UserFileCandidates = @()
Invoke-Step 'Scan user folders' {
    $UserFileCandidates = @()   # must be local: '+=' on a parent-scope variable starts from `$null in PowerShell 5.1
    $usf = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $known = [ordered]@{ Desktop = 'Desktop'; Documents = 'Personal'; Downloads = '{374DE290-123F-4565-9164-39C4925E467B}'; Pictures = 'My Pictures'; Videos = 'My Video'; Music = 'My Music'; Favorites = 'Favorites'; 'Saved Games' = '{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}'; Contacts = '{56784854-C6CB-462B-8169-88E350ACB882}'; Links = '{BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968}' }
    $oneDriveRoots = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial) | Where-Object { $_ } | Select-Object -Unique
    Write-Info 'Measuring folder sizes (may take a minute)...'
    foreach ($kv in $known.GetEnumerator()) {
        $raw = Get-RegValue $usf $kv.Value
        if (-not $raw) { $raw = Join-Path $env:USERPROFILE $kv.Key }
        $path = [Environment]::ExpandEnvironmentVariables($raw)
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $inOD = [bool]($oneDriveRoots | Where-Object { $path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })
        $UserFileCandidates += [pscustomobject]@{ User = $env:USERNAME; Folder = $kv.Key; Path = $path; SizeBytes = (Get-DirSize $path); OneDrive = $inOD; Kind = 'Known' }
    }
    # Other users' standard folders
    foreach ($up in ($Profiles | Where-Object { -not $_.IsCurrent })) {
        foreach ($f in 'Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'Saved Games') {
            $p = Join-Path $up.Path $f
            if (Test-Path -LiteralPath $p) { $UserFileCandidates += [pscustomobject]@{ User = $up.Name; Folder = $f; Path = $p; SizeBytes = (Get-DirSize $p); OneDrive = $false; Kind = 'Known' } }
        }
    }
    # Non-standard folders in the profile root
    $standard = 'AppData|Application Data|Cookies|Local Settings|My Documents|NetHood|PrintHood|Recent|SendTo|Start Menu|Templates|Desktop|Documents|Downloads|Music|Pictures|Videos|Saved Games|Favorites|Contacts|Links|Searches|3D Objects|IntelGraphicsProfiles|MicrosoftEdgeBackups|ansel|\.vscode|\.cache|\.nuget|\.dotnet|\.templateengine|\.ms-ad|\.cargo|\.rustup|scoop|\.conda|\.vscode-server|\.android|\.gradle|\.m2'
    foreach ($d in (Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($d.Name -match "^($standard)$" -or $d.Name -like 'OneDrive*') { continue }
        if ($AppConfigs | Where-Object { $_.Path -ieq $d.FullName }) { continue }
        $UserFileCandidates += [pscustomobject]@{ User = $env:USERNAME; Folder = $d.Name; Path = $d.FullName; SizeBytes = (Get-DirSize $d.FullName); OneDrive = $false; Kind = 'Profile folder' }
    }
    # Non-standard folders in the root of the system drive
    $sysStd = 'Windows|Program Files|Program Files \(x86\)|ProgramData|Users|\$Recycle\.Bin|\$WinREAgent|\$SysReset|\$Windows\.~BT|\$Windows\.~WS|\$GetCurrent|System Volume Information|Recovery|PerfLogs|OneDriveTemp|MSOCache|Config\.Msi|Documents and Settings|Intel|AMD|NVIDIA|inetpub|Drivers|ESD|Windows\.old|XboxGames|Riot Games|DumpStack\.log\.tmp|SWSetup|Dell|HP|Lenovo|OEM|tmp|temp'
    foreach ($d in (Get-ChildItem -LiteralPath "$env:SystemDrive\" -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($d.Name -match "^($sysStd)$") { continue }
        $UserFileCandidates += [pscustomobject]@{ User = '(drive root)'; Folder = $d.Name; Path = $d.FullName; SizeBytes = (Get-DirSize $d.FullName); OneDrive = $false; Kind = "$env:SystemDrive\ folder" }
    }
    $UserFileCandidates = @($UserFileCandidates | Where-Object { $_.SizeBytes -gt 0 })
    $Script:UserFileCandidates = $UserFileCandidates
}
$UserFileCandidates = $Script:UserFileCandidates
$M.UserFolders = @($UserFileCandidates | ForEach-Object { [pscustomobject]@{ User = $_.User; Folder = $_.Folder; Path = $_.Path; Size = Format-Size $_.SizeBytes; SizeBytes = $_.SizeBytes; OneDrive = $_.OneDrive; Kind = $_.Kind; Copied = $false; Backup = $null } })

Invoke-Step 'Copy user files' {
    if (-not $M.UserFolders) { return }
    $freeBytes = 0
    try { $freeBytes = (Get-PSDrive -Name ((Split-Path $B -Qualifier).TrimEnd(':')) -ErrorAction Stop).Free } catch { }
    Write-Host ''
    Write-Host ("  Folders found (backup drive has {0} free):" -f (Format-Size $freeBytes)) -ForegroundColor White
    Write-Host '  OneDrive folders are already in the cloud if OneDrive finished syncing - copying them may download online-only files.' -ForegroundColor DarkGray
    $recommended = @($M.UserFolders | Where-Object { $_.Kind -eq 'Known' -and $_.User -eq $env:USERNAME -and -not $_.OneDrive -and $_.Folder -ne 'Links' })
    Write-Host '  * = recommended (your Desktop, Documents, Pictures ... that are not already in OneDrive)' -ForegroundColor DarkGray
    $sel = Select-FromList -Items $M.UserFolders -Default $recommended -Label { param($x) ('{0}{1,-14} {2,-20} {3,10}  {4}{5}' -f $(if ($recommended -contains $x) { '* ' } else { '  ' }), $x.User, $x.Folder, $x.Size, $x.Path, $(if ($x.OneDrive) { '  [OneDrive]' } else { '' })) } -Prompt 'Press Enter to copy the * folders (recommended). Or: A = all, N = none, numbers like 1,3,5-7'
    if (-not $sel) { Write-Info 'No user folders copied. Make sure personal files are saved elsewhere before wiping!'; Write-Warn2 'User files were NOT copied by this script.'; return }
    $need = ($sel | Measure-Object SizeBytes -Sum).Sum
    if ($freeBytes -and $need -gt $freeBytes * 0.95) {
        Write-Warn2 ("Selected folders need {0} but only {1} free on the backup drive." -f (Format-Size $need), (Format-Size $freeBytes))
        if (-not (Ask-YesNo 'Copy anyway (it will stop when the drive is full)?' $false)) { return }
    }
    foreach ($f in $sel) {
        $dest = Join-Path $Dirs.UserFiles ("{0}\{1}" -f (Get-SafeName $f.User), (Get-SafeName $f.Folder))
        Write-Info ("Copying {0} {1} ({2})..." -f $f.User, $f.Folder, $f.Size)
        $ok = Invoke-Robo $f.Path $dest @('/XD', 'node_modules', '$RECYCLE.BIN', 'My Music', 'My Pictures', 'My Videos', '/XF', 'desktop.ini', 'Thumbs.db', '*.tmp', '~$*')
        $f.Copied = $ok
        $f.Backup = $dest.Substring($B.Length + 1)
        if ($ok) { Write-Ok "$($f.Folder) copied" } else { Write-Warn2 "$($f.Folder): some files could not be copied (see Logs\robocopy.log)" }
    }
}

# ---------------------------------------------------------------------------
# 10. Report
# ---------------------------------------------------------------------------
Write-Section 'Writing report and checklist'
$M.Warnings = @($Script:Warnings)
$M.Errors = @($Script:Errors)

Invoke-Step 'manifest.json' { Save-Json $M (Join-Path $B 'manifest.json'); Write-Ok 'manifest.json' }

$Script:PageCss = @'
/* Mauve / slate palette. Dark by default, light when the OS is light. */
:root{
  --bg:#3e3e56; --card:#4f4f6e; --card2:#45455f; --fg:#ffffff; --muted:#cdcddb; --line:#606086;
  --accent:#d9c6d0; --btn:#84596f; --btn-hover:#6c495b; --btn-fg:#ffffff; --chip:#606086; --chip-fg:#f8f4f6;
  --warn:#fda4af; --warnbg:rgba(244,63,94,.14); --bad:#fb7185; --done:#a0a0bb;
  --radius-card:14px; --ease-settle:cubic-bezier(0.22,1,0.36,1);
}
@media (prefers-color-scheme: light){:root{
  --bg:#ffffff; --card:#f9f9fb; --card2:#f8f4f6; --fg:#2d2d3f; --muted:#606086; --line:#cdcddb;
  --accent:#84596f; --btn:#84596f; --btn-hover:#6c495b; --chip:#d9c6d0; --chip-fg:#533846;
  --warn:#be123c; --warnbg:#fff1f2; --bad:#e11d48; --done:#74749b;
}}
*{box-sizing:border-box}
html{-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue","Noto Sans",Arial,sans-serif}
main{max-width:1080px;margin:0 auto;padding:32px 16px 72px}
h1{font-size:30px;letter-spacing:-.025em;line-height:1.1;margin:0 0 8px}
h2{font-size:21px;letter-spacing:-.018em;line-height:1.2;margin:36px 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line)}
h3{font-size:16px;letter-spacing:-.012em;margin:20px 0 8px}
a{color:var(--accent);text-underline-offset:2px}
.muted{color:var(--muted)} code{font:13px ui-monospace,SFMono-Regular,Consolas,monospace}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius-card);padding:14px 18px;margin:10px 0}
.warn{background:var(--warnbg);border-color:var(--warn)} .warn li{color:var(--warn)}
table{border-collapse:collapse;width:100%;font-size:14px;background:var(--card);border:1px solid var(--line);border-radius:var(--radius-card);display:block;overflow-x:auto}
table>tbody{display:table;width:100%}
th,td{padding:7px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{background:var(--card2);font-weight:600;white-space:nowrap}
nav{display:flex;flex-wrap:wrap;gap:6px 14px;margin:12px 0}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px 24px}.grid div span{color:var(--muted);display:block;font-size:13px}
.btn{display:inline-block;background:var(--btn);color:var(--btn-fg);text-decoration:none;font-weight:600;font-size:14px;padding:7px 14px;border-radius:999px;white-space:nowrap;transition:background .2s var(--ease-settle),transform .1s ease-out}
.btn:hover{background:var(--btn-hover)} .btn:active{transform:scale(.96)}
.chip{display:inline-block;font-size:12px;letter-spacing:.01em;padding:2px 9px;border-radius:999px;background:var(--chip);color:var(--chip-fg);margin-left:8px;vertical-align:middle}
@media (prefers-reduced-motion: reduce){*{transition:none!important}}
'@
function HtmlTable($Rows, [string[]]$Props) {
    if (-not $Rows -or @($Rows).Count -eq 0) { return '<p class="muted">None found.</p>' }
    $frag = $Rows | Select-Object -Property $Props | ConvertTo-Html -Fragment
    return ($frag -join "`n")
}
function ConvertTo-HtmlText([string]$s) { return [System.Net.WebUtility]::HtmlEncode("$s") }

Invoke-Step 'report.html' {
    $s = $M.System
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PC Backup Report - $(ConvertTo-HtmlText $env:COMPUTERNAME)</title>
<style>
$($Script:PageCss)
</style></head><body><main>
<h1>PC backup report: $(ConvertTo-HtmlText $env:COMPUTERNAME)</h1>
<p class="muted">Created $(Get-Date -Format 'yyyy-MM-dd HH:mm') by $(ConvertTo-HtmlText $env:USERNAME). Backup folder: <code>$(ConvertTo-HtmlText $B)</code></p>
<p><a class="btn" href="apps.html">Open the app download list</a></p>
<nav><a href="#warn">Warnings</a><a href="#sys">System</a><a href="#apps">Apps</a><a href="#lic">Licenses</a><a href="#hw">Drivers &amp; hardware</a><a href="#net">Network</a><a href="#set">Settings</a><a href="#br">Browsers</a><a href="#cfg">App data</a><a href="#games">Games</a><a href="#files">Files</a></nav>
"@)
    [void]$sb.Append('<h2 id="warn">Warnings and things to check</h2>')
    if ($Script:Warnings.Count -or $Script:Errors.Count) {
        [void]$sb.Append('<div class="card warn"><ul>')
        foreach ($w in $Script:Warnings) { [void]$sb.Append("<li>$(ConvertTo-HtmlText $w)</li>") }
        foreach ($e in $Script:Errors) { [void]$sb.Append("<li style='color:var(--bad)'>$(ConvertTo-HtmlText $e)</li>") }
        [void]$sb.Append('</ul></div>')
    } else { [void]$sb.Append('<p>No warnings.</p>') }

    [void]$sb.Append('<h2 id="sys">System</h2><div class="card grid">')
    foreach ($k in 'Manufacturer', 'Model', 'SerialNumber', 'Motherboard', 'BIOS', 'CPU', 'RAM', 'OS', 'Version', 'Build', 'FirmwareType', 'SecureBoot', 'TPM', 'InstallDate') { [void]$sb.Append("<div><span>$k</span>$(ConvertTo-HtmlText $s.$k)</div>") }
    [void]$sb.Append("<div><span>Windows license</span>$(ConvertTo-HtmlText $M.License.Status) - $(ConvertTo-HtmlText $M.License.Channel)</div>")
    if ($M.License.OEMKeyInFirmware) { [void]$sb.Append("<div><span>OEM key (firmware)</span><code>$(ConvertTo-HtmlText $M.License.OEMKeyInFirmware)</code></div>") }
    if ($M.License.InstalledKeyDecoded) { [void]$sb.Append("<div><span>Installed key (may be generic)</span><code>$(ConvertTo-HtmlText $M.License.InstalledKeyDecoded)</code></div>") }
    [void]$sb.Append('</div>')
    [void]$sb.Append('<h3>Graphics</h3>' + (HtmlTable $s.GPUs @('Name', 'DriverVersion', 'VRAM')))
    [void]$sb.Append('<h3>Displays</h3>' + (HtmlTable $M.Displays @('Monitor', 'Width', 'Height', 'RefreshHz', 'Primary', 'Adapter')))
    [void]$sb.Append('<h3>Disks</h3>' + (HtmlTable $s.Disks @('Model', 'Type', 'Size', 'Health')))
    [void]$sb.Append('<h3>Drives</h3>' + (HtmlTable $s.Volumes @('Drive', 'Label', 'FileSystem', 'Size', 'Free', 'Note')))

    [void]$sb.Append('<h2 id="apps">Installed programs</h2><p class="muted">Programs with a winget ID can be reinstalled automatically by Setup-NewPC.ps1. Full list: Apps\installed-programs.csv</p>')
    foreach ($cat in 'Application', 'Peripheral software', 'Game launcher', 'Game', 'Driver / hardware', 'Runtime / framework') {
        $rows = @($M.Apps | Where-Object Category -eq $cat)
        if (-not $rows) { continue }
        [void]$sb.Append("<h3>$(ConvertTo-HtmlText $cat) ($($rows.Count))</h3>" + (HtmlTable $rows @('Name', 'Version', 'Publisher', 'WingetId')))
    }
    $storeRows = @($M.StoreApps | Where-Object { -not $_.Inbox })
    [void]$sb.Append("<h3>Microsoft Store apps ($($storeRows.Count))</h3>" + (HtmlTable $storeRows @('Name', 'Publisher', 'Version')))

    [void]$sb.Append('<h2 id="lic">Licenses and sign-ins to sort out BEFORE wiping</h2><p class="muted">Deactivate / sign out where the software limits the number of activations, and make sure you have the keys or account logins.</p>')
    [void]$sb.Append((HtmlTable @($M.Apps | Where-Object NeedsLicense) @('Name', 'Version', 'Publisher')))

    [void]$sb.Append('<h2 id="hw">Drivers and hardware</h2>')
    [void]$sb.Append('<h3>Peripherals (USB)</h3>' + (HtmlTable $M.Hardware.Peripherals @('Vendor', 'Device', 'SuggestedSoftware', 'VID', 'PID')))
    [void]$sb.Append('<h3>Sound devices</h3>' + (HtmlTable $M.Hardware.AudioEndpoints @('Type', 'Name', 'Device')))
    if ($M.Hardware.Bluetooth) { [void]$sb.Append('<h3>Paired Bluetooth devices (re-pair after reinstall)</h3><p>' + (ConvertTo-HtmlText ($M.Hardware.Bluetooth -join ', ')) + '</p>') }
    [void]$sb.Append('<h3>Network adapters</h3>' + (HtmlTable $M.Hardware.NetworkAdapters @('Name', 'Description', 'Status', 'Speed')))
    [void]$sb.Append('<h3>Third-party drivers</h3>' + (HtmlTable $M.Drivers @('Class', 'Device', 'Provider', 'Version', 'Date')))
    if ($M.Hardware.ProblemDevices) { [void]$sb.Append('<h3>Devices with problems right now</h3>' + (HtmlTable $M.Hardware.ProblemDevices @('Name', 'Class', 'Status'))) }

    [void]$sb.Append('<h2 id="net">Network and printers</h2>')
    [void]$sb.Append('<h3>Wi-Fi networks saved</h3><p>' + (ConvertTo-HtmlText (($M.Network.WiFiProfiles) -join ', ')) + '</p>')
    [void]$sb.Append('<h3>Active adapters</h3>' + (HtmlTable $M.Network.Adapters @('Name', 'IPv4', 'Gateway', 'DNS', 'DHCP')))
    [void]$sb.Append('<h3>Mapped network drives</h3>' + (HtmlTable $M.Network.MappedDrives @('Letter', 'Path', 'User')))
    [void]$sb.Append('<h3>VPN connections</h3>' + (HtmlTable $M.Network.VPN @('Name', 'Server', 'Type')))
    if ($M.Network.HostsEntries) { [void]$sb.Append('<h3>Custom hosts entries</h3><pre>' + (ConvertTo-HtmlText ($M.Network.HostsEntries -join "`n")) + '</pre>') }
    [void]$sb.Append('<h3>Printers</h3>' + (HtmlTable $M.Printers @('Name', 'Driver', 'IP', 'Port', 'Default')))

    [void]$sb.Append('<h2 id="set">Windows settings</h2>')
    [void]$sb.Append("<div class='card grid'><div><span>Time zone</span>$(ConvertTo-HtmlText $M.Region.TimeZone)</div><div><span>Regional format</span>$(ConvertTo-HtmlText $M.Region.Culture)</div><div><span>Languages / keyboards</span>$(ConvertTo-HtmlText (($M.Region.Languages | ForEach-Object Tag) -join ', '))</div><div><span>Power plan</span>$(ConvertTo-HtmlText $M.Power.ActiveName)</div></div>")
    [void]$sb.Append((HtmlTable $M.Settings @('Category', 'Description', 'Value')))
    [void]$sb.Append('<h3>Default apps</h3>' + (HtmlTable $M.DefaultApps @('Type', 'ProgId')))
    [void]$sb.Append('<h3>Startup programs</h3>' + (HtmlTable $M.Startup @('Name', 'Command')))
    [void]$sb.Append('<h3>Scheduled tasks (non-Microsoft)</h3>' + (HtmlTable $M.ScheduledTasks @('Name', 'State', 'Action')))
    if ($M.SavedCredentialTargets) { [void]$sb.Append('<h3>Saved Windows credentials (re-enter after reinstall)</h3><p>' + (ConvertTo-HtmlText ($M.SavedCredentialTargets -join ', ')) + '</p>') }
    if ($M.WSL) { [void]$sb.Append('<h3>WSL distributions</h3>' + (HtmlTable $M.WSL @('Name', 'Size', 'Exported'))) }

    [void]$sb.Append('<h2 id="br">Browsers</h2><p class="muted">bookmarks.html files can be imported into any browser. Firefox/Thunderbird profiles are full copies.</p>')
    foreach ($brw in $M.Browsers) {
        [void]$sb.Append("<div class='card'><b>$(ConvertTo-HtmlText $brw.Browser)</b> - $(ConvertTo-HtmlText $brw.ProfileName) <span class='muted'>(user $(ConvertTo-HtmlText $brw.User), folder <code>$(ConvertTo-HtmlText $brw.BackupFolder)</code>)</span>")
        if ($brw.SignedInAs) { [void]$sb.Append("<br>Signed in as $(ConvertTo-HtmlText $brw.SignedInAs) (sync)") }
        if ($brw.Engine -eq 'Chromium') { [void]$sb.Append("<br>$($brw.Bookmarks) bookmarks") }
        if ($brw.Extensions) {
            [void]$sb.Append('<ul>')
            foreach ($e in $brw.Extensions) { [void]$sb.Append("<li><a href='$(ConvertTo-HtmlText $e.StoreUrl)'>$(ConvertTo-HtmlText $e.Name)</a>$(if (-not $e.Enabled) { ' <span class=muted>(disabled)</span>' })</li>") }
            [void]$sb.Append('</ul>')
        }
        [void]$sb.Append('</div>')
    }

    [void]$sb.Append('<h2 id="cfg">App settings and data backed up</h2>' + (HtmlTable $M.AppConfigs @('Name', 'Source', 'Backup')))
    if ($M.OutlookPST) { [void]$sb.Append('<h3>Outlook data files</h3>' + (HtmlTable $M.OutlookPST @('File', 'Size', 'Original'))) }

    [void]$sb.Append('<h2 id="games">Games</h2>')
    [void]$sb.Append('<h3>Steam</h3>' + (HtmlTable $M.Games.Steam @('Name', 'Size', 'Library', 'OnSystemDrive')))
    if ($M.Games.Epic) { [void]$sb.Append('<h3>Epic</h3>' + (HtmlTable $M.Games.Epic @('Name', 'Size', 'Location'))) }
    if ($M.Games.Other) { [void]$sb.Append('<h3>Other games</h3>' + (HtmlTable $M.Games.Other @('Name', 'Publisher', 'Location'))) }

    [void]$sb.Append('<h2 id="files">User files</h2>' + (HtmlTable $M.UserFolders @('User', 'Folder', 'Size', 'OneDrive', 'Copied', 'Path')))
    [void]$sb.Append('</main></body></html>')
    $sb.ToString() | Set-Content (Join-Path $B 'report.html') -Encoding UTF8
    Write-Ok 'report.html'
}

Invoke-Step 'apps.html' {
    $sb = New-Object System.Text.StringBuilder
    function Add-Row([string]$Name, [string]$Meta, [string]$Url, [string]$LinkText, [bool]$Auto) {
        $key = 'pcapps:' + $Name.ToLowerInvariant()
        $chip = if ($Auto) { '<span class="chip">installed by setup</span>' } else { '' }
        [void]$sb.Append("<li data-n=""$(ConvertTo-HtmlText $Name.ToLowerInvariant())""><label><input type=""checkbox"" data-k=""$(ConvertTo-HtmlText $key)""><span><b>$(ConvertTo-HtmlText $Name)</b>$chip<br><span class=""muted small"">$(ConvertTo-HtmlText $Meta)</span></span></label><a class=""btn"" href=""$(ConvertTo-HtmlText $Url)"" target=""_blank"" rel=""noopener"">$(ConvertTo-HtmlText $LinkText)</a></li>")
    }
    function Add-Section([string]$Title, [string]$Intro) {
        [void]$sb.Append("<section><h2>$(ConvertTo-HtmlText $Title)</h2>")
        if ($Intro) { [void]$sb.Append("<p class=""muted"">$(ConvertTo-HtmlText $Intro)</p>") }
        [void]$sb.Append('<ul class="apps">')
    }
    function Close-Section { [void]$sb.Append('</ul></section>') }
    $linkText = @{ site = 'Official site'; store = 'Microsoft Store'; search = 'Find download' }

    [void]$sb.Append(@"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>App List - $(ConvertTo-HtmlText $env:COMPUTERNAME)</title>
<style>
$($Script:PageCss)
.how{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;margin:18px 0}
.how div{background:var(--card);border:1px solid var(--line);border-radius:var(--radius-card);padding:12px 16px}
.how b{display:block;font-size:22px;color:var(--accent)}
.bar{position:sticky;top:0;background:var(--bg);padding:12px 0;z-index:2;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
.bar input{flex:1;min-width:200px;font:inherit;color:var(--fg);background:var(--card);border:1px solid var(--line);border-radius:999px;padding:9px 16px}
.bar input:focus{outline:2px solid var(--accent);outline-offset:1px}
ul.apps{list-style:none;margin:0;padding:0;display:grid;gap:8px}
ul.apps li{display:flex;align-items:center;justify-content:space-between;gap:12px;background:var(--card);border:1px solid var(--line);border-radius:var(--radius-card);padding:10px 14px;transition:opacity .3s var(--ease-settle)}
ul.apps label{display:flex;align-items:center;gap:12px;cursor:pointer;min-width:0;flex:1}
ul.apps label > span{min-width:0;overflow-wrap:anywhere}
ul.apps input[type=checkbox]{width:22px;height:22px;accent-color:var(--btn);flex:none}
ul.apps li.done{opacity:.55} ul.apps li.done b{text-decoration:line-through;color:var(--done)}
.small{font-size:13px} .hidden{display:none!important}
@media (max-width:520px){ul.apps li{flex-direction:column;align-items:stretch}.btn{text-align:center}}
</style></head><body><main>
<h1>Apps from $(ConvertTo-HtmlText $env:COMPUTERNAME)</h1>
<p class="muted">Saved $(Get-Date -Format 'd MMMM yyyy'). Everything that was installed on the old PC, with a link to get it again.</p>
<div class="how">
<div><b>1</b>Apps marked <span class="chip" style="margin:0">installed by setup</span> are installed for you by the setup program (step 4). Nothing to do.</div>
<div><b>2</b>For the rest, click the button. It opens the download page in your browser. Install the app.</div>
<div><b>3</b>Tick the box when it is done. Ticks are remembered on this computer.</div>
</div>
<div class="bar"><input id="q" type="search" placeholder="Search apps..." aria-label="Search apps"><span id="count" class="muted small"></span></div>
"@)

    $links = @($M.AppLinks)
    $groups = [ordered]@{
        'Apps' = @($links | Where-Object { $_.Category -eq 'Application' })
        'Mouse, keyboard and other device software' = @($links | Where-Object { $_.Category -eq 'Peripheral software' })
        'Games and game launchers' = @($links | Where-Object { $_.Category -in 'Game launcher', 'Game' })
    }
    $intros = @{
        'Mouse, keyboard and other device software' = 'After installing, set up DPI, buttons, macros and lighting again.'
        'Games and game launchers' = 'Sign in to the launcher first. Games on another drive can usually be found again instead of downloaded (look for "Locate" or "Add library folder").'
    }
    foreach ($g in $groups.Keys) {
        $rows = $groups[$g]
        if (-not $rows) { continue }
        Add-Section $g $intros[$g]
        foreach ($r in ($rows | Sort-Object @{ Expression = { $_.Auto } }, Name)) {
            $meta = (@($r.Publisher, $(if ($r.LinkType -eq 'search') { 'opens a web search' } else { '' })) | Where-Object { $_ }) -join ' - '
            Add-Row $r.Name $meta $r.Link $linkText[$r.LinkType] ([bool]$r.Auto)
        }
        Close-Section
    }

    $periph = @($M.Hardware.Peripherals | Where-Object SuggestedSoftware)
    if ($periph) {
        Add-Section 'Devices that were plugged in' 'Software these devices usually need. Skip any you already installed above.'
        foreach ($p in $periph) {
            $sw = ($p.SuggestedSoftware -replace ' /.*$', '' -replace ' \(.*$', '')
            Add-Row "$($p.Vendor): $sw" $p.Device ('https://www.google.com/search?q=' + [uri]::EscapeDataString("$sw download")) 'Find download' $false
        }
        Close-Section
    }

    $store = @($M.StoreApps | Where-Object { -not $_.Inbox })
    $haveNames = @($links | ForEach-Object Name)
    $store = @($store | Where-Object { $haveNames -notcontains $_.DisplayName })
    if ($store) {
        Add-Section 'Microsoft Store apps' ''
        foreach ($a in $store) {
            $nm = if ($a.DisplayName) { $a.DisplayName } else { $a.Name }
            Add-Row $nm $a.Publisher ('https://apps.microsoft.com/search?query=' + [uri]::EscapeDataString($nm)) 'Microsoft Store' $false
        }
        Close-Section
    }

    # Drivers
    $s = $M.System
    $drv = @()
    foreach ($gpu in @($s.GPUs | ForEach-Object Name)) {
        if ($gpu -match 'NVIDIA') { $drv += ,@("Graphics: $gpu", 'NVIDIA driver / NVIDIA App', 'https://www.nvidia.com/en-us/drivers/', 'Official site') }
        elseif ($gpu -match 'AMD|Radeon') { $drv += ,@("Graphics: $gpu", 'AMD Software: Adrenalin', 'https://www.amd.com/en/support/download/drivers.html', 'Official site') }
        elseif ($gpu -match 'Intel') { $drv += ,@("Graphics: $gpu", 'Intel Driver & Support Assistant', 'https://www.intel.com/content/www/us/en/support/detect.html', 'Official site') }
    }
    if ($s.CPUVendor -eq 'AMD') { $drv += ,@('Chipset (AMD)', 'AMD chipset driver', 'https://www.amd.com/en/support/download/drivers.html', 'Official site') }
    if ($s.CPUVendor -eq 'Intel') { $drv += ,@('Chipset (Intel)', 'Intel Driver & Support Assistant', 'https://www.intel.com/content/www/us/en/support/detect.html', 'Official site') }
    if ($s.Motherboard) { $drv += ,@("Motherboard: $($s.Motherboard)", 'Audio, network (LAN / Wi-Fi), chipset, BIOS', ('https://www.google.com/search?q=' + [uri]::EscapeDataString("$($s.Motherboard) support drivers")), 'Find support page') }
    if ($s.Manufacturer -and $s.Manufacturer -notmatch 'System manufacturer|To Be Filled|Default string') { $drv += ,@("Computer: $($s.Manufacturer) $($s.Model)", 'All drivers from the maker', ('https://www.google.com/search?q=' + [uri]::EscapeDataString("$($s.Manufacturer) $($s.Model) drivers support")), 'Find support page') }
    if ($drv) {
        Add-Section 'Drivers' 'Install these after Windows Update has finished. The graphics driver matters most for games.'
        foreach ($d in $drv) { Add-Row $d[0] $d[1] $d[2] $d[3] $false }
        Close-Section
    }

    # Browser extensions (this user's)
    foreach ($brw in @($M.Browsers | Where-Object { $_.IsCurrentUser -and $_.Extensions })) {
        $ext = @($brw.Extensions | Where-Object Enabled)
        if (-not $ext) { continue }
        Add-Section "$($brw.Browser) extensions ($($brw.ProfileName))" "Open in $($brw.Browser), then click Add / Get."
        foreach ($e in $ext) {
            $u = if ($brw.Engine -eq 'Gecko' -and $e.SearchUrl) { $e.SearchUrl } else { $e.StoreUrl }
            Add-Row $e.Name "$($brw.Browser) extension" $u 'Add-on page' $false
        }
        Close-Section
    }

    [void]$sb.Append(@'
<p class="muted small" style="margin-top:40px">Full details (settings, drivers, files) are in <a href="report.html">report.html</a>.</p>
</main>
<script>
(function(){
  var store = { get:function(k){ try { return localStorage.getItem(k); } catch(e){ return null; } },
                set:function(k,v){ try { if (v) localStorage.setItem(k,'1'); else localStorage.removeItem(k); } catch(e){} } };
  var boxes = document.querySelectorAll('input[data-k]');
  function refresh(){
    var done = 0;
    boxes.forEach(function(b){ var li = b.closest('li'); li.classList.toggle('done', b.checked); if (b.checked) done++; });
    document.getElementById('count').textContent = done + ' of ' + boxes.length + ' done';
  }
  boxes.forEach(function(b){ b.checked = store.get(b.dataset.k) === '1'; b.addEventListener('change', function(){ store.set(b.dataset.k, b.checked); refresh(); }); });
  document.getElementById('q').addEventListener('input', function(e){
    var q = e.target.value.trim().toLowerCase();
    document.querySelectorAll('ul.apps li').forEach(function(li){ li.classList.toggle('hidden', q && li.dataset.n.indexOf(q) < 0); });
    document.querySelectorAll('section').forEach(function(sec){ sec.classList.toggle('hidden', !sec.querySelector('li:not(.hidden)')); });
  });
  refresh();
})();
</script>
</body></html>
'@)
    $sb.ToString() | Set-Content (Join-Path $B 'apps.html') -Encoding UTF8
    Write-Ok 'apps.html (clickable download list)'
}

Invoke-Step 'CHECKLIST.txt' {
    $c = New-Object System.Collections.ArrayList
    $add = { param($t) [void]$c.Add($t) }
    & $add "BEFORE YOU WIPE THIS PC  -  $env:COMPUTERNAME  -  $(Get-Date -Format 'yyyy-MM-dd')"
    & $add '======================================================================'
    & $add ''
    & $add '[ ] Open report.html and read the Warnings section.'
    & $add '[ ] Copy this whole backup folder to a second place (another drive / cloud) if it matters.'
    & $add '[ ] Plug the backup drive into another computer and check that files open.'
    $notCopied = @($M.UserFolders | Where-Object { -not $_.Copied -and -not $_.OneDrive -and $_.SizeBytes -gt 1MB })
    if ($notCopied) {
        & $add '[ ] These folders were NOT copied - make sure they are saved elsewhere or not needed:'
        foreach ($f in $notCopied) { & $add ("      - {0} {1} ({2})  {3}" -f $f.User, $f.Folder, $f.Size, $f.Path) }
    }
    if ($M.UserFolders | Where-Object OneDrive) { & $add '[ ] OneDrive: open the OneDrive icon and confirm "Your files are synced" before wiping.' }
    & $add '[ ] Phone authenticator app (2FA) works - you will need it to sign in to everything again.'
    & $add '[ ] Know the password for your Microsoft account / email / browser sync account.'
    $synced = @($M.Browsers | Where-Object SignedInAs)
    if ($synced) { & $add ('[ ] Browser sync is on for: ' + (($synced | ForEach-Object { "$($_.Browser) ($($_.SignedInAs))" }) -join ', ') + ' - check sync includes passwords.') }
    if (-not $M.PasswordExports -and ($M.Browsers | Where-Object { $_.Engine -eq 'Chromium' -and -not $_.SignedInAs })) { & $add '[ ] Chrome/Edge passwords were NOT exported and the browser is not syncing - export them now or they are lost.' }
    $lic = @($M.Apps | Where-Object NeedsLicense)
    if ($lic) {
        & $add '[ ] Deactivate / sign out / find license keys for:'
        foreach ($a in $lic) { & $add "      - $($a.Name)" }
    }
    if ($M.BitLocker | Where-Object { $_.Protection -eq 'On' }) { & $add '[ ] BitLocker keys saved in System\BitLocker-RecoveryKeys-PRIVATE.txt (needed to unlock other encrypted drives).' }
    $sysGames = @($M.Games.Steam | Where-Object OnSystemDrive)
    if ($sysGames) { & $add "[ ] $($sysGames.Count) Steam games are on $env:SystemDrive and will need re-downloading (or move them to another drive in Steam > Settings > Storage first)." }
    & $add '[ ] Game saves without cloud sync (Documents\My Games, Saved Games, %APPDATA% for some games) are backed up.'
    & $add '[ ] Note any Wi-Fi password you do not know, in case the Wi-Fi export does not work.'
    & $add '[ ] Have a Windows install USB ready (Media Creation Tool) and the network driver backup (Drivers\Export).'
    & $add ''
    & $add 'WHEN REINSTALLING'
    & $add '----------------------------------------------------------------------'
    & $add "[ ] Only delete/format the Windows partition(s) on the system disk. Leave data drives alone:"
    foreach ($v in $M.System.Volumes) { & $add ("      {0} {1} {2} - {3}" -f $v.Drive, $v.Label, $v.Size, $v.Note) }
    & $add '[ ] Unplug other drives during install if unsure (prevents formatting the wrong one).'
    & $add '[ ] Afterwards run 2-SETUP-NEW-PC.bat from this drive.'
    $c | Set-Content (Join-Path $B 'CHECKLIST.txt') -Encoding UTF8
    Write-Ok 'CHECKLIST.txt'
}

Write-Info 'Calculating backup size...'
# Re-walking copied user files on a USB drive can take many minutes; reuse the sizes measured before copying.
$total = [int64](@($M.UserFolders | Where-Object Copied | ForEach-Object { [int64]$_.SizeBytes }) | Measure-Object -Sum).Sum
foreach ($d in (Get-ChildItem -LiteralPath $B -Force -ErrorAction SilentlyContinue)) {
    if ($d.Name -eq 'UserFiles') { continue }
    if ($d.PSIsContainer) { $total += Get-DirSize $d.FullName } else { $total += $d.Length }
}
try { Stop-Transcript | Out-Null } catch { }

Write-Host ''
Write-Host '======================================================================' -ForegroundColor Green
Write-Host "  BACKUP COMPLETE  ($(Format-Size $total))" -ForegroundColor Green
Write-Host "  $B" -ForegroundColor Green
Write-Host '======================================================================' -ForegroundColor Green
if ($Script:Warnings.Count) {
    Write-Host ''
    Write-Host '  Warnings:' -ForegroundColor Yellow
    foreach ($w in $Script:Warnings) { Write-Host "   - $w" -ForegroundColor Yellow }
}
if ($Script:Errors.Count) {
    Write-Host ''
    Write-Host "  $($Script:Errors.Count) sections failed (details in Logs\errors.log)." -ForegroundColor Red
}
Write-Host ''
Write-Host '  Files containing secrets (keep the drive private):' -ForegroundColor Yellow
Write-Host '   Network\WiFi (Wi-Fi passwords), System\BitLocker-*, Browsers\PasswordExports-PRIVATE, Browsers\*\Firefox (saved logins), AppConfigs\SSH*' -ForegroundColor Yellow
Write-Host ''
Write-Host '  Next: read CHECKLIST.txt before wiping. After reinstalling, run 2-SETUP-NEW-PC.bat.' -ForegroundColor Cyan
if (-not $Unattended) {
    try { Start-Process (Join-Path $B 'report.html') } catch { }
    try { Start-Process (Join-Path $B 'apps.html') } catch { }
    try { Start-Process notepad.exe (Join-Path $B 'CHECKLIST.txt') } catch { }
    [void](Read-Host '  Press Enter to close')
}
