#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-bounded-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
FACETS="${PROJECT_DIR}/tests/data/protected_policy_example.txt"

run_limited_case() {
    local name=$1
    local state_limit=$2
    local time_limit=$3
    local expected_limit=$4
    local log_file="${TEST_OUTPUT_DIR}/${name}.log"
    local certificate="${TEST_OUTPUT_DIR}/${name}.json"

    FACETS_FILE="${FACETS}" \
    RANDOM_SEED=123456 \
    CERTIFICATE_OUTPUT="${certificate}" \
    STATE_ENGINE=bitset \
    SEARCH_STATE_LIMIT="${state_limit}" \
    SEARCH_TIME_LIMIT_SECONDS="${time_limit}" \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1

    grep -Fq \
        'FINAL_RESULT: INCONCLUSIVE_RESOURCE_LIMIT;' \
        "${log_file}"
    grep -Fq "resource_limit=${expected_limit};" "${log_file}"
    grep -Fq \
        'Certificate: not emitted for INCONCLUSIVE_RESOURCE_LIMIT' \
        "${log_file}"
    if [[ -e "${certificate}" ]]; then
        echo "FAIL: limited search emitted a certificate" >&2
        exit 1
    fi
}

run_limited_case state_limit 1 0 state_limit
grep -Fq 'Subcomplex cache misses: 1' "${TEST_OUTPUT_DIR}/state_limit.log"
grep -Fq 'Sage state materializations: 1' "${TEST_OUTPUT_DIR}/state_limit.log"

run_limited_case time_limit 0 0.000000001 time_limit_seconds
grep -Fq 'Subcomplex cache misses: 0' "${TEST_OUTPUT_DIR}/time_limit.log"
grep -Fq 'Sage state materializations: 0' "${TEST_OUTPUT_DIR}/time_limit.log"

for invalid_setting in state time; do
    log_file="${TEST_OUTPUT_DIR}/invalid_${invalid_setting}.log"
    state_limit=0
    time_limit=0
    expected_message=''
    if [[ "${invalid_setting}" == state ]]; then
        state_limit=-1
        expected_message='SEARCH_STATE_LIMIT cannot be negative'
    else
        time_limit=nan
        expected_message='SEARCH_TIME_LIMIT_SECONDS must be a finite nonnegative number'
    fi
    if FACETS_FILE="${FACETS}" \
        SEARCH_STATE_LIMIT="${state_limit}" \
        SEARCH_TIME_LIMIT_SECONDS="${time_limit}" \
        "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1; then
        echo "FAIL: invalid ${invalid_setting} limit was accepted" >&2
        exit 1
    fi
    grep -Fq "${expected_message}" "${log_file}"
done

BENCHMARK_OUTPUT_DIR="${TEST_OUTPUT_DIR}/benchmark" \
BENCHMARK_STATE_LIMIT=1 \
BENCHMARK_TIME_LIMIT_SECONDS=30 \
SAGE_BIN="${SAGE_BIN}" \
bash "${PROJECT_DIR}/benchmarks/run_v12_engine_benchmark.sh" \
    "${FACETS}" bounded_smoke \
    >"${TEST_OUTPUT_DIR}/benchmark.log" 2>&1

SUMMARY="${TEST_OUTPUT_DIR}/benchmark/summary.tsv"
test -s "${SUMMARY}"
grep -Fq $'bitset\tINCONCLUSIVE_RESOURCE_LIMIT' "${SUMMARY}"
grep -Fq $'sage_reference\tINCONCLUSIVE_RESOURCE_LIMIT' "${SUMMARY}"
if find "${TEST_OUTPUT_DIR}/benchmark" -name '*_certificate.json' \
    -print -quit | grep -q .; then
    echo "FAIL: bounded benchmark emitted an inconclusive certificate" >&2
    exit 1
fi

if BENCHMARK_OUTPUT_DIR="${TEST_OUTPUT_DIR}/benchmark" \
    BENCHMARK_STATE_LIMIT=1 \
    BENCHMARK_TIME_LIMIT_SECONDS=30 \
    SAGE_BIN="${SAGE_BIN}" \
    bash "${PROJECT_DIR}/benchmarks/run_v12_engine_benchmark.sh" \
        "${FACETS}" bounded_smoke \
        >"${TEST_OUTPUT_DIR}/benchmark_overwrite.log" 2>&1; then
    echo "FAIL: benchmark runner overwrote an existing output directory" >&2
    exit 1
fi
grep -Fq 'Benchmark output already exists' \
    "${TEST_OUTPUT_DIR}/benchmark_overwrite.log"

echo "PASS: state and cooperative time limits are explicitly inconclusive"
echo "PASS: bounded sequential engine benchmark produced a summary"
echo "PASS: benchmark history cannot be overwritten"
echo "All bounded-search tests passed."
