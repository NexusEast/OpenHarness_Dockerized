# OpenHarness Dockerized - shared PowerShell module.
# Mirrors scripts/lib/common.sh.  Loaded by every .ps1 script:
#     Import-Module "$PSScriptRoot/lib/Common.psm1" -Force

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------- constants ----------------
$script:OhdHome           = if ($env:OHD_HOME) { $env:OHD_HOME } else { Join-Path $HOME '.openharness-docker' }
$script:OhdConfig         = Join-Path $script:OhdHome 'config.json'
$script:OhdInstancesDir   = Join-Path $script:OhdHome 'instances'
$script:OhdShimBinDir     = if ($env:OHD_SHIM_BIN_DIR) { $env:OHD_SHIM_BIN_DIR } else { Join-Path $HOME '.openharness-docker\bin' }
$script:OhdImageDefault   = 'openharness-dockerized:latest'
$script:OhdContainerPref  = 'oh-'
$script:OhdLabel          = 'dev.openharness.dockerized=1'

# ---------------- isolation helpers ----------------
# The "wrapper repo" is THIS git repository (the directory containing
# deploy.ps1, the Dockerfile, scripts/...). It must be fully isolated from
# any container we spawn so that:
#   * a container cannot read or modify our scripts/Dockerfile,
#   * `git pull` on this repo cannot affect a running container,
#   * the agent inside the container has no path back into our codebase.
function Get-OhdWrapperRepoRoot {
    # The module file lives at <repo>/scripts/lib/Common.psm1
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

# Test whether $Child path lies inside $Parent path. Both must be absolute.
function Test-OhdPathInside {
    param([Parameter(Mandatory)][string]$Child, [Parameter(Mandatory)][string]$Parent)
    $c = ([System.IO.Path]::GetFullPath($Child)).TrimEnd('\','/')
    $p = ([System.IO.Path]::GetFullPath($Parent)).TrimEnd('\','/')
    if ($c -eq $p) { return $true }
    if ($IsWindows) {
        return $c.ToLower().StartsWith($p.ToLower() + [System.IO.Path]::DirectorySeparatorChar)
    } else {
        return $c.StartsWith($p + '/')
    }
}

function Get-OhdPaths {
    [pscustomobject]@{
        Home          = $script:OhdHome
        Config        = $script:OhdConfig
        InstancesDir  = $script:OhdInstancesDir
        ShimBinDir    = $script:OhdShimBinDir
        ImageDefault  = $script:OhdImageDefault
        ContainerPref = $script:OhdContainerPref
        Label         = $script:OhdLabel
    }
}

# ---------------- logging ----------------
function Write-OhdInfo  { param([string]$Msg) Write-Host "[i] $Msg" -ForegroundColor Cyan }
function Write-OhdOk    { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-OhdWarn  { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-OhdErr   { param([string]$Msg) Write-Host "[x] $Msg" -ForegroundColor Red }
function Stop-OhdDie    { param([string]$Msg) Write-OhdErr $Msg; throw $Msg }

# ---------------- platform ----------------
function Test-OhdSupportedHost {
    if ($IsWindows) { return $true }
    if ($IsLinux -or $IsMacOS) { return $true }
    return $false
}

function Test-OhdDocker {
    try {
        docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        return $true
    } catch { return $false }
}

function Assert-OhdDocker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-OhdErr "'docker' CLI not found in PATH."
        Write-OhdInfo "Install Docker Desktop for Windows:"
        Write-OhdInfo "    https://www.docker.com/products/docker-desktop/"
        Write-OhdInfo "After install, ensure 'docker' is on your PATH and the daemon is running."
        Stop-OhdDie  "docker CLI not found; aborting."
    }
    if (-not (Test-OhdDocker)) {
        Write-OhdErr "Docker daemon is not reachable."
        Write-OhdInfo "Start Docker Desktop (Windows tray) and wait until it reports 'Engine running', then retry."
        Stop-OhdDie  "Docker daemon not reachable."
    }
}

# ---------------- WSL path translation ----------------
# Convert a Windows path (e.g. D:\Foo\Bar) to its container-side path.
# We use WSL's /mnt/<drive>/... convention because docker-desktop/wsl bind-mounts
# Windows drives there.
# Note: this function does NOT require the path to exist (so we can use it
# for staged files we are about to write).
function ConvertTo-OhdContainerPath {
    param([Parameter(Mandatory)][string]$Path)
    # Normalize to absolute Windows path without requiring existence.
    if ($IsWindows) {
        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full -match '^([A-Za-z]):[\\\/](.*)$') {
            $drive = $Matches[1].ToLower()
            $rest  = $Matches[2] -replace '\\','/'
            return ("/mnt/$drive/$rest").TrimEnd('/')
        } else {
            # UNC or unusual path - try wsl.exe
            $wsl = (& wsl.exe wslpath -u $full 2>$null) -join ''
            if ($LASTEXITCODE -eq 0 -and $wsl) { return $wsl.Trim() }
            Stop-OhdDie "Cannot translate path to a Linux path: $full"
        }
    }
    # On *nix, container path == host path (we mount $HOME identically there)
    return [System.IO.Path]::GetFullPath($Path)
}

# Bind-mount source as Docker sees it.
# IMPORTANT (verified empirically):
#   * On Windows + Docker Desktop, the bind-mount SOURCE must be a Windows path
#     (e.g. C:\Users\foo). If you pass /mnt/c/Users/foo as source, docker-desktop
#     mounts the entire C: drive as ext4 and the container will NOT see your
#     real Windows files.
#   * The DESTINATION inside the container is what we use for cwd alignment, and
#     we want it in Linux form (/mnt/c/Users/foo).
function Get-OhdMountSource {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

# ---------------- config IO ----------------
function Initialize-OhdConfig {
    if (-not (Test-Path $script:OhdHome))         { New-Item -ItemType Directory -Path $script:OhdHome -Force | Out-Null }
    if (-not (Test-Path $script:OhdInstancesDir)) { New-Item -ItemType Directory -Path $script:OhdInstancesDir -Force | Out-Null }
    if (-not (Test-Path $script:OhdConfig)) {
        @{ version=1; default_instance=$null; instances=@{} } | ConvertTo-Json -Depth 10 | Set-Content -Path $script:OhdConfig -Encoding UTF8
    }
}

function Get-OhdConfig {
    Initialize-OhdConfig
    $raw = Get-Content -Raw -Path $script:OhdConfig
    return ($raw | ConvertFrom-Json -AsHashtable)
}

function Save-OhdConfig {
    param([Parameter(Mandatory)][hashtable]$Cfg)
    $tmp = "$($script:OhdConfig).tmp"
    $Cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force -Path $tmp -Destination $script:OhdConfig
}

function Get-OhdDefaultInstance {
    $cfg = Get-OhdConfig
    if ($cfg.ContainsKey('default_instance')) { return $cfg.default_instance } else { return $null }
}

function Set-OhdDefaultInstance {
    param([Parameter(Mandatory)][AllowNull()][string]$Name)
    $cfg = Get-OhdConfig
    $cfg.default_instance = $Name
    Save-OhdConfig $cfg
}

function Get-OhdInstanceNames {
    $cfg = Get-OhdConfig
    if (-not $cfg.instances) { return @() }
    return @($cfg.instances.Keys)
}

function Test-OhdInstance {
    param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-OhdConfig
    return ($cfg.instances -and $cfg.instances.ContainsKey($Name))
}

function Get-OhdInstance {
    param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-OhdConfig
    if (-not (Test-OhdInstance $Name)) { return $null }
    return $cfg.instances[$Name]
}

function Set-OhdInstance {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Fields
    )
    $cfg = Get-OhdConfig
    if (-not $cfg.instances) { $cfg.instances = @{} }
    if (-not $cfg.instances.ContainsKey($Name)) { $cfg.instances[$Name] = @{} }
    foreach ($k in $Fields.Keys) { $cfg.instances[$Name][$k] = $Fields[$k] }
    Save-OhdConfig $cfg
}

function Remove-OhdInstance {
    param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-OhdConfig
    if ($cfg.instances -and $cfg.instances.ContainsKey($Name)) { $cfg.instances.Remove($Name) | Out-Null }
    if ($cfg.default_instance -eq $Name) { $cfg.default_instance = $null }
    Save-OhdConfig $cfg
}

# ---------------- container helpers ----------------
function Get-OhdContainerName {
    param([Parameter(Mandatory)][string]$Name)
    return "$script:OhdContainerPref$Name"
}

function Test-OhdContainerRunning {
    param([Parameter(Mandatory)][string]$ContainerName)
    $out = docker ps -q --filter "name=^$ContainerName`$" --filter "label=$script:OhdLabel" 2>$null
    return [bool]$out
}

function Test-OhdContainerExists {
    param([Parameter(Mandatory)][string]$ContainerName)
    $out = docker ps -aq --filter "name=^$ContainerName`$" --filter "label=$script:OhdLabel" 2>$null
    return [bool]$out
}

# ---------------- instance resolution ----------------
function Resolve-OhdInstance {
    param([string]$Explicit)

    if ($Explicit) { return $Explicit }
    if ($env:OH_INSTANCE) { return $env:OH_INSTANCE }
    $d = Get-OhdDefaultInstance
    if ($d -and (Test-OhdInstance $d)) { return $d }

    $names = @(Get-OhdInstanceNames)
    if ($names.Count -eq 1) { return $names[0] }
    if ($names.Count -eq 0) {
        Write-OhdErr "No OH instance is deployed. Run: deploy.ps1"
        return $null
    }
    Write-OhdErr "Multiple OH instances and no default set. Available:"
    $names | ForEach-Object { Write-OhdErr "    - $_" }
    Write-OhdErr "Set a default with:    oh-ctl set-default <name>"
    Write-OhdErr "Or pick explicitly:    `$env:OH_INSTANCE='<name>'; openh ..."
    return $null
}

# ---------------- exec ----------------
# Build the docker exec argv that the caller should run as `& docker @args`.
# We build but do NOT execute, so that stdout/stderr stream directly to the
# caller's console (PowerShell functions otherwise capture stdout into the
# return pipeline).
function Get-OhdExecArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$TargetCli,
        [Parameter()][string[]]$Arguments = @()
    )
    $cname = Get-OhdContainerName $Instance
    if (-not (Test-OhdContainerRunning $cname)) {
        if (Test-OhdContainerExists $cname) {
            Write-OhdInfo "Instance '$Instance' is stopped. Starting..."
            docker start $cname *> $null
            if ($LASTEXITCODE -ne 0) { Stop-OhdDie "Failed to start $cname" }
        } else {
            Stop-OhdDie "Instance '$Instance' has no container. Run deploy.ps1"
        }
    }
    $cwd = (Get-Location).ProviderPath
    $cwdInContainer = ConvertTo-OhdContainerPath -Path $cwd

    # Probe path visibility; gracefully fall back to host_home with a warning.
    & docker exec $cname test -d $cwdInContainer 2>$null
    if ($LASTEXITCODE -ne 0) {
        $inst = Get-OhdInstance $Instance
        $fallback = if ($inst -and $inst.host_home) { $inst.host_home } else { '/' }
        Write-OhdWarn "Path not visible inside container '$Instance':"
        Write-OhdWarn "    host cwd : $cwd"
        Write-OhdWarn "    expected : $cwdInContainer"
        Write-OhdWarn "Falling back to: $fallback"
        Write-OhdWarn "Tip: redeploy with  -ExtraMount '$cwd'  to add this path to the container."
        $cwdInContainer = $fallback
    }

    $tty = $false
    try {
        $tty = (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
    } catch { $tty = $false }
    $ttyFlag = if ($tty) { '-it' } else { '-i' }

    $argv = @(
        'exec', $ttyFlag,
        '-e', "OH_INSTANCE=$Instance",
        '-e', "TERM=$(if ($env:TERM) { $env:TERM } else { 'xterm-256color' })",
        '-w', $cwdInContainer,
        $cname,
        'oh-entrypoint', 'exec', '--', $TargetCli
    )
    $argv += $Arguments
    return ,$argv     # comma-prefix prevents PowerShell unrolling the array
}

# Convenience wrapper for callers that don't care about streaming output
# (e.g. when they pipe / capture). Most shims should call Get-OhdExecArgs and
# invoke docker themselves.
function Invoke-OhdExec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$TargetCli,
        [Parameter()][string[]]$Arguments = @()
    )
    $argv = Get-OhdExecArgs -Instance $Instance -TargetCli $TargetCli -Arguments $Arguments
    & docker @argv
    return $LASTEXITCODE
}
