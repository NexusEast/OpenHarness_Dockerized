# OpenHarness Sandbox - shared PowerShell module.
# Mirrors scripts/lib/common.sh. Loaded by every .ps1 script:
#     Import-Module "$PSScriptRoot/lib/Common.psm1" -Force
#
# Security model: SANDBOX. The container has NO host filesystem access
# except paths the user explicitly mounts via -Mount. This module provides
# the path blacklist (Assert-OhdMountSafe), host->container path mapping
# (Get-OhdContainerTargetFor), and the helpers used by oh-ctl / shims.
#
# Read SECURITY.md before changing anything in here.

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
$script:OhdLabelSandbox   = 'dev.openharness.sandbox=1'
$script:OhdWorkPrefix     = '/work'
$script:OhdSandboxUid     = 1000
$script:OhdSandboxGid     = 1000

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
        Stop-OhdDie  "docker CLI not found; aborting."
    }
    if (-not (Test-OhdDocker)) {
        Write-OhdErr "Docker daemon is not reachable."
        Write-OhdInfo "Start Docker Desktop and wait until 'Engine running'."
        Stop-OhdDie  "Docker daemon not reachable."
    }
}

# ---------------- path helpers ----------------
function Get-OhdWrapperRepoRoot {
    return ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')))
}

# Canonicalise a path. GetFullPath does not require existence.
function Resolve-OhdCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}

function Test-OhdPathInside {
    param([Parameter(Mandatory)][string]$Child, [Parameter(Mandatory)][string]$Parent)
    $c = (Resolve-OhdCanonicalPath $Child)
    $p = (Resolve-OhdCanonicalPath $Parent)
    if ([string]::IsNullOrEmpty($p)) { $p = '/' }
    if ($c -eq $p) { return $true }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($IsWindows) {
        return $c.ToLower().StartsWith($p.ToLower() + $sep)
    } else {
        return $c.StartsWith($p + '/')
    }
}

# Build the list of host paths that must NEVER be exposed inside a sandbox.
function Get-OhdSensitivePaths {
    $paths = @(
        '/'
        '/root', '/home', '/etc', '/var', '/usr', '/boot',
        '/sys', '/proc', '/dev', '/run', '/lib', '/lib64',
        '/sbin', '/bin', '/srv', '/opt'
        '/var/run/docker.sock', '/run/docker.sock',
        '/var/run/containerd', '/run/containerd',
        '/var/lib/docker', '/var/lib/containerd', '/var/lib/kubelet',
        '/mnt/wsl'
    )
    if ($IsWindows) {
        # Windows-side sensitive locations (when -Mount receives a Windows path).
        # These are case-insensitive prefixes.
        $sysroot = [Environment]::GetFolderPath('Windows')                       # C:\Windows
        $sysdrive = [Environment]::GetEnvironmentVariable('SystemDrive')         # C:
        $progFiles  = [Environment]::GetFolderPath('ProgramFiles')               # C:\Program Files
        $progFiles86= [Environment]::GetFolderPath('ProgramFilesX86')            # C:\Program Files (x86)
        $userProf   = [Environment]::GetFolderPath('UserProfile')                # C:\Users\foo
        $appData    = [Environment]::GetFolderPath('ApplicationData')            # roaming
        $localApp   = [Environment]::GetFolderPath('LocalApplicationData')
        $usersRoot  = if ($sysdrive) { Join-Path $sysdrive '\Users' } else { '' }
        $paths += @(
            $sysroot, $progFiles, $progFiles86, $usersRoot,
            $userProf,
            (Join-Path $userProf '.ssh'),
            (Join-Path $userProf '.aws'),
            (Join-Path $userProf '.azure'),
            (Join-Path $userProf '.gcloud'),
            (Join-Path $userProf '.docker'),
            (Join-Path $userProf '.kube'),
            (Join-Path $userProf '.gnupg'),
            (Join-Path $userProf '.openharness'),
            (Join-Path $userProf '.openharness-docker'),
            $appData, $localApp
        ) | Where-Object { $_ }
    } else {
        if ($HOME) {
            $paths += @(
                $HOME,
                (Join-Path $HOME '.ssh'),
                (Join-Path $HOME '.aws'),
                (Join-Path $HOME '.azure'),
                (Join-Path $HOME '.gcloud'),
                (Join-Path $HOME '.docker'),
                (Join-Path $HOME '.kube'),
                (Join-Path $HOME '.gnupg'),
                (Join-Path $HOME '.config'),
                (Join-Path $HOME '.netrc'),
                (Join-Path $HOME '.openharness'),
                (Join-Path $HOME '.openharness-docker'),
                (Join-Path $HOME '.openharness-instances'),
                (Join-Path $HOME '.bash_history'),
                (Join-Path $HOME '.zsh_history')
            )
        }
    }
    # Wrapper repo: the agent must not modify the scripts that run it.
    $wrapper = (Get-OhdWrapperRepoRoot)
    if ($wrapper) { $paths += $wrapper }
    return ,$paths
}

# Hard-fail if a host path requested for mount is unsafe. Mirrors
# scripts/lib/common.sh::ohd_assert_mount_safe.
function Assert-OhdMountSafe {
    param([Parameter(Mandatory)][string]$Path)
    $cpath = Resolve-OhdCanonicalPath $Path
    if (-not $cpath) { Stop-OhdDie "cannot canonicalise mount path: $Path" }
    if ($cpath -eq '/' -or $cpath -match '^[A-Za-z]:\\?$') {
        Stop-OhdDie "refusing to mount a filesystem root: $Path"
    }
    # Symlink check. Also reject reparse points on Windows.
    $item = $null
    try { $item = Get-Item -LiteralPath $cpath -Force -ErrorAction Stop } catch { $item = $null }
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Stop-OhdDie "mount '$Path' is a symlink/reparse-point; pass the resolved real target after re-checking it."
    }
    if ($item -and -not $item.PSIsContainer) {
        Stop-OhdDie "mount '$Path' is not a directory; refusing."
    }
    foreach ($s in (Get-OhdSensitivePaths)) {
        if (-not $s) { continue }
        if (Test-OhdPathInside -Child $cpath -Parent $s) {
            Stop-OhdDie "mount '$Path' (canonical '$cpath') is inside or equal to sensitive path '$s'; refusing. See SECURITY.md."
        }
        if (Test-OhdPathInside -Child $s -Parent $cpath) {
            Stop-OhdDie "mount '$Path' (canonical '$cpath') would expose sensitive path '$s'; refusing. See SECURITY.md."
        }
    }
}

# Map a host path to an in-container target /work/<basename>.
function Get-OhdContainerTargetFor {
    param([Parameter(Mandatory)][string]$HostPath, [string]$Suffix = '')
    $base = Split-Path -Leaf $HostPath
    if ([string]::IsNullOrEmpty($base)) { $base = 'root' }
    $base = ($base -replace '[^A-Za-z0-9._-]','_')
    if ($Suffix) {
        return "$script:OhdWorkPrefix/$base-$Suffix"
    } else {
        return "$script:OhdWorkPrefix/$base"
    }
}

# Convert a Windows path into the form Docker accepts as bind-mount source.
# IMPORTANT: on Docker Desktop, source must be the *Windows* path
# (C:\Users\foo), NOT the WSL form (/mnt/c/Users/foo).
function Get-OhdMountSource {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

# ---------------- config IO ----------------
function Initialize-OhdConfig {
    if (-not (Test-Path $script:OhdHome))         { New-Item -ItemType Directory -Path $script:OhdHome -Force | Out-Null }
    if (-not (Test-Path $script:OhdInstancesDir)) { New-Item -ItemType Directory -Path $script:OhdInstancesDir -Force | Out-Null }
    if (-not (Test-Path $script:OhdConfig)) {
        @{ version=2; default_instance=$null; instances=@{} } | ConvertTo-Json -Depth 10 | Set-Content -Path $script:OhdConfig -Encoding UTF8
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

function Get-OhdInstanceMounts {
    param([Parameter(Mandatory)][string]$Name)
    $inst = Get-OhdInstance $Name
    if (-not $inst) { return @() }
    if (-not $inst.ContainsKey('mounts') -or $null -eq $inst.mounts) { return @() }
    return @($inst.mounts)
}

function Set-OhdInstanceMounts {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Mounts
    )
    $cfg = Get-OhdConfig
    if (-not $cfg.instances) { $cfg.instances = @{} }
    if (-not $cfg.instances.ContainsKey($Name)) { $cfg.instances[$Name] = @{} }
    $cfg.instances[$Name].mounts = $Mounts
    Save-OhdConfig $cfg
}

function Add-OhdInstanceMount {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string]$Target,
        [bool]$ReadOnly = $false
    )
    $existing = @(Get-OhdInstanceMounts $Name)
    $entry = @{ host = $HostPath; target = $Target; readonly = $ReadOnly }
    Set-OhdInstanceMounts -Name $Name -Mounts ($existing + $entry)
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

function Get-OhdHomeVolumeName {
    param([Parameter(Mandatory)][string]$Name)
    return "oh-$Name-home"
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

# Given an instance and a host path, return the in-container path the agent
# would see it at, or $null if not in any of the instance's mounts.
function Resolve-OhdHostPathToContainer {
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$HostPath
    )
    if (-not $HostPath) { return $null }
    $cpath = Resolve-OhdCanonicalPath $HostPath
    $best = $null
    foreach ($m in (Get-OhdInstanceMounts $Instance)) {
        $mhost = $m.host
        if (-not $mhost) { continue }
        if (Test-OhdPathInside -Child $cpath -Parent $mhost) {
            if (-not $best -or $mhost.Length -gt $best.host.Length) {
                $best = $m
            }
        }
    }
    if (-not $best) { return $null }
    $rel = $cpath.Substring($best.host.Length).TrimStart('\','/')
    if (-not $rel) { return $best.target }
    # Always emit a Linux-style path (slashes) for the container.
    $rel = $rel -replace '\\','/'
    return ("$($best.target)/$rel")
}

function Confirm-OhdCwdMount {
    param([Parameter(Mandatory)][string]$HostPath)
    switch ($env:OH_AUTO_MOUNT_CWD) {
        { $_ -in '1','y','Y','yes','YES' } { Write-OhdInfo "OH_AUTO_MOUNT_CWD=1 -> mounting $HostPath"; return $true }
        { $_ -in '0','n','N','no','NO' }   { Write-OhdInfo "OH_AUTO_MOUNT_CWD=0 -> NOT mounting $HostPath"; return $false }
    }
    $tty = $false
    try { $tty = (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected) } catch { $tty = $false }
    if (-not $tty) {
        Write-OhdWarn "Non-interactive shell; refusing to auto-mount '$HostPath'."
        Write-OhdWarn "Set OH_AUTO_MOUNT_CWD=1 to allow, or pre-add it via:  oh-ctl mount add $HostPath"
        return $false
    }
    Write-Host ""
    Write-OhdWarn "About to expose host path inside the sandbox:"
    Write-OhdWarn "    $HostPath"
    Write-OhdWarn "The agent will be able to read AND WRITE everything under it."
    Write-OhdWarn "If this contains secrets, credentials or anything you wouldn't paste"
    Write-OhdWarn "into a public chat, answer 'n' and run from a different directory."
    $ans = Read-Host "? Mount it for this command? [y/N]"
    return ($ans -match '^(y|Y|yes|YES)$')
}

# Build the docker exec / docker run argv. The shim invokes
# `& docker @argv` at top level so output streams stay attached to the
# user's console.
function Get-OhdExecArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$TargetCli,
        [Parameter()][string[]]$Arguments = @()
    )
    $cname = Get-OhdContainerName $Instance
    $home_vol = Get-OhdHomeVolumeName $Instance
    $inst = Get-OhdInstance $Instance
    $image = if ($inst -and $inst.image) { $inst.image } else { $script:OhdImageDefault }

    if (-not (Test-OhdContainerRunning $cname)) {
        if (Test-OhdContainerExists $cname) {
            Write-OhdInfo "Instance '$Instance' is stopped. Starting..."
            docker start $cname *> $null
            if ($LASTEXITCODE -ne 0) { Stop-OhdDie "Failed to start $cname" }
        } else {
            Stop-OhdDie "Instance '$Instance' has no container. Run deploy.ps1"
        }
    }

    $tty = $false
    try { $tty = (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected) } catch { $tty = $false }
    $ttyFlag = if ($tty) { '-it' } else { '-i' }

    # Host CWD: PowerShell paths are Windows on Windows.
    $hostCwd = (Get-Location).ProviderPath
    $hostCwdCanonical = Resolve-OhdCanonicalPath $hostCwd
    $cwdInContainer = Resolve-OhdHostPathToContainer -Instance $Instance -HostPath $hostCwdCanonical

    if ($cwdInContainer) {
        # CWD inside an existing mount: long-lived container.
        $argv = @(
            'exec', $ttyFlag,
            '-e', "OH_INSTANCE=$Instance",
            '-e', "TERM=$(if ($env:TERM) { $env:TERM } else { 'xterm-256color' })",
            '-w', $cwdInContainer,
            $cname,
            'oh-entrypoint','exec','--',$TargetCli
        ) + $Arguments
        return ,$argv
    }

    # CWD not in any mount. Try to add ephemerally.
    $safe = $true
    try { Assert-OhdMountSafe -Path $hostCwdCanonical } catch { $safe = $false }
    if ($safe -and (Confirm-OhdCwdMount -HostPath $hostCwdCanonical)) {
        $target = Get-OhdContainerTargetFor -HostPath $hostCwdCanonical
        $mountSrc = Get-OhdMountSource $hostCwdCanonical
        $argv = @(
            'run','--rm',$ttyFlag,
            '--label',$script:OhdLabel,
            '--label',$script:OhdLabelSandbox,
            '--label',"dev.openharness.instance=$Instance",
            '--label','dev.openharness.ephemeral=1',
            '--user',"$script:OhdSandboxUid`:$script:OhdSandboxGid",
            '--read-only',
            '--tmpfs','/tmp:size=512m,mode=1777,nosuid,nodev,noexec',
            '--tmpfs','/run:size=64m,mode=755,nosuid,nodev,noexec',
            '-v',"$home_vol`:/oh-home",
            '--cap-drop=ALL',
            '--security-opt=no-new-privileges:true',
            '--pids-limit','512',
            '--memory','4g',
            '--cpus','2',
            '--add-host','metadata.google.internal:127.0.0.1',
            '--add-host','metadata.tencentyun.com:127.0.0.1',
            '--add-host','metadata.aliyuncs.com:127.0.0.1',
            '--add-host','metadata.azure.com:127.0.0.1',
            '--add-host','169.254.169.254:127.0.0.1',
            '-e',"HOME=/oh-home",
            '-e',"OH_INSTANCE=$Instance",
            '-e',"TERM=$(if ($env:TERM) { $env:TERM } else { 'xterm-256color' })",
            '-w',$target,
            "--mount=type=bind,source=$mountSrc,target=$target,bind-recursive=disabled",
            $image,
            'oh-entrypoint','exec','--',$TargetCli
        ) + $Arguments
        return ,$argv
    }

    # Fall back to /oh-home with a warning.
    Write-OhdWarn "Running '$TargetCli' from /oh-home; the agent cannot see your host cwd ($hostCwd)."
    Write-OhdWarn "To make a host directory available, run:  oh-ctl mount add <host_path>"
    $argv = @(
        'exec', $ttyFlag,
        '-e', "OH_INSTANCE=$Instance",
        '-e', "TERM=$(if ($env:TERM) { $env:TERM } else { 'xterm-256color' })",
        '-w', '/oh-home',
        $cname,
        'oh-entrypoint','exec','--',$TargetCli
    ) + $Arguments
    return ,$argv
}

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
