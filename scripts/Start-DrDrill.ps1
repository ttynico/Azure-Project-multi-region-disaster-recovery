<#
.SYNOPSIS
    Runs a non-disruptive DR drill: ASR test failover of the recovery plan into an
    isolated VNet, measures achieved RTO, records evidence, then cleans up.

.DESCRIPTION
    1. Pre-flight: every protected item in the plan must be Healthy / Protected.
    2. Starts a TEST failover of the recovery plan (production keeps running).
    3. Waits for the ASR job, then (optionally) polls the recovered web VM's
       /health.json until it reports the recovery region.
    4. Writes a drill report to evidence/drills/.
    5. Runs test-failover cleanup (deletes the test VMs) unless -SkipCleanup.

.EXAMPLE
    # Easiest: copy the `drill_command` Terraform output.
    ./Start-DrDrill.ps1 -ResourceGroupName rg-drlab-dr-westus2 -VaultName rsv-drlab-dr-abcde `
        -RecoveryPlanName rp-drlab-eastus-to-westus2 -TestNetworkId <vnet id> `
        -HealthUrl http://20.1.2.3/health.json -ExpectedRegion westus2

.NOTES
    Requires: PowerShell 7+, Az.Accounts, Az.RecoveryServices. Run Connect-AzAccount first.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $VaultName,
    [Parameter(Mandatory)] [string] $RecoveryPlanName,
    [Parameter(Mandatory)] [string] $TestNetworkId,
    [string] $HealthUrl,
    [string] $ExpectedRegion,
    [int]    $RtoTargetMinutes = 60,
    [int]    $JobTimeoutMinutes = 90,
    [switch] $SkipCleanup,
    [string] $EvidenceDir = (Join-Path $PSScriptRoot '..' 'evidence' 'drills')
)

$ErrorActionPreference = 'Stop'
Import-Module Az.RecoveryServices -ErrorAction Stop
. (Join-Path $PSScriptRoot 'AsrHelpers.ps1')

Write-Step "Setting vault context: $VaultName"
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName
Set-AzRecoveryServicesAsrVaultContext -Vault $vault | Out-Null
$plan = Get-AzRecoveryServicesAsrRecoveryPlan -Name $RecoveryPlanName

# ---- 1. Pre-flight -----------------------------------------------------------
Write-Step 'Pre-flight: checking replication health'
$health = Get-ReplicationHealth
$health | Format-Table Name, ProtectionState, ReplicationHealth, RpoSeconds -AutoSize | Out-String | Write-Host
$unhealthy = $health | Where-Object { $_.ReplicationHealth -ne 'Normal' -or $_.ProtectionState -ne 'Protected' }
if ($unhealthy) {
    throw "Aborting drill: $($unhealthy.Count) item(s) not Healthy/Protected. Fix replication first (see README Troubleshooting)."
}
$worstRpo = ($health | Measure-Object RpoSeconds -Maximum).Maximum

# ---- 2. Test failover --------------------------------------------------------
$drillStart = Get-Date
Write-Step "Starting TEST failover of '$RecoveryPlanName' into isolated network"
$job = Start-AzRecoveryServicesAsrTestFailoverJob -RecoveryPlan $plan `
        -Direction PrimaryToRecovery -AzureVMNetworkId $TestNetworkId
$job = Wait-AsrJob -Job $job -TimeoutMinutes $JobTimeoutMinutes
$jobDone = Get-Date
if ($job.State -ne 'Succeeded') {
    throw "Test failover job ended in state '$($job.State)'. Check the job in the portal: $($job.Name)"
}

# ---- 3. Application-level validation -----------------------------------------
$appReady = $null
$observedRegion = $null
if ($HealthUrl) {
    Write-Step "Polling $HealthUrl until region = '$ExpectedRegion'"
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 5
            $observedRegion = $resp.region
            if (-not $ExpectedRegion -or $observedRegion -eq $ExpectedRegion) { $appReady = Get-Date; break }
        } catch { }
        Start-Sleep -Seconds 10
    }
    if (-not $appReady) { Write-Warning 'Application did not report healthy in the recovery region within 15 minutes.' }
}

$rtoEnd = if ($appReady) { $appReady } else { $jobDone }
$rto = [math]::Round(($rtoEnd - $drillStart).TotalMinutes, 1)
$result = if ($rto -le $RtoTargetMinutes -and ($appReady -or -not $HealthUrl)) { 'PASS' } else { 'FAIL' }

# ---- 4. Evidence -------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$stamp = $drillStart.ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$report = Join-Path $EvidenceDir "drill-$stamp.md"
@"
# DR drill report - $stamp UTC

| Field | Value |
|---|---|
| Recovery plan | $RecoveryPlanName |
| Type | Test failover (isolated VNet) |
| Started (UTC) | $($drillStart.ToUniversalTime().ToString('u')) |
| ASR job finished (UTC) | $($jobDone.ToUniversalTime().ToString('u')) |
| App healthy in DR (UTC) | $(if ($appReady) { $appReady.ToUniversalTime().ToString('u') } else { 'not measured' }) |
| Observed region | $(if ($observedRegion) { $observedRegion } else { 'n/a' }) |
| **Achieved RTO** | **$rto min** (target $RtoTargetMinutes min) |
| Worst replica RPO at start | $worstRpo s |
| Result | **$result** |
| ASR job ID | $($job.Name) |

## Protected items at start
$( ($health | ForEach-Object { "- $($_.Name): $($_.ProtectionState) / $($_.ReplicationHealth) / RPO $($_.RpoSeconds)s" }) -join "`n" )
"@ | Set-Content -Path $report -Encoding utf8
Write-Step "Drill report written: $report"
Write-Host "RTO: $rto min  |  RPO: $worstRpo s  |  Result: $result" -ForegroundColor Cyan

# ---- 5. Cleanup --------------------------------------------------------------
if ($SkipCleanup) {
    Write-Warning 'Skipping cleanup. Test VMs keep running (and billing) until you run cleanup:'
    Write-Host "  Start-AzRecoveryServicesAsrTestFailoverCleanupJob -RecoveryPlan (Get-AzRecoveryServicesAsrRecoveryPlan -Name $RecoveryPlanName) -Comment 'drill $stamp'"
} else {
    Write-Step 'Cleaning up test failover (deleting test VMs)'
    $cleanup = Start-AzRecoveryServicesAsrTestFailoverCleanupJob -RecoveryPlan $plan -Comment "Drill $stamp result=$result rto=${rto}m"
    $cleanup = Wait-AsrJob -Job $cleanup -TimeoutMinutes 30
    Write-Step "Cleanup job: $($cleanup.State)"
}

if ($result -ne 'PASS') { exit 1 }
