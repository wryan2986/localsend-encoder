@echo off
setlocal
set "PYTHON_EXE=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
if exist "%PYTHON_EXE%" goto :ffmpeg
python -c "import tkinter, venv; assert __import__('sys').version_info >= (3, 9)" >nul 2>&1
if not errorlevel 1 goto :use_system_python
py -3.12 -c "import tkinter, venv" >nul 2>&1
if not errorlevel 1 goto :ffmpeg
where winget >nul 2>&1
if errorlevel 1 goto :missing
winget install --exact --id Python.Python.3.12 --source winget --scope user
if errorlevel 1 goto :failed

goto :ffmpeg

:use_system_python
set "PYTHON_EXE=python"

:ffmpeg
set "PATH=%LOCALAPPDATA%\Microsoft\WinGet\Links;%PATH%"
where ffmpeg >nul 2>&1
if errorlevel 1 goto :install_ffmpeg
where ffprobe >nul 2>&1
if not errorlevel 1 goto :install_app

:install_ffmpeg
where winget >nul 2>&1
if errorlevel 1 goto :missing
winget install --exact --id Gyan.FFmpeg --source winget --scope user
if errorlevel 1 goto :failed

:install_app
if "%PYTHON_EXE%"=="python" goto :use_path
if exist "%PYTHON_EXE%" goto :use_path
py -3.12 "%~dp0install-desktop.py"
if errorlevel 1 goto :failed
exit /b 0

:use_path
"%PYTHON_EXE%" "%~dp0install-desktop.py"
if errorlevel 1 goto :failed
exit /b 0

:missing
echo Install WinGet from Microsoft App Installer, or install Python 3.12 with Tk and FFmpeg manually.
exit /b 1

:failed
echo Installation did not finish. See the messages above.
exit /b 1
