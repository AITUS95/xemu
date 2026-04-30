@echo off
setlocal
for %%I in ("%~dp0.") do set "SCRIPT_DIR=%%~fI"
set "XEMU_SYMBOL_CACHE=%LOCALAPPDATA%\xemu\symbols"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\fetch-msvc-system-symbols.ps1" -OutputDir "%SCRIPT_DIR%" -SymbolCache "%XEMU_SYMBOL_CACHE%" -InstallUserSymbolPath %*
exit /b %ERRORLEVEL%
