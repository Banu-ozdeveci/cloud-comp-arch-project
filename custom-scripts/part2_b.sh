#!/bin/bash
set -euo pipefail

OUT_DIR="part2_b_results"
mkdir -p "$OUT_DIR"

LOG_FILE="$OUT_DIR/automation.log"
exec > >(tee -a "$LOG_FILE") 2>&1

WORKLOADS=("barnes" "blackscholes" "canneal" "freqmine" "radix" "streamcluster" "vips")
THREADS=(1 2 4 8)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

cleanup_job() {
  local job_name=$1

  log "Cleaning old job/pods for $job_name..."
  kubectl delete job "$job_name" --ignore-not-found=true || true

  # Wait until old pods of this job are gone
  while kubectl get pods --selector=job-name="$job_name" --no-headers 2>/dev/null | grep -q .; do
    log "Waiting for old pods of $job_name to terminate..."
    sleep 5
  done
}

run_experiment() {
  local workload=$1
  local threads=$2
  local original_yaml="parsec-benchmarks/part2b/parsec-${workload}.yaml"
  local temp_yaml="/tmp/parsec-${workload}-${threads}.yaml"
  local output_file="$OUT_DIR/${workload}_${threads}threads.txt"
  local job_name="parsec-${workload}"

  log "========================================"
  log "Starting experiment: $workload with $threads thread(s)"
  log "========================================"

  cleanup_job "$job_name"

  log "Creating temporary YAML with -n $threads"
  sed -E "s/-n [0-9]+/-n ${threads}/g" "$original_yaml" > "$temp_yaml"

  log "Launching job: $job_name"
  kubectl create -f "$temp_yaml"

  log "Waiting for $job_name to complete..."
  if kubectl wait --for=condition=complete "job/$job_name" --timeout=7200s; then
    log "$job_name completed successfully."
  else
    log "ERROR: $job_name failed or timed out."
    kubectl describe job "$job_name" || true
    kubectl get pods -o wide || true
    exit 1
  fi

  local pod_name
  pod_name=$(kubectl get pods --selector=job-name="$job_name" \
    --output=jsonpath='{.items[0].metadata.name}')

  log "Saving output to $output_file"
  kubectl logs "$pod_name" > "$output_file"

  cleanup_job "$job_name"

  log "Finished experiment: $workload with $threads thread(s)"
  sleep 5
}

for workload in "${WORKLOADS[@]}"; do
  for threads in "${THREADS[@]}"; do
    run_experiment "$workload" "$threads"
  done
done

log "All Part 2b experiments completed."