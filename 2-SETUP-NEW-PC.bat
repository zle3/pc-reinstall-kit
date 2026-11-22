@echo off
title New PC setup
echo Starting setup... (click Yes on the administrator prompt)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-NewPC.ps1" %*
if errorlevel 1 pause
