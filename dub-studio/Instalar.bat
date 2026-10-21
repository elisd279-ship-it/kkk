@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\windows.ps1" -Launch
if errorlevel 1 (
  echo.
  echo No se pudo completar la instalacion. Revisa el mensaje anterior.
  echo Registro: %LOCALAPPDATA%\DUBStudio\install.log
  pause
  exit /b 1
)
endlocal
