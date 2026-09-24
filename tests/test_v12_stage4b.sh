#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage4b-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${TEST_OUTPUT_DIR}/verify_nonevasive_certificate.sage"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" "${VERIFIER}"

run_case() {
    local case_name=$1
    local facets_file=$2
    local expected_result=$3
    local protected_vertices=$4
    local engine=$5
    local certificate="${TEST_OUTPUT_DIR}/${case_name}_${engine}.json"
    local log_file="${TEST_OUTPUT_DIR}/${case_name}_${engine}.log"

    FACETS_FILE="${facets_file}" \
    KNOT_NAME="${case_name}" \
    RANDOM_SEED=123456 \
    CERTIFICATE_OUTPUT="${certificate}" \
    PROTECTED_VERTICES="${protected_vertices}" \
    PROTECTED_VERTEX_POLICY=prefer \
    STATE_ENGINE="${engine}" \
    SEARCH_STATE_LIMIT=0 \
    SEARCH_TIME_LIMIT_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1 || {
        cat "${log_file}" >&2
        return 1
    }

    grep -Fq "State engine: ${engine}" "${log_file}"
    grep -Fq "FINAL_RESULT: ${expected_result};" "${log_file}"
    test -s "${certificate}"

    "${SAGE_BIN}" "${VERIFIER}" \
        "${facets_file}" "${certificate}" \
        >"${TEST_OUTPUT_DIR}/${case_name}_${engine}_verify.log" 2>&1 || {
        cat "${TEST_OUTPUT_DIR}/${case_name}_${engine}_verify.log" >&2
        return 1
    }

    "${SAGE_BIN}" -python -c '
import re
import sys

log_path, engine = sys.argv[1:]
text = open(log_path, encoding="utf-8").read()
misses = int(re.search(r"Subcomplex cache misses: ([0-9,]+)", text).group(1).replace(",", ""))
materializations = int(re.search(r"Sage state materializations: ([0-9,]+)", text).group(1).replace(",", ""))
bitset_reconstructions = int(re.search(r"Bitset state reconstructions: ([0-9,]+)", text).group(1).replace(",", ""))
assert materializations == misses
if engine == "bitset":
    assert bitset_reconstructions == misses
else:
    assert bitset_reconstructions == 0
' "${log_file}" "${engine}"
}

compare_certificates() {
    local case_name=$1
    "${SAGE_BIN}" -python -c '
import json
import sys

bitset_path, reference_path = sys.argv[1:]
with open(bitset_path, encoding="utf-8") as input_file:
    bitset = json.load(input_file)
with open(reference_path, encoding="utf-8") as input_file:
    reference = json.load(input_file)
for field in ("result", "root_state", "input", "states"):
    assert bitset[field] == reference[field], field
' \
        "${TEST_OUTPUT_DIR}/${case_name}_bitset.json" \
        "${TEST_OUTPUT_DIR}/${case_name}_sage_reference.json"
}

for engine in bitset sage_reference; do
    run_case \
        "rudins_stage4b" \
        "${PROJECT_DIR}/knots/rudins_ball.txt" \
        "NON_EVASIVE" \
        '[1, 2, 3]' \
        "${engine}"
    run_case \
        "acyclic_evasive_stage4b" \
        "${PROJECT_DIR}/tests/data/acyclic_evasive.txt" \
        "EVASIVE_CERTIFIED" \
        '' \
        "${engine}"
done

compare_certificates "rudins_stage4b"
compare_certificates "acyclic_evasive_stage4b"

if FACETS_FILE="${PROJECT_DIR}/tests/data/simplex.txt" \
    RANDOM_SEED=123456 \
    CERTIFICATE_OUTPUT="${TEST_OUTPUT_DIR}/invalid.json" \
    STATE_ENGINE=invalid \
    SEARCH_STATE_LIMIT=0 \
    SEARCH_TIME_LIMIT_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" \
    >"${TEST_OUTPUT_DIR}/invalid_engine.log" 2>&1; then
    echo "FAIL: invalid state engine was accepted" >&2
    exit 1
fi
grep -Fq \
    'STATE_ENGINE must be one of: bitset, sage_reference' \
    "${TEST_OUTPUT_DIR}/invalid_engine.log"

echo "PASS: bitset and Sage-reference engines produced identical proofs"
echo "PASS: every cache miss materialized exactly one Sage state"
echo "All Stage 4B tests passed."
