# oh-ctl.ps1 - manage OpenHarness sandbox instances (PowerShell port).
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Subcommand,
    [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$Args
)

Import-Module "$PSScriptRoot/lib/Common.psm1" -Force -DisableNameChecking

function Show-Usage {
@"
oh-ctl  -  manage OpenHarness sandbox instances

Usage:
  oh-ctl list                          List all instances and the default one
  oh-ctl set-default <name>            Set <name> as the default instance
  oh-ctl unset-default                 Clear the default instance
  oh-ctl status [name]                 Show container status (all if no name)
  oh-ctl start [name]                  Start a stopped container
  oh-ctl stop [name]                   Stop a running container
  oh-ctl restart [name]                Restart container (default if omitted)
  oh-ctl logs [name] [-f]              Show container logs
  oh-ctl shell [name]                  Open an interactive bash inside container
  oh-ctl exec <name> -- <cmd...>       Run a command inside a specific instance
  oh-ctl rm <name> [--purge]           Remove the container (--purge wipes home volume + metadata)
  oh-ctl info <name>                   Show instance details (mounts, image, model, ...)

  oh-ctl mount list [name]             List active sandbox mounts for an instance
  oh-ctl mount add <host_path> [name] [--ro]
                                       Add a host directory as a sandbox mount.
                                       Triggers container recreation.
  oh-ctl mount rm <host_path> [name]   Remove a sandbox mount.

Tips:
  Set `$env:OH_INSTANCE='<name>'` in your shell to override the default temporarily.
  Set `$env:OH_AUTO_MOUNT_CWD='1'` to allow ad-hoc cwd mounting at \`oh\` time
  without the [y/N] prompt (off by default for safety).
"@ | Write-Host
}

if (-not $Subcommand -or $Subcommand -in @('-h','--help','help')) { Show-Usage; exit 0 }

function Invoke-OhdRecreateWithCurrentMounts {
    param([Parameter(Mandatory)][string]$Instance)
    $repo = Get-OhdWrapperRepoRoot
    $deployer = Join-Path $repo 'deploy.ps1'
    if (-not (Test-Path $deployer)) { Stop-OhdDie "Cannot find deploy.ps1 at $deployer" }
    Write-OhdInfo "Recreating container for instance '$Instance' with the updated mount list..."
    # -NoDefault: never accidentally promote this instance to default just because
    # the user added/removed a mount.
    $argv = @('-Name', $Instance, '-NoSelfUpdate', '-Yes', '-NoDefault')
    foreach ($m in (Get-OhdInstanceMounts $Instance)) {
        if ($m.readonly) { $argv += @('-Mount', "$($m.host):ro") }
        else             { $argv += @('-Mount',  "$($m.host)")    }
    }
    & pwsh -NoProfile -File $deployer @argv
}

switch ($Subcommand) {
    { $_ -in 'list','ls' } {
        Initialize-OhdConfig
        $def = Get-OhdDefaultInstance
        '{0,2} {1,-14} {2,-9} {3,-32} {4}' -f '', 'NAME','STATE','IMAGE','MODEL' | Write-Host
        $names = @(Get-OhdInstanceNames)
        if ($names.Count -eq 0) { Write-OhdWarn "No instances yet. Run deploy.ps1"; break }
        foreach ($n in $names) {
            $cname = Get-OhdContainerName $n
            $state = if (Test-OhdContainerRunning $cname) { 'running' } else { 'stopped' }
            $inst  = Get-OhdInstance $n
            $image = if ($inst.image) { $inst.image } else { '?' }
            $model = if ($inst.model) { $inst.model } else { '?' }
            $mark  = if ($n -eq $def) { '* ' } else { '  ' }
            '{0}{1,-14} {2,-9} {3,-32} {4}' -f $mark, $n, $state, $image, $model | Write-Host
        }
        Write-Host ''
        if ($def) { Write-OhdInfo "Default: $def  (override per-call: `$env:OH_INSTANCE='name'; openh ...)" }
        else      { Write-OhdWarn "No default instance set. Use:  oh-ctl set-default <name>" }
        break
    }

    'set-default' {
        $name = $Args | Select-Object -First 1
        if (-not $name) { Stop-OhdDie "Usage: oh-ctl set-default <name>" }
        if (-not (Test-OhdInstance $name)) { Stop-OhdDie "No such instance: $name" }
        Set-OhdDefaultInstance $name
        Write-OhdOk "Default instance set to: $name"
        break
    }

    'unset-default' { Set-OhdDefaultInstance $null; Write-OhdOk "Cleared default instance."; break }

    'status' {
        Assert-OhdDocker
        Initialize-OhdConfig
        $name = $Args | Select-Object -First 1
        if ($name) {
            if (-not (Test-OhdInstance $name)) { Stop-OhdDie "No such instance: $name" }
            $cname = Get-OhdContainerName $name
            docker ps -a --filter "name=^$cname`$" --filter "label=$($script:OhdLabel)" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
        } else {
            docker ps -a --filter "label=$($script:OhdLabel)" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.RunningFor}}'
        }
        break
    }

    { $_ -in 'start','stop','restart' } {
        Assert-OhdDocker
        $name = ($Args | Select-Object -First 1)
        if (-not $name) { $name = Get-OhdDefaultInstance }
        if (-not $name) { Stop-OhdDie "No instance specified and no default set." }
        $cname = Get-OhdContainerName $name
        & docker $Subcommand $cname *> $null
        if ($LASTEXITCODE -ne 0) { Stop-OhdDie "docker $Subcommand $cname failed" }
        Write-OhdOk ("{0}ed {1}" -f ($Subcommand -replace 'p$','pp'), $cname)
        break
    }

    'logs' {
        Assert-OhdDocker
        $rest = @($Args)
        $name = if ($rest.Count -gt 0 -and -not $rest[0].StartsWith('-')) { $rest[0] } else { Get-OhdDefaultInstance }
        if (-not $name) { Stop-OhdDie "No instance specified and no default set." }
        $cname = Get-OhdContainerName $name
        $passed = @($rest | Where-Object { $_ -ne $name })
        & docker logs @passed $cname
        break
    }

    'shell' {
        Assert-OhdDocker
        $name = ($Args | Select-Object -First 1)
        if (-not $name) { $name = Get-OhdDefaultInstance }
        if (-not $name) { Stop-OhdDie "No instance specified and no default set." }
        if (-not (Test-OhdInstance $name)) { Stop-OhdDie "No such instance: $name" }
        $cname = Get-OhdContainerName $name
        if (-not (Test-OhdContainerRunning $cname)) { docker start $cname *> $null }
        & docker exec -it -w '/oh-home' -e "OH_INSTANCE=$name" $cname oh-entrypoint exec -- bash -l
        exit $LASTEXITCODE
    }

    'exec' {
        Assert-OhdDocker
        $rest = @($Args)
        if ($rest.Count -lt 1) { Stop-OhdDie "Usage: oh-ctl exec <name> -- <cmd...>" }
        $name = $rest[0]
        if (-not (Test-OhdInstance $name)) { Stop-OhdDie "No such instance: $name" }
        $remaining = @($rest | Select-Object -Skip 1)
        if ($remaining.Count -gt 0 -and $remaining[0] -eq '--') { $remaining = @($remaining | Select-Object -Skip 1) }
        if ($remaining.Count -lt 1) { Stop-OhdDie "No command provided." }
        $argv = Get-OhdExecArgs -Instance $name -TargetCli $remaining[0] -Arguments @($remaining | Select-Object -Skip 1)
        & docker @argv
        exit $LASTEXITCODE
    }

    { $_ -in 'rm','remove','destroy' } {
        Assert-OhdDocker
        $rest = @($Args)
        if ($rest.Count -lt 1) { Stop-OhdDie "Usage: oh-ctl rm <name> [--purge]" }
        $name = $rest[0]
        $purge = $rest -contains '--purge'
        if (-not (Test-OhdInstance $name)) { Stop-OhdDie "No such instance: $name" }
        $cname = Get-OhdContainerName $name
        if (Test-OhdContainerExists $cname) { docker rm -f $cname *> $null; Write-OhdOk "Container $cname removed" }
        else { Write-OhdWarn "No container '$cname' to remove." }
        if ($purge) {
            $inst = Get-OhdInstance $name
            $homeVol = if ($inst -and $inst.home_volume) { $inst.home_volume } else { (Get-OhdHomeVolumeName $name) }
            & docker volume inspect $homeVol *> $null
            if ($LASTEXITCODE -eq 0) { docker volume rm $homeVol *> $null; Write-OhdOk "Home volume '$homeVol' removed" }
            Remove-OhdInstance $name
            $instDir = Join-Path $script:OhdInstancesDir $name
            if (Test-Path $instDir) { Remove-Item -Recurse -Force -Path $instDir -ErrorAction SilentlyContinue }
            Write-OhdOk "Instance metadata for '$name' purged."
        } else {
            Write-OhdInfo "Instance metadata kept; redeploy with: deploy.ps1 -Name $name"
        }
        break
    }

    'info' {
        $name = $Args | Select-Object -First 1
        if (-not $name) { Stop-OhdDie "Usage: oh-ctl info <name>" }
        if (-not (Test-OhdInstance $name)) { Stop-OhdDie "No such instance: $name" }
        $inst = Get-OhdInstance $name
        ([ordered]@{ name = $name } + $inst) | ConvertTo-Json -Depth 5 | Write-Host
        break
    }

    'mount' {
        $rest = @($Args)
        $sub = if ($rest.Count -ge 1) { $rest[0] } else { '' }
        switch ($sub) {
            'list' {
                $name = if ($rest.Count -ge 2) { $rest[1] } else { Get-OhdDefaultInstance }
                if (-not $name) { Stop-OhdDie "No instance specified and no default set." }
                if (-not (Test-OhdInstance $name)) { Stop-OhdDie "No such instance: $name" }
                foreach ($m in (Get-OhdInstanceMounts $name)) {
                    $ro = if ($m.readonly) { '  :ro' } else { '' }
                    Write-Host "  $($m.host)  ->  $($m.target)$ro"
                }
                break
            }
            'add' {
                if ($rest.Count -lt 2) { Stop-OhdDie "Usage: oh-ctl mount add <host_path> [instance] [--ro]" }
                $hp = $rest[1]
                $ro = $false
                $name = $null
                foreach ($a in @($rest | Select-Object -Skip 2)) {
                    if ($a -in '--ro',':ro') { $ro = $true } else { $name = $a }
                }
                if (-not $name) { $name = Get-OhdDefaultInstance }
                if (-not $name) { Stop-OhdDie "No instance specified and no default set." }
                if (-not (Test-OhdInstance $name)) { Stop-OhdDie "No such instance: $name" }
                Assert-OhdMountSafe -Path $hp
                $canonical = Resolve-OhdCanonicalPath $hp
                if (-not (Test-Path -LiteralPath $canonical -PathType Container)) {
                    Stop-OhdDie "$hp is not a directory."
                }
                $existing = @(Get-OhdInstanceMounts $name)
                foreach ($m in $existing) {
                    if ($m.host -eq $canonical) { Stop-OhdDie "Mount '$canonical' is already attached to instance '$name'." }
                }
                # Avoid target collision.
                $cand = Get-OhdContainerTargetFor -HostPath $canonical
                $n = 2
                while ($existing.target -contains $cand) {
                    $cand = Get-OhdContainerTargetFor -HostPath $canonical -Suffix "$n"
                    $n++
                }
                Add-OhdInstanceMount -Name $name -HostPath $canonical -Target $cand -ReadOnly $ro
                $rolab = if ($ro) { ' :ro' } else { '' }
                Write-OhdOk "Recorded mount: $canonical -> $cand$rolab"
                Invoke-OhdRecreateWithCurrentMounts -Instance $name
                break
            }
            { $_ -in 'rm','remove' } {
                if ($rest.Count -lt 2) { Stop-OhdDie "Usage: oh-ctl mount rm <host_path> [instance]" }
                $hp = $rest[1]
                $name = if ($rest.Count -ge 3) { $rest[2] } else { Get-OhdDefaultInstance }
                if (-not $name) { Stop-OhdDie "No instance specified and no default set." }
                if (-not (Test-OhdInstance $name)) { Stop-OhdDie "No such instance: $name" }
                $canonical = Resolve-OhdCanonicalPath $hp
                $existing = @(Get-OhdInstanceMounts $name)
                if (-not ($existing | Where-Object { $_.host -eq $canonical })) {
                    Stop-OhdDie "Mount '$canonical' is not attached to instance '$name'."
                }
                $newArr = @($existing | Where-Object { $_.host -ne $canonical })
                Set-OhdInstanceMounts -Name $name -Mounts $newArr
                Write-OhdOk "Removed mount: $canonical"
                Invoke-OhdRecreateWithCurrentMounts -Instance $name
                break
            }
            default {
                @"
oh-ctl mount  -  manage sandbox mounts

  oh-ctl mount list [instance]
  oh-ctl mount add  <host_path> [instance] [--ro]
  oh-ctl mount rm   <host_path> [instance]

Adding or removing a mount recreates the container; the named-volume HOME
(`$HOME inside the container) is preserved across the recreation.
"@ | Write-Host
            }
        }
        break
    }

    default {
        Write-OhdErr "Unknown subcommand: $Subcommand"
        Show-Usage; exit 1
    }
}
