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

$built = @{}
foreach ($n in $names) {
    if ($Name -and $n -ne $Name) { continue }
    $inst = Get-OhdInstance $n
    $image = if ($inst.image) { $inst.image } else { (Get-OhdPaths).ImageDefault }

    if (-not $built.ContainsKey($image)) {
        Write-OhdInfo "Rebuilding image: $image (instance=$n)"
        $bargs = @('build','--no-cache',
            '--build-arg', "HOST_UID=1000",
            '--build-arg', "HOST_GID=1000",
            '--build-arg', "HOST_USER=ohuser",
            '--build-arg', "HOST_HOME=$($inst.host_home)")
        if ($Version) { $bargs += @('--build-arg', "OPENHARNESS_VERSION=$Version") }
        $bargs += @('-t', $image, (Join-Path $PSScriptRoot 'docker'))
        & docker @bargs
        if ($LASTEXITCODE -ne 0) { Stop-OhdDie "build failed for $image" }
        $built[$image] = $true
    }

    $cname = Get-OhdContainerName $n
    Write-OhdInfo "Re-creating container $cname ..."
    if (Test-OhdContainerExists $cname) { docker rm -f $cname *> $null }
    $mountSrc = if ($inst.mount_source) { $inst.mount_source } else { $inst.host_home }

    # Per-instance state directory; recompute if missing (older instance metadata).
    $perInstRoot = if ($inst.per_instance_root) { $inst.per_instance_root } else { Join-Path $HOME ".openharness-instances\$n" }
    $perOh   = Join-Path $perInstRoot 'openharness'
    $perOhmo = Join-Path $perInstRoot 'ohmo'
    foreach ($d in @($perInstRoot, $perOh, $perOhmo)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $runArgs = @(
        'run','-d','--restart','unless-stopped',
        '--name', $cname,
        '--label', (Get-OhdPaths).Label,
        '--label', "dev.openharness.instance=$n",
        '--hostname', $cname,
        '-e', "HOST_UID=$($inst.host_uid)", '-e', "HOST_GID=$($inst.host_gid)",
        '-e', 'HOST_USER=ohuser', '-e', "HOST_HOME=$($inst.host_home)",
        '-e', "OH_RUNTIME_HOME=$($inst.host_home)", '-e', "OH_INSTANCE=$n",
        '-v', "${mountSrc}:$($inst.host_home)",
        '-v', "${perOh}:$($inst.host_home)/.openharness",
        '-v', "${perOhmo}:$($inst.host_home)/.ohmo"
    )
    if ($inst.extra_mounts_host) {
        foreach ($m in ($inst.extra_mounts_host -split ';')) {
            if (-not $m) { continue }
            $src = Get-OhdMountSource -Path $m
            $dst = ConvertTo-OhdContainerPath -Path $m
            $runArgs += @('-v', "${src}:${dst}")
        }
    }
    if ($inst.shadow_paths_container) {
        foreach ($cp in ($inst.shadow_paths_container -split ';')) {
            if (-not $cp) { continue }
            $runArgs += @('--tmpfs', "${cp}:rw,size=16m,mode=0755")
        }
    }
    $runArgs += @($image, 'idle')

    & docker @runArgs *> $null
    if ($LASTEXITCODE -ne 0) { Stop-OhdDie "docker run failed for $cname" }

    # Re-inject runtime secrets from the host-side per-instance copy.
    $secretFile = Join-Path $perInstRoot 'runtime-secrets.env'
    if (Test-Path $secretFile) {
        & docker exec -u 0:0 $cname mkdir -p /etc/oh-runtime *> $null
        & docker exec -u 0:0 $cname chmod 0700 /etc/oh-runtime *> $null
        & docker cp $secretFile "${cname}:/etc/oh-runtime/secrets.env" *> $null
        & docker exec -u 0:0 $cname chown root:root /etc/oh-runtime/secrets.env *> $null
        & docker exec -u 0:0 $cname chmod 0600 /etc/oh-runtime/secrets.env *> $null
    }

    Write-OhdOk "Updated $cname"
}
Write-OhdOk "All requested instances updated."
