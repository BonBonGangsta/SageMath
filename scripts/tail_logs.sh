#!/usr/bin/env bash
find "${1:-.}" -maxdepth 1 -type f \( -name "*.log" -o -name "*.out" \) -print0 |
while IFS= read -r -d '' file; do
  echo "=============================="
  echo "File: $file"
  echo "=============================="
  tail -n 10 "$file"
  echo
done
