#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage3-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${TEST_OUTPUT_DIR}/verify_nonevasive_certificate.sage"
CERTIFICATE="${TEST_OUTPUT_DIR}/rudins_certificate.json"
LEGACY_TREE="${TEST_OUTPUT_DIR}/legacy_tree.csv"
LOG_FILE="${TEST_OUTPUT_DIR}/solver.log"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" "${VERIFIER}"

FACETS_FILE="${PROJECT_DIR}/knots/rudins_ball.txt" \
KNOT_NAME="rudins_stage3" \
RANDOM_SEED=123456 \
CSV_OUTPUT="${LEGACY_TREE}" \
CERTIFICATE_OUTPUT="${CERTIFICATE}" \
PROTECTED_VERTICES='[1, 2, 3]' \
PROTECTED_VERTEX_POLICY=prefer \
STATE_ENGINE=bitset \
"${SAGE_BIN}" "${SOLVER}" >"${LOG_FILE}" 2>&1 || {
    cat "${LOG_FILE}" >&2
    exit 1
}

grep -Fq 'FINAL_RESULT: NON_EVASIVE;' "${LOG_FILE}"
grep -Fq 'Found a valid certificate DAG.' "${LOG_FILE}"
grep -Fq 'Certificate DAG states:' "${LOG_FILE}"
if grep -Fq 'Deletion Decision Tree' "${LOG_FILE}"; then
    echo "FAIL: expanded decision tree was printed" >&2
    exit 1
fi
if [[ -e "${LEGACY_TREE}" ]]; then
    echo "FAIL: legacy CSV tree was written" >&2
    exit 1
fi
test -s "${CERTIFICATE}"

if ! "${SAGE_BIN}" "${VERIFIER}" \
    "${PROJECT_DIR}/knots/rudins_ball.txt" \
    "${CERTIFICATE}" >"${TEST_OUTPUT_DIR}/verifier.log" 2>&1; then
    cat "${TEST_OUTPUT_DIR}/verifier.log" >&2
    exit 1
fi
grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
    "${TEST_OUTPUT_DIR}/verifier.log"

echo "PASS: certificate DAG is the sole proof artifact"
echo "PASS: expanded tree output and legacy CSV are absent"
echo "All Stage 3 tests passed."
