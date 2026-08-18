@echo off
setlocal EnableExtensions
title ONS map kiosk - install

rem =====================================================================
rem  install-map.cmd
rem
rem  Double-click this. It asks for administrator rights, then installs
rem  the map kiosk and puts "ONS Map" and "Restore Desktop" on the
rem  desktop. No AutoHotkey, no ini file - the URL lives in one line
rem  inside install-map.ps1.
rem
rem  EDIT THE NEXT LINE ONCE: your GitHub user and repo name.
rem =====================================================================

set "REPO=sidagis/ONS"
set "BRANCH=main"
set "INSTALLDIR=C:\Kiosk\map"

rem ---- become administrator ------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo  Asking for administrator rights...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

rem ---- find the installer script --------------------------------------
set "PS1=%~dp0install-map.ps1"

if exist "%PS1%" (
  rem Running from a cloned or downloaded copy of the repo.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -InstallDir "%INSTALLDIR%"
  goto :done
)

rem Running as a lone downloaded file: fetch the installer first.
set "PS1=%TEMP%\install-map.ps1"
echo.
echo  Fetching the installer from GitHub...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "[Net.ServicePointManager]::SecurityProtocol='Tls12'; try { Invoke-WebRequest 'https://raw.githubusercontent.com/%REPO%/%BRANCH%/the%%20map/install-map.ps1' -OutFile '%PS1%' -UseBasicParsing } catch { Write-Host ''; Write-Host ('  Download failed: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }"

if not exist "%PS1%" (
  echo.
  echo  Could not download the installer.
  echo  Check the REPO line inside this file, and that the repo is public.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -InstallDir "%INSTALLDIR%"

:done
endlocal
