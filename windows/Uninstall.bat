@echo off
setlocal
title Uninstall NOTCH
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0resources\app\native\uninstall.ps1"
pause
exit /b 0
