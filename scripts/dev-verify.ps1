<#
  Local verification build for the Windows client.

  Difference from build-release.cmd / build-installer.ps1:
    those two are for shipping (they always produce an installer);
    this one is for "I changed a line and want to see it now" -- it only
    builds the runnable bundle and swaps in the gpu-next libmpv.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\dev-verify.ps1
        Build only. Output: build\windows\x64\runner\Release\mova.exe

    powershell -ExecutionPolicy Bypass -File scripts\dev-verify.ps1 -Deploy
        Also mirror the output into the install dir (default D:\Mova), so the
        desktop shortcut launches the freshly built code.

    powershell -ExecutionPolicy Bypass -File scripts\dev-verify.ps1 -Deploy -SkipChecks
        Fastest loop: no analyze / test.

    powershell -ExecutionPolicy Bypass -File scripts\dev-verify.ps1 -WithInstaller
        Additionally package an Inno Setup installer into dist-installer\.

  NOTE: keep this file ASCII-only. PowerShell 5.1 decodes BOM-less scripts
  using the ANSI code page, and non-ASCII text here breaks quote pairing.
#>
[CmdletBinding()]
param(
  [switch]$Deploy,
  [switch]$SkipChecks,
  [switch]$WithInstaller,
  [string]$InstallDir = 'D:\Mova'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $root 'build\windows\x64\runner\Release'

# Same workaround as build-release.cmd: these names contain parentheses and can
# be dropped when the process is launched from a Git Bash / MSYS shell.
[Environment]::SetEnvironmentVariable('PROGRAMFILES', 'C:\Program Files', 'Process')
[Environment]::SetEnvironmentVariable('PROGRAMFILES(X86)', 'C:\Program Files (x86)', 'Process')
[Environment]::SetEnvironmentVariable('CommonProgramFiles(X86)', 'C:\Program Files (x86)\Common Files', 'Process')

# Dummy Android SDK dir: short-circuits flutter_tools' Android SDK probing.
$dummySdk = Join-Path $env:TEMP 'yj-dummy-android-sdk'
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $dummySdk, 'Process')
[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $dummySdk, 'Process')
$dummyLicenses = Join-Path $dummySdk 'licenses'
if (-not (Test-Path $dummyLicenses)) { New-Item -ItemType Directory -Force -Path $dummyLicenses | Out-Null }

function Find-Flutter {
  $cmd = Get-Command flutter.bat -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($candidate in @('D:\flutter\bin\flutter.bat', 'D:\DevTools\flutter\bin\flutter.bat')) {
    if (Test-Path $candidate) { return $candidate }
  }
  throw 'Flutter SDK not found. Add flutter to PATH or edit the candidate list in this script.'
}

$flutter = Find-Flutter
$started = Get-Date

Push-Location $root
try {
  Write-Host "[env] flutter = $flutter"

  if ($SkipChecks) {
    Write-Host '[1/4] checks skipped (-SkipChecks)'
    Write-Host '[2/4] checks skipped (-SkipChecks)'
  } else {
    Write-Host '[1/4] flutter analyze ...'
    & $flutter analyze --no-fatal-infos --no-fatal-warnings
    if ($LASTEXITCODE -ne 0) { throw "flutter analyze failed: $LASTEXITCODE" }

    Write-Host '[2/4] flutter test ...'
    & $flutter test
    if ($LASTEXITCODE -ne 0) { throw "flutter test failed: $LASTEXITCODE" }
  }

  Write-Host '[3/4] flutter build windows --release ...'
  & $flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed: $LASTEXITCODE" }

  # Do not skip this: flutter build restores media_kit's own old libmpv-2.dll.
  # Without the verified libplacebo build, gpu-next and Dolby Vision are dead.
  Write-Host '[4/4] install libplacebo-enabled libmpv ...'
  try {
    & (Join-Path $root 'tool\install_windows_gpu_next.ps1') -TargetDirectory $releaseDir
  } catch {
    throw "gpu-next libmpv install failed: $($_.Exception.Message)"
  }

  if ($WithInstaller) {
    $iscc = 'C:\Users\gctyk\AppData\Local\Programs\Inno Setup 6\ISCC.exe'
    if (-not (Test-Path $iscc)) { throw "Inno Setup compiler not found: $iscc" }
    Write-Host '[+] ISCC packaging ...'
    & $iscc (Join-Path $root 'installer\Mova.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup build failed: $LASTEXITCODE" }
  }
} finally {
  Pop-Location
}

if ($Deploy) {
  $running = Get-Process -Name 'mova', 'MovaNativePlayer' -ErrorAction SilentlyContinue
  if ($running) {
    Write-Warning "Mova is running; skipped deploy. Quit the app and re-run with -Deploy."
  } elseif (-not (Test-Path $InstallDir)) {
    Write-Warning "Install dir not found: $InstallDir. Pass -InstallDir to override."
  } else {
    Write-Host "[deploy] $releaseDir -> $InstallDir"
    Copy-Item -Path (Join-Path $releaseDir '*') -Destination $InstallDir -Recurse -Force
    Write-Host '[deploy] done (stale files from an older build are not removed; reinstall to clean up)'
  }
}

$elapsed = (Get-Date) - $started
Write-Host ''
Write-Host ("BUILD_OK  elapsed {0:mm\:ss}" -f $elapsed)
Write-Host "Bundle   : $releaseDir\mova.exe"
if ($Deploy) { Write-Host "Installed: $InstallDir\mova.exe" }
