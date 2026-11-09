@echo off
setlocal
title Plug'n'Heal Builder
echo Bitte dieses Fenster offen lassen, bis der Helfer fertig ist. / Please keep this window open until the builder has finished.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0builder\Build-Drive.ps1" %*
set "PNH_RC=%ERRORLEVEL%"
endlocal & exit /b %PNH_RC%
