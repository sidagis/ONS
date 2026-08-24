@echo off
setlocal EnableExtensions
title ONS kiosk - restore desktop

rem =====================================================================
rem  restore-desktop.cmd
rem
rem  Ends a kiosk session from outside it. The normal exit is Alt+F4,
rem  which lets the controller unlock cleanly; this is for when the
rem  controller is gone and the machine is still locked down.
rem
rem  Needs administrator rights only if the scheduled task permissions
rem  were not widened at install time.
rem =====================================================================

set "INSTALLDIR=C:\Kiosk"

echo.
echo   Ending the kiosk session...

taskkill /f /im AutoHotkey64.exe >nul 2>&1
taskkill /f /im msedge.exe       >nul 2>&1

schtasks /run /tn "ONS Kiosk Unlock" >nul 2>&1

rem Wait for the SYSTEM task to finish before bringing Explorer back, so
rem it starts against the reverted policies rather than the kiosk ones.
set /a WAITED=0
:wait
if exist "%INSTALLDIR%\unlock.done" goto shell
if %WAITED% GEQ 30 goto shell
ping -n 2 127.0.0.1 >nul
set /a WAITED+=1
goto wait

:shell
tasklist /fi "imagename eq explorer.exe" | find /i "explorer.exe" >nul
if errorlevel 1 start "" explorer.exe

echo.
echo   Done. The desktop should be back.
echo.
timeout /t 4 >nul
