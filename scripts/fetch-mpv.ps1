$ErrorActionPreference = 'Stop'
$url = 'https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20260814/mpv-x86_64-20260814-git-7b8915bc1d.7z'
$expected = '1bf3b029da2c98e605e00e85f21ee3142f22a1dcc4ceb5c827b5c51e36e390f9'
$archive = Join-Path $PSScriptRoot '..\mpv.7z'
$target = Join-Path $PSScriptRoot '..\app\mpv'
Invoke-WebRequest -Uri $url -OutFile $archive
$stream = [System.IO.File]::OpenRead($archive)
try {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $actual = ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha256.Dispose()
  }
} finally {
  $stream.Dispose()
}
if ($actual -ne $expected) { throw "mpv SHA-256 mismatch: $actual" }
New-Item -ItemType Directory -Force $target | Out-Null
$sevenZip = Join-Path $PSScriptRoot '..\node_modules\.pnpm\7zip-bin@5.2.0\node_modules\7zip-bin\win\x64\7za.exe'
& $sevenZip x $archive "-o$target" -y
if ($LASTEXITCODE -ne 0) { throw 'mpv extraction failed' }
Write-Host 'mpv downloaded and verified.'
