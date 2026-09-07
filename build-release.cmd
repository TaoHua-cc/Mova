@echo off
setlocal
rem ============================================================
rem  Mova Windows release build + Inno Setup installer
rem  Usage:  build-release.cmd
rem  Output: dist-installer\Mova-3.1.74-Windows-x64-Setup.exe
rem ============================================================

rem -- Restore Windows env vars that may be dropped when launched
rem -- from a Git Bash / MSYS shell (names contain parentheses).
set "PROGRAMFILES(X86)=C:\Program Files (x86)"
set "PROGRAMFILES=C:\Program Files"
set "CommonProgramFiles(X86)=C:\Program Files (x86)\Common Files"

rem -- Dummy Android SDK dir: short-circuits flutter_tools' Android
rem -- SDK probing (which otherwise crashes in restricted hosts).
set "ANDROID_HOME=C:\Users\gctyk\AppData\Local\Temp\yj-dummy-android-sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"
if not exist "%ANDROID_HOME%\licenses" mkdir "%ANDROID_HOME%\licenses"

echo [1/2] flutter build windows --release ...
call "D:\DevTools\flutter\bin\flutter.bat" build windows --release
if errorlevel 1 (
  echo FLUTTER_BUILD_FAILED
  exit /b 1
)

echo [2/2] Inno Setup packaging ...
"C:\Users\gctyk\AppData\Local\Programs\Inno Setup 6\ISCC.exe" "%~dp0installer\Mova.iss"
if errorlevel 1 (
  echo INNO_PACKAGING_FAILED
  exit /b 1
)

echo BUILD_OK
exit /b 0
