param(
    [string]$OutputDir = $PSScriptRoot,
    [string]$SymbolCache = (Join-Path $env:LOCALAPPDATA "xemu\symbols"),
    [string[]]$Modules = @(
        (Join-Path $env:WINDIR "System32\wdmaud.drv"),
        (Join-Path $env:WINDIR "System32\msacm32.drv")
    ),
    [switch]$NoCopy
)

$ErrorActionPreference = "Stop"

function Read-UInt16 {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Read-UInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Convert-RvaToFileOffset {
    param(
        [uint32]$Rva,
        [object[]]$Sections
    )

    foreach ($section in $Sections) {
        $size = [Math]::Max($section.VirtualSize, $section.SizeOfRawData)
        if ($Rva -ge $section.VirtualAddress -and $Rva -lt ($section.VirtualAddress + $size)) {
            return [int]($section.PointerToRawData + ($Rva - $section.VirtualAddress))
        }
    }

    return $null
}

function Get-PeCodeViewInfo {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "Not a PE image: $Path"
    }

    $peOffset = [int](Read-UInt32 -Bytes $bytes -Offset 0x3c)
    if ($peOffset + 24 -ge $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or
        $bytes[$peOffset + 1] -ne 0x45 -or
        $bytes[$peOffset + 2] -ne 0 -or
        $bytes[$peOffset + 3] -ne 0) {
        throw "Invalid PE header: $Path"
    }

    $sectionCount = Read-UInt16 -Bytes $bytes -Offset ($peOffset + 6)
    $optionalHeaderSize = Read-UInt16 -Bytes $bytes -Offset ($peOffset + 20)
    $optionalHeaderOffset = $peOffset + 24
    $magic = Read-UInt16 -Bytes $bytes -Offset $optionalHeaderOffset
    if ($magic -eq 0x20b) {
        $dataDirectoryOffset = $optionalHeaderOffset + 112
    } elseif ($magic -eq 0x10b) {
        $dataDirectoryOffset = $optionalHeaderOffset + 96
    } else {
        throw ("Unsupported PE optional header magic: 0x{0:x}" -f $magic)
    }

    $debugDirectoryOffset = $dataDirectoryOffset + (6 * 8)
    $debugRva = Read-UInt32 -Bytes $bytes -Offset $debugDirectoryOffset
    $debugSize = Read-UInt32 -Bytes $bytes -Offset ($debugDirectoryOffset + 4)
    if ($debugRva -eq 0 -or $debugSize -eq 0) {
        return $null
    }

    $sectionTableOffset = $optionalHeaderOffset + $optionalHeaderSize
    $sections = @()
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $offset = $sectionTableOffset + ($i * 40)
        $sections += [pscustomobject]@{
            VirtualSize      = Read-UInt32 -Bytes $bytes -Offset ($offset + 8)
            VirtualAddress   = Read-UInt32 -Bytes $bytes -Offset ($offset + 12)
            SizeOfRawData    = Read-UInt32 -Bytes $bytes -Offset ($offset + 16)
            PointerToRawData = Read-UInt32 -Bytes $bytes -Offset ($offset + 20)
        }
    }

    $debugOffset = Convert-RvaToFileOffset -Rva $debugRva -Sections $sections
    if ($null -eq $debugOffset) {
        throw "Could not map debug directory RVA for $Path"
    }

    $entryCount = [Math]::Floor($debugSize / 28)
    for ($i = 0; $i -lt $entryCount; $i++) {
        $entryOffset = $debugOffset + ($i * 28)
        $type = Read-UInt32 -Bytes $bytes -Offset ($entryOffset + 12)
        $sizeOfData = Read-UInt32 -Bytes $bytes -Offset ($entryOffset + 16)
        $pointerToRawData = Read-UInt32 -Bytes $bytes -Offset ($entryOffset + 24)
        if ($type -ne 2 -or $sizeOfData -lt 24 -or $pointerToRawData -le 0) {
            continue
        }

        if ($pointerToRawData + 24 -ge $bytes.Length -or
            $bytes[$pointerToRawData] -ne 0x52 -or
            $bytes[$pointerToRawData + 1] -ne 0x53 -or
            $bytes[$pointerToRawData + 2] -ne 0x44 -or
            $bytes[$pointerToRawData + 3] -ne 0x53) {
            continue
        }

        $guidBytes = New-Object byte[] 16
        [Array]::Copy($bytes, $pointerToRawData + 4, $guidBytes, 0, 16)
        $guid = New-Object Guid -ArgumentList (,$guidBytes)
        $age = Read-UInt32 -Bytes $bytes -Offset ($pointerToRawData + 20)

        $nameOffset = $pointerToRawData + 24
        $nameEnd = $nameOffset
        while ($nameEnd -lt $bytes.Length -and $bytes[$nameEnd] -ne 0) {
            $nameEnd++
        }
        $pdbPath = [Text.Encoding]::UTF8.GetString($bytes, $nameOffset, $nameEnd - $nameOffset)
        $pdbName = [IO.Path]::GetFileName($pdbPath)
        $symbolId = $guid.ToString("N").ToUpperInvariant() + $age.ToString("x").ToUpperInvariant()

        return [pscustomobject]@{
            ModulePath = $Path
            PdbName    = $pdbName
            SymbolId   = $symbolId
            Url        = "https://msdl.microsoft.com/download/symbols/$pdbName/$symbolId/$pdbName"
        }
    }

    return $null
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path $SymbolCache | Out-Null

$failures = @()
foreach ($module in $Modules) {
    try {
        if (-not (Test-Path -LiteralPath $module)) {
            throw "Module not found: $module"
        }

        $info = Get-PeCodeViewInfo -Path $module
        if (-not $info) {
            throw "No CodeView/RSDS PDB reference found in $module"
        }

        $cacheFile = Join-Path (Join-Path (Join-Path $SymbolCache $info.PdbName) $info.SymbolId) $info.PdbName
        New-Item -ItemType Directory -Force -Path (Split-Path $cacheFile -Parent) | Out-Null
        if (-not (Test-Path -LiteralPath $cacheFile)) {
            Write-Host "Downloading $($info.PdbName) from Microsoft Symbol Server"
            Invoke-WebRequest -Uri $info.Url -OutFile $cacheFile
        } else {
            Write-Host "Using cached $($info.PdbName)"
        }

        if (-not $NoCopy) {
            Copy-Item -LiteralPath $cacheFile -Destination (Join-Path $OutputDir $info.PdbName) -Force
        }

        Write-Host "$($info.PdbName) ready"
    } catch {
        $failures += "${module}: $($_.Exception.Message)"
        Write-Warning $failures[-1]
    }
}

Write-Host ""
Write-Host "Recommended symbol path:"
Write-Host "$OutputDir;srv*$SymbolCache*https://msdl.microsoft.com/download/symbols"

if ($failures) {
    exit 1
}
