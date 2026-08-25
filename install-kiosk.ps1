#Requires -Version 5.1
<#
    install-kiosk.ps1
    ArcGIS Experience Builder touch kiosk - installer / updater / lockdown.

    Normally you do not run this by hand. Double-click install-kiosk.cmd
    or lockdown-kiosk.cmd, which handle the admin prompt for you.

    Modes
      Install   (default)  download files, install AutoHotkey, configure,
                           create shortcuts, set power settings
      Lockdown             apply the Windows + Edge restriction policies
      Unlock               reverse the restrictions for maintenance

    Examples
      .\install-kiosk.ps1 -Repo you/kiosk -AppUrl "https://experience.arcgis.com/experience/abc/"
      .\install-kiosk.ps1 -Mode Lockdown -SetShell
      .\install-kiosk.ps1 -Mode Unlock
#>
[CmdletBinding()]
param(
    # GitHub repo holding the kiosk files, as "user/repo".
    [string]$Repo = 'YOURUSER/YOURREPO',
    [string]$Branch = 'main',

    [string]$InstallDir = 'C:\Kiosk',

    # Published Experience URL. Prompted for if omitted.
    [string]$AppUrl,
    [int]$IdleSeconds = 0,

    [ValidateSet('Install','Lockdown','Unlock','Verify','Tasks')]
    [string]$Mode = 'Install',

    # Lockdown only: also make the kiosk the Windows shell for this user,
    # so Explorer (taskbar, Start menu, Task View) never starts.
    [switch]$SetShell,

    # Install from the folder this script sits in instead of downloading.
    [switch]$Local,

    # Never prompt; accept defaults.
    [switch]$Unattended,

    [string]$KioskUser
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Files pulled from the repo. kiosk.ini is handled separately so an
# update never overwrites a configured kiosk.
$PAYLOAD = @(
    'kiosk-lock.ahk',
    'kiosk-wrapper.html',
    'kiosk-session.ps1',
    'restore-desktop.cmd',
    'kiosk-lockdown.reg',
    'kiosk-unlock.reg',
    'install-kiosk.ps1',
    'install-kiosk.cmd',
    'lockdown-kiosk.cmd',
    'kiosk.ini',
    'README.md',
    'SETUP.md'
)

function Say  ($m) { Write-Host "  $m" }
function Step ($m) { Write-Host ""; Write-Host "[ $m ]" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host ""; Write-Host "  x $m" -ForegroundColor Red; Write-Host ""; if (-not $Unattended) { Read-Host 'Press Enter to close' }; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------
#  AutoHotkey
# ---------------------------------------------------------------------
function Get-AutoHotkey {
    param([string]$Dir)

    $candidates = @(
        (Join-Path $Dir 'bin\AutoHotkey64.exe'),
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { Say "found AutoHotkey: $c"; return $c }
    }

    Say 'AutoHotkey v2 not present - fetching the portable build'
    $bin = Join-Path $Dir 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $zip = Join-Path $env:TEMP 'ahk2.zip'

    $urls = @()
    try {
        $ver = (Invoke-WebRequest 'https://www.autohotkey.com/download/2.0/version.txt' -UseBasicParsing).Content.Trim()
        if ($ver) { $urls += "https://www.autohotkey.com/download/2.0/AutoHotkey_$ver.zip" }
    } catch { Warn 'could not read the AutoHotkey version file' }

    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/AutoHotkey/AutoHotkey/releases/latest' -UseBasicParsing
        $asset = $rel.assets | Where-Object { $_.name -match '^AutoHotkey_2\..*\.zip$' } | Select-Object -First 1
        if ($asset) { $urls += $asset.browser_download_url }
    } catch { }

    foreach ($u in $urls) {
        try {
            Say "downloading $u"
            Invoke-WebRequest $u -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $bin -Force
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            Get-ChildItem $bin -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
            $exe = Join-Path $bin 'AutoHotkey64.exe'
            if (Test-Path $exe) { Say 'portable AutoHotkey ready (nothing was installed system-wide)'; return $exe }
        } catch { Warn "that download failed: $($_.Exception.Message)" }
    }

    # Last resort: the official installer, silently, for all users.
    try {
        Say 'falling back to the AutoHotkey installer'
        $setup = Join-Path $env:TEMP 'ahk2-setup.exe'
        Invoke-WebRequest 'https://www.autohotkey.com/download/ahk-v2.exe' -OutFile $setup -UseBasicParsing
        Unblock-File $setup -ErrorAction SilentlyContinue
        Start-Process $setup -ArgumentList '/silent','/Elevate' -Wait
        Remove-Item $setup -Force -ErrorAction SilentlyContinue
        foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    } catch { }

    return $null
}

# ---------------------------------------------------------------------
#  Files
# ---------------------------------------------------------------------
function Get-Payload {
    param([string]$Dir)

    if ($Local) {
        $src = $PSScriptRoot
        Say "copying from $src"
        foreach ($f in $PAYLOAD) {
            $p = Join-Path $src $f
            if (-not (Test-Path $p)) { continue }
            if ($f -eq 'kiosk.ini' -and (Test-Path (Join-Path $Dir 'kiosk.ini'))) {
                Say 'kiosk.ini already exists - keeping your settings'
                continue
            }
            Copy-Item $p (Join-Path $Dir $f) -Force
        }
        return
    }

    $url = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
    Say "downloading $url"
    $zip = Join-Path $env:TEMP 'kiosk-payload.zip'
    $tmp = Join-Path $env:TEMP ('kiosk-payload-' + [guid]::NewGuid().ToString('N'))

    try { Invoke-WebRequest $url -OutFile $zip -UseBasicParsing }
    catch { Die "could not download the kiosk files from $url`n    Check that -Repo and -Branch are right and the repo is public.`n    ($($_.Exception.Message))" }

    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $root = Get-ChildItem $tmp -Directory | Select-Object -First 1
    if (-not $root) { Die 'the downloaded archive looked empty' }

    $copied = 0
    foreach ($f in $PAYLOAD) {
        $p = Get-ChildItem $root.FullName -Recurse -File -Filter $f -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $p) { continue }
        if ($f -eq 'kiosk.ini' -and (Test-Path (Join-Path $Dir 'kiosk.ini'))) {
            Say 'kiosk.ini already exists - keeping your settings'
            continue
        }
        Copy-Item $p.FullName (Join-Path $Dir $f) -Force
        $copied++
    }
    Get-ChildItem $Dir -File | Unblock-File -ErrorAction SilentlyContinue
    Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Say "$copied files installed to $Dir"

    if (-not (Test-Path (Join-Path $Dir 'kiosk-lock.ahk'))) {
        Die 'kiosk-lock.ahk was not in the repo. Check that all kiosk files are committed.'
    }
}

# ---------------------------------------------------------------------
#  Config
# ---------------------------------------------------------------------
function Set-IniValue {
    param([string]$Path,[string]$Key,[string]$Value)
    $lines = Get-Content $Path
    $hit = $false
    $out = foreach ($l in $lines) {
        if ($l -match "^\s*$([regex]::Escape($Key))\s*=") { $hit = $true; "$Key=$Value" } else { $l }
    }
    if (-not $hit) { $out += "$Key=$Value" }
    Set-Content -Path $Path -Value $out -Encoding UTF8
}

function Get-IniValue {
    param([string]$Path,[string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    foreach ($l in Get-Content $Path) {
        if ($l -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

function Set-Config {
    param([string]$Dir)
    $ini = Join-Path $Dir 'kiosk.ini'
    if (-not (Test-Path $ini)) { Die 'kiosk.ini is missing from the download' }

    $url = $AppUrl
    if (-not $url) {
        $current = Get-IniValue $ini 'AppUrl'
        if ($current -and $current -notmatch 'REPLACE_ME') {
            Say "keeping the existing URL: $current"
            $url = $current
        } elseif (-not $Unattended) {
            Write-Host ''
            Write-Host '  Paste the published Experience Builder app URL.' -ForegroundColor White
            Write-Host '  (Open the app in a browser and copy the address bar.)' -ForegroundColor DarkGray
            $url = (Read-Host '  URL').Trim().Trim('"')
        }
    }

    if ($url) {
        if ($url -notmatch '^https?://') { Warn "that does not look like a URL: $url" }
        Set-IniValue $ini 'AppUrl' $url
        Say "AppUrl set to $url"
    } else {
        Warn 'no URL set yet - the kiosk will open kiosk.ini for you on first start'
    }

    if ($IdleSeconds -gt 0) {
        Set-IniValue $ini 'IdleSeconds' $IdleSeconds
        Say "reset after $IdleSeconds seconds of inactivity"
    }
}

# ---------------------------------------------------------------------
#  Shortcuts
# ---------------------------------------------------------------------
function New-Shortcut {
    param([string]$Path,[string]$Target,[string]$Arguments,[string]$WorkDir,[string]$Icon,[string]$Description)
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath = $Target
    if ($Arguments)   { $sc.Arguments = $Arguments }
    if ($WorkDir)     { $sc.WorkingDirectory = $WorkDir }
    if ($Icon)        { $sc.IconLocation = $Icon }
    if ($Description) { $sc.Description = $Description }
    $sc.Save()
}

function Add-Shortcuts {
    param([string]$Dir,[string]$Ahk)

    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if (-not $desktop) { $desktop = [Environment]::GetFolderPath('Desktop') }
    $start = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Kiosk'
    New-Item -ItemType Directory -Force -Path $start | Out-Null

    $targets = @($desktop, $start)
    foreach ($t in $targets) {
        New-Shortcut -Path (Join-Path $t 'Start Kiosk.lnk') `
            -Target $Ahk -Arguments ('"' + (Join-Path $Dir 'kiosk-lock.ahk') + '"') `
            -WorkDir $Dir -Icon 'shell32.dll,14' `
            -Description 'Start the ArcGIS kiosk. Alt+F4 exits.'

        New-Shortcut -Path (Join-Path $t 'Kiosk settings.lnk') `
            -Target 'notepad.exe' -Arguments ('"' + (Join-Path $Dir 'kiosk.ini') + '"') `
            -WorkDir $Dir -Icon 'notepad.exe,0' `
            -Description 'Change the app URL and the reset timer.'

        New-Shortcut -Path (Join-Path $t 'Restore Desktop.lnk') `
            -Target "$env:SystemRoot\System32\cmd.exe" `
            -Arguments ('/c "' + (Join-Path $Dir 'restore-desktop.cmd') + '"') `
            -WorkDir $Dir -Icon 'shell32.dll,220' `
            -Description 'Unlock Windows if a kiosk session was interrupted.'
    }

    # What used to be done by setting the shell. A dedicated stand should
    # come straight back up after a power cut without anyone reaching
    # behind the screen; pair this with auto sign-in (netplwiz).
    $startup = Join-Path ([Environment]::GetFolderPath('CommonStartup')) 'Start Kiosk.lnk'
    New-Shortcut -Path $startup `
        -Target $Ahk -Arguments ('"' + (Join-Path $Dir 'kiosk-lock.ahk') + '"') `
        -WorkDir $Dir -Icon 'shell32.dll,14' `
        -Description 'Start the ArcGIS kiosk at sign-in.'
    Say 'the kiosk will start automatically at sign-in'

    Say "shortcuts created on the desktop and under Start > Kiosk"
}
# ---------------------------------------------------------------------
#  Power
# ---------------------------------------------------------------------
function Set-Power {
        foreach ($a in @('monitor-timeout-ac 0','monitor-timeout-dc 0',
                     'standby-timeout-ac 0','standby-timeout-dc 0',
                     'disk-timeout-ac 0','disk-timeout-dc 0',
                     'hibernate-timeout-ac 0','hibernate-timeout-dc 0')) {
        Start-Process powercfg -ArgumentList "/change $a" -Wait -WindowStyle Hidden
    }
    reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization' /v NoLockScreen /t REG_DWORD /d 1 /f | Out-Null
    Say 'screen blanking, sleep and the lock screen are off'
}

# ---------------------------------------------------------------------
#  Per-user policy, in the RIGHT user's hive
# ---------------------------------------------------------------------
# The whole point: reg import of a file full of HKEY_CURRENT_USER keys
# writes into whichever account UAC elevated us into. If the kiosk runs
# as a standard user - which is what SETUP.md recommends - that is the
# administrator, and the kiosk account ends up with no lockdown at all
# while the admin loses their own Task Manager.
function Get-KioskHive {
    param([string]$UserName)

    if ($UserName) {
        try {
            $sid = (New-Object Security.Principal.NTAccount($UserName)).Translate(
                       [Security.Principal.SecurityIdentifier]).Value
            if (Test-Path "Registry::HKEY_USERS\$sid") {
                return @{ Path = "Registry::HKEY_USERS\$sid"; Reg = "HKU\$sid"; Name = $UserName }
            }
            Warn "$UserName is not signed in, so their registry hive is not loaded."
            Warn 'Sign in as that account and run this again.'
        } catch {
            Warn "could not resolve '$UserName' to a SID: $($_.Exception.Message)"
        }
    }

    # Fall back to whoever owns the interactive Explorer.
    $p = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($p) {
        $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwner    -ErrorAction SilentlyContinue
        $osid  = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue
        if ($osid.Sid -and (Test-Path "Registry::HKEY_USERS\$($osid.Sid)")) {
            return @{ Path = "Registry::HKEY_USERS\$($osid.Sid)"
                      Reg  = "HKU\$($osid.Sid)"
                      Name = "$($owner.Domain)\$($owner.User)" }
        }
    }

    Warn 'Falling back to the hive of the account running this script.'
    return @{ Path = 'Registry::HKEY_CURRENT_USER'; Reg = 'HKCU'; Name = $env:USERNAME }
}

function Set-HiveValue {
    param($Base,[string]$SubKey,[string]$Name,$Value,[string]$Type = 'DWord')
    $p = Join-Path $Base $SubKey
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    New-ItemProperty -Path $p -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Set-UserPolicies {
    param($Hive,[bool]$On)

    $B = $Hive.Path
    $exp = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $sys = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'

    if ($On) {
        foreach ($n in 'NoWinKeys','NoRun','NoClose','NoLogoff','NoControlPanel',
                       'NoSetTaskbar','NoTrayContextMenu','NoViewContextMenu') {
            Set-HiveValue $B $exp $n 1
        }
        foreach ($n in 'DisableTaskMgr','DisableLockWorkstation','DisableChangePassword') {
            Set-HiveValue $B $sys $n 1
        }
        Set-HiveValue $B 'Software\Microsoft\Wisp\Touch' 'TouchMode_hold' 0
        Set-HiveValue $B 'Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
        Set-HiveValue $B 'Control Panel\Desktop' 'ScreenSaveActive'   '0' 'String'
        Set-HiveValue $B 'Control Panel\Desktop' 'ScreenSaverIsSecure' '0' 'String'
        Say "per-user policies applied to $($Hive.Name)"
    } else {
        Remove-Item (Join-Path $B $exp) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $B $sys) -Recurse -Force -ErrorAction SilentlyContinue
        Set-HiveValue $B 'Software\Microsoft\Wisp\Touch' 'TouchMode_hold' 1
        Set-HiveValue $B 'Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 1
        Set-HiveValue $B 'Control Panel\Desktop' 'ScreenSaveActive' '1' 'String'
        Say "per-user policies removed from $($Hive.Name)"
    }
}

# ---------------------------------------------------------------------
#  Lockdown
# ---------------------------------------------------------------------
function Invoke-Lockdown {
    param([string]$Dir)

    $reg = Join-Path $Dir 'kiosk-lockdown.reg'
    if (-not (Test-Path $reg)) { Die "kiosk-lockdown.reg not found in $Dir - run the installer first" }

    $hive = Get-KioskHive -UserName $KioskUser

    Write-Host ''
    Warn "Per-user settings will be written to the hive of: $($hive.Name)"
    Write-Host ''
    if (-not $Unattended) {
        $go = Read-Host "  Is $($hive.Name) the account the kiosk runs as? (y/n)"
        if ($go -notmatch '^[yY]') { Die 'Stopped. Sign in as the kiosk account and run this again.' }
    }

    Step 'Applying Windows and Edge restrictions'
    reg import $reg 2>&1 | Out-Null       # machine-wide policy only now
    Set-UserPolicies -Hive $hive -On $true
    Say 'policies applied'

    # Build the Edge URL allow list from the configured app URL, so the
    # kiosk cannot browse anywhere else and the app still works.
    $ini = Join-Path $Dir 'kiosk.ini'
    $url = Get-IniValue $ini 'AppUrl'
    $hosts = @('file:///' + $Dir.Replace('\','/').TrimEnd('/') + '/',              
                'arcgis.com', 'arcgisonline.com', 'arcgis.net',
                'vimeo.com', 'vimeocdn.com', 'sodir.no',
                'sidagis.github.io', 'githubusercontent.com',
                'fonts.googleapis.com', 'fonts.gstatic.com')
    if ($url -and $url -match '^https?://([^/:]+)') {
        $h = $Matches[1]
        $parts = $h.Split('.')
        if ($parts.Count -ge 2) { $hosts += ($parts[-2..-1] -join '.') }
        $hosts += $h
    }
    $key = 'HKLM\SOFTWARE\Policies\Microsoft\Edge\URLAllowlist'
    reg delete $key /f 2>&1 | Out-Null
    $i = 0
    foreach ($h in ($hosts | Select-Object -Unique)) {
        $i++
        reg add $key /v "$i" /t REG_SZ /d $h /f | Out-Null
    }
    Say "Edge may only reach: $(($hosts | Select-Object -Unique) -join ', ')"
    Warn 'if the map goes blank after this, a layer host is missing from that list'

    if ($SetShell) {
        $ahk = Get-AutoHotkey -Dir $Dir
        if (-not $ahk) { Die 'AutoHotkey not found - cannot set the shell' }
        $shell = '"' + $ahk + '" "' + (Join-Path $Dir 'kiosk-lock.ahk') + '"'
        # Must be the kiosk account's hive. Writing this into an admin
        # hive by mistake means the administrator signs in to a kiosk.
        reg add "$($hive.Reg)\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d $shell /f | Out-Null
        Say "the kiosk is now the Windows shell for $($hive.Name) ONLY"
        Warn 'Explorer will not start at next sign-in: no taskbar, no Start menu, no Task View'
        Warn 'Alt+F4 brings Explorer back for the rest of that session'
    }

    Write-Host ''
    Warn 'Ctrl+Alt+Del and Win+L cannot be fully blocked by software.'
    Warn 'The security screen is now stripped down, but keep the keyboard'
    Warn 'in the locked cabinet - see the notes in SETUP.md.'
}

# Reports whether this machine is actually locked down, for the account
# currently signed in. The per-user settings are the ones that get missed.
function Invoke-Verify {
    param([string]$Dir)

    $hive = Get-KioskHive -UserName $KioskUser
    Step "Checking lockdown for $($hive.Name)"
    $problems = @()

    # Session-scoped: an administrator signed in elsewhere used to make
    # this report a lockdown failure that was not real.
    $expl = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
                "$($o.Domain)\$($o.User)" -eq $hive.Name -or $o.User -eq ($hive.Name -split '\\')[-1]
            }
    if ($expl) {
        $problems += "Explorer is RUNNING for $($hive.Name) - the shell was not replaced. Taskbar, Start menu and edge swipes all work."
    }

    $shell = (Get-ItemProperty (Join-Path $hive.Path 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon') -Name Shell -ErrorAction SilentlyContinue).Shell
    if (-not $shell)                      { $problems += "no kiosk shell set for $($hive.Name)" }
    elseif ($shell -notmatch 'kiosk-lock'){ $problems += "the shell for $($hive.Name) is something else: $shell" }

    $checks = @(
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI'; Name='AllowEdgeSwipe'; Want=0; What='edge swipe from the screen sides' },
        @{ Path=(Join-Path $hive.Path 'Software\Microsoft\Windows\CurrentVersion\Policies\System');   Name='DisableTaskMgr';         Want=1; What='Task Manager' },
        @{ Path=(Join-Path $hive.Path 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'); Name='NoWinKeys';              Want=1; What='Windows key shortcuts' },
        @{ Path=(Join-Path $hive.Path 'Software\Microsoft\Windows\CurrentVersion\Policies\System');   Name='DisableLockWorkstation'; Want=1; What='Win+L lock' },
        @{ Path=(Join-Path $hive.Path 'Software\Microsoft\Wisp\Touch');                               Name='TouchMode_hold';         Want=0; What='press-and-hold right click' }
    )
    foreach ($c in $checks) {
        $v = (Get-ItemProperty $c.Path -Name $c.Name -ErrorAction SilentlyContinue).$($c.Name)
        if ($null -eq $v)      { $problems += "$($c.What): policy missing" }
        elseif ($v -ne $c.Want){ $problems += "$($c.What): set to $v, should be $($c.Want)" }
    }

    $allow = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLAllowlist' -ErrorAction SilentlyContinue
    if (-not $allow) { $problems += 'Edge URL allow list not set - the browser can reach anywhere' }

    Write-Host ''
    if ($problems.Count -eq 0) {
        Write-Host '  All clear on this machine, for this user.' -ForegroundColor Green
    } else {
        Write-Host "  $($problems.Count) problem(s) - THIS MACHINE IS NOT LOCKED DOWN" -ForegroundColor Red
        Write-Host ''
        foreach ($p in $problems) { Write-Host "   - $p" -ForegroundColor Yellow }
        Write-Host ''
        Say 'The per-user settings only apply to whoever is signed in when'
        Say 'you run the lockdown. Applying them from an administrator'
        Say 'account leaves the kiosk account untouched.'
        Say ''
        Say "Fix: sign in AS THE KIOSK ACCOUNT, then run lockdown-kiosk.cmd"
        Say 'and choose option 2.'
    }
}

function Invoke-Unlock {
    param([string]$Dir)

    # Revert a live session first, in case one is running.
    if (Get-ScheduledTask -TaskName 'ONS Kiosk Unlock' -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName 'ONS Kiosk Unlock'
        Start-Sleep -Seconds 5
    }

    $reg = Join-Path $Dir 'kiosk-unlock.reg'
    if (-not (Test-Path $reg)) { Die "kiosk-unlock.reg not found in $Dir" }
    $hive = Get-KioskHive -UserName $KioskUser

    Step 'Removing the restrictions'
    reg import $reg 2>&1 | Out-Null
    Set-UserPolicies -Hive $hive -On $false
    reg delete "$($hive.Reg)\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /f 2>&1 | Out-Null
    reg delete 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization' /v NoLockScreen /f 2>&1 | Out-Null
    Say 'Explorer will start normally at the next sign-in'
    Say 'sign out and back in, or reboot, to finish'
}
# ---------------------------------------------------------------------
#  Scheduled tasks
# ---------------------------------------------------------------------
# The lockdown runs as SYSTEM so it can write HKLM policy, stop services
# and reach the signed-in user's hive. The kiosk controller triggers
# these; it needs no admin rights of its own.
function Register-SessionTasks {
    param([string]$Dir)

    $script = Join-Path $Dir 'kiosk-session.ps1'
    if (-not (Test-Path $script)) { Die "kiosk-session.ps1 is missing from $Dir" }

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew

    $tasks = @(
        @{ Name = 'ONS Kiosk Lock';    Mode = 'Lock';    Trigger = $null },
        @{ Name = 'ONS Kiosk Unlock';  Mode = 'Unlock';  Trigger = $null },
        @{ Name = 'ONS Kiosk Recover'; Mode = 'Recover'; Trigger = (New-ScheduledTaskTrigger -AtLogOn) }
    )

    foreach ($t in $tasks) {
        Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction `
            -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Mode $($t.Mode) -Dir `"$Dir`""

        if ($t.Trigger) {
            Register-ScheduledTask -TaskName $t.Name -Action $action -Principal $principal `
                -Settings $settings -Trigger $t.Trigger | Out-Null
        } else {
            Register-ScheduledTask -TaskName $t.Name -Action $action -Principal $principal `
                -Settings $settings | Out-Null
        }
    }
    Say 'registered ONS Kiosk Lock / Unlock / Recover (SYSTEM, no UAC prompt)'

    # A standard stand account must be able to trigger Lock and Unlock, or
    # schtasks /run is denied and the kiosk silently runs unlocked.
    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $folder = $svc.GetFolder('\')
        $sddl = 'D:(A;;GA;;;BA)(A;;GA;;;SY)(A;;GRGX;;;AU)'
        foreach ($n in 'ONS Kiosk Lock','ONS Kiosk Unlock') {
            $folder.GetTask($n).SetSecurityDescriptor($sddl, 0)
        }
        Say 'task permissions widened so a standard user can trigger them'
    } catch {
        Warn "could not widen task permissions: $($_.Exception.Message)"
        Warn 'the kiosk account will need to be an administrator, or the lockdown will not apply'
    }
}

# =====================================================================
#  Main
# =====================================================================
Write-Host ''
Write-Host '  ArcGIS kiosk setup' -ForegroundColor White
Write-Host '  ------------------' -ForegroundColor DarkGray

if (-not (Test-Admin)) {
    Die "this needs administrator rights.`n    Close this window and use install-kiosk.cmd (right-click > Run as administrator)."
}

switch ($Mode) {

    'Unlock' {
        Invoke-Unlock -Dir $InstallDir
    }

    'Verify' {
        Invoke-Verify -Dir $InstallDir
    }

    'Tasks' {
        Step 'Re-registering the lockdown tasks'
        Register-SessionTasks -Dir $InstallDir
    }


    'Lockdown' {
        Invoke-Lockdown -Dir $InstallDir
    }

    'Install' {
        Step "Creating $InstallDir"
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

        Step 'Getting the kiosk files'
        Get-Payload -Dir $InstallDir

        Step 'Checking AutoHotkey'
        $ahk = Get-AutoHotkey -Dir $InstallDir
        if (-not $ahk) {
            Die "AutoHotkey v2 could not be installed automatically.`n    Install it from https://www.autohotkey.com and run this again."
        }

        Step 'Configuring'
        Set-Config -Dir $InstallDir

        Step 'Power settings'
        Set-Power

        Step 'Lockdown tasks'
        Register-SessionTasks -Dir $InstallDir

        Step 'Shortcuts'
        Add-Shortcuts -Dir $InstallDir -Ahk $ahk

        Write-Host ''
        Write-Host '  Done.' -ForegroundColor Green
        Write-Host ''
        Say 'Double-click "Start Kiosk" on the desktop to run it.'
        Say 'Alt+F4 exits. "Kiosk settings" edits the URL and the timer.'
        Write-Host ''
        Say 'Test it now: leave it alone for 25 seconds (it should reset),'
        Say 'then pan the map for a minute (it must NOT reset).'
        Write-Host ''
        Say 'When you are happy, run lockdown-kiosk.cmd to shut Windows out.'
    }
}


Write-Host ''
if (-not $Unattended) { Read-Host '  Press Enter to close' | Out-Null }
