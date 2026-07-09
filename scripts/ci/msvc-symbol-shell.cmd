@echo off
setlocal
for %%I in ("%~dp0.") do set "SCRIPT_DIR=%%~fI"
set "XEMU_SYMBOL_CACHE=%LOCALAPPDATA%\xemu\symbols"
set "_NT_SYMBOL_PATH=%SCRIPT_DIR%;srv*%XEMU_SYMBOL_CACHE%*https://msdl.microsoft.com/download/symbols;%_NT_SYMBOL_PATH%"
echo _NT_SYMBOL_PATH=%_NT_SYMBOL_PATH%
echo.
echo Run fetch-msvc-system-symbols.cmd once to place Windows system PDBs next to xemu.exe.
echo Start Visual Studio from this shell if you want the profiler to inherit this symbol path.
echo.
cmd /k
