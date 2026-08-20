#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreadsPerHotkey 1

; =====================================================================
;  kiosk-lock.ahk   -   ArcGIS Experience Builder touch kiosk controller
;
;  Configured entirely in kiosk.ini, which sits next to this file.
;
;  What it does:
;    * reads kiosk.ini and generates kiosk-config.js for the wrapper
;    * finds Microsoft Edge on its own
;    * launches Edge in kiosk mode and relaunches it if it dies
;    * resets the app after N seconds with no touch / mouse / key input
;    * holds that reset back while a video is playing (Edge audio, and
;      optionally motion inside a marked screen rectangle)
;    * mutes the Windows playback device, while keeping the audio signal
;      it depends on alive
;    * resets instantly by swapping to a pre-loaded copy of the app,
;      falling back to a plain reload if that is not available
;    * swallows every keystroke except Alt+F4
;
;  Needs no administrator rights.
; =====================================================================

Persistent
ProcessSetPriority "High"
CoordMode "Pixel", "Screen"
CoordMode "Mouse", "Screen"

global INI := A_ScriptDir "\kiosk.ini"
global LOGFILE := A_ScriptDir "\kiosk-log.txt"
global CFG := LoadConfig()
global exiting := false

global mediaLastSeen := 0          ; tick count when a video was last detected
global mediaWhy := ""              ; which detector saw it
global lastResetHow := "-"         ; diagnostics

; The kiosk injects mouse clicks and keystrokes of its own, and Windows
; counts those as user input. So idle time is tracked here rather than
; read straight from A_TimeIdle - see UpdateIdle().
global lastRealInput := A_TickCount
global suppressUntil := 0
global warmSent := false
global inputSinceReset := false    ; has a visitor touched it since the last reset
global houseKept := false

global motionPrev := ""            ; previous pixel sample of the video area
global motionHist := []            ; rolling record of which samples changed
global motionPlaying := false
global motionPct := 0
global meterUntil := 0

global EDGE_EXE := FindEdge()
if (EDGE_EXE = "") {
    MsgBox "Microsoft Edge could not be found.`n`nInstall Edge, or set EdgeExe= in kiosk.ini to the full path of msedge.exe.", "Kiosk", 0x10
    ExitApp
}

if (CFG["AppUrl"] = "" || InStr(CFG["AppUrl"], "REPLACE_ME")) {
    MsgBox "The Experience URL has not been set yet.`n`nkiosk.ini will open now. Paste your published app URL after`n`nAppUrl=`n`nthen save the file and start the kiosk again.", "Kiosk is not configured", 0x30
    try Run 'notepad.exe "' INI '"'
    ExitApp
}

global USES_WRAPPER := (CFG["StartUrl"] = "") && FileExist(A_ScriptDir "\kiosk-wrapper.html")
global START_URL := BuildStartUrl()
global EDGE_ARGS := BuildEdgeArgs()

; --------------------------- start up --------------------------------
KeepAwake()
if (CFG["MuteOutput"])
    MuteOutput()
KillStaleEdge()
if (CFG["ClearProfileOnStart"])
    try DirDelete CFG["UserDataDir"], true
StartEdge()

if (CFG["BlockAllKeys"])
    InstallKeyBlocks()

SetTimer IdleWatch, 1000
SetTimer EdgeWatch, 3000
SetTimer MotionTick, CFG["MotionSampleMs"]

BuildTrayMenu()
return

; =====================================================================
;  Configuration
; =====================================================================
LoadConfig() {
    global INI
    c := Map()
    c["AppUrl"]              := Trim(IniRead(INI, "Kiosk", "AppUrl", ""))
    c["StartUrl"]            := Trim(IniRead(INI, "Kiosk", "StartUrl", ""))
    c["EdgeExe"]             := Trim(IniRead(INI, "Kiosk", "EdgeExe", ""))
    c["UserDataDir"]         := Trim(IniRead(INI, "Kiosk", "UserDataDir", "C:\KioskProfile"))
    c["IdleSeconds"]         := NumOr(IniRead(INI, "Kiosk", "IdleSeconds", 25), 25)
    c["LoadTimeoutSeconds"]  := NumOr(IniRead(INI, "Kiosk", "LoadTimeoutSeconds", 25), 25)
    c["RevealDelayMs"]       := NumOr(IniRead(INI, "Kiosk", "RevealDelayMs", 250), 250)
    c["BlockAllKeys"]        := NumOr(IniRead(INI, "Kiosk", "BlockAllKeys", 1), 1)
    c["BlockMouseButtons"]   := NumOr(IniRead(INI, "Kiosk", "BlockMouseButtons", 1), 1)
    c["BlockWheel"]          := NumOr(IniRead(INI, "Kiosk", "BlockWheel", 0), 0)
    c["ExitToDesktop"]       := NumOr(IniRead(INI, "Kiosk", "ExitToDesktop", 1), 1)
    c["ClearProfileOnStart"] := NumOr(IniRead(INI, "Kiosk", "ClearProfileOnStart", 0), 0)

    c["HoldForAudio"]        := NumOr(IniRead(INI, "Kiosk", "HoldForAudio", 1), 1)
    c["AudioAnyProcess"]     := NumOr(IniRead(INI, "Kiosk", "AudioAnyProcess", 1), 1)
    c["MuteOutput"]          := NumOr(IniRead(INI, "Kiosk", "MuteOutput", 1), 1)
    c["DisableVideoOverlay"] := NumOr(IniRead(INI, "Kiosk", "DisableVideoOverlay", 1), 1)
    c["VideoRect"]           := Trim(IniRead(INI, "Kiosk", "VideoRect", ""))
    c["MotionSampleMs"]      := NumOr(IniRead(INI, "Kiosk", "MotionSampleMs", 250), 250)
    c["MotionWindowMs"]      := NumOr(IniRead(INI, "Kiosk", "MotionWindowMs", 3000), 3000)
    c["MotionSustainPercent"]:= NumOr(IniRead(INI, "Kiosk", "MotionSustainPercent", 70), 70)
    c["MotionPointsPercent"] := NumOr(IniRead(INI, "Kiosk", "MotionPointsPercent", 15), 15)
    c["MaxHoldSeconds"]      := NumOr(IniRead(INI, "Kiosk", "MaxHoldSeconds", 180), 180)
    c["PostVideoSeconds"]    := NumOr(IniRead(INI, "Kiosk", "PostVideoSeconds", 20), 20)

    c["FastReset"]           := NumOr(IniRead(INI, "Kiosk", "FastReset", 1), 1)
    c["PrewarmSeconds"]      := NumOr(IniRead(INI, "Kiosk", "PrewarmSeconds", 12), 12)
    c["ResetFallback"]       := NumOr(IniRead(INI, "Kiosk", "ResetFallback", 0), 0)
    c["IdleReloadMinutes"]   := NumOr(IniRead(INI, "Kiosk", "IdleReloadMinutes", 30), 30)

    if (c["IdleSeconds"] < 5)                          ; a typo must not brick the kiosk
        c["IdleSeconds"] := 5
    if (c["MaxHoldSeconds"] < c["IdleSeconds"] + 10)    ; a hold shorter than the timeout is meaningless
        c["MaxHoldSeconds"] := c["IdleSeconds"] + 10
    if (c["PrewarmSeconds"] > c["IdleSeconds"] - 3)     ; must leave time to actually load
        c["PrewarmSeconds"] := Max(3, c["IdleSeconds"] - 3)

    c["Rect"] := ParseRect(c["VideoRect"])
    return c
}

NumOr(value, fallback) {
    if IsNumber(Trim(value))
        return Integer(Trim(value))
    return fallback
}

ParseRect(s) {
    parts := StrSplit(Trim(s), ",")
    if (parts.Length != 4)
        return ""
    r := []
    for p in parts {
        if !IsNumber(Trim(p))
            return ""
        r.Push(Integer(Trim(p)))
    }
    if (r[3] <= r[1] || r[4] <= r[2])
        return ""
    return r
}

FindEdge() {
    global CFG
    if (CFG["EdgeExe"] != "" && FileExist(CFG["EdgeExe"]))
        return CFG["EdgeExe"]

    for p in [ EnvGet("ProgramFiles(x86)") "\Microsoft\Edge\Application\msedge.exe"
             , EnvGet("ProgramFiles")      "\Microsoft\Edge\Application\msedge.exe"
             , "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
             , "C:\Program Files\Microsoft\Edge\Application\msedge.exe" ]
        if (p != "" && FileExist(p))
            return p

    try {
        p := RegRead("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe", "")
        if (p != "" && FileExist(p))
            return p
    }
    return ""
}

BuildStartUrl() {
    global CFG, USES_WRAPPER
    if (CFG["StartUrl"] != "")
        return CFG["StartUrl"]
    if (USES_WRAPPER) {
        WriteWrapperConfig()
        return "file:///" StrReplace(A_ScriptDir "\kiosk-wrapper.html", "\", "/")
    }
    return CFG["AppUrl"]
}

; The wrapper reads this, so kiosk.ini stays the single source of truth.
WriteWrapperConfig() {
    global CFG
    f := A_ScriptDir "\kiosk-config.js"
    js := "/* Generated from kiosk.ini by kiosk-lock.ahk. Do not edit. */`n"
        . "window.KIOSK_CONFIG = {`n"
        . '  appUrl: "' JsEsc(CFG["AppUrl"]) '",`n'
        . "  idleSeconds: "        CFG["IdleSeconds"] ",`n"
        . "  loadTimeoutSeconds: " CFG["LoadTimeoutSeconds"] ",`n"
        . "  revealDelayMs: "      CFG["RevealDelayMs"] ",`n"
        . "  fastReset: "          (CFG["FastReset"] ? "true" : "false") ",`n"
        . "  retrySeconds: 10`n"
        . "};`n"
    try FileDelete f
    try FileAppend js, f, "UTF-8-RAW"
}

JsEsc(s) => StrReplace(StrReplace(s, "\", "\\"), '"', '\"')

BuildEdgeArgs() {
    global CFG, START_URL
    ; Hardware video overlays can put video frames on a separate plane
    ; that never reaches the composited desktop image - so a screen
    ; sample of a playing video reads as a static black rectangle and the
    ; motion detector sees nothing. Turning overlays off costs a little
    ; video efficiency and makes the pixels readable.
    overlay := CFG["DisableVideoOverlay"]
        ? ' --disable-direct-composition-video-overlays'
        . ' --disable-features=DirectCompositionVideoSwapChain,UseMultiPlaneFormatForHardwareVideo'
        : ''
    return '--kiosk "' START_URL '"' overlay
        . ' --edge-kiosk-type=fullscreen'
        . ' --kiosk-idle-timeout-minutes=0'
        . ' --user-data-dir="' CFG["UserDataDir"] '"'
        . ' --no-first-run --no-default-browser-check --disable-sync'
        . ' --noerrdialogs --disable-session-crashed-bubble --hide-crash-restore-bubble'
        . ' --disable-infobars --disable-popup-blocking'
        . ' --disable-features=TranslateUI,EdgeShoppingAssistant,msEdgeSidebar,EdgeSplitScreen,msWebOOUI'
        . ' --disable-pinch --overscroll-history-navigation=0'
        . ' --disable-backgrounding-occluded-windows'
        . ' --disable-background-timer-throttling --disable-renderer-backgrounding'
        . ' --autoplay-policy=no-user-gesture-required'
        . ' --check-for-update-interval=31536000'
        . ' --start-fullscreen'
}

; =====================================================================
;  Idle tracking
; =====================================================================
; Our own injected clicks and keystrokes update the Windows "last input"
; time, which would keep pushing the reset out of reach. So the real
; idle clock is kept here, and updates from A_TimeIdle are ignored for a
; moment after we inject anything. If a visitor really does touch the
; screen during that window, the next tick still picks it up, because
; A_TimeIdle keeps counting from their touch.
UpdateIdle() {
    global lastRealInput, suppressUntil, inputSinceReset, houseKept
    t := A_TickCount - A_TimeIdle
    if (t > lastRealInput && A_TickCount > suppressUntil) {
        lastRealInput := t
        inputSinceReset := true       ; a real visitor, not one of our clicks
        houseKept := false
    }
}

Injecting(ms := 1500) {
    global suppressUntil
    suppressUntil := A_TickCount + ms
}

IdleMs() {
    global lastRealInput
    return A_TickCount - lastRealInput
}

; =====================================================================
;  The main loop
; =====================================================================
IdleWatch() {
    global CFG, exiting, mediaLastSeen, mediaWhy, lastRealInput, warmSent, USES_WRAPPER
    global inputSinceReset, houseKept
    static fired := false

    if (exiting)
        return

    UpdateIdle()

    ; Sample the detectors every tick, not only once idle - the motion
    ; detector needs two consecutive samples before it can say anything.
    why := DetectVideo()
    if (why != "") {
        mediaLastSeen := A_TickCount
        mediaWhy := why
    }

    idle := IdleMs()

    if (idle < CFG["IdleSeconds"] * 1000) {
        fired := false

        ; Start loading the standby copy shortly before the reset is due,
        ; so the swap is instant when it happens. Only worth doing if
        ; somebody has actually used the app since the last reset.
        if (CFG["FastReset"] && USES_WRAPPER && !warmSent && inputSinceReset
            && idle >= (CFG["IdleSeconds"] - CFG["PrewarmSeconds"]) * 1000) {
            warmSent := true
            TapZone("warm")
        }
        return
    }

    ; Nobody has touched the screen since the last reset, so the app is
    ; already sitting on its front page. Resetting again would just churn
    ; through the night - but do one full reload after a long quiet spell,
    ; as housekeeping and as a safety net in case a swap silently failed.
    if (!inputSinceReset) {
        if (CFG["IdleReloadMinutes"] > 0 && !houseKept
            && idle >= CFG["IdleReloadMinutes"] * 60000) {
            houseKept := true
            LogLine("housekeeping reload after " CFG["IdleReloadMinutes"] " idle minutes")
            HardReload()
            lastRealInput := A_TickCount
        }
        return
    }

    ; Idle threshold passed. Hold the reset back if a video was seen
    ; recently, unless we have been holding past the ceiling.
    if (mediaLastSeen
        && (A_TickCount - mediaLastSeen) < CFG["PostVideoSeconds"] * 1000
        && idle < CFG["MaxHoldSeconds"] * 1000)
        return

    if (!fired) {
        fired := true
        mediaLastSeen := 0
        mediaWhy := ""
        ResetApp()
        lastRealInput := A_TickCount     ; the idle clock restarts now
        inputSinceReset := false
        warmSent := false
    }
}

; Returns the name of whichever detector saw a video, or "".
DetectVideo() {
    global CFG, motionPlaying
    if (CFG["HoldForAudio"] && EdgeAudioActive())
        return "Edge audio"
    if (CFG["Rect"] != "" && motionPlaying)
        return "screen motion"
    return ""
}

; =====================================================================
;  Video detection
; =====================================================================
; --- Edge is feeding audio to Windows --------------------------------
; Walks the audio sessions on the default playback device and looks for
; an active one owned by msedge.exe. A muted OUTPUT does not affect
; this: Edge still produces the stream, Windows just discards it. A
; video muted inside the player is a different matter - then Edge
; produces nothing and this detector goes quiet.
EdgeAudioActive() {
    global CFG
    static broken := false
    if (broken)
        return false

    try {
        for s in EnumAudioSessions() {
            if (s["state"] != 1)                  ; 1 = AudioSessionStateActive
                continue
            if (CFG["AudioAnyProcess"])
                return true
            ; Edge renders audio from a utility child process, also named
            ; msedge.exe. An unknown owner counts, because failing to read
            ; the name should not mean failing to see the video.
            if (s["name"] = "" || s["name"] = "msedge.exe")
                return true
        }
    } catch as e {
        broken := true
        LogLine("audio detection unavailable, switching it off: " e.Message)
    }
    return false
}

; Returns an array of Maps: state (0 inactive, 1 active, 2 expired),
; pid, name. Throws if the audio stack cannot be reached at all.
EnumAudioSessions() {
    sessions := []

    ; MMDeviceEnumerator -> default render endpoint
    enum := ComObject("{BCDE0395-E52F-467C-8E3D-C4579291692E}"
                    , "{A95664D2-9614-4F35-A746-DE8DB63617E6}")
    ComCall(4, enum, "int", 0, "int", 1, "ptr*", &devPtr := 0)   ; GetDefaultAudioEndpoint(eRender, eMultimedia)
    dev := ComValue(13, devPtr)

    ; IMMDevice::Activate(IAudioSessionManager2)
    iid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "wstr", "{77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F}", "ptr", iid)
    ComCall(3, dev, "ptr", iid, "uint", 0, "ptr", 0, "ptr*", &mgrPtr := 0)
    mgr := ComValue(13, mgrPtr)

    ComCall(5, mgr, "ptr*", &sePtr := 0)                        ; GetSessionEnumerator
    se := ComValue(13, sePtr)
    ComCall(3, se, "int*", &count := 0)                         ; GetCount

    Loop count {
        ComCall(4, se, "int", A_Index - 1, "ptr*", &scPtr := 0) ; GetSession
        sc := ComValue(13, scPtr)

        state := -1
        ComCall(3, sc, "int*", &state)                          ; IAudioSessionControl::GetState

        pid := 0, name := ""
        try {
            sc2 := ComObjQuery(sc, "{BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D}")
            ComCall(14, sc2, "uint*", &pid)                     ; IAudioSessionControl2::GetProcessId
            name := ProcessGetName(pid)
        }
        sessions.Push(Map("state", state, "pid", pid, "name", name))
    }
    return sessions
}

; --- Pixels in the video area keep changing --------------------------
; The backstop for a video muted in the player.
;
; The hard part is telling a video apart from a rotating image banner,
; which also changes pixels and may sit in or beside the same area. What
; separates them is not whether the pixels change but how CONSTANTLY:
;
;   a video      changes on essentially every frame, all the time
;   a carousel   changes for a moment, then holds still for seconds
;
; So the area is sampled several times a second and a rolling window of
; recent comparisons is kept. Playback is declared only when most of that
; window shows change. A banner rotating every few seconds scores maybe
; 20-30%; a video scores close to 100%.
;
; Sampling only runs in the seconds around the reset deadline, so it
; costs nothing while somebody is actually using the kiosk.

MotionTick() {
    global CFG, motionPrev, motionHist, motionPlaying, motionPct, meterUntil

    r := CFG["Rect"]
    if (r = "")
        return

    ; Only sample when a decision is close, with enough lead time to fill
    ; the window first - unless the tuning meter is running.
    lead := CFG["MotionWindowMs"] + 3000
    if (A_TickCount > meterUntil && IdleMs() < CFG["IdleSeconds"] * 1000 - lead) {
        if (motionHist.Length) {
            motionHist := []
            motionPrev := ""
            motionPlaying := false
            motionPct := 0
        }
        return
    }

    sig := []
    N := 4
    Loop N {
        ix := A_Index
        Loop N {
            iy := A_Index
            x := Round(r[1] + (r[3] - r[1]) * (ix - 0.5) / N)
            y := Round(r[2] + (r[4] - r[2]) * (iy - 0.5) / N)
            try sig.Push(PixelGetColor(x, y))
            catch
                sig.Push(0)
        }
    }

    if (motionPrev != "" && motionPrev.Length = sig.Length) {
        moved := 0
        Loop sig.Length
            if (sig[A_Index] != motionPrev[A_Index])
                moved++

        ; A frame counts as "moving" only if a fair share of the sample
        ; points changed - a single flickering pixel is not a video.
        movingFrame := (moved * 100 / sig.Length) >= CFG["MotionPointsPercent"]
        motionHist.Push(movingFrame ? 1 : 0)

        cap := Max(4, Round(CFG["MotionWindowMs"] / CFG["MotionSampleMs"]))
        while (motionHist.Length > cap)
            motionHist.RemoveAt(1)

        if (motionHist.Length >= cap) {
            hits := 0
            for v in motionHist
                hits += v
            motionPct := Round(hits * 100 / motionHist.Length)

            ; Hysteresis: harder to start than to keep going, so a quiet
            ; passage in the video does not drop the hold.
            enter := CFG["MotionSustainPercent"]
            leave := Max(20, enter // 2)
            motionPlaying := motionPlaying ? (motionPct >= leave) : (motionPct >= enter)
        }
    }
    motionPrev := sig
}

MotionSummary() {
    global CFG, motionPlaying, motionPct, motionHist
    if (CFG["Rect"] = "")
        return "off, no VideoRect set"
    if (motionHist.Length = 0)
        return "idle, sampling starts near the reset deadline"
    return motionPct "% sustained -> " (motionPlaying ? "PLAYING" : "not a video")
}

; =====================================================================
;  Audio output mute
; =====================================================================
; Mutes the default playback device. Deliberately mutes the DEVICE, not
; the video, so EdgeAudioActive() keeps working: Edge goes on producing
; the stream and Windows discards it.
MuteOutput() {
    try {
        enum := ComObject("{BCDE0395-E52F-467C-8E3D-C4579291692E}"
                        , "{A95664D2-9614-4F35-A746-DE8DB63617E6}")
        ComCall(4, enum, "int", 0, "int", 1, "ptr*", &devPtr := 0)
        dev := ComValue(13, devPtr)

        iid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "wstr", "{5CDF2C82-841E-4546-9722-0CF74078229A}", "ptr", iid)   ; IAudioEndpointVolume
        ComCall(3, dev, "ptr", iid, "uint", 0, "ptr", 0, "ptr*", &volPtr := 0)
        vol := ComValue(13, volPtr)

        ComCall(14, vol, "int", 1, "ptr", 0)      ; SetMute(TRUE, NULL)
        LogLine("playback device muted")
        return true
    } catch as e {
        LogLine("could not mute the playback device: " e.Message)
        return false
    }
}

OutputIsMuted() {
    try {
        enum := ComObject("{BCDE0395-E52F-467C-8E3D-C4579291692E}"
                        , "{A95664D2-9614-4F35-A746-DE8DB63617E6}")
        ComCall(4, enum, "int", 0, "int", 1, "ptr*", &devPtr := 0)
        dev := ComValue(13, devPtr)
        iid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "wstr", "{5CDF2C82-841E-4546-9722-0CF74078229A}", "ptr", iid)
        ComCall(3, dev, "ptr", iid, "uint", 0, "ptr", 0, "ptr*", &volPtr := 0)
        vol := ComValue(13, volPtr)
        ComCall(15, vol, "int*", &muted := 0)     ; GetMute
        return muted ? "muted" : "NOT muted"
    }
    return "unknown"
}

; =====================================================================
;  Reset
; =====================================================================
ResetApp() {
    global CFG, USES_WRAPPER, lastResetHow

    if (CFG["FastReset"] && USES_WRAPPER) {

        ; Trust the swap. One posted click, no verification, no reload.
        ; Use this when resets work but are never acknowledged - the
        ; fallback then fires every single time, and the reload it does is
        ; exactly the loading screen fast reset exists to avoid.
        if (!CFG["ResetFallback"]) {
            TapZone("reset", false)
            lastResetHow := "swap (unverified)"
            return
        }

        tokBefore := ResetToken()
        pixBefore := AckPixel()
        if (tokBefore != "" || pixBefore != "") {
            TapZone("reset", false)                  ; try without moving the cursor
            if (WaitForAck(tokBefore, pixBefore, 900)) {
                lastResetHow := "swap (posted click)"
                return
            }
            TapZone("reset", true)                   ; real click
            if (WaitForAck(tokBefore, pixBefore, 1200)) {
                lastResetHow := "swap (click)"
                return
            }
            lastResetHow := "reload (no acknowledgement)"
            LogLine("fast reset was not acknowledged - falling back to reload")
        }
    }

    HardReload()
}

; Two independent acknowledgement channels, because either one alone can
; be unreliable: Chromium in kiosk fullscreen does not always push
; document.title into the window text, and a posted click is not always
; honoured. Any change in either means the click landed.
WaitForAck(tokBefore, pixBefore, timeoutMs) {
    t0 := A_TickCount
    while (A_TickCount - t0 < timeoutMs) {
        Sleep 40
        t := ResetToken()
        if (t != "" && t != tokBefore)
            return true
        p := AckPixel()
        if (p != "" && p != pixBefore)
            return true
    }
    return false
}

; The wrapper flips a 6px marker in the bottom-left corner on every
; trigger. Reading a pixel is not subject to any of the window-text
; quirks, so this is the channel that actually carries the answer.
AckPixel() {
    hwnd := KioskWindow()
    if (!hwnd)
        return ""
    try {
        WinGetPos &wx, &wy, &ww, &wh, hwnd
        return PixelGetColor(wx + 3, wy + wh - 4)
    }
    return ""
}

; WinExist("ahk_exe msedge.exe") can return one of Edge's hidden helper
; windows, whose title never changes. Pick the largest visible one.
KioskWindow() {
    static cached := 0
    if (cached && WinExist("ahk_id " cached))
        return cached

    best := 0, bestArea := 0
    try {
        for h in WinGetList("ahk_exe msedge.exe") {
            try WinGetPos &x, &y, &w, &ht, h
            catch
                continue
            if (w * ht > bestArea) {
                bestArea := w * ht
                best := h
            }
        }
    }
    cached := best
    return best
}

HardReload() {
    global lastResetHow
    hwnd := KioskWindow()
    if (!hwnd)
        return
    try {
        WinActivate hwnd
        WinWaitActive hwnd, , 2
    }
    Injecting()
    SendInput "{F5}"
    lastResetHow := "reload"
}

; Reads the token the wrapper publishes in its title, e.g. "Kiosk|r7f3a-2".
ResetToken() {
    try {
        if (hwnd := KioskWindow()) {
            t := WinGetTitle(hwnd)
            if RegExMatch(t, "\|r([^|]+)", &m)
                return m[1]
        }
    }
    return ""
}

; which = "reset" (top-left) or "warm" (top-right)
TapZone(which, realClick := true) {
    hwnd := KioskWindow()
    if (!hwnd)
        return
    try {
        WinActivate hwnd
        WinGetPos &wx, &wy, &ww, &wh, hwnd
    } catch
        return

    cx := (which = "reset") ? 4 : ww - 5          ; client coordinates
    cy := 4

    Injecting()
    if (!realClick) {
        ; Posted message: no cursor movement, no visible pointer. Chromium
        ; does not always honour these, hence the verification upstairs.
        try ControlClick "X" cx " Y" cy, hwnd, , "Left", 1, "NA"
        return
    }

    MouseGetPos &ox, &oy
    try Click(wx + cx, wy + cy)
    try MouseMove ox, oy, 0
}

; =====================================================================
;  Watchdog and housekeeping
; =====================================================================
EdgeWatch() {
    global exiting
    if (exiting)
        return
    if (!ProcessExist("msedge.exe")) {
        Sleep 800
        StartEdge()
    }
}

StartEdge() {
    global EDGE_EXE, EDGE_ARGS
    try Run '"' EDGE_EXE '" ' EDGE_ARGS
    catch as e
        MsgBox "Could not start Edge:`n`n" e.Message, "Kiosk", 0x10
}

KillStaleEdge() {
    try RunWait A_ComSpec ' /c taskkill /f /im msedge.exe', , "Hide"
    Sleep 1200
}

KeepAwake() {
    ; Silently does nothing if not elevated - the installer already
    ; applied these once with admin rights.
    try RunWait A_ComSpec ' /c powercfg /change monitor-timeout-ac 0'
                        . ' & powercfg /change standby-timeout-ac 0'
                        . ' & powercfg /change disk-timeout-ac 0'
                        . ' & powercfg /change hibernate-timeout-ac 0', , "Hide"
}

; Named LOGFILE, not LOG: variables and functions share one namespace in
; AutoHotkey v2, and Log() is the built-in natural logarithm.
LogLine(text) {
    global LOGFILE
    try FileAppend FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " text "`n", LOGFILE, "UTF-8-RAW"
}

; =====================================================================
;  Tray menu (setup and diagnostics)
;  Reachable only while BlockMouseButtons=0 in kiosk.ini, and invisible
;  in full kiosk mode because there is no taskbar.
; =====================================================================
BuildTrayMenu() {
    global CFG, INI
    m := A_TrayMenu
    m.Delete()
    m.Add("Status", (*) => ShowStatus())
    m.Add("Motion meter (30s)", (*) => MotionMeter())
    m.Add("Audio sessions", (*) => ShowAudioSessions())
    m.Add("Mark video area", (*) => MarkVideoArea())
    m.Add()
    m.Add("Reset app now", (*) => ResetApp())
    m.Add("Hard reload now", (*) => HardReload())
    m.Add("Mute output again", (*) => MuteOutput())
    m.Add("Edit kiosk.ini", (*) => Run('notepad.exe "' INI '"'))
    m.Add()
    m.Add("Exit kiosk", (*) => ExitKiosk())
    TraySetIcon "shell32.dll", 14
    A_IconTip := "Kiosk - resets after " CFG["IdleSeconds"] "s idle - Alt+F4 to exit"
}

ShowStatus() {
    global CFG, mediaLastSeen, mediaWhy, lastResetHow, USES_WRAPPER, inputSinceReset
    live := DetectVideo()
    ago := mediaLastSeen ? Round((A_TickCount - mediaLastSeen) / 1000) " s ago" : "never"
    tok := ResetToken()
    MsgBox ""
        . "VIDEO`n"
        . "  right now:      " (live = "" ? "nothing detected" : "detected by " live) "`n"
        . "  last detected:  " ago (mediaWhy != "" ? " (" mediaWhy ")" : "") "`n"
        . "  Edge audio:     " (CFG["HoldForAudio"] ? (EdgeAudioActive() ? "PLAYING" : "quiet") : "off") "`n"
        . "  screen motion:  " MotionSummary() "`n"
        . "  output device:  " OutputIsMuted() "`n`n"
        . "IDLE`n"
        . "  now:            " Round(IdleMs() / 1000) " s of " CFG["IdleSeconds"] " s`n"
        . "  hold ceiling:   " CFG["MaxHoldSeconds"] " s`n`n"
        . "RESET`n"
        . "  fast reset:     " (CFG["FastReset"] && USES_WRAPPER ? "on" : "off")
        . (CFG["FastReset"] && USES_WRAPPER && !CFG["ResetFallback"] ? ", unverified (no reload fallback)" : "") "`n"
        . "  visitor since:  " (inputSinceReset ? "yes - a reset is due when idle" : "no - already on the front page") "`n"
        . "  ack pixel:      " (AckPixel() != "" ? AckPixel() " (this is what confirms a swap)" : "unreadable") "`n"
        . "  wrapper token:  " (tok != "" ? tok : "not visible (harmless, the pixel is the real channel)") "`n"
        . "  last reset via: " lastResetHow
        , "Kiosk status", 0x40
}

; Start the video, then open this. It shows exactly what Windows reports,
; which is the fastest way to find out why audio detection is quiet.
ShowAudioSessions() {
    txt := ""
    try {
        list := EnumAudioSessions()
        if (list.Length = 0)
            txt := "The default playback device reports no sessions at all.`n`n"
                 . "Usually that means no application has opened an audio`n"
                 . "stream since boot, or the device is not really the one`n"
                 . "Edge is using."
        for s in list {
            txt .= (s["state"] = 1 ? "ACTIVE  " : s["state"] = 0 ? "idle    " : "expired ")
                . (s["name"] != "" ? s["name"] : "pid " s["pid"] " (name unavailable)") "`n"
        }
    } catch as e {
        txt := "Could not read the audio sessions:`n`n" e.Message
             . "`n`nThe playback device may be missing or disabled."
    }
    MsgBox txt "`n`nWhat to look for: with the video playing there should`n"
        . "be an ACTIVE msedge.exe line. If every Edge line is idle,`n"
        . "the video is muted in the PLAYER - mute the Windows device`n"
        . "instead, and use VideoRect as the backstop."
        , "Kiosk - audio sessions", 0x40
}

; Live read-out for tuning MotionSustainPercent. Run it once with the
; video playing and once with only the image banner rotating, and put the
; threshold between the two numbers. Sampling is forced on for the
; duration, so the idle deadline does not have to be near.
MotionMeter() {
    global CFG, motionPct, motionPlaying, motionHist, meterUntil

    if (CFG["Rect"] = "") {
        MsgBox "No VideoRect is set yet.`n`nUse 'Mark video area' first.", "Kiosk", 0x30
        return
    }

    meterUntil := A_TickCount + 30000
    motionHist := []
    SetTimer MeterTick, 250
}

MeterTick() {
    global CFG, motionPct, motionPlaying, meterUntil
    if (A_TickCount > meterUntil) {
        SetTimer MeterTick, 0
        ToolTip
        return
    }
    left := Round((meterUntil - A_TickCount) / 1000)
    ToolTip "Motion in " CFG["VideoRect"] "`n`n"
          . motionPct "% sustained`n"
          . "verdict: " (motionPlaying ? "PLAYING - reset held" : "not a video - reset allowed") "`n"
          . "threshold: " CFG["MotionSustainPercent"] "%`n`n"
          . "A video reads near 100%. A rotating banner reads low.`n"
          . "closing in " left "s"
          , 20, 20
}

MarkVideoArea() {
    global INI, CFG
    ToolTip "Tap or click the TOP-LEFT corner of the video."
    KeyWait "LButton", "D"
    MouseGetPos &x1, &y1
    KeyWait "LButton"

    ToolTip "Now tap the BOTTOM-RIGHT corner of the video."
    KeyWait "LButton", "D"
    MouseGetPos &x2, &y2
    KeyWait "LButton"
    ToolTip

    if (Abs(x2 - x1) < 40 || Abs(y2 - y1) < 40) {
        MsgBox "That area is too small - nothing was saved.`n`nTry again and tap opposite corners of the video.", "Kiosk", 0x30
        return
    }
    rect := Min(x1, x2) "," Min(y1, y2) "," Max(x1, x2) "," Max(y1, y2)
    try IniWrite rect, INI, "Kiosk", "VideoRect"
    CFG["VideoRect"] := rect
    CFG["Rect"] := ParseRect(rect)
    MsgBox "Video area saved: " rect "`n`nIt is active straight away. Start the video, leave the screen alone, and check Status to confirm it is detected.", "Kiosk", 0x40
}

; =====================================================================
;  Key lockdown
; =====================================================================
InstallKeyBlocks() {
    ; Everything is swallowed except the Alt modifiers and F4 itself, so
    ; Alt+F4 can still be assembled. Alt alone does nothing once every
    ; other key is dead.
    keep := Map(
        0x12, true,   ; VK_MENU  (Alt)
        0xA4, true,   ; VK_LMENU
        0xA5, true,   ; VK_RMENU
        0x73, true )  ; VK_F4

    Loop 0xFE {
        vk := A_Index
        if (vk <= 0x07)          ; mouse button VKs - handled separately
            continue
        if (keep.Has(vk))
            continue
        try Hotkey "*vk" Format("{:X}", vk), Swallow, "On"
    }
}

Swallow(*) {
    return
}

; F4 variants: only Alt+F4 does anything.
F4::return
^F4::return
+F4::return
#F4::return
!F4::ExitKiosk()

; Right-click / long-press context menu, extra buttons.
#HotIf CFG["BlockMouseButtons"]
    *RButton::return
    *MButton::return
    *XButton1::return
    *XButton2::return
#HotIf

#HotIf CFG["BlockWheel"]
    *WheelUp::return
    *WheelDown::return
    *WheelLeft::return
    *WheelRight::return
#HotIf

; =====================================================================
;  Clean exit
; =====================================================================
ExitKiosk() {
    global exiting, CFG
    exiting := true

    SetTimer IdleWatch, 0
    SetTimer EdgeWatch, 0
    Suspend true                      ; release every blocked key

    try ProcessClose "msedge.exe"
    Sleep 400
    try ProcessClose "msedge.exe"     ; second pass for stragglers

    if (CFG["ExitToDesktop"] && !ProcessExist("explorer.exe"))
        try Run "explorer.exe"

    ExitApp
}
