#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

tests=(
    tests/test_v12_bounded_search.sh
    tests/test_v12_stage1.sh
    tests/test_v12_stage2a.sh
    tests/test_v12_stage2b.sh
    tests/test_v12_stage3.sh
    tests/test_v12_stage4a.sh
    tests/test_v12_stage4b.sh
    tests/test_v12_stage5a.sh
    tests/test_v12_stage5b.sh
    tests/test_v12_stage5c.sh
    tests/test_v12_stage6a.sh
    tests/test_v12_stage6b.sh
    tests/test_v12_stage7.sh
    tests/test_v12_stage8.sh
)

cd "${PROJECT_DIR}"
for test_script in "${tests[@]}"; do
    echo "RUN: ${test_script}"
    bash "${test_script}"
done

echo "All v12 regression suites passed (${#tests[@]} suites)."
