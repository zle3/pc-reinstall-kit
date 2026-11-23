# PC Reinstall Kit

Two Windows scripts for reinstalling Windows without losing anything:

1. **Before wiping:** `1-BACKUP-OLD-PC.bat` records installed apps, drivers, settings, Wi-Fi networks, printers, browser bookmarks/extensions/profiles, app settings and (optionally) personal files. It writes a report, an app download list and a "before you wipe" checklist, and copies itself onto the backup drive so the drive is ready for the new PC.
2. **After reinstalling:** `2-SETUP-NEW-PC.bat` on that drive walks through setup step by step: internet and drivers, Windows Update, reinstalling apps automatically (winget), restoring browsers, files and settings, and a guided checklist.

Both run as a normal app window with a step list, progress bars and dialogs. If the window can't open, they fall back to a text console.

## Download

Grab **`pc-reinstall-kit.zip`** from the [latest release](../../releases/latest), unzip it onto a USB stick or external drive, and double-click `1-BACKUP-OLD-PC.bat`. `README.txt` has the details.

The highlighted button in every dialog is the recommended choice.

## Requirements

- Windows 10 or 11 (Windows PowerShell 5.1, built in)
- Administrator rights (it asks)
- winget / App Installer for automatic app installs (built into current Windows)

## Privacy

Everything stays on your drive. Nothing is uploaded anywhere. The backup folder contains private data (Wi-Fi passwords, browser data, optional password exports), so keep the drive safe. The setup's last step offers to delete those files.
