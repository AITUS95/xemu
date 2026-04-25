param(
    [string]$Architecture = "amd64",
    [string]$QemuCpu = "x86_64",
    [string]$BuildDir = "build-msvc",
    [ValidateSet("fast", "full")]
    [string]$BuildScope = "fast",
    [string]$VcpkgTriplet = "x64-windows",
    [string]$ExtraConfigureArgs = "",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

function Import-VisualStudioEnvironment {
    param([string]$Arch)

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found"
    }

    $installPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $installPath) {
        throw "Visual Studio with MSVC tools was not found"
    }

    $vcvars = Join-Path $installPath "VC\Auxiliary\Build\vcvarsall.bat"
    if (-not (Test-Path $vcvars)) {
        throw "vcvarsall.bat not found at $vcvars"
    }

    $environment = & cmd.exe /s /c "`"$vcvars`" $Arch >nul && set"
    foreach ($line in $environment) {
        if ($line -match "^([^=]+)=(.*)$") {
            Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
        }
    }
}

function ConvertTo-GitBashPath {
    param([string]$WindowsPath)

    $fullPath = (Resolve-Path $WindowsPath).Path
    $drive = $fullPath.Substring(0, 1).ToLowerInvariant()
    $path = $fullPath.Substring(2).Replace("\", "/")
    return "/$drive$path"
}

function ConvertTo-WindowsSlashPath {
    param([string]$WindowsPath)

    return (Resolve-Path $WindowsPath).Path.Replace("\", "/")
}

function Find-Vcpkg {
    $candidates = @(
        $env:VCPKG_INSTALLATION_ROOT,
        "C:\vcpkg"
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        $vcpkg = Join-Path $candidate "vcpkg.exe"
        if (Test-Path $vcpkg) {
            return $vcpkg
        }
    }

    throw "vcpkg.exe was not found"
}

function Invoke-LoggedCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    Write-Host ">> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    $script:LastCommandExitCode = $LASTEXITCODE
}

function Log-Phase {
    param([string]$Message)

    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$now] $Message"
    Write-Host $line
    $script:PhaseEvents += $line
    if ($script:PhaseLog) {
        Add-Content -Path $script:PhaseLog -Value $line
    }
}

function Start-Phase {
    param([string]$Name)

    $script:PhaseStart[$Name] = Get-Date
    Log-Phase "BEGIN $Name"
}

function End-Phase {
    param([string]$Name)

    if ($script:PhaseStart.ContainsKey($Name)) {
        $elapsed = (Get-Date) - $script:PhaseStart[$Name]
        Log-Phase ("END {0} duration={1:n1}s" -f $Name, $elapsed.TotalSeconds)
    } else {
        Log-Phase "END $Name"
    }
}

function Find-FinalExecutable {
    param([string]$Root)

    foreach ($name in @("xemu.exe", "qemu-system-i386w.exe", "qemu-system-i386.exe")) {
        $match = Get-ChildItem -Path $Root -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($match) {
            return $match
        }
    }

    return $null
}

function Copy-ProbeArtifact {
    param(
        [System.IO.FileInfo]$File,
        [string]$Destination
    )

    if ($File -and (Test-Path -LiteralPath $File.FullName)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        Copy-Item -LiteralPath $File.FullName -Destination $Destination -Force
    }
}

function Copy-DllArtifacts {
    param(
        [System.IO.FileInfo]$Executable,
        [string]$DependencyBin,
        [string]$Destination
    )

    if (-not $Executable) {
        return
    }

    $dllDestination = Join-Path $Destination "dlls"
    New-Item -ItemType Directory -Force -Path $dllDestination | Out-Null

    $exeDir = Split-Path $Executable.FullName -Parent
    Get-ChildItem -Path $exeDir -File -Filter "*.dll" -ErrorAction SilentlyContinue |
        Copy-Item -Destination $dllDestination -Force

    if (Test-Path $DependencyBin) {
        Get-ChildItem -Path $DependencyBin -File -Filter "*.dll" -ErrorAction SilentlyContinue |
            Copy-Item -Destination $dllDestination -Force
    }
}

$script:PhaseStart = @{}
$script:PhaseEvents = @()
$script:PhaseLog = $null
Start-Phase "probe"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$logsDir = Join-Path $repoRoot "msvc-probe-logs"
$artifactsDir = Join-Path $repoRoot "msvc-probe-artifacts"
$buildPath = Join-Path $repoRoot $BuildDir
$wrapperLog = Join-Path $logsDir "msvc-cl-wrapper.log"
$finalExecutable = $null
$finalPdb = $null
$pdbReferenceCheck = "not_run"
$cv2pdbCheck = "not_run"

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
New-Item -ItemType Directory -Force -Path $artifactsDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $wrapperLog
$script:PhaseLog = Join-Path $logsDir "phase-timings.log"
$script:PhaseEvents | Set-Content -Path $script:PhaseLog

Start-Phase "toolchain setup"
Import-VisualStudioEnvironment -Arch $Architecture

Write-Host "MSVC probe environment"
Write-Host "Repository: $repoRoot"
Write-Host "Build dir:  $buildPath"
Write-Host "Arch:       $Architecture"
Write-Host "QEMU CPU:   $QemuCpu"
Write-Host "Scope:      $BuildScope"
Write-Host "vcpkg:      $VcpkgTriplet"

where.exe cl | Tee-Object -FilePath (Join-Path $logsDir "where-cl.log")
where.exe clang-cl 2>&1 | Tee-Object -FilePath (Join-Path $logsDir "where-clang-cl.log")
where.exe link | Tee-Object -FilePath (Join-Path $logsDir "where-link.log")
where.exe bash | Tee-Object -FilePath (Join-Path $logsDir "where-bash.log")
$compilerCommand = "cl.exe"
if (Get-Command clang-cl.exe -ErrorAction SilentlyContinue) {
    $compilerCommand = "clang-cl.exe"
}
Write-Host "Compiler:   $compilerCommand"
End-Phase "toolchain setup"

Start-Phase "vcpkg dependency install"
$vcpkg = Find-Vcpkg
$vcpkgRoot = Split-Path $vcpkg -Parent
$env:VCPKG_ROOT = $vcpkgRoot
if ($env:GITHUB_ACTIONS -and -not $env:VCPKG_BINARY_SOURCES) {
    $binarySources = @("clear")
    if ($env:VCPKG_DEFAULT_BINARY_CACHE) {
        New-Item -ItemType Directory -Force -Path $env:VCPKG_DEFAULT_BINARY_CACHE | Out-Null
        $binarySources += "files,$env:VCPKG_DEFAULT_BINARY_CACHE,readwrite"
    }
    $env:VCPKG_BINARY_SOURCES = $binarySources -join ";"
}
$vcpkgPackageNames = @("pkgconf", "glib", "pixman", "libepoxy", "libsamplerate")
$vcpkgPackages = $vcpkgPackageNames | ForEach-Object { "${_}:$VcpkgTriplet" }
$vcpkgArgs = @("install") + $vcpkgPackages + @("--clean-after-build")
Invoke-LoggedCommand -FilePath $vcpkg -Arguments $vcpkgArgs
if ($script:LastCommandExitCode -ne 0) {
    exit $script:LastCommandExitCode
}
End-Phase "vcpkg dependency install"

$vcpkgInstalled = Join-Path $vcpkgRoot "installed\$VcpkgTriplet"
$vcpkgBin = Join-Path $vcpkgInstalled "bin"
$pkgconfBin = Join-Path $vcpkgInstalled "tools\pkgconf"
$pkgConfig = Join-Path $pkgconfBin "pkgconf.exe"
$pkgConfigDirs = @(
    (Join-Path $vcpkgInstalled "lib\pkgconfig"),
    (Join-Path $vcpkgInstalled "share\pkgconfig")
) | Where-Object { Test-Path $_ }
if (-not (Test-Path $pkgConfig)) {
    throw "pkgconf.exe not found at $pkgConfig"
}
if (-not $pkgConfigDirs) {
    throw "No vcpkg pkg-config directories were found under $vcpkgInstalled"
}

$env:PATH = "$pkgconfBin;$vcpkgBin;$env:PATH"
$env:PKG_CONFIG = $pkgConfig
$env:PKG_CONFIG_LIBDIR = $pkgConfigDirs -join ";"
$env:PKG_CONFIG_PATH = $env:PKG_CONFIG_LIBDIR

$msvcBin = Split-Path (Get-Command cl.exe -ErrorAction Stop).Source -Parent
$sdkBin = Split-Path (Get-Command rc.exe -ErrorAction Stop).Source -Parent
$msvcBinBash = ConvertTo-GitBashPath $msvcBin
$sdkBinBash = ConvertTo-GitBashPath $sdkBin
$vcpkgBinBash = ConvertTo-GitBashPath $vcpkgBin
$pkgconfBinBash = ConvertTo-GitBashPath $pkgconfBin
$pkgConfigMeson = ConvertTo-WindowsSlashPath $pkgConfig
$pkgConfigLibdirMeson = ($pkgConfigDirs | ForEach-Object { ConvertTo-WindowsSlashPath $_ }) -join ";"
$repoRootMeson = ConvertTo-WindowsSlashPath $repoRoot
$wrapperLogMeson = $wrapperLog.Replace("\", "/")
$probePathBash = @('$PWD', $msvcBinBash, $sdkBinBash, $pkgconfBinBash, $vcpkgBinBash, '$PATH') -join ":"

Start-Phase "python and meson tool setup"
cl /Bv 2>&1 | Tee-Object -FilePath (Join-Path $logsDir "cl-version.log")
python --version 2>&1 | Tee-Object -FilePath (Join-Path $logsDir "python-version.log")
python -m pip install --upgrade pip meson ninja
$pythonScripts = python -c "import sysconfig; print(sysconfig.get_path('scripts'))"
if ($pythonScripts) {
    $env:PATH = "$pythonScripts;$env:PATH"
}
python -m mesonbuild.mesonmain --version 2>&1 | Tee-Object -FilePath (Join-Path $logsDir "meson-version.log")
ninja --version 2>&1 | Tee-Object -FilePath (Join-Path $logsDir "ninja-version.log")
End-Phase "python and meson tool setup"

if (Test-Path $buildPath) {
    Remove-Item -Recurse -Force $buildPath
}
New-Item -ItemType Directory -Force -Path $buildPath | Out-Null

$bash = (Get-Command bash.exe -ErrorAction Stop).Source
$wrapperPy = Join-Path $repoRoot "scripts\ci\msvc-cl-wrapper.py"
$localCompiler = Join-Path $buildPath "msvc-cl.cmd"
@(
    "@echo off",
    "python `"$wrapperPy`" $compilerCommand %*",
    "exit /b %ERRORLEVEL%"
) | Set-Content -Path $localCompiler -Encoding ASCII
$localCompilerMeson = ConvertTo-WindowsSlashPath $localCompiler

$configureArgs = @(
    "../configure",
    "--cc=$localCompilerMeson",
    "--cxx=$localCompilerMeson",
    "--cpu=$QemuCpu",
    "--target-list=i386-softmmu",
    "--without-default-features",
    "--disable-docs",
    "--disable-rust",
    "--disable-tools",
    "--disable-werror",
    "-Doptimization=0",
    "-Db_vscrt=md",
    "-Db_lto=false",
    "-Dslirp=disabled",
    "-Dslirp_smbd=disabled"
)

if ($BuildScope -eq "fast") {
    $configureArgs += @(
        "-Dsdl=disabled",
        "-Dopengl=disabled"
    )
}

$configureLine = $configureArgs -join " "
if ($ExtraConfigureArgs) {
    $configureLine += " $ExtraConfigureArgs"
}
$configureLine += " 2>&1 | tee ../msvc-probe-logs/configure-output.log"

$configureCommand = @(
    "set -o pipefail",
    "export AR=lib",
    "export LD=link",
    "export NM=dumpbin",
    "export WINDRES=rc",
    "export DLLTOOL=:",
    "export RANLIB=:",
    "export STRIP=:",
    "export MSVC_CL_WRAPPER_TRACE=1",
    "export MSVC_CL_WRAPPER_LOG=`"${wrapperLogMeson}`"",
    "export PATH=`"${probePathBash}`"",
    "export PKG_CONFIG=`"${pkgConfigMeson}`"",
    "export PKG_CONFIG_LIBDIR=`"${pkgConfigLibdirMeson}`"",
    "export PKG_CONFIG_PATH=`"${pkgConfigLibdirMeson}`"",
    "command -v cl",
    "command -v link",
    "command -v pkgconf",
    "command -v msvc-cl.cmd",
    $configureLine
) -join "; "

Push-Location $buildPath
try {
    Start-Phase "meson setup"
    Invoke-LoggedCommand -FilePath $bash -Arguments @("-lc", $configureCommand)
    $configureExit = $script:LastCommandExitCode
} finally {
    End-Phase "meson setup"
    Pop-Location
}

$buildExit = $null
if ($configureExit -eq 0) {
    Start-Phase "PyYAML install"
    $buildPythonCandidates = @(
        (Join-Path $buildPath "pyvenv\Scripts\python.exe"),
        (Join-Path $buildPath "pyvenv\Scripts\python3.exe")
    )
    $buildPython = $buildPythonCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $buildPython) {
        Write-Warning "Meson Python venv was not found under $buildPath\pyvenv."
        $buildExit = 1
    } else {
        Invoke-LoggedCommand -FilePath $buildPython -Arguments @("-m", "pip", "install", "pyyaml")
        if ($script:LastCommandExitCode -ne 0) {
            $buildExit = $script:LastCommandExitCode
        } else {
            Invoke-LoggedCommand -FilePath $buildPython -Arguments @("-c", "import yaml; print(yaml.__version__)")
            if ($script:LastCommandExitCode -ne 0) {
                $buildExit = $script:LastCommandExitCode
            }
        }
    }
    End-Phase "PyYAML install"
}

if ($configureExit -eq 0 -and ($null -eq $buildExit -or $buildExit -eq 0)) {
    $xemuVersionCommand = @(
        "set -o pipefail",
        "cat ../scripts/xemu-version.sh",
        "bash -n ../scripts/xemu-version.sh",
        "sh -n ../scripts/xemu-version.sh",
        "sh -x ../scripts/xemu-version.sh `"${repoRootMeson}`" 2>&1 | tee ../msvc-probe-logs/xemu-version-diagnostics.log; xemu_version_exit=`${PIPESTATUS[0]}; echo xemu_version_exit=`$xemu_version_exit; test `$xemu_version_exit -eq 0"
    ) -join "; "

    Push-Location $buildPath
    try {
        Start-Phase "xemu-version diagnostics"
        Invoke-LoggedCommand -FilePath $bash -Arguments @("-lc", $xemuVersionCommand)
        if ($script:LastCommandExitCode -ne 0) {
            $buildExit = $script:LastCommandExitCode
        }
    } finally {
        End-Phase "xemu-version diagnostics"
        Pop-Location
    }
}

if ($configureExit -eq 0 -and ($null -eq $buildExit -or $buildExit -eq 0)) {
    $compileTarget = ""
    if ($BuildScope -eq "fast") {
        $targetsLog = Join-Path $logsDir "meson-targets.json"
        Push-Location $buildPath
        try {
            Start-Phase "meson introspect"
            & $buildPython -m mesonbuild.mesonmain introspect . --targets 2>&1 |
                Tee-Object -FilePath $targetsLog
            if ($LASTEXITCODE -ne 0) {
                $buildExit = $LASTEXITCODE
            } else {
                $targets = Get-Content -Raw $targetsLog | ConvertFrom-Json
                $qemuUtilTarget = @($targets | Where-Object {
                    $_.name -eq "qemuutil" -or
                    $_.id -match "qemuutil" -or
                    ((@($_.filename) -join "`n") -match "libqemuutil\.a")
                } | Select-Object -First 1)
                if ($qemuUtilTarget) {
                    if ($qemuUtilTarget.name) {
                        $compileTarget = $qemuUtilTarget.name
                    } elseif ($qemuUtilTarget.id) {
                        $compileTarget = $qemuUtilTarget.id
                    } else {
                        Write-Warning "Found qemuutil/libqemuutil target, but Meson introspection did not include a target name or id."
                        $buildExit = 1
                    }
                } else {
                    Write-Warning "Could not find qemuutil/libqemuutil target in Meson introspection output."
                    $buildExit = 1
                }
            }
        } finally {
            End-Phase "meson introspect"
            Pop-Location
        }
    }

    if ($null -eq $buildExit -or $buildExit -eq 0) {
        if ($BuildScope -eq "fast") {
            $compileLine = "echo Fast MSVC probe target: ${compileTarget}; python -m mesonbuild.mesonmain compile -C . `"${compileTarget}`" --verbose 2>&1 | tee ../msvc-probe-logs/build-output.log"
        } else {
            $compileLine = "echo Full MSVC probe build; python -m mesonbuild.mesonmain compile -C . --verbose 2>&1 | tee ../msvc-probe-logs/build-output.log"
        }

        $buildCommand = @(
            "set -o pipefail",
            "export AR=lib",
            "export LD=link",
            "export NM=dumpbin",
            "export WINDRES=rc",
            "export DLLTOOL=:",
            "export RANLIB=:",
            "export STRIP=:",
            "export MSVC_CL_WRAPPER_TRACE=1",
            "export MSVC_CL_WRAPPER_LOG=`"${wrapperLogMeson}`"",
            "export PATH=`"${probePathBash}`"",
            "export PKG_CONFIG=`"${pkgConfigMeson}`"",
            "export PKG_CONFIG_LIBDIR=`"${pkgConfigLibdirMeson}`"",
            "export PKG_CONFIG_PATH=`"${pkgConfigLibdirMeson}`"",
            $compileLine
        ) -join "; "

        Push-Location $buildPath
        try {
            Start-Phase "meson compile $BuildScope"
            Invoke-LoggedCommand -FilePath $bash -Arguments @("-lc", $buildCommand)
            $buildExit = $script:LastCommandExitCode
        } finally {
            End-Phase "meson compile $BuildScope"
            Pop-Location
        }
    }
}

if ($configureExit -eq 0 -and $BuildScope -eq "full" -and $buildExit -eq 0) {
    Start-Phase "full validation"
    try {
        $finalExecutable = Find-FinalExecutable -Root $buildPath
        if (-not $finalExecutable) {
            Write-Warning "FAIL: xemu/qemu-system-i386 executable was not found."
            Get-ChildItem -Path $buildPath -Recurse -File -Filter "*.exe" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName |
                Set-Content -Path (Join-Path $logsDir "exe-files.txt")
            $buildExit = 1
        } else {
            Write-Host "Binary found: $($finalExecutable.FullName)"

            $matchingPdb = Join-Path $finalExecutable.DirectoryName "$($finalExecutable.BaseName).pdb"
            if (Test-Path $matchingPdb) {
                $finalPdb = Get-Item $matchingPdb
            } else {
                Write-Warning "Matching PDB was not found next to the binary: $matchingPdb"
                Get-ChildItem -Path $buildPath -Recurse -File -Filter "*.pdb" -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName |
                    Set-Content -Path (Join-Path $logsDir "pdb-files.txt")

                $fallbackPdb = Join-Path $buildPath "xemu.pdb"
                if (Test-Path $fallbackPdb) {
                    $finalPdb = Get-Item $fallbackPdb
                } else {
                    Write-Warning "FAIL: final PDB was not found."
                    $buildExit = 1
                }
            }

            if ($finalPdb) {
                Write-Host "PDB found: $($finalPdb.FullName)"
            }

            $dumpbinOutput = & dumpbin.exe /headers $finalExecutable.FullName 2>&1
            $dumpbinOutput | Set-Content -Path (Join-Path $logsDir "dumpbin-headers.txt")
            $dumpbinExit = $LASTEXITCODE
            if ($dumpbinExit -ne 0 -or -not ($dumpbinOutput | Select-String -Pattern "RSDS|PDB" -CaseSensitive:$false)) {
                Write-Warning "FAIL: no CodeView/RSDS/PDB reference was found in the binary."
                $pdbReferenceCheck = "failed"
                $buildExit = 1
            } else {
                Write-Host "OK: CodeView/RSDS/PDB reference found in binary."
                $pdbReferenceCheck = "passed"
            }
        }

        $buildNinja = Join-Path $buildPath "build.ninja"
        if (Test-Path $buildNinja) {
            $cv2pdbMatches = Select-String -Path $buildNinja -Pattern "cv2pdb" -CaseSensitive:$false
            if ($cv2pdbMatches) {
                Write-Warning "FAIL: cv2pdb was found in the MSVC build system."
                $cv2pdbMatches |
                    ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line)" } |
                    Set-Content -Path (Join-Path $logsDir "cv2pdb-matches.txt")
                $cv2pdbCheck = "found"
                $buildExit = 1
            } else {
                Write-Host "OK: cv2pdb not present in the MSVC build system."
                $cv2pdbCheck = "absent"
            }
        } else {
            Write-Warning "FAIL: build.ninja was not found for cv2pdb validation."
            $cv2pdbCheck = "missing_build_ninja"
            $buildExit = 1
        }
    } finally {
        End-Phase "full validation"
    }
}

Start-Phase "artifact collection"
if (Test-Path (Join-Path $buildPath "config.log")) {
    Copy-Item (Join-Path $buildPath "config.log") (Join-Path $logsDir "config.log") -Force
}
if (Test-Path (Join-Path $buildPath "meson-logs\meson-log.txt")) {
    Copy-Item (Join-Path $buildPath "meson-logs\meson-log.txt") (Join-Path $logsDir "meson-log.txt") -Force
}
if ($BuildScope -eq "full") {
    Copy-ProbeArtifact -File $finalExecutable -Destination $artifactsDir
    Copy-ProbeArtifact -File $finalPdb -Destination $artifactsDir
    Copy-DllArtifacts -Executable $finalExecutable -DependencyBin $vcpkgBin -Destination $artifactsDir
}

@(
    "configure_exit_code=$configureExit",
    "build_exit_code=$(if ($null -eq $buildExit) { 'not_run' } else { $buildExit })",
    "build_scope=$BuildScope",
    "strict=$Strict",
    "xemu_exe=$(if ($finalExecutable) { $finalExecutable.FullName } else { 'not_found' })",
    "xemu_pdb=$(if ($finalPdb) { $finalPdb.FullName } else { 'not_found' })",
    "pdb_reference_check=$pdbReferenceCheck",
    "cv2pdb_check=$cv2pdbCheck"
) | Set-Content -Path (Join-Path $logsDir "status.txt")
End-Phase "artifact collection"

if ($configureExit -ne 0) {
    Write-Warning "MSVC configure probe failed with exit code $configureExit. Logs were written to $logsDir."
    if ($Strict) {
        End-Phase "probe"
        exit $configureExit
    }
}
if ($null -ne $buildExit -and $buildExit -ne 0) {
    Write-Warning "MSVC build probe failed with exit code $buildExit. Logs were written to $logsDir."
    if ($Strict) {
        End-Phase "probe"
        exit $buildExit
    }
}

End-Phase "probe"
exit 0
