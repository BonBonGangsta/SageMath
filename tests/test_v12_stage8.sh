#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage8-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEST_OUTPUT_DIR}/"

"${SAGE_BIN}" "${PROJECT_DIR}/tests/test_v12_stage8.sage" \
    >"${TEST_OUTPUT_DIR}/reference.log" 2>&1 || {
        cat "${TEST_OUTPUT_DIR}/reference.log" >&2
        exit 1
    }
cat "${TEST_OUTPUT_DIR}/reference.log"

run_case() {
    local name=$1
    local fixture=$2
    local expected=$3
    local normalized_cache=${4:-true}
    local log_file="${TEST_OUTPUT_DIR}/${name}.log"
    local certificate="${TEST_OUTPUT_DIR}/${name}.json"
    local verification="${TEST_OUTPUT_DIR}/${name}_verify.log"

    FACETS_FILE="${fixture}" \
    KNOT_NAME="stage8_${name}" \
    RANDOM_SEED=123456 \
    CERTIFICATE_OUTPUT="${certificate}" \
    PROTECTED_VERTICES='' \
    PROTECTED_VERTEX_POLICY=prefer \
    STATE_ENGINE=bitset \
    SEARCH_STRATEGY=lexical \
    NORMALIZED_COMPLEX_CACHE="${normalized_cache}" \
    ISOMORPHISM_COMPLEX_CACHE=false \
    AUTOMORPHISM_ORBIT_PRUNING=false \
    CHILD_AWARE_ORDERING=false \
    OBSTRUCTION_SCHEDULER=fixed \
    NONCOLLAPSIBILITY_OBSTRUCTION=false \
    HOMOLOGY_FIELD_PRIMES=2 \
    CHECKPOINT_PATH='' \
    CHECKPOINT_RESUME=false \
    CHECKPOINT_OVERWRITE=false \
    SEARCH_STATE_LIMIT=0 \
    SEARCH_TIME_LIMIT_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1 || {
        cat "${log_file}" >&2
        exit 1
    }

    grep -Fq "FINAL_RESULT: ${expected};" "${log_file}"
    test -s "${certificate}"
    "${SAGE_BIN}" "${VERIFIER}" "${fixture}" "${certificate}" \
        >"${verification}" 2>&1 || {
            cat "${verification}" >&2
            exit 1
        }
    grep -Fq "CERTIFICATE_VALID: ${expected};" "${verification}"
}

DATA_DIR="${PROJECT_DIR}/tests/data"
run_case point "${DATA_DIR}/point.txt" NON_EVASIVE
run_case simplex "${DATA_DIR}/simplex.txt" NON_EVASIVE
run_case tree "${DATA_DIR}/tree.txt" NON_EVASIVE
run_case cycle "${DATA_DIR}/cycle.txt" EVASIVE_CERTIFIED
run_case disconnected_vertices \
    "${DATA_DIR}/disconnected_vertices.txt" EVASIVE_CERTIFIED
run_case cone_over_tree "${DATA_DIR}/cone_over_tree.txt" NON_EVASIVE
run_case cone_over_cycle "${DATA_DIR}/cone_over_cycle.txt" NON_EVASIVE
run_case tetrahedron_boundary \
    "${DATA_DIR}/tetrahedron_boundary.txt" EVASIVE_CERTIFIED
run_case acyclic_evasive \
    "${DATA_DIR}/acyclic_evasive.txt" EVASIVE_CERTIFIED
run_case acyclic_evasive_cache_off \
    "${DATA_DIR}/acyclic_evasive.txt" EVASIVE_CERTIFIED false

# A JSON load/dump round trip must preserve both proof directions.
for name in tree acyclic_evasive; do
    "${SAGE_BIN}" -python -c '
import json
import sys

source, destination = sys.argv[1:]
with open(source, encoding="utf-8") as input_file:
    document = json.load(input_file)
with open(destination, "w", encoding="utf-8") as output_file:
    json.dump(document, output_file, indent=2, sort_keys=True)
    output_file.write("\n")
' "${TEST_OUTPUT_DIR}/${name}.json" \
        "${TEST_OUTPUT_DIR}/${name}_roundtrip.json"
    "${SAGE_BIN}" "${VERIFIER}" "${DATA_DIR}/${name}.txt" \
        "${TEST_OUTPUT_DIR}/${name}_roundtrip.json" \
        >"${TEST_OUTPUT_DIR}/${name}_roundtrip_verify.log" 2>&1
    grep -Fq 'CERTIFICATE_VALID:' \
        "${TEST_OUTPUT_DIR}/${name}_roundtrip_verify.log"
done

# Corrupt one positive input binding and one recursive negative proof.
"${SAGE_BIN}" -python -c '
import json
import sys

positive, bad_positive, negative, bad_negative = sys.argv[1:]
with open(positive, encoding="utf-8") as input_file:
    document = json.load(input_file)
document["input"]["canonical_facets_sha256"] = "0" * 64
with open(bad_positive, "w", encoding="utf-8") as output_file:
    json.dump(document, output_file)

with open(negative, encoding="utf-8") as input_file:
    document = json.load(input_file)
root = next(
    state for state in document["states"]
    if state["id"] == document["root_state"]
)
root["failed_children"].pop()
with open(bad_negative, "w", encoding="utf-8") as output_file:
    json.dump(document, output_file)
' "${TEST_OUTPUT_DIR}/tree.json" \
    "${TEST_OUTPUT_DIR}/tree_corrupted.json" \
    "${TEST_OUTPUT_DIR}/acyclic_evasive.json" \
    "${TEST_OUTPUT_DIR}/acyclic_evasive_corrupted.json"

if "${SAGE_BIN}" "${VERIFIER}" "${DATA_DIR}/tree.txt" \
    "${TEST_OUTPUT_DIR}/tree_corrupted.json" \
    >"${TEST_OUTPUT_DIR}/tree_corrupted.log" 2>&1; then
    echo "FAIL: corrupted positive certificate was accepted" >&2
    exit 1
fi
grep -Fq 'CERTIFICATE_INVALID:' \
    "${TEST_OUTPUT_DIR}/tree_corrupted.log"

if "${SAGE_BIN}" "${VERIFIER}" "${DATA_DIR}/acyclic_evasive.txt" \
    "${TEST_OUTPUT_DIR}/acyclic_evasive_corrupted.json" \
    >"${TEST_OUTPUT_DIR}/acyclic_evasive_corrupted.log" 2>&1; then
    echo "FAIL: incomplete negative certificate was accepted" >&2
    exit 1
fi
grep -Fq 'CERTIFICATE_INVALID:' \
    "${TEST_OUTPUT_DIR}/acyclic_evasive_corrupted.log"

# Confirm the complete preferred policy and deliberately incomplete strict
# policy retain distinct top-level result semantics.
PREFERRED_CERTIFICATE="${TEST_OUTPUT_DIR}/protected_prefer.json"
FACETS_FILE="${DATA_DIR}/protected_policy_example.txt" \
RANDOM_SEED=123456 \
CERTIFICATE_OUTPUT="${PREFERRED_CERTIFICATE}" \
PROTECTED_VERTICES='[1, 2, 3]' \
PROTECTED_VERTEX_POLICY=prefer \
STATE_ENGINE=bitset \
SEARCH_STRATEGY=lexical \
NORMALIZED_COMPLEX_CACHE=true \
ISOMORPHISM_COMPLEX_CACHE=false \
AUTOMORPHISM_ORBIT_PRUNING=false \
CHILD_AWARE_ORDERING=false \
NONCOLLAPSIBILITY_OBSTRUCTION=false \
CHECKPOINT_PATH='' \
CHECKPOINT_RESUME=false \
CHECKPOINT_OVERWRITE=false \
SEARCH_STATE_LIMIT=0 \
SEARCH_TIME_LIMIT_SECONDS=0 \
"${SAGE_BIN}" "${SOLVER}" \
    >"${TEST_OUTPUT_DIR}/protected_prefer.log" 2>&1
grep -Fq 'FINAL_RESULT: NON_EVASIVE;' \
    "${TEST_OUTPUT_DIR}/protected_prefer.log"
"${SAGE_BIN}" "${VERIFIER}" \
    "${DATA_DIR}/protected_policy_example.txt" \
    "${PREFERRED_CERTIFICATE}" \
    >"${TEST_OUTPUT_DIR}/protected_prefer_verify.log" 2>&1
grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
    "${TEST_OUTPUT_DIR}/protected_prefer_verify.log"

STRICT_CERTIFICATE="${TEST_OUTPUT_DIR}/protected_restrict.json"
FACETS_FILE="${DATA_DIR}/protected_policy_example.txt" \
RANDOM_SEED=123456 \
CERTIFICATE_OUTPUT="${STRICT_CERTIFICATE}" \
PROTECTED_VERTICES='[1, 2, 3]' \
PROTECTED_VERTEX_POLICY=restrict \
STATE_ENGINE=bitset \
SEARCH_STRATEGY=lexical \
NORMALIZED_COMPLEX_CACHE=true \
ISOMORPHISM_COMPLEX_CACHE=false \
AUTOMORPHISM_ORBIT_PRUNING=false \
CHILD_AWARE_ORDERING=false \
NONCOLLAPSIBILITY_OBSTRUCTION=false \
CHECKPOINT_PATH='' \
CHECKPOINT_RESUME=false \
CHECKPOINT_OVERWRITE=false \
SEARCH_STATE_LIMIT=0 \
SEARCH_TIME_LIMIT_SECONDS=0 \
"${SAGE_BIN}" "${SOLVER}" \
    >"${TEST_OUTPUT_DIR}/protected_restrict.log" 2>&1
grep -Fq 'FINAL_RESULT: INCONCLUSIVE_RESTRICTED;' \
    "${TEST_OUTPUT_DIR}/protected_restrict.log"
if [[ -e "${STRICT_CERTIFICATE}" ]]; then
    echo "FAIL: strict inconclusive search emitted a certificate" >&2
    exit 1
fi

echo "PASS: all named topology fixtures produced verified certificates"
echo "PASS: cache-on and cache-off recursive proofs both verified"
echo "PASS: certificate round trips verified and corruptions were rejected"
echo "PASS: preferred and strict protected policies retained sound results"
echo "All Stage 8 tests passed."
