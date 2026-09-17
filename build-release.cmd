@echo off
setlocal
rem ============================================================
rem  Mova Windows release build + Inno Setup installer
rem  Usage:  build-release.cmd
rem  Output: dist-installer\Mova-<version>-Windows-x64-Setup.exe
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

rem -- Locate the Flutter SDK: prefer PATH, then common local installs.
set "FLUTTER_BIN="
for %%F in (flutter.bat) do if not defined FLUTTER_BIN set "FLUTTER_BIN=%%~$PATH:F"
if not defined FLUTTER_BIN if exist "D:\flutter\bin\flutter.bat" set "FLUTTER_BIN=D:\flutter\bin\flutter.bat"
if not defined FLUTTER_BIN if exist "D:\DevTools\flutter\bin\flutter.bat" set "FLUTTER_BIN=D:\DevTools\flutter\bin\flutter.bat"
if not defined FLUTTER_BIN (
  echo FLUTTER_NOT_FOUND
  echo Set the Flutter SDK on PATH or edit FLUTTER_BIN in this script.
  exit /b 1
)

echo [1/3] flutter build windows --release ...
call "%FLUTTER_BIN%" build windows --release
if errorlevel 1 (
  echo FLUTTER_BUILD_FAILED
  exit /b 1
)

echo [2/3] install libplacebo-enabled Windows libmpv ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\install_windows_gpu_next.ps1" -TargetDirectory "%~dp0build\windows\x64\runner\Release"
if errorlevel 1 (
  echo GPU_NEXT_LIBMPV_INSTALL_FAILED
  exit /b 1
)

echo [3/3] Inno Setup packaging ...
"C:\Users\gctyk\AppData\Local\Programs\Inno Setup 6\ISCC.exe" "%~dp0installer\Mova.iss"
if errorlevel 1 (
  echo INNO_PACKAGING_FAILED
  exit /b 1
)

echo BUILD_OK
exit /b 0
