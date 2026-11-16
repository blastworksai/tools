@echo off
setlocal
set "TODO_PROBE=import sys;print('TODO_PYTHON_3={}.{}'.format(*sys.version_info[:2]));sys.exit(sys.version_info.major != 3)"

set "TODO_PYTHON=py -3"
for /f "tokens=1,2 delims=.=" %%V in ('py -3 -I -c "%TODO_PROBE%" 2^>nul') do if "%%V"=="TODO_PYTHON_3" if "%%W"=="3" goto run_python
set "TODO_PYTHON=python"
for /f "tokens=1,2 delims=.=" %%V in ('python -I -c "%TODO_PROBE%" 2^>nul') do if "%%V"=="TODO_PYTHON_3" if "%%W"=="3" goto run_python
set "TODO_PYTHON=python3"
for /f "tokens=1,2 delims=.=" %%V in ('python3 -I -c "%TODO_PROBE%" 2^>nul') do if "%%V"=="TODO_PYTHON_3" if "%%W"=="3" goto run_python
endlocal & exit /b 1

:run_python
%TODO_PYTHON% -I "%~dp0todo.py" %*
if errorlevel 1 (endlocal & exit /b 1)
endlocal & exit /b 0
