@echo off
python "%~dp0msvc-cl-wrapper.py" cl.exe %*
exit /b %ERRORLEVEL%
