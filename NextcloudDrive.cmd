@echo off
rem Opens the Nextcloud Drive window without a console.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0NextcloudDrive.ps1"
