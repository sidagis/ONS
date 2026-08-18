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
| `RevealDelayMs` | Loading screen hold after a cold load. Does not affect a fast reset |
| `FastReset` | Swap to a pre-loaded copy instead of reloading |
| `PrewarmSeconds` | How early to start building that copy |
| `MuteOutput` | Mute the playback device at every start |
| `HoldForAudio` | Hold the reset while Edge is producing audio |

While the kiosk is running there's a tray icon (invisible in full kiosk mode, since there's no taskbar) with **Reset app now**, **Edit kiosk.ini** and **Exit kiosk** — handy during testing.

## Not resetting during a video

A 25 second timeout and a 2 minute video are in direct conflict: someone watching touches nothing, so as far as Windows is concerned they left. The kiosk therefore holds the reset back while it believes a video is playing.

**Signal 1, Edge audio.** The controller walks the Windows audio sessions on the default playback device and looks for an active one owned by `msedge.exe`. No changes to the published app, so the same app still works normally on mobile.

The important detail: **mute the output device, never the player.** A muted output device still has Edge producing the stream — Windows just throws it away — so the session stays active and the detector keeps working. A video muted inside the Vimeo player produces no stream at all, and the detector goes blind. `MuteOutput=1` in `kiosk.ini` makes the controller mute the default playback device itself at every start, so nobody has to remember. There's a **Mute output again** item in the tray menu too.

Two consequences worth planning for. Your Vimeo embed must not be set to muted autoplay — the player has to be unmuted for this to work, which is fine because the device is silent anyway. And the kiosk needs a playback device that exists and is enabled: if the machine has no audio endpoint at all, there are no sessions to inspect, the detector switches itself off and writes a line to `C:\Kiosk\kiosk-log.txt`. HDMI audio to the display, muted, is the ideal arrangement. Unplugging the speakers is fine; disabling the device in Windows is not.

**Signal 2, screen motion — the backstop.** If the player has visible controls, a visitor can mute it by hand and signal 1 goes quiet. Set `VideoRect` and the controller samples a 4×4 grid of pixels inside that rectangle every second; while they keep changing, something is playing. A static poster frame doesn't trigger it. Given the mute constraint, it's worth setting this even if audio detection tests fine.

To set the rectangle: put `BlockMouseButtons=0` in `kiosk.ini` temporarily, start the kiosk, right-click the tray icon → **Mark video area**, then tap the two opposite corners of the video. It saves to `kiosk.ini` and takes effect immediately. Set `BlockMouseButtons` back to `1` afterwards.

Keep the rectangle inside the video. Point it at the map and an animated layer or a spinning progress indicator will hold the reset forever — well, until the ceiling.

**The ceiling.** `MaxHoldSeconds` (default 180) is measured from the last real touch, and nothing holds the reset past it. So the worst case with a stuck detector is a kiosk that resets three minutes late, not one that never resets. Longest video plus about a minute; for 2 minutes, 180.

**After the video.** `PostVideoSeconds` (default 20) is the gap between playback stopping and the reset firing.

Verify with the tray icon → **Status**, which shows what each detector sees right now, whether the output device is actually muted, and how the idle count compares to the threshold.

## Making the reset instant

A reload means Experience Builder starts from nothing: parse the bundle, build the map, fetch tiles. Trimming the loading screen only hides that, it doesn't remove it.

So with `FastReset=1` the wrapper doesn't reload at all. It keeps **two stacked copies** of the app. One is visible; the other sits behind it, already loaded and painted, at the published start state. A reset swaps their stacking order — instant, no loading screen, no network. The copy the last visitor used is then dropped, so between resets only one live instance is running.

The standby copy is built on demand, `PrewarmSeconds` (default 12) before the reset is due. The controller knows the idle time, so it triggers the prewarm; raise it if resets still show the loading screen, because that means the standby wasn't finished.

**How the controller talks to the page.** There are two 12-pixel transparent zones in the top corners: top-left means reset, top-right means prewarm. They ignore any pointer event that isn't `pointerType === "mouse"`, and the kiosk has no mouse — so a visitor's finger in the corner can't trigger anything, while an injected click can. The controller tries a posted click first, which moves no cursor at all, and only falls back to a real click if that's ignored.

**How it knows it worked — and why that's off by default.** The wrapper acknowledges a trigger two ways: it flips a 6-pixel marker in the bottom-left corner, and it bumps a token in `document.title`. The controller can read the pixel with `PixelGetColor` and the title with `WinGetTitle`.

On some Edge builds neither channel comes through: kiosk fullscreen doesn't always push `document.title` into the window text, and the pixel read can miss under display scaling. When that happens the swap works perfectly but is never confirmed, so the controller assumes failure and sends F5 — meaning you see a flawless instant reset immediately followed by a reload. The reload *is* the problem in that situation.

So `ResetFallback=0` is the default: one posted click, trusted, no verification and no reload. `last reset via` in the Status dialog will read `swap (unverified)`.

The cost of trusting it is that a swap which silently stopped working would leave the kiosk never resetting, with nothing to tell you. `IdleReloadMinutes` (default 30) closes that: after half an hour with no visitor input at all, the kiosk does one full reload. It only ever fires on a kiosk nobody is using, it can't interrupt anyone, and it doubles as ordinary housekeeping for a machine that runs for months. Set `ResetFallback=1` if you'd rather have the old immediate verification and are willing to accept the reload when it can't confirm.

**Resets need a visitor.** The controller only resets if somebody has actually touched the screen since the last reset — otherwise an unattended kiosk would swap to a fresh copy every 25 seconds all night, reloading Experience Builder thousands of times before morning. Prewarming is gated the same way. Status shows this as `visitor since`.

Two things to know. During the prewarm window there are briefly two Experience Builder instances live, which on weak hardware means two WebGL map contexts; if the kiosk PC is modest, watch memory during testing and lower `PrewarmSeconds` if it struggles. And the swapped-in copy was loaded 12-ish seconds earlier, so time-sensitive layers are that stale at the moment of the swap.

`RevealDelayMs` still applies, but only to the first cold load and the F5 fallback. It's 250 ms now instead of 1400.

`FastReset` needs the wrapper, so it's off automatically if you've set `StartUrl`.

## If ArcGIS refuses to be framed

Some ArcGIS Online and Portal configurations send `X-Frame-Options` or a `frame-ancestors` CSP that blocks framing from a `file://` origin. Symptom: the loading screen never goes away, and `kiosk-wrapper.html?debug=1` shows a framing error in the console.

**Fix, one line:** put the Experience URL in `StartUrl=` in `kiosk.ini`. Edge then loads the app directly. You lose the loading screen and the hidden URL; the idle reset, the lockdown and the watchdog are untouched, because the reset is an OS-level F5 either way.

**Better fix, if you have somewhere to host:** download the Experience as a deployable app from Experience Builder and serve it from the kiosk itself (IIS, or any static server on localhost), then point `AppUrl` at `http://localhost/experience/`. Same origin, and three things improve: the wrapper's own idle timer becomes live and precise, it can suppress context menus inside the app, and the kiosk keeps working through a network blip — only the map services need to be reachable, not the app shell.

## Diagnostics

Add `?debug=1` to the wrapper URL (temporarily set `StartUrl=file:///C:/Kiosk/kiosk-wrapper.html?debug=1`) for a corner overlay showing the app URL, whether the frame is same-origin, which idle timer is live, and seconds since the last event the page could see.

| Symptom | Likely cause |
|---|---|
| Resets while someone is using it | `IdleSeconds` too low, or the app is same-origin and both timers are running short |
| Resets during the video | No detector firing. Tray icon → **Status**: is the video muted in the *player* rather than the device, and is `VideoRect` unset? |
| Never resets after the video | A detector stuck on — usually a `VideoRect` covering something animated. `MaxHoldSeconds` caps the damage |
| Instant reset, then a loading screen | The swap wasn't acknowledged so the fallback reloaded. Set `ResetFallback=0` |
| Reset still shows the loading screen | The standby copy wasn't ready. Raise `PrewarmSeconds` |
| Mouse pointer parked in a corner | A real click was needed because the posted one was ignored. It hides again on the next touch |
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
