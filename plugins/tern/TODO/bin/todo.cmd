@echo off
where py >nul 2>nul
if errorlevel 1 goto use_python3
py -3 -I "%~dp0todo.py" %*
if errorlevel 1 exit /b 1
exit /b 0
:use_python3
python3 -I "%~dp0todo.py" %*
if errorlevel 1 exit /b 1
exit /b 0
