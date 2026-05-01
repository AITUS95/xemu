# xemu MSVC branch

This branch carries Windows/MSVC build integration for xemu while preserving the
normal QEMU/xemu Meson and Ninja build flow. Visual Studio is used as the
Windows toolchain provider and can also be used as a frontend for build, debug,
and profiling workflows.

The supported Windows path uses `clang-cl` with the MSVC ABI, the MSVC linker,
and the MSVC runtime. It is not a pure `cl.exe` port, and pure `cl.exe`
compatibility is not promised unless it is explicitly tested. Native PDB files
are produced by the MSVC-compatible toolchain; this branch must not rely on
`cv2pdb`.

For general project information, visit <https://xemu.app>.

## MSVC Status

The MSVC workflow supports three x64 configurations:

- `Debug`: low optimization, debug-oriented build.
- `Profile`: optimized build with native symbols for Visual Studio Performance
  Profiler, GitHub Copilot Profiler, WPA, VTune, and similar tools.
- `Release`: optimized runtime build.

Artifacts are written under:

- `msvc-artifacts/debug`
- `msvc-artifacts/profile`
- `msvc-artifacts/release`

Build logs are written under `msvc-probe-logs` and packaged CI-style logs under
`xemu-msvc-logs`.

Runtime validation that actually exercises emulation requires user-provided
BIOS, ROM, disk images, or test payloads. Those assets are not included in this
repository. A successful build proves configure, compile, link, packaging, and
PDB generation; full runtime validation is a separate manual step.

## Prerequisites

Install these manually before building on Windows:

- Visual Studio 2022 or Build Tools for Visual Studio with the C++ x64 tools.
- C++ Clang tools for Windows, providing `clang-cl.exe`.
- Windows SDK, providing `rc.exe` and `midl.exe`.
- Git for Windows, providing `git.exe`, `bash.exe`, and `sh.exe`.
- Python 3 available as `python.exe`.

The local wrapper can prepare these inside the repository:

- `.venv-msvc` with Meson and Ninja.
- `.vcpkg-tool` as a standalone vcpkg checkout when no standalone vcpkg is
  already available.
- `.vcpkg-downloads` for vcpkg downloads.
- `.vcpkg-binary-cache` for vcpkg binary packages.
- vcpkg packages needed by the build: `pkgconf`, `glib`, `pixman`, `libepoxy`,
  `libsamplerate`, and `vulkan-headers`.

The vcpkg copy bundled inside Visual Studio is not used because it may not
support classic mode installs. Use a standalone vcpkg checkout through
`VCPKG_ROOT`, `VCPKG_INSTALLATION_ROOT`, `vcpkg.exe` on `PATH`, or let
`build-msvc.ps1` bootstrap `.vcpkg-tool`.

## Clone

```powershell
git clone --branch MSVC https://github.com/AITUS95/xemu.git
cd xemu
git submodule update --init --recursive
```

## Simple Local Build

From the repository root:

```powershell
.\build-msvc.ps1
```

The default builds `Release`. To choose a configuration:

```powershell
.\build-msvc.ps1 -Config Debug
.\build-msvc.ps1 -Config Profile
.\build-msvc.ps1 -Config Release
.\build-msvc.ps1 -Config All
```

The wrapper prepares local Python tools and standalone vcpkg when possible, then
delegates to `scripts\ci\windows-msvc-probe.ps1`. It does not create a second
build system.

Useful local commands:

```powershell
.\build-msvc.ps1 -CheckOnly
.\build-msvc.ps1 -BootstrapVcpkg -CheckOnly
.\build-msvc.ps1 -Config Release -Rebuild
.\build-msvc.ps1 -Clean
.\build-msvc.ps1 -Config Release -CleanIntermediates
.\build-msvc.ps1 -Config Release -CleanAll
.\build-msvc.ps1 -Config Release -KeepBuildTree
```

`-CheckOnly` verifies and prepares the local wrapper environment without
configuring or compiling xemu. `-Rebuild` removes the selected configuration's
generated outputs before building. `-Clean` removes generated build, artifact,
and log outputs and exits.

## Cleanup

Final runnable packages live in `msvc-artifacts/<config>`.

Generated build trees and logs are intermediate data:

- `build-msvc`
- `build-msvc-debug`
- `build-msvc-profile`
- `build-msvc-release`
- `msvc-probe-logs`
- `xemu-msvc-logs`

Reusable caches speed up future builds:

- `.venv-msvc`
- `.vcpkg-tool`
- `.vcpkg-downloads`
- `.vcpkg-binary-cache`

After a successful build, `-CleanIntermediates` removes build trees and logs but
keeps `msvc-artifacts/<config>` and does not remove artifacts from other
configurations. `-CleanAll` also removes reusable local caches, which saves disk
space but makes the next build slower. `-KeepBuildTree` keeps the build tree for
debugging even when cleanup switches are present.

Cleanup never removes source files, tracked configuration files, Visual Studio
JSON files, or runtime assets supplied by the user.

## Advanced Build Script

The lower-level CI/probe script remains available for diagnostics:

```powershell
.\scripts\ci\windows-msvc-probe.ps1 `
  -Architecture amd64 `
  -QemuCpu x86_64 `
  -BuildDir build-msvc-profile `
  -BuildScope full `
  -BuildConfig profile
```

The accepted build scopes are:

- `deps`: install vcpkg dependencies and write dependency/cache diagnostics.
- `fast`: configure and compile the smallest useful probe target.
- `core`: compile a broader core target.
- `full`: build and package the emulator artifact.

Use `-Strict` when CI-style validation should fail the script on missing required
build outputs, invalid PDB state, or strict runtime-validation failures.

## Visual Studio Project

Open `xemu-msvc.vcxproj` directly in Visual Studio. It is a Makefile/NMake
wrapper project; Meson and Ninja remain the real build system.

Select one of:

- `Debug|x64`
- `Profile|x64`
- `Release|x64`

Then use the normal Build, Rebuild, or Clean commands. Visual Studio calls
`build-msvc.ps1`, so a first build after a clean clone can prepare the local
Python tools and standalone vcpkg automatically. Artifacts are written under
`msvc-artifacts/<config>`.

## Visual Studio Open Folder

You can also use `File > Open > Folder` and select the cloned repository root.
The repository includes portable Open Folder configuration:

- `tasks.vs.json`: build, rebuild, clean, environment check, and vcpkg bootstrap
  tasks that call `build-msvc.ps1`.
- `launch.vs.json`: launch targets for `msvc-artifacts/debug/xemu.exe`,
  `msvc-artifacts/profile/xemu.exe`, and `msvc-artifacts/release/xemu.exe`.
  Arguments are empty because runtime assets are user-provided.
- `CppProperties.json`: IntelliSense configuration for MSVC x64 and clang-cl
  parsing. Some generated include directories do not exist before the first
  configure, so transient IntelliSense errors before the first build are normal.

For profiling, build `xemu MSVC Profile`, then launch or profile the `xemu MSVC
Profile` target. It points to `msvc-artifacts/profile/xemu.exe`.

## GitHub Actions

The Windows MSVC workflow has one dependency warm-up job and parallel
Debug/Profile/Release build jobs. The dependency job warms the standalone vcpkg
tool, downloads, binary cache, and package cache with a stable cache key based on
the files that actually affect dependencies. The build jobs restore that cache
and then run in parallel.

A first cold run can still spend significant time populating vcpkg. Later runs
should spend much less time in `vcpkg dependency install`. Inspect
`msvc-probe-logs/phase-timings.log` and `msvc-probe-logs/vcpkg-cache.log` in the
`logs` artifact to verify cache behavior.

## Troubleshooting

`Visual Studio C++ tools were not found`

Install Visual Studio 2022 or Build Tools for Visual Studio with the C++ x64
toolchain.

`clang-cl.exe was not found`

Install the C++ Clang tools for Windows component in Visual Studio.

`cl.exe was not found`

Install the MSVC C++ build tools. The scripts import the Visual Studio build
environment automatically.

`link.exe` resolves to Git for Windows

Git also ships a `link.exe` under `usr\bin`. The probe imports the Visual Studio
environment first, then adds Git for Windows while keeping MSVC `link.exe`
ahead of Git's linker shim. The probe still fails if `link.exe` does not resolve
to the MSVC linker.

`rc.exe` or `midl.exe was not found`

Install a Windows SDK through Visual Studio Installer.

`bash.exe` or `sh.exe was not found`

Install Git for Windows and ensure command-line tools are available. The scripts
search common Git for Windows install roots and the root discovered from
`git.exe`; no personal or absolute repository path is required.

`python.exe was not found`

Install Python 3 and enable the PATH option, or run from a shell where
`python.exe` is already available.

Meson or Ninja errors

Use `build-msvc.ps1`; it creates `.venv-msvc` and installs Meson/Ninja there.
Then inspect `msvc-probe-logs/meson-version.log`, `ninja-version.log`,
`configure-output.log`, and `build-output.log`.

`vcpkg.exe was not found`

Run `.\build-msvc.ps1 -BootstrapVcpkg -CheckOnly`, set `VCPKG_ROOT` to a
standalone vcpkg checkout, or put a standalone `vcpkg.exe` on `PATH`.

Visual Studio bundled vcpkg is rejected

Use a standalone vcpkg checkout. The bundled Visual Studio vcpkg can report that
it has no classic mode instance.

Paths with spaces

The scripts quote repository paths. If a third-party tool fails on a path with
spaces, retry from a shorter clone path and report the failing command from
`msvc-probe-logs`.

Missing PDB files

Debug and Profile builds are expected to package native PDB files. Check
`msvc-artifacts/<config>` and `msvc-probe-logs/status.txt`. Release artifacts may
not package a final xemu PDB unless the release validation mode requires it.

Missing DLLs

The packaging step copies known runtime DLLs from vcpkg when the final
executable is found. If runtime launch fails, check `msvc-artifacts/<config>` and
`msvc-probe-logs/artifact-layout.log`.

Artifacts not generated

Check `configure_exit_code`, `build_exit_code`, and `packaged_artifact` in
`msvc-probe-logs/status.txt`, then inspect `configure-output.log` and
`build-output.log`.

Visual Studio IntelliSense errors before the first build

Generated Meson headers do not exist until configure has completed. Run a Debug,
Profile, or Release build once, then reload IntelliSense if needed.

Workflow is slow on a cold cache

Check `phase-timings.log` and `vcpkg-cache.log`. The first run may populate
vcpkg downloads and binary packages; later runs should restore the stable cache.

## Known Limitations

- Runtime validation that exercises the emulator requires user-provided BIOS,
  ROM, disk images, or test payloads. These assets are not included in the repo.
- A successful compile/link does not automatically prove full runtime behavior.
  Treat runtime validation separately from build validation.
- This branch targets `clang-cl` with the MSVC ABI. It is not a guarantee that
  every source file is accepted by pure `cl.exe`.
- Some third-party or system DLL symbols may need Microsoft symbol server or
  locally downloaded PDBs for complete profiler call stacks.
