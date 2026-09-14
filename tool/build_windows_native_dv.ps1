param(
  [string]$Configuration = 'Release',
  [string]$FlutterOutput = 'build\windows\x64\runner\Release'
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot '..\windows\native_dv_player\Mova.NativeDvPlayer.csproj'
$publish = Join-Path $PSScriptRoot "..\windows\native_dv_player\bin\$Configuration\net8.0-windows10.0.19041.0\win-x64\publish"
$destination = Join-Path (Join-Path $PSScriptRoot '..') "$FlutterOutput\native_dv_player"

dotnet publish $project -c $Configuration -r win-x64 --self-contained true
if ($LASTEXITCODE -ne 0) { throw "Windows 原生 DV 播放器构建失败: $LASTEXITCODE" }

New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item (Join-Path $publish '*') $destination -Recurse -Force
Write-Host "Windows native Dolby Vision player copied to $destination"
