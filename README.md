# xemu (MSVC + cl)

This fork carries the Windows/MSVC build integration from the `MSVC` branch.
Its build documentation combines the guidance previously maintained on
`MSVC` and `improve`, while preserving the normal QEMU/xemu Meson and Ninja
build flow and providing native build paths for Windows, Linux, and macOS.

Visual Studio can be used as the Windows toolchain provider and as a frontend
for build, debug, and profiling workflows.

The supported Windows path uses `clang-cl` with the MSVC ABI, the MSVC linker,
and the MSVC runtime. It is not a pure `cl.exe` port, and pure `cl.exe`
compatibility is not promised unless it is explicitly tested. Native PDB files
are produced by the MSVC-compatible toolchain; that build route does not rely
on `cv2pdb`.

For general project information, visit <https://xemu.app>.

## Windows: Visual Studio and MSVC

### MSVC Status

The local MSVC integration supports three x64 configurations:

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

### Prerequisites

Install these manually before building on Windows:

- Visual Studio 2026 or Build Tools for Visual Studio 2026 with the C++ x64 tools.
- C++ Clang tools for Windows, providing `clang-cl.exe` and LLVM utilities such
  as `llvm-objcopy.exe`.
- Windows SDK, providing `rc.exe` and `midl.exe`.
- Git for Windows, providing `git.exe`, `bash.exe`, and `sh.exe`.
- Python 3 available as `python.exe`.

The local wrapper can prepare these inside the repository:

- `.venv-msvc` with Meson and Ninja.
- `.vcpkg-tool` as a standalone vcpkg checkout when no standalone vcpkg is
  already available.
- `.vcpkg-downloads` for vcpkg downloads.
- `.vcpkg-binary-cache` for vcpkg binary packages.
- `.msvc-mingw-cache` for the MSYS2 MinGW GCC package used to provide
  `libgcc_eh.a` for the prebuilt `dsp56300` archive.
- vcpkg packages needed by the build: `pkgconf`, `glib`, `pixman`, `libepoxy`,
  `libsamplerate`, `libslirp`, and `vulkan-headers`.

The vcpkg copy bundled inside Visual Studio is not used because it may not
support classic mode installs. Use a standalone vcpkg checkout through
`VCPKG_ROOT`, `VCPKG_INSTALLATION_ROOT`, `vcpkg.exe` on `PATH`, or let
`build-msvc.ps1` bootstrap `.vcpkg-tool`.

### Clone

```powershell
git clone --recursive https://github.com/AITUS95/xemu.git
cd xemu
git submodule update --init --recursive
```

### Simple Local Build

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

Normal local builds are incremental. The first build creates the selected
Meson/Ninja build tree:

- `Debug` -> `build-msvc-debug`
- `Profile` -> `build-msvc-profile`
- `Release` -> `build-msvc-release`

Later builds reuse that build tree when the MSVC configuration marker still
matches the selected architecture, QEMU CPU, build scope, vcpkg triplet,
compiler, and configure arguments. The wrapper still runs `meson compile`, so
Ninja decides which files need to be rebuilt. It never skips compilation just
because `msvc-artifacts/<config>/xemu.exe` already exists.

The MSVC compiler wrapper forwards `clang-cl` dependency-generation flags so
Ninja tracks included headers, not only the compiled source file. When the
wrapper itself changes, `build-msvc.ps1` invalidates object files, depfiles, and
Ninja dependency state for the affected build tree once, then stamps the wrapper
hash. This keeps later incremental builds reliable after shared header changes
without requiring a manual Visual Studio Rebuild.

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
build tree and artifacts before building from zero. `-Clean` removes generated
outputs for the selected configuration and exits. A plain build without
`-Rebuild`, `-CleanIntermediates`, or `-CleanAll` preserves the build tree and
is the path to use while editing source files.

### Cleanup

Final runnable packages live in `msvc-artifacts/<config>`.

Generated build trees are the state required for incremental local builds:

- `build-msvc`
- `build-msvc-debug`
- `build-msvc-profile`
- `build-msvc-release`

Logs are regenerated on each build:

- `msvc-probe-logs`
- `xemu-msvc-logs`

Reusable caches speed up future builds:

- `.venv-msvc`
- `.vcpkg-tool`
- `.vcpkg-downloads`
- `.vcpkg-binary-cache`
- `.msvc-mingw-cache`

After a successful build, `-CleanIntermediates` removes build trees and logs but
keeps `msvc-artifacts/<config>` and does not remove artifacts from other
configurations. Use it only when you explicitly want to free disk space: the
next build of that configuration must configure again and will not be fully
incremental. `-CleanAll` also removes reusable local caches, which saves more
disk space but makes the next build slower. `-KeepBuildTree` keeps the build
tree for debugging even when cleanup switches are present.

Cleanup never removes source files, tracked configuration files, Visual Studio
JSON files, or runtime assets supplied by the user.

### Advanced Build Script

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
The probe reuses an existing valid build tree when its generated
`.msvc-build-config.json` marker matches the current configuration. Pass
`-CleanBuild` to the probe only when intentionally discarding that build tree.

### Visual Studio Project

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

Visual Studio Build is incremental and preserves `build-msvc-<config>`.
Visual Studio Rebuild passes `-Rebuild` and intentionally recreates only the
selected configuration. Visual Studio Clean passes `-Clean` and removes only the
selected configuration's generated outputs.

### Visual Studio Open Folder

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

The Open Folder Build Debug/Profile/Release tasks are incremental. Rebuild tasks
are separate and pass `-Rebuild`. Clean tasks are available per configuration,
with `xemu MSVC Clean All` kept as an explicit full generated-output cleanup.

### GitHub Actions

The Windows MSVC workflow targets GitHub's `windows-2025-vs2026` image, with
one dependency warm-up job and parallel Debug/Release build jobs. The
dependency job warms the standalone vcpkg
tool, downloads, binary cache, and package cache with a stable cache key based on
the files that actually affect dependencies. The build jobs restore that cache
and then run in parallel.

A first cold run can still spend significant time populating vcpkg. Later runs
should spend much less time in `vcpkg dependency install`. Inspect
`msvc-probe-logs/phase-timings.log` and `msvc-probe-logs/vcpkg-cache.log` in the
`logs` artifact to verify cache behavior.

### Troubleshooting

`Visual Studio C++ tools were not found`

Install Visual Studio 2026 or Build Tools for Visual Studio 2026 with the C++ x64
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

`configure_exit_code=0` but no compile output was produced

Inspect `msvc-probe-logs/phase-timings.log`. A valid full build should contain
a `meson compile full` phase and `msvc-probe-logs/build-output.log`. If Meson's
per-build `pyvenv` is missing, the probe falls back to `.venv-msvc` or another
Python that has Meson installed instead of silently skipping compile.

`vcpkg.exe was not found`

Run `.\build-msvc.ps1 -BootstrapVcpkg -CheckOnly`, set `VCPKG_ROOT` to a
standalone vcpkg checkout, or put a standalone `vcpkg.exe` on `PATH`.

vcpkg bootstrap or clone fails

The local wrapper can clone vcpkg into `.vcpkg-tool` and run
`bootstrap-vcpkg.bat`. Normal Git clone progress may appear on stderr and is
not treated as failure; only the native command exit code is authoritative. If
bootstrap really fails, check internet access, Git for Windows,
proxy/firewall settings, Visual Studio C++ tools, Windows SDK, and antivirus
restrictions.

Visual Studio bundled vcpkg is rejected

Use a standalone vcpkg checkout. The bundled Visual Studio vcpkg can report that
it has no classic mode instance.

`libgcc_eh.a was not found`

The prebuilt `dsp56300` archive targets `x86_64-pc-windows-gnu` and needs the
MinGW GCC unwind library when linked into the MSVC build. `build-msvc.ps1`
downloads a pinned MSYS2 MinGW GCC package into `.msvc-mingw-cache`, verifies
its SHA256, and extracts the required archive. If this fails, check internet
access, proxy/firewall settings, Windows `tar.exe` support for `.zst` archives,
or provide an existing MinGW install with `MINGW_PREFIX`, `LIBGCC_EH`, or
`LIBGCC_EH_PATH`.

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

### Known Limitations

- Runtime validation that exercises the emulator requires user-provided BIOS,
  ROM, disk images, or test payloads. These assets are not included in the repo.
- A successful compile/link does not automatically prove full runtime behavior.
  Treat runtime validation separately from build validation.
- This route targets `clang-cl` with the MSVC ABI. It is not a guarantee that
  every source file is accepted by pure `cl.exe`.
- Some third-party or system DLL symbols may need Microsoft symbol server or
  locally downloaded PDBs for complete profiler call stacks.

## Windows: MSYS2 and MinGW

MSYS2/MinGW is an alternative native Windows route inherited from the
`improve` branch. It produces DWARF symbols; use `cv2pdb` only for this
route when a PDB is needed. Do not run `cv2pdb` on artifacts produced by the
MSVC route above.

Use the **MSYS2 MINGW64** shell. PowerShell's `bash.exe` is usually WSL and is
not sufficient for a native MinGW build.

1. Install MSYS2 from <https://www.msys2.org/>.
2. Open **MSYS2 MINGW64**.
3. Install the build dependencies:

```sh
pacman --noconfirm -Syu
pacman --noconfirm --needed -S \
  base-devel git make diffutils python python-pip python-setuptools \
  python-packaging python-yaml python-mako ninja \
  mingw-w64-x86_64-toolchain \
  mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-meson \
  mingw-w64-x86_64-ninja \
  mingw-w64-x86_64-python \
  mingw-w64-x86_64-python-yaml \
  mingw-w64-x86_64-pkgconf \
  mingw-w64-x86_64-glib2 \
  mingw-w64-x86_64-pixman \
  mingw-w64-x86_64-sdl3 \
  mingw-w64-x86_64-libepoxy \
  mingw-w64-x86_64-libusb \
  mingw-w64-x86_64-curl \
  mingw-w64-x86_64-libslirp \
  mingw-w64-x86_64-libsamplerate \
  mingw-w64-x86_64-openssl \
  mingw-w64-x86_64-vulkan-headers
```

Clone and initialize the repository:

```sh
cd /e
git clone --recursive https://github.com/AITUS95/xemu.git xemu
cd /e/xemu
git submodule update --init --recursive --jobs 8
```

If the initial clone is interrupted while fetching submodules, rerun the
`git submodule update --init --recursive --jobs 8` command from the repository
root.

Build xemu:

```sh
# Release-style local build with the Vulkan backend required
./build.sh --enable-vulkan

# Debug build
./build.sh --debug --enable-vulkan

# Incremental rebuild with the same configuration options as the first build
./build.sh --skip-configure
```

The packaged executable and DLLs are written to `dist/`; the main binary is
`dist/xemu.exe`. The unbundled binary is `build/qemu-system-i386w.exe`.

To convert DWARF debug information from a MinGW debug or profiling build to a
PDB, download `cv2pdb` and run it against the matching executable:

```powershell
New-Item -ItemType Directory -Force -Path .codex-build-tools | Out-Null
Invoke-WebRequest `
  -Uri "https://github.com/rainers/cv2pdb/releases/download/v0.54/cv2pdb-0.54.zip" `
  -OutFile ".codex-build-tools\cv2pdb-0.54.zip"
Expand-Archive `
  -Path ".codex-build-tools\cv2pdb-0.54.zip" `
  -DestinationPath ".codex-build-tools\cv2pdb" `
  -Force
.\.codex-build-tools\cv2pdb\cv2pdb64.exe .\dist\xemu.exe
```

This writes `dist/xemu.pdb` next to `dist/xemu.exe`. Keep the PDB and
executable from the same build together. Running `cv2pdb` again on an
already-converted executable can fail with `no debug entries found`; rebuild
or repackage first when a new PDB is required.

Notes:

- Use `mingw-w64-x86_64-sdl3`, not the older SDL2 package.
- `cmake` is required because several graphics subprojects use Meson/CMake
  fallback projects.
- `build.sh` sets `TAR_OPTIONS=--force-local` under MSYS/MinGW so GNU tar
  treats paths such as `E:/xemu/...` as local Windows paths.
- The `--skip-configure` command is only valid while the architecture and all
  configure options are unchanged.

## Linux

The native Linux route uses `build.sh`, Meson, and Ninja. On Debian or Ubuntu,
clone first, enable source repositories if necessary, then install the
repository's declared build dependencies:

```sh
git clone --recursive https://github.com/AITUS95/xemu.git
cd xemu
git submodule update --init --recursive

sudo apt update
sudo apt build-dep .
```

If `apt build-dep .` is unavailable on the distribution, install the
equivalent development packages listed in `debian/control`; in particular the
toolchain, Meson, Ninja, pkg-config, GLib, Pixman, SDL, Epoxy, libslirp,
libsamplerate, libusb, OpenSSL, curl, and Vulkan headers and loader.

Build commands:

```sh
# Release-style local build with Vulkan required
./build.sh --enable-vulkan

# Debug build
./build.sh --debug --enable-vulkan

# Incremental rebuild after a successful configure
./build.sh --skip-configure
```

The package is written to `dist/` and the executable is `dist/xemu`.
Use `--skip-configure` only when the initial configuration options have not
changed. Other distributions can use the same build commands after installing
the equivalent packages through their native package manager.

## macOS

The macOS route uses the Xcode Command Line Tools, Homebrew utilities, and
prebuilt MacPorts libraries downloaded by `build.sh`. Install the Command
Line Tools even when full Xcode is present because the build script locates the
SDK under `/Library/Developer/CommandLineTools/SDKs`.

```sh
xcode-select --install
brew install ccache coreutils dylibbundler
python3 -m pip install --user pyyaml requests
```

Clone and build for the native architecture:

```sh
git clone --recursive https://github.com/AITUS95/xemu.git
cd xemu
git submodule update --init --recursive

# Apple Silicon
./build.sh -a arm64

# Intel Mac
./build.sh -a x86_64

# Incremental rebuild after a successful configure
./build.sh --skip-configure -a <arm64-or-x86_64>
```

The current script requires an SDK of at least macOS 14.0 for `arm64` or
macOS 12.7.5 for `x86_64`. It produces the application bundle at
`dist/xemu.app`.

Vulkan is enabled and required by the Windows and Linux recipes above. The
current source tree does not provide a macOS Vulkan configuration, so macOS
builds use the OpenGL backend. 
