@echo off
rem ==========================================================================
rem  CleanDisk.bat - double-click launcher for Clear-DiskSpace.ps1
rem
rem  Asks for admin rights (so system caches can be cleaned too), then shows a
rem  simple menu. No need to open PowerShell or remember any parameters.
rem ==========================================================================
setlocal
title Clear-DiskSpace
cd /d "%~dp0"

set "SELF=%~f0"
set "HERE=%~dp0"
set "SCRIPT=%~dp0Clear-DiskSpace.ps1"

if exist "%SCRIPT%" goto checkadmin
echo Could not find Clear-DiskSpace.ps1 next to this file.
echo Keep CleanDisk.bat in the same folder as Clear-DiskSpace.ps1.
pause
exit /b 1

:checkadmin
rem fltmc only succeeds in an elevated session.
set "ADMIN=no"
fltmc >nul 2>&1
if not errorlevel 1 set "ADMIN=yes"
if "%ADMIN%"=="yes" goto menu
if /i "%~1"=="--no-elevate" goto menu

echo Requesting administrator rights so system caches can be cleaned too...
powershell -NoProfile -Command "try { Start-Process -FilePath $env:SELF -ArgumentList '--no-elevate' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
if not errorlevel 1 exit /b 0
echo Admin rights were not granted - continuing as a standard user.
timeout /t 3 >nul

:menu
cls
echo ============================================================
echo    Clear-DiskSpace  -  one-click Windows disk cleanup
echo ============================================================
if "%ADMIN%"=="yes" echo    Running as Administrator: all targets available
if "%ADMIN%"=="no" echo    Running as standard user: system targets will be skipped
echo.
echo    1. Preview       Show what can be freed - deletes nothing
echo    2. Quick clean   Temp files, crash dumps, Recycle Bin, ...
echo    3. Full clean    Quick + developer and browser caches
echo    4. Deep clean    Full + DISM Windows Update cleanup - slow
echo.
echo    S. Create a desktop shortcut to this menu
echo    Q. Quit
echo.
choice /c 1234SQ /n /m "Pick an option: "
set "PICK=%errorlevel%"

set "ARGS="
if "%PICK%"=="1" goto run
if "%PICK%"=="2" set "ARGS=-Execute"
if "%PICK%"=="2" goto run
if "%PICK%"=="3" set "ARGS=-Execute -IncludeDevCaches -IncludeBrowserCaches"
if "%PICK%"=="3" goto heavy
if "%PICK%"=="4" set "ARGS=-Execute -IncludeDevCaches -IncludeBrowserCaches -RunDism"
if "%PICK%"=="4" goto heavy
if "%PICK%"=="5" goto shortcut
exit /b 0

:heavy
echo.
echo  Before continuing, please:
echo    - Close Android Studio / IntelliJ and stop Gradle daemons: gradlew --stop
echo    - Close Chrome and Edge
echo  You will still get a preview and a y/N confirmation before anything is deleted.
echo.
pause

:run
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %ARGS%
echo.
pause
goto menu

:shortcut
powershell -NoProfile -Command "$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Clean Disk.lnk'; $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath = $env:SELF; $s.WorkingDirectory = $env:HERE; $s.IconLocation = (Join-Path $env:SystemRoot 'System32\cleanmgr.exe') + ',0'; $s.Description = 'Clear-DiskSpace cleanup menu'; $s.Save()"
if errorlevel 1 echo Could not create the shortcut.
if not errorlevel 1 echo Created "Clean Disk" on your desktop - double-click it any time.
echo.
pause
goto menu
