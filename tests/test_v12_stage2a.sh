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
CORRUPTED="${TEST_OUTPUT_DIR}/rudins_certificate_corrupted.json"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" "${VERIFIER}"

FACETS_FILE="${PROJECT_DIR}/knots/rudins_ball.txt" \
KNOT_NAME="rudins_stage2a" \
RANDOM_SEED=123456 \
CSV_OUTPUT="${TEST_OUTPUT_DIR}/rudins_tree.csv" \
CERTIFICATE_OUTPUT="${CERTIFICATE}" \
PROTECTED_VERTICES='[1, 2, 3]' \
PROTECTED_VERTEX_POLICY=prefer \
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

cp "${CERTIFICATE}" "${CORRUPTED}"
sed -i \
    's/"canonical_facets_sha256": "[^"]*"/"canonical_facets_sha256": "broken"/' \
    "${CORRUPTED}"
if "${SAGE_BIN}" "${VERIFIER}" \
    "${PROJECT_DIR}/knots/rudins_ball.txt" \
    "${CORRUPTED}" >"${TEST_OUTPUT_DIR}/corrupted.log" 2>&1; then
    echo "FAIL: corrupted certificate was accepted" >&2
    exit 1
fi
grep -Fq 'CERTIFICATE_INVALID:' "${TEST_OUTPUT_DIR}/corrupted.log"

echo "PASS: Rudin's-ball non-evasive certificate verified"
echo "PASS: corrupted certificate rejected"
echo "All Stage 2A tests passed."
