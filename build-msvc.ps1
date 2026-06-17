[CmdletBinding()]
param(
    [ValidateSet("Debug", "Profile", "Release", "All", "debug", "profile", "release", "all")]
    [string]$Config = "Release",
    [ValidateSet("fast", "core", "full")]
    [string]$BuildScope = "full",
    [string]$Architecture = "amd64",
    [string]$QemuCpu = "x86_64",
    [string]$VcpkgTriplet = "x64-windows",
    [string]$ExtraConfigureArgs = "",
    [switch]$Clean,
    [switch]$Rebuild,
    [switch]$CheckOnly,
    [switch]$BootstrapVcpkg,
    [switch]$CleanIntermediates,
    [switch]$CleanAll,
    [switch]$KeepBuildTree
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$LocalVenv = Join-Path $RepoRoot ".venv-msvc"
$LocalVcpkgRoot = Join-Path $RepoRoot ".vcpkg-tool"
$LocalVcpkgDownloads = Join-Path $RepoRoot ".vcpkg-downloads"
$LocalVcpkgBinaryCache = Join-Path $RepoRoot ".vcpkg-binary-cache"
$LocalMingwCache = Join-Path $RepoRoot ".msvc-mingw-cache"
$MingwGccPackageName = "mingw-w64-x86_64-gcc-16.1.0-5-any.pkg.tar.zst"
$MingwGccPackageUrl = "https://mirror.msys2.org/mingw/mingw64/$MingwGccPackageName"
$MingwGccPackageSha256 = "10F7C55275F7FBE7924209D61C368A1A6FCF775CFFBDEAC2EEF1F5CCACDD35CD"
$MingwGccVersion = "16.1.0"

function Write-Step {
    param([string]$Message)
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$now] $Message"
}

function Get-PowerShellHostPath {
    $path = (Get-Process -Id $PID).Path
    if ($path -and (Test-Path -LiteralPath $path)) {
        return $path
    }
    return (Join-Path $PSHOME "powershell.exe")
}

function Get-ConfigName {
    param([string]$Name)
    return $Name.ToLowerInvariant()
}

function Assert-InRepoPath {
    param([string]$Path)
    $fullRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the repository: $fullPath"
    }
    return $fullPath
}

function Import-VisualStudioEnvironment {
    param([string]$Arch)

    $preservedEnv = @{}
    foreach ($name in @("VCPKG_ROOT", "VCPKG_DOWNLOADS", "VCPKG_DEFAULT_BINARY_CACHE", "VCPKG_FEATURE_FLAGS", "VCPKG_BINARY_SOURCES")) {
        $preservedEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe was not found. Install Visual Studio 2026 or Build Tools for Visual Studio 2026 with the C++ workload."
    }

    $vs2026Range = "[18.0,19.0)"
    $installPath = & $vswhere -latest -version $vs2026Range -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -requires Microsoft.VisualStudio.Component.VC.Llvm.Clang `
        -property installationPath

    if (-not $installPath) {
        $installPath = & $vswhere -latest -version $vs2026Range -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    }

    if (-not $installPath) {
        throw "Visual Studio 2026 C++ tools were not found. Install Visual Studio 2026 or Build Tools for Visual Studio 2026 with the MSVC x64/x86 build tools component."
    }

    $vcvars = Join-Path $installPath "VC\Auxiliary\Build\vcvarsall.bat"
    if (-not (Test-Path -LiteralPath $vcvars)) {
        throw "vcvarsall.bat was not found at $vcvars. Repair the Visual Studio C++ toolchain installation."
    }

    $environment = & cmd.exe /s /c "`"$vcvars`" $Arch >nul && set"
    foreach ($line in $environment) {
        if ($line -match "^([^=]+)=(.*)$") {
            Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
        }
    }

    foreach ($name in $preservedEnv.Keys) {
        if ($preservedEnv[$name]) {
            Set-Item -Path "Env:$name" -Value $preservedEnv[$name]
        }
    }
}

function Assert-Tool {
    param(
        [string]$Name,
        [string]$Hint
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        throw "$Name was not found on PATH. $Hint"
    }
    Write-Host "$Name`: $($command.Source)"
    return $command.Source
}

function Format-NativeCommandLine {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $parts = @($FilePath) + @($Arguments)
    return ($parts | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join " "
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)]
        [string]$FailureMessage,
        [string]$FailureHint = ""
    )

    $commandLine = Format-NativeCommandLine -FilePath $FilePath -Arguments $Arguments
    Write-Host ">> $commandLine"

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    foreach ($line in @($output)) {
        Write-Host $line
    }

    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    if ($exitCode -ne 0) {
        $details = [System.Collections.Generic.List[string]]::new()
        $details.Add($FailureMessage)
        $details.Add("Command: $commandLine")
        $details.Add("Exit code: $exitCode")
        if ($output) {
            $details.Add("Output tail:")
            foreach ($line in (@($output) | Select-Object -Last 80)) {
                $details.Add([string]$line)
            }
        }
        if ($FailureHint) {
            $details.Add("Hint: $FailureHint")
        }
        throw ($details -join [Environment]::NewLine)
    }

    return $exitCode
}

function Test-MsvcToolchain {
    Write-Step "Checking Visual Studio/MSVC toolchain"
    Import-VisualStudioEnvironment -Arch $Architecture
    Add-GitForWindowsToPath
    Assert-Tool -Name "cl.exe" -Hint "Install the MSVC compiler tools." | Out-Null
    Assert-Tool -Name "clang-cl.exe" -Hint "Install the C++ Clang tools for Windows component in Visual Studio." | Out-Null
    $link = Assert-Tool -Name "link.exe" -Hint "Install the MSVC linker component."
    if ($link -match "\\Git\\usr\\bin\\link\.exe$") {
        throw "Git for Windows link.exe is first on PATH. The MSVC linker must appear first."
    }
    Assert-Tool -Name "rc.exe" -Hint "Install a Windows SDK with resource compiler tools." | Out-Null
    Assert-Tool -Name "midl.exe" -Hint "Install a Windows SDK with MIDL tools." | Out-Null
    Assert-Tool -Name "bash.exe" -Hint "Install Git for Windows." | Out-Null
    Assert-Tool -Name "sh.exe" -Hint "Install Git for Windows." | Out-Null
}

function Add-GitForWindowsToPath {
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($command in Get-Command git.exe -ErrorAction SilentlyContinue) {
        if ($command.Source) {
            $dir = Split-Path $command.Source -Parent
            if ((Split-Path $dir -Leaf) -ieq "cmd") {
                $roots.Add((Split-Path $dir -Parent))
            }
        }
    }

    foreach ($root in @(
        (Join-Path $env:ProgramFiles "Git"),
        (Join-Path ${env:ProgramFiles(x86)} "Git")
    )) {
        if ($root) {
            $roots.Add($root)
        }
    }

    foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        $bash = Join-Path $root "bin\bash.exe"
        $sh = Join-Path $root "usr\bin\sh.exe"
        if ((Test-Path -LiteralPath $bash) -and (Test-Path -LiteralPath $sh)) {
            $gitBin = Join-Path $root "bin"
            $gitUsrBin = Join-Path $root "usr\bin"
            $pathEntries = $env:PATH -split ";" |
                Where-Object {
                    $_ -and
                    ([System.IO.Path]::GetFullPath($_).TrimEnd("\") -ine [System.IO.Path]::GetFullPath($gitBin).TrimEnd("\")) -and
                    ([System.IO.Path]::GetFullPath($_).TrimEnd("\") -ine [System.IO.Path]::GetFullPath($gitUsrBin).TrimEnd("\"))
                }
            $env:PATH = (@($gitBin) + $pathEntries + @($gitUsrBin)) -join ";"
            Write-Host "Git for Windows: $root"
            return
        }
    }

    throw "Git for Windows bash.exe/sh.exe were not found. Install Git for Windows or add its bin and usr\bin directories to PATH."
}

function Remove-RepoPath {
    param([string]$RelativePath)
    $target = Assert-InRepoPath (Join-Path $RepoRoot $RelativePath)
    if (Test-Path -LiteralPath $target) {
        Write-Host "Removing $RelativePath"
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

function Get-OutputPaths {
    param([string]$ConfigName)
    if ($ConfigName -eq "all") {
        return @(
            "build-msvc",
            "build-msvc-debug",
            "build-msvc-profile",
            "build-msvc-release",
            "msvc-artifacts",
            "msvc-probe-logs",
            "xemu-msvc-logs"
        )
    }

    return @(
        "build-msvc-$ConfigName",
        "msvc-artifacts\$ConfigName",
        "msvc-probe-logs",
        "xemu-msvc-logs"
    )
}

function Clear-MsvcOutputs {
    param(
        [string]$ConfigName,
        [switch]$IncludeArtifacts,
        [switch]$IncludeReusableCaches,
        [switch]$KeepBuildTree
    )

    $paths = Get-OutputPaths -ConfigName $ConfigName
    foreach ($relative in $paths) {
        if ($KeepBuildTree -and $relative -like "build-msvc*") {
            Write-Host "Keeping $relative"
            continue
        }
        if (-not $IncludeArtifacts -and $relative -like "msvc-artifacts*") {
            Write-Host "Keeping $relative"
            continue
        }
        Remove-RepoPath -RelativePath $relative
    }

    if ($IncludeReusableCaches) {
        foreach ($relative in @(".vcpkg-tool", ".vcpkg-downloads", ".vcpkg-binary-cache", ".venv-msvc", ".msvc-mingw-cache")) {
            Remove-RepoPath -RelativePath $relative
        }
    }
}

function Test-VisualStudioVcpkg {
    param([string]$Path)
    if (-not $Path) {
        return $false
    }
    return ([System.IO.Path]::GetFullPath($Path) -match "\\Microsoft Visual Studio\\.*\\VC\\vcpkg\\vcpkg\.exe$")
}

function Find-StandaloneVcpkg {
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @("VCPKG_ROOT", "VCPKG_INSTALLATION_ROOT")) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) {
            $roots.Add($value)
        }
    }

    foreach ($command in Get-Command vcpkg.exe -ErrorAction SilentlyContinue) {
        if ($command.Source) {
            $roots.Add((Split-Path $command.Source -Parent))
        }
    }

    $roots.Add("C:\vcpkg")

    foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        $vcpkg = if ((Split-Path $root -Leaf) -ieq "vcpkg.exe") {
            $root
        } else {
            Join-Path $root "vcpkg.exe"
        }
        if ((Test-Path -LiteralPath $vcpkg) -and -not (Test-VisualStudioVcpkg -Path $vcpkg)) {
            return (Resolve-Path $vcpkg).Path
        }
    }

    return $null
}

function Ensure-PythonTools {
    $python = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) {
        throw "python.exe was not found. Install Python 3 and enable the PATH option, then rerun build-msvc.ps1."
    }

    $venvPython = Join-Path $LocalVenv "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Write-Step "Creating local Python environment: .venv-msvc"
        & $python.Source -m venv $LocalVenv
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create .venv-msvc with Python."
        }
    }

    Write-Step "Installing Meson and Ninja in .venv-msvc"
    & $venvPython -m pip install --upgrade pip meson ninja
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Meson/Ninja in .venv-msvc."
    }

    $venvScripts = Join-Path $LocalVenv "Scripts"
    $env:PATH = "$venvScripts;$env:PATH"
    return $venvPython
}

function Ensure-Vcpkg {
    $vcpkg = Find-StandaloneVcpkg
    if ($BootstrapVcpkg -or -not $vcpkg) {
        $vcpkg = Join-Path $LocalVcpkgRoot "vcpkg.exe"
        if (-not (Test-Path -LiteralPath $vcpkg)) {
            $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $git) {
                throw "git.exe was not found. Install Git for Windows, then rerun build-msvc.ps1."
            }

            if (Test-Path -LiteralPath $LocalVcpkgRoot) {
                Remove-Item -LiteralPath $LocalVcpkgRoot -Recurse -Force
            }

            Write-Step "Bootstrapping standalone vcpkg in .vcpkg-tool"
            Invoke-NativeCommand `
                -FilePath $git.Source `
                -Arguments @("clone", "--depth", "1", "https://github.com/microsoft/vcpkg.git", $LocalVcpkgRoot) `
                -FailureMessage "Failed to clone vcpkg into .vcpkg-tool from https://github.com/microsoft/vcpkg.git." `
                -FailureHint "Check internet access, Git for Windows, and proxy/firewall settings."

            Invoke-NativeCommand `
                -FilePath (Join-Path $LocalVcpkgRoot "bootstrap-vcpkg.bat") `
                -Arguments @("-disableMetrics") `
                -FailureMessage "Failed to bootstrap vcpkg in .vcpkg-tool." `
                -FailureHint "Check the Visual Studio C++ toolchain, Windows SDK, network access, proxy/firewall settings, and antivirus restrictions."
        }
    }

    $vcpkgRoot = Split-Path $vcpkg -Parent
    $env:VCPKG_ROOT = $vcpkgRoot
    if (-not $env:VCPKG_DOWNLOADS) {
        $env:VCPKG_DOWNLOADS = $LocalVcpkgDownloads
    }
    if (-not $env:VCPKG_DEFAULT_BINARY_CACHE) {
        $env:VCPKG_DEFAULT_BINARY_CACHE = $LocalVcpkgBinaryCache
    }
    if (-not $env:VCPKG_FEATURE_FLAGS) {
        $env:VCPKG_FEATURE_FLAGS = "binarycaching"
    }
    if (-not $env:VCPKG_BINARY_SOURCES) {
        $env:VCPKG_BINARY_SOURCES = "clear;files,$env:VCPKG_DEFAULT_BINARY_CACHE,readwrite"
    }

    New-Item -ItemType Directory -Force -Path $env:VCPKG_DOWNLOADS, $env:VCPKG_DEFAULT_BINARY_CACHE | Out-Null
    return $vcpkg
}

function Ensure-MingwLibgccEh {
    $mingwPrefix = Join-Path $LocalMingwCache "mingw64"
    $gccLibDir = Join-Path $mingwPrefix "lib\gcc\x86_64-w64-mingw32\$MingwGccVersion"
    $libgccEh = Join-Path $gccLibDir "libgcc_eh.a"
    $packagePath = Join-Path $LocalMingwCache $MingwGccPackageName

    if (-not (Test-Path -LiteralPath $libgccEh)) {
        New-Item -ItemType Directory -Force -Path $LocalMingwCache | Out-Null

        if (-not (Test-Path -LiteralPath $packagePath)) {
            Write-Step "Downloading MinGW GCC unwind library package"
            try {
                Invoke-WebRequest -Uri $MingwGccPackageUrl -OutFile $packagePath
            } catch {
                if (Test-Path -LiteralPath $packagePath) {
                    Remove-Item -LiteralPath $packagePath -Force
                }
                throw "Failed to download $MingwGccPackageUrl. Check internet access, proxy/firewall settings, or install MSYS2 mingw-w64-x86_64-gcc and set MINGW_PREFIX."
            }
        }

        $hash = (Get-FileHash -Path $packagePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($hash -ne $MingwGccPackageSha256) {
            Remove-Item -LiteralPath $packagePath -Force
            throw "SHA256 mismatch for $MingwGccPackageName. Expected $MingwGccPackageSha256 but got $hash."
        }

        Write-Step "Extracting MinGW GCC unwind library"
        $members = @(
            "mingw64/lib/gcc/x86_64-w64-mingw32/$MingwGccVersion/libgcc_eh.a",
            "mingw64/lib/gcc/x86_64-w64-mingw32/$MingwGccVersion/libgcc.a"
        )
        $tarArgs = @("-xf", $packagePath, "-C", $LocalMingwCache) + $members
        Invoke-NativeCommand `
            -FilePath "tar.exe" `
            -Arguments $tarArgs `
            -FailureMessage "Failed to extract libgcc_eh.a from $MingwGccPackageName." `
            -FailureHint "Ensure Windows tar.exe supports .zst archives, or install MSYS2 mingw-w64-x86_64-gcc and set MINGW_PREFIX." | Out-Null

        if (-not (Test-Path -LiteralPath $libgccEh)) {
            throw "libgcc_eh.a was not extracted to $libgccEh."
        }
    }

    $env:MINGW_PREFIX = $mingwPrefix
    return $libgccEh
}

function Invoke-MsvcProbe {
    param([string]$ConfigName)

    $probe = Join-Path $RepoRoot "scripts\ci\windows-msvc-probe.ps1"
    $hostPath = Get-PowerShellHostPath
    $buildDir = if ($ConfigName -eq "all") { "build-msvc" } else { "build-msvc-$ConfigName" }
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $probe,
        "-Architecture", $Architecture,
        "-QemuCpu", $QemuCpu,
        "-BuildDir", $buildDir,
        "-BuildScope", $BuildScope,
        "-BuildConfig", $ConfigName,
        "-VcpkgTriplet", $VcpkgTriplet
    )
    if ($ExtraConfigureArgs) {
        $args += @("-ExtraConfigureArgs", $ExtraConfigureArgs)
    }
    if ($Rebuild) {
        $args += "-CleanBuild"
    }

    Write-Step "Starting MSVC $ConfigName build"
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $hostPath @args 2>&1 | ForEach-Object { Write-Host $_ }
        $processExit = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    $statusPath = Join-Path $RepoRoot "msvc-probe-logs\status.txt"
    if (Test-Path -LiteralPath $statusPath) {
        $status = @{}
        Get-Content -Path $statusPath | ForEach-Object {
            if ($_ -match "^([^=]+)=(.*)$") {
                $status[$matches[1]] = $matches[2]
            }
        }

        foreach ($key in @("configure_exit_code", "build_exit_code")) {
            if ($status.ContainsKey($key) -and $status[$key] -notin @("0", "not_run")) {
                Write-Error "MSVC probe reported $key=$($status[$key]). Check msvc-probe-logs."
                return 1
            }
        }
    } elseif ($processExit -eq 0) {
        Write-Error "MSVC probe did not produce msvc-probe-logs\\status.txt."
        return 1
    }

    return $processExit
}

$configName = Get-ConfigName -Name $Config
if ($Clean -and -not $PSBoundParameters.ContainsKey("Config")) {
    $configName = "all"
}

try {
    if ($Clean) {
        Clear-MsvcOutputs -ConfigName $configName -IncludeArtifacts -IncludeReusableCaches:$CleanAll -KeepBuildTree:$KeepBuildTree
        if (-not $Rebuild) {
            Write-Step "Clean completed"
            exit 0
        }
    }

    if ($Rebuild) {
        Clear-MsvcOutputs -ConfigName $configName -IncludeArtifacts -IncludeReusableCaches:$false -KeepBuildTree:$false
    }

    Test-MsvcToolchain
    Ensure-PythonTools | Out-Null
    $vcpkg = Ensure-Vcpkg
    $mingwLibgccEh = Ensure-MingwLibgccEh

    Write-Host "MSVC local build environment"
    Write-Host "Repository:              $RepoRoot"
    Write-Host "Config:                  $configName"
    Write-Host "Scope:                   $BuildScope"
    Write-Host "VCPKG_ROOT:              $env:VCPKG_ROOT"
    Write-Host "VCPKG_DOWNLOADS:         $env:VCPKG_DOWNLOADS"
    Write-Host "VCPKG_DEFAULT_BINARY_CACHE: $env:VCPKG_DEFAULT_BINARY_CACHE"
    Write-Host "vcpkg.exe:               $vcpkg"
    Write-Host "MINGW_PREFIX:            $env:MINGW_PREFIX"
    Write-Host "libgcc_eh.a:             $mingwLibgccEh"

    if ($CheckOnly) {
        Write-Step "CheckOnly completed"
        exit 0
    }

    $exitCode = Invoke-MsvcProbe -ConfigName $configName
    if ($exitCode -ne 0) {
        throw "MSVC build failed with exit code $exitCode. Check msvc-probe-logs and xemu-msvc-logs."
    }

    if ($CleanIntermediates -or $CleanAll) {
        Clear-MsvcOutputs -ConfigName $configName -IncludeArtifacts:$false -IncludeReusableCaches:$CleanAll -KeepBuildTree:$KeepBuildTree
    }

    if ($configName -eq "all") {
        Write-Step "MSVC build completed. Artifacts are under msvc-artifacts\\debug, msvc-artifacts\\profile, and msvc-artifacts\\release."
    } else {
        $artifactExe = Join-Path $RepoRoot "msvc-artifacts\$configName\xemu.exe"
        Write-Step "MSVC build completed. Expected executable: $artifactExe"
    }
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
