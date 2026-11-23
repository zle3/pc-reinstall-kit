PC REINSTALL KIT  v1.1.0
========================

Put this folder on a USB stick or external drive (not the PC's C: drive).

BEFORE reinstalling (on the old PC)
-----------------------------------
1. Double-click 1-BACKUP-OLD-PC.bat and click Yes when Windows asks for permission.
   (If Windows says "Windows protected your PC": click More info > Run anyway.)
2. Click "Start backup". Pick your USB stick when it asks where to save.
3. Answer the questions - the highlighted button is always the recommended choice.
4. When it finishes, the USB stick holds the backup AND this kit, plus a file called
   "START HERE - after reinstalling Windows.txt".
5. Click "Checklist" and go through it BEFORE wiping the old PC.

In the backup folder (PCBackup_<PC name>_<date>):
   apps.html       every app with a button to download it again
   report.html     everything found: apps, drivers, devices, settings, browsers, games, licenses
   CHECKLIST.txt   what to sort out before wiping (licenses, OneDrive sync, 2FA, partitions ...)

AFTER reinstalling (on the fresh Windows)
-----------------------------------------
1. Plug in the USB stick and double-click 2-SETUP-NEW-PC.bat on it. Click Yes.
2. Click "Start setup". It finds the backup by itself and goes through every step:
   internet, Windows Update, drivers, apps, browsers, your files, settings and a checklist.
3. Every step asks before changing anything. You can stop any time - progress is saved,
   even across restarts. Click a step on the left and "Run this step" to redo one.

No backup? 2-SETUP-NEW-PC.bat still works with general steps and a list of common apps.

Make it yours
-------------
checklist.txt is the checklist used in the "Checklist" step. Edit it: remove what you
don't use, add your own items. "Text | ms-settings:display" lines get an "Open" button.

Text-only version
-----------------
If the window does not open, the kit falls back to a text console automatically.
To force it: powershell -ExecutionPolicy Bypass -File Backup-OldPC.ps1 -Console

PRIVATE FILES on the drive after a backup
-----------------------------------------
Network\WiFi (Wi-Fi passwords), Browsers\PasswordExports-PRIVATE (plain-text passwords),
System\BitLocker-RecoveryKeys-PRIVATE.txt, Firefox profile copies (saved logins),
AppConfigs\SSH*. The setup's last step offers to delete them once everything works.
