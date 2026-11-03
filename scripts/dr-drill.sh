#!/usr/bin/env bash
# DR drill using only the Azure CLI (az rest -> ASR REST API). No Az PowerShell needed.
# Works in Git Bash, Linux, macOS, Cloud Shell. Reads names from `terraform output`.
#
#   scripts/dr-drill.sh health    # replication health / RPO per VM
#   scripts/dr-drill.sh drill     # TEST failover into isolated VNet + RTO measurement + report
#   scripts/dr-drill.sh cleanup   # delete the test-failover VMs
set -euo pipefail
export MSYS_NO_PATHCONV=1   # stop Git Bash from rewriting /subscriptions/... into C:/...

cd "$(dirname "$0")/.."
tf() { terraform -chdir=terraform output -raw "$1"; }

API=2024-04-01
SUB=$(az account show --query id -o tsv | tr -d '\r')
RG=$(tf dr_resource_group)
VAULT=$(tf recovery_vault_name)
PLAN=$(tf recovery_plan_name)
TEST_VNET=$(tf test_network_id)
HEALTH_URL=${HEALTH_URL:-$(terraform -chdir=terraform output -json endpoints | tr -d ' \n\r' \
  | sed -n 's/.*"web":{[^}]*"drtest":"\([^"]*\)".*/\1/p')}
EXPECTED_REGION=${EXPECTED_REGION:-westus2}
RTO_TARGET_MIN=${RTO_TARGET_MIN:-60}
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.RecoveryServices/vaults/$VAULT"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

health() {
  az rest --method get --url "$BASE/replicationProtectedItems?api-version=$API" \
    --query "value[].{vm:properties.friendlyName, health:properties.replicationHealth, state:properties.protectionStateDescription, rpoSec:properties.providerSpecificDetails.rpoInSeconds, lastTestFailover:properties.lastSuccessfulTestFailoverTime}" -o table
}

latest_job_state() { # $1 = exact ASR scenario name, prints the newest job's state
  # tr: az on Windows can emit CRLF; a trailing \r made "Succeeded" never match.
  az rest --method get --url "$BASE/replicationJobs?api-version=$API" \
    --query "sort_by(value[?properties.scenarioName=='$1'], &properties.startTime)[-1].properties.state" -o tsv \
    | tr -d '\r[:space:]'
}

wait_job() { # $1 = exact ASR scenario name
  local state
  while true; do
    sleep 30
    state=$(latest_job_state "$1")
    log "job $1: ${state:-<not found yet>}"
    case "$state" in
      Succeeded) return 0 ;;
      Failed|Cancelled) return 1 ;;
      Suspended) log "Waiting on a MANUAL ACTION in the recovery plan - resume it in the portal." ;;
    esac
  done
}

drill() {
  log "Pre-flight: replication health"
  health
  local bad
  bad=$(az rest --method get --url "$BASE/replicationProtectedItems?api-version=$API" \
        --query "length(value[?properties.replicationHealth!='Normal'])" -o tsv | tr -d '\r')
  [ "$bad" = "0" ] || { log "ABORT: $bad item(s) not Normal"; exit 1; }
  local rpo
  rpo=$(az rest --method get --url "$BASE/replicationProtectedItems?api-version=$API" \
        --query "max(value[].properties.providerSpecificDetails.rpoInSeconds)" -o tsv | tr -d '\r')

  local start; start=$(date -u +%s)
  log "Starting TEST failover of $PLAN into $(basename "$TEST_VNET") (production untouched)"
  az rest --method post --url "$BASE/replicationRecoveryPlans/$PLAN/testFailover?api-version=$API" --body "{
    \"properties\": {
      \"failoverDirection\": \"PrimaryToRecovery\",
      \"networkType\": \"VmNetworkAsInput\",
      \"networkId\": \"$TEST_VNET\",
      \"providerSpecificDetails\": [{ \"instanceType\": \"A2A\", \"recoveryPointType\": \"LatestProcessed\", \"multiVmSyncPointOption\": \"UseMultiVmSyncRecoveryPoint\" }]
    }}" >/dev/null

  local result=PASS
  wait_job "TestFailover" || result=FAIL
  local job_done; job_done=$(date -u +%s)

  local app_ok="" region="n/a"
  if [ "$result" = PASS ] && [ -n "$HEALTH_URL" ]; then
    log "Polling $HEALTH_URL for region=$EXPECTED_REGION"
    for _ in $(seq 1 90); do
      body=$(curl -s --max-time 5 "$HEALTH_URL" || true)
      region=$(printf '%s' "$body" | sed -n 's/.*"region":"\([^"]*\)".*/\1/p')
      if [ "$region" = "$EXPECTED_REGION" ]; then app_ok=$(date -u +%s); log "App healthy: $body"; break; fi
      sleep 10
    done
    [ -n "$app_ok" ] || { result=FAIL; log "App never reported $EXPECTED_REGION"; }
  fi

  local end=${app_ok:-$job_done}
  local rto; rto=$(awk "BEGIN{printf \"%.1f\", ($end-$start)/60}")
  awk "BEGIN{exit !($rto > $RTO_TARGET_MIN)}" && result=FAIL

  mkdir -p evidence/drills
  local stamp; stamp=$(date -u -d "@$start" +%Y%m%d-%H%M%S 2>/dev/null || date -u +%Y%m%d-%H%M%S)
  local report="evidence/drills/drill-$stamp.md"
  {
    echo "# DR drill report - $stamp UTC"
    echo
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Recovery plan | $PLAN |"
    echo "| Type | Test failover (isolated VNet), recovery point LatestProcessed, multi-VM sync |"
    echo "| Started (UTC) | $(date -u -d "@$start" '+%F %T' 2>/dev/null || echo "$start") |"
    echo "| ASR job finished after | $(awk "BEGIN{printf \"%.1f\", ($job_done-$start)/60}") min |"
    echo "| Observed region | $region |"
    echo "| **Achieved RTO** | **$rto min** (target $RTO_TARGET_MIN min) |"
    echo "| Worst replica RPO at start | ${rpo} s |"
    echo "| Result | **$result** |"
  } > "$report"
  cat "$report"
  log "Report written: $report"
  log "Test VMs are still running so you can screenshot $HEALTH_URL. Then run: scripts/dr-drill.sh cleanup"
  [ "$result" = PASS ]
}

cleanup() {
  log "Cleaning up test failover"
  az rest --method post --url "$BASE/replicationRecoveryPlans/$PLAN/testFailoverCleanup?api-version=$API" \
    --body '{"properties":{"comments":"DR drill complete"}}' >/dev/null
  wait_job "TestFailoverCleanup"
  log "Cleanup done"
}

case "${1:-}" in
  health)  health ;;
  drill)   drill ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 {health|drill|cleanup}"; exit 2 ;;
esac
