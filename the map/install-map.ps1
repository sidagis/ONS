<#
    install-map.ps1
    =====================================================================
    ONS map touch kiosk - single self-contained installer.
    No AutoHotkey, no ini file, no companion files in the repo:
    everything it needs is generated at install time.

    Fetched and run by install-map.cmd.

    THE IMPORTANT ARCHITECTURAL POINT
      A scheduled task running as SYSTEM lives in session 0 and cannot
      draw on the interactive desktop. Launching Edge from there gives
      a black flash and an immediate exit. So the work is split:

        start-map.vbs   runs as the signed-in user, in their session.
                        Triggers the lock task, launches Edge, waits
                        for it to close, triggers the unlock task.

        kiosk-lock.ps1  runs as SYSTEM via scheduled task. Registry,
                        services and power only. Never opens a window.

    WHAT GETS INSTALLED (default C:\Kiosk\map)
        start-map.vbs      user-session launcher      (generated)
        kiosk-lock.ps1     lock / unlock, SYSTEM      (generated)
        serve-mirror.ps1   local fallback server      (generated)
        mirror\theMap.html last-known-good copy, refreshed every launch
        kiosk.log          what happened, in order

    DESKTOP ICONS
        ONS Map            start the kiosk
        Restore Desktop    manual unlock if a session was interrupted

    OPTIONS
        -AutoStart     also launch at logon (recommended for a dedicated
                       device: an overnight reboot brings the map back
                       with nobody crawling behind the screen)
        -NoFallback    skip the local mirror entirely
        -Uninstall     remove everything and restore the PC

    Run as Administrator.
#>

[CmdletBinding()]
param(
    # ---- the only line you normally need to change -------------------
    [string]$Url        = "https://sidagis.github.io/ONS/theMap.html",

    [string]$InstallDir = "C:\Kiosk\map",
    [int]   $Port       = 8731,
    [string]$TaskLock   = "ONS Map Lock",
    [string]$TaskUnlock = "ONS Map Unlock",
    [switch]$AutoStart,
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
$startupDir = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\StartUp"
$lnkStart   = Join-Path $desk "ONS Map.lnk"
$lnkRestore = Join-Path $desk "Restore Desktop.lnk"
$lnkAuto    = Join-Path $startupDir "ONS Map.lnk"

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

    Remove-Item $lnkStart, $lnkRestore, $lnkAuto -Force -ErrorAction SilentlyContinue
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Step "Files and icons removed"
    Write-Host "`n  Done. Reboot to be certain nothing is left applied.`n" -ForegroundColor Green
    exit 0
}

Write-Host "`n=== ONS map kiosk - install ===" -ForegroundColor Green
Write-Host "  URL: $Url`n"

# ---------------------------------------------------------------------
#  CLEAN UP EARLIER ATTEMPTS
#  The old toggle edition left a task that launches Edge as SYSTEM.
#  If it is still registered it will keep failing.
# ---------------------------------------------------------------------
foreach ($old in @("ONS Kiosk Session", "ONS Kiosk Session Revert")) {
    if (Get-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $old -Confirm:$false
        Step "Removed old task '$old'"
    }
}
foreach ($f in @("C:\Kiosk\Kiosk-Session.ps1","C:\Kiosk\Resolve-MapUrl.ps1","C:\Kiosk\kiosk-url.txt")) {
    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue; Step "Removed stale $f" }
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

    # AutoRestartShell normally brings it back, but a forced kill does not
    # always trigger it and the result is a wallpaper with no shell at all.
    $waited = 0
    while ($waited -lt 8) {
        Start-Sleep -Seconds 1
        $waited++
        if (Get-Process explorer -ErrorAction SilentlyContinue) { return }
    }
    Log "Explorer did not come back on its own - starting it"
    Start-Process "$env:SystemRoot\explorer.exe"
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
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoRestartShell" 0
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "HideFastUserSwitching" 1

    # notifications
    Set-Reg "$UH\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" 1
    Set-Reg "$UH\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 0

    # --- shell restrictions ------------------------------------------
    # Explorer keeps running in this design, so the taskbar and Start menu
    # are only hidden, not absent. These stop them being reachable.
    $pex = "$UH\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    foreach ($n in "NoWinKeys","NoRun","NoClose","NoLogoff","NoControlPanel",
                   "NoSetTaskbar","NoTrayContextMenu","NoViewContextMenu") {
        Set-Reg $pex $n 1
    }
    $psy = "$UH\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    foreach ($n in "DisableTaskMgr","DisableLockWorkstation","DisableChangePassword") {
        Set-Reg $psy $n 1
    }

    # Press-and-hold = right click, at source, so no ripple circle appears
    # under a visitor's finger either.
    Set-Reg "$UH\Software\Microsoft\Wisp\Touch" "TouchMode_hold" 0
    

    # taskbar
    $adv = "$UH\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-Reg $adv "ShowTaskViewButton" 0
    Set-Reg $adv "TaskbarDa"          0
    Set-Reg $adv "TaskbarMn"          0
    Set-TaskbarAutoHide $true

    # touch keyboard
    Set-Service -Name TabletInputService -StartupType Disabled
    Stop-Service  -Name TabletInputService -Force

    # --- power: AC *and* battery ------------------------------------
    # A Surface wedged behind a screen can lose its charger. Without the
    # -dc lines the panel would blank and the device would sleep.
    powercfg /change monitor-timeout-ac   0 | Out-Null
    powercfg /change monitor-timeout-dc   0 | Out-Null
    powercfg /change standby-timeout-ac   0 | Out-Null
    powercfg /change standby-timeout-dc   0 | Out-Null
    powercfg /change disk-timeout-ac      0 | Out-Null
    powercfg /change disk-timeout-dc      0 | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
    powercfg /change hibernate-timeout-dc 0 | Out-Null

    # physical power button and lid do nothing (0 = take no action)
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0 | Out-Null
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION     0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION     0 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null

    # screensaver / auto-lock
    Set-Reg "$UH\Control Panel\Desktop" "ScreenSaveActive"  "0" "String"
    Set-Reg "$UH\Control Panel\Desktop" "ScreenSaveTimeOut" "0" "String"
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "InactivityTimeoutSecs" 0

    # lock screen rotation - a bumped tablet must not flip sideways
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AutoRotation" "Enable" 0

    Restart-Explorer
    New-Item -Path $DoneLock -ItemType File -Force | Out-Null
    Log "applied"
}

# ============================== UNLOCK ===============================
if ($Mode -eq "Unlock") {
    Remove-Item $DoneUnlk -Force
    Log "reverting"

    # Remove only what Lock set. Deleting the whole Edge policy key took
    # out anything Intune, Group Policy or the other kiosk had put there.
    $E = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    Del-Key "$E\URLAllowlist"
    Del-Key "$E\URLBlocklist"
    foreach ($v in @("DeveloperToolsAvailability","PrintingEnabled","TranslateEnabled",
                     "BrowserSignin","PasswordManagerEnabled","DefaultNotificationsSetting",
                     "DefaultGeolocationSetting","DefaultPopupsSetting","AllowSurfGame",
                     "HideFirstRunExperience","DownloadRestrictions","InPrivateModeAvailability",
                     "EdgeCollectionsEnabled","ShowRecommendationsEnabled","PromotionalTabsEnabled",
                     "UserFeedbackAllowed")) { Del-Val $E $v }

    Del-Val "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" "AllowEdgeSwipe"
    Del-Val "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" "TurnOffBackstack"
    Del-Val "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests"
    Del-Val "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot"
        Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoRestartShell" 1
    Del-Val "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "HideFastUserSwitching"

    Del-Val "$UH\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter"
    Del-Key "$UH\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    Del-Key "$UH\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-Reg "$UH\Software\Microsoft\Wisp\Touch" "TouchMode_hold" 1
    Set-Reg "$UH\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 1

    $adv = "$UH\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-Reg $adv "ShowTaskViewButton" 1
    Set-Reg $adv "TaskbarDa"          1
    Set-TaskbarAutoHide $false

    Set-Service   -Name TabletInputService -StartupType Manual
    Start-Service -Name TabletInputService

    powercfg /change monitor-timeout-ac  15 | Out-Null
    powercfg /change monitor-timeout-dc   5 | Out-Null
    powercfg /change standby-timeout-ac  30 | Out-Null
    powercfg /change standby-timeout-dc  15 | Out-Null
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3 | Out-Null
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION     1 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION     1 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null

    Set-Reg "$UH\Control Panel\Desktop" "ScreenSaveActive" "1" "String"
    Del-Val "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "InactivityTimeoutSecs"
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AutoRotation" "Enable" 1

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
#  start-map.vbs  - USER SESSION. This is the part that must not be a
#  scheduled task, or Edge has no desktop to draw on.
# =====================================================================
$vbs = @'
' ====================================================================
'  start-map.vbs - generated by install-map.ps1
'
'  Runs as the signed-in user. Order of business:
'    1. trigger the SYSTEM lock task and wait for it to finish
'    2. refresh the local mirror if GitHub is reachable
'    3. launch Edge in kiosk mode IN THIS SESSION
'    4. wait for Edge to APPEAR, then wait for it to close
'    5. trigger the SYSTEM unlock task
'
'  Step 4 is deliberately paranoid. An earlier version slept a fixed
'  6 seconds and then read any absence of our Edge process as "the
'  user closed it". On a loaded machine Edge can take far longer than
'  that to start, so the script unlocked and killed the browser it had
'  just launched - a blink and back to the desktop. Now it waits for
'  the process to exist first, and needs several consecutive misses
'  before believing it has gone.
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

' --- tuning ---------------------------------------------------------
Const START_TIMEOUT_MS  = 90000  ' how long Edge may take to appear
Const POLL_MS           = 5000   ' gap between liveness polls
Const MISSES_TO_CLOSE   = 2      ' consecutive misses = really gone
Const RELAUNCH_GAP_MS   = 3000   ' pause before bringing Edge back
Const MAX_LAUNCH_FAILS  = 5      ' give up and unlock after this many

Dim sh, fso, wmi, profileDir, url, marker, serverPid, edgePid
Dim edgeArgs, stopFlag, fails, running, state, misses
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

serverPid  = 0
edgePid    = 0
marker     = "onskioskmap"
profileDir = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\ONSKioskMap\profile"
stopFlag   = DIR & "\stop.flag"

Sub Log(msg)
    On Error Resume Next
    Dim ts : Set ts = fso.OpenTextFile(DIR & "\kiosk.log", 8, True)
    ts.WriteLine Now & "  [start] " & msg
    ts.Close
    On Error GoTo 0
End Sub

' Returns: 1 = our Edge is running, 0 = not running, -1 = query failed.
' A failed query must never be read as "closed", or a WMI hiccup under
' load would tear the kiosk down.
'
' Enumerating every process and reading its CommandLine is expensive and
' this runs all day, so the browser PID is resolved once and then polled
' directly. The full scan only happens on the first poll and after the
' PID disappears, to confirm it really has gone.
Function EdgeState()
    Dim procs, p, found
    found = 0
    On Error Resume Next
    Err.Clear

    If edgePid <> 0 Then
        Set procs = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process " & _
                                  "WHERE ProcessId=" & edgePid & " AND Name='msedge.exe'")
        If Err.Number <> 0 Then
            EdgeState = -1
            On Error GoTo 0
            Exit Function
        End If
        For Each p In procs
            found = 1
        Next
        If found = 1 Then
            EdgeState = 1
            On Error GoTo 0
            Exit Function
        End If
        edgePid = 0
        Err.Clear
    End If

    Set procs = wmi.ExecQuery("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='msedge.exe'")
    If Err.Number <> 0 Then
        EdgeState = -1
        On Error GoTo 0
        Exit Function
    End If
    For Each p In procs
        If Not IsNull(p.CommandLine) Then
            If InStr(p.CommandLine, marker) > 0 Then
                found = 1
                edgePid = p.ProcessId
            End If
        End If
    Next
    If Err.Number <> 0 Then
        EdgeState = -1
        On Error GoTo 0
        Exit Function
    End If
    On Error GoTo 0
    EdgeState = found
End Function

Sub KillOurEdge()
    ' Only our own kiosk processes - never anybody else's windows.
    Dim procs, p
    On Error Resume Next
    Set procs = wmi.ExecQuery("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='msedge.exe'")
    For Each p In procs
        If Not IsNull(p.CommandLine) Then
            If InStr(p.CommandLine, marker) > 0 Then
                sh.Run "taskkill /F /PID " & p.ProcessId, 0, True
            End If
        End If
    Next
    On Error GoTo 0
End Sub

Sub KillExplorer()
    Dim procs, p
    On Error Resume Next
    Set procs = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name='explorer.exe'")
    For Each p In procs
        sh.Run "taskkill /F /PID " & p.ProcessId, 0, True
    Next
    On Error GoTo 0
End Sub

Set wmi = GetObject("winmgmts:\\.\root\cimv2")

' ---- 1. lock Windows down ------------------------------------------
On Error Resume Next
fso.DeleteFile DIR & "\lock.done", True
fso.DeleteFile stopFlag, True
On Error GoTo 0

Log "requesting lockdown"
sh.Run "schtasks /run /tn """ & TASK_LOCK & """", 0, True

Dim waited : waited = 0
Do While Not fso.FileExists(DIR & "\lock.done")
    WScript.Sleep 500
    waited = waited + 500
    If waited > 45000 Then
        Log "lockdown timed out - continuing anyway"
        Exit Do
    End If
Loop
Log "stopping Explorer for this session"
KillExplorer
WScript.Sleep 800
KillExplorer
WScript.Sleep 700

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
            If LenB(body) > 2048 And InStr(http.responseText, "portalItemId") > 0 Then
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

        ' remember the listener's PID so we stop exactly that process
        On Error Resume Next
        Dim sp, sprocs
        Set sprocs = wmi.ExecQuery("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'")
        For Each sp In sprocs
            If Not IsNull(sp.CommandLine) Then
                If InStr(sp.CommandLine, "serve-mirror.ps1") > 0 Then serverPid = sp.ProcessId
            End If
        Next
        On Error GoTo 0

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
' Our own --user-data-dir means Edge always spawns a separate browser
' process, so there is no need to kill anyone else's Edge first.
'
' The profile is wiped once per SESSION, not once per relaunch: a crash
' recovery should reuse the warm cache and come back in seconds rather
' than re-downloading the whole ArcGIS bundle.
On Error Resume Next
fso.DeleteFolder profileDir, True
On Error GoTo 0

edgeArgs = " --kiosk """ & url & """" & _
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

' Launch and wait for it to actually appear. Returns True if it did.
Function LaunchEdge()
    Dim elapsed
    KillOurEdge
    edgePid = 0
    WScript.Sleep 500

    Log "launching Edge"
    sh.Run """" & EDGE & """" & edgeArgs, 1, False

    elapsed = 0
    Do While elapsed < START_TIMEOUT_MS
        WScript.Sleep 1000
        elapsed = elapsed + 1000
        If EdgeState() = 1 Then
            Log "Edge is up after " & CStr(elapsed \ 1000) & "s"
            LaunchEdge = True
            Exit Function
        End If
    Loop
    LaunchEdge = False
End Function

' ---- 4. supervise ---------------------------------------------------
' The old version exited - and unlocked Windows - the moment Edge went
' away. One crash, one GPU driver reset or one stray Alt+F4 at 10am left
' the stand showing a Windows desktop for the rest of the day. Now only
' the Restore Desktop icon ends the session, by writing stop.flag.
fails = 0

Do
    If fso.FileExists(stopFlag) Then
        Log "stop flag - handing the desktop back"
        Exit Do
    End If

    running = LaunchEdge()

    If Not running Then
        fails = fails + 1
        Log "ERROR: Edge did not appear (failure " & CStr(fails) & " of " & CStr(MAX_LAUNCH_FAILS) & ")"
        If fails >= MAX_LAUNCH_FAILS Then
            Log "giving up - unlocking so the machine is at least usable"
            Exit Do
        End If
        WScript.Sleep RELAUNCH_GAP_MS
    Else
        fails = 0
        misses = 0
        Do
            WScript.Sleep POLL_MS
            If fso.FileExists(stopFlag) Then Exit Do
            state = EdgeState()
            If state = 1 Then
                misses = 0
            ElseIf state = 0 Then
                misses = misses + 1
            Else
                Log "WMI query failed, ignoring this poll"
            End If
        Loop While misses < MISSES_TO_CLOSE

        If Not fso.FileExists(stopFlag) Then
            Log "Edge vanished - relaunching"
            WScript.Sleep RELAUNCH_GAP_MS
        End If
    End If
Loop

On Error Resume Next
fso.DeleteFile stopFlag, True
On Error GoTo 0

' ---- 5. give the desktop back --------------------------------------
If serverPid <> 0 Then
    On Error Resume Next
    sh.Run "taskkill /F /PID " & serverPid, 0, True
    On Error GoTo 0
End If

KillOurEdge

Log "requesting unlock"
sh.Run "schtasks /run /tn """ & TASK_UNLK & """", 0, True

' Wait for the policies to be back, then bring the shell up in THIS
' session - the SYSTEM task cannot, it lives in session 0.
Dim uw : uw = 0
Do While Not fso.FileExists(DIR & "\unlock.done") And uw < 20000
    WScript.Sleep 500
    uw = uw + 500
Loop
sh.Run "explorer.exe", 1, False

Set wmi = Nothing
Set sh  = Nothing
Set fso = Nothing
'@

if ($NoFallback) { $useMirror = "False" } else { $useMirror = "True" }
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

# The supervisor relaunches Edge on any exit, so ending a session has to
# be explicit. This is what the Restore Desktop icon runs.
$stopCmd = @'
@echo off
rem stop-map.cmd - generated by install-map.ps1
rem Ends a kiosk session: the supervisor sees the flag within one poll,
rem closes its Edge and unlocks. The schtasks line is a belt-and-braces
rem unlock in case the supervisor is not running at all.
echo stop > "__INSTALLDIR__\stop.flag"
schtasks /run /tn "__TASKUNLOCK__" >nul 2>&1
'@
$stopCmd  = $stopCmd.Replace("__INSTALLDIR__", $InstallDir).Replace("__TASKUNLOCK__", $TaskUnlock)
$stopPath = Join-Path $InstallDir "stop-map.cmd"
Set-Content -Path $stopPath -Value $stopCmd -Encoding ASCII
Step "Wrote stop-map.cmd"

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

# Let a standard (non-admin) stand account trigger the tasks. Without an
# explicit descriptor, schtasks /run from a limited user can be denied.
try {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $folder = $svc.GetFolder("\")
    # Admins + SYSTEM full control; Authenticated Users read + execute.
    $sddl = "D:(A;;GA;;;BA)(A;;GA;;;SY)(A;;GRGX;;;AU)"
    foreach ($t in @($TaskLock, $TaskUnlock)) {
        $folder.GetTask($t).SetSecurityDescriptor($sddl, 0)
    }
    Step "Task permissions widened so a standard user can trigger them"
} catch {
    Warn "Could not set task permissions: $($_.Exception.Message)"
    Warn "Not a problem if the stand account is an administrator."
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
    Step "Loopback reservation for port $Port; inbound blocked from the network"

    try {
        Invoke-WebRequest -Uri $Url -OutFile (Join-Path $mirrorDir "theMap.html") -UseBasicParsing -TimeoutSec 25
        $kb = [math]::Round((Get-Item (Join-Path $mirrorDir "theMap.html")).Length / 1KB, 1)
        Step "Mirror seeded ($kb KB)"
    } catch {
        Warn "Could not seed the mirror: $($_.Exception.Message)"
        Warn "It will fill in on the first successful launch."
    }
}

# =====================================================================
#  ICONS
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
$r.TargetPath       = "$env:SystemRoot\System32\cmd.exe"
$r.Arguments        = "/c ""$stopPath"""
$r.WorkingDirectory = $InstallDir
$r.IconLocation     = "$env:SystemRoot\System32\shell32.dll,220"
$r.Description      = "Unlock Windows if a kiosk session was interrupted"
$r.WindowStyle      = 7
$r.Save()
Step "Desktop icons: 'ONS Map', 'Restore Desktop'"

if ($AutoStart) {
    Copy-Item $lnkStart $lnkAuto -Force
    Step "Added to all-users Startup - launches at logon"
} else {
    Remove-Item $lnkAuto -Force -ErrorAction SilentlyContinue
}

# =====================================================================
Write-Host "`n  Done - no reboot needed.`n" -ForegroundColor Green
Write-Host "  TEST NOW" -ForegroundColor Yellow
Write-Host "    1. Tap 'ONS Map'. One black flash (Explorer restart), then the map"
Write-Host "       fullscreen. It should STAY up."
Write-Host "    2. Check every button, including the wind layer and minerals basemap."
Write-Host "    3. Alt+F4. Desktop returns, taskbar back, Edge browses normally."
Write-Host "    4. If anything misbehaves:"
Write-Host "         Get-Content '$InstallDir\kiosk.log' -Tail 30"
Write-Host ""
Write-Host "  FALLBACK TEST (do this once before the event)" -ForegroundColor Yellow
Write-Host "    Add to C:\Windows\System32\drivers\etc\hosts:  127.0.0.2 sidagis.github.io"
Write-Host "    Launch again - the log should say 'serving local mirror'."
Write-Host "    Remove the hosts line afterwards."
Write-Host ""
if (-not $AutoStart) {
    Write-Host "  TIP: for a dedicated device, re-run with -AutoStart so an overnight" -ForegroundColor DarkGray
    Write-Host "       reboot brings the map back without anyone reaching behind the screen." -ForegroundColor DarkGray
    Write-Host ""
}
