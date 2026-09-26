#!/usr/bin/env bash
set -euo pipefail

CSV_FILE="${1:-jobs.csv}"
SCRIPT="${BATCH_RUNNER_SCRIPT:-./run_sage_and_notify.sh}"

# Expected CSV columns (with header row):
# ID,KNOT,SCRIPT_PATH,FACET_FILE,RANDOM_SEED
#
# - FACET_FILE is optional; leave blank to skip passing one.
# - RANDOM_SEED is optional. When absent, a stable seed is derived from the
#   job name so a later checkpoint resume uses the same search order.
tail -n +2 "$CSV_FILE" | while IFS=, read -r ID KNOT SCRIPT_PATH FACET_FILE JOB_SEED; do
    [[ -z "$ID" || -z "$KNOT" || -z "$SCRIPT_PATH" ]] && continue
    name="${KNOT}_${ID}"
    out="${name}.out"
    checkpoint_path="outputs/${name}_checkpoint.json"
    checkpoint_resume=false
    if [[ -f "$checkpoint_path" ]]; then
        checkpoint_resume=true
    fi
    if [[ -z "${JOB_SEED:-}" ]]; then
        read -r JOB_SEED _ < <(printf '%s' "$name" | cksum)
    fi
    echo "Starting $name (seed=$JOB_SEED, resume=$checkpoint_resume)..."
    if [[ -n "$FACET_FILE" ]]; then
        RANDOM_SEED="$JOB_SEED" \
        HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-86400}" \
        CHECKPOINT_PATH="$checkpoint_path" \
        CHECKPOINT_RESUME="$checkpoint_resume" \
        CHECKPOINT_OVERWRITE=false \
        CHECKPOINT_INTERVAL_STATES="${CHECKPOINT_INTERVAL_STATES:-0}" \
        CHECKPOINT_INTERVAL_SECONDS="${CHECKPOINT_INTERVAL_SECONDS:-1800}" \
        SEARCH_STATE_LIMIT="${SEARCH_STATE_LIMIT:-0}" \
        SEARCH_TIME_LIMIT_SECONDS="${SEARCH_TIME_LIMIT_SECONDS:-0}" \
        SEARCH_MEMORY_LIMIT_MIB="${SEARCH_MEMORY_LIMIT_MIB:-18432}" \
        nohup "$SCRIPT" "$name" "$SCRIPT_PATH" "$FACET_FILE" >"$out" 2>&1 &
    else
        RANDOM_SEED="$JOB_SEED" \
        HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-86400}" \
        CHECKPOINT_PATH="$checkpoint_path" \
        CHECKPOINT_RESUME="$checkpoint_resume" \
        CHECKPOINT_OVERWRITE=false \
        CHECKPOINT_INTERVAL_STATES="${CHECKPOINT_INTERVAL_STATES:-0}" \
        CHECKPOINT_INTERVAL_SECONDS="${CHECKPOINT_INTERVAL_SECONDS:-1800}" \
        SEARCH_STATE_LIMIT="${SEARCH_STATE_LIMIT:-0}" \
        SEARCH_TIME_LIMIT_SECONDS="${SEARCH_TIME_LIMIT_SECONDS:-0}" \
        SEARCH_MEMORY_LIMIT_MIB="${SEARCH_MEMORY_LIMIT_MIB:-18432}" \
        nohup "$SCRIPT" "$name" "$SCRIPT_PATH" >"$out" 2>&1 &
    fi
done
