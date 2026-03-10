; Koe for Windows — NSIS Installer Script
; Generates: Koe-Setup.exe

!include "MUI2.nsh"

; ── General ──
Name "Koe"
OutFile "Koe-Setup.exe"
InstallDir "$PROGRAMFILES64\Koe"
InstallDirRegKey HKLM "Software\Koe" "InstallDir"
RequestExecutionLevel admin

; ── Version Info ──
VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName" "Koe"
VIAddVersionKey "CompanyName" "EnablerDAO"
VIAddVersionKey "FileDescription" "Koe — Ultra-fast Voice Input"
VIAddVersionKey "FileVersion" "1.0.0"
VIAddVersionKey "LegalCopyright" "Copyright 2026 Yuki Hamada"

; ── UI ──
; !define MUI_ICON "..\assets\koe.ico"  ; TODO: add icon file
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Koe — 超高速音声入力"
!define MUI_WELCOMEPAGE_TEXT "Koe をインストールします。$\r$\n$\r$\nCtrl+Alt+V で どこでも音声入力。$\r$\nwhisper.cpp + GPU で 0.5秒以下のレイテンシ。$\r$\n$\r$\n20言語対応 · 完全プライベート · クラウド不要"

; Pages
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

; Uninstall pages
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; Languages
!insertmacro MUI_LANGUAGE "Japanese"
!insertmacro MUI_LANGUAGE "English"

; ── Install Section ──
Section "Install"
    SetOutPath "$INSTDIR"

    ; Main binary
    File "..\dist\koe.exe"

    ; README
    File "..\dist\README.md"

    ; Create uninstaller
    WriteUninstaller "$INSTDIR\Uninstall.exe"

    ; Start menu shortcut
    CreateDirectory "$SMPROGRAMS\Koe"
    CreateShortCut "$SMPROGRAMS\Koe\Koe.lnk" "$INSTDIR\koe.exe"
    CreateShortCut "$SMPROGRAMS\Koe\Uninstall.lnk" "$INSTDIR\Uninstall.exe"

    ; Desktop shortcut
    CreateShortCut "$DESKTOP\Koe.lnk" "$INSTDIR\koe.exe"

    ; Auto-start (registry)
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Koe" '"$INSTDIR\koe.exe"'

    ; Add/Remove Programs entry
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Koe" "DisplayName" "Koe — Voice Input"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Koe" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Koe" "DisplayVersion" "1.0.0"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Koe" "Publisher" "EnablerDAO"
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Koe" "EstimatedSize" 10240

    ; Install dir in registry
    WriteRegStr HKLM "Software\Koe" "InstallDir" "$INSTDIR"
SectionEnd

; ── Uninstall Section ──
Section "Uninstall"
    ; Kill running process
    nsExec::ExecToLog 'taskkill /F /IM koe.exe'

    ; Remove files
    Delete "$INSTDIR\koe.exe"
    Delete "$INSTDIR\README.md"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"

    ; Remove shortcuts
    Delete "$DESKTOP\Koe.lnk"
    Delete "$SMPROGRAMS\Koe\Koe.lnk"
    Delete "$SMPROGRAMS\Koe\Uninstall.lnk"
    RMDir "$SMPROGRAMS\Koe"

    ; Remove auto-start
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Koe"

    ; Remove registry
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Koe"
    DeleteRegKey HKLM "Software\Koe"
SectionEnd
