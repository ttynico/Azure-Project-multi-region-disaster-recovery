# Shared helpers dot-sourced by the DR scripts. Assumes the ASR vault context is already set.

function Write-Step([string] $Message) {
    Write-Host ("[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss'), $Message) -ForegroundColor Green
}

function Wait-AsrJob {
    param(
        [Parameter(Mandatory)] $Job,
        [int] $TimeoutMinutes = 90,
        [int] $PollSeconds = 30
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds $PollSeconds
        $Job = Get-AzRecoveryServicesAsrJob -Job $Job
        $current = ($Job.Tasks | Where-Object { $_.State -eq 'InProgress' } | Select-Object -First 1).Name
        Write-Host ("    job {0}: {1}{2}" -f $Job.Name, $Job.State, $(if ($current) { " - $current" } else { '' }))
        if ($Job.State -eq 'Suspended') {
            Write-Warning 'Job is waiting on a MANUAL ACTION from the recovery plan. Complete it, then run Resume-AzRecoveryServicesAsrJob or resume in the portal.'
        }
        if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutMinutes min waiting for job $($Job.Name)" }
    } while ($Job.State -in @('NotStarted', 'InProgress', 'Suspended'))
    return $Job
}

function Get-ReplicationHealth {
    <# Returns one row per replicated item across all protection containers in the vault. #>
    $rows = foreach ($fabric in Get-AzRecoveryServicesAsrFabric) {
        foreach ($pc in Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric) {
            foreach ($item in Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $pc) {
                [pscustomobject]@{
                    Name              = $item.FriendlyName
                    SourceFabric      = $fabric.FriendlyName
                    ProtectionState   = $item.ProtectionState
                    ReplicationHealth = $item.ReplicationHealth
                    RpoSeconds        = $item.ProviderSpecificDetails.RpoInSeconds
                    LastRpoCalculated = $item.ProviderSpecificDetails.LastRpoCalculatedTime
                    ActiveLocation    = $item.ActiveLocation
                    AllowedOperations = ($item.AllowedOperations -join ',')
                }
            }
        }
    }
    return $rows
}
