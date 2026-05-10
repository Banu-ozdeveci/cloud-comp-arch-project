#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

RUN_ID=${1:-1}

YAML_DIR="part_3a_yamls"
RESULT_DIR="part3_results/run_${RUN_ID}"

mkdir -p "$RESULT_DIR"

dump_debug_info() {
  ERROR_DIR="$RESULT_DIR/error"
  mkdir -p "$ERROR_DIR/pod_logs"

  echo "=== DEBUG INFO DUMP ===" | tee -a "$ERROR_DIR/debug_summary.txt"
  date | tee -a "$ERROR_DIR/debug_summary.txt"

  kubectl get nodes -o wide > "$ERROR_DIR/debug_nodes.txt" 2>&1 || true
  kubectl get pods -o wide > "$ERROR_DIR/debug_pods_wide.txt" 2>&1 || true
  kubectl get jobs -o wide > "$ERROR_DIR/debug_jobs_wide.txt" 2>&1 || true
  kubectl describe pods > "$ERROR_DIR/debug_describe_pods.txt" 2>&1 || true
  kubectl describe jobs > "$ERROR_DIR/debug_describe_jobs.txt" 2>&1 || true
  kubectl get events --sort-by=.metadata.creationTimestamp > "$ERROR_DIR/debug_events.txt" 2>&1 || true

  for pod in $(kubectl get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    kubectl logs "$pod" > "$ERROR_DIR/pod_logs/${pod}.log" 2>&1 || true
  done
}

on_error() {
  echo "ERROR: Script failed. Saving debug logs..."
  dump_debug_info
  echo "Debug files saved in $RESULT_DIR"
}

trap on_error ERR

wait_for_job_complete() {
  local job_name="$1"
  local timeout="${2:-1800s}"

  echo "Waiting for $job_name..."
  if ! kubectl wait --for=condition=complete "job/$job_name" --timeout="$timeout"; then
    echo "ERROR: $job_name did not complete within $timeout"
    dump_debug_info
    exit 1
  fi
}

start_job() {
  local job_name="$1"
  echo "Starting $job_name"
  kubectl create -f "$YAML_DIR/${job_name}.yaml"
  sleep 2
  kubectl get pods -o wide | tee -a "$RESULT_DIR/scheduler_trace.txt"
}

run_nodeb_lane() {
  echo "[node-b] starting blackscholes -> canneal" | tee -a "$RESULT_DIR/scheduler_trace.txt"

  start_job "parsec-blackscholes"
  wait_for_job_complete "parsec-blackscholes" "1800s"

  start_job "parsec-canneal"
  wait_for_job_complete "parsec-canneal" "3600s"

  echo "[node-b] completed blackscholes -> canneal" | tee -a "$RESULT_DIR/scheduler_trace.txt"
}

echo "=== Part 3 Policy Run ${RUN_ID} started ==="
date | tee "$RESULT_DIR/run_start.txt"

echo "Cleaning old jobs/pods/services..."
kubectl delete jobs --all --ignore-not-found=true
kubectl delete pod some-memcached --ignore-not-found=true
kubectl delete service some-memcached-11211 --ignore-not-found=true
sleep 5

echo "Saving initial cluster state..."
kubectl get nodes -o wide | tee "$RESULT_DIR/nodes_initial.txt"

echo "Starting memcached..."
kubectl create -f "$YAML_DIR/memcached.yaml"

echo "Waiting for memcached pod to be ready..."
if ! kubectl wait --for=condition=Ready pod/some-memcached --timeout=120s; then
  echo "ERROR: memcached did not become Ready"
  dump_debug_info
  exit 1
fi

echo "Exposing memcached..."
kubectl expose pod some-memcached \
  --name some-memcached-11211 \
  --type LoadBalancer \
  --port 11211 \
  --protocol TCP

sleep 30

kubectl get pods -o wide | tee "$RESULT_DIR/pods_initial.txt"
kubectl describe pod some-memcached > "$RESULT_DIR/memcached_describe.txt" 2>&1 || true

MEMCACHED_IP=$(kubectl get pod some-memcached -o jsonpath='{.status.podIP}')
echo "MEMCACHED_IP=$MEMCACHED_IP" | tee "$RESULT_DIR/memcached_ip.txt"

echo ""
echo "================================================="
echo "Start mcperf manually before continuing."
echo ""
echo "client-agent-a:"
echo "./mcperf -T 2 -A"
echo ""
echo "client-agent-b:"
echo "./mcperf -T 4 -A"
echo ""
echo "client-measure:"
echo "./mcperf -s $MEMCACHED_IP --loadonly"
echo "./mcperf -s $MEMCACHED_IP -a INTERNAL_AGENT_A_IP -a INTERNAL_AGENT_B_IP \\"
echo "  --noload -T 6 -C 4 -D 4 -Q 1000 -c 4 -t 10 \\"
echo "  --scan 30000:30500:5 | tee $RESULT_DIR/mcperf_${RUN_ID}.txt"
echo "================================================="
echo ""

read -p "Press ENTER after mcperf is running..."

echo "=== Scheduler started ===" | tee "$RESULT_DIR/scheduler_trace.txt"
date | tee -a "$RESULT_DIR/scheduler_trace.txt"

echo "Starting node-b lane in background..."
run_nodeb_lane &
NODEB_PID=$!

echo "Starting node-a slot scheduler..."

NEXT_JOBS=("parsec-barnes" "parsec-radix" "parsec-vips")
QUEUE_FILE="$RESULT_DIR/queue.txt"
printf "%s\n" "${NEXT_JOBS[@]}" > "$QUEUE_FILE"

get_next_job() {
  local next
  next=$(head -n 1 "$QUEUE_FILE" || true)

  if [ -z "$next" ]; then
    return 1
  fi

  tail -n +2 "$QUEUE_FILE" > "$QUEUE_FILE.tmp" || true
  mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"

  echo "$next"
}

run_slot() {
  local current_job="$1"
  local slot_name="$2"

  while true; do
    echo "[$slot_name] waiting for $current_job" | tee -a "$RESULT_DIR/scheduler_trace.txt"
    wait_for_job_complete "$current_job" "3600s"

    local next_job
    if ! next_job=$(get_next_job); then
      echo "[$slot_name] no more jobs" | tee -a "$RESULT_DIR/scheduler_trace.txt"
      break
    fi

    echo "[$slot_name] launching $next_job" | tee -a "$RESULT_DIR/scheduler_trace.txt"
    start_job "$next_job"
    current_job="$next_job"
  done
}

start_job "parsec-freqmine"
start_job "parsec-streamcluster"

run_slot "parsec-freqmine" "slot-a" &
SLOT_A_PID=$!

run_slot "parsec-streamcluster" "slot-b" &
SLOT_B_PID=$!

wait "$SLOT_A_PID"
wait "$SLOT_B_PID"
wait "$NODEB_PID"

echo "All batch jobs completed."

echo "Saving pod JSON..."
kubectl get pods -o json > "$RESULT_DIR/pods_${RUN_ID}.json"

echo "Computing job times..."
python3 get_time.py "$RESULT_DIR/pods_${RUN_ID}.json" | tee "$RESULT_DIR/times_${RUN_ID}.txt"

echo "Saving final status and logs..."
kubectl get pods -o wide | tee "$RESULT_DIR/pods_final.txt"
kubectl get jobs -o wide | tee "$RESULT_DIR/jobs_final.txt"
kubectl get events --sort-by=.metadata.creationTimestamp > "$RESULT_DIR/events_final.txt" 2>&1 || true
kubectl describe jobs > "$RESULT_DIR/jobs_describe_final.txt" 2>&1 || true
kubectl describe pods > "$RESULT_DIR/pods_describe_final.txt" 2>&1 || true

mkdir -p "$RESULT_DIR/pod_logs"
for pod in $(kubectl get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  kubectl logs "$pod" > "$RESULT_DIR/pod_logs/${pod}.log" 2>&1 || true
done

date | tee "$RESULT_DIR/run_end.txt"

echo "=== Run ${RUN_ID} completed ==="
echo "Results saved in $RESULT_DIR"