PC REINSTALL KIT
================

Copy this whole folder to a USB stick / external drive (NOT the PC's C: drive).

BEFORE reinstalling (on the old PC)
-----------------------------------
1. Double-click 1-BACKUP-OLD-PC.bat and click Yes on the admin prompt.
2. Answer the questions. Pressing Enter always picks the recommended answer.
3. A folder PCBackup_<PC name>_<date> is created next to the scripts, with:
     apps.html       every app with a button to download it again - tick them off as you go
     report.html     everything found: apps, drivers, peripherals, settings, browsers, games, licenses
     CHECKLIST.txt   what to sort out BEFORE wiping (licenses, OneDrive sync, 2FA, partitions ...)
4. Read CHECKLIST.txt and the Warnings in report.html before wiping anything.

If Windows is too broken to run the script: boot Safe Mode (Shift+Restart > Troubleshoot >
Startup Settings) and try there.

AFTER reinstalling (on the fresh Windows)
-----------------------------------------
1. Plug the drive in, double-click 2-SETUP-NEW-PC.bat, click Yes.
2. Press Enter. It goes through every step in order.
   Each question shows what it will do: Enter = yes, C = let me choose, N = skip.
   Every step can be re-run; progress is remembered, even across restarts.
3. Apps from the old PC are installed automatically. For the rest, apps.html opens:
   click each app's button to download it.
4. Only if you press C: a selection window opens (Ctrl+A = all, Ctrl+click = several, then OK).
   It can open behind the console window.

No backup? 2-SETUP-NEW-PC.bat still works: it uses this PC's hardware, offers common apps,
and walks through the checklist.

Make it yours
-------------
checklist.txt is the guided checklist (menu step 11). Edit it: remove what you don't
use, add your own items. "Text | ms-settings:display" lines get an "open" shortcut.

PRIVATE FILES on the drive after a backup
-----------------------------------------
Network\WiFi (Wi-Fi passwords), Browsers\PasswordExports-PRIVATE (plain-text passwords),
System\BitLocker-RecoveryKeys-PRIVATE.txt, Firefox profile copies (saved logins),
AppConfigs\SSH*. Menu step 12 offers to delete them once everything works.
