# update-deployer.ps1 - update THIS wrapper repo (deploy/shim/Dockerfile/scripts).
#
# This pulls the latest version of the OpenHarness_Dockerized repository into
# the current working tree using 'git pull --ff-only'. It does NOT touch your
# OpenHarness runtime image - run .\update-oh.ps1 for that.
#
# Usage:
#   .\update-deployer.ps1                     # git pull --ff-only origin <current branch>
#   .\update-deployer.ps1 -Remote NAME        # use a different remote (default: origin)
#   .\update-deployer.ps1 -Branch NAME        # check out a specific branch first
#   .\update-deployer.ps1 -Rebase             # use 'git pull --rebase' instead of --ff-only
#
[CmdletBinding()]
param(
    [string]$Remote = 'origin',
    [string]$Branch,
    [switch]$Rebase
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/scripts/lib/Common.psm1" -Force -DisableNameChecking

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-OhdDie "git is required for update-deployer."
}

Set-Location $PSScriptRoot
if (-not (Test-Path (Join-Path $PSScriptRoot '.git'))) {
    Stop-OhdDie "Not a git checkout: $PSScriptRoot  (did you download a release zip instead of cloning?)"
}

$current = (& git rev-parse --abbrev-ref HEAD).Trim()
if ($current -eq 'HEAD') {
    Stop-OhdDie "Detached HEAD - check out a branch first (e.g. 'git checkout main')."
}

if ($Branch -and $Branch -ne $current) {
    Write-OhdInfo "Switching from '$current' to '$Branch'..."
    & git checkout $Branch
    if ($LASTEXITCODE -ne 0) { Stop-OhdDie "git checkout $Branch failed" }
    $current = $Branch
}

# Refuse to pull on top of dirty changes - too easy to silently lose work.
& git diff --quiet
$dirty1 = $LASTEXITCODE
& git diff --cached --quiet
$dirty2 = $LASTEXITCODE
if ($dirty1 -ne 0 -or $dirty2 -ne 0) {
    Write-OhdErr "Working tree has uncommitted changes. Commit/stash them first."
    & git status --short
    exit 1
}

$before = (& git rev-parse HEAD).Trim()

Write-OhdInfo "Fetching from '$Remote'..."
& git fetch --prune $Remote
if ($LASTEXITCODE -ne 0) { Stop-OhdDie "git fetch failed" }

if ($Rebase) {
    Write-OhdInfo "Rebasing onto '$Remote/$current'..."
    & git pull --rebase $Remote $current
} else {
    Write-OhdInfo "Fast-forwarding to '$Remote/$current'..."
    & git pull --ff-only $Remote $current
}
if ($LASTEXITCODE -ne 0) { Stop-OhdDie "git pull failed" }

$after = (& git rev-parse HEAD).Trim()

if ($before -eq $after) {
    Write-OhdOk "Already up to date ($after)."
    exit 0
}

Write-OhdOk "Updated: $before -> $after"

# Report whether runtime / shim layout changed so the user knows what to re-run.
$changedRaw = (& git diff --name-only $before $after)
$changed = @($changedRaw | Where-Object { $_ -ne '' })
$needUpdateOh = $false
$needReinstallShims = $false
foreach ($f in $changed) {
    if ($f -match '^docker/(Dockerfile|entrypoint\.sh|\.dockerignore)$') { $needUpdateOh = $true }
    if ($f -match '^scripts/(lib/(Common\.psm1|shim_template\.ps1|common\.sh|shim_template\.sh)|Install-Shims\.ps1|install-shims\.sh|oh-ctl\.ps1|oh-ctl\.sh)$') { $needReinstallShims = $true }
}

Write-Host ''
Write-OhdInfo 'Changed files:'
$changed | ForEach-Object { Write-Host "  $_" }
Write-Host ''

if ($needUpdateOh) {
    Write-OhdWarn 'Container runtime files changed.'
    Write-OhdInfo  '  -> rebuild image + recreate all instances:  .\update-oh.ps1'
}
if ($needReinstallShims) {
    Write-OhdWarn 'Host shim / oh-ctl files changed.'
    Write-OhdInfo  "  -> reinstall shims:                          .\scripts\Install-Shims.ps1 -Repo `"$PSScriptRoot`""
}
if (-not $needUpdateOh -and -not $needReinstallShims) {
    Write-OhdOk 'No container or shim files changed; nothing else to do.'
}
