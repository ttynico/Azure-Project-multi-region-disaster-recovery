# Evidence

Screenshots and drill reports that prove the deployment ran. Capture them before `terraform destroy`.

## Screenshot checklist

Save the files in `evidence/screenshots/` with these names:

1. `01-terraform-apply.png`: apply complete with the outputs
2. `02-rg-primary.png` / `03-rg-dr.png`: both resource groups and their resources
3. `04-replicated-items-healthy.png`: Vault → Replicated items, both VMs **Protected / Healthy**
4. `05-replication-rpo.png`: a VM's replication overview showing the current RPO
5. `06-infra-view.png`: Replicated item → Infrastructure view (East US → West US 2)
6. `07-recovery-plan.png`: Recovery plan customize view with groups, order, and manual actions
7. `08-primary-health-json.png`: browser showing `/health.json` with `"region":"eastus"`
8. `09-test-failover-job.png`: completed Test Failover job with all steps green
9. `10-drtest-health-json.png`: browser showing `/health.json` with `"region":"westus2"` from the test-failover VM
10. `11-drill-report.png`: terminal output of `Start-DrDrill.ps1` (RTO / RPO / PASS)
11. `12-cleanup-job.png`: test failover cleanup succeeded
12. `13-log-analytics.png`: KQL on `AzureSiteRecoveryJobs` / `AzureSiteRecoveryReplicatedItems`
13. `14-terraform-destroy.png`: destroy complete

## Useful KQL (Log Analytics → Logs)

```kusto
AzureSiteRecoveryReplicatedItems
| summarize arg_max(TimeGenerated, *) by Name
| project Name, ReplicationHealth, ProtectionState, RpoInSeconds, PrimaryFabricName, RecoveryFabricName

AzureSiteRecoveryJobs
| where TimeGenerated > ago(1d)
| project TimeGenerated, OperationName, Status, DurationMs, AffectedResourceName
| order by TimeGenerated desc
```
