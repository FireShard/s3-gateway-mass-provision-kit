@echo off
rem ====================================================================
rem  Launcher for flash-and-provision.ps1 (Windows version of
rem  host/flash-and-provision.sh). Keep both files in the same folder.
rem
rem  DOUBLE-CLICK this file: Windows asks for Administrator rights (needed
rem  to write to the SD card), then the script asks for what it needs.
rem
rem  Advanced: from an Administrator Command Prompt, pass options:
rem     flash-and-provision.bat -Image D:\golden.img -DiskNumber 2 -GatewayId s3-gw-03
rem
rem  The encoded command below is just this (encoded so that spaces,
rem  brackets and quotes in the folder name cannot break it):
rem     Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList
rem       ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -PauseAtEnd' -f $env:PS1)
rem ====================================================================
set "PS1=%~dp0flash-and-provision.ps1"
if not exist "%PS1%" goto :missing
if not "%~1"=="" goto :withargs

powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand UwB0AGEAcgB0AC0AUAByAG8AYwBlAHMAcwAgAC0ARgBpAGwAZQBQAGEAdABoACAAJwBwAG8AdwBlAHIAcwBoAGUAbABsAC4AZQB4AGUAJwAgAC0AVgBlAHIAYgAgAFIAdQBuAEEAcwAgAC0AQQByAGcAdQBtAGUAbgB0AEwAaQBzAHQAIAAoACcALQBOAG8AUAByAG8AZgBpAGwAZQAgAC0ARQB4AGUAYwB1AHQAaQBvAG4AUABvAGwAaQBjAHkAIABCAHkAcABhAHMAcwAgAC0ARgBpAGwAZQAgACIAewAwAH0AIgAgAC0AUABhAHUAcwBlAEEAdABFAG4AZAAnACAALQBmACAAJABlAG4AdgA6AFAAUwAxACkA
if errorlevel 1 goto :failed
exit /b 0

:withargs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %errorlevel%

:missing
echo Cannot find flash-and-provision.ps1 next to this file.
echo Keep flash-and-provision.bat and flash-and-provision.ps1 in the same folder.
pause
exit /b 1

:failed
echo Could not start PowerShell as Administrator (was the Windows prompt cancelled?).
pause
exit /b 1
