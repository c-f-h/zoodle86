param(
    [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootAsm = Join-Path $root "boot.asm"
$bootBin = Join-Path $root "boot.bin"
$stage2Asm = Join-Path $root "stage2.asm"
$stage2Bin = Join-Path $root "stage2.bin"
$floppyImg = Join-Path $root "floppy.img"
$bochsrc = Join-Path $root "bochsrc.txt"
$stage2Sectors = 4

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Glob
    )

    $matches = Get-ChildItem -Path $Glob -File -ErrorAction SilentlyContinue | Sort-Object FullName
    if (-not $matches) {
        throw "Could not find tool matching: $Glob"
    }

    return $matches[-1].FullName
}

$nasmExe = Resolve-ToolPath -Glob "C:\Program Files\nasm*\nasm.exe"
$bochsExe = Resolve-ToolPath -Glob "C:\Program Files\Bochs*\bochs.exe"
$bochsDir = Split-Path -Parent $bochsExe

Write-Host "NASM : $nasmExe"
Write-Host "Bochs: $bochsExe"

$bochsConfig = @"
megs: 32
romimage: file="$bochsDir\BIOS-bochs-latest", options=fastboot
vgaromimage: file="$bochsDir\VGABIOS-lgpl-latest.bin"
boot: floppy
floppya: 1_44="floppy.img", status=inserted
log: bochsout.txt
display_library: win32
panic: action=ask
error: action=report
info: action=report
debug: action=ignore
clock: sync=realtime
"@

[System.IO.File]::WriteAllText($bochsrc, $bochsConfig)

& $nasmExe -f bin $bootAsm -o $bootBin
if ($LASTEXITCODE -ne 0) {
    throw "NASM failed."
}

& $nasmExe -f bin $stage2Asm -o $stage2Bin
if ($LASTEXITCODE -ne 0) {
    throw "NASM failed assembling stage2."
}

$bootBytes = [System.IO.File]::ReadAllBytes($bootBin)
if ($bootBytes.Length -ne 512) {
    throw "Boot sector must be exactly 512 bytes, got $($bootBytes.Length)."
}

$stage2Bytes = [System.IO.File]::ReadAllBytes($stage2Bin)
$stage2Capacity = $stage2Sectors * 512
if ($stage2Bytes.Length -gt $stage2Capacity) {
    throw "stage2.bin is $($stage2Bytes.Length) bytes, but only $stage2Capacity bytes are reserved."
}

$floppySize = 1474560
$imageBytes = New-Object byte[] $floppySize
[Array]::Copy($bootBytes, 0, $imageBytes, 0, $bootBytes.Length)
[Array]::Copy($stage2Bytes, 0, $imageBytes, 512, $stage2Bytes.Length)
[System.IO.File]::WriteAllBytes($floppyImg, $imageBytes)

if ($BuildOnly) {
    Write-Host "Built $bootBin, $stage2Bin, and $floppyImg"
    exit 0
}

Push-Location $root
try {
    & $bochsExe -q -f $bochsrc #-dbg
    if ($LASTEXITCODE -ne 0) {
        throw "Bochs exited with code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
