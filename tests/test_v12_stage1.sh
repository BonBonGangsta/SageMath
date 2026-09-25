#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}
V12_SCRIPT="${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage"
TEST_DATA_DIR="${PROJECT_DIR}/tests/data"

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-tests-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT
TEMP_V12_SCRIPT="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
cp "${V12_SCRIPT}" "${TEMP_V12_SCRIPT}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEST_OUTPUT_DIR}/"

run_case() {
    local name=$1
    local facets_file=$2
    local expected_result=$3
    local protected_vertices=${4:-}
    local protected_policy=${5:-prefer}
    local log_file="${TEST_OUTPUT_DIR}/${name}.log"

    FACETS_FILE="${facets_file}" \
    KNOT_NAME="${name}" \
    RANDOM_SEED=123456 \
    CSV_OUTPUT="${TEST_OUTPUT_DIR}/${name}.csv" \
    PROTECTED_VERTICES="${protected_vertices}" \
    PROTECTED_VERTEX_POLICY="${protected_policy}" \
    STATE_ENGINE=bitset \
    NORMALIZED_COMPLEX_CACHE=true \
    NORMALIZED_CACHE_MAX_FAILURES=100000 \
    SEARCH_STATE_LIMIT=0 \
    SEARCH_TIME_LIMIT_SECONDS=0 \
    "${SAGE_BIN}" "${TEMP_V12_SCRIPT}" >"${log_file}" 2>&1

    if ! grep -Fq "FINAL_RESULT: ${expected_result};" "${log_file}"; then
        echo "FAIL: ${name}; expected ${expected_result}" >&2
        tail -n 30 "${log_file}" >&2
        return 1
    fi
    echo "PASS: ${name} -> ${expected_result}"
}

run_case \
    "simplex" \
    "${TEST_DATA_DIR}/simplex.txt" \
    "NON_EVASIVE"

run_case \
    "cycle" \
    "${TEST_DATA_DIR}/cycle.txt" \
    "EVASIVE_CERTIFIED"

run_case \
    "protected_preference" \
    "${TEST_DATA_DIR}/protected_policy_example.txt" \
    "NON_EVASIVE" \
    "[1, 2, 3]" \
    "prefer"

run_case \
    "protected_restriction" \
    "${TEST_DATA_DIR}/protected_policy_example.txt" \
    "INCONCLUSIVE_RESTRICTED" \
    "[1, 2, 3]" \
    "restrict"

echo "All Stage 1 v12 tests passed."
