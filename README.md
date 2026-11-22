# PC Reinstall Kit

Two Windows scripts for reinstalling Windows without losing anything:

1. **Before wiping:** `1-BACKUP-OLD-PC.bat` records installed apps, drivers, settings, Wi-Fi networks, printers, browser bookmarks/extensions/profiles, app settings and (optionally) personal files, and writes a report, an app download list and a "before you wipe" checklist.
2. **After reinstalling:** `2-SETUP-NEW-PC.bat` walks through setup step by step: internet and drivers, Windows Update, reinstalling apps automatically (winget), restoring browsers, files and settings, and a guided checklist.

## Download

Grab **`pc-reinstall-kit.zip`** from the [latest release](../../releases/latest), unzip it onto a USB stick or external drive, and follow `README.txt`.

Press Enter at any question to take the recommended choice.

## Requirements

- Windows 10 or 11 (Windows PowerShell 5.1, built in)
- Administrator rights (it asks)
- winget / App Installer for automatic app installs (built into current Windows)

## Privacy

Everything stays on your drive. Nothing is uploaded anywhere. The backup folder contains private data (Wi-Fi passwords, browser data, optional password exports), so keep the drive safe. The setup's last step offers to delete those files.
