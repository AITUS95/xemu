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

function Get-SafeFileName {
    param([string]$PathOrName)

    if (-not $PathOrName) {
        return $null
    }

    $fileName = [System.IO.Path]::GetFileName($PathOrName.Trim().Trim('"'))
    if (-not $fileName) {
        return $null
    }

    if ($fileName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        return $null
    }

    return $fileName
}

function Get-CodeViewPdbNames {
    param([object[]]$DumpbinOutput)

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in $DumpbinOutput) {
        $text = [string]$line
        foreach ($match in [regex]::Matches($text, '(?i)([A-Za-z]:\\[^,\r\n]+?\.pdb|\\\\[^,\r\n]+?\.pdb|[^\\/:*?"<>|\s,]+\.pdb)')) {
            $fileName = Get-SafeFileName -PathOrName $match.Groups[1].Value
            if ($fileName -and -not $names.Contains($fileName)) {
                $names.Add($fileName)
            }
        }
    }

    return @($names)
}

function Publish-LogsArtifact {
    param(
        [string]$LogsDir,
        [string]$LogsArtifactRoot
    )

    if (Test-Path $LogsArtifactRoot) {
        Remove-Item -Recurse -Force $LogsArtifactRoot
    }
    New-Item -ItemType Directory -Force -Path $LogsArtifactRoot | Out-Null
    Copy-Item -LiteralPath $LogsDir -Destination $LogsArtifactRoot -Recurse -Force
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

        $dllPdb = Join-Path $dll.DirectoryName "$($dll.BaseName).pdb"
        if (Test-Path -LiteralPath $dllPdb) {
            Copy-Item -LiteralPath $dllPdb -Destination $Destination -Force
            Add-Content -Path $DependentsLog -Value "packaged symbols: $dllPdb"
        }

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
        [string[]]$EmbeddedPdbNames,
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
        $pdbNames = New-Object System.Collections.Generic.List[string]
        foreach ($name in @("xemu.pdb") + @($EmbeddedPdbNames)) {
            $safeName = Get-SafeFileName -PathOrName $name
            if ($safeName -and -not $pdbNames.Contains($safeName)) {
                $pdbNames.Add($safeName)
            }
        }

        foreach ($name in $pdbNames) {
            Copy-Item -LiteralPath $Pdb.FullName -Destination (Join-Path $destination $name) -Force
            Add-Content -Path $LayoutLog -Value "packaged pdb: $name"
        }
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

function Find-XemuLogFiles {
    param(
        [string]$PackageDir,
        [string]$LogsDir,
        [datetime]$Since,
        [string]$WorkspaceRoot
    )

    $searchLog = Join-Path $LogsDir "xemu-log-search.log"
    $resolvedLogsDir = if (Test-Path $LogsDir) { (Resolve-Path $LogsDir).Path } else { $LogsDir }
    $roots = @(
        $PackageDir,
        (Get-Location).Path,
        $WorkspaceRoot,
        $env:GITHUB_WORKSPACE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:TEMP
    ) | Where-Object { $_ -and (Test-Path $_) } |
        ForEach-Object { (Resolve-Path $_).Path } |
        Sort-Object -Unique

    "search_since=$($Since.ToString("o"))" | Set-Content -Path $searchLog
    $roots | ForEach-Object { Add-Content -Path $searchLog -Value "search_root=$_" }

    $candidates = @()
    foreach ($root in $roots) {
        try {
            $candidates += Get-ChildItem -Path $root -Recurse -Force -File -Filter "xemu.log" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.LastWriteTime -ge $Since.AddSeconds(-5) -and
                    -not $_.FullName.StartsWith($resolvedLogsDir, [System.StringComparison]::OrdinalIgnoreCase)
                }
        } catch {
            Add-Content -Path $searchLog -Value "search_error=$root :: $($_.Exception.Message)"
        }
    }

    $candidates = @($candidates | Sort-Object LastWriteTime -Descending -Unique)
    if ($candidates) {
        $candidates | ForEach-Object {
            Add-Content -Path $searchLog -Value "candidate=$($_.FullName); last_write=$($_.LastWriteTime.ToString("o")); bytes=$($_.Length)"
        }
    } else {
        Add-Content -Path $searchLog -Value "candidate=none"
    }

    return $candidates
}

function Test-XemuRuntimeLog {
    param(
        [string]$Path,
        [string]$SmokeLog
    )

    $text = Get-Content -Raw -Path $Path
    $patterns = @(
        "la_bb_end",
        "Bail out",
        "code should not be reached",
        "ERROR:\.\./tcg/tcg\.c"
    )
    foreach ($pattern in $patterns) {
        if ($text -match $pattern) {
            Add-Content -Path $SmokeLog -Value "runtime_log_failure=$pattern"
            return "found"
        }
    }

    Add-Content -Path $SmokeLog -Value "runtime_log_failure=absent"
    return "absent"
}

function Invoke-RuntimeVersionSmokeTest {
    param(
        [string]$ConfigName,
        [string]$PackageDir,
        [string]$LogsDir,
        [string]$WorkspaceRoot
    )

    $smokeLog = Join-Path $LogsDir "runtime-smoke.log"
    $xemuLogDestination = Join-Path $LogsDir "xemu.log"
    Add-Content -Path $smokeLog -Value "===== runtime smoke: $ConfigName ====="

    if (-not $PackageDir) {
        Add-Content -Path $smokeLog -Value "not_run: package directory missing"
        return [pscustomobject]@{
            VersionSmoke = "not_run"
            XemuLogStatus = "not_found"
            LaBbEndStatus = "unverified"
        }
    }

    $exe = Join-Path $PackageDir "xemu.exe"
    if (-not (Test-Path $exe)) {
        Add-Content -Path $smokeLog -Value "failed: xemu.exe missing"
        return [pscustomobject]@{
            VersionSmoke = "failed"
            XemuLogStatus = "not_found"
            LaBbEndStatus = "unverified"
        }
    }

    $localXemuLog = Join-Path $PackageDir "xemu.log"
    Remove-Item -Force -ErrorAction SilentlyContinue $localXemuLog
    Remove-Item -Force -ErrorAction SilentlyContinue $xemuLogDestination

    $startedAt = Get-Date
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
                Add-Content -Path $smokeLog -Value "runtime_version_smoke=timeout_no_crash_observed"
                Add-Content -Path $smokeLog -Value "timeout=10s killed=true"
                $result = "timeout_no_crash_observed"
            } else {
                Add-Content -Path $smokeLog -Value "exit_code=$($proc.ExitCode)"
                $result = if ($proc.ExitCode -eq 0) { "passed" } else { "failed" }
            }
        }
    } catch {
        Add-Content -Path $smokeLog -Value "failed_to_start=$($_.Exception.Message)"
        $result = "failed"
    }

    $xemuLogs = Find-XemuLogFiles `
        -PackageDir $PackageDir `
        -LogsDir $LogsDir `
        -Since $startedAt `
        -WorkspaceRoot $WorkspaceRoot

    if ($xemuLogs) {
        $selected = $xemuLogs | Select-Object -First 1
        Copy-Item -LiteralPath $selected.FullName -Destination $xemuLogDestination -Force
        Add-Content -Path $smokeLog -Value "xemu_log=found:$($selected.FullName)"
        $xemuLogStatus = "found"
        $laBbEndStatus = Test-XemuRuntimeLog -Path $selected.FullName -SmokeLog $smokeLog
        if ($laBbEndStatus -eq "found") {
            $result = "la_bb_end"
        }
    } else {
        "not_found" | Set-Content -Path $xemuLogDestination
        Add-Content -Path $smokeLog -Value "xemu_log=not_found"
        $xemuLogStatus = "not_found"
        $laBbEndStatus = "unverified"
    }

    return [pscustomobject]@{
        VersionSmoke = $result
        XemuLogStatus = $xemuLogStatus
        LaBbEndStatus = $laBbEndStatus
    }
}

function Invoke-RuntimeRealSmokeTest {
    param(
        [string]$ConfigName,
        [string]$PackageDir,
        [string]$LogsDir,
        [string]$WorkspaceRoot
    )

    $realLog = Join-Path $LogsDir "runtime-real-smoke.log"
    Add-Content -Path $realLog -Value "===== runtime real smoke: $ConfigName ====="

    if (-not $env:MSVC_RUNTIME_REAL_ARGS) {
        Add-Content -Path $realLog -Value "runtime_real_validation=manual_required"
        Add-Content -Path $realLog -Value "reason=MSVC_RUNTIME_REAL_ARGS not set; CI has no BIOS/ROM/test payload to exercise TCG"
        Add-Content -Path $realLog -Value "la_bb_end_status=unresolved"
        return [pscustomobject]@{
            RuntimeRealValidation = "manual_required"
            LaBbEndStatus = "unresolved"
            XemuLogStatus = "not_run"
        }
    }

    $exe = Join-Path $PackageDir "xemu.exe"
    if (-not (Test-Path $exe)) {
        Add-Content -Path $realLog -Value "runtime_real_validation=failed"
        Add-Content -Path $realLog -Value "reason=xemu.exe missing"
        return [pscustomobject]@{
            RuntimeRealValidation = "failed"
            LaBbEndStatus = "unverified"
            XemuLogStatus = "not_found"
        }
    }

    $startedAt = Get-Date
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $env:MSVC_RUNTIME_REAL_ARGS `
            -WorkingDirectory $PackageDir `
            -PassThru -WindowStyle Hidden
        try {
            Wait-Process -Id $proc.Id -Timeout 20 -ErrorAction Stop
            Add-Content -Path $realLog -Value "exit_code=$($proc.ExitCode)"
            $realResult = if ($proc.ExitCode -eq 0) { "passed" } else { "failed" }
        } catch {
            if (-not $proc.HasExited) {
                $proc.Kill()
                Add-Content -Path $realLog -Value "timeout=20s killed=true"
                $realResult = "timeout_no_crash_observed"
            } else {
                Add-Content -Path $realLog -Value "exit_code=$($proc.ExitCode)"
                $realResult = if ($proc.ExitCode -eq 0) { "passed" } else { "failed" }
            }
        }
    } catch {
        Add-Content -Path $realLog -Value "failed_to_start=$($_.Exception.Message)"
        $realResult = "failed"
    }

    $xemuLogs = Find-XemuLogFiles `
        -PackageDir $PackageDir `
        -LogsDir $LogsDir `
        -Since $startedAt `
        -WorkspaceRoot $WorkspaceRoot

    if ($xemuLogs) {
        $selected = $xemuLogs | Select-Object -First 1
        Copy-Item -LiteralPath $selected.FullName -Destination (Join-Path $LogsDir "xemu-real.log") -Force
        Add-Content -Path $realLog -Value "xemu_log=found:$($selected.FullName)"
        $xemuLogStatus = "found"
        $laBbEndStatus = Test-XemuRuntimeLog -Path $selected.FullName -SmokeLog $realLog
        if ($laBbEndStatus -eq "found") {
            $realResult = "la_bb_end"
        }
    } else {
        Add-Content -Path $realLog -Value "xemu_log=not_found"
        $xemuLogStatus = "not_found"
        $laBbEndStatus = "unverified"
    }

    Add-Content -Path $realLog -Value "runtime_real_validation=$realResult"
    Add-Content -Path $realLog -Value "la_bb_end_status=$laBbEndStatus"
    return [pscustomobject]@{
        RuntimeRealValidation = $realResult
        LaBbEndStatus = $laBbEndStatus
        XemuLogStatus = $xemuLogStatus
    }
}

function Get-PowerShellHostPath {
    $preferred = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh" } else { "powershell" }
    $command = Get-Command $preferred -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $current = Get-Process -Id $PID
    if ($current.Path) {
        return $current.Path
    }

    throw "Could not locate a PowerShell host for build_config=all."
}

function Get-StatusValue {
    param(
        [string]$StatusPath,
        [string]$Key
    )

    if (-not (Test-Path $StatusPath)) {
        return "missing"
    }

    $line = Get-Content -Path $StatusPath |
        Where-Object { $_ -match "^$([regex]::Escape($Key))=" } |
        Select-Object -First 1
    if (-not $line) {
        return "missing"
    }

    return $line.Substring($Key.Length + 1)
}

function Invoke-AllBuildConfigs {
    param(
        [string]$Architecture,
        [string]$QemuCpu,
        [string]$BuildScope,
        [string]$VcpkgTriplet,
        [string]$ExtraConfigureArgs,
        [switch]$Strict
    )

    if ($BuildScope -ne "full") {
        throw "build_config=all is only supported with build_scope=full."
    }

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $logsDir = Join-Path $repoRoot "msvc-probe-logs"
    $logsArtifactRoot = Join-Path $repoRoot "xemu-msvc-logs"
    $artifactsRoot = Join-Path $repoRoot "msvc-artifacts"
    $phaseLog = Join-Path $logsDir "phase-timings.log"

    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $logsDir, $logsArtifactRoot, $artifactsRoot
    New-Item -ItemType Directory -Force -Path $logsDir, $artifactsRoot | Out-Null

    $startedAt = Get-Date
    "[$($startedAt.ToString("yyyy-MM-dd HH:mm:ss"))] BEGIN all configs" | Set-Content -Path $phaseLog

    $powerShellHost = Get-PowerShellHostPath
    $configs = @("debug", "profile", "release")
    $statusLines = @(
        "build_scope=$BuildScope",
        "build_config=all",
        "strict=$Strict"
    )
    $buildExitAggregate = 0
    $validationExitAggregate = 0
    $configureExitAggregate = 0

    foreach ($config in $configs) {
        $configStartedAt = Get-Date
        Add-Content -Path $phaseLog -Value "[$($configStartedAt.ToString("yyyy-MM-dd HH:mm:ss"))] BEGIN $config"

        $childBuildDir = "build-msvc-$config"
        $childLogsName = "msvc-probe-logs-$config"
        $childLogsDir = Join-Path $repoRoot $childLogsName
        $configLogsDir = Join-Path $logsDir $config
        $consoleLog = Join-Path $logsDir "all-$config-console.log"

        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $childLogsDir, $configLogsDir

        $savedEnv = @{}
        foreach ($name in @("MSVC_PROBE_ALL_CHILD", "MSVC_PROBE_LOGS_DIR_NAME", "MSVC_PROBE_KEEP_ARTIFACTS")) {
            $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }

        try {
            $env:MSVC_PROBE_ALL_CHILD = "1"
            $env:MSVC_PROBE_LOGS_DIR_NAME = $childLogsName
            $env:MSVC_PROBE_KEEP_ARTIFACTS = "1"

            $childArgs = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $PSCommandPath,
                "-Architecture", $Architecture,
                "-QemuCpu", $QemuCpu,
                "-BuildDir", $childBuildDir,
                "-BuildScope", $BuildScope,
                "-BuildConfig", $config,
                "-VcpkgTriplet", $VcpkgTriplet,
                "-ExtraConfigureArgs", $ExtraConfigureArgs
            )
            if ($Strict) {
                $childArgs += "-Strict"
            }

            & $powerShellHost @childArgs *> $consoleLog
            $childExit = $LASTEXITCODE
        } finally {
            foreach ($name in $savedEnv.Keys) {
                if ($null -eq $savedEnv[$name]) {
                    Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
                } else {
                    Set-Item -Path "Env:$name" -Value $savedEnv[$name]
                }
            }
        }

        Write-Host "Windows MSVC $config exit code: $childExit"
        Write-Host "Last 80 lines of ${consoleLog}:"
        Get-Content -Path $consoleLog -Tail 80

        if (Test-Path $childLogsDir) {
            Copy-Item -LiteralPath $childLogsDir -Destination $configLogsDir -Recurse -Force
        } else {
            "missing child logs: $childLogsDir" | Set-Content -Path (Join-Path $logsDir "$config-missing-logs.txt")
        }

        $statusPath = Join-Path $configLogsDir "status.txt"
        $configConfigureExit = Get-StatusValue -StatusPath $statusPath -Key "configure_exit_code"
        $configBuildExit = Get-StatusValue -StatusPath $statusPath -Key "build_exit_code"
        $statusLines += "$config.configure_exit_code=$configConfigureExit"
        $statusLines += "$config.build_exit_code=$configBuildExit"
        $statusLines += "$config.pdb_reference_check=$(Get-StatusValue -StatusPath $statusPath -Key "pdb_reference_check")"
        $statusLines += "$config.cv2pdb_check=$(Get-StatusValue -StatusPath $statusPath -Key "cv2pdb_check")"
        $statusLines += "$config.runtime_smoke_check=$(Get-StatusValue -StatusPath $statusPath -Key "runtime_smoke_check")"
        $statusLines += "$config.runtime_version_smoke=$(Get-StatusValue -StatusPath $statusPath -Key "runtime_version_smoke")"
        $statusLines += "$config.runtime_real_validation=$(Get-StatusValue -StatusPath $statusPath -Key "runtime_real_validation")"
        $statusLines += "$config.xemu_log_status=$(Get-StatusValue -StatusPath $statusPath -Key "xemu_log_status")"
        $statusLines += "$config.la_bb_end_status=$(Get-StatusValue -StatusPath $statusPath -Key "la_bb_end_status")"
        $statusLines += "$config.missing_source_filename_check=$(Get-StatusValue -StatusPath $statusPath -Key "missing_source_filename_check")"
        $statusLines += "$config.validation_exit_code=$(Get-StatusValue -StatusPath $statusPath -Key "validation_exit_code")"
        $statusLines += "$config.packaged_artifact=$(Get-StatusValue -StatusPath $statusPath -Key "packaged_artifact")"

        if ($configConfigureExit -ne "0") {
            $configureExitAggregate = 1
        }
        if ($configBuildExit -ne "0") {
            $buildExitAggregate = 1
        }
        if ($childExit -ne 0) {
            $validationExitAggregate = $childExit
        }

        $configElapsed = (Get-Date) - $configStartedAt
        Add-Content -Path $phaseLog -Value ("[$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))] END {0} duration={1:n1}s" -f $config, $configElapsed.TotalSeconds)
    }

    $aggregateLogs = @{
        "artifact-layout.log" = "artifact-layout.log"
        "dependents.log" = "dependents.log"
        "runtime-smoke.log" = "runtime-smoke.log"
        "runtime-real-smoke.log" = "runtime-real-smoke.log"
        "dumpbin-headers.txt" = "dumpbin-headers.txt"
        "pdb-check.log" = "pdb-check.log"
        "xemu.log" = "xemu.log"
        "xemu-real.log" = "xemu-real.log"
        "xemu-log-search.log" = "xemu-log-search.log"
        "missing-source-filename-matches.txt" = "missing-source-filename-matches.txt"
        "strict-validation-failures.txt" = "strict-validation-failures.txt"
    }
    foreach ($entry in $aggregateLogs.GetEnumerator()) {
        $aggregatePath = Join-Path $logsDir $entry.Key
        "build_config=all" | Set-Content -Path $aggregatePath
        foreach ($config in $configs) {
            $sourcePath = Join-Path (Join-Path $logsDir $config) $entry.Value
            Add-Content -Path $aggregatePath -Value "===== $config ====="
            if (Test-Path $sourcePath) {
                Get-Content -Path $sourcePath | Add-Content -Path $aggregatePath
            } else {
                Add-Content -Path $aggregatePath -Value "not_found"
            }
        }
    }

    foreach ($logName in @(
        "build-output.log",
        "meson-log.txt",
        "msvc-cl-wrapper.log",
        "where-link.log",
        "xemu-version-diagnostics.log",
        "meson-targets.json",
        "config.log",
        "strict-validation-failures.txt"
    )) {
        $indexPath = Join-Path $logsDir $logName
        "build_config=all" | Set-Content -Path $indexPath
        foreach ($config in $configs) {
            $sourcePath = Join-Path (Join-Path $logsDir $config) $logName
            if (Test-Path $sourcePath) {
                Add-Content -Path $indexPath -Value "$config=$config/$logName"
            } else {
                Add-Content -Path $indexPath -Value "$config=not_found"
            }
        }
    }

    $totalElapsed = (Get-Date) - $startedAt
    Add-Content -Path $phaseLog -Value ("[$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))] END all configs duration={0:n1}s" -f $totalElapsed.TotalSeconds)

    @(
        "configure_exit_code=$configureExitAggregate",
        "build_exit_code=$buildExitAggregate",
        "validation_exit_code=$validationExitAggregate"
    ) + $statusLines + @(
        "xemu_exe=see_config_logs",
        "xemu_pdb=see_config_logs",
        "pdb_reference_check=see_config_logs",
        "cv2pdb_check=see_config_logs",
        "runtime_smoke_check=see_config_logs",
        "embedded_pdb_names=see_config_logs",
        "packaged_artifact=$artifactsRoot"
    ) | Set-Content -Path (Join-Path $logsDir "status.txt")

    Write-Host "Status summary:"
    Get-Content -Path (Join-Path $logsDir "status.txt")
    Write-Host "Phase timings:"
    Get-Content -Path $phaseLog

    Publish-LogsArtifact -LogsDir $logsDir -LogsArtifactRoot $logsArtifactRoot

    if ($Strict -and ($configureExitAggregate -ne 0 -or $buildExitAggregate -ne 0 -or $validationExitAggregate -ne 0)) {
        if ($buildExitAggregate -ne 0) {
            exit $buildExitAggregate
        }
        if ($validationExitAggregate -ne 0) {
            exit $validationExitAggregate
        }
        exit $configureExitAggregate
    }

    exit 0
}

if ($BuildConfig -eq "all" -and -not $env:MSVC_PROBE_ALL_CHILD) {
    Invoke-AllBuildConfigs `
        -Architecture $Architecture `
        -QemuCpu $QemuCpu `
        -BuildScope $BuildScope `
        -VcpkgTriplet $VcpkgTriplet `
        -ExtraConfigureArgs $ExtraConfigureArgs `
        -Strict:$Strict
}

$script:PhaseStart = @{}
$script:PhaseEvents = @()
$script:PhaseLog = $null
Start-Phase "probe"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:RepoRoot = $repoRoot
$logsDirName = if ($env:MSVC_PROBE_LOGS_DIR_NAME) { $env:MSVC_PROBE_LOGS_DIR_NAME } else { "msvc-probe-logs" }
$logsDir = Join-Path $repoRoot $logsDirName
$logsDirBash = "../$logsDirName"
$logsArtifactRoot = Join-Path $repoRoot "xemu-msvc-logs"
$artifactsRoot = Join-Path $repoRoot "msvc-artifacts"
$buildPath = Join-Path $repoRoot $BuildDir
$wrapperLog = Join-Path $logsDir "msvc-cl-wrapper.log"
$finalExecutable = $null
$finalPdb = $null
$embeddedPdbNames = @()
$pdbReferenceCheck = "not_run"
$cv2pdbCheck = "not_run"
$runtimeSmokeCheck = "not_run"
$runtimeVersionSmokeCheck = "not_run"
$runtimeRealValidation = "not_run"
$xemuLogStatus = "not_run"
$laBbEndStatus = "not_run"
$d8003Check = "not_run"
$validationExit = 0
$validationFailures = @()
$packagedArtifact = "not_run"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $logsDir
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $logsArtifactRoot
Remove-Item -Force -ErrorAction SilentlyContinue $wrapperLog
New-Item -ItemType File -Force -Path $wrapperLog | Out-Null
$keepArtifacts = $env:MSVC_PROBE_KEEP_ARTIFACTS -in @("1", "true", "yes")
if (-not $keepArtifacts) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $artifactsRoot
}
New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null
$script:PhaseLog = Join-Path $logsDir "phase-timings.log"
$script:PhaseEvents | Set-Content -Path $script:PhaseLog

Start-Phase "toolchain setup"
Import-VisualStudioEnvironment -Arch $Architecture

Write-Host "Windows MSVC build environment"
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
if ($BuildScope -eq "full") {
    $vcpkgPackageNames += "vulkan-headers"
}
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
$env:INCLUDE = "$(Join-Path $vcpkgInstalled "include");$env:INCLUDE"
$env:LIB = "$(Join-Path $vcpkgInstalled "lib");$env:LIB"
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
$clVersionLog = Join-Path $logsDir "cl-version.log"
if ($compilerCommand -eq "clang-cl.exe") {
    clang-cl.exe --version 2>&1 | Tee-Object -FilePath $clVersionLog
} else {
    @(
        "compiler=$compilerCommand",
        "cl_version_probe=skipped",
        "reason=cl /Bv without a source emits a missing-source-filename diagnostic"
    ) | Set-Content -Path $clVersionLog
}
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
        "-Dopengl=disabled",
        "-Dvulkan=disabled"
    )
} elseif ($BuildScope -eq "full") {
    $configureArgs += "-Dvulkan=enabled"
}

$configureLine = $configureArgs -join " "
if ($ExtraConfigureArgs) {
    $configureLine += " $ExtraConfigureArgs"
}
$configureLine += " > ${logsDirBash}/configure-output.log 2>&1"

$configureCommand = @(
    "set -o pipefail",
    "export AR=lib",
    "export LD=link",
    "export NM=dumpbin",
    "export WINDRES=rc",
    "export DLLTOOL=:",
    "export RANLIB=:",
    "export STRIP=:",
    "export MSVC_CL_WRAPPER_TRACE=unknown",
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
        "sh -x ../scripts/xemu-version.sh `"${repoRootMeson}`" 2>&1 | tee ${logsDirBash}/xemu-version-diagnostics.log; xemu_version_exit=`${PIPESTATUS[0]}; echo xemu_version_exit=`$xemu_version_exit; test `$xemu_version_exit -eq 0"
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
        $compileLine = "echo Windows MSVC ${BuildScope}/${BuildConfig} target: ${compileTarget}; python -m mesonbuild.mesonmain compile -C . `"${compileTarget}`" --verbose > ${logsDirBash}/build-output.log 2>&1"

        $buildCommand = @(
            "set -o pipefail",
            "export AR=lib",
            "export LD=link",
            "export NM=dumpbin",
            "export WINDRES=rc",
            "export DLLTOOL=:",
            "export RANLIB=:",
            "export STRIP=:",
            "export MSVC_CL_WRAPPER_TRACE=unknown",
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
        $pdbCheckLog = Join-Path $logsDir "pdb-check.log"
        @(
            "build_config=$BuildConfig",
            "build_scope=$BuildScope"
        ) | Set-Content -Path $pdbCheckLog

        $requiresPdb = $BuildConfig -ne "release"
        $finalExecutable = Find-FinalExecutable -Root $buildPath
        if (-not $finalExecutable) {
            Write-Warning "FAIL: xemu/qemu-system-i386 executable was not found."
            Add-Content -Path $pdbCheckLog -Value "binary=not_found"
            Get-ChildItem -Path $buildPath -Recurse -File -Filter "*.exe" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName |
                Set-Content -Path (Join-Path $logsDir "exe-files.txt")
            $buildExit = 1
        } else {
            Write-Host "Binary found: $($finalExecutable.FullName)"
            Add-Content -Path $pdbCheckLog -Value "binary=$($finalExecutable.FullName)"

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
                    Add-Content -Path $pdbCheckLog -Value "pdb=$($finalPdb.FullName)"
                }

                $dumpbinOutput = & dumpbin.exe /headers $finalExecutable.FullName 2>&1
                $dumpbinOutput | Set-Content -Path (Join-Path $logsDir "dumpbin-headers.txt")
                $embeddedPdbNames = Get-CodeViewPdbNames -DumpbinOutput $dumpbinOutput
                $dumpbinExit = $LASTEXITCODE
                if ($dumpbinExit -ne 0 -or -not ($dumpbinOutput | Select-String -Pattern "RSDS|PDB" -CaseSensitive:$false)) {
                    Write-Warning "FAIL: no CodeView/RSDS/PDB reference was found in the binary."
                    $pdbReferenceCheck = "failed"
                    Add-Content -Path $pdbCheckLog -Value "pdb_reference_check=failed"
                    $buildExit = 1
                } elseif (-not $embeddedPdbNames) {
                    Write-Warning "FAIL: CodeView/RSDS was found, but no PDB file name was parsed from the binary."
                    $pdbReferenceCheck = "failed"
                    Add-Content -Path $pdbCheckLog -Value "pdb_reference_check=failed"
                    $buildExit = 1
                } else {
                    Write-Host "OK: CodeView/RSDS/PDB reference found in binary."
                    Write-Host "Embedded PDB name(s): $($embeddedPdbNames -join ', ')"
                    $pdbReferenceCheck = "passed"
                    Add-Content -Path $pdbCheckLog -Value "pdb_reference_check=passed"
                    Add-Content -Path $pdbCheckLog -Value "embedded_pdb_names=$($embeddedPdbNames -join ',')"
                }
            } else {
                $pdbReferenceCheck = "not_required_release"
                Add-Content -Path $pdbCheckLog -Value "pdb_reference_check=not_required_release"
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
$runtimeRealSmokeLog = Join-Path $logsDir "runtime-real-smoke.log"
$pdbCheckLog = Join-Path $logsDir "pdb-check.log"
$xemuLog = Join-Path $logsDir "xemu.log"
$xemuLogSearchLog = Join-Path $logsDir "xemu-log-search.log"
$d8003MatchesLog = Join-Path $logsDir "missing-source-filename-matches.txt"
if (-not (Test-Path $dependentsLog)) { "not_run" | Set-Content -Path $dependentsLog }
if (-not (Test-Path $layoutLog)) { "not_run" | Set-Content -Path $layoutLog }
if (-not (Test-Path $runtimeSmokeLog)) { "not_run" | Set-Content -Path $runtimeSmokeLog }
if (-not (Test-Path $runtimeRealSmokeLog)) { "not_run" | Set-Content -Path $runtimeRealSmokeLog }
if (-not (Test-Path $pdbCheckLog)) { "not_run" | Set-Content -Path $pdbCheckLog }
if (-not (Test-Path $xemuLog)) { "not_run" | Set-Content -Path $xemuLog }
if (-not (Test-Path $xemuLogSearchLog)) { "not_run" | Set-Content -Path $xemuLogSearchLog }
if (-not (Test-Path $d8003MatchesLog)) { "not_run" | Set-Content -Path $d8003MatchesLog }

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
        -EmbeddedPdbNames $embeddedPdbNames `
        -DependencyDirs @($vcpkgBin) `
        -ArtifactsRoot $artifactsRoot `
        -DependentsLog $dependentsLog `
        -LayoutLog $layoutLog `
        -IncludePdb:$includePdb
}
End-Phase "artifact packaging"

if ($BuildScope -eq "full" -and $buildExit -eq 0 -and $packagedArtifact -ne "not_run") {
    Start-Phase "runtime version smoke test"
    try {
        $versionSmoke = Invoke-RuntimeVersionSmokeTest `
            -ConfigName $BuildConfig `
            -PackageDir $packagedArtifact `
            -LogsDir $logsDir `
            -WorkspaceRoot $repoRoot
        $runtimeVersionSmokeCheck = $versionSmoke.VersionSmoke
        $runtimeSmokeCheck = $runtimeVersionSmokeCheck
        $xemuLogStatus = $versionSmoke.XemuLogStatus
        $laBbEndStatus = $versionSmoke.LaBbEndStatus
        if ($runtimeSmokeCheck -in @("failed", "la_bb_end")) {
            Write-Warning "FAIL: runtime version smoke test result: $runtimeSmokeCheck"
            $buildExit = 1
        } elseif ($runtimeSmokeCheck -eq "timeout_no_crash_observed") {
            Write-Warning "WARN: runtime version smoke timed out; this is not runtime validation."
        } else {
            Write-Host "Runtime version smoke test result: $runtimeSmokeCheck"
        }
    } finally {
        End-Phase "runtime version smoke test"
    }

    Start-Phase "runtime real smoke test"
    try {
        $realSmoke = Invoke-RuntimeRealSmokeTest `
            -ConfigName $BuildConfig `
            -PackageDir $packagedArtifact `
            -LogsDir $logsDir `
            -WorkspaceRoot $repoRoot
        $runtimeRealValidation = $realSmoke.RuntimeRealValidation
        if ($realSmoke.XemuLogStatus -eq "found") {
            $xemuLogStatus = "found"
        }
        if ($realSmoke.LaBbEndStatus -in @("found", "unresolved")) {
            $laBbEndStatus = $realSmoke.LaBbEndStatus
        }
        if ($runtimeRealValidation -in @("failed", "la_bb_end")) {
            Write-Warning "FAIL: runtime real smoke test result: $runtimeRealValidation"
            $buildExit = 1
        } elseif ($runtimeRealValidation -eq "manual_required") {
            Write-Warning "WARN: runtime real smoke test requires external BIOS/ROM/test payload."
        } else {
            Write-Host "Runtime real smoke test result: $runtimeRealValidation"
        }
    } finally {
        End-Phase "runtime real smoke test"
    }
}

$d8003Matches = Get-ChildItem -Path $logsDir -Recurse -Force -File -ErrorAction SilentlyContinue |
    Select-String -Pattern "D8003" -CaseSensitive:$false
if ($d8003Matches) {
    $d8003Check = "found"
    $d8003Matches |
        ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line)" } |
        Set-Content -Path (Join-Path $logsDir "missing-source-filename-matches.txt")
    $validationFailures += "MSVC missing-source-filename diagnostic present in logs"
} else {
    $d8003Check = "absent"
    "missing_source_filename=absent" | Set-Content -Path (Join-Path $logsDir "missing-source-filename-matches.txt")
}

if ($BuildScope -eq "full") {
    if ($xemuLogStatus -ne "found") {
        $validationFailures += "xemu.log was not collected"
    }
    if ($runtimeRealValidation -ne "passed") {
        $validationFailures += "runtime real validation is $runtimeRealValidation"
    }
    if ($laBbEndStatus -in @("found", "unresolved", "unverified")) {
        $validationFailures += "la_bb_end status is $laBbEndStatus"
    }
}

if ($validationFailures) {
    $validationExit = 1
    $validationFailures | Set-Content -Path (Join-Path $logsDir "strict-validation-failures.txt")
} else {
    "none" | Set-Content -Path (Join-Path $logsDir "strict-validation-failures.txt")
}

@(
    "configure_exit_code=$configureExit",
    "build_exit_code=$(if ($null -eq $buildExit) { 'not_run' } else { $buildExit })",
    "validation_exit_code=$validationExit",
    "build_scope=$BuildScope",
    "build_config=$BuildConfig",
    "strict=$Strict",
    "xemu_exe=$(if ($finalExecutable) { $finalExecutable.FullName } else { 'not_found' })",
    "xemu_pdb=$(if ($finalPdb) { $finalPdb.FullName } else { 'not_found' })",
    "embedded_pdb_names=$(if ($embeddedPdbNames) { $embeddedPdbNames -join ',' } else { 'not_found' })",
    "pdb_reference_check=$pdbReferenceCheck",
    "cv2pdb_check=$cv2pdbCheck",
    "runtime_smoke_check=$runtimeSmokeCheck",
    "runtime_version_smoke=$runtimeVersionSmokeCheck",
    "runtime_real_validation=$runtimeRealValidation",
    "xemu_log_status=$xemuLogStatus",
    "la_bb_end_status=$laBbEndStatus",
    "missing_source_filename_check=$d8003Check",
    "packaged_artifact=$packagedArtifact"
) | Set-Content -Path (Join-Path $logsDir "status.txt")

Write-Host "Status summary:"
Get-Content -Path (Join-Path $logsDir "status.txt")
Write-Host "Phase timings:"
Get-Content -Path $script:PhaseLog

if ($configureExit -ne 0) {
    Write-Warning "Windows MSVC configure failed with exit code $configureExit. Logs were written to $logsDir."
    if ($Strict) {
        End-Phase "probe"
        Publish-LogsArtifact -LogsDir $logsDir -LogsArtifactRoot $logsArtifactRoot
        exit $configureExit
    }
}
if ($null -ne $buildExit -and $buildExit -ne 0) {
    Write-Warning "Windows MSVC build failed with exit code $buildExit. Logs were written to $logsDir."
    if ($Strict) {
        End-Phase "probe"
        Publish-LogsArtifact -LogsDir $logsDir -LogsArtifactRoot $logsArtifactRoot
        exit $buildExit
    }
}
if ($validationExit -ne 0) {
    Write-Warning "Windows MSVC strict validation failed. Logs were written to $logsDir."
    if ($Strict) {
        End-Phase "probe"
        Publish-LogsArtifact -LogsDir $logsDir -LogsArtifactRoot $logsArtifactRoot
        exit $validationExit
    }
}

End-Phase "probe"
Publish-LogsArtifact -LogsDir $logsDir -LogsArtifactRoot $logsArtifactRoot
exit 0
