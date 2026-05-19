# update-oh.ps1 - rebuild the openharness-ai image and recreate sandbox containers.
# Per-instance state (named volume HOME) is preserved.
[CmdletBinding()]
param(
    [string]$Name,
    [string]$Version
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/scripts/lib/Common.psm1" -Force -DisableNameChecking
Assert-OhdDocker
Initialize-OhdConfig

$names = @(Get-OhdInstanceNames)
if ($names.Count -eq 0) { Stop-OhdDie "No instances to update. Run .\deploy.ps1 first." }

$deployer = Join-Path (Get-OhdWrapperRepoRoot) 'deploy.ps1'
if (-not (Test-Path $deployer)) { Stop-OhdDie "Cannot find deploy.ps1 at $deployer" }

foreach ($n in $names) {
    if ($Name -and $n -ne $Name) { continue }
    Write-OhdInfo "Updating instance: $n"
    $argv = @('-Name', $n, '-NoSelfUpdate', '-Yes', '-NoDefault', '-RebuildImage')
    if ($Version) { $argv += @('-OpenharnessVersion', $Version) }
    foreach ($m in (Get-OhdInstanceMounts $n)) {
        if ($m.readonly) { $argv += @('-Mount', "$($m.host):ro") }
        else             { $argv += @('-Mount',  "$($m.host)")    }
    }
    & pwsh -NoProfile -File $deployer @argv
    if ($LASTEXITCODE -ne 0) { Stop-OhdDie "deploy.ps1 failed for $n" }
    Write-OhdOk "Updated $n"
}
Write-OhdOk "All requested instances updated."
