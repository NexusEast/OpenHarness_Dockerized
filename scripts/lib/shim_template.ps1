# OpenHarness Sandbox PowerShell shim. Auto-generated; do not edit by hand.
#
# Installed as openh.ps1 / ohmo.ps1 / openharness.ps1 in the user shim dir.
# Detects which name it was invoked as and forwards to the chosen sandbox.
#
# Sandbox semantics:
#   The container has NO host filesystem access except paths the user has
#   added via `oh-ctl mount add`. If your current host CWD is not inside
#   any sandbox mount, this shim will:
#     - run the command from /oh-home (with a warning), OR
#     - if the cwd is safe per the blacklist and you confirm [y/N], mount
#       the cwd ephemerally for that one invocation (a one-shot --rm
#       container with the same hardening flags).
#   Set `$env:OH_AUTO_MOUNT_CWD='1'` to skip the [y/N] prompt.
#
# IMPORTANT: this script deliberately does NOT use a `param(...)` block.
# PowerShell's parameter binder would otherwise see things like `-p` and
# try to match them against advanced-function common parameters and throw
# "ambiguous parameter name". By relying on the automatic $args variable,
# every token is forwarded verbatim to the container.

# Sentinel for Install-Shims.ps1 / deploy.ps1 -- DO NOT REMOVE.
$OHD_SHIM_TEMPLATE_VERSION = 2

$OhdRepo = '__OHD_REPO__'
Import-Module (Join-Path $OhdRepo 'scripts/lib/Common.psm1') -Force -DisableNameChecking

$progName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
$targetCli = switch ($progName) {
    'oh'           { 'oh' }
    'openh'        { 'oh' }
    'openharness'  { 'oh' }
    'ohmo'         { 'ohmo' }
    default        { $progName }
}

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

$dockerArgv = Get-OhdExecArgs -Instance $instance -TargetCli $targetCli -Arguments $forwarded.ToArray()
& docker @dockerArgv
exit $LASTEXITCODE
