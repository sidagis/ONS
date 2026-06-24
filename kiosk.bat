@echo off
set "URL=https://raw.githubusercontent.com/sidagis/ONS/refs/heads/main/theMap.html"
set "DEST=C:\theMap.html"

curl -L -o "%DEST%" "%URL%"

start "" "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" ^
  --kiosk "file:///C:/kiosk/theMap.html" ^
  --edge-kiosk-type=fullscreen ^
  --no-first-run ^
  --kiosk-idle-timeout-minutes=0 ^
  --user-data-dir="C:\KioskProfile"
