<#
.SYNOPSIS
    REAL failover of the recovery plan (planned or unplanned), then commit.
    This moves production to the recovery region. Use Start-DrDrill.ps1 for drills.

.DESCRIPTION
    Planned   : primary region is healthy (maintenance, migration). Source VMs are
                shut down first, then a final sync => zero data loss.
    Unplanned : primary region is down. Fails over to the latest recovery point
                (data loss up to the current RPO).

    The recovery plan contains MANUAL ACTIONS (declaration gate, web validation).
    The job will pause at each; this script waits and tells you when to act.

    After commit, re-protect (DR region -> primary) from the portal or with
    Update-AzRecoveryServicesAsrProtectionDirection per item, then fail back with
    a planned failover in direction RecoveryToPrimary. See docs/DR-PLAN.md.

.EXAMPLE
    ./Invoke-Failover.ps1 -ResourceGroupName rg-drlab-dr-westus2 -VaultName rsv-drlab-dr-abcde `
        -RecoveryPlanName rp-drlab-eastus-to-westus2 -Type Unplanned
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $VaultName,
    [Parameter(Mandatory)] [string] $RecoveryPlanName,
    [Parameter(Mandatory)] [ValidateSet('Planned', 'Unplanned')] [string] $Type,
    [ValidateSet('PrimaryToRecovery', 'RecoveryToPrimary')] [string] $Direction = 'PrimaryToRecovery',
    [switch] $NoCommit
)

$ErrorActionPreference = 'Stop'
Import-Module Az.RecoveryServices -ErrorAction Stop
. (Join-Path $PSScriptRoot 'AsrHelpers.ps1')

$vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName
Set-AzRecoveryServicesAsrVaultContext -Vault $vault | Out-Null
$plan = Get-AzRecoveryServicesAsrRecoveryPlan -Name $RecoveryPlanName

if (-not $PSCmdlet.ShouldProcess($RecoveryPlanName, "$Type failover ($Direction) - THIS MOVES PRODUCTION")) { return }

$start = Get-Date
Write-Step "Starting $Type failover ($Direction). RTO clock started."
$job = if ($Type -eq 'Planned') {
    Start-AzRecoveryServicesAsrPlannedFailoverJob -RecoveryPlan $plan -Direction $Direction
} else {
    Start-AzRecoveryServicesAsrUnplannedFailoverJob -RecoveryPlan $plan -Direction $Direction
}
$job = Wait-AsrJob -Job $job -TimeoutMinutes 180
if ($job.State -ne 'Succeeded') { throw "Failover job ended in state '$($job.State)' ($($job.Name))." }
Write-Step ("Failover complete in {0:N1} min." -f ((Get-Date) - $start).TotalMinutes)

if ($NoCommit) {
    Write-Warning 'Not committing. You can still change recovery point. Commit when validated:'
    Write-Host "  Start-AzRecoveryServicesAsrCommitFailoverJob -RecoveryPlan (Get-AzRecoveryServicesAsrRecoveryPlan -Name $RecoveryPlanName)"
    return
}

Write-Step 'Committing failover'
$commit = Wait-AsrJob -Job (Start-AzRecoveryServicesAsrCommitFailoverJob -RecoveryPlan $plan) -TimeoutMinutes 30
Write-Step "Commit: $($commit.State). Next: re-protect in the reverse direction (docs/DR-PLAN.md section 6)."
