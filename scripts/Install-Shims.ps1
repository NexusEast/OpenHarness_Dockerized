# Install-Shims.ps1 - install openh / ohmo / openharness / oh-ctl shims for the current user.
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Bin,
    [switch]$AddToProfile
)

Import-Module "$PSScriptRoot/lib/Common.psm1" -Force -DisableNameChecking

if (-not $Repo) { $Repo = (Resolve-Path "$PSScriptRoot/..").Path }
if (-not $Bin)  { $Bin  = (Get-OhdPaths).ShimBinDir }
if (-not (Test-Path $Bin)) { New-Item -ItemType Directory -Path $Bin -Force | Out-Null }

$template = Join-Path $Repo 'scripts/lib/shim_template.ps1'
if (-not (Test-Path $template)) { Stop-OhdDie "Missing template: $template" }
$tplContent = Get-Content -Raw -Path $template

function Install-OneShim {
    param([string]$Name)

    # 1) the .ps1 itself
    $ps1 = Join-Path $Bin "$Name.ps1"
    ($tplContent -replace [regex]::Escape('__OHD_REPO__'), ($Repo -replace '\\','/')) |
        Set-Content -Path $ps1 -Encoding UTF8
    Write-OhdOk "Installed $ps1"

    # 2) a .cmd wrapper so cmd.exe / non-PS callers can invoke it too
    $cmd = Join-Path $Bin "$Name.cmd"
    @"
@echo off
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0$Name.ps1" %*
"@ | Set-Content -Path $cmd -Encoding ASCII
    Write-OhdOk "Installed $cmd"
}

# Note: we deliberately do NOT install a shim called literally `oh`,
# because PowerShell aliases `oh` to Out-Host. Use `openh` instead.
foreach ($n in 'openh','ohmo','openharness') { Install-OneShim -Name $n }

# oh-ctl is its own script (not a shim template)
$ctlPs1 = Join-Path $Bin 'oh-ctl.ps1'
@"
# auto-generated wrapper; calls the in-repo oh-ctl.ps1
& '$Repo/scripts/oh-ctl.ps1' @args
exit `$LASTEXITCODE
"@ | Set-Content -Path $ctlPs1 -Encoding UTF8
$ctlCmd = Join-Path $Bin 'oh-ctl.cmd'
@"
@echo off
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0oh-ctl.ps1" %*
"@ | Set-Content -Path $ctlCmd -Encoding ASCII
Write-OhdOk "Installed $ctlPs1"
Write-OhdOk "Installed $ctlCmd"

# Generate a profile snippet the user can dot-source
$profileSnippet = Join-Path (Get-OhdPaths).Home 'profile.ps1'
@"
# OpenHarness Dockerized - PowerShell integration
# Source this from your `$PROFILE` to get short commands.
`$ohdBin = '$Bin'
if (`$env:Path -notlike "*`$ohdBin*") { `$env:Path = "`$ohdBin;`$env:Path" }
# Convenience functions so users can type `openh`, `ohmo`, `oh-ctl` directly.
function global:openh        { & (Join-Path '$Bin' 'openh.ps1')        @args; `$global:LASTEXITCODE }
function global:ohmo         { & (Join-Path '$Bin' 'ohmo.ps1')         @args; `$global:LASTEXITCODE }
function global:openharness  { & (Join-Path '$Bin' 'openharness.ps1')  @args; `$global:LASTEXITCODE }
function global:oh-ctl       { & (Join-Path '$Bin' 'oh-ctl.ps1')       @args; `$global:LASTEXITCODE }
"@ | Set-Content -Path $profileSnippet -Encoding UTF8
Write-OhdOk "Wrote $profileSnippet"

if ($AddToProfile) {
    if (-not $PROFILE) { Write-OhdWarn "No `\$PROFILE detected; cannot auto-edit." }
    else {
        $line = ". `"$profileSnippet`""
        $existing = if (Test-Path $PROFILE) { Get-Content -Raw -Path $PROFILE } else { '' }
        if ($existing -notmatch [regex]::Escape($profileSnippet)) {
            if (-not (Test-Path (Split-Path $PROFILE))) { New-Item -ItemType Directory -Path (Split-Path $PROFILE) -Force | Out-Null }
            Add-Content -Path $PROFILE -Value "`n# Added by OpenHarness Dockerized`n$line`n"
            Write-OhdOk "Appended snippet to `$PROFILE: $PROFILE"
        } else {
            Write-OhdInfo "`$PROFILE already references the snippet."
        }
    }
} else {
    Write-OhdInfo "To enable shorthand commands, add this line to your `$PROFILE:"
    Write-Host "    . `"$profileSnippet`"" -ForegroundColor Yellow
    Write-OhdInfo "Or pass -AddToProfile to do it automatically."
}

# PATH check
if ($env:Path -notlike "*$Bin*") {
    Write-OhdWarn "User PATH does not include $Bin yet. Add it via:"
    Write-Host "    [Environment]::SetEnvironmentVariable('Path', `"$Bin;`$([Environment]::GetEnvironmentVariable('Path','User'))`", 'User')" -ForegroundColor Yellow
}
