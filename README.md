# ArcGIS Experience Builder touch kiosk

Runs a published Experience Builder app fullscreen on a Windows touch kiosk. Resets itself after 25 seconds of inactivity, and shuts everything else on the machine out of reach.

## One-time setup on your GitHub repo

1. Put every file from this folder in the repo.
2. Open `install-kiosk.cmd` and `lockdown-kiosk.cmd` in Notepad and change the `REPO=` line to your `user/repo`.
3. Commit. The repo has to be public for the plain download to work.

## Installing on a kiosk machine

Download `install-kiosk.cmd` from the repo and double-click it. That's it.

Windows will show a SmartScreen warning on a freshly downloaded `.cmd` — **More info → Run anyway** — and then a UAC prompt. The installer then:

- downloads the rest of the files to `C:\Kiosk`
- installs AutoHotkey v2 if it isn't there (portable copy in `C:\Kiosk\bin`, nothing added to Programs and Features)
- asks you to paste the published Experience URL
- turns off screen blanking, sleep and the lock screen
- puts **Start Kiosk** and **Kiosk settings** on the desktop and in the Start menu

If you'd rather not download a `.cmd` file, run this in an **administrator** PowerShell instead:

```powershell
iwr https://raw.githubusercontent.com/YOURUSER/YOURREPO/main/install-kiosk.ps1 -OutFile "$env:TEMP\ik.ps1"; & "$env:TEMP\ik.ps1" -Repo YOURUSER/YOURREPO
```

## Test before locking anything down

Double-click **Start Kiosk**, then check all five:

1. The app fills the screen with no browser chrome.
2. Leave it alone 25 seconds → it reloads to the start extent.
3. **Pan the map continuously for a minute → it must NOT reset.**
4. Win, Alt+Tab, Ctrl+Shift+Esc, F11, F12, Ctrl+P, Esc → nothing happens.
5. Long-press the screen → no context menu.
6. Alt+F4 → the kiosk closes and the desktop comes back.

Keep a second machine or Remote Desktop handy while testing. The key blocker is thorough.

## Locking it down

Sign in as the account the kiosk will run under, then double-click **`lockdown-kiosk.cmd`**:

| Option | What it does |
|---|---|
| 1 | Windows + Edge restrictions: no Task Manager, no Win keys, no edge swipes, no long-press right-click, no devtools, and Edge may only reach your app's hosts |
| 2 | The same, plus makes the kiosk the Windows shell for this user, so Explorer never starts — no taskbar, no Start menu, no Task View |
| 3 | Removes all of it again for maintenance |

Option 2 is the real lockdown. Pair it with auto sign-in for that account (`netplwiz`, or Sysinternals Autologon) and the stand comes up straight into the app after a power cut.

Your admin account keeps a normal desktop — the shell setting is per-user.

## Changing the URL or the timer

**Kiosk settings** on the desktop opens `C:\Kiosk\kiosk.ini`. Change `AppUrl` or `IdleSeconds`, save, restart the kiosk. That one file drives both the browser wrapper and the reset timer.

25 seconds is short — someone reading a popup without touching anything gets reset out from under them. If you see that happen in the field, try 45.

## Videos in the app

The kiosk won't reset while a video is playing. Two signals feed that, either is enough:

1. **Edge is producing audio.** No changes to your published app, so it still behaves normally on mobile. **Mute the output device, not the player** — a muted device still leaves Edge producing the stream, which is what the detector sees. `MuteOutput=1` makes the kiosk mute the device itself at every start.
2. **Pixels in the video area keep changing.** The backstop for a visitor muting the player by hand. Tray icon → **Mark video area**, tap two opposite corners.

`MaxHoldSeconds` (default 180) caps the hold, measured from the last real touch, so a stuck detector can't park the kiosk forever. `PostVideoSeconds` is the pause between the video ending and the reset.

Check it with the tray icon → **Status** before the stand goes public. The tray menu needs `BlockMouseButtons=0` in `kiosk.ini` while you're setting up.

## Instant resets

With `FastReset=1` the reset doesn't reload anything. The wrapper keeps a second copy of the app loaded and painted behind the visible one, and a reset just swaps them — no loading screen, no network. The standby copy is built about 12 seconds before the reset is due (`PrewarmSeconds`) and thrown away after the swap, so only one live instance runs between resets.

If the standby isn't ready, it falls back to a normal reload by itself. Raise `PrewarmSeconds` if resets still show the loading screen.

## Updating

Commit the change, then re-run `install-kiosk.cmd` on the kiosk. It overwrites the program files and **leaves `kiosk.ini` alone**, so the URL and timer survive an update.

## Day-to-day

| | |
|---|---|
| Reset the app | Happens by itself 25 s after the last touch |
| Exit for maintenance | Alt+F4 (a keyboard is required) |
| Get back into kiosk mode | **Start Kiosk**, or reboot |
| Edge crashed | Relaunched automatically within ~3 seconds |
| Locked yourself out | `lockdown-kiosk.cmd` → option 3. Keep a copy on a USB stick |

## Read before it goes public

`SETUP.md` has the full reference, including the manual steps and the important part: **Ctrl+Alt+Del and Win+L cannot be blocked by any user-mode software.** The policies strip the security screen down to almost nothing, but the complete fix needs the Keyboard Filter feature from Windows IoT Enterprise. In practice: keep the keyboard in the locked cabinet, blank off unused USB ports, and set a UEFI password.

Also in `SETUP.md`: what to do if ArcGIS refuses to be framed (one line in `kiosk.ini`), and why self-hosting the app makes the setup better if you have somewhere to host it.

## Files

| File | Role |
|---|---|
| `install-kiosk.cmd` | Double-click installer / updater |
| `lockdown-kiosk.cmd` | Double-click lockdown menu |
| `install-kiosk.ps1` | The work behind both of the above |
| `kiosk.ini` | **The only file you edit** — URL, timer, options |
| `kiosk-lock.ahk` | Launches and supervises Edge, idle reset, key lockdown |
| `kiosk-wrapper.html` | Frames the app twice over, for instant swap resets |
| `kiosk-config.js` | Generated from `kiosk.ini` at every start — don't edit |
| `kiosk-lockdown.reg` / `kiosk-unlock.reg` | The Windows and Edge policies |
| `SETUP.md` | Full reference and caveats |
