Please visit [https://xemu.app](https://xemu.app) for more information.

## Visual Studio Open Folder MSVC workflow

Open Microsoft Visual Studio and use `File > Open > Folder`, then select this
repository folder, for example `C:\Users\daddy\Desktop\xemu`.

Visual Studio reads the portable Open Folder configuration in the repository
root. Use the `xemu MSVC Profile` task to build the MSVC/clang-cl profile
configuration through `scripts\ci\windows-msvc-probe.ps1`. After the task
finishes, choose the `xemu MSVC Profile` startup target to run, debug, or profile
`msvc-artifacts\profile\xemu.exe` with Visual Studio Performance Profiler or
GitHub Copilot Profiler. Debug and release startup targets are also available
for `msvc-artifacts\debug\xemu.exe` and `msvc-artifacts\release\xemu.exe`.
