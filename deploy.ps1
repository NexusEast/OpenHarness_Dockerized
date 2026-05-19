# deploy.ps1 - interactive deployment wizard for OpenHarness Dockerized.
#
# Usage examples:
#     .\deploy.ps1
#     .\deploy.ps1 -Name oh-default -Yes
#     .\deploy.ps1 -ExtraMount D:\Projects -RebuildImage
#     .\deploy.ps1 -NoSelfUpdate                # skip the wrapper-repo self-update check
[CmdletBinding()]
param(
    [string]$Name,
    [string]$OpenrouterKey,
    [string]$Model,
    [string[]]$ExtraMount = @(),
    [string]$Image,
    [string]$OpenharnessVersion,
    [switch]$RebuildImage,
    [switch]$Yes,
    [switch]$SetDefault,
    [switch]$NoDefault,
    [switch]$NoSelfUpdate
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/scripts/lib/Common.psm1" -Force -DisableNameChecking

# ---------------- self-update check (wrapper repo) ----------------
# Re-exec ourselves after a successful pull. Guard against infinite loops with
# the OH_DEPLOYER_SELF_UPDATE_DONE env var. Honor both -NoSelfUpdate and the
# OH_DEPLOYER_NO_SELF_UPDATE env var as escape hatches.
function Invoke-OhdSelfUpdateCheck {
    if ($env:OH_DEPLOYER_SELF_UPDATE_DONE -eq '1') { return }
    if ($NoSelfUpdate) { return }
    if ($env:OH_DEPLOYER_NO_SELF_UPDATE -eq '1') { return }

    # Helper: the self-update was skipped for some reason; ask the user whether
    # to continue running deploy anyway, or abort. Non-interactive shells
    # auto-continue (so CI / piped invocations don't hang).
    function Confirm-OhdContinueWithoutSelfUpdate {
        param(
            [ValidateSet('info','warn')] [string]$Level,
            [string]$Reason,
            [string]$Hint = ''
        )
        if ($Level -eq 'warn') { Write-OhdWarn $Reason } else { Write-OhdInfo $Reason }
        if ($Hint) { Write-OhdInfo $Hint }
        if ([Environment]::UserInteractive -and $Host.UI.RawUI) {
            $ans = Read-Host -Prompt '? Continue deploy without self-update? [Y/n]'
            if ([string]::IsNullOrWhiteSpace($ans)) { $ans = 'Y' }
            if ($ans -match '^[nN]') {
                Write-OhdErr 'Aborted by user.'
                exit 1
            }
        } else {
            Write-OhdInfo 'Non-interactive shell; continuing without self-update.'
        }
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Confirm-OhdContinueWithoutSelfUpdate -Level info `
            -Reason 'git not found; cannot self-update the wrapper repo.'
        return
    }
    if (-not (Test-Path (Join-Path $PSScriptRoot '.git'))) {
        Confirm-OhdContinueWithoutSelfUpdate -Level info `
            -Reason 'Not a git checkout; cannot self-update the wrapper repo.'
        return
    }

    $branch = (& git -C $PSScriptRoot rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Confirm-OhdContinueWithoutSelfUpdate -Level info `
            -Reason 'git rev-parse failed; cannot self-update.'
        return
    }
    $branch = $branch.Trim()
    if ($branch -eq 'HEAD') {
        Confirm-OhdContinueWithoutSelfUpdate -Level info `
            -Reason 'Detached HEAD; cannot self-update.'
        return
    }

    & git -C $PSScriptRoot diff --quiet
    $dirty1 = $LASTEXITCODE
    & git -C $PSScriptRoot diff --cached --quiet
    $dirty2 = $LASTEXITCODE
    if ($dirty1 -ne 0 -or $dirty2 -ne 0) {
        Confirm-OhdContinueWithoutSelfUpdate -Level warn `
            -Reason 'Wrapper repo has uncommitted changes; cannot self-update.' `
            -Hint   "Run .\update-deployer.ps1 manually after committing/stashing."
        return
    }

    Write-OhdInfo "Checking wrapper repo for updates (origin/$branch)..."
    & git -C $PSScriptRoot fetch --quiet --prune origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        Confirm-OhdContinueWithoutSelfUpdate -Level info `
            -Reason 'git fetch failed (offline?); cannot self-update.'
        return
    }

    $local  = (& git -C $PSScriptRoot rev-parse HEAD).Trim()
    $remote = (& git -C $PSScriptRoot rev-parse "origin/$branch" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Confirm-OhdContinueWithoutSelfUpdate -Level info `
            -Reason "origin/$branch is missing; cannot self-update."
        return
    }
    $remote = $remote.Trim()
    if ($local -eq $remote) {
        Write-OhdOk 'Wrapper repo is up to date.'
        return
    }
    $base = (& git -C $PSScriptRoot merge-base HEAD "origin/$branch" 2>$null)
    if ($LASTEXITCODE -eq 0) { $base = $base.Trim() } else { $base = '' }
    if ($base -and $base -ne $local) {
        Confirm-OhdContinueWithoutSelfUpdate -Level warn `
            -Reason "Local branch has commits not on origin/$branch; cannot fast-forward." `
            -Hint   "Run .\update-deployer.ps1 -Rebase manually if you want to integrate."
        return
    }

    $behind = (& git -C $PSScriptRoot rev-list --count "HEAD..origin/$branch" 2>$null).Trim()
    Write-Host ''
    Write-OhdInfo "Wrapper repo is $behind commit(s) behind origin/$branch."
    Write-OhdInfo 'Recent upstream commits:'
    & git -C $PSScriptRoot log --oneline --no-decorate "HEAD..origin/$branch" |
        Select-Object -First 10 |
        ForEach-Object { Write-Host "    $_" }
    Write-Host ''

    $ans = 'Y'
    if ([Environment]::UserInteractive -and $Host.UI.RawUI) {
        $ans = Read-Host -Prompt '? Pull latest wrapper code and restart deploy? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($ans)) { $ans = 'Y' }
    } else {
        Write-OhdInfo 'Non-interactive shell; auto-accepting self-update.'
    }
    if ($ans -match '^[nN]') {
        Confirm-OhdContinueWithoutSelfUpdate -Level warn `
            -Reason 'Self-update declined by user.'
        return
    }

    Write-OhdInfo 'Pulling...'
    & git -C $PSScriptRoot pull --ff-only --quiet origin $branch
    if ($LASTEXITCODE -ne 0) {
        Confirm-OhdContinueWithoutSelfUpdate -Level warn `
            -Reason 'git pull --ff-only failed.' `
            -Hint   "Run .\update-deployer.ps1 manually to investigate."
        return
    }
    $short = (& git -C $PSScriptRoot rev-parse --short HEAD).Trim()
    Write-OhdOk "Wrapper repo updated to $short. Restarting deploy..."
    Write-Host ''

    # Rebuild original argv (without -NoSelfUpdate, which we'd strip; the env var
    # OH_DEPLOYER_SELF_UPDATE_DONE prevents infinite re-exec).
    $env:OH_DEPLOYER_SELF_UPDATE_DONE = '1'
    $reArgs = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Key -eq 'NoSelfUpdate') { continue }
        $val = $kv.Value
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $reArgs += "-$($kv.Key)" }
        } elseif ($val -is [System.Array]) {
            foreach ($v in $val) { $reArgs += @("-$($kv.Key)", "$v") }
        } else {
            $reArgs += @("-$($kv.Key)", "$val")
        }
    }
    $pwshExe = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwshExe) { $pwshExe = Get-Command powershell -ErrorAction SilentlyContinue }
    if (-not $pwshExe) { Stop-OhdDie 'Cannot locate pwsh or powershell to re-exec deploy.' }
    & $pwshExe.Source -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'deploy.ps1') @reArgs
    exit $LASTEXITCODE
}
Invoke-OhdSelfUpdateCheck

if (-not (Test-OhdSupportedHost)) { Stop-OhdDie "Unsupported host." }
Assert-OhdDocker
Initialize-OhdConfig

$paths = Get-OhdPaths
if (-not $Image) { $Image = $paths.ImageDefault }

function Read-Default {
    param([string]$Msg, [string]$DefaultValue)
    if ($Yes) { return $DefaultValue }
    if ($DefaultValue) { $hint = " [$DefaultValue]" } else { $hint = '' }
    $ans = Read-Host -Prompt ("? " + $Msg + $hint)
    if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultValue } else { return $ans }
}

function Read-Secret {
    param([string]$Msg)
    if ($Yes) { return '' }
    $sec = Read-Host -Prompt ("? " + $Msg) -AsSecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

function Confirm-Default {
    param([string]$Msg, [bool]$DefaultYes)
    if ($Yes) { return $DefaultYes }
    $hint = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host -Prompt ("? " + $Msg + ' ' + $hint)
    if ([string]::IsNullOrWhiteSpace($a)) { return $DefaultYes }
    return $a -match '^[yY]'
}

Write-Host @"

╔══════════════════════════════════════════════════════╗
║          OpenHarness Dockerized — Deploy             ║
╚══════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

# ---- 1. instance name ----
$existing = @(Get-OhdInstanceNames)
if (-not $Name) {
    if ($existing.Count -eq 0) {
        $Name = Read-Default "Instance name" "default"
    } else {
        Write-OhdInfo "Existing instances:"
        $existing | ForEach-Object { Write-Host "    - $_" }
        $Name = Read-Default "New (or existing to redeploy) instance name" ""
    }
}
if (-not $Name) { Stop-OhdDie "Instance name is required." }
if ($Name -notmatch '^[A-Za-z0-9_.\-]+$') { Stop-OhdDie "Invalid instance name: '$Name'" }

$cname = Get-OhdContainerName $Name

# ---- 2. credentials ----
$existingInst = Get-OhdInstance $Name
if (-not $OpenrouterKey) {
    $reuse = $false
    if ($existingInst -and $existingInst.openrouter_key_set -eq 'yes') {
        $reuse = Confirm-Default "Reuse existing OpenRouter API key for '$Name'?" $true
    }
    if ($reuse) {
        $OpenrouterKey = '__KEEP__'
    } else {
        Write-OhdInfo "Get a key at: https://openrouter.ai/keys"
        $OpenrouterKey = Read-Secret "OpenRouter API key (input hidden)"
        if (-not $OpenrouterKey) { Stop-OhdDie "OpenRouter API key is required." }
    }
}

if (-not $Model) {
    $suggested = if ($existingInst -and $existingInst.model) { $existingInst.model } else { 'anthropic/claude-3.5-sonnet' }
    $Model = Read-Default "Default OpenRouter model id" $suggested
}

# ---- 3. host info ----
# On Windows, Docker Desktop bind-mounts:
#   SOURCE = a Windows path (C:\Users\you)
#   DEST   = a Linux path inside the container (/mnt/c/Users/you)
# We deliberately use the /mnt/<drive>/... form as the in-container path so that
# the same path string can be reused as cwd from BOTH PowerShell shims (which
# convert host -> /mnt/<drive>/...) and from WSL shells (which already use it).
$winHome = $HOME
$mountSrc = Get-OhdMountSource -Path $winHome   # "C:\Users\foo"
$linuxHome = ConvertTo-OhdContainerPath -Path $winHome   # "/mnt/c/Users/foo"
# Docker Desktop's 9p layer maps file owner to host user regardless of in-container UID,
# but we still need a real Linux account; we always use 1000:1000 inside, named "ohuser".
$hostUid = 1000
$hostGid = 1000
$hostUser = 'ohuser'   # always the in-container user name; do NOT use $env:USERNAME here.

Write-OhdInfo "Will bind-mount your home: $mountSrc  ->  $linuxHome  (inside container)"

# ---- 4. image ----
$needBuild = $false
if ($RebuildImage) { $needBuild = $true }
docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) { $needBuild = $true }

if ($needBuild) {
    Write-OhdInfo "Building image $Image ..."
    $buildArgs = @(
        'build',
        '--build-arg', "HOST_UID=$hostUid",
        '--build-arg', "HOST_GID=$hostGid",
        '--build-arg', "HOST_USER=$hostUser",
        '--build-arg', "HOST_HOME=$linuxHome"
    )
    if ($OpenharnessVersion) { $buildArgs += @('--build-arg', "OPENHARNESS_VERSION=$OpenharnessVersion") }
    $buildArgs += @('-t', $Image, (Join-Path $PSScriptRoot 'docker'))
    & docker @buildArgs
    if ($LASTEXITCODE -ne 0) { Stop-OhdDie "docker build failed." }
    Write-OhdOk "Image built: $Image"
} else {
    Write-OhdInfo "Reusing existing image $Image (use -RebuildImage to force)"
}

# ---- 5. container ----
if (Test-OhdContainerExists $cname) {
    if (Confirm-Default "Container '$cname' already exists. Recreate it?" $true) {
        docker rm -f $cname *> $null
    } else {
        Write-OhdInfo "Keeping existing container; will only update provider config inside it."
    }
}

if (-not (Test-OhdContainerExists $cname)) {
    Write-OhdInfo "Creating container $cname ..."
    $runArgs = @(
        'run','-d','--restart','unless-stopped',
        '--name', $cname,
        '--label', $paths.Label,
        '--label', "dev.openharness.instance=$Name",
        '--hostname', $cname,
        '-e', "HOST_UID=$hostUid",
        '-e', "HOST_GID=$hostGid",
        '-e', "HOST_USER=$hostUser",
        '-e', "HOST_HOME=$linuxHome",
        '-e', "OH_RUNTIME_HOME=$linuxHome",
        '-e', "OH_INSTANCE=$Name",
        '-v', "${mountSrc}:${linuxHome}"
    )
    foreach ($m in $ExtraMount) {
        $src = Get-OhdMountSource -Path $m
        $dst = ConvertTo-OhdContainerPath -Path $m
        $runArgs += @('-v', "${src}:${dst}")
    }

    # ---- Isolation guards: shadow the wrapper repo and our state dir ----
    # If they happen to fall under a bind-mount we just attached, overlay a
    # tmpfs at the in-container path so the container can't read or modify
    # those host files.
    $wrapperRepo  = Get-OhdWrapperRepoRoot
    $wrapperStateDirHost = (Get-OhdPaths).Home
    $shadowHostPaths = @()
    $isInsideMounted = {
        param($p)
        if (Test-OhdPathInside -Child $p -Parent $winHome) { return $true }
        foreach ($m in $ExtraMount) {
            if (Test-OhdPathInside -Child $p -Parent $m) { return $true }
        }
        return $false
    }
    if (& $isInsideMounted $wrapperRepo) {
        $shadowHostPaths += $wrapperRepo
        Write-OhdInfo "Wrapper repo is inside a bind-mount; shadowing inside container: $wrapperRepo"
    }
    if (& $isInsideMounted $wrapperStateDirHost) {
        $shadowHostPaths += $wrapperStateDirHost
        Write-OhdInfo "Wrapper state dir will be shadowed inside the container: $wrapperStateDirHost"
    }
    $shadowContainerPaths = @()
    foreach ($p in $shadowHostPaths) {
        $shadowContainerPaths += (ConvertTo-OhdContainerPath -Path $p)
    }
    foreach ($cp in $shadowContainerPaths) {
        $runArgs += @('--tmpfs', "${cp}:rw,size=16m,mode=0755")
    }

    # ---- Per-instance state directories (so multi-instance does NOT bleed) ----
    # Bind-mount a per-instance dir on top of the shared $HOME at the same
    # in-container paths OpenHarness expects: ~/.openharness and ~/.ohmo.
    # Otherwise every container would read/write the same provider profile,
    # memory, and ohmo soul, and `deploy` would silently overwrite the previous
    # instance's settings.
    $perInstRootHost      = Join-Path $winHome ".openharness-instances\$Name"
    $perInstOpenharnessH  = Join-Path $perInstRootHost 'openharness'
    $perInstOhmoH         = Join-Path $perInstRootHost 'ohmo'
    foreach ($d in @($perInstRootHost, $perInstOpenharnessH, $perInstOhmoH)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $perInstOpenharnessC = "$linuxHome/.openharness"
    $perInstOhmoC        = "$linuxHome/.ohmo"
    $runArgs += @('-v', "${perInstOpenharnessH}:${perInstOpenharnessC}")
    $runArgs += @('-v', "${perInstOhmoH}:${perInstOhmoC}")
    Write-OhdInfo "Per-instance state: $perInstRootHost  (isolated from other instances)"

    $runArgs += @($Image, 'idle')
    & docker @runArgs *> $null
    if ($LASTEXITCODE -ne 0) { Stop-OhdDie "docker run failed." }
    Write-OhdOk "Container started: $cname"
}

if (-not (Test-OhdContainerRunning $cname)) { docker start $cname *> $null }

# ---- 6. configure OpenRouter inside container ----
if ($OpenrouterKey -ne '__KEEP__') {
    Write-OhdInfo "Configuring OpenRouter provider inside the container ..."
    $stageHostDir = Join-Path $winHome '.openharness-docker-stage'
    if (-not (Test-Path $stageHostDir)) { New-Item -ItemType Directory -Path $stageHostDir -Force | Out-Null }
    $stageId = [Guid]::NewGuid().ToString('N').Substring(0,8)
    $envFileHost = Join-Path $stageHostDir "env-$stageId"
    $cfgFileHost = Join-Path $stageHostDir "cfg-$stageId.sh"

    # Container-side Linux paths for the same files (bind-mounted via $linuxHome).
    $envFileC = ConvertTo-OhdContainerPath -Path $envFileHost
    $cfgFileC = ConvertTo-OhdContainerPath -Path $cfgFileHost

    # Write env-file (LF endings)
    $envContent = "OPENAI_API_KEY=$OpenrouterKey`nOPENROUTER_API_KEY=$OpenrouterKey`nOH_DEFAULT_MODEL=$Model`n"
    [System.IO.File]::WriteAllText($envFileHost, $envContent)
    # Write configurator script (LF endings)
    $cfgContent = @'
#!/usr/bin/env bash
set -e
mkdir -p "$HOME/.openharness"
oh provider add openrouter \
    --label "OpenRouter" \
    --provider openai \
    --api-format openai \
    --auth-source openai_api_key \
    --base-url "https://openrouter.ai/api/v1" \
    --model "$OH_DEFAULT_MODEL" 2>/dev/null || true
oh provider use openrouter >/dev/null 2>&1 || true
oh config set default_model "$OH_DEFAULT_MODEL" 2>/dev/null || true
'@
    [System.IO.File]::WriteAllText($cfgFileHost, ($cfgContent -replace "`r`n","`n"))

    & docker exec -i --env-file $envFileHost `
        -u "$hostUid`:$hostGid" `
        -e "HOME=$linuxHome" `
        $cname bash $cfgFileC
    $cfgRc = $LASTEXITCODE

    # Persist the OpenRouter API key:
    #  (1) inside the container at /etc/oh-runtime/secrets.env so the entrypoint
    #      can source it before every command (no need to pass -e on each call).
    #  (2) on the host at <per-instance>/runtime-secrets.env (0600) so update-oh.ps1
    #      can re-inject it after a container recreate.  This file lives under
    #      the per-instance dir; it is never bind-mounted into any container,
    #      and goes away with `oh-ctl rm <name> --purge`.
    #
    # We use `docker cp` instead of piping stdin to `docker exec` because
    # PowerShell's native-command stdin pipe has long-standing reliability
    # quirks — it can silently deliver zero bytes.
    $hostSecretPath = Join-Path $perInstRootHost 'runtime-secrets.env'
    Copy-Item -Force -Path $envFileHost -Destination $hostSecretPath
    & docker exec -u 0:0 $cname mkdir -p /etc/oh-runtime *> $null
    & docker exec -u 0:0 $cname chmod 0700 /etc/oh-runtime *> $null
    & docker cp $envFileHost "${cname}:/etc/oh-runtime/secrets.env" *> $null
    & docker exec -u 0:0 $cname chown root:root /etc/oh-runtime/secrets.env *> $null
    & docker exec -u 0:0 $cname chmod 0600 /etc/oh-runtime/secrets.env *> $null

    Remove-Item -Force -Path $envFileHost -ErrorAction SilentlyContinue
    Remove-Item -Force -Path $cfgFileHost -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem -Force $stageHostDir -ErrorAction SilentlyContinue)) {
        Remove-Item -Force $stageHostDir -ErrorAction SilentlyContinue
    }
    if ($cfgRc -ne 0) { Write-OhdWarn "Provider configuration returned $cfgRc; check 'oh provider list' inside the container." }
    else { Write-OhdOk "OpenRouter provider configured inside $cname" }
}

# ---- 7. persist instance metadata ----
Set-OhdInstance -Name $Name -Fields @{
    image = $Image
    container = $cname
    model = $Model
    host_home = $linuxHome
    mount_source = $mountSrc
    host_uid = "$hostUid"
    host_gid = "$hostGid"
    openrouter_key_set = 'yes'
    created_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    platform = 'windows'
    extra_mounts_host = ($ExtraMount -join ';')
    shadow_paths_container = ($shadowContainerPaths -join ';')
    wrapper_repo = $wrapperRepo
    per_instance_root = $perInstRootHost
}

# ---- 8. default instance handling ----
$curDef = Get-OhdDefaultInstance
if (-not $curDef) {
    if ($NoDefault) {
        Write-OhdWarn "No default instance set. Run:  oh-ctl set-default $Name"
    } else {
        Set-OhdDefaultInstance $Name
        Write-OhdOk "Marked '$Name' as default (first instance)."
    }
} elseif ($curDef -eq $Name) {
    Write-OhdInfo "'$Name' is already the default."
} else {
    if ($SetDefault) {
        Set-OhdDefaultInstance $Name; Write-OhdOk "Default instance changed to '$Name' (was '$curDef')."
    } elseif ($NoDefault) {
        Write-OhdInfo "Keeping default as '$curDef'."
    } else {
        if (Confirm-Default "Make '$Name' the default OH instance? (current: $curDef)" $false) {
            Set-OhdDefaultInstance $Name
            Write-OhdOk "Default instance changed to '$Name'."
        } else {
            Write-OhdInfo "Keeping default as '$curDef'."
        }
    }
}

# ---- 9. install host shims ----
& (Join-Path $PSScriptRoot 'scripts/Install-Shims.ps1') -Repo $PSScriptRoot -Bin $paths.ShimBinDir

Write-Host @"

✓ Done.

Instance:    $Name
Container:   $cname
Image:       $Image
Model:       $Model
Default:     $((Get-OhdDefaultInstance))

Try it now (PowerShell):
    cd path\to\your\project
    openh -p "Summarize this repo"
    oh-ctl list

If `openh` / `oh-ctl` are not found, either:
    1) Add the shim dir to PATH:
       [Environment]::SetEnvironmentVariable('Path', "$($paths.ShimBinDir);`$([Environment]::GetEnvironmentVariable('Path','User'))", 'User')
    2) Or dot-source the profile snippet for this session:
       . "$($paths.Home)/profile.ps1"
"@ -ForegroundColor Green
