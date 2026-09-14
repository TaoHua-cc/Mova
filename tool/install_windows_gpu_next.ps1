param(
  [Parameter(Mandatory = $true)]
  [string]$TargetDirectory
)

$ErrorActionPreference = 'Stop'

# mpv.io lists shinchiro's Windows builds. The dev archive contains libmpv and
# is pinned here so a supply-chain change cannot silently alter release output.
$asset = 'mpv-dev-x86_64-20260903-git-69e63f425a.7z'
$url = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20260903/$asset"
$expectedSha256 = 'fac135c68a35b7639e39d72c0c365104edbaebdea39a0dfdd8c36e8c8e80faef'
$cache = Join-Path $PSScriptRoot '..\build\native-libs'
$archive = Join-Path $cache $asset
$extract = Join-Path $cache 'mpv-dev-x86_64-20260903'

New-Item -ItemType Directory -Force -Path $cache | Out-Null
if (-not (Test-Path $archive)) {
  Invoke-WebRequest -Uri $url -OutFile $archive
}

$actualSha256 = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $expectedSha256) {
  throw "libmpv archive SHA-256 mismatch: $actualSha256"
}

$sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
if (-not $sevenZip) {
  $sevenZip = @(
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe'
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $sevenZip) {
  $uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $sevenZip = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '7-Zip*' } |
    ForEach-Object { Join-Path $_.InstallLocation '7z.exe' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
}
if (-not $sevenZip) {
  throw '需要 7-Zip 的 7z.exe 来解压受校验的 libmpv 构建。'
}

if (-not (Test-Path $extract)) {
  New-Item -ItemType Directory -Force -Path $extract | Out-Null
  & $sevenZip x $archive "-o$extract" -y | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed: $LASTEXITCODE" }
}

$sourceDll = Get-ChildItem -Path $extract -Filter 'libmpv-2.dll' -Recurse |
  Select-Object -First 1
if ($null -eq $sourceDll) {
  throw '受校验的 mpv-dev 构建中未找到 libmpv-2.dll。'
}

New-Item -ItemType Directory -Force -Path $TargetDirectory | Out-Null
$targetDll = Join-Path $TargetDirectory 'libmpv-2.dll'
Copy-Item -LiteralPath $sourceDll.FullName -Destination $targetDll -Force

# The build embeds its configure line. This catches an accidentally selected
# audio-only/legacy archive before an installer is produced.
$configuration = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($targetDll))
if ($configuration -notmatch 'Video output based on libplacebo') {
  throw '替换后的 libmpv 未启用 libplacebo，拒绝打包。'
}

Write-Host "Installed libplacebo-enabled libmpv: $targetDll"
