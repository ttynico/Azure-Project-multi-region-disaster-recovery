<#
.SYNOPSIS
    Prints replication health and current RPO for every VM protected by the vault.
    Exit code 1 if anything is not Normal/Protected (usable as a scheduled check).

.EXAMPLE
    ./Get-ReplicationHealth.ps1 -ResourceGroupName rg-drlab-dr-westus2 -VaultName rsv-drlab-dr-abcde -RpoAlertSeconds 900
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $VaultName,
    [int] $RpoAlertSeconds = 900
)

$ErrorActionPreference = 'Stop'
Import-Module Az.RecoveryServices -ErrorAction Stop
. (Join-Path $PSScriptRoot 'AsrHelpers.ps1')

$vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName
Set-AzRecoveryServicesAsrVaultContext -Vault $vault | Out-Null

$rows = Get-ReplicationHealth
$rows | Format-Table Name, SourceFabric, ProtectionState, ReplicationHealth, RpoSeconds, LastRpoCalculated, ActiveLocation -AutoSize

$bad = $rows | Where-Object {
    $_.ReplicationHealth -ne 'Normal' -or $_.ProtectionState -ne 'Protected' -or ($_.RpoSeconds -gt $RpoAlertSeconds)
}
if ($bad) {
    Write-Warning "$($bad.Count) item(s) outside policy (health/protection/RPO > $RpoAlertSeconds s)."
    exit 1
}
Write-Step "All $($rows.Count) item(s) healthy; worst RPO $(($rows | Measure-Object RpoSeconds -Maximum).Maximum) s."
