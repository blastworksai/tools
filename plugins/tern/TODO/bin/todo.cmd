@echo off
powershell -NoProfile -File "%~dp0todo.ps1" %*
if errorlevel 1 exit /b 1
exit /b 0
