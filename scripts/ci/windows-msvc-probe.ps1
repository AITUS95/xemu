param(
    [string]$Architecture = "amd64",
    [string]$QemuCpu = "x86_64",
    [string]$BuildDir = "build-msvc",
    [ValidateSet("fast", "core", "full")]
    [string]$BuildScope = "fast",
    [ValidateSet("debug", "profile", "release", "all")]
    [string]$BuildConfig = "profile",
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

function Write-LogSummary {
    param(
        [string]$Path,
        [int]$Tail = 200
    )

    if (-not (Test-Path $Path)) {
        Write-Host "Log not found: $Path"
        return
    }

    $patterns = "FAILED:|error C[0-9]+|fatal error|LINK : fatal|LNK[0-9]+|ninja: build stopped|Traceback|Exception|ERROR:"
    Write-Host "First relevant errors in ${Path}:"
    $matches = Select-String -Path $Path -Pattern $patterns -CaseSensitive:$false | Select-Object -First 80
    if ($matches) {
        $matches | ForEach-Object { Write-Host "$($_.LineNumber): $($_.Line)" }
    } else {
        Write-Host "(none)"
    }

    Write-Host "Last $Tail lines of ${Path}:"
    Get-Content -Path $Path -Tail $Tail
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

function Get-DumpbinDependentNames {
    param(
        [string]$BinaryPath,
        [string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $BinaryPath)) {
        return @()
    }

    $output = & dumpbin.exe /dependents $BinaryPath 2>&1
    Add-Content -Path $LogPath -Value "===== dumpbin /dependents $BinaryPath ====="
    Add-Content -Path $LogPath -Value $output
    Add-Content -Path $LogPath -Value ""

    $output |
        Where-Object { $_ -match "^\s*[^:\s]+\.dll\s*$" } |
        ForEach-Object { $_.Trim() } |
        Sort-Object -Unique
}

function Resolve-DependencyDll {
    param(
        [string]$Name,
        [string[]]$SearchDirs
    )

    foreach ($dir in $SearchDirs) {
        if (-not $dir -or -not (Test-Path $dir)) {
            continue
        }
        $candidate = Join-Path $dir $Name
        if (Test-Path $candidate) {
            return (Get-Item $candidate)
        }
    }

    return $null
}

function Copy-RuntimeDllArtifacts {
    param(
        [System.IO.FileInfo]$Executable,
        [string[]]$SearchDirs,
        [string]$Destination,
        [string]$DependentsLog
    )

    if (-not $Executable) {
        return @()
    }

    $copied = @{}
    $queue = New-Object System.Collections.Generic.Queue[string]
    Get-DumpbinDependentNames -BinaryPath $Executable.FullName -LogPath $DependentsLog |
        ForEach-Object { $queue.Enqueue($_) }

    while ($queue.Count -gt 0) {
        $name = $queue.Dequeue()
        if ($copied.ContainsKey($name.ToLowerInvariant())) {
            continue
        }

        $dll = Resolve-DependencyDll -Name $name -SearchDirs $SearchDirs
        if (-not $dll) {
            Add-Content -Path $DependentsLog -Value "not packaged (system or missing): $name"
            continue
        }

        Copy-Item -LiteralPath $dll.FullName -Destination $Destination -Force
        $copied[$name.ToLowerInvariant()] = $dll.FullName

        Get-DumpbinDependentNames -BinaryPath $dll.FullName -LogPath $DependentsLog |
            ForEach-Object {
                if (-not $copied.ContainsKey($_.ToLowerInvariant())) {
                    $queue.Enqueue($_)
                }
            }
    }

    return $copied.Values
}

function Copy-MsvcPackage {
    param(
        [string]$ConfigName,
        [System.IO.FileInfo]$Executable,
        [System.IO.FileInfo]$Pdb,
        [string[]]$DependencyDirs,
        [string]$ArtifactsRoot,
        [string]$DependentsLog,
        [string]$LayoutLog,
        [bool]$IncludePdb
    )

    if (-not $Executable) {
        return $null
    }

    $destination = Join-Path $ArtifactsRoot $ConfigName
    if (Test-Path $destination) {
        Remove-Item -Recurse -Force $destination
    }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null

    Copy-Item -LiteralPath $Executable.FullName -Destination (Join-Path $destination "xemu.exe") -Force
    if ($IncludePdb -and $Pdb) {
        Copy-Item -LiteralPath $Pdb.FullName -Destination (Join-Path $destination "xemu.pdb") -Force
    }

    Copy-RuntimeDllArtifacts `
        -Executable (Get-Item (Join-Path $destination "xemu.exe")) `
        -SearchDirs (@($Executable.DirectoryName) + $DependencyDirs) `
        -Destination $destination `
        -DependentsLog $DependentsLog | Out-Null

    Add-Content -Path $LayoutLog -Value "===== $ConfigName ====="
    Get-ChildItem -Path $destination -Recurse -File |
        Sort-Object FullName |
        ForEach-Object { Add-Content -Path $LayoutLog -Value $_.FullName }

    return $destination
}

function Invoke-RuntimeSmokeTest {
    param(
        [string]$ConfigName,
        [string]$PackageDir,
        [string]$LogsDir
    )

    $smokeLog = Join-Path $LogsDir "runtime-smoke.log"
    $xemuLogDestination = Join-Path $LogsDir "xemu.log"
    Add-Content -Path $smokeLog -Value "===== runtime smoke: $ConfigName ====="

    if (-not $PackageDir) {
        Add-Content -Path $smokeLog -Value "not_run: package directory missing"
        return "not_run"
    }

    $exe = Join-Path $PackageDir "xemu.exe"
    if (-not (Test-Path $exe)) {
        Add-Content -Path $smokeLog -Value "failed: xemu.exe missing"
        return "failed"
    }

    $localXemuLog = Join-Path $PackageDir "xemu.log"
    Remove-Item -Force -ErrorAction SilentlyContinue $localXemuLog

    try {
        $proc = Start-Process -FilePath $exe -ArgumentList "--version" `
            -WorkingDirectory $PackageDir `
            -PassThru -WindowStyle Hidden
        try {
            Wait-Process -Id $proc.Id -Timeout 10 -ErrorAction Stop
            Add-Content -Path $smokeLog -Value "exit_code=$($proc.ExitCode)"
            if ($proc.ExitCode -ne 0) {
                $result = "failed"
            } else {
                $result = "passed"
            }
        } catch {
            if (-not $proc.HasExited) {
                $proc.Kill()
                Add-Content -Path $smokeLog -Value "timeout=10s killed=true"
                $result = "timeout"
            } else {
                Add-Content -Path $smokeLog -Value "exit_code=$($proc.ExitCode)"
                $result = if ($proc.ExitCode -eq 0) { "passed" } else { "failed" }
            }
        }
    } catch {
        Add-Content -Path $smokeLog -Value "failed_to_start=$($_.Exception.Message)"
        $result = "failed"
    }

    if (Test-Path $localXemuLog) {
        Copy-Item -LiteralPath $localXemuLog -Destination $xemuLogDestination -Force
        $logText = Get-Content -Raw $localXemuLog
        if ($logText -match "la_bb_end: code should not be reached") {
            Add-Content -Path $smokeLog -Value "la_bb_end=found"
            $result = "la_bb_end"
        } else {
            Add-Content -Path $smokeLog -Value "la_bb_end=absent"
        }
    } else {
        Add-Content -Path $smokeLog -Value "xemu_log=not_found"
    }

    return $result
}

$script:PhaseStart = @{}
$script:PhaseEvents = @()
$script:PhaseLog = $null
Start-Phase "probe"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$logsDir = Join-Path $repoRoot "msvc-probe-logs"
$artifactsRoot = Join-Path $repoRoot "msvc-native-artifacts"
$buildPath = Join-Path $repoRoot $BuildDir
$wrapperLog = Join-Path $logsDir "msvc-cl-wrapper.log"
$finalExecutable = $null
$finalPdb = $null
$pdbReferenceCheck = "not_run"
$cv2pdbCheck = "not_run"
$runtimeSmokeCheck = "not_run"
$packagedArtifact = "not_run"

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $wrapperLog
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $artifactsRoot
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null
$script:PhaseLog = Join-Path $logsDir "phase-timings.log"
$script:PhaseEvents | Set-Content -Path $script:PhaseLog

Start-Phase "toolchain setup"
Import-VisualStudioEnvironment -Arch $Architecture

Write-Host "Windows MSVC native build environment"
Write-Host "Repository: $repoRoot"
Write-Host "Build dir:  $buildPath"
Write-Host "Arch:       $Architecture"
Write-Host "QEMU CPU:   $QemuCpu"
Write-Host "Scope:      $BuildScope"
Write-Host "Config:     $BuildConfig"
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
$mesonOptimization = if ($BuildConfig -eq "debug") { "0" } else { "2" }

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
    "--extra-cflags=-DXBOX=1",
    "--extra-cxxflags=-DXBOX=1",
    "-Doptimization=$mesonOptimization",
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
$configureLine += " > ../msvc-probe-logs/configure-output.log 2>&1"

$configureCommand = @(
    "set -o pipefail",
    "export AR=lib",
    "export LD=link",
    "export NM=dumpbin",
    "export WINDRES=rc",
    "export DLLTOOL=:",
    "export RANLIB=:",
    "export STRIP=:",
    "export MSVC_CL_WRAPPER_TRACE=link",
    "export MSVC_CL_WRAPPER_BUILD_CONFIG=`"${BuildConfig}`"",
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
    if ($configureExit -ne 0) {
        Write-LogSummary -Path (Join-Path $logsDir "configure-output.log") -Tail 150
    } else {
        Write-Host "Configure exit code: $configureExit"
    }
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
            if ($BuildScope -in @("fast", "core")) {
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
            } else {
                $emulatorTarget = $null
                foreach ($name in @("xemu", "qemu-system-i386w", "qemu-system-i386")) {
                    $emulatorTarget = @($targets | Where-Object {
                        $_.name -eq $name -or $_.id -eq $name
                    } | Select-Object -First 1)
                    if ($emulatorTarget) {
                        break
                    }
                }

                if ($emulatorTarget) {
                    if ($emulatorTarget.name) {
                        $compileTarget = $emulatorTarget.name
                    } elseif ($emulatorTarget.id) {
                        $compileTarget = $emulatorTarget.id
                    } else {
                        Write-Warning "Found final emulator target, but Meson introspection did not include a target name or id."
                        $buildExit = 1
                    }
                } else {
                    Write-Warning "Could not find xemu/qemu-system-i386 target in Meson introspection output."
                    $buildExit = 1
                }
            }
        }
    } finally {
        End-Phase "meson introspect"
        Pop-Location
    }

    if ($null -eq $buildExit -or $buildExit -eq 0) {
        $compileLine = "echo Windows MSVC native ${BuildScope}/${BuildConfig} target: ${compileTarget}; python -m mesonbuild.mesonmain compile -C . `"${compileTarget}`" --verbose > ../msvc-probe-logs/build-output.log 2>&1"

        $buildCommand = @(
            "set -o pipefail",
            "export AR=lib",
            "export LD=link",
            "export NM=dumpbin",
            "export WINDRES=rc",
            "export DLLTOOL=:",
            "export RANLIB=:",
            "export STRIP=:",
            "export MSVC_CL_WRAPPER_TRACE=link",
            "export MSVC_CL_WRAPPER_BUILD_CONFIG=`"${BuildConfig}`"",
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
            Write-Host "Build exit code: $buildExit"
            Write-LogSummary -Path (Join-Path $logsDir "build-output.log") -Tail 200
        } finally {
            End-Phase "meson compile $BuildScope"
            Pop-Location
        }
    }
}

if ($configureExit -eq 0 -and $BuildScope -eq "full" -and $buildExit -eq 0) {
    Start-Phase "full validation"
    try {
        $requiresPdb = $BuildConfig -ne "release"
        $finalExecutable = Find-FinalExecutable -Root $buildPath
        if (-not $finalExecutable) {
            Write-Warning "FAIL: xemu/qemu-system-i386 executable was not found."
            Get-ChildItem -Path $buildPath -Recurse -File -Filter "*.exe" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName |
                Set-Content -Path (Join-Path $logsDir "exe-files.txt")
            $buildExit = 1
        } else {
            Write-Host "Binary found: $($finalExecutable.FullName)"

            if ($requiresPdb) {
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
            } else {
                $pdbReferenceCheck = "not_required_release"
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

Start-Phase "artifact packaging"
if (Test-Path (Join-Path $buildPath "config.log")) {
    Copy-Item (Join-Path $buildPath "config.log") (Join-Path $logsDir "config.log") -Force
}
if (Test-Path (Join-Path $buildPath "meson-logs\meson-log.txt")) {
    Copy-Item (Join-Path $buildPath "meson-logs\meson-log.txt") (Join-Path $logsDir "meson-log.txt") -Force
}
$dependentsLog = Join-Path $logsDir "dependents.log"
$layoutLog = Join-Path $logsDir "artifact-layout.log"
$runtimeSmokeLog = Join-Path $logsDir "runtime-smoke.log"
if (-not (Test-Path $dependentsLog)) { "not_run" | Set-Content -Path $dependentsLog }
if (-not (Test-Path $layoutLog)) { "not_run" | Set-Content -Path $layoutLog }
if (-not (Test-Path $runtimeSmokeLog)) { "not_run" | Set-Content -Path $runtimeSmokeLog }

if ($BuildScope -eq "full" -and $buildExit -eq 0 -and $finalExecutable) {
    "" | Set-Content -Path $dependentsLog
    "" | Set-Content -Path $layoutLog
    $artifactConfigName = switch ($BuildConfig) {
        "release" { "release" }
        "debug" { "debug" }
        default { "profile" }
    }
    $includePdb = $BuildConfig -ne "release"
    $packagedArtifact = Copy-MsvcPackage `
        -ConfigName $artifactConfigName `
        -Executable $finalExecutable `
        -Pdb $finalPdb `
        -DependencyDirs @($vcpkgBin) `
        -ArtifactsRoot $artifactsRoot `
        -DependentsLog $dependentsLog `
        -LayoutLog $layoutLog `
        -IncludePdb:$includePdb
}
End-Phase "artifact packaging"

if ($BuildScope -eq "full" -and $buildExit -eq 0 -and $packagedArtifact -ne "not_run") {
    Start-Phase "runtime smoke test"
    try {
        $runtimeSmokeCheck = Invoke-RuntimeSmokeTest `
            -ConfigName $BuildConfig `
            -PackageDir $packagedArtifact `
            -LogsDir $logsDir
        if ($runtimeSmokeCheck -in @("failed", "la_bb_end")) {
            Write-Warning "FAIL: runtime smoke test result: $runtimeSmokeCheck"
            $buildExit = 1
        } elseif ($runtimeSmokeCheck -eq "timeout") {
            Write-Warning "WARN: runtime smoke test timed out; GUI subsystem may keep running."
        } else {
            Write-Host "Runtime smoke test result: $runtimeSmokeCheck"
        }
    } finally {
        End-Phase "runtime smoke test"
    }
}

@(
    "configure_exit_code=$configureExit",
    "build_exit_code=$(if ($null -eq $buildExit) { 'not_run' } else { $buildExit })",
    "build_scope=$BuildScope",
    "build_config=$BuildConfig",
    "strict=$Strict",
    "xemu_exe=$(if ($finalExecutable) { $finalExecutable.FullName } else { 'not_found' })",
    "xemu_pdb=$(if ($finalPdb) { $finalPdb.FullName } else { 'not_found' })",
    "pdb_reference_check=$pdbReferenceCheck",
    "cv2pdb_check=$cv2pdbCheck",
    "runtime_smoke_check=$runtimeSmokeCheck",
    "packaged_artifact=$packagedArtifact"
) | Set-Content -Path (Join-Path $logsDir "status.txt")

Write-Host "Status summary:"
Get-Content -Path (Join-Path $logsDir "status.txt")
Write-Host "Phase timings:"
Get-Content -Path $script:PhaseLog

if ($configureExit -ne 0) {
    Write-Warning "Windows MSVC native configure failed with exit code $configureExit. Logs were written to $logsDir."
    if ($Strict) {
        End-Phase "probe"
        exit $configureExit
    }
}
if ($null -ne $buildExit -and $buildExit -ne 0) {
    Write-Warning "Windows MSVC native build failed with exit code $buildExit. Logs were written to $logsDir."
    if ($Strict) {
        End-Phase "probe"
        exit $buildExit
    }
}

End-Phase "probe"
exit 0
