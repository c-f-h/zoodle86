param(
    [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootAsm = Join-Path $root "boot.asm"
$bootBin = Join-Path $root "boot.bin"
$interruptsAsm = Join-Path $root "interrupts.asm"
$interruptsObj = Join-Path $root "interrupts.o"
$kernelC = Join-Path $root "kernel.c"
$kernelObj = Join-Path $root "kernel.o"
$stage2Pe = Join-Path $root "stage2.exe"
$stage2Bin = Join-Path $root "stage2.bin"
$floppyImg = Join-Path $root "floppy.img"
$bochsrc = Join-Path $root "bochsrc.txt"

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
$tcc32Exe = Resolve-ToolPath -Glob "C:\Program Files (x86)\tcc*\i386-win32-tcc.exe"
$bochsExe = Resolve-ToolPath -Glob "C:\Program Files\Bochs*\bochs.exe"
$bochsDir = Split-Path -Parent $bochsExe

Write-Host "NASM : $nasmExe"
Write-Host "TCC  : $tcc32Exe"
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

if (Test-Path $interruptsObj) {
    Remove-Item $interruptsObj -Force
}
if (Test-Path $kernelObj) {
    Remove-Item $kernelObj -Force
}

& $nasmExe -f elf32 $interruptsAsm -o $interruptsObj
if ($LASTEXITCODE -ne 0) {
    throw "NASM failed compiling interrupts.asm."
}

& $tcc32Exe -c $kernelC
if ($LASTEXITCODE -ne 0) {
    throw "TCC failed compiling kernel.c."
}

if (-not (Test-Path $interruptsObj)) {
    throw "NASM did not produce interrupts.o."
}
if (-not (Test-Path $kernelObj)) {
    throw "TCC did not produce kernel.o."
}

& $tcc32Exe `
    -nostdlib `
    '-Wl,-image-base=0x8000' `
    '-Wl,-section-alignment=0x200' `
    '-Wl,-file-alignment=0x200' `
    -o $stage2Pe `
    $interruptsObj `
    $kernelObj
if ($LASTEXITCODE -ne 0) {
    throw "TCC failed linking stage2.pe."
}

$peBytes = [System.IO.File]::ReadAllBytes($stage2Pe)
if ($peBytes.Length -lt 0x40) {
    throw "stage2.pe is too small to be a valid PE image."
}

$peHeaderOffset = [BitConverter]::ToInt32($peBytes, 0x3C)
$signature = [BitConverter]::ToUInt32($peBytes, $peHeaderOffset)
if ($signature -ne 0x00004550) {
    throw "stage2.pe does not contain a valid PE signature."
}

$coffOffset = $peHeaderOffset + 4
$numberOfSections = [BitConverter]::ToUInt16($peBytes, $coffOffset + 2)
$sizeOfOptionalHeader = [BitConverter]::ToUInt16($peBytes, $coffOffset + 16)
$optionalOffset = $coffOffset + 20
$optionalMagic = [BitConverter]::ToUInt16($peBytes, $optionalOffset)
if ($optionalMagic -ne 0x10B) {
    throw "Expected a PE32 optional header, got 0x{0:X}" -f $optionalMagic
}

$entryRva = [BitConverter]::ToInt32($peBytes, $optionalOffset + 16)
$imageBase = [BitConverter]::ToInt32($peBytes, $optionalOffset + 28)
if ($imageBase -ne 0x8000) {
    throw "Expected stage2 image base 0x8000, got 0x{0:X}" -f $imageBase
}

$sectionTableOffset = $optionalOffset + $sizeOfOptionalHeader
$imageSize = 0
for ($i = 0; $i -lt $numberOfSections; ++$i) {
    $sectionOffset = $sectionTableOffset + (40 * $i)
    $virtualSize = [BitConverter]::ToInt32($peBytes, $sectionOffset + 8)
    $virtualAddress = [BitConverter]::ToInt32($peBytes, $sectionOffset + 12)
    $sizeOfRawData = [BitConverter]::ToInt32($peBytes, $sectionOffset + 16)
    $end = $virtualAddress + [Math]::Max($virtualSize, $sizeOfRawData)
    if ($end -gt $imageSize) {
        $imageSize = $end
    }
}

$stage2Bytes = New-Object byte[] $imageSize
for ($i = 0; $i -lt $numberOfSections; ++$i) {
    $sectionOffset = $sectionTableOffset + (40 * $i)
    $virtualAddress = [BitConverter]::ToInt32($peBytes, $sectionOffset + 12)
    $sizeOfRawData = [BitConverter]::ToInt32($peBytes, $sectionOffset + 16)
    $pointerToRawData = [BitConverter]::ToInt32($peBytes, $sectionOffset + 20)
    if ($sizeOfRawData -gt 0) {
        [Array]::Copy($peBytes, $pointerToRawData, $stage2Bytes, $virtualAddress, $sizeOfRawData)
    }
}

[System.IO.File]::WriteAllBytes($stage2Bin, $stage2Bytes)

$stage2Sectors = [int][Math]::Ceiling($stage2Bytes.Length / 512.0)
if ($stage2Sectors -lt 1) {
    throw "Computed invalid stage2 sector count."
}
if ($stage2Sectors -gt 18) {
    throw "stage2.bin requires $stage2Sectors sectors, which does not fit in one floppy track with the current CHS loader."
}

& $nasmExe "-DSTAGE2_SECTORS=$stage2Sectors" "-DSTAGE2_ENTRY_OFFSET=$entryRva" -f bin $bootAsm -o $bootBin
if ($LASTEXITCODE -ne 0) {
    throw "NASM failed assembling boot sector."
}

$bootBytes = [System.IO.File]::ReadAllBytes($bootBin)
if ($bootBytes.Length -ne 512) {
    throw "Boot sector must be exactly 512 bytes, got $($bootBytes.Length)."
}

$floppySize = 1474560
$imageBytes = New-Object byte[] $floppySize
[Array]::Copy($bootBytes, 0, $imageBytes, 0, $bootBytes.Length)
[Array]::Copy($stage2Bytes, 0, $imageBytes, 512, $stage2Bytes.Length)
[System.IO.File]::WriteAllBytes($floppyImg, $imageBytes)

if ($BuildOnly) {
    Write-Host "Built $bootBin, $stage2Bin, and $floppyImg"
    Write-Host "Stage2 entry offset: 0x$("{0:X}" -f $entryRva)"
    Write-Host "Stage2 sectors     : $stage2Sectors"
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
