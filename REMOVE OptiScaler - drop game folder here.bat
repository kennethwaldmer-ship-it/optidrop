@echo off
REM Drag a game folder onto this file to remove OptiScaler from it.
if "%~1"=="" (
  echo Drag a GAME FOLDER onto this file.
  echo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Add-OptiScaler.ps1" "%~1" -Uninstall
echo.
pause
