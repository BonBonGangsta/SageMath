#!/usr/bin/env bash
set -euo pipefail

CSV_FILE="${1:-jobs.csv}"
SCRIPT="./run_sage_and_notify.sh"

# Expected CSV columns (with header row):
# ID,KNOT,SCRIPT_PATH,FACET_FILE
# - FACET_FILE is optional; leave blank to skip passing one.
tail -n +2 "$CSV_FILE" | while IFS=, read -r ID KNOT SCRIPT_PATH FACET_FILE; do
    [[ -z "$ID" || -z "$KNOT" || -z "$SCRIPT_PATH" ]] && continue
    name="${KNOT}_${ID}"
    out="${name}.out"
    echo "Starting $name..."
    if [[ -n "$FACET_FILE" ]]; then
        FACETS_FILE="$FACET_FILE" nohup "$SCRIPT" "$name" "$SCRIPT_PATH" >"$out" 2>&1 &
    else
        nohup "$SCRIPT" "$name" "$SCRIPT_PATH" 2>&1 &
    fi
done
