#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage2b-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${TEST_OUTPUT_DIR}/verify_nonevasive_certificate.sage"
FACETS="${PROJECT_DIR}/tests/data/acyclic_evasive.txt"
CERTIFICATE="${TEST_OUTPUT_DIR}/evasive_certificate.json"
CORRUPTED="${TEST_OUTPUT_DIR}/evasive_certificate_corrupted.json"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" "${VERIFIER}"

FACETS_FILE="${FACETS}" \
KNOT_NAME="acyclic_evasive_stage2b" \
RANDOM_SEED=123456 \
CSV_OUTPUT="${TEST_OUTPUT_DIR}/unused_tree.csv" \
CERTIFICATE_OUTPUT="${CERTIFICATE}" \
PROTECTED_VERTICES='' \
PROTECTED_VERTEX_POLICY=prefer \
STATE_ENGINE=bitset \
NORMALIZED_COMPLEX_CACHE=true \
NORMALIZED_CACHE_MAX_FAILURES=100000 \
SEARCH_STATE_LIMIT=0 \
SEARCH_TIME_LIMIT_SECONDS=0 \
"${SAGE_BIN}" "${SOLVER}" >"${TEST_OUTPUT_DIR}/solver.log" 2>&1 || {
    cat "${TEST_OUTPUT_DIR}/solver.log" >&2
    exit 1
}

grep -Fq 'FINAL_RESULT: EVASIVE_CERTIFIED;' "${TEST_OUTPUT_DIR}/solver.log"
test -s "${CERTIFICATE}"

if ! "${SAGE_BIN}" "${VERIFIER}" \
    "${FACETS}" "${CERTIFICATE}" \
    >"${TEST_OUTPUT_DIR}/verifier.log" 2>&1; then
    cat "${TEST_OUTPUT_DIR}/verifier.log" >&2
    exit 1
fi
grep -Fq \
    'CERTIFICATE_VALID: EVASIVE_CERTIFIED;' \
    "${TEST_OUTPUT_DIR}/verifier.log"

"${SAGE_BIN}" -python -c '
import json
import sys

source, destination = sys.argv[1:]
with open(source, encoding="utf-8") as input_file:
    document = json.load(input_file)
root = next(
    state for state in document["states"]
    if state["id"] == document["root_state"]
)
root["failed_children"].pop()
with open(destination, "w", encoding="utf-8") as output_file:
    json.dump(document, output_file)
' "${CERTIFICATE}" "${CORRUPTED}"
if "${SAGE_BIN}" "${VERIFIER}" \
    "${FACETS}" "${CORRUPTED}" \
    >"${TEST_OUTPUT_DIR}/corrupted.log" 2>&1; then
    echo "FAIL: incomplete evasiveness certificate was accepted" >&2
    exit 1
fi
grep -Fq 'CERTIFICATE_INVALID:' "${TEST_OUTPUT_DIR}/corrupted.log"

echo "PASS: nonterminal evasiveness certificate verified"
echo "PASS: incomplete vertex coverage rejected"
echo "All Stage 2B tests passed."
