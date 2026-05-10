#!/usr/bin/env bash

PATTERN="${1:-sagemath}"
LINES="${2:-10}"

docker ps -a --filter "name=$PATTERN" --format "{{.Names}}" |
while read -r container; do
  echo "=============================="
  echo "Container: $container"
  echo "Status: $(docker inspect -f '{{.State.Status}}' "$container")"
  echo "=============================="
  docker logs --tail "$LINES" "$container" 2>&1
  echo
done
