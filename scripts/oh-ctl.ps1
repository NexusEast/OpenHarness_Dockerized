# oh-ctl.ps1 - manage multiple OpenHarness containers (PowerShell port).
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Subcommand,
    [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$Args
)

Import-Module "$PSScriptRoot/lib/Common.psm1" -Force -DisableNameChecking

function Show-Usage {
@"
oh-ctl  -  manage OpenHarness Docker instances

Usage:
  oh-ctl list                        List all instances and show the default one
  oh-ctl set-default <name>          Set <name> as the default instance
  oh-ctl unset-default               Clear the default instance
  oh-ctl status [name]               Show container status (all if no name)
  oh-ctl start [name]                Start a stopped container
  oh-ctl stop [name]                 Stop a running container
  oh-ctl restart [name]              Restart container (default if omitted)
  oh-ctl logs [name] [-f]            Show container logs
  oh-ctl shell [name]                Open an interactive bash inside container
  oh-ctl exec <name> -- <cmd...>     Run a command inside a specific instance
  oh-ctl rm <name> [--purge]         Remove the container (--purge wipes metadata)
  oh-ctl info <name>                 Show instance details
"@ | Write-Host
}

if (-not $Subcommand -or $Subcommand -in @('-h','--help','help')) { Show-Usage; exit 0 }

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
            docker ps -a --filter "label=$((Get-OhdPaths).Label)" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.RunningFor}}'
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
        $cwd = (Get-Location).ProviderPath
        $cwdC = ConvertTo-OhdContainerPath -Path $cwd
        & docker exec -it -w $cwdC -e "OH_INSTANCE=$name" $cname oh-entrypoint exec -- bash -l
        break
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
            $perInstRoot = if ($inst -and $inst.per_instance_root) { $inst.per_instance_root } else { $null }
            Remove-OhdInstance $name
            Remove-Item -Recurse -Force -Path (Join-Path (Get-OhdPaths).InstancesDir $name) -ErrorAction SilentlyContinue
            if ($perInstRoot -and (Test-Path $perInstRoot)) {
                Remove-Item -Recurse -Force -Path $perInstRoot -ErrorAction SilentlyContinue
                Write-OhdOk "Per-instance state purged: $perInstRoot"
            }
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

    default {
        Write-OhdErr "Unknown subcommand: $Subcommand"
        Show-Usage; exit 1
    }
}
