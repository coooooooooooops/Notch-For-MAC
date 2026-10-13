@echo off
setlocal
title Install NOTCH
cd /d "%~dp0"
if not exist "%~dp0NOTCH.exe" (
  echo NOTCH.exe was not found next to Install.bat.
  echo Unzip the whole download first, then run Install.bat again.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0resources\app\native\install.ps1" -Root "%~dp0"
if errorlevel 1 (
  echo.
  echo Install failed - see the message above.
  pause
  exit /b 1
)
timeout /t 4 >nul
exit /b 0
