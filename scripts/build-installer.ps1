$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$flutter = (Get-Command flutter.bat -ErrorAction SilentlyContinue).Source
if (-not $flutter -and (Test-Path 'D:\DevTools\flutter\bin\flutter.bat')) { $flutter = 'D:\DevTools\flutter\bin\flutter.bat' }
if (-not $flutter) { throw 'Flutter SDK not found. Add Flutter to PATH.' }
$iscc = 'C:\Users\gctyk\AppData\Local\Programs\Inno Setup 6\ISCC.exe'
if (-not (Test-Path $iscc)) { throw "Inno Setup compiler not found: $iscc" }
Push-Location $root
try {
  & $flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "Flutter Windows build failed: exit code $LASTEXITCODE" }
  & $iscc (Join-Path $root 'installer\Yingji.iss')
  if ($LASTEXITCODE -ne 0) { throw "Inno Setup build failed: exit code $LASTEXITCODE" }
} finally { Pop-Location }
