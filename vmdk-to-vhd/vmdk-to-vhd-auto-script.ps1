
<#
.SYNOPSIS
    Automates the process of aligning a disk file to a 1MB boundary for Azure migration.
.DESCRIPTION
    Based on the Adex guide, this script converts a disk to a temporary RAW file,
    calculates the correct 1MB boundary size, resizes the RAW file, and converts
    it back to an Azure-compliant fixed-type VHD.
.EXAMPLE
    .\convert.ps1 -QemuImgPath ".\qemu\qemu-img.exe" -SourceDisk ".\kali-disk001.vmdk" -DestinationVhd ".\kali.vhd"
#>
param(
    [Parameter(Mandatory = $true, HelpMessage = "Full path to your qemu-img.exe")]
    [string]$QemuImgPath,

    [Parameter(Mandatory = $true, HelpMessage = "Path to the input VHD or VMDK file")]
    [string]$SourceDisk,

    [Parameter(Mandatory = $true, HelpMessage = "Path where the final Azure-aligned VHD will be saved")]
    [string]$DestinationVhd
)

# Set up temporary raw disk path in the same directory as destination
$RawDisk = [System.IO.Path]::ChangeExtension($DestinationVhd, ".raw")

Write-Host "[1/4] Converting source disk to RAW format (Auto-detecting input format)..." -ForegroundColor Cyan
# Removed '-f vpc' so qemu-img can automatically read your VMDK format cleanly
& $QemuImgPath convert -O raw $SourceDisk $RawDisk -p

if (-not (Test-Path $RawDisk)) {
    Write-Error "Failed to create raw disk. Aborting."
    exit
}

Write-Host "[2/4] Calculating 1MB alignment size..." -ForegroundColor Cyan
# Run qemu-img info, parse the JSON string, and find virtual size
$JsonOutput = & $QemuImgPath info -f raw --output json $RawDisk | ConvertFrom-Json
$Size = $JsonOutput."virtual-size"

# Ceiling math to round up to the nearest 1MB (1,048,576 bytes)
$RoundedSize = [Math]::Ceiling($Size / 1MB) * 1MB

Write-Host "Original Size: $Size bytes" -ForegroundColor Gray
Write-Host "Azure Aligned Size: $RoundedSize bytes" -ForegroundColor Green

Write-Host "[3/4] Resizing RAW image to match boundary..." -ForegroundColor Cyan
& $QemuImgPath resize -f raw $RawDisk $RoundedSize

Write-Host "[4/4] Converting RAW back to Fixed-type VHD..." -ForegroundColor Cyan
& $QemuImgPath convert -f raw -o subformat=fixed,force_size -O vpc $RawDisk $DestinationVhd -p

# Cleanup temporary RAW file
if (Test-Path $RawDisk) {
    Write-Host "Cleaning up temporary RAW file..." -ForegroundColor Gray
    Remove-Item $RawDisk -Force
}

Write-Host "Process complete! Your Azure-ready VHD is located at: $DestinationVhd" -ForegroundColor Green
