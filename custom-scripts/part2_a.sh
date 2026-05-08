#!/bin/bash
set -euo pipefail

OUT_DIR="part2a_results"
mkdir -p "$OUT_DIR"

LOG_FILE="$OUT_DIR/automation.log"
exec > >(tee -a "$LOG_FILE") 2>&1

WORKLOADS=("barnes" "blackscholes" "canneal" "freqmine" "radix" "streamcluster" "vips")
INTERFERENCES=("none" "cpu" "l1d" "l1i" "l2" "llc" "membw")

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

run_experiment() {
  local workload=$1
  local interference=$2
  local parsec_yaml="parsec-benchmarks/part2a/parsec-${workload}.yaml"
  local output_file="$OUT_DIR/${workload}_${interference}.txt"

  log "========================================"
  log "Starting experiment: $workload + $interference"
  log "========================================"

  if [ "$interference" != "none" ]; then
    log "Starting ibench-$interference..."
    kubectl delete pod "ibench-$interference" --ignore-not-found=true
    kubectl create -f "interference/ibench-${interference}.yaml"

    log "Waiting for ibench-$interference to be Ready..."
    kubectl wait --for=condition=Ready "pod/ibench-$interference" --timeout=180s
    log "ibench-$interference is Ready."
    sleep 10
  else
    log "Running baseline without interference."
  fi

  log "Starting PARSEC workload: $workload"
  kubectl create -f "$parsec_yaml"

  sleep 5

  job_name=$(kubectl get jobs --no-headers | awk '{print $1}' | grep "$workload" | head -n 1)

  if [ -z "$job_name" ]; then
    log "ERROR: Could not find PARSEC job for $workload"
    kubectl get jobs
    exit 1
  fi

  log "Detected job: $job_name"
  log "Waiting for $job_name to complete..."

  if kubectl wait --for=condition=complete "job/$job_name" --timeout=7200s; then
    log "$job_name completed successfully."
  else
    log "ERROR: $job_name failed or timed out."
    kubectl describe job "$job_name" || true
    exit 1
  fi

  pod_name=$(kubectl get pods --selector=job-name="$job_name" \
    --output=jsonpath='{.items[0].metadata.name}')

  log "Saving PARSEC output to $output_file"
  kubectl logs "$pod_name" > "$output_file"

  log "Deleting PARSEC job: $job_name"
  kubectl delete job "$job_name" --ignore-not-found=true

  if [ "$interference" != "none" ]; then
    log "Deleting ibench-$interference"
    kubectl delete pod "ibench-$interference" --ignore-not-found=true
  fi

  log "Finished experiment: $workload + $interference"
  sleep 10
}

for workload in "${WORKLOADS[@]}"; do
  for interference in "${INTERFERENCES[@]}"; do
    run_experiment "$workload" "$interference"
  done
done

log "All Part 2.1 experiments completed."