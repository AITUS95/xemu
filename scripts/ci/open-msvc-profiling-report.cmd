@echo off
setlocal
for %%I in ("%~dp0.") do set "SCRIPT_DIR=%%~fI"
set "XEMU_SYMBOL_CACHE=%LOCALAPPDATA%\xemu\symbols"
set "_NT_SYMBOL_PATH=%SCRIPT_DIR%;srv*%XEMU_SYMBOL_CACHE%*https://msdl.microsoft.com/download/symbols;%_NT_SYMBOL_PATH%"

set "REPORT=%~1"
if "%REPORT%"=="" (
  for /f "delims=" %%F in ('dir /b /a:-d /o:-d "%SCRIPT_DIR%\*.diagsession" 2^>nul') do (
    set "REPORT=%SCRIPT_DIR%\%%F"
    goto :found_report
  )
)
:found_report

if "%REPORT%"=="" (
  echo No .diagsession file found. Pass the report path as the first argument.
  exit /b 1
)

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo vswhere.exe not found.
  exit /b 1
)

for /f "usebackq delims=" %%V in (`"%VSWHERE%" -latest -property installationPath`) do set "VSINSTALL=%%V"
if "%VSINSTALL%"=="" (
  echo Visual Studio installation not found.
  exit /b 1
)

set "DEVENV=%VSINSTALL%\Common7\IDE\devenv.exe"
if not exist "%DEVENV%" (
  echo devenv.exe not found at "%DEVENV%".
  exit /b 1
)

echo _NT_SYMBOL_PATH=%_NT_SYMBOL_PATH%
echo Opening "%REPORT%"
start "" "%DEVENV%" "%REPORT%"
