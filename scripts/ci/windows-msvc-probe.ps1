param(
    [string]$Architecture = "amd64",
    [string]$QemuCpu = "x86_64",
    [string]$BuildDir = "build-msvc",
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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$logsDir = Join-Path $repoRoot "msvc-probe-logs"
$buildPath = Join-Path $repoRoot $BuildDir

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

Import-VisualStudioEnvironment -Arch $Architecture

Write-Host "MSVC probe environment"
Write-Host "Repository: $repoRoot"
Write-Host "Build dir:  $buildPath"
Write-Host "Arch:       $Architecture"
Write-Host "QEMU CPU:   $QemuCpu"
Write-Host "vcpkg:      $VcpkgTriplet"

where.exe cl | Tee-Object -FilePath (Join-Path $logsDir "where-cl.log")
where.exe link | Tee-Object -FilePath (Join-Path $logsDir "where-link.log")
where.exe bash | Tee-Object -FilePath (Join-Path $logsDir "where-bash.log")

$vcpkg = Find-Vcpkg
$vcpkgRoot = Split-Path $vcpkg -Parent
$env:VCPKG_ROOT = $vcpkgRoot
if ($env:GITHUB_ACTIONS -and -not $env:VCPKG_BINARY_SOURCES) {
    $env:VCPKG_BINARY_SOURCES = "clear;x-gha,readwrite"
}
$vcpkgPackages = @("pkgconf", "glib", "pixman", "libepoxy") | ForEach-Object { "${_}:$VcpkgTriplet" }
$vcpkgArgs = @("install") + $vcpkgPackages + @("--clean-after-build")
Invoke-LoggedCommand -FilePath $vcpkg -Arguments $vcpkgArgs
if ($script:LastCommandExitCode -ne 0) {
    exit $script:LastCommandExitCode
}

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
$probePathBash = @('$PWD', $msvcBinBash, $sdkBinBash, $pkgconfBinBash, $vcpkgBinBash, '$PATH') -join ":"

cl /Bv 2>&1 | Tee-Object -FilePath (Join-Path $logsDir "cl-version.log")
python --version 2>&1 | Tee-Object -FilePath (Join-Path $logsDir "python-version.log")
python -m pip install --upgrade pip meson ninja
$pythonScripts = python -c "import sysconfig; print(sysconfig.get_path('scripts'))"
if ($pythonScripts) {
    $env:PATH = "$pythonScripts;$env:PATH"
}
python -m mesonbuild.mesonmain --version 2>&1 | Tee-Object -FilePath (Join-Path $logsDir "meson-version.log")
ninja --version 2>&1 | Tee-Object -FilePath (Join-Path $logsDir "ninja-version.log")

if (Test-Path $buildPath) {
    Remove-Item -Recurse -Force $buildPath
}
New-Item -ItemType Directory -Force -Path $buildPath | Out-Null

$bash = (Get-Command bash.exe -ErrorAction Stop).Source
$wrapperPy = Join-Path $repoRoot "scripts\ci\msvc-cl-wrapper.py"
$localCompiler = Join-Path $buildPath "msvc-cl.cmd"
@(
    "@echo off",
    "python `"$wrapperPy`" cl.exe %*",
    "exit /b %ERRORLEVEL%"
) | Set-Content -Path $localCompiler -Encoding ASCII

$configureArgs = @(
    "../configure",
    "--cc=msvc-cl.cmd",
    "--cxx=msvc-cl.cmd",
    "--cpu=$QemuCpu",
    "--target-list=i386-softmmu",
    "--without-default-features",
    "--disable-docs",
    "--disable-rust",
    "--disable-tools",
    "--disable-werror",
    "-Doptimization=0",
    "-Db_vscrt=md",
    "-Db_lto=false"
)

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
    Invoke-LoggedCommand -FilePath $bash -Arguments @("-lc", $configureCommand)
    $configureExit = $script:LastCommandExitCode
} finally {
    Pop-Location
}

if (Test-Path (Join-Path $buildPath "config.log")) {
    Copy-Item (Join-Path $buildPath "config.log") (Join-Path $logsDir "config.log") -Force
}

@(
    "configure_exit_code=$configureExit",
    "strict=$Strict"
) | Set-Content -Path (Join-Path $logsDir "status.txt")

if ($configureExit -ne 0) {
    Write-Warning "MSVC configure probe failed with exit code $configureExit. Logs were written to $logsDir."
    if ($Strict) {
        exit $configureExit
    }
}

exit 0
