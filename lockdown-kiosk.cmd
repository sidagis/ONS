@echo off
setlocal EnableExtensions
title ArcGIS kiosk - lockdown

rem =====================================================================
rem  lockdown-kiosk.cmd
rem
rem  Run this AFTER the kiosk has been tested and works.
rem  Run it while signed in as the account the kiosk will run under -
rem  some settings are per-user.
rem =====================================================================

set "INSTALLDIR=C:\Kiosk"

net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo  Asking for administrator rights...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "PS1=%INSTALLDIR%\install-kiosk.ps1"
if not exist "%PS1%" set "PS1=%~dp0install-kiosk.ps1"
if not exist "%PS1%" (
  echo.
  echo  install-kiosk.ps1 was not found. Run install-kiosk.cmd first.
  echo.
  pause
  exit /b 1
)

:menu
cls
echo.
echo   ArcGIS kiosk - lockdown
echo   -----------------------
echo.
echo   Signed in as: %USERDOMAIN%\%USERNAME%
echo.
echo   1  Lock the machine down  (Windows + Edge restrictions)
echo   2  Lock down AND stop Explorer from starting  (full kiosk)
echo   3  Remove all restrictions  (maintenance)
echo   4  CHECK what is actually applied on this machine
echo   5  Cancel
echo.
set "PICK="
set /p "PICK=  Choose 1-5: "

if "%PICK%"=="1" goto lock
if "%PICK%"=="2" goto lockshell
if "%PICK%"=="3" goto unlock
if "%PICK%"=="4" goto verify
if "%PICK%"=="5" goto :eof
goto menu

:lock
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Lockdown -InstallDir "%INSTALLDIR%"
goto :eof

:lockshell
echo.
echo   This makes the kiosk the Windows shell for %USERNAME%.
echo   At the next sign-in there will be no taskbar, no Start menu and
echo   no Task View. Alt+F4 brings the desktop back for that session.
echo.
choice /c YN /m "  Continue"
if errorlevel 2 goto menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Lockdown -SetShell -InstallDir "%INSTALLDIR%"
goto :eof

:verify
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Verify -InstallDir "%INSTALLDIR%"
goto :eof

:unlock
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Unlock -InstallDir "%INSTALLDIR%"
goto :eof
