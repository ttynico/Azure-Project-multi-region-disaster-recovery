# Azure Multi-Region Disaster Recovery with Azure Site Recovery

> Project 8 (Advanced Azure) from [AWS-GCP-Azure-Cloud-Projects-Workshop](https://github.com/NotHarshhaa/AWS-GCP-Azure-Cloud-Projects-Workshop#project-8-designing-a-multi-region-disaster-recovery-plan), built end-to-end as Infrastructure as Code.

This project protects a two-tier Linux workload in **East US**. **Azure Site Recovery (ASR)** replicates it continuously to **West US 2**. An ordered **recovery plan** fails the whole workload over with one action. **Scripted DR drills** run test failovers in an isolated network and measure the RTO and RPO actually achieved.

| | |
|---|---|
| **Objective** | Replicate VMs, configure cross-region failover, and build a recovery plan that keeps downtime low |
| **Stack** | Terraform (azurerm 5.x), Azure Site Recovery, Recovery Services vault, VNets/NSGs, Log Analytics, PowerShell (Az.RecoveryServices), GitHub Actions (OIDC) |
| **Targets** | RPO ≤ 15 min · RTO ≤ 60 min (see [DR plan](docs/DR-PLAN.md)) |
| **Skills** | DR planning, multi-region architecture, ASR, IaC, DR-as-code testing, least-privilege network design |

---

## Architecture

```mermaid
flowchart LR
  subgraph P["Primary region: East US (rg-drlab-primary-eastus)"]
    direction TB
    PV["vnet-drlab-primary 10.10.0.0/16<br/>snet-workload 10.10.1.0/24<br/>NSG: 22/80 from admin /32 only"]
    APP1["vm-app-01<br/>10.10.1.10"]
    WEB1["vm-web-01<br/>10.10.1.20"]
    CACHE[("ASR cache<br/>storage account")]
    APP1 --- PV
    WEB1 --- PV
    APP1 -. disk writes .-> CACHE
    WEB1 -. disk writes .-> CACHE
  end

  subgraph S["Recovery region: West US 2 (rg-drlab-dr-westus2)"]
    direction TB
    RSV["Recovery Services vault<br/>fabrics · containers · policy<br/>recovery plan"]
    REP[("Replica managed disks")]
    DV["vnet-drlab-dr 10.20.0.0/16<br/>(real failover target)"]
    TV["vnet-drlab-drtest 10.30.0.0/16<br/>(isolated, drills only)"]
    LAW["Log Analytics<br/>ASR diagnostics"]
    RSV --> LAW
  end

  CACHE == "continuous replication" ==> REP
  PV <-. "network mapping (both directions)" .-> DV
  REP -- "failover / planned / unplanned" --> DV
  REP -- "test failover" --> TV
```

**Recovery plan order** (`rp-drlab-eastus-to-westus2`):

```mermaid
flowchart LR
  A["Failover group<br/>⏸ Manual: IC confirms DR declaration<br/>(real failovers only)"] --> B["Boot group 1<br/>vm-app-01"] --> C["Boot group 2<br/>vm-web-01"] --> D["⏸ Manual: validate /health.json<br/>update DNS"]
```

### Design decisions

| Decision | Why |
|---|---|
| Vault, logs, and DR network live in the **recovery** region | If East US is down, the control plane you need to fail over is not down with it. |
| **Isolated test VNet** (`10.30.0.0/16`, no peering) | Drills never collide with production IPs or DNS. You can test monthly without a change window. |
| **Non-overlapping** address spaces + **static IPs per VM per environment** | Predictable addressing after failover. The DR VNet can later be peered to a hub without re-IPing. |
| **Reverse container + network mappings created upfront** | Re-protect and failback don't require building infrastructure mid-incident. |
| **Multi-VM consistency group** | The app and web tiers recover to the *same* point in time. |
| **Pre-staged Standard public IPs** in DR and test | No manual IP work in the recovery path. Standard SKU is closed by default, and NSGs allow only the admin /32. |
| Manual actions gate **real** failovers only | A human declares a disaster. Drills stay fully automated. |
| Status page rebuilt from **IMDS on every boot** | `/health.json` reports the region the VM is actually running in, which proves the failover. |

---

## Repository layout

```
terraform/
  versions.tf          provider pins, features (teardown-friendly for ASR)
  variables.tf         inputs with validation (no 0.0.0.0/0 allowed)
  locals.tf            VM map, CIDRs, tags
  network.tf           RGs, 3 VNets, NSGs, public IPs
  compute.tf           2x Ubuntu 22.04 VMs (app, web) + cloud-init
  site-recovery.tf     vault, cache SA, fabrics, containers, policy, mappings, replicated VMs
  recovery-plan.tf     ordered recovery plan with manual gates
  monitoring.tf        Log Analytics + vault diagnostic settings
  outputs.tf           endpoints + ready-to-run drill command
  cloud-init/status-page.yaml
scripts/
  Start-DrDrill.ps1          test failover -> measure RTO -> evidence -> cleanup
  Invoke-Failover.ps1        real planned/unplanned failover + commit
  Get-ReplicationHealth.ps1  health/RPO check (non-zero exit on breach)
  AsrHelpers.ps1
docs/
  DR-PLAN.md                 the DR plan: scope, RTO/RPO, roles, runbooks, failback
evidence/                    screenshots + drill reports
.github/workflows/
  terraform-ci.yml           fmt, validate, tflint, Checkov
  dr-drill.yml               on-demand/scheduled test failover via OIDC
```

---

## Deploy

**Prerequisites:** Azure subscription with Owner/Contributor rights, Terraform ≥ 1.9, Azure CLI, PowerShell 7 with `Az.Accounts` and `Az.RecoveryServices`.

```bash
az login
az account set --subscription <SUBSCRIPTION_ID>
az provider register --namespace Microsoft.RecoveryServices --wait

cd terraform
cp terraform.tfvars.example terraform.tfvars   # set subscription_id, allowed_source_cidr, admin_ssh_public_key
terraform init
terraform plan -out tfplan
terraform apply tfplan                           # ~45-90 min: initial replication is the long pole
```

Check that replication is healthy before you drill:

```powershell
Connect-AzAccount
./scripts/Get-ReplicationHealth.ps1 -ResourceGroupName <dr_resource_group> -VaultName <recovery_vault_name>
```

## Run a DR drill (non-disruptive)

```bash
terraform output -raw drill_command   # copy, then run in pwsh
```

The drill:
1. Aborts if any VM isn't Healthy/Protected.
2. Starts a **test failover** of the recovery plan into `vnet-drlab-drtest`. Production keeps running.
3. Waits for the ASR job, then polls the recovered web VM's `/health.json` until it reports `westus2`.
4. Writes a report with achieved **RTO**, **RPO**, and PASS/FAIL to `evidence/drills/drill-<timestamp>.md`.
5. Cleans up the test VMs (`-SkipCleanup` keeps them so you can inspect them).

You can also run it from GitHub: **Actions → dr-drill → Run workflow**. The workflow uses OIDC, so there are no stored secrets.

## Real failover / failback

See [docs/DR-PLAN.md](docs/DR-PLAN.md) sections 5–6. Summary:

```powershell
./scripts/Invoke-Failover.ps1 -ResourceGroupName <rg> -VaultName <vault> -RecoveryPlanName <plan> -Type Unplanned
# then re-protect (West US 2 -> East US) and fail back with -Type Planned -Direction RecoveryToPrimary
```

## Teardown

Delete ASR test or failover artifacts first (run a drill cleanup or commit), then:

```bash
terraform destroy
```

`prevent_deletion_if_contains_resources = false` and `purge_protected_items_from_vault_on_destroy = true` let destroy remove the ASR-created replica disks and the vault. Afterwards, confirm in the portal that both resource groups are gone.

---

## Results

> Fill this in from your own deployment. The screenshots and the drill report are the proof that it ran.

| Metric | Target | Achieved |
|---|---|---|
| Initial replication time (per VM) | n/a | _TBD_ |
| Steady-state RPO | ≤ 15 min | _TBD_ |
| Test failover RTO (job complete) | ≤ 60 min | _TBD_ |
| Test failover RTO (app healthy in DR) | ≤ 60 min | _TBD_ |

See [evidence/README.md](evidence/README.md) for the screenshot checklist.

## Troubleshooting

### Known pitfalls (checked against docs before deployment)

| Symptom | Cause | Fix |
|---|---|---|
| Enable replication fails with Mobility Service / connectivity error (e.g. 151037 / 151196) | VM can't reach ASR endpoints outbound | Default NSG outbound allows this. If you lock outbound down, allow service tags `AzureSiteRecovery`, `Storage.<source region>`, `AzureActiveDirectory`, `EventHub`, `GuestAndHybridManagement`. |
| Replication stuck at 0% / "waiting for first recovery point" | Initial sync is still running | Normal for 30–60+ min. Check with `Get-ReplicationHealth.ps1`. Don't destroy mid-sync. |
| `terraform destroy` fails on the DR resource group | ASR-created disks/NICs not in state | Already handled by the provider `features` block. If test failover VMs exist, run cleanup first. |
| Test failover VM isn't reachable on its public IP | NSG allows only `allowed_source_cidr`, or your IP changed | Update `allowed_source_cidr` and `terraform apply`. |
| `/health.json` still says `eastus` after failover | Status service didn't run at boot | Check with the serial console (boot diagnostics are enabled): `systemctl status dr-status-page`. |
| Multi-VM consistency warnings | Port 20004 blocked between group members | Intra-VNet traffic is allowed by default NSG rules. Make sure no host firewall blocks 20004. |

### Issues hit during my deployment

> Record real issues here as you hit them: symptom → root cause → fix. This is the most valuable part of the write-up.

---

## Production hardening roadmap

- Customer-managed keys (CMK) on the vault and on replica disks (`target_disk_encryption_set_id`)
- Private endpoints for the vault and the cache storage account, and outbound NSG rules restricted to ASR service tags
- Azure Front Door / Traffic Manager health-probe routing so DNS cutover isn't a manual step
- Azure Automation runbooks as recovery-plan actions (DNS update, app config swap)
- Zone-to-zone ASR within the primary region for cheaper protection against zonal failures
- Azure Policy to enforce "every prod VM tagged `dr_protected=true` must have replication enabled"

## Cost

ASR is billed per protected instance (Azure has historically included the first 31 days free per instance, so check current pricing). You also pay for replica disks, cache storage, 2× B2s VMs, public IPs, and Log Analytics ingestion. **Tear down after you collect evidence.**

## License

MIT. See [LICENSE](LICENSE).
