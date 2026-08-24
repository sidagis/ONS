<#
    kiosk-session.ps1
    =====================================================================
    Applies and reverts the kiosk lockdown. Runs as SYSTEM via the
    "ONS Kiosk Lock" / "ONS Kiosk Unlock" scheduled tasks, triggered by
    kiosk-lock.ahk at the start and end of every session.

    It must never launch anything with a window: SYSTEM tasks run in
    session 0, where there is no visible desktop. Everything that has to
    happen in the user's session - killing and restarting Explorer -
    is done by kiosk-lock.ahk instead.

      -Mode Lock      apply the restrictions
      -Mode Unlock    remove them
      -Mode Recover   at logon: unlock only if a session was interrupted
#>
param(
    [ValidateSet("Lock","Unlock","Recover")][string]$Mode = "Lock",
    [string]$Dir = "C:\Kiosk"
)

$ErrorActionPreference = "SilentlyContinue"

$Ini      = Join-Path $Dir "kiosk.ini"
$LogFile  = Join-Path $Dir "kiosk-log.txt"
$DoneLock = Join-Path $Dir "lock.done"
$DoneUnlk = Join-Path $Dir "unlock.done"

function Log { param($m) "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  [session] $m" | Add-Content $LogFile }

# ---------------------------------------------------------------------
#  The signed-in user's hive. SYSTEM's own HKCU is useless here, and this
#  is the whole reason the old lockdown silently missed the kiosk account:
#  reg import of HKEY_CURRENT_USER keys wrote into whichever account UAC
#  had elevated into.
#
#  Win32_ComputerSystem.UserName is the console user and is still readable
#  after we have killed Explorer, which the Explorer-owner trick is not.
# ---------------------------------------------------------------------
function Get-UserHive {
    $name = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($name) {
        try {
            $sid = (New-Object Security.Principal.NTAccount($name)).Translate(
                       [Security.Principal.SecurityIdentifier]).Value
            if (Test-Path "Registry::HKEY_USERS\$sid") {
                Log "user hive: $name"
                return "Registry::HKEY_USERS\$sid"
            }
        } catch { }
    }

    $p = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
    if ($p) {
        $sid = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid).Sid
        if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) {
            Log "user hive resolved via Explorer: $sid"
            return "Registry::HKEY_USERS\$sid"
        }
    }

    Log "WARNING: could not resolve the interactive user - falling back to SYSTEM's own hive"
    return "Registry::HKEY_CURRENT_USER"
}

function Set-Reg {
    param($Path,$Name,$Value,[string]$Type = "DWord")
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Del-Key { param($p) if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
function Del-Val { param($p,$n) if (Test-Path $p) { Remove-ItemProperty $p -Name $n -Force } }

function Get-IniValue {
    param([string]$Key)
    if (-not (Test-Path $Ini)) { return $null }
    foreach ($l in Get-Content $Ini) {
        if ($l -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

# =====================================================================
#  RECOVER - a session was interrupted and left the machine locked
# =====================================================================
# The kiosk normally unlocks itself on exit. This covers the cases where
# it could not: a power cut mid-session, or the controller being killed
# outright. It runs at every logon, waits for the kiosk to start if it is
# going to, and only acts if it did not.
if ($Mode -eq "Recover") {
    Start-Sleep -Seconds 90
    if (Get-Process AutoHotkey64 -ErrorAction SilentlyContinue) { exit 0 }
    if (-not (Test-Path $DoneLock)) { exit 0 }
    Log "recover: lockdown was left applied with no kiosk running - reverting"
    $Mode = "Unlock"
}

$UH = Get-UserHive

# =====================================================================
#  LOCK
# =====================================================================
if ($Mode -eq "Lock") {
    Remove-Item $DoneUnlk -Force
    Log "applying"

    # --- Edge policy -------------------------------------------------
    $E = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"

    $allow = @(
        "file:///" + $Dir.Replace('\','/').TrimEnd('/') + "/"
        "[*.]arcgis.com"
        "[*.]arcgisonline.com"
        "[*.]arcgis.net"
        "[*.]vimeo.com"
        "[*.]vimeocdn.com"
    )
    # Whatever host AppUrl actually points at, plus its parent domain.
    $url = Get-IniValue "AppUrl"
    if ($url -and $url -match '^https?://([^/:]+)') {
        $h = $Matches[1]
        $allow += $h
        $parts = $h.Split('.')
        if ($parts.Count -ge 2) { $allow += ('[*.]' + ($parts[-2..-1] -join '.')) }
    }
    $allow = $allow | Select-Object -Unique

    Del-Key "$E\URLAllowlist"; Del-Key "$E\URLBlocklist"
    for ($i = 0; $i -lt $allow.Count; $i++) { Set-Reg "$E\URLAllowlist" ($i+1) $allow[$i] "String" }
    Set-Reg "$E\URLBlocklist" "1" "*" "String"
    Log "Edge may reach: $($allow -join ', ')"

    Set-Reg $E "HideFirstRunExperience"       1
    Set-Reg $E "DeveloperToolsAvailability"   2
    Set-Reg $E "InPrivateModeAvailability"    1
    Set-Reg $E "BrowserSignin"                0
    Set-Reg $E "SyncDisabled"                 1
    Set-Reg $E "PasswordManagerEnabled"       0
    Set-Reg $E "AutofillAddressEnabled"       0
    Set-Reg $E "AutofillCreditCardEnabled"    0
    Set-Reg $E "TranslateEnabled"             0
    Set-Reg $E "EdgeCollectionsEnabled"       0
    Set-Reg $E "ShowRecommendationsEnabled"   0
    Set-Reg $E "PromotionalTabsEnabled"       0
    Set-Reg $E "EdgeShoppingAssistantEnabled" 0
    Set-Reg $E "UserFeedbackAllowed"          0
    Set-Reg $E "PrintingEnabled"              0
    Set-Reg $E "SavingBrowserHistoryDisabled" 1
    Set-Reg $E "DefaultNotificationsSetting"  2
    Set-Reg $E "DefaultGeolocationSetting"    1   # 1 = allow silently, so no
                                                  # permission bubble a visitor
                                                  # with no mouse cannot dismiss
    Set-Reg $E "BackgroundModeEnabled"        0
    Set-Reg $E "AllowFileSelectionDialogs"    0
    Set-Reg $E "DownloadRestrictions"         3
    Set-Reg $E "AllowSurfGame"                0
    Set-Reg $E "DiskCacheSize"                262144000   # 250 MB, so a profile
                                                          # that lives for months
                                                          # cannot fill the disk

    # Edge updates itself through its own service. The command-line
    # --check-for-update-interval does nothing about that.
    $EU = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
    Set-Reg $EU "UpdateDefault"                0
    Set-Reg $EU "AutoUpdateCheckPeriodMinutes" 0
    Set-Reg $EU "InstallDefault"               0

    # --- shell and touch, machine-wide -------------------------------
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" "AllowEdgeSwipe"   0
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" "TurnOffBackstack" 1
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "HideFastUserSwitching" 1
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" "NoLockScreen" 1

    # THIS is what lets the controller kill Explorer and have it stay
    # dead. Winlogon would otherwise relaunch the shell immediately.
    # It only governs restart-after-death, so a fresh logon still gets a
    # normal desktop - a power cut cannot strand the machine.
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoRestartShell" 0

    # --- per-user, in the KIOSK account's hive ------------------------
    $exp = "$UH\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    foreach ($n in "NoWinKeys","NoRun","NoClose","NoLogoff","NoControlPanel",
                   "NoSetTaskbar","NoTrayContextMenu","NoViewContextMenu") {
        Set-Reg $exp $n 1
    }
    $sys = "$UH\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    foreach ($n in "DisableTaskMgr","DisableLockWorkstation","DisableChangePassword") {
        Set-Reg $sys $n 1
    }
    Set-Reg "$UH\Software\Microsoft\Wisp\Touch" "TouchMode_hold" 0
    Set-Reg "$UH\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 0
    Set-Reg "$UH\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" 1
    Set-Reg "$UH\Control Panel\Desktop" "ScreenSaveActive"    "0" "String"
    Set-Reg "$UH\Control Panel\Desktop" "ScreenSaverIsSecure" "0" "String"

    # --- touch keyboard, so no on-screen keyboard can be summoned -----
    Set-Service -Name TabletInputService -StartupType Disabled
    Stop-Service  -Name TabletInputService -Force

    # --- power, AC and battery ---------------------------------------
    foreach ($t in "monitor-timeout","standby-timeout","disk-timeout","hibernate-timeout") {
        powercfg /change "$t-ac" 0 | Out-Null
        powercfg /change "$t-dc" 0 | Out-Null
    }
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0 | Out-Null
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION     0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION     0 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null

    New-Item -Path $DoneLock -ItemType File -Force | Out-Null
    Log "applied"
}

# =====================================================================
#  UNLOCK
# =====================================================================
if ($Mode -eq "Unlock") {
    Remove-Item $DoneUnlk -Force
    Log "reverting"

    # Remove only what Lock set. Deleting the whole Edge policy key would
    # take out anything Intune or Group Policy had put there.
    $E = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    Del-Key "$E\URLAllowlist"
    Del-Key "$E\URLBlocklist"
    foreach ($v in "HideFirstRunExperience","DeveloperToolsAvailability","InPrivateModeAvailability",
                   "BrowserSignin","SyncDisabled","PasswordManagerEnabled","AutofillAddressEnabled",
                   "AutofillCreditCardEnabled","TranslateEnabled","EdgeCollectionsEnabled",
                   "ShowRecommendationsEnabled","PromotionalTabsEnabled","EdgeShoppingAssistantEnabled",
                   "UserFeedbackAllowed","PrintingEnabled","SavingBrowserHistoryDisabled",
                   "DefaultNotificationsSetting","DefaultGeolocationSetting","BackgroundModeEnabled",
                   "AllowFileSelectionDialogs","DownloadRestrictions","AllowSurfGame","DiskCacheSize") {
        Del-Val $E $v
    }

    $EU = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
    foreach ($v in "UpdateDefault","AutoUpdateCheckPeriodMinutes","InstallDefault") { Del-Val $EU $v }

    Del-Val "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" "AllowEdgeSwipe"
    Del-Val "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" "TurnOffBackstack"
    Del-Val "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests"
    Del-Val "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot"
    Del-Val "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "HideFastUserSwitching"
    Del-Val "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" "NoLockScreen"

    # Let Winlogon look after the shell again.
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoRestartShell" 1

    Del-Key "$UH\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    Del-Key "$UH\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    Del-Val "$UH\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter"
    Set-Reg "$UH\Software\Microsoft\Wisp\Touch" "TouchMode_hold" 1
    Set-Reg "$UH\Software\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 1
    Set-Reg "$UH\Control Panel\Desktop" "ScreenSaveActive" "1" "String"

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

    Remove-Item $DoneLock -Force
    New-Item -Path $DoneUnlk -ItemType File -Force | Out-Null
    Log "reverted"
}
