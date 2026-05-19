# deploy.ps1 - interactive deployment wizard for OpenHarness sandbox.
#
# This is the SANDBOX deploy. There is no "share-home" mode. The container
# created here has no host filesystem access except through paths passed
# via -Mount. See SECURITY.md for the threat model.
#
# Usage examples:
#     .\deploy.ps1
#     .\deploy.ps1 -Name default -Yes
#     .\deploy.ps1 -Mount D:\Projects -RebuildImage
#     .\deploy.ps1 -Mount D:\Docs:ro
#     .\deploy.ps1 -NoSelfUpdate
[CmdletBinding()]
param(
    [string]$Name,
    [string]$OpenrouterKey,
    [string]$Model,
    [string[]]$Mount = @(),
    [string]$Image,
    [string]$OpenharnessVersion,
    [switch]$RebuildImage,
    [switch]$NoNetwork,
    [switch]$Yes,
    [switch]$SetDefault,
    [switch]$NoDefault,
    [switch]$NoSelfUpdate
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/scripts/lib/Common.psm1" -Force -DisableNameChecking

# ---------------- self-update check (wrapper repo) ----------------
function Invoke-OhdSelfUpdateCheck {
    if ($env:OH_DEPLOYER_SELF_UPDATE_DONE -eq '1') { return }
    if ($NoSelfUpdate) { return }
    if ($env:OH_DEPLOYER_NO_SELF_UPDATE -eq '1') { return }

    function Confirm-OhdContinueWithoutSelfUpdate {
        param([ValidateSet('info','warn')][string]$Level, [string]$Reason, [string]$Hint = '')
        if ($Level -eq 'warn') { Write-OhdWarn $Reason } else { Write-OhdInfo $Reason }
        if ($Hint) { Write-OhdInfo $Hint }
        if ([Environment]::UserInteractive -and $Host.UI.RawUI) {
            $ans = Read-Host -Prompt '? Continue deploy without self-update? [Y/n]'
            if ([string]::IsNullOrWhiteSpace($ans)) { $ans = 'Y' }
            if ($ans -match '^[nN]') { Write-OhdErr 'Aborted by user.'; exit 1 }
        } else {
            Write-OhdInfo 'Non-interactive shell; continuing without self-update.'
        }
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Confirm-OhdContinueWithoutSelfUpdate -Level info -Reason 'git not found; cannot self-update.'
        return
    }
    $repo = Get-OhdWrapperRepoRoot
    if (-not (Test-Path (Join-Path $repo '.git'))) {
        Confirm-OhdContinueWithoutSelfUpdate -Level info -Reason 'Not a git checkout; cannot self-update.'
        return
    }
    $branch = (& git -C $repo rev-parse --abbrev-ref HEAD 2>$null) -join '' 
    if (-not $branch -or $branch -eq 'HEAD') {
        Confirm-OhdContinueWithoutSelfUpdate -Level info -Reason 'Detached HEAD; cannot self-update.'
        return
    }
    & git -C $repo diff --quiet 2>$null
    $dirty1 = ($LASTEXITCODE -ne 0)
    & git -C $repo diff --cached --quiet 2>$null
    $dirty2 = ($LASTEXITCODE -ne 0)
    if ($dirty1 -or $dirty2) {
        Confirm-OhdContinueWithoutSelfUpdate -Level warn `
            -Reason 'Wrapper repo has uncommitted changes; cannot self-update.' `
            -Hint   "Run '.\update-deployer.ps1' manually after committing/stashing."
        return
    }
    Write-OhdInfo "Checking wrapper repo for updates (origin/$branch)..."
    & git -C $repo fetch --quiet --prune origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        Confirm-OhdContinueWithoutSelfUpdate -Level info -Reason 'git fetch failed (offline?); cannot self-update.'
        return
    }
    $local_sha  = ((& git -C $repo rev-parse HEAD) -join '').Trim()
    $remote_sha = ((& git -C $repo rev-parse "origin/$branch") -join '').Trim()
    if ($local_sha -eq $remote_sha) { Write-OhdOk 'Wrapper repo is up to date.'; return }
    $base = ((& git -C $repo merge-base HEAD "origin/$branch" 2>$null) -join '').Trim()
    if ($base -and ($base -ne $local_sha)) {
        Confirm-OhdContinueWithoutSelfUpdate -Level warn `
            -Reason "Local branch has commits not on origin/$branch; cannot fast-forward." `
            -Hint   "Run '.\update-deployer.ps1 -Rebase' manually if you want to integrate."
        return
    }
    $n_behind = ((& git -C $repo rev-list --count "HEAD..origin/$branch" 2>$null) -join '').Trim()
    Write-OhdInfo "Wrapper repo is $n_behind commit(s) behind origin/$branch."
    & git -C $repo log --oneline --no-decorate "HEAD..origin/$branch" | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
    $accept = $true
    if ([Environment]::UserInteractive -and $Host.UI.RawUI) {
        $ans = Read-Host -Prompt '? Pull latest wrapper code and restart deploy? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($ans)) { $ans = 'Y' }
        if ($ans -match '^[nN]') { $accept = $false }
    } else {
        Write-OhdInfo 'Non-interactive shell; auto-accepting self-update.'
    }
    if (-not $accept) { Confirm-OhdContinueWithoutSelfUpdate -Level warn -Reason 'Self-update declined by user.'; return }
    Write-OhdInfo 'Pulling...'
    & git -C $repo pull --ff-only --quiet origin $branch
    if ($LASTEXITCODE -ne 0) {
        Confirm-OhdContinueWithoutSelfUpdate -Level warn -Reason 'git pull --ff-only failed.' -Hint "Run '.\update-deployer.ps1' manually."
        return
    }
    $newSha = ((& git -C $repo rev-parse --short HEAD) -join '').Trim()
    Write-OhdOk "Wrapper repo updated to $newSha. Restarting deploy..."
    $env:OH_DEPLOYER_SELF_UPDATE_DONE = '1'
    $script_path = Join-Path $repo 'deploy.ps1'
    $argv = @()
    if ($Name) { $argv += @('-Name', $Name) }
    if ($OpenrouterKey) { $argv += @('-OpenrouterKey', $OpenrouterKey) }
    if ($Model) { $argv += @('-Model', $Model) }
    foreach ($m in $Mount) { $argv += @('-Mount', $m) }
    if ($Image) { $argv += @('-Image', $Image) }
    if ($OpenharnessVersion) { $argv += @('-OpenharnessVersion', $OpenharnessVersion) }
    if ($RebuildImage) { $argv += '-RebuildImage' }
    if ($NoNetwork) { $argv += '-NoNetwork' }
    if ($Yes) { $argv += '-Yes' }
    if ($SetDefault) { $argv += '-SetDefault' }
    if ($NoDefault) { $argv += '-NoDefault' }
    & pwsh -NoProfile -File $script_path @argv
    exit $LASTEXITCODE
}
Invoke-OhdSelfUpdateCheck

if (-not (Test-OhdSupportedHost)) { Stop-OhdDie "Unsupported host platform." }
Assert-OhdDocker
Initialize-OhdConfig

# ---------------- helpers ----------------
function Read-OhdValue {
    param([string]$Prompt, [string]$Default)
    if ($Yes) { return $Default }
    if ($Default) {
        $ans = Read-Host "? $Prompt [$Default]"
    } else {
        $ans = Read-Host "? $Prompt"
    }
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return $ans
}

function Read-OhdSecret {
    param([string]$Prompt)
    if ($Yes) { return '' }
    $sec = Read-Host -AsSecureString -Prompt "? $Prompt"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Confirm-OhdYes {
    param([string]$Prompt, [string]$Default = 'no')
    if ($Yes) { return ($Default -eq 'yes') }
    $hint = if ($Default -eq 'yes') { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "? $Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $Default }
    return ($ans -match '^(y|Y|yes|YES|Yes)$')
}

# ---------------- defaults ----------------
$IMAGE_TAG = if ($Image) { $Image } else { 'openharness-dockerized:latest' }

# ---------------- banner ----------------
Write-Host @"
╔══════════════════════════════════════════════════════╗
║          OpenHarness Sandbox - Deploy                ║
╚══════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan
Write-Host @"
This wizard will:
  1) ask for an instance name
  2) ask for your OpenRouter API key + default model
  3) build the docker image (first time only)
  4) create a hardened sandbox container (NO host `$HOME access)
  5) configure the OpenRouter provider profile inside the container
  6) install oh / ohmo / openh / oh-ctl shims

"@
Write-Host "Security model:" -ForegroundColor Yellow -NoNewline
Write-Host " the agent inside the container can read/write ONLY the host"
Write-Host "paths you pass via -Mount. See SECURITY.md.`n"

# ---------------- 1. instance name ----------------
$existingNames = @(Get-OhdInstanceNames)
if (-not $Name) {
    if ($existingNames.Count -eq 0) {
        $Name = Read-OhdValue -Prompt "Instance name" -Default "default"
    } else {
        Write-OhdInfo "Existing instances:"
        $existingNames | ForEach-Object { Write-Host "    - $_" }
        $Name = Read-OhdValue -Prompt "New (or existing to redeploy) instance name" -Default ""
    }
}
if (-not $Name) { Stop-OhdDie "Instance name is required." }
if ($Name -notmatch '^[a-zA-Z0-9_.\-]+$') { Stop-OhdDie "Invalid instance name: '$Name'" }

$CONTAINER_NAME = Get-OhdContainerName $Name
$HOME_VOLUME    = Get-OhdHomeVolumeName $Name

# ---------------- 2. credentials ----------------
if (-not $OpenrouterKey -and $env:OPENROUTER_API_KEY) {
    $OpenrouterKey = $env:OPENROUTER_API_KEY
}
$inst = Get-OhdInstance $Name
$existingKeySet = if ($inst -and $inst.openrouter_key_set -eq 'yes') { $true } else { $false }
if (-not $OpenrouterKey) {
    if ($existingKeySet -and (Confirm-OhdYes -Prompt "Reuse existing OpenRouter API key for '$Name'?" -Default 'yes')) {
        $OpenrouterKey = '__KEEP__'
    } else {
        Write-OhdInfo "Get a key at: https://openrouter.ai/keys"
        Write-OhdInfo "Tip: create a sub-key with a budget cap; the agent inside the sandbox CAN read this key."
        $OpenrouterKey = Read-OhdSecret -Prompt "OpenRouter API key (input hidden)"
        if (-not $OpenrouterKey) { Stop-OhdDie "OpenRouter API key is required." }
    }
}
if (-not $Model) {
    $suggested = if ($inst -and $inst.model) { $inst.model } else { 'anthropic/claude-3.5-sonnet' }
    $Model = Read-OhdValue -Prompt "Default OpenRouter model id" -Default $suggested
}

# ---------------- 3. mounts (validate before doing anything) -------
$dockerMountArgs = New-Object System.Collections.Generic.List[string]
$mountDescs      = New-Object System.Collections.Generic.List[string]
$mountRecords    = New-Object System.Collections.Generic.List[hashtable]
$usedBaseSuffix  = @{}

foreach ($raw in $Mount) {
    $ro = $false
    $spec = $raw
    if ($spec -match ':ro$') { $ro = $true; $spec = $spec.Substring(0, $spec.Length - 3) }
    Assert-OhdMountSafe -Path $spec
    $canonical = Resolve-OhdCanonicalPath $spec
    if (-not (Test-Path -LiteralPath $canonical -PathType Container)) {
        Stop-OhdDie "mount '$spec' canonical '$canonical' does not exist or is not a directory."
    }
    $base = Split-Path -Leaf $canonical
    $base = ($base -replace '[^A-Za-z0-9._-]','_')
    if (-not $base) { $base = 'root' }
    $suffix = ''
    if ($usedBaseSuffix.ContainsKey($base)) {
        $suffix = "$($usedBaseSuffix[$base])"
        $usedBaseSuffix[$base] = $usedBaseSuffix[$base] + 1
    } else {
        $usedBaseSuffix[$base] = 2
    }
    $target = Get-OhdContainerTargetFor -HostPath $canonical -Suffix $suffix
    $mountSrc = Get-OhdMountSource $canonical
    if ($ro) {
        $dockerMountArgs.Add("--mount=type=bind,source=$mountSrc,target=$target,readonly,bind-recursive=disabled") | Out-Null
        $mountDescs.Add("$canonical -> $target  :ro") | Out-Null
    } else {
        $dockerMountArgs.Add("--mount=type=bind,source=$mountSrc,target=$target,bind-recursive=disabled") | Out-Null
        $mountDescs.Add("$canonical -> $target") | Out-Null
    }
    $mountRecords.Add(@{ host = $canonical; target = $target; readonly = $ro }) | Out-Null
}

# ---------------- 4. image ----------------
$needBuild = $false
if ($RebuildImage) { $needBuild = $true }
& docker image inspect $IMAGE_TAG *> $null
if ($LASTEXITCODE -ne 0) { $needBuild = $true }
if ($needBuild) {
    Write-OhdInfo "Building image $IMAGE_TAG ..."
    $build_args = @(
        '--build-arg', "SANDBOX_UID=$script:OhdSandboxUid",
        '--build-arg', "SANDBOX_GID=$script:OhdSandboxGid"
    )
    if ($OpenharnessVersion) { $build_args += @('--build-arg', "OPENHARNESS_VERSION=$OpenharnessVersion") }
    & docker build @build_args -t $IMAGE_TAG (Join-Path (Get-OhdWrapperRepoRoot) 'docker')
    if ($LASTEXITCODE -ne 0) { Stop-OhdDie "docker build failed." }
    Write-OhdOk "Image built: $IMAGE_TAG"
} else {
    Write-OhdInfo "Reusing existing image $IMAGE_TAG (use -RebuildImage to force rebuild)"
}

# ---------------- 5. (re)create container ----------------
if (Test-OhdContainerExists $CONTAINER_NAME) {
    if (Confirm-OhdYes -Prompt "Container '$CONTAINER_NAME' already exists. Recreate it?" -Default 'yes') {
        & docker rm -f $CONTAINER_NAME *> $null
    } else {
        Write-OhdInfo "Keeping existing container; will only update provider config inside it."
    }
}

# Ensure the home volume.
& docker volume inspect $HOME_VOLUME *> $null
if ($LASTEXITCODE -ne 0) {
    Write-OhdInfo "Creating named volume $HOME_VOLUME ..."
    & docker volume create $HOME_VOLUME *> $null
}

$networkMode = if ($NoNetwork) { 'none' } else { 'bridge' }

$run_args = @(
    'run','-d','--restart','unless-stopped'
    '--name', $CONTAINER_NAME
    '--label', $script:OhdLabel
    '--label', $script:OhdLabelSandbox
    '--label', "dev.openharness.instance=$Name"
    '--hostname', $CONTAINER_NAME
    '--user', "$script:OhdSandboxUid`:$script:OhdSandboxGid"
    '--read-only'
    '--tmpfs', '/tmp:size=512m,mode=1777,nosuid,nodev,noexec'
    '--tmpfs', '/run:size=64m,mode=755,nosuid,nodev,noexec'
    '-v', "$HOME_VOLUME`:/oh-home"
    '--cap-drop=ALL'
    '--security-opt=no-new-privileges:true'
    '--pids-limit', '512'
    '--memory', '4g'
    '--cpus', '2'
    '-e', 'HOME=/oh-home'
    '-e', "OH_INSTANCE=$Name"
    '-e', "OH_DEFAULT_MODEL=$Model"
    '--add-host', 'metadata.google.internal:127.0.0.1'
    '--add-host', 'metadata.tencentyun.com:127.0.0.1'
    '--add-host', 'metadata.aliyuncs.com:127.0.0.1'
    '--add-host', 'metadata.azure.com:127.0.0.1'
    '--add-host', '169.254.169.254:127.0.0.1'
)
if ($networkMode -eq 'none') { $run_args += '--network=none' }
foreach ($m in $dockerMountArgs) { $run_args += $m }

if (-not (Test-OhdContainerExists $CONTAINER_NAME)) {
    Write-OhdInfo "Creating sandbox container $CONTAINER_NAME ..."
    & docker @run_args $IMAGE_TAG idle *> $null
    if ($LASTEXITCODE -ne 0) { Stop-OhdDie "docker run failed." }
    Write-OhdOk "Container started: $CONTAINER_NAME"
}
if (-not (Test-OhdContainerRunning $CONTAINER_NAME)) {
    & docker start $CONTAINER_NAME *> $null
}

# ---------------- 6. inject secrets + configure provider ------------------
function Set-OhdSecrets {
    param([string]$Key, [string]$ModelId)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        @(
            "OPENAI_API_KEY=$Key",
            "OPENROUTER_API_KEY=$Key",
            "OPENAI_BASE_URL=https://openrouter.ai/api/v1",
            "OPENHARNESS_API_FORMAT=openai",
            "OH_DEFAULT_MODEL=$ModelId"
        ) -join "`n" | Set-Content -NoNewline -Path $tmp -Encoding ASCII
        & docker exec $CONTAINER_NAME mkdir -p /oh-home/.oh-runtime *> $null
        # Pipe through docker exec -i so file is owned by UID 1000.
        Get-Content -LiteralPath $tmp | & docker exec -i $CONTAINER_NAME sh -c 'cat > /oh-home/.oh-runtime/secrets.env && chmod 0400 /oh-home/.oh-runtime/secrets.env'
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

if ($OpenrouterKey -ne '__KEEP__') {
    Write-OhdInfo "Injecting OpenRouter secrets into the sandbox ..."
    Set-OhdSecrets -Key $OpenrouterKey -ModelId $Model
}

Write-OhdInfo "Configuring OpenRouter provider inside the sandbox ..."
$cfgScript = @'
mkdir -p $HOME/.openharness
oh provider add openrouter \
    --label "OpenRouter" \
    --provider openai \
    --api-format openai \
    --auth-source openai_api_key \
    --base-url "https://openrouter.ai/api/v1" \
    --model "${OH_DEFAULT_MODEL}" 2>/dev/null || true
oh provider use openrouter >/dev/null 2>&1 || true
oh config set default_model "${OH_DEFAULT_MODEL}" 2>/dev/null || true
'@
# Stage script via stdin pipe (avoids quoting/escaping inside the container).
$cfgScript | & docker exec -i $CONTAINER_NAME sh -c 'cat > /oh-home/.oh-runtime/configure.sh && chmod 0500 /oh-home/.oh-runtime/configure.sh'
& docker exec -e "OH_DEFAULT_MODEL=$Model" $CONTAINER_NAME bash -c '. /oh-home/.oh-runtime/secrets.env 2>/dev/null; bash /oh-home/.oh-runtime/configure.sh' 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) { Write-OhdWarn "Provider configuration returned a non-zero status." }

# ---------------- 7. persist instance metadata ---------------------------
Set-OhdInstance -Name $Name -Fields @{
    image              = $IMAGE_TAG
    container          = $CONTAINER_NAME
    home_volume        = $HOME_VOLUME
    model              = $Model
    network            = $networkMode
    openrouter_key_set = 'yes'
    wrapper_repo       = (Get-OhdWrapperRepoRoot)
    created_at         = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
}
Set-OhdInstanceMounts -Name $Name -Mounts @($mountRecords)

# ---------------- 8. default-instance handling ----------------
$current_default = Get-OhdDefaultInstance
if (-not $current_default) {
    if ($NoDefault) {
        Write-OhdWarn "No default instance set. Run:  oh-ctl set-default $Name"
    } else {
        Set-OhdDefaultInstance -Name $Name
        Write-OhdOk "Marked '$Name' as default (first instance)."
    }
} else {
    if ($current_default -eq $Name) {
        Write-OhdInfo "'$Name' is already the default."
    } elseif ($SetDefault) {
        Set-OhdDefaultInstance -Name $Name
        Write-OhdOk "Default instance changed to '$Name' (was '$current_default')."
    } elseif ($NoDefault) {
        Write-OhdInfo "Keeping default as '$current_default'."
    } else {
        if (Confirm-OhdYes -Prompt "Make '$Name' the default OH instance? (current: $current_default)" -Default 'no') {
            Set-OhdDefaultInstance -Name $Name
            Write-OhdOk "Default instance changed to '$Name'."
        } else {
            Write-OhdInfo "Keeping default as '$current_default'."
        }
    }
}

# ---------------- 9. install shims ----------------
$installShims = Join-Path (Get-OhdWrapperRepoRoot) 'scripts/Install-Shims.ps1'
$tmplPath = Join-Path (Get-OhdWrapperRepoRoot) 'scripts/lib/shim_template.ps1'
if ((Test-Path $installShims) -and (Test-Path $tmplPath) -and ((Get-Content -Raw $tmplPath) -match 'OHD_SHIM_TEMPLATE_VERSION\s*=\s*2')) {
    & pwsh -NoProfile -File $installShims -Repo (Get-OhdWrapperRepoRoot) -Bin $script:OhdShimBinDir
} else {
    Write-OhdWarn "Install-Shims.ps1 skipped (shim template v2 not yet present)."
    Write-OhdInfo "Run it manually once shims are upgraded: $installShims"
}

# ---------------- 10. summary ----------------
Write-Host ""
Write-OhdOk "Done."
Write-Host ""
Write-Host "Instance:    " -NoNewline; Write-Host $Name -ForegroundColor White
Write-Host "Container:   $CONTAINER_NAME"
Write-Host "Image:       $IMAGE_TAG"
Write-Host "Home volume: $HOME_VOLUME    (Docker named volume; not on your host home)"
Write-Host "Model:       $Model"
Write-Host "Network:     $networkMode"
Write-Host "Default:     $(Get-OhdDefaultInstance)"
Write-Host ""
Write-Host "Sandbox mounts (the ONLY host paths the agent can see):"
if ($mountDescs.Count -eq 0) {
    Write-Host "  (none)  -- the agent has no host filesystem access."
    Write-Host "  Add one with:  oh-ctl mount add <host_path>"
} else {
    foreach ($d in $mountDescs) { Write-Host "  $d" }
}
Write-Host ""
Write-Host "Try it now:"
Write-Host "    oh-ctl mount add D:\path\to\your\project    # expose a host dir"
Write-Host "    cd D:\path\to\your\project; openh -p 'Summarize'"
Write-Host "    oh-ctl list"
Write-Host ""
Write-Host "If 'openh' is not found, restart your shell or:"
Write-Host "    `$env:Path = '$($script:OhdShimBinDir);' + `$env:Path"
Write-Host ""
Write-Host "Read SECURITY.md for the full threat model and isolation contract."
