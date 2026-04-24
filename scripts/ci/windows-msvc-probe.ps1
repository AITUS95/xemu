param(
    [string]$Architecture = "amd64",
    [string]$QemuCpu = "x86_64",
    [string]$BuildDir = "build-msvc",
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

where.exe cl | Tee-Object -FilePath (Join-Path $logsDir "where-cl.log")
where.exe link | Tee-Object -FilePath (Join-Path $logsDir "where-link.log")
where.exe bash | Tee-Object -FilePath (Join-Path $logsDir "where-bash.log")

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

$configureArgs = @(
    "../configure",
    "--cc=../scripts/ci/msvc-cl.cmd",
    "--cxx=../scripts/ci/msvc-cl.cmd",
    "--cpu=$QemuCpu",
    "--target-list=i386-softmmu",
    "--without-default-features",
    "--disable-docs",
    "--disable-rust",
    "--disable-tools",
    "--disable-werror",
    "-Doptimization=0",
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
    "command -v cl",
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
