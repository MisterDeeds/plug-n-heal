@echo off
rem Plug'n'Heal: the only file a person clicks. It lives in the root of the drive,
rem the program lives in PlugNHeal\app. Keep this file ASCII with CRLF line endings.
rem All logic is in Start.ps1. This window closes as soon as the Plug'n'Heal window is open.
setlocal
title Plug'n'Heal - bitte warten / please wait ...
set "PNH_RC=0"
if exist "%~dp0PlugNHeal\app\Start.ps1" goto drive
if exist "%~dp0Start.ps1" goto source
goto missing

:drive
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlugNHeal\app\Start.ps1"
set "PNH_RC=%ERRORLEVEL%"
goto result

:source
rem Started from the source folder (src\START.cmd next to Start.ps1): for developers.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start.ps1"
set "PNH_RC=%ERRORLEVEL%"
goto result

:result
if "%PNH_RC%"=="0" goto end
rem Codes 20 to 29: Start.ps1 has already explained the problem in its own message.
if %PNH_RC% GEQ 20 if %PNH_RC% LEQ 29 goto end
title Plug'n'Heal
echo.
echo   Plug'n'Heal konnte nicht starten.
echo   Auf diesem Computer sind solche Hilfsprogramme wahrscheinlich gesperrt,
echo   zum Beispiel bei einem Computer von einer Firma oder Schule.
echo   Bitte fragen Sie die Person, die diesen Computer betreut.
echo.
echo   Plug'n'Heal could not start.
echo   This computer probably blocks helper programs like this one,
echo   for example a computer from a company or a school.
echo   Please ask the person who looks after this computer.
echo.
echo   Code: %PNH_RC%
echo.
pause
goto end

:missing
set "PNH_RC=1"
title Plug'n'Heal
echo.
echo   Plug'n'Heal ist unvollstaendig: Der Ordner PlugNHeal fehlt neben dieser Datei.
echo   Das Laufwerk muss neu eingerichtet werden.
echo.
echo   Plug'n'Heal is incomplete: the folder PlugNHeal is missing next to this file.
echo   The drive has to be set up again.
echo.
pause
goto end

:end
endlocal & exit /b %PNH_RC%
