@echo off
cd /d "%~dp0"
where py >nul 2>nul
if errorlevel 1 (
  python app.py --open-browser
) else (
  py -3 app.py --open-browser
)
pause
