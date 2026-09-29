<#
.SYNOPSIS
    Windows version of host/flash-and-provision.sh: flash the golden S3 gateway
    image to an SD card and write that card's GATEWAY_ID (plus optional site
    files) to its boot partition.

.DESCRIPTION
    Same job and same on-card result as the Linux script, so
    image/firstboot/s3-gateway-firstboot.sh picks the card up on first boot
    exactly as it does for a card made on Linux. Run it on the provisioning PC,
    NOT on a gateway.

    Needs Administrator rights (it writes straight to the disk). Easiest start:
    double-click flash-and-provision.bat, which asks for them. Run with no
    arguments and the script asks for whatever it needs.

    Safety: it never touches the Windows system/boot disk, only offers USB / SD
    card disks (override: -AllowNonRemovable), shows what is on the disk before
    erasing it, and makes you retype the disk number to confirm.

.PARAMETER Image
    Path to the golden .img file (not needed with -NoFlash).
.PARAMETER DiskNumber
    Windows disk number of the SD card (see -ListDisks). Omit to pick from a list.
.PARAMETER GatewayId
    GATEWAY_ID for this card, e.g. s3-gw-03. Letters, digits and '-' only,
    because it also becomes the Pi's hostname.
.PARAMETER SiteDir
    Folder holding this gateway's site files, used exactly as given.
.PARAMETER Site
    Site name. With -SiteFilesRoot the folder used is <SiteFilesRoot>\<Site>.
.PARAMETER SiteFilesRoot
    Folder containing one sub-folder per site.
.PARAMETER Batch
    CSV file (header: gateway_id,site) - one card per row, prompts between cards.
.PARAMETER NoFlash
    Do not write the image. Only (re)write provision.env and the site files on
    a card that is already flashed.
.PARAMETER KeepLineEndings
    Copy samplelist.csv / pygw_conf.py byte-for-byte. By default Windows line
    endings (CRLF) and a UTF-8 BOM are converted to Linux style, because the
    gateway runs Linux.
.PARAMETER AllowNonRemovable
    Also offer disks that are not on a USB / SD bus. Use with great care.
.PARAMETER ListDisks
    Show the disks this script would offer, then exit.
.PARAMETER PauseAtEnd
    Used by flash-and-provision.bat. Waits for Enter before finishing, so a
    double-clicked window does not vanish before the result can be read, and
    makes relative paths start from this script's own folder.

.EXAMPLE
    .\flash-and-provision.ps1
    Guided mode: asks for the image, gateway ID, site folder and disk.

.EXAMPLE
    .\flash-and-provision.ps1 -Image D:\images\deb13-arm64-min.img -DiskNumber 2 -GatewayId s3-gw-03
    One card, no site files (keeps the image's sample samplelist.csv).

.EXAMPLE
    .\flash-and-provision.ps1 -Image D:\images\golden.img -DiskNumber 2 -GatewayId s3-gw-99 -SiteDir .\site-files
    One card, site files taken straight from .\site-files

.EXAMPLE
    .\flash-and-provision.ps1 -Image D:\images\golden.img -DiskNumber 2 -GatewayId s3-gw-99 -SiteFilesRoot .\site-files -Site siteA
    One card, site files taken from .\site-files\siteA

.EXAMPLE
    .\flash-and-provision.ps1 -Image D:\images\golden.img -DiskNumber 2 -Batch .\gateways.csv -SiteFilesRoot .\site-files
    Many cards: one CSV row per card, site files from .\site-files\<site>

.EXAMPLE
    .\flash-and-provision.ps1 -NoFlash -DiskNumber 2 -GatewayId s3-gw-07
    Re-provision an already flashed card without re-flashing it.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Image,
    [int]$DiskNumber = -1,
    [string]$GatewayId,
    [string]$SiteDir,
    [string]$Site,
    [string]$SiteFilesRoot,
    [string]$Batch,
    [switch]$NoFlash,
    [switch]$KeepLineEndings,
    [switch]$AllowNonRemovable,
    [switch]$ListDisks,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'

$script:ProvisionDirName = 's3-gateway-provision'
$script:ChunkBytes       = 4MB
$script:FlushEveryBytes  = 64MB
# Same rule s3-gateway-firstboot.sh applies before it accepts GATEWAY_ID as a hostname.
$script:GatewayIdPattern = '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z'
$script:CardBuses        = @('USB', 'SD', 'MMC')
$script:GuardPaths       = @()
$script:DiskFromParam    = $false
$script:ImageBytes       = [long]0

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Warn { param([string]$Message) Write-Host "WARNING: $Message" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Message) Write-Host $Message -ForegroundColor Red }

function Test-IsWindows { return ($env:OS -eq 'Windows_NT') }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-Line {
    param([string]$Prompt)
    $v = Read-Host $Prompt
    if ($null -eq $v) { return '' }
    return $v.Trim()
}

function Resolve-UserPath {
    # Accepts relative paths (against the current PowerShell folder) and the
    # quotes you get when you drag a file into the window.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    if ($p.StartsWith('& ')) { $p = $p.Substring(2).Trim() }
    $p = $p.Trim('"', "'")
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-Location).ProviderPath $p }
    return [IO.Path]::GetFullPath($p)
}

function Test-GatewayId {
    param([string]$Value)
    return ($Value -cmatch $script:GatewayIdPattern)
}

function Assert-GatewayId {
    param([string]$Value)
    if (-not (Test-GatewayId -Value $Value)) {
        throw "Invalid gateway ID '$Value'. Use letters, digits and '-' only (max 63 characters, no leading or trailing '-') - it becomes the Pi's hostname."
    }
}

function Test-SiteName {
    param([string]$Value)
    return (($Value -notmatch '[\\/:]') -and ($Value -ne '.') -and ($Value -ne '..'))
}

# ---------------------------------------------------------------------------
# Raw disk writer (Windows only). Compiled on demand so -ListDisks and
# -NoFlash never need it. Kept to C# 5 so Windows PowerShell 5.1 can build it.
# ---------------------------------------------------------------------------
function Initialize-RawDiskType {
    if ('S3Gw.RawDisk' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace S3Gw
{
    public static class RawDisk
    {
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFile(string fileName, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WriteFile(SafeFileHandle file, byte[] buffer, uint count,
            out uint written, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FlushFileBuffers(SafeFileHandle file);

        public static SafeFileHandle OpenForWrite(int diskNumber)
        {
            string path = @"\\.\PhysicalDrive" + diskNumber;
            SafeFileHandle h = CreateFile(path, GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (h.IsInvalid)
            {
                int err = Marshal.GetLastWin32Error();
                throw new Win32Exception(err, "Cannot open " + path + ": " + new Win32Exception(err).Message);
            }
            return h;
        }

        public static void Write(SafeFileHandle h, byte[] buffer, int count)
        {
            uint written;
            if (!WriteFile(h, buffer, (uint)count, out written, IntPtr.Zero))
            {
                int err = Marshal.GetLastWin32Error();
                throw new Win32Exception(err, "Write failed: " + new Win32Exception(err).Message);
            }
            if (written != (uint)count)
            {
                throw new IOException("Short write: " + written + " of " + count + " bytes.");
            }
        }

        public static void Flush(SafeFileHandle h)
        {
            if (!FlushFileBuffers(h))
            {
                int err = Marshal.GetLastWin32Error();
                throw new Win32Exception(err, "Flush failed: " + new Win32Exception(err).Message);
            }
        }
    }
}
'@
}

function Get-DiskWriteHint {
    # Turns a raw Win32 failure into something an operator can act on.
    param([Exception]$Ex)
    $e = $Ex
    while ($e -and -not ($e -is [System.ComponentModel.Win32Exception]) -and $e.InnerException) { $e = $e.InnerException }
    $code = 0
    if ($e -is [System.ComponentModel.Win32Exception]) { $code = $e.NativeErrorCode }
    if ($code -eq 5) {
        return "Access denied writing to the disk. Make sure this window is running as Administrator. If it is, Windows Security > Virus & threat protection > Ransomware protection > 'Controlled folder access' may be blocking the write: turn it off for the session, then try again. ($($e.Message))"
    }
    if ($code -eq 19) {
        return "The card is write-protected. Slide the lock switch on the SD card / adapter to the unlocked position and try again. ($($e.Message))"
    }
    if ($code -eq 32 -or $code -eq 33) {
        return "Another program is using the card (an Explorer window, Raspberry Pi Imager, antivirus...). Close it and try again. ($($e.Message))"
    }
    return $Ex.Message
}

# ---------------------------------------------------------------------------
# Disk selection and safety
# ---------------------------------------------------------------------------
function Get-DiskOrNull {
    param([int]$Number)
    try { return (Get-Disk -Number $Number -ErrorAction Stop) } catch { return $null }
}

function Get-DiskFingerprint {
    param($Disk)
    return ('{0}|{1}|{2}|{3}' -f $Disk.Number, $Disk.Size, $Disk.SerialNumber, $Disk.UniqueId)
}

function Test-DiskEligible {
    param($Disk)
    if ($Disk.IsSystem -or $Disk.IsBoot) { return $false }
    if ($script:AllowNonRemovable) { return $true }
    return ($script:CardBuses -contains [string]$Disk.BusType)
}

function Get-CandidateDisks {
    $all = @(Get-Disk | Where-Object { $_.Size -gt 0 })
    return @($all | Where-Object { Test-DiskEligible -Disk $_ })
}

function Show-DiskTable {
    param($Disks)
    $Disks | Format-Table -AutoSize `
        @{ Label = 'Disk';       Expression = { $_.Number } },
        @{ Label = 'Name';       Expression = { $_.FriendlyName } },
        @{ Label = 'Size';       Expression = { '{0:N1} GB' -f ($_.Size / 1GB) } },
        @{ Label = 'Bus';        Expression = { [string]$_.BusType } },
        @{ Label = 'Partitions'; Expression = { $_.NumberOfPartitions } } | Out-Host
}

function ConvertTo-DriveLetter {
    # Storage cmdlets hand back a [char]; a partition without a letter is [char]0.
    param($Value)
    $s = [string]$Value
    if (($s.Length -eq 1) -and ($s -match '[A-Za-z]')) { return $s.ToUpper() }
    return ''
}

function Show-DiskContents {
    param($Disk)
    $parts = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue)
    if ($parts.Count -eq 0) { Write-Host '    (no partitions - blank or unformatted card)'; return }
    foreach ($p in $parts) {
        $letter = ConvertTo-DriveLetter -Value $p.DriveLetter
        $fs = ''
        $label = ''
        if ($letter) {
            $v = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            if ($v) { $fs = [string]$v.FileSystem; $label = [string]$v.FileSystemLabel }
            $letter = $letter + ':'
        }
        Write-Host ('    Partition {0}  {1,-3} {2,-6} {3,-14} {4:N1} GB' -f $p.PartitionNumber, $letter, $fs, $label, ($p.Size / 1GB))
    }
}

function Test-PathOnDisk {
    # True if the file/folder lives on a drive letter that belongs to $Disk.
    param([string]$Path, $Disk)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Path -notmatch '^([A-Za-z]):') { return $false }    # UNC / relative: not a local drive letter
    $letter = $Matches[1].ToUpper()
    $hit = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue |
             Where-Object { (ConvertTo-DriveLetter -Value $_.DriveLetter) -eq $letter })
    return ($hit.Count -gt 0)
}

function Assert-SafeDisk {
    param($Disk)
    $n = $Disk.Number
    if ($Disk.IsSystem -or $Disk.IsBoot) { throw "Disk $n is the Windows system/boot disk. Refusing to touch it." }
    if ($Disk.Size -le 0) { throw "Disk $n has no media - there is no card in the reader." }
    if ((-not $script:AllowNonRemovable) -and ($script:CardBuses -notcontains [string]$Disk.BusType)) {
        throw "Disk $n ($($Disk.FriendlyName)) is on the '$($Disk.BusType)' bus, not a USB / SD card reader. If it really is your SD card reader, run again with -AllowNonRemovable."
    }
    foreach ($p in $script:GuardPaths) {
        if (Test-PathOnDisk -Path $p -Disk $Disk) {
            throw "'$p' is stored on Disk $n - the very disk you selected. Wiping it would destroy that file. Copy it to your PC's own drive and try again."
        }
    }
}

function Get-TargetDisk {
    $num = $script:DiskNumber
    if ($num -ge 0) {
        $d = Get-DiskOrNull -Number $num
        if ((-not $d) -or ($d.Size -le 0)) {
            if ($script:DiskFromParam) { throw "Disk $num is not present, or there is no card in it. Check with -ListDisks." }
            $num = -1   # a disk picked from the list earlier has gone away (reader re-plugged): ask again
        }
    }
    if ($num -lt 0) {
        $cands = @(Get-CandidateDisks)
        if ($cands.Count -eq 0) {
            throw 'No SD card found. Put the card in the reader and try again (removable USB / SD disks only; see -AllowNonRemovable).'
        }
        Write-Host ''
        Write-Host 'Disks that look like SD cards:'
        Show-DiskTable -Disks $cands
        $answer = Read-Line 'Enter the Disk number of the SD card'
        if ($answer -notmatch '^\d+$') { throw "'$answer' is not a disk number." }
        $num = [int]$answer
        $script:DiskNumber = $num
    }
    $disk = Get-DiskOrNull -Number $num
    if (-not $disk) { throw "Disk $num not found." }
    Assert-SafeDisk -Disk $disk
    return $disk
}

function Confirm-Disk {
    # Returns a fingerprint of the disk that was confirmed.
    param($Disk)
    $sizeGb = '{0:N1}' -f ($Disk.Size / 1GB)
    Write-Host ''
    if ($script:NoFlash) {
        Write-Host "About to write to: Disk $($Disk.Number)  $($Disk.FriendlyName)  $sizeGb GB" -ForegroundColor Yellow
    } else {
        Write-Host "About to ERASE and flash: Disk $($Disk.Number)  $($Disk.FriendlyName)  $sizeGb GB  ($($Disk.BusType))" -ForegroundColor Yellow
        Write-Host 'EVERYTHING on this disk will be lost. It currently holds:' -ForegroundColor Yellow
    }
    Show-DiskContents -Disk $Disk
    if ($Disk.Size -gt 256GB) { Write-Warn 'This disk is much bigger than a normal SD card - double-check it is the right one.' }
    Write-Host ''
    $ans = Read-Line "Type the disk number again to confirm ($($Disk.Number))"
    if ($ans -ne [string]$Disk.Number) { throw 'Confirmation did not match. Aborting.' }
    return (Get-DiskFingerprint -Disk $Disk)
}

function Assert-SameDisk {
    param($Disk, [string]$Fingerprint)
    $now = Get-DiskOrNull -Number $Disk.Number
    if ((-not $now) -or ((Get-DiskFingerprint -Disk $now) -ne $Fingerprint)) {
        throw "Disk $($Disk.Number) changed after you confirmed it (card swapped or reader re-plugged). Nothing was written - start this card again."
    }
}

# ---------------------------------------------------------------------------
# Flashing
# ---------------------------------------------------------------------------
function Assert-ImageUsable {
    if (-not (Test-Path -LiteralPath $script:Image -PathType Leaf)) { throw "Image file not found: $($script:Image)" }
    $ext = [IO.Path]::GetExtension($script:Image).ToLowerInvariant()
    if ($ext -in '.xz', '.gz', '.zip', '.zst', '.bz2', '.7z') {
        throw "The image is compressed ($ext). Extract it first - this script writes a plain .img file."
    }
    $script:ImageBytes = (Get-Item -LiteralPath $script:Image).Length
    if ($script:ImageBytes -lt 1MB) { throw "The image looks too small ($($script:ImageBytes) bytes): $($script:Image)" }
}

function Clear-CardDisk {
    # Windows refuses raw writes into sectors that belong to a mounted volume,
    # so drop the old partition table first (this also unmounts the volumes).
    param($Disk)
    $n = $Disk.Number
    $d = Get-DiskOrNull -Number $n
    if ($d -and $d.IsOffline)  { try { Set-Disk -Number $n -IsOffline $false -ErrorAction Stop } catch { } }
    if ($d -and $d.IsReadOnly) { try { Set-Disk -Number $n -IsReadOnly $false -ErrorAction Stop } catch { } }
    try {
        Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    } catch {
        $left = @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)
        if ($left.Count -gt 0) {
            throw "Could not clear Disk ${n}: $($_.Exception.Message) Close any Explorer window or program that is using the card and try again."
        }
    }
    Start-Sleep -Seconds 1
}

function Write-ImageToDisk {
    param([string]$ImagePath, $Disk)
    Initialize-RawDiskType
    $sector = [Math]::Max(512, [int]$Disk.LogicalSectorSize)
    $total  = (Get-Item -LiteralPath $ImagePath).Length
    $buf    = New-Object byte[] $script:ChunkBytes
    $act    = "Writing image to Disk $($Disk.Number)"
    $src    = [IO.File]::OpenRead($ImagePath)
    $h      = $null
    try {
        try { $h = [S3Gw.RawDisk]::OpenForWrite([int]$Disk.Number) }
        catch { throw (Get-DiskWriteHint -Ex $_.Exception) }

        $done = [long]0
        $sinceFlush = [long]0
        $lastUi = [long]-1000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            # Fill the whole buffer (network shares can return short reads) so every write stays sector-aligned.
            $filled = 0
            while ($filled -lt $buf.Length) {
                $r = $src.Read($buf, $filled, $buf.Length - $filled)
                if ($r -le 0) { break }
                $filled += $r
            }
            if ($filled -eq 0) { break }
            $count = $filled
            $rem = $filled % $sector
            if ($rem -ne 0) {
                # Last, partial chunk: pad with zeros up to a whole sector.
                $count = $filled + ($sector - $rem)
                [Array]::Clear($buf, $filled, $count - $filled)
            }
            try { [S3Gw.RawDisk]::Write($h, $buf, $count) }
            catch { throw (Get-DiskWriteHint -Ex $_.Exception) }
            $done += $filled
            $sinceFlush += $count
            if ($sinceFlush -ge $script:FlushEveryBytes) { [S3Gw.RawDisk]::Flush($h); $sinceFlush = 0 }

            if (($sw.ElapsedMilliseconds - $lastUi) -ge 1000) {
                $lastUi = $sw.ElapsedMilliseconds
                $pct = [int][Math]::Min(100, ($done * 100) / [Math]::Max(1, $total))
                $mbps = ($done / 1MB) / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)
                Write-Progress -Activity $act -Status ('{0:N0} of {1:N0} MB  ({2:N1} MB/s)' -f ($done / 1MB), ($total / 1MB), $mbps) -PercentComplete $pct
            }
            if ($filled -lt $buf.Length) { break }
        }
        Write-Progress -Activity $act -Status 'Flushing to the card - do not remove it...' -PercentComplete 100
        [S3Gw.RawDisk]::Flush($h)
        Write-Step ('Wrote {0:N0} MB in {1:N0} s' -f ($done / 1MB), $sw.Elapsed.TotalSeconds)
    }
    finally {
        Write-Progress -Activity $act -Completed
        if ($h) { $h.Dispose() }
        $src.Dispose()
    }
}

function Invoke-Flash {
    param($Disk, [string]$Fingerprint)
    if ($script:ImageBytes -gt $Disk.Size) {
        throw ('The image ({0:N1} GB) is bigger than the card ({1:N1} GB).' -f ($script:ImageBytes / 1GB), ($Disk.Size / 1GB))
    }
    Write-Step "Flashing $($script:Image) to Disk $($Disk.Number)"
    Assert-SameDisk -Disk $Disk -Fingerprint $Fingerprint
    Clear-CardDisk -Disk $Disk
    Write-ImageToDisk -ImagePath $script:Image -Disk $Disk
}

# ---------------------------------------------------------------------------
# Finding / releasing the card's boot partition (FAT, partition 1)
# ---------------------------------------------------------------------------
function Get-BootVolume {
    param([int]$DiskNumber, [int]$TimeoutSeconds = 40)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $problem = 'the boot partition did not show up'
    do {
        try { Update-Disk -Number $DiskNumber -ErrorAction Stop | Out-Null } catch { }
        $d = Get-DiskOrNull -Number $DiskNumber
        if ($d -and $d.IsOffline) { try { Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction Stop | Out-Null } catch { } }

        $part = $null
        try { $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber 1 -ErrorAction Stop } catch { }
        if ($part) {
            $letter = ConvertTo-DriveLetter -Value $part.DriveLetter
            if (-not $letter) {
                try { Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber 1 -AssignDriveLetter -ErrorAction Stop | Out-Null } catch { }
                try { $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber 1 -ErrorAction Stop } catch { }
                $letter = ConvertTo-DriveLetter -Value $part.DriveLetter
            }
            if ($letter) {
                $vol = $null
                try { $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop } catch { }
                if ($vol -and ([string]$vol.FileSystem -match 'FAT')) {
                    $root = $letter + ':\'
                    if (Test-Path -LiteralPath $root) {
                        return [pscustomobject]@{
                            DriveLetter     = $letter
                            Root            = $root
                            PartitionNumber = 1
                            Label           = [string]$vol.FileSystemLabel
                        }
                    }
                } elseif ($vol) {
                    $problem = "partition 1 is '$($vol.FileSystem)', not FAT - is this really the golden image?"
                }
            }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for the card's boot partition to appear in Windows ($problem). Unplug and re-insert the card, then run again with -NoFlash to just write the provisioning files."
}

function Dismount-BootVolume {
    # Flush, then drop the drive letter so the card can be pulled safely.
    param($Volume, [int]$DiskNumber)
    $ok = $true
    try { Write-VolumeCache -DriveLetter $Volume.DriveLetter -ErrorAction Stop | Out-Null } catch { $ok = $false }
    try {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $Volume.PartitionNumber -AccessPath $Volume.Root -ErrorAction Stop | Out-Null
    } catch { $ok = $false }
    return $ok
}

# ---------------------------------------------------------------------------
# provision.env + site files
# ---------------------------------------------------------------------------
function Get-SitePlan {
    param([string]$Dir)
    $plan = [pscustomobject]@{ Dir = $Dir; Exists = $false; Items = @() }
    if ([string]::IsNullOrEmpty($Dir)) { return $plan }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $plan }
    $plan.Exists = $true
    $items = @()
    foreach ($name in 'samplelist.csv', 'pygw_conf.py') {
        $f = Join-Path $Dir $name
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            $items += [pscustomobject]@{ Source = $f; Dest = $name; Text = $true }
        }
    }
    # The extra -like keeps Windows' 8.3 quirk (*.zip also matching *.zipx) out.
    $zips = @(Get-ChildItem -LiteralPath $Dir -Filter 'required-*gw.zip' -File | Where-Object { $_.Name -like 'required-*gw.zip' })
    foreach ($z in $zips) {
        $items += [pscustomobject]@{ Source = $z.FullName; Dest = $z.Name; Text = $false }
    }
    $plan.Items = $items
    return $plan
}

function Show-SitePlan {
    param($Plan)
    if (-not $Plan.Dir) {
        Write-Host "Site files: none requested - the card keeps the image's own samplelist.csv / pygw_conf.py (sample nodes)."
        return
    }
    if (-not $Plan.Exists) { Write-Warn "site folder not found: $($Plan.Dir) - no site files will be copied to this card."; return }
    if ($Plan.Items.Count -eq 0) {
        Write-Warn "no samplelist.csv, pygw_conf.py or required-*gw.zip in $($Plan.Dir) - no site files will be copied to this card."
        return
    }
    Write-Host ('Site files from {0}: {1}' -f $Plan.Dir, (($Plan.Items | ForEach-Object { $_.Dest }) -join ', '))
}

function ConvertTo-LfText {
    # The gateway is Linux: drop a UTF-8 BOM and turn CRLF into LF. ISO-8859-1
    # maps bytes 1:1 to chars, so nothing else in the file can change.
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 2) {
        if ((($Bytes[0] -eq 0xFF) -and ($Bytes[1] -eq 0xFE)) -or (($Bytes[0] -eq 0xFE) -and ($Bytes[1] -eq 0xFF))) {
            throw 'the file is saved as UTF-16 - re-save it as UTF-8 (plain CSV, or "CSV UTF-8" in Excel)'
        }
    }
    $notes = @()
    $work = $Bytes
    if (($work.Length -ge 3) -and ($work[0] -eq 0xEF) -and ($work[1] -eq 0xBB) -and ($work[2] -eq 0xBF)) {
        $rest = New-Object byte[] ($work.Length - 3)
        [Array]::Copy($work, 3, $rest, 0, $rest.Length)
        $work = $rest
        $notes += 'removed UTF-8 BOM'
    }
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $text = $latin1.GetString($work)
    if ($text.Contains("`r`n")) {
        $text = $text.Replace("`r`n", "`n")
        $notes += 'CRLF -> LF'
    }
    return [pscustomobject]@{ Bytes = $latin1.GetBytes($text); Notes = $notes }
}

function Assert-FileBytes {
    # Read the file back from the card and compare with what we meant to write.
    param([string]$Path, [byte[]]$Expected)
    $actual = [IO.File]::ReadAllBytes($Path)
    if ([Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($Expected)) {
        throw "Read-back check failed for $Path - what is on the card does not match what was written."
    }
}

function Write-ProvisionFiles {
    # Returns how many site files were copied.
    param([string]$BootRoot, [string]$Gw, $Plan)
    $pdir = Join-Path $BootRoot $script:ProvisionDirName
    New-Item -ItemType Directory -Path $pdir -Force | Out-Null

    # Leftovers from an earlier run must not follow this card to a different site.
    foreach ($f in @(Get-ChildItem -LiteralPath $pdir -File -ErrorAction SilentlyContinue)) {
        if ((@('provision.env', 'samplelist.csv', 'pygw_conf.py') -contains $f.Name) -or ($f.Name -like 'required-*gw.zip')) {
            Remove-Item -LiteralPath $f.FullName -Force
        }
    }

    $copied = 0
    if ($Plan -and $Plan.Exists) {
        foreach ($it in $Plan.Items) {
            $out = [IO.File]::ReadAllBytes($it.Source)
            $note = ''
            if ($it.Text -and (-not $script:KeepLineEndings)) {
                try { $conv = ConvertTo-LfText -Bytes $out }
                catch { throw "$($it.Dest): $($_.Exception.Message)" }
                $out = $conv.Bytes
                if (@($conv.Notes).Count -gt 0) { $note = '  (converted: ' + (@($conv.Notes) -join ', ') + ')' }
            }
            $dest = Join-Path $pdir $it.Dest
            [IO.File]::WriteAllBytes($dest, $out)
            Assert-FileBytes -Path $dest -Expected $out
            Write-Step "Copied $($it.Dest) from $($Plan.Dir)$note"
            $copied++
        }
    }

    # provision.env goes last: an interrupted run then leaves a card with NO
    # provision.env (first boot refuses it loudly) instead of a half-provisioned one.
    # First boot SOURCES this file as root in bash, so it must be plain ASCII,
    # LF line endings and no BOM - never let PowerShell pick the encoding.
    $envBytes = [Text.Encoding]::ASCII.GetBytes("GATEWAY_ID=$Gw`n")
    $envPath = Join-Path $pdir 'provision.env'
    [IO.File]::WriteAllBytes($envPath, $envBytes)
    Assert-FileBytes -Path $envPath -Expected $envBytes
    Write-Step "Wrote provision.env (GATEWAY_ID=$Gw) to $BootRoot"
    return $copied
}

# ---------------------------------------------------------------------------
# One card
# ---------------------------------------------------------------------------
function Invoke-Card {
    param([string]$Gw, [string]$SiteDirPath)
    $disk = Get-TargetDisk
    $plan = Get-SitePlan -Dir $SiteDirPath
    Show-SitePlan -Plan $plan
    $fingerprint = Confirm-Disk -Disk $disk

    if (-not $script:NoFlash) { [void](Invoke-Flash -Disk $disk -Fingerprint $fingerprint) }

    Write-Step 'Waiting for Windows to mount the card''s boot partition'
    $vol = Get-BootVolume -DiskNumber $disk.Number
    $copied = 0
    $unmounted = $false
    try {
        $copied = @(Write-ProvisionFiles -BootRoot $vol.Root -Gw $Gw -Plan $plan)[-1]
    } finally {
        $unmounted = Dismount-BootVolume -Volume $vol -DiskNumber $disk.Number
    }

    if ($SiteDirPath -and ($copied -eq 0)) { Write-Warn 'no site files were copied to this card - it will boot with the image''s sample node list.' }
    if ($unmounted) {
        Write-Step "Done: Disk $($disk.Number) -> $Gw.  You can remove the card now."
    } else {
        Write-Step "Done: Disk $($disk.Number) -> $Gw."
        Write-Warn "could not unmount the card automatically. Close any Explorer window showing it and use 'Safely Remove Hardware' before pulling it out."
    }
    return [pscustomobject]@{ SiteFiles = $copied }
}

# ---------------------------------------------------------------------------
# Batch CSV
# ---------------------------------------------------------------------------
function Read-BatchCsv {
    param([string]$Path)
    # '#' comment lines and blank lines are skipped (the example CSV ends with a block of them).
    $lines = @([IO.File]::ReadAllLines($Path) | Where-Object { ($_.Trim() -ne '') -and (-not $_.TrimStart().StartsWith('#')) })
    if ($lines.Count -lt 2) { throw "The batch CSV needs a header line (gateway_id,site) and at least one row: $Path" }
    $rows = @($lines | ConvertFrom-Csv)
    if ($rows.Count -eq 0) { throw "The batch CSV has no data rows: $Path" }
    $names = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
    $idCol = $names | Where-Object { $_.Trim() -ieq 'gateway_id' } | Select-Object -First 1
    if (-not $idCol) { throw "The batch CSV needs a 'gateway_id' column. Columns found: $($names -join ', ')" }
    $siteCol = $names | Where-Object { $_.Trim() -ieq 'site' } | Select-Object -First 1
    $out = @()
    $n = 0
    foreach ($r in $rows) {
        $n++
        $gw = ([string]$r.$idCol).Trim()
        $st = ''
        if ($siteCol) { $st = ([string]$r.$siteCol).Trim() }
        if (-not $gw) { Write-Warn "CSV data row $n has no gateway_id - skipped."; continue }
        $out += [pscustomobject]@{ GatewayId = $gw; Site = $st }
    }
    return $out
}

function Test-BatchPlan {
    # Checks the whole list up front so nothing is flashed until the CSV is sane.
    param($Rows)
    $errors = @()
    $warns = @()
    $seen = @{}
    $i = 0
    foreach ($r in $Rows) {
        $i++
        $tag = "Row ${i} ($($r.GatewayId))"
        if (-not (Test-GatewayId -Value $r.GatewayId)) { $errors += "$tag - not a valid hostname (letters, digits and '-' only, max 63)." }
        $key = $r.GatewayId.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { $errors += "$tag - duplicate of row $($seen[$key])." } else { $seen[$key] = $i }
        if ($r.Site) {
            if (-not (Test-SiteName -Value $r.Site)) {
                $errors += "$tag - site name '$($r.Site)' must not contain \ / or :"
            } elseif (-not $script:SiteFilesRoot) {
                $warns += "$tag - names site '$($r.Site)' but -SiteFilesRoot was not given, so no site files will be copied."
            } else {
                $p = Get-SitePlan -Dir (Join-Path $script:SiteFilesRoot $r.Site)
                if (-not $p.Exists) { $warns += "$tag - site folder not found: $($p.Dir)" }
                elseif ($p.Items.Count -eq 0) { $warns += "$tag - no samplelist.csv / pygw_conf.py / required-*gw.zip in $($p.Dir)" }
            }
        }
    }
    return [pscustomobject]@{ Errors = $errors; Warnings = $warns }
}

# ---------------------------------------------------------------------------
# Guided mode
# ---------------------------------------------------------------------------
function Read-MissingAnswers {
    $needImage = (-not $script:NoFlash) -and (-not $script:Image)
    $needWho   = (-not $script:Batch) -and (-not $script:GatewayId)
    if (-not ($needImage -or $needWho)) { return }
    Write-Host ''
    Write-Host 'S3 Gateway - flash and provision an SD card' -ForegroundColor Cyan
    Write-Host '(press Ctrl+C at any time to stop)'
    Write-Host ''
    if ($needImage) { $script:Image = Read-Line 'Path to the image file (.img) - you can drag the file into this window' }
    if ($needWho) {
        $id = Read-Line 'Gateway ID for this card, e.g. s3-gw-03 (or just press Enter to do many cards from a CSV list)'
        if ($id) {
            $script:GatewayId = $id
            if (-not ($script:SiteDir -or $script:Site -or $script:SiteFilesRoot)) {
                $script:SiteDir = Read-Line 'Folder with this gateway''s site files (press Enter for none - the card keeps the image''s sample nodes)'
            }
        } else {
            $script:Batch = Read-Line 'Path to the gateways CSV (gateway_id,site)'
            if (-not $script:SiteFilesRoot) {
                $script:SiteFilesRoot = Read-Line 'Folder that contains one sub-folder per site (press Enter if none)'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-S3Provision {
    if (-not (Test-IsWindows)) { throw 'This is the Windows version. On Linux use host/flash-and-provision.sh.' }
    if (-not (Test-IsAdmin)) {
        throw "Administrator rights are needed (the script writes straight to a disk). Double-click flash-and-provision.bat, or start PowerShell with 'Run as administrator'."
    }

    if ($script:ListDisks) {
        $c = @(Get-CandidateDisks)
        if ($c.Count -eq 0) { Write-Host 'No SD card / USB disk found.' } else { Show-DiskTable -Disks $c }
        return 0
    }

    $script:DiskFromParam = ($script:DiskNumber -ge 0)
    Read-MissingAnswers

    $script:Image         = Resolve-UserPath $script:Image
    $script:Batch         = Resolve-UserPath $script:Batch
    $script:SiteDir       = Resolve-UserPath $script:SiteDir
    $script:SiteFilesRoot = Resolve-UserPath $script:SiteFilesRoot
    $batchMode = [bool]$script:Batch

    if (-not $script:NoFlash) {
        if (-not $script:Image) { throw '-Image is required unless -NoFlash is used.' }
        Assert-ImageUsable
        Initialize-RawDiskType   # fail now, not after the card has been wiped
    }

    $script:GuardPaths = @($script:Image, $script:Batch, $script:SiteDir, $script:SiteFilesRoot, $PSScriptRoot) | Where-Object { $_ }

    if ($script:Site -and -not (Test-SiteName -Value $script:Site)) { throw "Site name '$($script:Site)' must not contain \ / or :" }

    # ---- batch: one CSV row per card ------------------------------------
    if ($batchMode) {
        if (-not (Test-Path -LiteralPath $script:Batch -PathType Leaf)) { throw "Batch CSV not found: $($script:Batch)" }
        if ($script:GatewayId) { Write-Warn '-GatewayId is ignored in batch mode (the IDs come from the CSV).' }
        if ($script:SiteDir)   { Write-Warn '-SiteDir is ignored in batch mode (use -SiteFilesRoot with the CSV site column).' }
        if ($script:Site)      { Write-Warn '-Site is ignored in batch mode (the site comes from each CSV row).' }

        $rows = @(Read-BatchCsv -Path $script:Batch)
        if ($rows.Count -eq 0) { throw 'The batch CSV has no usable rows.' }
        $check = Test-BatchPlan -Rows $rows
        if (@($check.Errors).Count -gt 0) {
            $check.Errors | ForEach-Object { Write-Bad "  $_" }
            throw 'Fix the CSV problems above, then run again. Nothing was written.'
        }
        if (@($check.Warnings).Count -gt 0) {
            $check.Warnings | ForEach-Object { Write-Warn $_ }
            $go = Read-Line 'Continue anyway? (y/N)'
            if ($go -notmatch '^[yY]') { throw 'Stopped. Nothing was written.' }
        }

        $results = @()
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $siteDirPath = ''
            if ($script:SiteFilesRoot -and $r.Site) { $siteDirPath = Join-Path $script:SiteFilesRoot $r.Site }
            $siteText = '<none>'
            if ($r.Site) { $siteText = $r.Site }
            $status = 'ABORTED'
            $files = ''
            while ($true) {
                Write-Host ''
                Write-Host ('#' * 62)
                Write-Host "# Card $($i + 1) of $($rows.Count):  gateway_id=$($r.GatewayId)   site=$siteText"
                Write-Host '# Insert the SD card, then press Enter.'
                Write-Host ('#' * 62)
                [void](Read-Line 'Press Enter when the card is in')
                try {
                    $res = Invoke-Card -Gw $r.GatewayId -SiteDirPath $siteDirPath
                    $status = 'OK'
                    $files = [string]$res.SiteFiles
                    break
                } catch {
                    Write-Bad "ERROR: $($_.Exception.Message)"
                    $choice = (Read-Line '[R]etry this card, [S]kip it, or [Q]uit?  (r/s/q)').ToLower()
                    if ($choice -eq 'r') { continue }
                    if ($choice -eq 's') { $status = 'SKIPPED' } else { $status = 'ABORTED' }
                    break
                }
            }
            $results += [pscustomobject]@{ Card = $i + 1; GatewayId = $r.GatewayId; Site = $siteText; SiteFiles = $files; Result = $status }
            if ($status -eq 'ABORTED') { break }
        }
        Write-Host ''
        Write-Host 'Summary:' -ForegroundColor Cyan
        $results | Format-Table -AutoSize | Out-Host
        if (@($results | Where-Object { $_.Result -ne 'OK' }).Count -gt 0 -or $results.Count -lt $rows.Count) { return 1 }
        return 0
    }

    # ---- single card -----------------------------------------------------
    if (-not $script:GatewayId) { throw '-GatewayId or -Batch is required.' }
    Assert-GatewayId -Value $script:GatewayId

    $siteDirPath = ''
    if ($script:SiteDir) { $siteDirPath = $script:SiteDir }
    elseif ($script:SiteFilesRoot -and $script:Site) { $siteDirPath = Join-Path $script:SiteFilesRoot $script:Site }
    if ($script:SiteFilesRoot -and -not $siteDirPath) {
        Write-Warn '-SiteFilesRoot has no effect here without -Site (single-card mode) or -Batch. No site files will be copied.'
    }
    if ($script:Site -and -not $script:SiteFilesRoot -and -not $script:SiteDir) {
        Write-Warn '-Site has no effect without -SiteFilesRoot. No site files will be copied.'
    }

    [void](Invoke-Card -Gw $script:GatewayId -SiteDirPath $siteDirPath)
    return 0
}

# Skipped when the file is dot-sourced (which is how the functions above get tested).
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        # An elevated window opens in System32; typed relative paths should mean "next to this script".
        if ($script:PauseAtEnd) { Set-Location -LiteralPath $PSScriptRoot }
        # Only the last value counts: it is the explicit 'return 0/1' of Invoke-S3Provision.
        $result = @(Invoke-S3Provision)
        if ($result.Count -gt 0) { $exitCode = [int]$result[-1] }
    } catch {
        Write-Host ''
        Write-Bad "ERROR: $($_.Exception.Message)"
        if ($VerbosePreference -eq 'Continue') { Write-Host $_.ScriptStackTrace }
    }
    if ($script:PauseAtEnd) { [void](Read-Host 'Press Enter to close this window') }
    exit $exitCode
}
