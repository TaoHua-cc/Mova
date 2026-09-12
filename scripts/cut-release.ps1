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

# Run git, always echo its output, hard-fail on non-zero exit.
# Without capturing output a failure looks like a silent hang.
function Invoke-Git([string[]]$GitArgs) {
  $out = & git @GitArgs 2>&1
  $code = $LASTEXITCODE
  $text = ($out | Out-String).Trim()
  if ($text) { Write-Host "  git $($GitArgs[0]): $text" }
  if ($code -ne 0) { throw "git $($GitArgs -join ' ') failed (exit $code): $text" }
}

# ---- 0. preflight ----
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw 'git not found in PATH'
}
& git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { throw "$root is not a git working tree" }
if (-not (& git config user.email)) {
  throw 'git user.email is not configured (git config --global user.email ...); commit would fail'
}
if (& git tag -l "v$Version") {
  throw "tag v$Version already exists"
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

# ---- 3. lib/src/version.dart: the version the UI and UA strings report ----
# The About panel and the HTTP user agents read movaVersion from here, so it has
# to move with the release or it silently goes stale (it once sat at 3.1.65 for
# eighteen releases).
$verDart = Join-Path $root 'lib\src\version.dart'
if (-not (Test-Path $verDart)) {
  throw 'lib/src/version.dart is missing; movaVersion is read from it'
}
$verText = [System.IO.File]::ReadAllText($verDart)
$verNew = [regex]::Replace($verText, "(?m)^const String movaVersion = '\d+\.\d+\.\d+';", "const String movaVersion = '$Version';")
if ($verNew -eq $verText) {
  throw 'lib/src/version.dart has no movable "const String movaVersion = X.Y.Z;" line'
}
Write-Utf8NoBom $verDart $verNew
Write-Host "lib/src/version.dart: movaVersion -> $Version"

# ---- 4. commit ----
Invoke-Git @('add', 'pubspec.yaml', 'installer/Mova.iss', 'lib/src/version.dart')
Invoke-Git @('commit', '-m', "release: Mova $Version")

# ---- 5. tag ----
Invoke-Git @('tag', "v$Version")
Write-Host "tagged v$Version"

if ($SkipPush) {
  Write-Host 'SkipPush set: commit and tag stay local.'
  exit 0
}

# ---- 6. push branch then tag (tag push triggers the release workflow) ----
Invoke-Git @('push', 'origin', 'main')
Invoke-Git @('push', 'origin', "v$Version")

Write-Host "Done. Watch Actions: the Release workflow will publish v$Version to GitHub Releases."
