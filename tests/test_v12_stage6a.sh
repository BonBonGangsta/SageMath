#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

"${SAGE_BIN}" "${PROJECT_DIR}/tests/test_v12_stage6a.sage"

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage6a-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${TEST_OUTPUT_DIR}/verify_nonevasive_certificate.sage"
FACETS="${PROJECT_DIR}/knots/rudins_ball.txt"
PROTECTED_FACETS="${PROJECT_DIR}/tests/data/protected_policy_example.txt"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" "${VERIFIER}"

run_case() {
    local name=$1
    local child_aware=$2
    local engine=$3
    local max_vertices=$4
    local certificate="${TEST_OUTPUT_DIR}/${name}.json"
    local log_file="${TEST_OUTPUT_DIR}/${name}.log"

    FACETS_FILE="${FACETS}" \
    KNOT_NAME="stage6a_${name}" \
    RANDOM_SEED=123456 \
    CERTIFICATE_OUTPUT="${certificate}" \
    PROTECTED_VERTICES='' \
    PROTECTED_VERTEX_POLICY=prefer \
    STATE_ENGINE="${engine}" \
    SEARCH_STRATEGY=random \
    NORMALIZED_COMPLEX_CACHE=true \
    ISOMORPHISM_COMPLEX_CACHE=false \
    AUTOMORPHISM_ORBIT_PRUNING=false \
    CHILD_AWARE_ORDERING="${child_aware}" \
    CHILD_AWARE_MAX_VERTICES="${max_vertices}" \
    CHILD_AWARE_MAX_FACETS=0 \
    SEARCH_STATE_LIMIT=0 \
    SEARCH_TIME_LIMIT_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1 || {
        cat "${log_file}" >&2
        return 1
    }

    grep -Fq 'FINAL_RESULT: NON_EVASIVE;' "${log_file}"
    test -s "${certificate}"
    "${SAGE_BIN}" "${VERIFIER}" "${FACETS}" "${certificate}" \
        >"${TEST_OUTPUT_DIR}/${name}_verify.log" 2>&1 || {
        cat "${TEST_OUTPUT_DIR}/${name}_verify.log" >&2
        return 1
    }
    grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
        "${TEST_OUTPUT_DIR}/${name}_verify.log"
}

run_case baseline false bitset 0
run_case child_aware true bitset 0
run_case child_aware_reference true sage_reference 0
run_case threshold_skip true bitset 1

grep -Fq 'child_aware_states_scored=0;' "${TEST_OUTPUT_DIR}/baseline.log"
grep -Eq 'child_aware_states_scored=[1-9][0-9]*;' \
    "${TEST_OUTPUT_DIR}/child_aware.log"
grep -Eq 'child_aware_states_reordered=[1-9][0-9]*;' \
    "${TEST_OUTPUT_DIR}/child_aware.log"
grep -Eq 'child_preclassifications=[1-9][0-9]*;' \
    "${TEST_OUTPUT_DIR}/child_aware.log"
grep -Fq 'child_aware_states_scored=0;' \
    "${TEST_OUTPUT_DIR}/threshold_skip.log"
grep -Eq 'child_aware_states_skipped=[1-9][0-9]*;' \
    "${TEST_OUTPUT_DIR}/threshold_skip.log"

"${SAGE_BIN}" -python -c '
import json
import re
import sys

baseline_log, child_log, reference_path, child_path = sys.argv[1:]

def metric(path, label):
    text = open(path, encoding="utf-8").read()
    match = re.search(rf"^{re.escape(label)}: ([0-9,]+)", text, re.MULTILINE)
    assert match, label
    return int(match.group(1).replace(",", ""))

assert metric(child_log, "Subcomplex cache misses") < metric(
    baseline_log, "Subcomplex cache misses"
)
assert metric(child_log, "Vertex attempts") < metric(
    baseline_log, "Vertex attempts"
)

with open(reference_path, encoding="utf-8") as input_file:
    reference = json.load(input_file)
with open(child_path, encoding="utf-8") as input_file:
    child = json.load(input_file)
assert reference["result"] == child["result"] == "NON_EVASIVE"
assert reference["states"] == child["states"]
' \
    "${TEST_OUTPUT_DIR}/baseline.log" \
    "${TEST_OUTPUT_DIR}/child_aware.log" \
    "${TEST_OUTPUT_DIR}/child_aware_reference.json" \
    "${TEST_OUTPUT_DIR}/child_aware.json"

for policy in prefer restrict; do
    expected=NON_EVASIVE
    if [[ "${policy}" == restrict ]]; then
        expected=INCONCLUSIVE_RESTRICTED
    fi
    log_file="${TEST_OUTPUT_DIR}/protected_${policy}.log"
    FACETS_FILE="${PROTECTED_FACETS}" \
    KNOT_NAME="stage6a_protected_${policy}" \
    RANDOM_SEED=123456 \
    CERTIFICATE_OUTPUT="${TEST_OUTPUT_DIR}/protected_${policy}.json" \
    PROTECTED_VERTICES='[1, 2, 3]' \
    PROTECTED_VERTEX_POLICY="${policy}" \
    STATE_ENGINE=bitset \
    SEARCH_STRATEGY=random \
    CHILD_AWARE_ORDERING=true \
    CHILD_AWARE_MAX_VERTICES=0 \
    CHILD_AWARE_MAX_FACETS=0 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1
    grep -Fq "FINAL_RESULT: ${expected};" "${log_file}"
done

for invalid_case in strategy vertices facets; do
    log_file="${TEST_OUTPUT_DIR}/invalid_${invalid_case}.log"
    strategy=random
    max_vertices=80
    max_facets=500
    expected_message=''
    case "${invalid_case}" in
        strategy)
            strategy=unknown
            expected_message='SEARCH_STRATEGY must be one of:'
            ;;
        vertices)
            max_vertices=-1
            expected_message='CHILD_AWARE_MAX_VERTICES cannot be negative'
            ;;
        facets)
            max_facets=-1
            expected_message='CHILD_AWARE_MAX_FACETS cannot be negative'
            ;;
    esac
    if FACETS_FILE="${FACETS}" \
        SEARCH_STRATEGY="${strategy}" \
        CHILD_AWARE_MAX_VERTICES="${max_vertices}" \
        CHILD_AWARE_MAX_FACETS="${max_facets}" \
        "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1; then
        echo "FAIL: invalid Stage 6A setting accepted: ${invalid_case}" >&2
        exit 1
    fi
    grep -Fq "${expected_message}" "${log_file}"
done

BENCHMARK_OUTPUT_DIR="${TEST_OUTPUT_DIR}/branching_benchmark" \
BENCHMARK_STATE_LIMIT=0 \
BENCHMARK_TIME_LIMIT_SECONDS=0 \
RANDOM_SEED=123456 \
CHILD_AWARE_MAX_VERTICES=0 \
CHILD_AWARE_MAX_FACETS=0 \
SAGE_BIN="${SAGE_BIN}" \
bash "${PROJECT_DIR}/benchmarks/run_v12_branching_benchmark.sh" \
    "${FACETS}" stage6a_benchmark \
    >"${TEST_OUTPUT_DIR}/benchmark.log" 2>&1

SUMMARY="${TEST_OUTPUT_DIR}/branching_benchmark/summary.tsv"
test -s "${SUMMARY}"
grep -Fq $'baseline\tNON_EVASIVE' "${SUMMARY}"
grep -Fq $'child_aware\tNON_EVASIVE' "${SUMMARY}"
grep -Fq $'resource_limit\tcertificate' "${SUMMARY}"
grep -Fq $'verified' "${SUMMARY}"

if BENCHMARK_OUTPUT_DIR="${TEST_OUTPUT_DIR}/branching_benchmark" \
    SAGE_BIN="${SAGE_BIN}" \
    bash "${PROJECT_DIR}/benchmarks/run_v12_branching_benchmark.sh" \
        "${FACETS}" stage6a_benchmark \
        >"${TEST_OUTPUT_DIR}/benchmark_overwrite.log" 2>&1; then
    echo "FAIL: branching benchmark overwrote existing output" >&2
    exit 1
fi
grep -Fq 'Benchmark output already exists' \
    "${TEST_OUTPUT_DIR}/benchmark_overwrite.log"

echo "PASS: child-aware ordering reduced Rudin search work"
echo "PASS: bitset and Sage-reference child-aware proofs matched"
echo "PASS: size gates and protected policies retained their semantics"
echo "PASS: sequential branching benchmark produced verified artifacts"
echo "All Stage 6A tests passed."
