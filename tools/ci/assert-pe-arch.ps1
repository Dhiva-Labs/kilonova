# Fails unless every .exe and .dll under -Path (a folder, or one file) is built
# for the given architecture (PE machine 0x8664 for x64, 0xAA64 for arm64) and
# every -Required name is among them. With -Aot it also checks that the Dart
# AOT snapshot data\app.so, which is an ELF file even on Windows, has the
# matching ELF machine. CI runs it on the Flutter release folder, so
# kn_ffi.dll (the Rust library) is checked along with the runner and plugins.
#
#   tools/ci/assert-pe-arch.ps1 -Path <folder> -Arch x64|arm64 -Aot -Required kilonova.exe,kn_ffi.dll
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Arch,
    [switch]$Aot,
    [string[]]$Required = @()
)
$ErrorActionPreference = 'Stop'

$peMachine = @{ x64 = 0x8664; arm64 = 0xAA64 }[$Arch]
$elfMachine = @{ x64 = 0x3E; arm64 = 0xB7 }[$Arch]

function Get-PeMachine([string]$File) {
    $fs = [IO.File]::OpenRead($File)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $fs.Position = $br.ReadInt32()
        if ($br.ReadUInt32() -ne 0x4550) { throw "$File is not a PE file" }
        return $br.ReadUInt16()
    } finally { $fs.Dispose() }
}

if (Test-Path -Path $Path -PathType Leaf) {
    $files = @(Get-Item -Path $Path)
} else {
    $files = @(Get-ChildItem -Path $Path -Recurse -File -Include *.exe, *.dll)
}
foreach ($name in $Required) {
    if (-not ($files.Name -contains $name)) { throw "$name is missing from $Path" }
}

$bad = 0
foreach ($f in $files) {
    $m = Get-PeMachine $f.FullName
    '{0,-50} 0x{1:X4}' -f $f.Name, $m
    if ($m -ne $peMachine) {
        Write-Host "::error file=$($f.FullName)::machine 0x$('{0:X4}' -f $m), expected 0x$('{0:X4}' -f $peMachine)"
        $bad++
    }
}

if ($Aot) {
    $snapshot = Join-Path $Path 'data\app.so'
    if (-not (Test-Path $snapshot)) { throw "$snapshot is missing" }
    $bytes = [IO.File]::ReadAllBytes($snapshot)
    $elf = [BitConverter]::ToUInt16($bytes, 0x12)
    'data\app.so ELF e_machine 0x{0:X2}' -f $elf
    if ($elf -ne $elfMachine) {
        Write-Host "::error::data\app.so is not ELF machine 0x$('{0:X2}' -f $elfMachine)"
        $bad++
    }
}

"checked $($files.Count) PE files for $Arch"
# Throw rather than exit: a calling step only stops on an exception, not on
# a script's exit code.
if ($files.Count -eq 0) { throw "no .exe or .dll files found under $Path" }
if ($bad -gt 0) { throw "$bad file(s) are not $Arch" }
