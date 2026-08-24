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

rem Capture who is signed in BEFORE elevating. UAC may run the elevated
rem copy as a different (administrator) account, and the per-user
rem policies have to land in the KIOSK account's hive, not that one.
if not "%~1"=="" (
  set "KIOSKUSER=%~1"
) else (
  set "KIOSKUSER=%USERDOMAIN%\%USERNAME%"
)

net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo  Asking for administrator rights...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -FilePath '%~f0' -ArgumentList '%KIOSKUSER%' -Verb RunAs"
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
echo   The lockdown is now applied automatically every time the kiosk
echo   starts, and reverted when it exits. This menu is for repair.
echo.
echo   1  Re-register the lockdown tasks  (run after an update)
echo   2  Make the kiosk the Windows shell  (legacy, permanent)
echo   3  Remove all restrictions NOW  (maintenance)
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Tasks -InstallDir "%INSTALLDIR%"
goto :eof

:lockshell
echo.
echo   This makes the kiosk the Windows shell for %USERNAME%.
echo   At the next sign-in there will be no taskbar, no Start menu and
echo   no Task View. Alt+F4 brings the desktop back for that session.
echo.
choice /c YN /m "  Continue"
if errorlevel 2 goto menu
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Lockdown -SetShell -InstallDir "%INSTALLDIR%" -KioskUser "%KIOSKUSER%"
goto :eof

:verify
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Verify -InstallDir "%INSTALLDIR%" -KioskUser "%KIOSKUSER%"
goto :eof

:unlock
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Mode Unlock -InstallDir "%INSTALLDIR%" -KioskUser "%KIOSKUSER%"
goto :eof
