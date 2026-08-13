@echo off
setlocal EnableExtensions
title ArcGIS kiosk - install

rem =====================================================================
rem  install-kiosk.cmd
rem
rem  Double-click this. It asks for administrator rights, downloads the
rem  kiosk files, installs AutoHotkey if it is missing, asks for your
rem  Experience URL, and puts a "Start Kiosk" shortcut on the desktop.
rem
rem  EDIT THE NEXT LINE ONCE: your GitHub user and repo name.
rem =====================================================================

set "REPO=sidagis/ONS"
set "BRANCH=main"
set "INSTALLDIR=C:\Kiosk"

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
set "PS1=%~dp0install-kiosk.ps1"

if exist "%PS1%" (
  rem Running from a cloned or downloaded copy of the repo: install the
  rem files sitting right here, no download needed.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" ^
    -Repo "%REPO%" -Branch "%BRANCH%" -InstallDir "%INSTALLDIR%" -Local
  goto :done
)

rem Running as a lone downloaded file: fetch the installer, which then
rem fetches everything else from the repo.
set "PS1=%TEMP%\install-kiosk.ps1"
echo.
echo  Fetching the installer from GitHub...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "[Net.ServicePointManager]::SecurityProtocol='Tls12'; try { Invoke-WebRequest 'https://raw.githubusercontent.com/%REPO%/%BRANCH%/install-kiosk.ps1' -OutFile '%PS1%' -UseBasicParsing } catch { Write-Host ''; Write-Host ('  Download failed: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }"

if not exist "%PS1%" (
  echo.
  echo  Could not download the installer.
  echo  Check the REPO line inside this file, and that the repo is public.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" ^
  -Repo "%REPO%" -Branch "%BRANCH%" -InstallDir "%INSTALLDIR%"

:done
endlocal
