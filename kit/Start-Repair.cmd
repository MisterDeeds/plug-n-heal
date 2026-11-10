@echo off
title Plug'n'Heal network rescue - local AI agent
fltmc >nul 2>&1
if errorlevel 1 (
  if "%~1"=="elevated" (
    echo This needs administrator rights. Right-click this file and choose "Run as administrator".
    pause
    exit /b 1
  )
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent.ps1"
pause
