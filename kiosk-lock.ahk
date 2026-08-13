#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreadsPerHotkey 1

; =====================================================================
;  kiosk-lock.ahk   -   ArcGIS Experience Builder touch kiosk controller
;
;  Everything is configured in kiosk.ini, which sits next to this file.
;  This script:
;    * reads kiosk.ini and generates kiosk-config.js for the wrapper
;    * finds Microsoft Edge on its own
;    * launches Edge in kiosk mode and relaunches it if it dies
;    * resets the app after N seconds with no touch / mouse / key input
;    * swallows every keystroke except Alt+F4
;
;  Start it from the "Start Kiosk" shortcut, or run it directly with
;  AutoHotkey64.exe. It needs no administrator rights.
; =====================================================================

Persistent
ProcessSetPriority "High"

global INI := A_ScriptDir "\kiosk.ini"
global CFG := LoadConfig()
global exiting := false

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

global START_URL := BuildStartUrl()
global EDGE_ARGS := BuildEdgeArgs()

; --------------------------- start up --------------------------------
KeepAwake()
KillStaleEdge()
if (CFG["ClearProfileOnStart"])
    try DirDelete CFG["UserDataDir"], true
StartEdge()

if (CFG["BlockAllKeys"])
    InstallKeyBlocks()

SetTimer IdleWatch, 1000
SetTimer EdgeWatch, 3000

A_TrayMenu.Delete()
A_TrayMenu.Add("Reset app now", (*) => ResetApp())
A_TrayMenu.Add("Edit kiosk.ini", (*) => Run('notepad.exe "' INI '"'))
A_TrayMenu.Add()
A_TrayMenu.Add("Exit kiosk", (*) => ExitKiosk())
TraySetIcon "shell32.dll", 14
A_IconTip := "Kiosk - reset after " CFG["IdleSeconds"] "s idle - Alt+F4 to exit"
return

; --------------------------- config ----------------------------------
LoadConfig() {
    global INI
    c := Map()
    c["AppUrl"]              := Trim(IniRead(INI, "Kiosk", "AppUrl", ""))
    c["StartUrl"]            := Trim(IniRead(INI, "Kiosk", "StartUrl", ""))
    c["EdgeExe"]             := Trim(IniRead(INI, "Kiosk", "EdgeExe", ""))
    c["UserDataDir"]         := Trim(IniRead(INI, "Kiosk", "UserDataDir", "C:\KioskProfile"))
    c["IdleSeconds"]         := NumOr(IniRead(INI, "Kiosk", "IdleSeconds", 25), 25)
    c["LoadTimeoutSeconds"]  := NumOr(IniRead(INI, "Kiosk", "LoadTimeoutSeconds", 25), 25)
    c["RevealDelayMs"]       := NumOr(IniRead(INI, "Kiosk", "RevealDelayMs", 1400), 1400)
    c["BlockAllKeys"]        := NumOr(IniRead(INI, "Kiosk", "BlockAllKeys", 1), 1)
    c["BlockMouseButtons"]   := NumOr(IniRead(INI, "Kiosk", "BlockMouseButtons", 1), 1)
    c["BlockWheel"]          := NumOr(IniRead(INI, "Kiosk", "BlockWheel", 0), 0)
    c["ExitToDesktop"]       := NumOr(IniRead(INI, "Kiosk", "ExitToDesktop", 1), 1)
    c["ClearProfileOnStart"] := NumOr(IniRead(INI, "Kiosk", "ClearProfileOnStart", 0), 0)

    if (c["IdleSeconds"] < 5)          ; guard against a typo bricking the kiosk
        c["IdleSeconds"] := 5
    return c
}

NumOr(value, fallback) {
    if IsNumber(Trim(value))
        return Integer(Trim(value))
    return fallback
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
    global CFG
    if (CFG["StartUrl"] != "")
        return CFG["StartUrl"]

    wrapper := A_ScriptDir "\kiosk-wrapper.html"
    if FileExist(wrapper) {
        WriteWrapperConfig()
        return "file:///" StrReplace(wrapper, "\", "/")
    }
    return CFG["AppUrl"]          ; no wrapper present - load the app directly
}

; The wrapper reads this file, so kiosk.ini stays the single source of truth.
WriteWrapperConfig() {
    global CFG
    f := A_ScriptDir "\kiosk-config.js"
    js := "/* Generated from kiosk.ini by kiosk-lock.ahk. Do not edit. */`n"
        . "window.KIOSK_CONFIG = {`n"
        . '  appUrl: "' JsEsc(CFG["AppUrl"]) '",`n'
        . "  idleSeconds: "        CFG["IdleSeconds"] ",`n"
        . "  loadTimeoutSeconds: " CFG["LoadTimeoutSeconds"] ",`n"
        . "  revealDelayMs: "      CFG["RevealDelayMs"] ",`n"
        . "  retrySeconds: 10`n"
        . "};`n"
    try FileDelete f
    try FileAppend js, f, "UTF-8-RAW"
}

JsEsc(s) => StrReplace(StrReplace(s, "\", "\\"), '"', '\"')

BuildEdgeArgs() {
    global CFG, START_URL
    return '--kiosk "' START_URL '"'
        . ' --edge-kiosk-type=fullscreen'
        . ' --kiosk-idle-timeout-minutes=0'
        . ' --user-data-dir="' CFG["UserDataDir"] '"'
        . ' --no-first-run --no-default-browser-check --disable-sync'
        . ' --noerrdialogs --disable-session-crashed-bubble --hide-crash-restore-bubble'
        . ' --disable-infobars --disable-popup-blocking'
        . ' --disable-features=TranslateUI,EdgeShoppingAssistant,msEdgeSidebar,EdgeSplitScreen,msWebOOUI'
        . ' --disable-pinch --overscroll-history-navigation=0'
        . ' --disable-backgrounding-occluded-windows'
        . ' --autoplay-policy=no-user-gesture-required'
        . ' --check-for-update-interval=31536000'
        . ' --start-fullscreen'
}

; --------------------------- idle reset ------------------------------
; A_TimeIdle is driven by GetLastInputInfo, which touch input updates.
; A_TimeIdlePhysical is deliberately NOT used: Windows can flag touch as
; injected input, which would make the app reset under someone's finger.
IdleWatch() {
    global CFG, exiting
    static fired := false

    if (exiting)
        return

    if (A_TimeIdle >= CFG["IdleSeconds"] * 1000) {
        if (!fired) {
            fired := true
            ResetApp()
        }
    } else {
        fired := false
    }
}

ResetApp() {
    hwnd := WinExist("ahk_exe msedge.exe")
    if (!hwnd)
        return
    try {
        WinActivate hwnd
        WinWaitActive hwnd, , 2
    }
    SendInput "{F5}"      ; reloads the wrapper, so the app returns to its home state
}

; --------------------------- watchdog --------------------------------
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
    ; No monitor blank, no sleep, no disk spindown while on AC.
    ; Silently does nothing if the script is not elevated - the installer
    ; already applied these once with admin rights.
    try RunWait A_ComSpec ' /c powercfg /change monitor-timeout-ac 0'
                        . ' & powercfg /change standby-timeout-ac 0'
                        . ' & powercfg /change disk-timeout-ac 0'
                        . ' & powercfg /change hibernate-timeout-ac 0', , "Hide"
}

; --------------------------- key lockdown ----------------------------
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

; --------------------------- clean exit ------------------------------
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
