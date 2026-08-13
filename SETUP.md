# Kiosk reference

`README.md` covers installing and locking down. This file is the reference: what the installer did, what to change by hand, what can go wrong, and the limits of the lockdown.

## What ends up on the machine

```
C:\Kiosk\
  kiosk.ini              the only file you edit
  kiosk-lock.ahk         the controller
  kiosk-wrapper.html     the page Edge actually loads
  kiosk-config.js        generated from kiosk.ini at every start
  bin\AutoHotkey64.exe   portable AutoHotkey, if it wasn't already installed
  install-kiosk.ps1      kept locally so lockdown-kiosk.cmd can find it
  kiosk-lockdown.reg  kiosk-unlock.reg
C:\KioskProfile\         Edge's profile for the kiosk session
```

The **Start Kiosk** shortcut runs `AutoHotkey64.exe "C:\Kiosk\kiosk-lock.ahk"` — no batch file, so no console window flashes on a public screen. The controller needs no admin rights; the installer already applied the settings that did.

## How the reset works, and why it isn't plain JavaScript

Events inside a cross-origin iframe are invisible to the page that frames it. With the Experience served from `arcgis.com` and the wrapper loaded from `file://`, a JavaScript idle timer in the wrapper cannot see a single tap on the map — so it would reset the app every 25 seconds while someone was actively using it.

So idle detection happens at the OS level. `kiosk-lock.ahk` polls `A_TimeIdle`, which Windows updates on touch as well as mouse and keys, and sends F5 when it crosses the threshold. F5 reloads the wrapper, which reloads the app at its published URL, so the extent, panels and widget state all return to their starting values.

`A_TimeIdlePhysical` is deliberately not used: Windows can flag touch input as injected, which would make the reset fire under someone's finger.

The wrapper still carries its own timer, but it arms itself only after proving it can see events inside the frame — which happens only if the app is same-origin. Both mechanisms together are harmless.

## kiosk.ini

Everything is here, and `kiosk-lock.ahk` regenerates `kiosk-config.js` from it at every start, so the browser and the controller can't drift apart.

| Key | Notes |
|---|---|
| `AppUrl` | The published Experience URL |
| `IdleSeconds` | Reset threshold. Clamped to a minimum of 5 so a typo can't brick the kiosk |
| `BlockAllKeys` | Set to `0` while testing if the key blocking gets in your way |
| `BlockMouseButtons` | Blocks right-click, which is also what a long-press produces |
| `BlockWheel` | Only matters if a mouse is attached |
| `ExitToDesktop` | Alt+F4 also starts Explorer, so whoever exits gets a desktop |
| `StartUrl` | Set this to bypass the wrapper entirely — see below |
| `ClearProfileOnStart` | Wipes `C:\KioskProfile` at every start. Cleanest state, slower first load |
| `RevealDelayMs` | How long the loading screen stays up after the app reports ready |

While the kiosk is running there's a tray icon (invisible in full kiosk mode, since there's no taskbar) with **Reset app now**, **Edit kiosk.ini** and **Exit kiosk** — handy during testing.

## If ArcGIS refuses to be framed

Some ArcGIS Online and Portal configurations send `X-Frame-Options` or a `frame-ancestors` CSP that blocks framing from a `file://` origin. Symptom: the loading screen never goes away, and `kiosk-wrapper.html?debug=1` shows a framing error in the console.

**Fix, one line:** put the Experience URL in `StartUrl=` in `kiosk.ini`. Edge then loads the app directly. You lose the loading screen and the hidden URL; the idle reset, the lockdown and the watchdog are untouched, because the reset is an OS-level F5 either way.

**Better fix, if you have somewhere to host:** download the Experience as a deployable app from Experience Builder and serve it from the kiosk itself (IIS, or any static server on localhost), then point `AppUrl` at `http://localhost/experience/`. Same origin, and three things improve: the wrapper's own idle timer becomes live and precise, it can suppress context menus inside the app, and the kiosk keeps working through a network blip — only the map services need to be reachable, not the app shell.

## Diagnostics

Add `?debug=1` to the wrapper URL (temporarily set `StartUrl=file:///C:/Kiosk/kiosk-wrapper.html?debug=1`) for a corner overlay showing the app URL, whether the frame is same-origin, which idle timer is live, and seconds since the last event the page could see.

| Symptom | Likely cause |
|---|---|
| Resets while someone is using it | `IdleSeconds` too low, or the app is same-origin and both timers are running short |
| Never resets | AutoHotkey isn't running — check for the tray icon, or start it from the shortcut |
| Map is blank grey after lockdown | A layer or basemap host is missing from the Edge allow list. Re-run lockdown after fixing `AppUrl`, or add hosts under `HKLM\SOFTWARE\Policies\Microsoft\Edge\URLAllowlist` |
| Loading screen forever | Framing blocked, or no network. See above |
| Keys still work | `BlockAllKeys=0` in `kiosk.ini`, or the focused window is elevated — AutoHotkey can't block keys for a process running higher than itself |
| Console window flashes at sign-in | The shell is pointing at a `.cmd`. Point it at `AutoHotkey64.exe "C:\Kiosk\kiosk-lock.ahk"` instead |

## Setting the shell by hand

`lockdown-kiosk.cmd` option 2 writes this for you. To do it manually, signed in as the kiosk user:

```
HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon
  Shell  (REG_SZ)  =  "C:\Kiosk\bin\AutoHotkey64.exe" "C:\Kiosk\kiosk-lock.ahk"
```

This is what actually removes Windows from the picture: with Explorer never launched there is no taskbar, no Start menu, no Task View, no tray, and no Alt+Tab surface to reach. Use a dedicated local **standard** user for the kiosk, not an admin account.

Then enable auto sign-in for it (`netplwiz`, or Sysinternals Autologon), and in BIOS/UEFI turn on restore-on-AC-power-loss so the stand recovers from a power cut by itself.

## What the lockdown does not cover

**Ctrl+Alt+Del cannot be blocked** by any user-mode software, AutoHotkey included — the Secure Attention Sequence is handled below the keyboard hook. The policies strip the resulting screen down (no Task Manager, no lock, no sign-out, no switch user) but Cancel and shutdown remain.

**Win+L cannot be blocked** by a keyboard hook either; `DisableLockWorkstation` in the policy file is what neutralises it.

The complete fix for both is the **Keyboard Filter** feature, which needs Windows 10/11 **IoT Enterprise**:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Client-KeyboardFilter
```

It blocks SAS and the Windows key at driver level. On standard Pro or Enterprise it isn't available.

Given that: **don't leave a keyboard attached.** Keep one in the locked cabinet. Alt+F4 needs a keyboard anyway, so your escape hatch and your biggest exposure are the same device — the cabinet lock is doing more work here than any software.

Same for the ports. Blank off or fill unused USB sockets, disable USB boot, and set a UEFI password. None of the above matters against someone who can plug in a keyboard or boot from a stick.

## Windows Update

Set active hours outside opening times, or configure a scheduled reboot window. An unattended kiosk that reboots into a "Let's finish setting up your device" screen is the most common way these stands end up showing something other than your map.
