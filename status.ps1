[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
& (Join-Path $PSScriptRoot 'scripts/oh-ctl.ps1') status @Args
exit $LASTEXITCODE
