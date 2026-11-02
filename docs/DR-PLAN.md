# Disaster Recovery Plan: DR Lab Workload

| | |
|---|---|
| **Document owner** | Yves Tagne (Cloud Security / DevSecOps) |
| **Version** | 1.0 |
| **Review cadence** | Quarterly, and after every drill or real invocation |
| **Primary region** | East US (`eastus`) |
| **Recovery region** | West US 2 (`westus2`) |
| **Mechanism** | Azure Site Recovery (Azure-to-Azure), recovery plan `rp-drlab-eastus-to-westus2` |

---

## 1. Scope

| System | Tier | Protected by | Recovery order |
|---|---|---|---|
| `vm-app-01` | Application | ASR, multi-VM consistency group `mvg-drlab` | Boot group 1 |
| `vm-web-01` | Web / front end | ASR, multi-VM consistency group `mvg-drlab` | Boot group 2 |

**Out of scope:** PaaS data stores (they need their own geo-replication), identity (Entra ID is global), and DNS hosting.

## 2. Objectives

| Objective | Target | How it is met | How it is verified |
|---|---|---|---|
| **RPO**: max tolerable data loss | ≤ 15 min | ASR continuous replication; crash-consistent points every ~5 min; app-consistent every 4 h | `Get-ReplicationHealth.ps1` (RPO per VM); vault alerts |
| **RTO**: max tolerable downtime | ≤ 60 min | Pre-built recovery plan, pre-staged IPs/networks, ordered boot groups | Monthly test-failover drill (`Start-DrDrill.ps1`) |
| **Recovery point retention** | 24 h | Replication policy `policy-drlab-24h` | Terraform config |

## 3. Invocation criteria and decision authority

Declare a disaster and fail over when **any** of these is true and the restore ETA exceeds the RTO:

1. The Azure Service Health / status page reports a regional outage in East US affecting Compute, Storage, or Networking.
2. Both VMs have been unreachable from outside the region for more than 15 min and in-region remediation has failed.
3. The primary region is compromised in a way that makes it untrustworthy (e.g., confirmed destructive security incident). Pick a recovery point from **before** the compromise.

**Decision authority:** the Incident Commander (IC). The recovery plan's first step is a **manual gate** that records the declaration time. The RTO clock starts there.

## 4. Roles

| Role | Responsibility |
|---|---|
| Incident Commander | Declares the disaster, approves failover, owns comms |
| DR Operator | Runs the recovery plan, monitors jobs, completes manual actions |
| App Owner | Validates application health in the recovery region |
| Security | Confirms the recovery point is clean (for security-driven failovers) |

## 5. Runbook: failover to West US 2

### 5a. Pre-checks (≤ 5 min)
1. `Get-ReplicationHealth.ps1`: note each VM's RPO. This is your expected data loss.
2. Confirm the vault (in West US 2) is reachable. It is deliberately outside the failed region.

### 5b. Execute
| Situation | Command |
|---|---|
| Primary down (outage) | `Invoke-Failover.ps1 -Type Unplanned` |
| Primary healthy (maintenance/migration, zero data loss) | `Invoke-Failover.ps1 -Type Planned` |

Portal equivalent: Vault → Recovery Plans → `rp-drlab-…` → **Failover** → direction East US → West US 2 → recovery point **Latest processed (low RTO)**.

1. The job pauses at **Confirm-DR-Declaration**. The IC records the time and resumes.
2. Boot group 1 (`vm-app-01`) starts, then boot group 2 (`vm-web-01`).
3. The job pauses at **Validate-Web-Tier**. The App Owner opens `http://<web DR IP>/health.json`, confirms `"region":"westus2"`, and updates DNS / Traffic Manager. Then the operator resumes.
4. **Commit** the failover (the script does this automatically unless `-NoCommit` is set). After commit, you can no longer change the recovery point.

### 5c. Post-failover
- Record actual RTO = (app healthy) − (declaration time).
- Send the status update to stakeholders.

## 6. Re-protect and failback

1. **Re-protect** (start replication West US 2 → East US) once East US is healthy. In the portal: Replicated items → each VM → **Re-protect**. The reverse container and network mappings already exist (created by Terraform).
2. Wait for replication to show **Protected** and **Healthy**.
3. In a change window, run a **planned failover**: `Invoke-Failover.ps1 -Type Planned -Direction RecoveryToPrimary` (zero data loss).
4. Commit, then re-protect again East US → West US 2 to return to steady state.
5. Run `terraform plan`. The Terraform-managed replicated-VM resources will show drift after a full cycle, so reconcile by re-importing or re-applying.

## 7. Testing

| Test | Frequency | Method | Pass criteria |
|---|---|---|---|
| Replication health | Daily (scheduled) | `Get-ReplicationHealth.ps1` | All Normal/Protected, RPO ≤ 900 s |
| DR drill (test failover) | Monthly + after infra changes | `Start-DrDrill.ps1` or `dr-drill` workflow | Plan succeeds, web reports `westus2`, RTO ≤ 60 min |
| Full failover + failback | Annually | Sections 5–6 in a change window | RTO/RPO met, failback clean |

Drill reports are saved in `evidence/drills/`. Any FAIL creates an action item with an owner and a due date.

## 8. Communications template

> **[DR ACTIVATED]** DR Lab workload is failing over from East US to West US 2 due to `<reason>`. Declared at `<time UTC>` by `<IC>`. Expected restoration by `<declaration + 60 min>`. Expected data loss: up to `<RPO>` minutes. Next update in 30 minutes.

## 9. Drill log

| Date (UTC) | Type | RTO achieved | RPO at start | Result | Report | Follow-ups |
|---|---|---|---|---|---|---|
| | | | | | | |
