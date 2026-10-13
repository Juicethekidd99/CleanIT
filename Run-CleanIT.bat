@echo off
rem Double-click to open CleanIT (asks for admin via UAC).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CleanIT.ps1" %*
