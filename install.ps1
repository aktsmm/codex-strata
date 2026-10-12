#Requires -Version 7.3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 aktsmm
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StrataRoot,
    [string]$EngineConfig = 'strata-iq2_xs.json',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\codex-strata'),
    [switch]$AddToPath,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows is required.' }
$StrataRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StrataRoot))
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$enginePath = [IO.Path]::GetFullPath($EngineConfig, $StrataRoot)
foreach ($file in @($enginePath, (Join-Path $StrataRoot 'serve\server.py'), (Join-Path $StrataRoot '.venv\Scripts\python.exe'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing Strata file: $file" }
}
Get-Content -LiteralPath $enginePath -Raw | ConvertFrom-Json | Out-Null
$settingsPath = Join-Path $InstallDir 'settings.json'
if ((Test-Path -LiteralPath $settingsPath) -and -not $Force) {
    throw 'An installation already exists. Use -Force to update it; existing settings will be preserved.'
}
if ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -eq $InstallDir.TrimEnd('\')) {
    throw 'Choose an installation folder different from the source folder.'
}
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$backupRoot = Join-Path $InstallDir ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
foreach ($name in @('codex-strata.cmd', 'codex-strata.ps1', 'start-server.py', 'LICENSE', 'NOTICE', 'docs\licenses\Strata-MIT.txt')) {
    $destination = Join-Path $InstallDir $name
    if (Test-Path -LiteralPath $destination) {
        $backupPath = Join-Path $backupRoot $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Copy-Item -LiteralPath $destination -Destination $backupPath
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $destination -Force
}
if (-not (Test-Path -LiteralPath $settingsPath)) {
    $settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'settings.example.json') -Raw | ConvertFrom-Json
    $settings.strata_root = $StrataRoot
    $settings.engine_config = $enginePath
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding utf8
}
if ($AddToPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object { $_ })
    if (-not ($entries | Where-Object { $_.TrimEnd('\') -eq $InstallDir.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable('Path', (($entries + $InstallDir) -join ';'), 'User')
    }
    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -eq $InstallDir.TrimEnd('\') })) {
        $env:Path += ";$InstallDir"
    }
}
Write-Host "Installed: $InstallDir"
Write-Host "Settings: $settingsPath"
Write-Host 'Open a new terminal after adding PATH. Strata and Codex are installed separately.'
$existing = Get-Command codex-strata -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing -and $existing.Source -ne (Join-Path $InstallDir 'codex-strata.cmd')) {
    Write-Warning "Another codex-strata command takes priority: $($existing.Source). Use the installed .cmd by its full path until you resolve the conflict."
}
