<#
.SYNOPSIS
    Windows version of host/flash-and-provision.sh and host/flash-and-provision-wizard.sh:
    flash the golden S3 gateway image to an SD card and write that card's
    GATEWAY_ID (plus optional site files) to its boot partition.

.DESCRIPTION
    Same job and same on-card result as the Linux scripts, so
    image/firstboot/s3-gateway-firstboot.sh picks the card up on first boot
    exactly as it does for a card made on Linux. Run it on the provisioning PC,
    NOT on a gateway.

    Needs Administrator rights (it writes straight to the disk). Easiest start:
    double-click flash-and-provision.bat, which asks for them.

    Run with no card options (just double-click the .bat) and you get the
    WIZARD, the same guided flow as the Linux flash wizard. It asks one
    question at a time (image, Gateway ID, site, SD card), shows a summary and
    only then writes. On top of the plain command-line mode it:
      * only offers removable / SD-card disks, and never the Windows system
        disk, the disk the image or kit lives on, or a card that is too small;
      * checks the image (not compressed, plausible size, disk-image boot
        signature, and the <image>.img.sha256 checksum if one sits next to it);
      * checks the Gateway ID, warns if it was already used, suggests the next
        number;
      * checks the site folder has the expected files;
      * offers batch mode from a CSV (comment lines and Excel line endings are
        fine) that can skip cards already done;
      * waits for you to remove each card before the next one;
      * keeps a record in flash-log.csv next to this script (same format as the
        Linux wizard's host/flash-log.csv).
    Menu: 1 flash cards one at a time, 2 batch from CSV, 3 change the Gateway ID
    on a never-booted card (no re-flash), 4 show the log.

    Giving any card option (-GatewayId, -Batch, -DiskNumber, -SiteDir, -Site,
    -NoFlash) or -ListDisks switches to the non-interactive command-line mode
    described by the parameters and examples below. Safety there is the same:
    it never touches the Windows system/boot disk, only offers USB / SD card
    disks (override: -AllowNonRemovable), shows what is on the disk before
    erasing it, and makes you retype the disk number to confirm.

.PARAMETER Image
    Path to the golden .img file (not needed with -NoFlash). In the wizard it
    is optional: without it the wizard looks in the kit folders, Downloads and
    Desktop and asks.
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
    Folder containing one sub-folder per site. In the wizard the default is
    site-files next to this script.
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
    Wizard: menu, then asks for the image, gateway ID, site and SD card.

.EXAMPLE
    .\flash-and-provision.ps1 -Image D:\images\deb13-arm64-min.img -SiteFilesRoot D:\kit\site-files
    Wizard, with the image and the site folder already chosen.

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

function Get-Win32Code {
    # Native Windows error code buried inside a (possibly wrapped) exception, or 0.
    param([Exception]$Ex)
    $e = $Ex
    while ($e -and -not ($e -is [System.ComponentModel.Win32Exception]) -and $e.InnerException) { $e = $e.InnerException }
    if ($e -is [System.ComponentModel.Win32Exception]) { return [int]$e.NativeErrorCode }
    return 0
}

function Set-DiskWritable {
    # Brings the disk online and writable (a freshly cleared card can drop offline) and
    # waits up to ~10 s until Windows reports it that way. Returns $true when it is.
    param([int]$Number)
    for ($i = 0; $i -lt 10; $i++) {
        try { Update-Disk -Number $Number -ErrorAction Stop | Out-Null } catch { }
        $d = Get-DiskOrNull -Number $Number
        if (-not $d) { Start-Sleep -Seconds 1; continue }
        if ($d.IsOffline)  { try { Set-Disk -Number $Number -IsOffline $false -ErrorAction Stop } catch { } }
        if ($d.IsReadOnly) { try { Set-Disk -Number $Number -IsReadOnly $false -ErrorAction Stop } catch { } }
        $d = Get-DiskOrNull -Number $Number
        if ($d -and (-not $d.IsOffline) -and (-not $d.IsReadOnly) -and ($d.Size -gt 0)) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
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
    if ($code -eq 21) {
        return "Windows says the card is 'not ready' even after bringing it online. Unplug the card reader, plug it into a different USB port (directly into the PC, not a hub), re-insert the card and try again. If it still fails, try another card reader; if a different reader fails the same way, the SD card itself is probably faulty - replace it. ($($e.Message))"
    }
    if ($code -eq 1117 -or $code -eq 23) {
        return "The card or reader reported a hardware error while writing. Try another USB port or card reader; if it repeats, the SD card is probably failing - replace it. ($($e.Message))"
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
    [void](Set-DiskWritable -Number $n)
    try {
        Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    } catch {
        $left = @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue)
        if ($left.Count -gt 0) {
            throw "Could not clear Disk ${n}: $($_.Exception.Message) Close any Explorer window or program that is using the card and try again."
        }
    }
    Start-Sleep -Seconds 1
    # Clearing can leave the disk offline, and Windows refuses raw writes to an offline disk
    # with "The device is not ready" - so make sure it is online and writable before writing.
    if (-not (Set-DiskWritable -Number $n)) {
        Write-Warn "Disk $n is still not online/writable after clearing; trying to write anyway."
    }
}

function Write-ImageToDisk {
    param([string]$ImagePath, $Disk)
    Initialize-RawDiskType
    $sector = [Math]::Max(512, [int]$Disk.LogicalSectorSize)
    $total  = [long](Get-Item -LiteralPath $ImagePath).Length
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
            $attempt = 0
            while ($true) {
                try { [S3Gw.RawDisk]::Write($h, $buf, $count); break }
                catch {
                    $ex = $_.Exception
                    $attempt++
                    # Only the very first chunk is retried (the write position is certainly still 0 there).
                    if ((Get-Win32Code -Ex $ex) -eq 21 -and $done -eq 0 -and $attempt -le 3) {
                        Write-Warn "Windows says the card is not ready (try $attempt of 3) - bringing it online and retrying..."
                        [void](Set-DiskWritable -Number ([int]$Disk.Number))
                        Start-Sleep -Seconds 3
                        $h.Dispose()
                        try { $h = [S3Gw.RawDisk]::OpenForWrite([int]$Disk.Number) }
                        catch { throw (Get-DiskWriteHint -Ex $_.Exception) }
                        continue
                    }
                    throw (Get-DiskWriteHint -Ex $ex)
                }
            }
            $done += $filled
            $sinceFlush += $count
            if ($sinceFlush -ge $script:FlushEveryBytes) { [S3Gw.RawDisk]::Flush($h); $sinceFlush = 0 }

            if (($sw.ElapsedMilliseconds - $lastUi) -ge 1000) {
                $lastUi = $sw.ElapsedMilliseconds
                $pct = [int][Math]::Min([double]100, ([double]$done * 100) / [Math]::Max([double]1, [double]$total))
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
function Get-SiteCsvName {
    # The node-list CSV is not always called samplelist.csv: the site's
    # pygw_conf.py names it (localDBpath = '...'), and s3-gateway-dbup - which
    # runs on first boot and refuses to continue on a bad value - applies a
    # strict rule. This mirrors it (scripts/s3-gateway-dbup, read_local_db_name):
    #   - the LAST top-level `localDBpath = '<name>'` line wins, like Python
    #   - <name> is [A-Za-z0-9_.-], 1-60 characters, then .csv (case-sensitive)
    # No pygw_conf.py in the folder -> the image's own config is used -> samplelist.csv.
    # Returns Name, and Error when the setting is unusable.
    param([string]$Dir)
    $result = [pscustomobject]@{ Name = 'samplelist.csv'; Error = '' }
    $conf = Join-Path $Dir 'pygw_conf.py'
    if (-not (Test-Path -LiteralPath $conf -PathType Leaf)) { return $result }
    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($conf))
    $line = $null
    foreach ($l in ($text -split "`r?`n")) { if ($l -match '^localDBpath[ \t]*=') { $line = $l } }
    if ($null -eq $line) {
        $result.Error = 'localDBpath is not set in pygw_conf.py (s3-gateway-dbup refuses a pygw_conf.py without it).'
        return $result
    }
    $m = [regex]::Match($line, '^localDBpath[ \t]*=[ \t]*([''"])([^''"\\]*)\1[ \t]*(#.*)?$')
    if (-not $m.Success) {
        $result.Error = "localDBpath in pygw_conf.py must be a plain quoted string such as 'samplelist.csv'."
        return $result
    }
    $name = $m.Groups[2].Value
    if ($name -cnotmatch '^[A-Za-z0-9_.-]{1,60}\.csv$') {
        $result.Error = "localDBpath '$name' in pygw_conf.py must be a plain file name ending in .csv (letters, digits, . _ - only, at most 60 characters before .csv, no folders)."
        return $result
    }
    $result.Name = $name
    return $result
}

function Get-SitePlan {
    param([string]$Dir)
    $plan = [pscustomobject]@{ Dir = $Dir; Exists = $false; Items = @(); CsvName = 'samplelist.csv'; Errors = @() }
    if ([string]::IsNullOrEmpty($Dir)) { return $plan }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $plan }
    $plan.Exists = $true
    $csv = Get-SiteCsvName -Dir $Dir
    $plan.CsvName = $csv.Name
    # Errors are things that would make first boot stop at s3-gateway-dbup (it
    # would then retry on every boot until someone fixed the card by hand), so
    # a card with errors is never written.
    $errs = @()
    if ($csv.Error) { $errs += $csv.Error }
    $hasConf = Test-Path -LiteralPath (Join-Path $Dir 'pygw_conf.py') -PathType Leaf
    if ((-not $csv.Error) -and $hasConf -and ($csv.Name -cne 'samplelist.csv') -and -not (Test-Path -LiteralPath (Join-Path $Dir $csv.Name) -PathType Leaf)) {
        $errs += "pygw_conf.py names the node list '$($csv.Name)' but that file is not in $Dir (the image only ships samplelist.csv, so first boot would stop at s3-gateway-dbup)."
    }
    $plan.Errors = $errs
    $items = @()
    foreach ($name in $csv.Name, 'pygw_conf.py') {
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
        Write-Warn "no node-list .csv, pygw_conf.py or required-*gw.zip in $($Plan.Dir) - no site files will be copied to this card."
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
        if ((@('provision.env', 'pygw_conf.py') -contains $f.Name) -or ($f.Extension -ieq '.csv') -or ($f.Name -like 'required-*gw.zip')) {
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
    if (@($plan.Errors).Count -gt 0) {
        throw ("The site files in $($plan.Dir) cannot be used:`n  - " + (@($plan.Errors) -join "`n  - ") + "`nNothing was written to the card. Fix the site files and try again.")
    }
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
                elseif ($p.Items.Count -eq 0) { $warns += "$tag - no node-list .csv / pygw_conf.py / required-*gw.zip in $($p.Dir)" }
                else { foreach ($pe in @($p.Errors)) { $errors += "$tag - site '$($r.Site)': $pe" } }
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
# Wizard - the Windows counterpart of host/flash-and-provision-wizard.sh.
# Runs when the script is started without any card-specific option (for
# example by double-clicking flash-and-provision.bat). It asks one question at
# a time, only offers real SD-card / USB disks, checks the Gateway ID, site
# folder and image, and keeps a record in flash-log.csv (same file format as
# the Linux wizard, so a shared kit folder gets one combined history).
# It reuses Invoke-Card above, so the disk-number re-type confirmation and all
# the write safety checks are exactly the same as in the command-line mode.
# ---------------------------------------------------------------------------
$script:MaxCardGb     = 256                      # anything bigger is not offered as an SD card
$script:MinImageBytes = [long](16MB)
$script:LogHeader     = 'timestamp,operator,gateway_id,site,result,image,card_model,card_gb,device'
$script:LogFile       = ''
$script:LogOk         = $true
$script:ImageOk       = $false
$script:WzSiteRoot    = ''
$script:WzSite        = ''
$script:WzSiteDir     = ''
$script:GwId          = ''
$script:Card          = $null
$script:Cards         = @()
$script:LastId        = ''
$script:LastSite      = ''
$script:LastSiteDir   = ''
$script:Flashing      = $false

# --- output and input helpers ------------------------------------------------
function Write-Say  { param([string]$Message = '') Write-Host $Message }
function Write-Head { param([string]$Message) Write-Host ''; Write-Host $Message -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Err  { param([string]$Message) Write-Host "ERROR: $Message" -ForegroundColor Red }
function Write-Rule { Write-Host ('  ' + ('-' * 66)) }

function Format-Size {
    param([double]$Bytes)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1e9) { return (($Bytes / 1e9).ToString('0.0', $inv) + 'GB') }
    if ($Bytes -ge 1e6) { return (($Bytes / 1e6).ToString('0.0', $inv) + 'MB') }
    return (($Bytes / 1e3).ToString('0', $inv) + 'kB')
}

function ConvertTo-CleanField {
    # Trim blanks and the quotes Excel / drag-and-drop may leave around a value.
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Trim().Trim('"', "'").Trim()
}

function Read-Answer {
    # Read-Answer "Question" [default] -> the typed text, or the default on Enter.
    param([string]$Prompt, [string]$Default = '')
    $p = $Prompt
    if ($Default) { $p = "$Prompt [$Default]" }
    $a = Read-Host $p
    if ($null -eq $a) { throw 'Input closed - exiting.' }
    $a = $a.Trim()
    if ($a) { return $a }
    return $Default
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = 'y/N'
    if ($Default) { $hint = 'Y/n' }
    while ($true) {
        $a = Read-Host "$Prompt [$hint]"
        if ($null -eq $a) { throw 'Input closed - exiting.' }
        $a = $a.Trim().ToLowerInvariant()
        if (-not $a) { return $Default }
        if ($a -eq 'y' -or $a -eq 'yes') { return $true }
        if ($a -eq 'n' -or $a -eq 'no') { return $false }
        Write-Say 'Please answer y or n.'
    }
}

function Test-KeyPolling {
    # False when there is no real console (ISE, redirected input): waits then fall back to Enter prompts.
    try { [void][Console]::KeyAvailable; return $true } catch { return $false }
}

function Clear-KeyBuffer {
    if (-not (Test-KeyPolling)) { return }
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
}

function Read-KeyWithin {
    # Waits up to $Milliseconds for a key. Returns 'ENTER', the key typed, or $null on timeout.
    param([int]$Milliseconds)
    $end = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $end) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Enter) { return 'ENTER' }
            return [string]$k.KeyChar
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

# --- record keeping ----------------------------------------------------------
function Initialize-Log {
    $script:LogFile = Join-Path $PSScriptRoot 'flash-log.csv'
    $script:LogOk = $true
    try {
        if (-not (Test-Path -LiteralPath $script:LogFile -PathType Leaf)) {
            [IO.File]::WriteAllText($script:LogFile, $script:LogHeader + "`n", (New-Object Text.UTF8Encoding($false)))
        } else {
            $fs = [IO.File]::Open($script:LogFile, 'Append', 'Write', 'ReadWrite')
            $fs.Dispose()
        }
    } catch {
        $script:LogOk = $false
        Write-Warn "Cannot write to $($script:LogFile) - flashes will not be recorded."
    }
}

function ConvertTo-CsvField {
    param([string]$Value)
    return (($Value -replace ',', ' ') -replace '[\r\n]+', ' ')
}

function Add-LogRow {
    param([string]$Result, [string]$Gw, [string]$SiteName, [string]$Model, [long]$Bytes, [string]$Device)
    if (-not $script:LogOk) { return }
    $img = 'none'
    if ($script:Image) { $img = Split-Path -Leaf $script:Image }
    $siteText = 'none'
    if ($SiteName) { $siteText = $SiteName }
    $gb = [long][Math]::Floor($Bytes / 1e9)
    $vals = @((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), [Environment]::UserName, $Gw, $siteText, $Result, $img, $Model, [string]$gb, $Device)
    $line = (($vals | ForEach-Object { ConvertTo-CsvField -Value ([string]$_) }) -join ',')
    try {
        [IO.File]::AppendAllText($script:LogFile, $line + "`n", (New-Object Text.UTF8Encoding($false)))
    } catch {
        Write-Warn "Could not write to the log: $($_.Exception.Message)"
    }
}

function Read-LogRows {
    if ((-not $script:LogFile) -or (-not (Test-Path -LiteralPath $script:LogFile -PathType Leaf))) { return @() }
    try { return @(Import-Csv -LiteralPath $script:LogFile -ErrorAction Stop) } catch { return @() }
}

function Get-PriorUse {
    # Timestamp of an earlier successful use of this Gateway ID, or '' if none.
    param([string]$Id)
    $t = ''
    foreach ($r in @(Read-LogRows)) {
        if ((([string]$r.gateway_id).ToLowerInvariant() -eq $Id.ToLowerInvariant()) -and
            (([string]$r.result -ceq 'FLASHED') -or ([string]$r.result -ceq 'RELABELED'))) {
            $t = [string]$r.timestamp
        }
    }
    return $t
}

function Get-LastLoggedId {
    $id = ''
    foreach ($r in @(Read-LogRows)) {
        if (([string]$r.result -ceq 'FLASHED') -or ([string]$r.result -ceq 'RELABELED')) { $id = [string]$r.gateway_id }
    }
    return $id
}

function Get-NextId {
    # s3-gw-03 -> s3-gw-04 (keeps zero padding); '' if there is no trailing number.
    param([string]$Id)
    if (-not $Id) { return '' }
    if ($Id -match '^(.*[^0-9])?([0-9]+)$') {
        $prefix = [string]$Matches[1]
        $digits = [string]$Matches[2]
        if ($digits.Length -gt 15) { return '' }
        $n = ([long]$digits) + 1
        return ($prefix + $n.ToString().PadLeft($digits.Length, '0'))
    }
    return ''
}

# --- the golden image --------------------------------------------------------
function Find-Images {
    $dirs = @($PSScriptRoot)
    $kit = Split-Path -Parent $PSScriptRoot
    if ($kit) { $dirs += @($kit, (Join-Path $kit 'image'), (Join-Path $kit 'images')) }
    try { $dirs += (Get-Location).ProviderPath } catch { }
    $userDir = [Environment]::GetFolderPath('UserProfile')
    if ($userDir) { $dirs += @((Join-Path $userDir 'Downloads'), (Join-Path $userDir 'Desktop')) }
    $seen = @{}
    $out = @()
    foreach ($d in $dirs) {
        if ((-not $d) -or (-not (Test-Path -LiteralPath $d -PathType Container))) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.img' -File -ErrorAction SilentlyContinue)) {
            if ($f.Extension -ine '.img') { continue }     # Windows' 8.3 matching can let *.imgx through
            $k = $f.FullName.ToLowerInvariant()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            $out += $f.FullName
        }
    }
    return @($out | Sort-Object)
}

function Get-ImageLine {
    param([string]$Path)
    $fi = Get-Item -LiteralPath $Path
    return ('{0} ({1}, {2:yyyy-MM-dd}) in {3}' -f $fi.Name, (Format-Size $fi.Length), $fi.LastWriteTime, $fi.DirectoryName)
}

function Test-ImageFile {
    # Checks a candidate golden image. On success it becomes THE image for this session.
    param([string]$Path)
    if (-not $Path) { Write-Err 'No file was entered.'; return $false }
    try { $Path = Resolve-UserPath $Path } catch { Write-Err "That is not a valid path: $Path"; return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Err "File not found: $Path"; return $false }
    $name = Split-Path -Leaf $Path
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -in '.xz', '.gz', '.zip', '.zst', '.bz2', '.7z', '.tar', '.tgz') {
        Write-Err 'This looks like a compressed file. Extract it first so you have a plain .img file.'
        return $false
    }
    $size = [long](Get-Item -LiteralPath $Path).Length
    if ($size -lt $script:MinImageBytes) {
        Write-Err "$name is only $(Format-Size $size) - too small to be the golden image."
        return $false
    }
    $sig = ''
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            [void]$fs.Seek(510, 'Begin')
            $b = New-Object byte[] 2
            if ($fs.Read($b, 0, 2) -eq 2) { $sig = ('{0:x2}{1:x2}' -f $b[0], $b[1]) }
        } finally { $fs.Dispose() }
    } catch {
        Write-Err "Cannot read ${name}: $($_.Exception.Message)"
        return $false
    }
    if ($sig -ne '55aa') {
        Write-Err "$name does not look like a Raspberry Pi disk image (wrong file?)."
        return $false
    }
    if ($ext -ne '.img') {
        Write-Warn 'The file name does not end in .img.'
        if (-not (Read-YesNo 'Use it anyway?' $false)) { return $false }
    }
    $sumFile = "$Path.sha256"
    if (Test-Path -LiteralPath $sumFile -PathType Leaf) {
        Write-Say 'Checking the image checksum (this can take a minute)...'
        $first = [IO.File]::ReadAllLines($sumFile) | Select-Object -First 1
        $want = ''
        if ($first) { $want = ((([string]$first) -replace '^\uFEFF', '').Trim() -split '\s+')[0].ToLowerInvariant() }
        $got = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($want -ne $got) {
            Write-Err 'CHECKSUM MISMATCH - this image is damaged or is not the approved one. Do not use it.'
            Write-Say "  expected: $want"
            Write-Say "  actual:   $got"
            return $false
        }
        Write-Ok 'Checksum OK.'
    } else {
        Write-Say "(No $name.sha256 file next to the image - checksum check skipped.)"
    }
    $script:Image = $Path
    $script:ImageBytes = $size
    $script:ImageOk = $true
    return $true
}

function Confirm-Image {
    if ($script:ImageOk) { return $true }
    if ($script:Image) {
        if (Test-ImageFile -Path $script:Image) { return $true }
        $script:Image = ''
        return $false
    }
    $found = @(Find-Images)
    if ($found.Count -eq 1) {
        Write-Say 'Found this golden image:'
        Write-Say ('  ' + (Get-ImageLine -Path $found[0]))
        if (Read-YesNo 'Use it?' $true) {
            if (Test-ImageFile -Path $found[0]) { return $true }
            # verification failed (bad checksum, too small, wrong signature): fall through to the manual prompt
        }
    } elseif ($found.Count -gt 1) {
        Write-Say 'Several image files were found:'
        for ($i = 0; $i -lt $found.Count; $i++) { Write-Say ('  {0}) {1}' -f ($i + 1), (Get-ImageLine -Path $found[$i])) }
        $pick = Read-Answer 'Choose the image number, or type/drag in another path'
        if (($pick -match '^\d+$') -and ([long]$pick -ge 1) -and ([long]$pick -le $found.Count)) {
            if (Test-ImageFile -Path $found[[int]$pick - 1]) { return $true }
        } else {
            if (Test-ImageFile -Path $pick) { return $true }
        }
    }
    Write-Say 'Type the path of the golden image (.img) file, or drag the file into this window.'
    $a = Read-Answer 'Image file (or q to go back)'
    if ($a -eq 'q') { return $false }
    return (Test-ImageFile -Path $a)
}

function Confirm-ImageReady {
    if (-not (Confirm-Image)) { return $false }
    try { Initialize-RawDiskType }     # fail now, not after a card has been wiped
    catch {
        Write-Err "Could not prepare the disk writer: $($_.Exception.Message)"
        return $false
    }
    return $true
}

# --- finding the SD card -----------------------------------------------------
function Update-GuardPaths {
    # Disks holding any of these are never offered: wiping them would destroy the kit itself.
    $paths = @($script:Image, $script:WzSiteRoot, $script:LogFile, $PSScriptRoot, (Split-Path -Parent $PSScriptRoot))
    try { $paths += (Get-Location).ProviderPath } catch { }
    $script:GuardPaths = @($paths | Where-Object { $_ })
}

function Test-DiskProtected {
    param($Disk)
    if ($Disk.IsSystem -or $Disk.IsBoot) { return $true }
    foreach ($p in $script:GuardPaths) {
        if (Test-PathOnDisk -Path $p -Disk $Disk) { return $true }
    }
    return $false
}

function Get-DiskLabels {
    param($Disk)
    $out = @()
    foreach ($p in @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue)) {
        $letter = ConvertTo-DriveLetter -Value $p.DriveLetter
        if (-not $letter) { continue }
        $v = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if ($v -and $v.FileSystemLabel) { $out += [string]$v.FileSystemLabel }
    }
    return ($out -join ', ')
}

function Update-CardCache {
    try { Update-HostStorageCache -ErrorAction Stop } catch { }
}

function Find-Cards {
    Update-GuardPaths
    $max = [long]$script:MaxCardGb * 1000000000
    $found = @()
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue)) {
        if ($d.Size -le 0) { continue }                        # empty reader slot
        if ($d.Size -gt $max) { continue }                     # too big to be an SD card
        if (-not (Test-DiskEligible -Disk $d)) { continue }    # system/boot disk, or not a USB / SD bus
        if (Test-DiskProtected -Disk $d) { continue }
        $model = ([string]$d.FriendlyName).Trim()
        if (-not $model) { $model = 'unknown card reader' }
        $found += [pscustomobject]@{
            Number = [int]$d.Number
            Bytes  = [long]$d.Size
            Model  = $model
            Bus    = [string]$d.BusType
            Labels = (Get-DiskLabels -Disk $d)
        }
    }
    $script:Cards = $found
}

function Test-CardPresent {
    param([int]$Number)
    $d = Get-DiskOrNull -Number $Number
    return [bool]($d -and ($d.Size -gt 0))
}

function Get-CardLine {
    param($Card)
    $s = 'Disk {0}  {1}  {2} ({3})' -f $Card.Number, (Format-Size $Card.Bytes), $Card.Model, $Card.Bus
    if ($Card.Labels) { $s += '  - currently holds: ' + $Card.Labels }
    return $s
}

function Wait-ForCard {
    # Returns $false if the operator asks to go back.
    $shown = $false
    $poll = Test-KeyPolling
    Clear-KeyBuffer
    while ($true) {
        Update-CardCache
        Find-Cards
        if ($script:Cards.Count -gt 0) {
            Start-Sleep -Seconds 1
            Find-Cards
            if ($script:Cards.Count -gt 0) { return $true }
            continue
        }
        if (-not $shown) {
            Write-Say 'Insert the SD card into the card reader (and plug the reader into this computer).'
            if ($poll) { Write-Say 'Waiting for a card... (press q to go back)' } else { Write-Say 'Waiting for a card...' }
            $shown = $true
        }
        if ($poll) {
            $k = Read-KeyWithin -Milliseconds 2000
            if ($k -eq 'q') { return $false }
        } else {
            $a = Read-Answer 'Press Enter once the card is in (q = go back)'
            if ($a -eq 'q') { return $false }
        }
    }
}

function Wait-ForRemoval {
    param([int]$Number)
    Update-CardCache
    if (-not (Test-CardPresent -Number $Number)) { return }
    Write-Say 'Please remove the SD card from the reader now.'
    if (Test-KeyPolling) {
        Write-Say '(The wizard continues by itself once it is out. Press Enter to skip this check.)'
        Clear-KeyBuffer
        while (Test-CardPresent -Number $Number) {
            $k = Read-KeyWithin -Milliseconds 1000
            if ($k -eq 'ENTER') { break }
            Update-CardCache
        }
    } else {
        [void](Read-Answer 'Press Enter once the card is out')
    }
}

function Select-Card {
    # Sets $script:Card. Mode 'flash' also needs the card to be big enough for the image.
    param([string]$Mode)
    while ($true) {
        if (-not (Wait-ForCard)) { return $false }
        $n = $script:Cards.Count
        $card = $null
        if ($n -eq 1) {
            Write-Say 'Found this SD card:'
            Write-Say ('  ' + (Get-CardLine -Card $script:Cards[0]))
            if (Read-YesNo 'Use this card?' $true) {
                $card = $script:Cards[0]
            } else {
                if (Read-YesNo 'Look again?' $true) { continue }
                return $false
            }
        } else {
            Write-Say 'Several possible SD cards were found:'
            for ($i = 0; $i -lt $n; $i++) { Write-Say ('  {0}) {1}' -f ($i + 1), (Get-CardLine -Card $script:Cards[$i])) }
            $pick = Read-Answer 'Choose the card number (r = look again, q = go back)'
            if ($pick -eq 'q') { return $false }
            if ($pick -eq 'r') { continue }
            if (($pick -notmatch '^\d+$') -or ([long]$pick -lt 1) -or ([long]$pick -gt $n)) {
                Write-Err 'Please type a number from the list.'
                continue
            }
            $card = $script:Cards[[int]$pick - 1]
        }
        if (($Mode -eq 'flash') -and ($card.Bytes -lt $script:ImageBytes)) {
            Write-Err "That card ($(Format-Size $card.Bytes)) is smaller than the image ($(Format-Size $script:ImageBytes)). Use a bigger card."
            Wait-ForRemoval -Number $card.Number
            continue
        }
        $script:Card = $card
        return $true
    }
}

# --- Gateway ID and site -----------------------------------------------------
function Read-GatewayId {
    # Sets $script:GwId.
    $base = $script:LastId
    if (-not $base) { $base = Get-LastLoggedId }
    $suggest = Get-NextId -Id $base
    Write-Say "Gateway ID rules: letters, numbers and '-' only (for example s3-gw-03)."
    Write-Say 'Every gateway needs its own, unique ID.'
    while ($true) {
        $id = Read-Answer 'Gateway ID' $suggest
        if (-not $id) { Write-Err 'The Gateway ID cannot be empty.'; continue }
        if (-not (Test-GatewayId -Value $id)) {
            Write-Err "'$id' is not a valid Gateway ID. Use letters, numbers and '-' only (no spaces or underscores, no '-' at the start or end, max 63 characters)."
            continue
        }
        $prev = Get-PriorUse -Id $id
        if ($prev) {
            Write-Warn "'$id' was already flashed on $prev."
            if (-not (Read-YesNo 'Use this ID again anyway?' $false)) { continue }
        }
        $script:GwId = $id
        return
    }
}

function Get-SiteReport {
    # What a site folder would install, and what it lacks.
    param([string]$Dir)
    $plan = Get-SitePlan -Dir $Dir
    $found = @($plan.Items | ForEach-Object { $_.Dest })
    $missing = @()
    if (-not (Test-Path -LiteralPath (Join-Path $Dir $plan.CsvName) -PathType Leaf)) { $missing += $plan.CsvName }
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'pygw_conf.py') -PathType Leaf)) { $missing += 'pygw_conf.py' }
    if (@($found | Where-Object { $_ -like 'required-*gw.zip' }).Count -eq 0) { $missing += 'required-*gw.zip' }
    return [pscustomobject]@{ Found = $found; Missing = $missing; Errors = @($plan.Errors); Usable = (($found.Count -gt 0) -and (@($plan.Errors).Count -eq 0)) }
}

function Select-Site {
    # Sets $script:WzSite / $script:WzSiteDir. Returns $false to go back.
    $script:WzSite = ''
    $script:WzSiteDir = ''
    $dirs = @()
    if (Test-Path -LiteralPath $script:WzSiteRoot -PathType Container) {
        $dirs = @(Get-ChildItem -LiteralPath $script:WzSiteRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    }
    if ($dirs.Count -eq 0) {
        if (Read-YesNo 'Does this card need site-specific files (from the project team)?' $false) {
            Write-Err "No site folders were found in: $($script:WzSiteRoot)"
            Write-Say "Put the site files in '$($script:WzSiteRoot)\<site name>\' and start again."
            return $false
        }
        return $true
    }
    if ($script:LastSiteDir -and (Test-Path -LiteralPath $script:LastSiteDir -PathType Container)) {
        if (Read-YesNo "Use the same site as the last card ($($script:LastSite))?" $true) {
            $script:WzSite = $script:LastSite
            $script:WzSiteDir = $script:LastSiteDir
            return $true
        }
    } elseif (($script:LastSite -eq 'none') -and (-not $script:LastSiteDir)) {
        if (Read-YesNo 'Use the image defaults again (no site files), like the last card?' $true) { return $true }
    }
    while ($true) {
        Write-Say 'Which site is this card for?'
        Write-Say '  0) No site files - use the defaults built into the image'
        for ($i = 0; $i -lt $dirs.Count; $i++) { Write-Say ('  {0}) {1}' -f ($i + 1), $dirs[$i].Name) }
        $pick = Read-Answer 'Choose a number (q = go back)'
        if ($pick -eq 'q') { return $false }
        if (($pick -notmatch '^\d+$') -or ([long]$pick -gt $dirs.Count)) {
            Write-Err 'Please type a number from the list.'
            continue
        }
        if ([long]$pick -eq 0) { return $true }
        $d = $dirs[[int]$pick - 1]
        $rep = Get-SiteReport -Dir $d.FullName
        if (-not $rep.Usable) {
            if (@($rep.Errors).Count -gt 0) {
                Write-Err "The folder '$($d.Name)' cannot be used:"
                foreach ($e in $rep.Errors) { Write-Err "  - $e" }
                Write-Say 'Ask the project team for corrected site files.'
            } else {
                Write-Err "The folder '$($d.Name)' has none of the expected files (the node-list .csv named in pygw_conf.py, pygw_conf.py, required-*gw.zip)."
            }
            continue
        }
        Write-Say "  Site '$($d.Name)' will install: $($rep.Found -join ', ')"
        if ($rep.Missing.Count -gt 0) { Write-Warn "Not in this folder (the image default is kept): $($rep.Missing -join ', ')" }
        if (-not (Read-YesNo 'Is that the right site?' $true)) { continue }
        $script:WzSite = $d.Name
        $script:WzSiteDir = $d.FullName
        return $true
    }
}

# --- running one card --------------------------------------------------------
function Show-Plan {
    param([string]$Mode, [string]$Id)
    $c = $script:Card
    Write-Head 'Please check:'
    Write-Rule
    if ($Mode -eq 'flash') {
        Write-Say ('   {0,-12} {1} ({2})' -f 'Image', (Split-Path -Leaf $script:Image), (Format-Size $script:ImageBytes))
    } else {
        Write-Say ('   {0,-12} {1}' -f 'Action', 'write the Gateway ID only (card is NOT re-flashed)')
    }
    Write-Say ('   {0,-12} Disk {1}  {2}  {3}' -f 'SD card', $c.Number, (Format-Size $c.Bytes), $c.Model)
    Write-Say ('   {0,-12} {1}' -f 'Gateway ID', $Id)
    $what = 'none - the defaults built into the image'
    if ($script:WzSiteDir) {
        $rep = Get-SiteReport -Dir $script:WzSiteDir
        $what = '{0} ({1})' -f $script:WzSite, ($rep.Found -join ', ')
    }
    Write-Say ('   {0,-12} {1}' -f 'Site files', $what)
    Write-Rule
    if ($Mode -eq 'flash') { Write-Host '   EVERYTHING ON THE SD CARD WILL BE ERASED.' -ForegroundColor Red }
}

function Invoke-WizardCard {
    # Hands the chosen card to Invoke-Card (which asks for the disk number again). Returns $true on success.
    param([string]$Mode, [string]$Id)
    $script:NoFlash = ($Mode -eq 'relabel')
    $script:DiskNumber = [int]$script:Card.Number
    $script:DiskFromParam = $true
    Update-GuardPaths
    Write-Host ''
    Write-Say "Starting. You will be asked to type the disk number ($($script:Card.Number)) once more to confirm."
    $script:Flashing = $true
    $ok = $false
    try {
        [void](Invoke-Card -Gw $Id -SiteDirPath $script:WzSiteDir)
        $ok = $true
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        Write-Err $_.Exception.Message
    }
    $script:Flashing = $false
    return $ok
}

function Complete-Card {
    param([bool]$Ok, [string]$Mode, [string]$Id)
    $c = $script:Card
    Write-Host ''
    if ($Ok) {
        $result = 'FLASHED'
        if ($Mode -ne 'flash') { $result = 'RELABELED' }
        Add-LogRow -Result $result -Gw $Id -SiteName $script:WzSite -Model $c.Model -Bytes $c.Bytes -Device ('Disk ' + $c.Number)
        $script:LastId = $Id
        $script:LastSite = 'none'
        if ($script:WzSite) { $script:LastSite = $script:WzSite }
        $script:LastSiteDir = $script:WzSiteDir
        Write-Ok "DONE - card for $Id is ready."
        Write-Say "  1. Wait until the card reader's light stops blinking."
        Write-Say "  2. Take the card out and label it:  $Id"
        Write-Host "`a" -NoNewline
        return $true
    }
    Add-LogRow -Result 'INCOMPLETE' -Gw $Id -SiteName $script:WzSite -Model $c.Model -Bytes $c.Bytes -Device ('Disk ' + $c.Number)
    Write-Err 'This card was NOT completed (it failed or was cancelled). Read the messages above.'
    Write-Say '  Do not use this card until it has been flashed again successfully.'
    Write-Host "`a" -NoNewline
    return $false
}

# --- modes -------------------------------------------------------------------
function Invoke-SingleMode {
    if (-not (Confirm-ImageReady)) { return }
    while ($true) {
        Write-Head 'New card'
        Read-GatewayId
        if (-not (Select-Site)) { return }
        if (-not (Select-Card -Mode 'flash')) { return }
        Show-Plan -Mode 'flash' -Id $script:GwId
        if (-not (Read-YesNo 'Is this correct?' $true)) {
            Write-Say "OK - let's start this card again."
            Wait-ForRemoval -Number $script:Card.Number
            continue
        }
        $ok = Invoke-WizardCard -Mode 'flash' -Id $script:GwId
        [void](Complete-Card -Ok $ok -Mode 'flash' -Id $script:GwId)
        Wait-ForRemoval -Number $script:Card.Number
        if (-not (Read-YesNo 'Flash another card?' $true)) { return }
    }
}

function Invoke-RelabelMode {
    Write-Head 'Change the Gateway ID on a card without re-flashing'
    Write-Say 'Use this ONLY for a card that has never been started in a gateway.'
    Write-Say 'A gateway that has already booted keeps its ID - re-flash that card instead.'
    if (-not (Read-YesNo 'Has this card NEVER been booted in a gateway?' $false)) {
        Write-Say 'Then use option 1 (flash) to give it a new ID.'
        return
    }
    while ($true) {
        Read-GatewayId
        if (-not (Select-Site)) { return }
        if (-not (Select-Card -Mode 'relabel')) { return }
        Show-Plan -Mode 'relabel' -Id $script:GwId
        if (-not (Read-YesNo 'Is this correct?' $true)) {
            Wait-ForRemoval -Number $script:Card.Number
            continue
        }
        $ok = Invoke-WizardCard -Mode 'relabel' -Id $script:GwId
        [void](Complete-Card -Ok $ok -Mode 'relabel' -Id $script:GwId)
        Wait-ForRemoval -Number $script:Card.Number
        if (-not (Read-YesNo 'Change another card?' $false)) { return }
    }
}

function Read-WizardBatchCsv {
    # Returns the rows (Id, Site), or $null after printing what is wrong. Comment lines,
    # blank lines, a BOM and Excel/Windows line endings are all fine.
    param([string]$Path)
    $first = $true
    $idCol = -1
    $siteCol = -1
    $n = 0
    $bad = $false
    $seen = @{}
    $rows = @()
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.TrimEnd("`r")
        if ($first) { $line = $line.TrimStart([char]0xFEFF) }
        if ($line -match '^\s*(#.*)?$') { continue }
        $cols = @($line.Split(',') | ForEach-Object { ConvertTo-CleanField -Value $_ })
        if ($first) {
            for ($i = 0; $i -lt $cols.Count; $i++) {
                $h = $cols[$i].ToLowerInvariant()
                if ($h -eq 'gateway_id') { $idCol = $i } elseif ($h -eq 'site') { $siteCol = $i }
            }
            if ($idCol -lt 0) {
                Write-Err "The first line of the CSV must be a header containing 'gateway_id' (for example: gateway_id,site,notes)."
                return $null
            }
            $first = $false
            continue
        }
        $n++
        $id = ''
        if ($idCol -lt $cols.Count) { $id = $cols[$idCol] }
        $siteName = ''
        if (($siteCol -ge 0) -and ($siteCol -lt $cols.Count)) { $siteName = $cols[$siteCol] }
        $lc = $id.ToLowerInvariant()
        if (-not (Test-GatewayId -Value $id)) {
            Write-Err "Row ${n}: '$id' is not a valid Gateway ID."
            $bad = $true
        } elseif ($seen.ContainsKey($lc)) {
            Write-Err "Row ${n}: Gateway ID '$id' appears twice in the CSV."
            $bad = $true
        }
        $seen[$lc] = $true
        if ($siteName) {
            if (-not (Test-SiteName -Value $siteName)) {
                Write-Err "Row ${n} ($id): site name '$siteName' must not contain \ / or :"
                $bad = $true
            } else {
                $sd = Join-Path $script:WzSiteRoot $siteName
                if (-not (Test-Path -LiteralPath $sd -PathType Container)) {
                    Write-Err "Row ${n} ($id): site folder not found: $sd"
                    $bad = $true
                } else {
                    $srep = Get-SiteReport -Dir $sd
                    if (-not $srep.Usable) {
                        if (@($srep.Errors).Count -gt 0) {
                            foreach ($e in $srep.Errors) { Write-Err "Row ${n} ($id): site '$siteName': $e" }
                        } else {
                            Write-Err "Row ${n} ($id): site folder '$siteName' has none of the expected files."
                        }
                        $bad = $true
                    }
                }
            }
        }
        $rows += [pscustomobject]@{ Id = $id; Site = $siteName }
    }
    if ($first) { Write-Err 'The CSV file is empty.'; return $null }
    if ($rows.Count -eq 0) { Write-Err 'The CSV has a header but no cards.'; return $null }
    if ($bad) { return $null }
    return ,$rows
}

function Show-BatchSummary {
    param([int]$Ok, [int]$Failed, [int]$Skipped, [int]$Total)
    Write-Head 'Batch finished'
    Write-Say "  Flashed OK    : $Ok"
    Write-Say "  Not completed : $Failed"
    Write-Say "  Skipped       : $Skipped"
    Write-Say "  In the list   : $Total"
    if ($Failed -gt 0) { Write-Warn 'Some cards were not completed - see the messages above and the log (option 4).' }
}

function Invoke-BatchMode {
    if (-not (Confirm-ImageReady)) { return }
    Write-Head 'Batch from a CSV list'
    Write-Say 'The CSV needs a header line (gateway_id,site,notes) and one line per card.'
    $default = Join-Path $PSScriptRoot 'gateways.csv'
    if (Test-Path -LiteralPath $default -PathType Leaf) {
        $a = Read-Answer 'CSV file' $default
    } else {
        $a = Read-Answer 'CSV file (type or drag it in, q = go back)'
    }
    if ($a -eq 'q') { return }
    try { $csv = Resolve-UserPath $a } catch { Write-Err "That is not a valid path: $a"; return }
    if ((-not $csv) -or (-not (Test-Path -LiteralPath $csv -PathType Leaf))) { Write-Err "File not found: $csv"; return }
    $rows = Read-WizardBatchCsv -Path $csv
    if ($null -eq $rows) { Write-Say 'Fix the problems above in the CSV and start again.'; return }
    $rows = @($rows)
    $n = $rows.Count
    Write-Say "The list has $n card(s):"
    $doneCount = 0
    for ($i = 0; $i -lt $n; $i++) {
        $note = ''
        if (Get-PriorUse -Id $rows[$i].Id) { $note = '  (already flashed before)'; $doneCount++ }
        $siteText = 'none'
        if ($rows[$i].Site) { $siteText = $rows[$i].Site }
        Write-Say ('  {0,2}) {1,-24} site: {2}{3}' -f ($i + 1), $rows[$i].Id, $siteText, $note)
    }
    $skipDone = $false
    if ($doneCount -gt 0) {
        if (Read-YesNo "$doneCount card(s) were already flashed. Skip those?" $true) { $skipDone = $true }
    }
    if (-not (Read-YesNo 'Start the batch?' $true)) { return }

    $okN = 0; $failN = 0; $skipN = 0
    :cards for ($i = 0; $i -lt $n; $i++) {
        $script:GwId = $rows[$i].Id
        $script:WzSite = $rows[$i].Site
        $script:WzSiteDir = ''
        if ($script:WzSite) { $script:WzSiteDir = Join-Path $script:WzSiteRoot $script:WzSite }
        if ($skipDone -and (Get-PriorUse -Id $script:GwId)) { $skipN++; continue }
        $siteText = 'none'
        if ($script:WzSite) { $siteText = $script:WzSite }
        Write-Head ('Card {0} of {1}:  {2}   (site: {3})' -f ($i + 1), $n, $script:GwId, $siteText)
        while ($true) {
            if (-not (Select-Card -Mode 'flash')) {
                Write-Say 'Batch stopped.'
                Show-BatchSummary -Ok $okN -Failed $failN -Skipped $skipN -Total $n
                return
            }
            Show-Plan -Mode 'flash' -Id $script:GwId
            $ans = ''
            while ($true) {
                $ans = (Read-Answer 'Press Enter to start, s = skip this card, q = stop the batch').ToLowerInvariant()
                if (($ans -eq '') -or ($ans -eq 's') -or ($ans -eq 'q')) { break }
                Write-Say 'Please press Enter, s or q.'
            }
            if ($ans -eq 's') {
                $skipN++
                Wait-ForRemoval -Number $script:Card.Number
                continue cards
            }
            if ($ans -eq 'q') {
                Wait-ForRemoval -Number $script:Card.Number
                Show-BatchSummary -Ok $okN -Failed $failN -Skipped $skipN -Total $n
                return
            }
            $ok = Invoke-WizardCard -Mode 'flash' -Id $script:GwId
            if (Complete-Card -Ok $ok -Mode 'flash' -Id $script:GwId) { $okN++ } else { $failN++ }
            Wait-ForRemoval -Number $script:Card.Number
            break
        }
    }
    Show-BatchSummary -Ok $okN -Failed $failN -Skipped $skipN -Total $n
}

function Show-FlashLog {
    $rows = @(Read-LogRows)
    if ($rows.Count -eq 0) { Write-Say 'Nothing has been recorded yet.'; return }
    Write-Head "Last 20 flashes (full record: $($script:LogFile))"
    $fmt = '  {0,-19} {1,-10} {2,-16} {3,-10} {4,-11} {5}'
    Write-Say ($fmt -f 'timestamp', 'operator', 'gateway_id', 'site', 'result', 'card_model')
    foreach ($r in @($rows | Select-Object -Last 20)) {
        Write-Say ($fmt -f $r.timestamp, $r.operator, $r.gateway_id, $r.site, $r.result, $r.card_model)
    }
}

function Show-MainMenu {
    while ($true) {
        Write-Head 'S3 Gateway - SD card flashing'
        Write-Say '  1) Flash SD cards, one at a time'
        Write-Say '  2) Flash a batch from a CSV list'
        Write-Say '  3) Change the Gateway ID on a card that has never been booted'
        Write-Say '  4) Show what has been flashed'
        Write-Say '  q) Quit'
        $choice = (Read-Answer 'Choose').ToLowerInvariant()
        if ($choice -eq '1') { Invoke-SingleMode }
        elseif ($choice -eq '2') { Invoke-BatchMode }
        elseif ($choice -eq '3') { Invoke-RelabelMode }
        elseif ($choice -eq '4') { Show-FlashLog }
        elseif ($choice -in 'q', 'quit', 'exit') { Write-Say 'Goodbye.'; return }
        else { Write-Err 'Please type 1, 2, 3, 4 or q.' }
    }
}

function Test-WizardRequested {
    # Any card-specific option means "command-line mode"; otherwise the wizard runs.
    if ($script:ListDisks -or $script:NoFlash -or $script:Batch -or $script:GatewayId -or $script:SiteDir -or $script:Site) { return $false }
    if ($script:DiskNumber -ge 0) { return $false }
    return $true
}

function Restart-Elevated {
    # Windows' equivalent of the Linux wizard's "exec sudo": relaunch this script as Administrator.
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = 'powershell.exe' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-PauseAtEnd')
    if ($script:Image)         { $argList += @('-Image', ('"{0}"' -f (Resolve-UserPath $script:Image))) }
    if ($script:SiteFilesRoot) { $argList += @('-SiteFilesRoot', ('"{0}"' -f (Resolve-UserPath $script:SiteFilesRoot))) }
    if ($script:KeepLineEndings)  { $argList += '-KeepLineEndings' }
    if ($script:AllowNonRemovable) { $argList += '-AllowNonRemovable' }
    Write-Say 'Administrator rights are needed to write to SD cards.'
    Write-Say 'Windows will now ask for permission and open the wizard in a new window.'
    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList ($argList -join ' ')
    } catch {
        throw 'Could not start PowerShell as Administrator (was the Windows prompt cancelled?).'
    }
}

function Invoke-Wizard {
    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        throw 'The Windows Storage cmdlets (Get-Disk) are not available on this PC.'
    }
    if ($script:SiteFilesRoot) { $script:WzSiteRoot = Resolve-UserPath $script:SiteFilesRoot }
    else { $script:WzSiteRoot = Join-Path $PSScriptRoot 'site-files' }
    Initialize-Log
    Write-Head 'Welcome'
    Write-Say 'This wizard flashes the golden S3 Gateway image onto SD cards and gives'
    Write-Say 'each card its own Gateway ID. Before you start:'
    Write-Say '  - plug in your SD card reader,'
    Write-Say '  - have the Gateway IDs from your batch sheet ready,'
    Write-Say '  - never remove a card while it is being written.'
    Write-Say 'You can stop at any time with Ctrl+C.'
    try {
        Show-MainMenu
    } finally {
        if ($script:Flashing) {
            Write-Host ''
            Write-Warn 'Interrupted while writing. That SD card is NOT usable - flash it again.'
        }
    }
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-S3Provision {
    if (-not (Test-IsWindows)) { throw 'This is the Windows version. On Linux use host/flash-and-provision.sh.' }

    # No card-specific option given: run the guided wizard (same flow as the Linux flash wizard).
    if (Test-WizardRequested) {
        if (-not (Test-IsAdmin)) { Restart-Elevated; return 0 }
        return (Invoke-Wizard)
    }

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
