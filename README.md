# xemu MSVC branch

This branch carries Windows/MSVC build integration for xemu. The normal
QEMU/xemu Meson and Ninja build flow is preserved; Visual Studio is used as the
Windows toolchain provider and, optionally, as a frontend for build, debug, and
profiling workflows.

The Windows build uses `clang-cl` with the MSVC ABI and MSVC linker/runtime. It
is not intended to be a pure `cl.exe` port. Native PDB generation is handled by
the MSVC-compatible toolchain and must not rely on `cv2pdb`.

For general project information, visit <https://xemu.app>.

## Current MSVC Status

The MSVC workflow supports three x64 configurations:

- `debug`: low optimization, debug-oriented build.
- `profile`: optimized build intended for Visual Studio Performance Profiler,
  GitHub Copilot Profiler, WPA, VTune, and similar tools.
- `release`: optimized runtime build.

Artifacts are written under:

- `msvc-artifacts/debug`
- `msvc-artifacts/profile`
- `msvc-artifacts/release`

Build logs are written under `msvc-probe-logs` and packaged logs under
`xemu-msvc-logs`.

## Prerequisites

Install these tools before building on Windows:

- Visual Studio 2022 or Build Tools for Visual Studio with C++ x64 tools.
- C++ Clang tools for Windows, providing `clang-cl.exe`.
- Windows SDK, providing `rc.exe` and `midl.exe`.
- MSVC linker, providing `link.exe`.
- Git for Windows, providing `bash.exe` and `sh.exe`.
- Python 3 available as `python.exe`.
- vcpkg available through one of:
  - `VCPKG_ROOT`
  - `VCPKG_INSTALLATION_ROOT`
  - `vcpkg.exe` on `PATH`
  - `C:\vcpkg` as a convenience fallback for common CI images.

The build script installs or updates Meson and Ninja through Python/pip when it
runs. You can preinstall them, but the scripted path is the supported one.

## Clone

```powershell
git clone --branch MSVC https://github.com/AITUS95/xemu.git
cd xemu
git submodule update --init --recursive
```

If vcpkg is not on `PATH`, set one of the supported environment variables:

```powershell
$env:VCPKG_ROOT = "<path-to-vcpkg>"
```

Do not hardcode this value in the repository. Keep it in your shell, user
environment, or CI configuration.

## Build From PowerShell

Run PowerShell from the repository root.

Build one configuration:

```powershell
.\scripts\ci\windows-msvc-probe.ps1 `
  -Architecture amd64 `
  -QemuCpu x86_64 `
  -BuildDir build-msvc-profile `
  -BuildScope full `
  -BuildConfig profile
```

Build all three configurations:

```powershell
foreach ($config in @("debug", "profile", "release")) {
  .\scripts\ci\windows-msvc-probe.ps1 `
    -Architecture amd64 `
    -QemuCpu x86_64 `
    -BuildDir "build-msvc-$config" `
    -BuildScope full `
    -BuildConfig $config
}
```

Use `-Strict` when you want CI-style validation to fail on missing required
build outputs or invalid PDB state:

```powershell
.\scripts\ci\windows-msvc-probe.ps1 `
  -Architecture amd64 `
  -QemuCpu x86_64 `
  -BuildDir build-msvc-profile `
  -BuildScope full `
  -BuildConfig profile `
  -Strict
```

## Build From Visual Studio Project

Open `xemu-msvc.vcxproj` directly in Visual Studio. It is a Makefile/NMake
wrapper project. It does not replace Meson or Ninja; it delegates Build, Rebuild,
and Clean to `scripts\ci\windows-msvc-probe.ps1`.

Select one of:

- `Debug|x64`
- `Profile|x64`
- `Release|x64`

Then use the normal Visual Studio Build, Rebuild, or Clean commands. The project
uses relative paths only and writes artifacts under `msvc-artifacts/<config>`.

## Visual Studio Open Folder

You can also use `File > Open > Folder` and select the cloned repository root.
The repository includes portable Open Folder configuration:

- `tasks.vs.json`: build, rebuild, and clean tasks that call the same MSVC probe
  script used by the `.vcxproj`.
- `launch.vs.json`: launch targets for the generated Debug, Profile, and Release
  artifacts. Arguments are intentionally empty because BIOS, ROM, HDD images, and
  other runtime assets are user-provided and are not redistributable.
- `CppProperties.json`: IntelliSense configuration for MSVC x64/clang-cl style
  parsing. Some generated include directories will not exist before the first
  build; Visual Studio may show transient IntelliSense errors until configure
  has generated them.

For profiling, build `xemu MSVC Profile`, then launch or profile the `xemu MSVC
Profile` target. This target points to `msvc-artifacts/profile/xemu.exe`.

## Clean and Rebuild

From Visual Studio, use Clean or Rebuild on the active `.vcxproj` configuration,
or run the Open Folder task `xemu MSVC Clean`.

From PowerShell:

```powershell
$paths = @(
  "build-msvc",
  "build-msvc-debug",
  "build-msvc-profile",
  "build-msvc-release",
  "msvc-artifacts",
  "msvc-probe-logs",
  "xemu-msvc-logs"
)
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $paths
```

The clean commands only target generated MSVC build, artifact, and log
directories.

## vcpkg

The build script installs these dependencies through vcpkg as needed:

- `pkgconf`
- `glib`
- `pixman`
- `libepoxy`
- `libsamplerate`
- `vulkan-headers` for full builds

The script looks for vcpkg using `VCPKG_ROOT`, `VCPKG_INSTALLATION_ROOT`,
`vcpkg.exe` on `PATH`, then the CI-friendly fallback `C:\vcpkg`. Prefer an
environment variable for local machines.

## Troubleshooting

`clang-cl.exe was not found`

Install the C++ Clang tools for Windows component in Visual Studio.

`cl.exe was not found`

Install the MSVC C++ build tools. The script imports `vcvarsall.bat`
automatically, so you do not need to start from a Developer Command Prompt.

`link.exe` resolves to Git for Windows

Git also ships a `link.exe` under `usr\bin`. The script imports the Visual Studio
environment first and fails if the Git linker shim is first on `PATH`.

`rc.exe` or `midl.exe was not found`

Install a Windows SDK through Visual Studio Installer.

`bash.exe` or `sh.exe was not found`

Install Git for Windows and ensure its command-line tools are available.

`python.exe was not found`

Install Python 3 and enable the PATH option, or run the script from a shell where
`python.exe` is already available.

Meson or Ninja errors

The script installs Meson and Ninja through `python -m pip`. Check
`msvc-probe-logs/meson-version.log`, `ninja-version.log`, `configure-output.log`,
and `build-output.log`.

`vcpkg.exe was not found`

Set `VCPKG_ROOT` or `VCPKG_INSTALLATION_ROOT`, or put `vcpkg.exe` on `PATH`.

Paths with spaces

The script and Visual Studio files quote repository paths. If a third-party tool
fails on a path with spaces, retry from a shorter clone path and report the
failing command from `msvc-probe-logs`.

Missing PDB files

Debug and Profile builds are expected to produce native PDB files beside or
packaged with the final executable. Check `msvc-artifacts/<config>` and
`msvc-probe-logs/status.txt`.

Missing DLLs

The packaging step copies known runtime DLLs from vcpkg when the final
executable is found. If runtime launch fails, check `msvc-artifacts/<config>` and
the package log under `xemu-msvc-logs`.

Artifacts not generated

Check `configure_exit_code`, `build_exit_code`, and `packaged_artifact` in
`msvc-probe-logs/status.txt`, then inspect `build-output.log`.

Visual Studio IntelliSense errors before the first build

Generated Meson headers do not exist until configure has completed. Run a Debug,
Profile, or Release build once, then reload IntelliSense if needed.

## Known Limitations

- Runtime validation that exercises the emulator requires user-provided BIOS,
  ROM, disk images, or test payloads. These assets are not included in the repo.
- A successful compile/link does not automatically prove full runtime behavior.
  Treat runtime validation separately from build validation.
- This branch targets `clang-cl` with the MSVC ABI. It is not a guarantee that
  every source file is accepted by pure `cl.exe`.
- Some third-party or system DLL symbols may need Microsoft symbol server or
  locally downloaded PDBs for complete profiler call stacks.
