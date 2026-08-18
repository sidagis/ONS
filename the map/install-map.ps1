<#
    install-map.ps1
    =====================================================================
    ONS map touch kiosk. No AutoHotkey, no ini file.

    THE IMPORTANT ARCHITECTURAL POINT
      A scheduled task running as SYSTEM lives in session 0 and cannot
      draw on the interactive desktop. If you launch Edge from there it
      starts, finds no desktop, and exits immediately - a black flash
      and back to Windows. So the work is split:

        start-map.vbs   runs as the signed-in user, in their session.
                        Triggers the lock task, launches Edge, waits
                        for it to close, triggers the unlock task.

        kiosk-lock.ps1  runs as SYSTEM via scheduled task. Only touches
                        the registry, services and power settings.
                        Never launches anything with a window.

    WHAT GETS INSTALLED (default C:\Kiosk\map)
        start-map.vbs      user-session launcher
        kiosk-lock.ps1     lock / unlock, SYSTEM
        serve-mirror.ps1   local fallback web server
        mirror\theMap.html last-known-good copy, refreshed every launch

    DESKTOP ICONS
        ONS Map            start the kiosk
        Restore Desktop    manual unlock if a session was interrupted

    RUN AS ADMINISTRATOR:
        powershell -ExecutionPolicy Bypass -File .\install-map.ps1

    UNINSTALL:
        powershell -ExecutionPolicy Bypass -File .\install-map.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    # ---- the only line you normally need to change -------------------
    [string]$Url        = "https://sidagis.github.io/ONS/theMap.html",

    [string]$InstallDir = "C:\Kiosk\map",
    [int]   $Port       = 8731,
    [string]$TaskLock   = "ONS Map Lock",
    [string]$TaskUnlock = "ONS Map Unlock",
    [switch]$NoFallback,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "`n  Run this as Administrator.`n" -ForegroundColor Red; exit 1
}

function Step { param($m) Write-Host "  [+] $m" -ForegroundColor Cyan }
function Warn { param($m) Write-Host "  [!] $m" -ForegroundColor Yellow }

$desk       = Join-Path $env:PUBLIC "Desktop"
$lnkStart   = Join-Path $desk "ONS Map.lnk"
$lnkRestore = Join-Path $desk "Restore Desktop.lnk"

# =====================================================================
#  UNINSTALL
# =====================================================================
if ($Uninstall) {
    Write-Host "`n=== Removing ONS map kiosk ===`n" -ForegroundColor Green

    $lockScript = Join-Path $InstallDir "kiosk-lock.ps1"
    if (Test-Path $lockScript) {
        Write-Host "  Reverting any active lockdown..."
        & powershell -NoProfile -ExecutionPolicy Bypass -File $lockScript -Mode Unlock
    }
    foreach ($t in @($TaskLock, $TaskUnlock)) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    }
    Step "Scheduled tasks removed"

    netsh http delete urlacl url="http://127.0.0.1:$Port/" 2>$null | Out-Null
    netsh advfirewall firewall delete rule name="ONS map local mirror" 2>$null | Out-Null

    Remove-Item $lnkStart, $lnkRestore -Force -ErrorAction SilentlyContinue
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Step "Files and icons removed"
    Write-Host "`n  Done. Reboot to be certain nothing is left applied.`n" -ForegroundColor Green
    exit 0
}

Write-Host "`n=== ONS map kiosk - install ===" -ForegroundColor Green
Write-Host "  URL: $Url`n"

# ---------------------------------------------------------------------
#  CLEAN UP THE PREVIOUS ATTEMPT
#  The old toggle-edition script left a scheduled task that launches
#  Edge as SYSTEM. If it is still registered it will keep failing.
# ---------------------------------------------------------------------
foreach ($old in @("ONS Kiosk Session", "ONS Kiosk Session Revert")) {
    if (Get-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $old -Confirm:$false
        Step "Removed old task '$old'"
    }
}
$oldSession = "C:\Kiosk\Kiosk-Session.ps1"
if (Test-Path $oldSession) {
    Remove-Item $oldSession, "C:\Kiosk\Resolve-MapUrl.ps1", "C:\Kiosk\kiosk-url.txt" -Force -ErrorAction SilentlyContinue
    Step "Removed old session scripts"
}

# ---------------------------------------------------------------------
#  LOCATE EDGE
# ---------------------------------------------------------------------
$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw "msedge.exe not found. Install Microsoft Edge first." }
Step "Edge: $edge"

New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
$mirrorDir = Join-Path $InstallDir "mirror"
New-Item -Path $mirrorDir -ItemType Directory -Force | Out-Null
Step "Install folder: $InstallDir"

# =====================================================================
#  kiosk-lock.ps1   - SYSTEM, registry only, no windows
# =====================================================================
$lockPs1 = @'
<#  kiosk-lock.ps1 - generated by install-map.ps1
    Runs as SYSTEM via scheduled task. Registry, services and power only:
    it must never launch anything with a window, because SYSTEM tasks run
    in session 0 where there is no visible desktop.
      -Mode Lock    apply the kiosk restrictions
      -Mode Unlock  remove them
#>
param([ValidateSet("Lock","Unlock")][string]$Mode = "Lock")

$ErrorActionPreference = "SilentlyContinue"

$Dir      = "__INSTALLDIR__"
$Port     = __PORT__
$LogFile  = Join-Path $Dir "kiosk.log"
$DoneLock = Join-Path $Dir "lock.done"
$DoneUnlk = Join-Path $Dir "unlock.done"

function Log { param($m) "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  [lock] $m" | Add-Content $LogFile }

# --- the signed-in user's registry hive (SYSTEM's own HKCU is useless) ---
function Get-UserHive {
    $p = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
    if ($p) {
        $sid = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid).Sid
        if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) { return "Registry::HKEY_USERS\$sid" }
    }
    return "Registry::HKEY_CURRENT_USER"
}
$UH = Get-UserHive

function Set-Reg {
    param($Path,$Name,$Value,[string]$Type="DWord")
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Del-Key { param($p) if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
function Del-Val { param($p,$n) if (Test-Path $p) { Remove-ItemProperty $p -Name $n -Force } }

function Set-TaskbarAutoHide {
    param([bool]$On)
    $sr = "$UH\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3"
    if (-not (Test-Path $sr)) { return }
    $b = (Get-ItemProperty -Path $sr -Name Settings).Settings
    if ($On) { $b[8] = $b[8] -bor 0x01 } else { $b[8] = $b[8] -band 0xFE }
    Set-ItemProperty -Path $sr -Name Settings -Value $b -Force
}

# Explorer must be recycled for gesture and taskbar policy to take hold.
# Windows relaunches it by itself; this is the one-frame black flash.
function Restart-Explorer {
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

# =============================== LOCK ================================
if ($Mode -eq "Lock") {
    Remove-Item $DoneLock -Force
    Log "applying"

    $E = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    $allow = @(
        "sidagis.github.io"
        "*.githubusercontent.com"
        "*.arcgis.com"
        "*.arcgisonline.com"
        "*.sodir.no"
        "127.0.0.1:__PORT__"
    )
    Del-Key "$E\URLAllowlist"; Del-Key "$E\URLBlocklist"
    for ($i=0; $i -lt $allow.Count; $i++) { Set-Reg "$E\URLAllowlist" ($i+1) $allow[$i] "String" }
    Set-Reg "$E\URLBlocklist" "1" "*" "String"

    Set-Reg $E "DeveloperToolsAvailability"  2
    Set-Reg $E "PrintingEnabled"             0
    Set-Reg $E "TranslateEnabled"            0
    Set-Reg $E "BrowserSignin"               0
    Set-Reg $E "PasswordManagerEnabled"      0
    Set-Reg $E "DefaultNotificationsSetting" 2
    Set-Reg $E "DefaultGeolocationSetting"   2
    Set-Reg $E "DefaultPopupsSetting"        2
    Set-Reg $E "AllowSurfGame"               0
    Set-Reg $E "HideFirstRunExperience"      1
    Set-Reg $E "DownloadRestrictions"        3
    Set-Reg $E "InPrivateModeAvailability"   1
    Set-Reg $E "EdgeCollectionsEnabled"      0
    Set-Reg $E "ShowRecommendationsEnabled"  0
    Set-Reg $E "PromotionalTabsEnabled"      0
    Set-Reg $E "UserFeedbackAllowed"         0

    # shell touch gestures
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" "AllowEdgeSwipe"   0
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" "TurnOffBackstack" 1
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1

    # notifications
    Set-Reg "$UH\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" 1
    Set-Reg "$UH\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 0

    # taskbar
    $adv = "$UH\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-Reg $adv "ShowTaskViewButton" 0
    Set-Reg $adv "TaskbarDa"          0
    Set-Reg $adv "TaskbarMn"          0
    Set-TaskbarAutoHide $true

    # touch keyboard
    Set-Service -Name TabletInputService -StartupType Disabled
    Stop-Service  -Name TabletInputService -Force

    # no sleep, no screensaver, no auto-lock
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /change standby-timeout-ac 0 | Out-Null
    Set-Reg "$UH\Control Panel\Desktop" "ScreenSaveActive" "0" "String"
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "InactivityTimeoutSecs" 0

    Restart-Explorer
    New-Item -Path $DoneLock -ItemType File -Force | Out-Null
    Log "applied"
}

# ============================== UNLOCK ===============================
if ($Mode -eq "Unlock") {
    Remove-Item $DoneUnlk -Force
    Log "reverting"

    Del-Key "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    Del-Key "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"
    Del-Key "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
    Del-Key "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"

    Del-Val "$UH\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter"
    Set-Reg "$UH\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 1

    $adv = "$UH\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-Reg $adv "ShowTaskViewButton" 1
    Set-Reg $adv "TaskbarDa"          1
    Set-TaskbarAutoHide $false

    Set-Service   -Name TabletInputService -StartupType Manual
    Start-Service -Name TabletInputService

    powercfg /change monitor-timeout-ac 15 | Out-Null
    powercfg /change standby-timeout-ac 30 | Out-Null
    Set-Reg "$UH\Control Panel\Desktop" "ScreenSaveActive" "1" "String"
    Del-Val "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "InactivityTimeoutSecs"

    Remove-Item (Join-Path $Dir "lock.done") -Force
    Restart-Explorer
    New-Item -Path $DoneUnlk -ItemType File -Force | Out-Null
    Log "reverted"
}
'@

$lockPs1 = $lockPs1.Replace("__INSTALLDIR__", $InstallDir).Replace("__PORT__", "$Port")
$lockPath = Join-Path $InstallDir "kiosk-lock.ps1"
Set-Content -Path $lockPath -Value $lockPs1 -Encoding UTF8
Step "Wrote kiosk-lock.ps1"

# =====================================================================
#  serve-mirror.ps1  - local fallback, user session
# =====================================================================
$servePs1 = @'
<#  serve-mirror.ps1 - generated by install-map.ps1
    Serves the local copy of theMap.html on loopback only, so the page
    keeps a proper http:// origin. Loading from file:// gives a "null"
    origin that some ArcGIS and FactMaps endpoints reject on CORS. #>
param([string]$Root = "__MIRRORDIR__", [int]$Port = __PORT__)

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() } catch { exit 1 }

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
        $rel = $ctx.Request.Url.LocalPath.TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($rel)) { $rel = "theMap.html" }
        $path = Join-Path $Root $rel
        if (Test-Path $path -PathType Leaf) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $ctx.Response.ContentType = switch ([IO.Path]::GetExtension($path).ToLower()) {
                ".html" { "text/html; charset=utf-8" }
                ".js"   { "application/javascript" }
                ".css"  { "text/css" }
                ".json" { "application/json" }
                ".png"  { "image/png" }
                ".jpg"  { "image/jpeg" }
                ".svg"  { "image/svg+xml" }
                default { "application/octet-stream" }
            }
            $ctx.Response.Headers.Add("Cache-Control","no-store")
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else { $ctx.Response.StatusCode = 404 }
        $ctx.Response.Close()
    } catch { }
}
'@

$servePs1 = $servePs1.Replace("__MIRRORDIR__", $mirrorDir).Replace("__PORT__", "$Port")
Set-Content -Path (Join-Path $InstallDir "serve-mirror.ps1") -Value $servePs1 -Encoding UTF8
Step "Wrote serve-mirror.ps1"

# =====================================================================
#  start-map.vbs  - USER SESSION. This is the part that must not be
#  a scheduled task, or Edge has no desktop to draw on.
# =====================================================================
$vbs = @'
' ====================================================================
'  start-map.vbs - generated by install-map.ps1
'
'  Runs as the signed-in user. Order of business:
'    1. trigger the SYSTEM lock task and wait for it to finish
'    2. refresh the local mirror if GitHub is reachable
'    3. launch Edge in kiosk mode IN THIS SESSION
'    4. wait for Edge to close (Alt+F4 on the stand)
'    5. trigger the SYSTEM unlock task
'
'  To change the URL, edit MAP_URL below. Nothing else needs touching.
' ====================================================================
Option Explicit

Const MAP_URL    = "__URL__"
Const EDGE       = "__EDGE__"
Const DIR        = "__INSTALLDIR__"
Const MIRROR     = "__MIRRORDIR__"
Const PORT       = __PORT__
Const TASK_LOCK  = "__TASKLOCK__"
Const TASK_UNLK  = "__TASKUNLOCK__"
Const USE_MIRROR = __USEMIRROR__

Dim sh, fso, profileDir, url, marker, serverStarted
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

serverStarted = False
marker        = "onskioskmap"
profileDir    = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\ONSKioskMap\profile"

Sub Log(msg)
    On Error Resume Next
    Dim ts : Set ts = fso.OpenTextFile(DIR & "\kiosk.log", 8, True)
    ts.WriteLine Now & "  [start] " & msg
    ts.Close
    On Error GoTo 0
End Sub

' ---- 1. lock Windows down ------------------------------------------
On Error Resume Next
fso.DeleteFile DIR & "\lock.done", True
On Error GoTo 0

Log "requesting lockdown"
sh.Run "schtasks /run /tn """ & TASK_LOCK & """", 0, True

' wait for the lock task to signal completion (it restarts Explorer,
' which takes a couple of seconds)
Dim waited : waited = 0
Do While Not fso.FileExists(DIR & "\lock.done")
    WScript.Sleep 500
    waited = waited + 500
    If waited > 30000 Then
        Log "lockdown timed out - continuing anyway"
        Exit Do
    End If
Loop
WScript.Sleep 1500   ' let the new Explorer settle

' ---- 2. live or mirror ---------------------------------------------
url = MAP_URL

If USE_MIRROR Then
    Dim http, ok
    ok = False
    On Error Resume Next
    Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
    http.setTimeouts 4000, 4000, 8000, 8000
    http.open "GET", MAP_URL & "?probe=" & CStr(Timer), False
    http.setRequestHeader "Cache-Control", "no-cache"
    http.send
    If Err.Number = 0 Then
        If http.status = 200 Then
            Dim body : body = http.responseBody
            If LenB(body) > 2048 Then
                Dim st : Set st = CreateObject("ADODB.Stream")
                st.Type = 1 : st.Open : st.Write body
                st.SaveToFile MIRROR & "\theMap.html", 2
                st.Close
                ok = True
            End If
        End If
    End If
    On Error GoTo 0

    If ok Then
        Log "live OK, mirror refreshed"
    ElseIf fso.FileExists(MIRROR & "\theMap.html") Then
        Log "live unreachable - serving local mirror"
        sh.Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & _
               DIR & "\serve-mirror.ps1""", 0, False
        WScript.Sleep 1500
        serverStarted = True
        url = "http://127.0.0.1:" & PORT & "/theMap.html"
    Else
        Log "live unreachable and no mirror - trying live anyway"
    End If
End If

' cache-buster so a push to GitHub is picked up on the next launch
If InStr(url, "?") > 0 Then
    url = url & "&v=" & CStr(CLng(Timer * 100))
Else
    url = url & "?v=" & CStr(CLng(Timer * 100))
End If

' ---- 3. launch Edge in THIS session --------------------------------
On Error Resume Next
sh.Run "taskkill /F /IM msedge.exe", 0, True
On Error GoTo 0
WScript.Sleep 1000

On Error Resume Next
fso.DeleteFolder profileDir, True
On Error GoTo 0

Dim args
args = " --kiosk """ & url & """" & _
       " --edge-kiosk-type=fullscreen" & _
       " --kiosk-idle-timeout-minutes=0" & _
       " --user-data-dir=""" & profileDir & """" & _
       " --" & marker & _
       " --no-first-run" & _
       " --no-default-browser-check" & _
       " --disable-pinch" & _
       " --overscroll-history-navigation=0" & _
       " --noerrdialogs" & _
       " --disable-infobars" & _
       " --hide-crash-restore-bubble" & _
       " --disable-session-crashed-bubble" & _
       " --disable-background-networking" & _
       " --disable-component-update" & _
       " --disable-features=msEdgeSplitScreen,msWebOOUI,msPdfOOUI"

Log "launching Edge"
sh.Run """" & EDGE & """" & args, 1, False

' ---- 4. wait for our Edge to close ---------------------------------
' Match on our own marker switch so an unrelated Edge update process
' can never hold the session open.
WScript.Sleep 6000
Dim wmi, procs
Set wmi = GetObject("winmgmts:\\.\root\cimv2")

Do
    WScript.Sleep 2000
    Dim alive : alive = False
    On Error Resume Next
    Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='msedge.exe'")
    Dim p
    For Each p In procs
        If Not IsNull(p.CommandLine) Then
            If InStr(p.CommandLine, marker) > 0 Then alive = True
        End If
    Next
    On Error GoTo 0
Loop While alive

Log "Edge closed"

' ---- 5. give the desktop back --------------------------------------
If serverStarted Then
    On Error Resume Next
    sh.Run "taskkill /F /FI ""WINDOWTITLE eq serve-mirror*""", 0, True
    On Error GoTo 0
End If

On Error Resume Next
sh.Run "taskkill /F /IM msedge.exe", 0, True
On Error GoTo 0

Log "requesting unlock"
sh.Run "schtasks /run /tn """ & TASK_UNLK & """", 0, True

Set sh  = Nothing
Set fso = Nothing
'@

$useMirror = if ($NoFallback) { "False" } else { "True" }
$vbs = $vbs.Replace("__URL__", $Url).
            Replace("__EDGE__", $edge).
            Replace("__INSTALLDIR__", $InstallDir).
            Replace("__MIRRORDIR__", $mirrorDir).
            Replace("__PORT__", "$Port").
            Replace("__TASKLOCK__", $TaskLock).
            Replace("__TASKUNLOCK__", $TaskUnlock).
            Replace("__USEMIRROR__", $useMirror)

$vbsPath = Join-Path $InstallDir "start-map.vbs"
Set-Content -Path $vbsPath -Value $vbs -Encoding ASCII
Step "Wrote start-map.vbs (URL is editable in this file)"

# =====================================================================
#  SCHEDULED TASKS - registry work only, no GUI
# =====================================================================
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

foreach ($pair in @(@($TaskLock,"Lock"), @($TaskUnlock,"Unlock"))) {
    $name = $pair[0]; $mode = $pair[1]
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction `
        -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$lockPath`" -Mode $mode"
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
}
Step "Registered '$TaskLock' and '$TaskUnlock' (SYSTEM, no UAC prompt)"

# Any user must be able to trigger the tasks, including a non-admin stand account.
foreach ($t in @($TaskLock, $TaskUnlock)) {
    $sd = (Get-ScheduledTask -TaskName $t | Get-ScheduledTaskInfo) 2>$null
    schtasks /change /tn "$t" /enable 2>$null | Out-Null
}

# =====================================================================
#  LOOPBACK RESERVATION + FIREWALL for the fallback server
# =====================================================================
if (-not $NoFallback) {
    netsh http delete urlacl url="http://127.0.0.1:$Port/" 2>$null | Out-Null
    netsh http add urlacl url="http://127.0.0.1:$Port/" user="Everyone" 2>$null | Out-Null
    netsh advfirewall firewall delete rule name="ONS map local mirror" 2>$null | Out-Null
    netsh advfirewall firewall add rule name="ONS map local mirror" dir=in action=block `
        protocol=TCP localport=$Port remoteip=any 2>$null | Out-Null
    Step "Loopback reservation added for port $Port; inbound blocked from the network"

    # seed the mirror now
    try {
        Invoke-WebRequest -Uri $Url -OutFile (Join-Path $mirrorDir "theMap.html") -UseBasicParsing -TimeoutSec 25
        $kb = [math]::Round((Get-Item (Join-Path $mirrorDir "theMap.html")).Length / 1KB, 1)
        Step "Mirror seeded ($kb KB)"
    } catch {
        Warn "Could not seed the mirror: $($_.Exception.Message)"
        Warn "It will be filled in on the first successful launch."
    }
}

# =====================================================================
#  DESKTOP ICONS
# =====================================================================
$wsh = New-Object -ComObject WScript.Shell

$s = $wsh.CreateShortcut($lnkStart)
$s.TargetPath       = "$env:SystemRoot\System32\wscript.exe"
$s.Arguments        = """$vbsPath"""
$s.WorkingDirectory = $InstallDir
$s.IconLocation     = "$edge,0"
$s.Description      = "Start the ONS map kiosk"
$s.WindowStyle      = 7
$s.Save()

$r = $wsh.CreateShortcut($lnkRestore)
$r.TargetPath       = "$env:SystemRoot\System32\schtasks.exe"
$r.Arguments        = "/run /tn ""$TaskUnlock"""
$r.WorkingDirectory = $InstallDir
$r.IconLocation     = "$env:SystemRoot\System32\shell32.dll,220"
$r.Description      = "Unlock Windows if a kiosk session was interrupted"
$r.WindowStyle      = 7
$r.Save()
Step "Desktop icons: 'ONS Map', 'Restore Desktop'"

# =====================================================================
Write-Host "`n  Done - no reboot needed.`n" -ForegroundColor Green
Write-Host "  TEST NOW" -ForegroundColor Yellow
Write-Host "    1. Tap 'ONS Map'. One black flash (Explorer restart), then the map"
Write-Host "       fullscreen. It should STAY up."
Write-Host "    2. Check every button, including the wind layer and minerals basemap."
Write-Host "    3. Alt+F4. Desktop returns, taskbar back, Edge browses normally again."
Write-Host "    4. Tail the log if anything misbehaves:"
Write-Host "         Get-Content '$InstallDir\kiosk.log' -Tail 30"
Write-Host ""
Write-Host "  FALLBACK TEST (do this before the event)" -ForegroundColor Yellow
Write-Host "    Add to C:\Windows\System32\drivers\etc\hosts:  127.0.0.2 sidagis.github.io"
Write-Host "    Launch again - the log should say 'serving local mirror'."
Write-Host "    Remove the hosts line afterwards.`n"
