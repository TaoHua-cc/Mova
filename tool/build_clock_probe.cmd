@echo off
REM Build tool\tick_clock_probe.cpp standalone (no CMake, no vcvars - see the
REM windows-sandbox-toolchain-workarounds skill: reg.exe is blocked, so
REM vcvars64.bat cannot be used and INCLUDE/LIB must be set by hand).
setlocal
set MSVC=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231
set SDK=C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0
set LIB_SDK=C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0
set INCLUDE=%MSVC%\include;%SDK%\ucrt;%SDK%\um;%SDK%\shared;%SDK%\cppwinrt
set LIB=%MSVC%\lib\x64;%LIB_SDK%\ucrt\x64;%LIB_SDK%\um\x64
"%MSVC%\bin\Hostx64\x64\cl.exe" /nologo /W4 /std:c++17 /utf-8 /O2 /EHsc ^
  /Fe:"%~dp0tick_clock_probe.exe" /Fo:"%TEMP%\tick_clock_probe.obj" ^
  "%~dp0tick_clock_probe.cpp" winmm.lib
endlocal
