@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "XEMU_SYMBOL_CACHE=%LOCALAPPDATA%\xemu\symbols"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%fetch-msvc-system-symbols.ps1" -OutputDir "%SCRIPT_DIR%" -SymbolCache "%XEMU_SYMBOL_CACHE%" %*
exit /b %ERRORLEVEL%
