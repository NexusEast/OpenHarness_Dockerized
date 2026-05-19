# OpenHarness Dockerized PowerShell shim. Auto-generated; do not edit by hand.
#
# Installed as openh.ps1 / ohmo.ps1 / openharness.ps1 in the user shim dir.
# Detects which name it was invoked as and forwards to the chosen container.
#
# IMPORTANT: we deliberately do NOT use a `param(...)` block here. PowerShell's
# parameter binder would otherwise see things like `-p` and try to match them
# against advanced-function common parameters (-Verbose, -ProgressAction, ...)
# and throw "ambiguous parameter name". By relying on the automatic $args
# variable instead, every token is forwarded verbatim — including quoted
# strings with spaces — to the container.

$OhdRepo = '__OHD_REPO__'
Import-Module (Join-Path $OhdRepo 'scripts/lib/Common.psm1') -Force -DisableNameChecking

# What CLI is this shim representing? Derived from script filename.
$progName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
$targetCli = switch ($progName) {
    'oh'           { 'oh' }
    'openh'        { 'oh' }
    'openharness'  { 'oh' }
    'ohmo'         { 'ohmo' }
    default        { $progName }
}

# Pull --oh-instance / --oh-instance=NAME out of $args; pass the rest through.
$explicit  = $null
$forwarded = New-Object System.Collections.Generic.List[string]
$skipNext  = $false
foreach ($a in $args) {
    if ($skipNext) { $explicit = [string]$a; $skipNext = $false; continue }
    $s = [string]$a
    if ($s -eq '--oh-instance')      { $skipNext = $true; continue }
    if ($s -like '--oh-instance=*')  { $explicit = $s.Substring('--oh-instance='.Length); continue }
    $forwarded.Add($s) | Out-Null
}

$instance = Resolve-OhdInstance -Explicit $explicit
if (-not $instance) { exit 1 }

# Build docker args inside the helper, but execute docker at the top level so
# stdout/stderr stream directly to the user's console (PowerShell functions
# capture stdout into the return pipeline otherwise).
$dockerArgv = Get-OhdExecArgs -Instance $instance -TargetCli $targetCli -Arguments $forwarded.ToArray()
& docker @dockerArgv
exit $LASTEXITCODE
