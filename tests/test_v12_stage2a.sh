#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage2a-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${TEST_OUTPUT_DIR}/verify_nonevasive_certificate.sage"
CERTIFICATE="${TEST_OUTPUT_DIR}/rudins_certificate.json"
CORRUPTED_HASH="${TEST_OUTPUT_DIR}/corrupted_hash.json"
CORRUPTED_VERTEX="${TEST_OUTPUT_DIR}/corrupted_vertex.json"
CORRUPTED_BRANCH="${TEST_OUTPUT_DIR}/corrupted_branch.json"
CORRUPTED_TERMINAL="${TEST_OUTPUT_DIR}/corrupted_terminal.json"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" "${VERIFIER}"

FACETS_FILE="${PROJECT_DIR}/knots/rudins_ball.txt" \
KNOT_NAME="rudins_stage2a" \
RANDOM_SEED=123456 \
CSV_OUTPUT="${TEST_OUTPUT_DIR}/rudins_tree.csv" \
CERTIFICATE_OUTPUT="${CERTIFICATE}" \
PROTECTED_VERTICES='[1, 2, 3]' \
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

grep -Fq 'FINAL_RESULT: NON_EVASIVE;' "${TEST_OUTPUT_DIR}/solver.log"
test -s "${CERTIFICATE}"

if ! "${SAGE_BIN}" "${VERIFIER}" \
    "${PROJECT_DIR}/knots/rudins_ball.txt" \
    "${CERTIFICATE}" >"${TEST_OUTPUT_DIR}/verifier.log" 2>&1; then
    cat "${TEST_OUTPUT_DIR}/verifier.log" >&2
    exit 1
fi
grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' "${TEST_OUTPUT_DIR}/verifier.log"

cp "${CERTIFICATE}" "${CORRUPTED_HASH}"
sed -i \
    's/"canonical_facets_sha256": "[^"]*"/"canonical_facets_sha256": "broken"/' \
    "${CORRUPTED_HASH}"

for corruption in vertex branch terminal; do
    destination_variable="CORRUPTED_${corruption^^}"
    destination=${!destination_variable}
    "${SAGE_BIN}" -python -c '
import json
import sys

source, destination, mode = sys.argv[1:]
with open(source, encoding="utf-8") as input_file:
    document = json.load(input_file)
root = next(
    state for state in document["states"]
    if state["id"] == document["root_state"]
)
if mode == "vertex":
    root["winning_vertex"] = 999999
elif mode == "branch":
    root["link_child"] = document["root_state"]
elif mode == "terminal":
    terminal = next(
        state for state in document["states"]
        if "terminal_reason" in state
    )
    terminal["terminal_reason"] = "not_a_terminal_theorem"
with open(destination, "w", encoding="utf-8") as output_file:
    json.dump(document, output_file)
' "${CERTIFICATE}" "${destination}" "${corruption}"
done

for corrupted in \
    "${CORRUPTED_HASH}" \
    "${CORRUPTED_VERTEX}" \
    "${CORRUPTED_BRANCH}" \
    "${CORRUPTED_TERMINAL}"; do
    if "${SAGE_BIN}" "${VERIFIER}" \
        "${PROJECT_DIR}/knots/rudins_ball.txt" \
        "${corrupted}" >"${TEST_OUTPUT_DIR}/corrupted.log" 2>&1; then
        echo "FAIL: corrupted certificate was accepted: ${corrupted}" >&2
        exit 1
    fi
    grep -Fq 'CERTIFICATE_INVALID:' "${TEST_OUTPUT_DIR}/corrupted.log"
done

echo "PASS: Rudin's-ball non-evasive certificate verified"
echo "PASS: hash, vertex, branch, and terminal corruptions rejected"
echo "All Stage 2A tests passed."
