#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

"${SAGE_BIN}" "${PROJECT_DIR}/tests/test_v12_stage6b.sage"

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage6b-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage"
DUNCE="${PROJECT_DIR}/tests/data/dunce_hat.txt"
MOORE="${PROJECT_DIR}/tests/data/moore_space_3.txt"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEST_OUTPUT_DIR}/"

run_dunce() {
    local name=$1
    local scheduler=$2
    local obstruction=$3
    local max_vertices=$4
    local certificate="${TEST_OUTPUT_DIR}/${name}.json"
    local log_file="${TEST_OUTPUT_DIR}/${name}.log"

    FACETS_FILE="${DUNCE}" \
    KNOT_NAME="stage6b_${name}" \
    RANDOM_SEED=123456 \
    CERTIFICATE_OUTPUT="${certificate}" \
    STATE_ENGINE=bitset \
    SEARCH_STRATEGY=random \
    NORMALIZED_COMPLEX_CACHE=true \
    OBSTRUCTION_SCHEDULER="${scheduler}" \
    OBSTRUCTION_ADAPTIVE_WARMUP_CALLS=1 \
    NONCOLLAPSIBILITY_OBSTRUCTION="${obstruction}" \
    NONCOLLAPSIBILITY_MAX_VERTICES="${max_vertices}" \
    NONCOLLAPSIBILITY_MAX_FACETS=0 \
    HOMOLOGY_FIELD_PRIMES=2,3 \
    SEARCH_STATE_LIMIT=0 \
    SEARCH_TIME_LIMIT_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1 || {
        cat "${log_file}" >&2
        return 1
    }

    grep -Fq 'FINAL_RESULT: EVASIVE_CERTIFIED;' "${log_file}"
    test -s "${certificate}"
    "${SAGE_BIN}" "${VERIFIER}" "${DUNCE}" "${certificate}" \
        >"${TEST_OUTPUT_DIR}/${name}_verify.log" 2>&1
    grep -Fq 'CERTIFICATE_VALID: EVASIVE_CERTIFIED;' \
        "${TEST_OUTPUT_DIR}/${name}_verify.log"
}

run_dunce baseline fixed false 0
run_dunce no_free adaptive true 0
run_dunce size_gated adaptive true 1

grep -Fq 'noncollapsibility_rejections=0;' \
    "${TEST_OUTPUT_DIR}/baseline.log"
grep -Fq 'noncollapsibility_rejections=1;' \
    "${TEST_OUTPUT_DIR}/no_free.log"
grep -Eq 'No-free-face obstruction: 0 eligible; [1-9][0-9]* size-gated' \
    "${TEST_OUTPUT_DIR}/size_gated.log"

"${SAGE_BIN}" -python -c '
import json
import re
import sys

baseline_log, optimized_log, optimized_certificate = sys.argv[1:]

def states(path):
    text = open(path, encoding="utf-8").read()
    match = re.search(r"^Subcomplex cache misses: ([0-9,]+)", text, re.M)
    assert match
    return int(match.group(1).replace(",", ""))

assert states(optimized_log) < states(baseline_log)
with open(optimized_certificate, encoding="utf-8") as input_file:
    document = json.load(input_file)
root = next(
    state for state in document["states"]
    if state["id"] == document["root_state"]
)
assert root["terminal_reason"] == "no_free_face_noncollapsible"
' \
    "${TEST_OUTPUT_DIR}/baseline.log" \
    "${TEST_OUTPUT_DIR}/no_free.log" \
    "${TEST_OUTPUT_DIR}/no_free.json"

MOORE_CERTIFICATE="${TEST_OUTPUT_DIR}/moore.json"
MOORE_LOG="${TEST_OUTPUT_DIR}/moore.log"
FACETS_FILE="${MOORE}" \
KNOT_NAME=stage6b_moore \
RANDOM_SEED=123456 \
CERTIFICATE_OUTPUT="${MOORE_CERTIFICATE}" \
OBSTRUCTION_SCHEDULER=adaptive \
NONCOLLAPSIBILITY_OBSTRUCTION=false \
HOMOLOGY_FIELD_PRIMES=2,3 \
HOMOLOGY_FIELDS_AT_ROOT=true \
"${SAGE_BIN}" "${SOLVER}" >"${MOORE_LOG}" 2>&1

grep -Fq 'FINAL_RESULT: EVASIVE_CERTIFIED;' "${MOORE_LOG}"
grep -Fq 'homology_zz_calls=0;' "${MOORE_LOG}"
grep -Fq 'homology_gf2_calls=1;' "${MOORE_LOG}"
grep -Fq 'homology_field_rejections=2:0,3:1' "${MOORE_LOG}"
"${SAGE_BIN}" "${VERIFIER}" "${MOORE}" "${MOORE_CERTIFICATE}" \
    >"${TEST_OUTPUT_DIR}/moore_verify.log" 2>&1
grep -Fq 'CERTIFICATE_VALID: EVASIVE_CERTIFIED;' \
    "${TEST_OUTPUT_DIR}/moore_verify.log"
grep -Fq '"terminal_reason": "nontrivial_homology_GF3"' \
    "${MOORE_CERTIFICATE}"

"${SAGE_BIN}" -python -c '
import json
import sys

source, target, replacement = sys.argv[1:]
with open(source, encoding="utf-8") as input_file:
    document = json.load(input_file)
root = next(
    state for state in document["states"]
    if state["id"] == document["root_state"]
)
root["terminal_reason"] = replacement
with open(target, "w", encoding="utf-8") as output_file:
    json.dump(document, output_file)
' "${TEST_OUTPUT_DIR}/no_free.json" \
    "${TEST_OUTPUT_DIR}/corrupt_no_free.json" simplex

if "${SAGE_BIN}" "${VERIFIER}" "${DUNCE}" \
    "${TEST_OUTPUT_DIR}/corrupt_no_free.json" \
    >"${TEST_OUTPUT_DIR}/corrupt_no_free.log" 2>&1; then
    echo "FAIL: false no-free-face replacement was accepted" >&2
    exit 1
fi
grep -Fq 'CERTIFICATE_INVALID:' \
    "${TEST_OUTPUT_DIR}/corrupt_no_free.log"

"${SAGE_BIN}" -python -c '
import json
import sys

source, target = sys.argv[1:]
with open(source, encoding="utf-8") as input_file:
    document = json.load(input_file)
root = next(
    state for state in document["states"]
    if state["id"] == document["root_state"]
)
root["terminal_reason"] = "nontrivial_homology_GF5"
with open(target, "w", encoding="utf-8") as output_file:
    json.dump(document, output_file)
' "${MOORE_CERTIFICATE}" "${TEST_OUTPUT_DIR}/corrupt_moore.json"

if "${SAGE_BIN}" "${VERIFIER}" "${MOORE}" \
    "${TEST_OUTPUT_DIR}/corrupt_moore.json" \
    >"${TEST_OUTPUT_DIR}/corrupt_moore.log" 2>&1; then
    echo "FAIL: false GF(5) terminal reason was accepted" >&2
    exit 1
fi
grep -Fq 'CERTIFICATE_INVALID:' "${TEST_OUTPUT_DIR}/corrupt_moore.log"

for invalid_case in scheduler warmup vertices facets composite repeated; do
    scheduler=fixed
    warmup=8
    max_vertices=80
    max_facets=200
    primes=2
    expected_message=''
    case "${invalid_case}" in
        scheduler)
            scheduler=unknown
            expected_message='OBSTRUCTION_SCHEDULER must be one of:'
            ;;
        warmup)
            warmup=-1
            expected_message='OBSTRUCTION_ADAPTIVE_WARMUP_CALLS cannot be negative'
            ;;
        vertices)
            max_vertices=-1
            expected_message='NONCOLLAPSIBILITY_MAX_VERTICES cannot be negative'
            ;;
        facets)
            max_facets=-1
            expected_message='NONCOLLAPSIBILITY_MAX_FACETS cannot be negative'
            ;;
        composite)
            primes=2,4
            expected_message='HOMOLOGY_FIELD_PRIMES must contain primes'
            ;;
        repeated)
            primes=2,2
            expected_message='HOMOLOGY_FIELD_PRIMES cannot repeat a prime'
            ;;
    esac
    log_file="${TEST_OUTPUT_DIR}/invalid_${invalid_case}.log"
    if FACETS_FILE="${DUNCE}" \
        OBSTRUCTION_SCHEDULER="${scheduler}" \
        OBSTRUCTION_ADAPTIVE_WARMUP_CALLS="${warmup}" \
        NONCOLLAPSIBILITY_MAX_VERTICES="${max_vertices}" \
        NONCOLLAPSIBILITY_MAX_FACETS="${max_facets}" \
        HOMOLOGY_FIELD_PRIMES="${primes}" \
        "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1; then
        echo "FAIL: invalid Stage 6B setting accepted: ${invalid_case}" >&2
        exit 1
    fi
    grep -Fq "${expected_message}" "${log_file}"
done

BENCHMARK_OUTPUT_DIR="${TEST_OUTPUT_DIR}/obstruction_benchmark" \
BENCHMARK_STATE_LIMIT=0 \
BENCHMARK_TIME_LIMIT_SECONDS=0 \
RANDOM_SEED=123456 \
SAGE_BIN="${SAGE_BIN}" \
bash "${PROJECT_DIR}/benchmarks/run_v12_obstruction_benchmark.sh" \
    "${DUNCE}" stage6b_benchmark \
    >"${TEST_OUTPUT_DIR}/benchmark.log" 2>&1

SUMMARY="${TEST_OUTPUT_DIR}/obstruction_benchmark/summary.tsv"
test -s "${SUMMARY}"
grep -Fq $'fixed\tEVASIVE_CERTIFIED' "${SUMMARY}"
grep -Fq $'adaptive\tEVASIVE_CERTIFIED' "${SUMMARY}"
grep -Fq $'resource_limit\tcertificate' "${SUMMARY}"
grep -Fq $'verified' "${SUMMARY}"

if BENCHMARK_OUTPUT_DIR="${TEST_OUTPUT_DIR}/obstruction_benchmark" \
    SAGE_BIN="${SAGE_BIN}" \
    bash "${PROJECT_DIR}/benchmarks/run_v12_obstruction_benchmark.sh" \
        "${DUNCE}" stage6b_benchmark \
        >"${TEST_OUTPUT_DIR}/benchmark_overwrite.log" 2>&1; then
    echo "FAIL: obstruction benchmark overwrote existing output" >&2
    exit 1
fi
grep -Fq 'Benchmark output already exists' \
    "${TEST_OUTPUT_DIR}/benchmark_overwrite.log"

echo "PASS: certified no-free-face rejection reduced the Dunce Hat search"
echo "PASS: independently verified GF(3) rejection caught odd torsion"
echo "PASS: corrupted Stage 6B terminal claims were rejected"
echo "PASS: size gates and invalid Stage 6B settings behaved correctly"
echo "PASS: sequential obstruction benchmark produced verified artifacts"
echo "All Stage 6B tests passed."
