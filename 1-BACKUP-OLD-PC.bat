@echo off
title Old PC backup
echo Starting backup... (click Yes on the administrator prompt)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Backup-OldPC.ps1" %*
if errorlevel 1 pause
