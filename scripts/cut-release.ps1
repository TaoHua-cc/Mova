# Cut a Mova release: bump version, commit, tag, push.
# Pushing the tag makes the Release workflow build both platforms
# and publish them to GitHub Releases.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\cut-release.ps1 -Version 3.1.81
#   powershell -ExecutionPolicy Bypass -File scripts\cut-release.ps1 -Version 3.1.81 -SkipPush
#
# ASCII only on purpose: keeps the file safe under any console code page.

param(
  [Parameter(Mandatory = $true)][string]$Version,
  [switch]$SkipPush
)

$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "Version must look like 3.1.81 (got: $Version)"
}

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# ---- 1. pubspec.yaml: bump version name, increment build number ----
$pubspec = Join-Path $root 'pubspec.yaml'
$text = [System.IO.File]::ReadAllText($pubspec)
if ($text -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
  throw 'pubspec.yaml must contain a "version: X.Y.Z+N" line'
}
$build = [int]$Matches[2] + 1
$old = "$($Matches[1])+$($Matches[2])"
$text = [regex]::Replace($text, '(?m)^version:\s*\d+\.\d+\.\d+\+\d+\s*$', "version: $Version+$build")
Write-Utf8NoBom $pubspec $text
Write-Host "pubspec.yaml: $old -> $Version+$build"

# ---- 2. installer/Mova.iss: keep the local-build default in sync ----
$iss = Join-Path $root 'installer\Mova.iss'
if (Test-Path $iss) {
  $issText = [System.IO.File]::ReadAllText($iss)
  $issText = [regex]::Replace($issText, '(\s*#define AppVersion ")\d+\.\d+\.\d+(")', "`${1}$Version`${2}")
  Write-Utf8NoBom $iss $issText
  Write-Host "installer/Mova.iss: $Version"
}

# ---- 3. commit ----
git add pubspec.yaml installer/Mova.iss
if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
git commit -m "release: Mova $Version"
if ($LASTEXITCODE -ne 0) { throw 'git commit failed (nothing to commit?)' }

# ---- 4. tag ----
git tag "v$Version"
if ($LASTEXITCODE -ne 0) { throw "git tag v$Version failed (tag already exists?)" }
Write-Host "tagged v$Version"

if ($SkipPush) {
  Write-Host 'SkipPush set: commit and tag stay local.'
  exit 0
}

# ---- 5. push branch then tag (tag push triggers the release workflow) ----
git push origin main
if ($LASTEXITCODE -ne 0) { throw 'git push origin main failed' }
git push origin "v$Version"
if ($LASTEXITCODE -ne 0) { throw "git push origin v$Version failed" }

Write-Host "Done. Watch Actions: the Release workflow will publish v$Version to GitHub Releases."
