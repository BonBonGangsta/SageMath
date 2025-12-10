#!/usr/bin/env bash
set -euo pipefail

CSV_FILE="${1:-jobs.csv}"
SCRIPT="./run_sage_and_notify.sh"

tail -n +2 "$CSV_FILE" | while IFS=, read -r ID KNOT SCRIPT_PATH; do
    [[ -z "$ID" || -z "$KNOT" || -z "$SCRIPT_PATH" ]] && continue
    name="${KNOT}_${ID}"
    out="${name}.out"
    echo "Starting $name..."
    nohup "$SCRIPT" "$name" "$SCRIPT_PATH" >"$out" 2>&1 &
done