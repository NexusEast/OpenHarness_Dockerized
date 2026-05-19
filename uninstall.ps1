[CmdletBinding()]
param(
    [switch]$Image,
    [switch]$Volumes,
    [switch]$PurgeConfig,
    [switch]$All
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/scripts/lib/Common.psm1" -Force -DisableNameChecking
if ($All) { $Image = $true; $Volumes = $true; $PurgeConfig = $true }
Assert-OhdDocker

$labelFilter = "label=$script:OhdLabel"
$ctns = @(docker ps -aq --filter $labelFilter)
if ($ctns.Count -gt 0) {
    Write-OhdInfo "Removing $($ctns.Count) OH container(s)..."
    docker rm -f @ctns *> $null
    Write-OhdOk "Containers removed."
} else { Write-OhdInfo "No OH containers found." }

if ($Volumes) {
    $vols = @(docker volume ls -q | Where-Object { $_ -match '^oh-.*-home$' })
    if ($vols.Count -gt 0) {
        Write-OhdInfo "Removing $($vols.Count) OH home volume(s)..."
        docker volume rm @vols *> $null
        Write-OhdOk "Home volumes removed (per-instance OpenHarness state is gone)."
    }
}

if ($Image) {
    $imgs = @(docker images -q openharness-dockerized 2>$null | Sort-Object -Unique)
    if ($imgs.Count -gt 0) {
        Write-OhdInfo "Removing image(s)..."
        docker rmi -f @imgs *> $null
        Write-OhdOk "Image(s) removed."
    }
}

# Shims.
$bin = $script:OhdShimBinDir
foreach ($f in 'openh.ps1','openh.cmd','ohmo.ps1','ohmo.cmd','openharness.ps1','openharness.cmd','oh-ctl.ps1','oh-ctl.cmd','oh','ohmo','openh','openharness','oh-ctl') {
    $p = Join-Path $bin $f
    if (Test-Path $p) { Remove-Item -Force $p; Write-OhdOk "Removed $p" }
}

if ($PurgeConfig) {
    Write-OhdInfo "Purging $script:OhdHome (instance metadata only)"
    Remove-Item -Recurse -Force -Path $script:OhdHome -ErrorAction SilentlyContinue
    Write-OhdOk "Done."
}

Write-Host @"

Uninstall complete.

NOTE: Per-instance OpenHarness state lives in Docker named volumes
(oh-<instance>-home). If you did not pass -Volumes, that state is preserved.
List with:    docker volume ls --filter name=^oh-
Remove one:   docker volume rm oh-<name>-home
"@ -ForegroundColor Green
