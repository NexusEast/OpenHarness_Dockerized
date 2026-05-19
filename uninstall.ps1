[CmdletBinding()]
param(
    [switch]$Image,
    [switch]$PurgeConfig,
    [switch]$All
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/scripts/lib/Common.psm1" -Force -DisableNameChecking
if ($All) { $Image = $true; $PurgeConfig = $true }
Assert-OhdDocker

$labelFilter = "label=$((Get-OhdPaths).Label)"
$ctns = @(docker ps -aq --filter $labelFilter)
if ($ctns.Count -gt 0) {
    Write-OhdInfo "Removing $($ctns.Count) OH container(s)..."
    docker rm -f @ctns *> $null
    Write-OhdOk "Containers removed."
} else { Write-OhdInfo "No OH containers found." }

if ($Image) {
    $imgs = @(docker images -q openharness-dockerized 2>$null | Sort-Object -Unique)
    if ($imgs.Count -gt 0) {
        Write-OhdInfo "Removing image(s)..."
        docker rmi -f @imgs *> $null
        Write-OhdOk "Image(s) removed."
    }
}

# Shims (both .ps1 and .cmd, plus the *nix-style ones if present)
$bin = (Get-OhdPaths).ShimBinDir
foreach ($f in 'openh.ps1','openh.cmd','ohmo.ps1','ohmo.cmd','openharness.ps1','openharness.cmd','oh-ctl.ps1','oh-ctl.cmd','oh','ohmo','openh','openharness','oh-ctl') {
    $p = Join-Path $bin $f
    if (Test-Path $p) { Remove-Item -Force $p; Write-OhdOk "Removed $p" }
}

if ($PurgeConfig) {
    $home2 = (Get-OhdPaths).Home
    Write-OhdInfo "Purging $home2 (instance metadata)"
    Remove-Item -Recurse -Force -Path $home2 -ErrorAction SilentlyContinue
    Write-OhdOk "Done."
}

Write-Host @"

Uninstall complete.

Kept on disk (your user data, NOT touched):
    `$HOME/.openharness/   (skills, plugins, provider profiles, credentials)
    `$HOME/.ohmo/          (ohmo workspace)
"@ -ForegroundColor Green
