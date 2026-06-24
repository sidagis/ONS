@echo off
start "" "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" ^
  --kiosk "file:///C:/theMap.html" ^
  --edge-kiosk-type=fullscreen ^
  --no-first-run ^
  --kiosk-idle-timeout-minutes=0 ^
  --user-data-dir="C:\KioskProfile"
