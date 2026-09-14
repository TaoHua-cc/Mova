param(
  [string]$Version
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
  # Use the same proxy as Git when one is configured.
  if ([string]::IsNullOrWhiteSpace($env:HTTPS_PROXY)) {
    $gitProxy = git config --get http.proxy 2>$null
    if (-not [string]::IsNullOrWhiteSpace($gitProxy)) {
      $proxy = $gitProxy.Trim()
      $env:HTTP_PROXY = $proxy
      $env:HTTPS_PROXY = $proxy
      $env:NO_PROXY = '127.0.0.1,localhost'
    }
  }

  $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
  if (-not $gh) {
    $installedGh = 'C:\Program Files\GitHub CLI\gh.exe'
    if (Test-Path -LiteralPath $installedGh) { $gh = $installedGh }
  }
  if (-not $gh) {
    throw 'GitHub CLI was not found. Install GitHub CLI and run gh auth login.'
  }

  & $gh auth status --hostname github.com | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated. Run gh auth login and retry.'
  }

  if ([string]::IsNullOrWhiteSpace($Version)) {
    $match = Select-String -LiteralPath 'pubspec.yaml' `
      -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
    if (-not $match) { throw 'Unable to read a version from pubspec.yaml.' }
    $Version = $match.Matches[0].Groups[1].Value
  }

  $setup = Join-Path $root "dist-installer\Mova-$Version-Windows-x64-Setup.exe"
  $portable = Join-Path $root "dist-installer\Mova-$Version-Windows-x64-Portable.zip"
  $missing = @($setup, $portable) | Where-Object { -not (Test-Path -LiteralPath $_) }
  if ($missing.Count -gt 0) {
    throw "Missing local Windows artifacts: $($missing -join '; ')"
  }

  $repo = 'TaoHua-cc/Mova'
  & $gh release view continuous --repo $repo | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Continuous Release was not found. Push main once to create it first.'
  }

  & $gh release upload continuous $setup $portable --clobber --repo $repo
  if ($LASTEXITCODE -ne 0) {
    throw 'Windows artifact upload failed. Check GitHub authentication and proxy settings.'
  }

  Write-Host "Uploaded Mova $Version Windows setup and portable archive to Mova Continuous."
} finally {
  Pop-Location
}
