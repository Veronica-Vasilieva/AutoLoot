@echo off
REM ============================================================
REM AutoLoot -- one-click background installer
REM
REM Double-click this file.  It will:
REM   1. Open a "Select image" dialog
REM   2. Resize it to 1024x512 (a power-of-2 landscape size)
REM   3. Save as TGA
REM   4. Copy the result to:
REM        Interface\AddOns\AutoLoot\Media\Background.tga
REM   5. Tell you to /reload in-game.
REM
REM No PowerShell knowledge needed -- the -ExecutionPolicy Bypass
REM flag lets the script run without changing your global policy.
REM ============================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Resize-Background.ps1" -ToAddon

echo.
echo (Press any key to close)
pause >nul
