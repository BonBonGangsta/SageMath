#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

"${SAGE_BIN}" "${PROJECT_DIR}/tests/test_v12_stage5b.sage"

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage5b-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${TEST_OUTPUT_DIR}/verify_nonevasive_certificate.sage"
FACETS="${PROJECT_DIR}/knots/rudins_ball.txt"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" "${VERIFIER}"

run_case() {
    local mode=$1
    local certificate="${TEST_OUTPUT_DIR}/${mode}.json"
    local log_file="${TEST_OUTPUT_DIR}/${mode}.log"

    FACETS_FILE="${FACETS}" \
    KNOT_NAME="stage5b_${mode}" \
    RANDOM_SEED=13 \
    CERTIFICATE_OUTPUT="${certificate}" \
    PROTECTED_VERTICES='' \
    PROTECTED_VERTEX_POLICY=prefer \
    STATE_ENGINE=bitset \
    NORMALIZED_COMPLEX_CACHE=true \
    NORMALIZED_CACHE_MAX_FAILURES=100000 \
    ISOMORPHISM_COMPLEX_CACHE="${mode}" \
    ISOMORPHISM_CACHE_MAX_FAILURES=100000 \
    SEARCH_STATE_LIMIT=0 \
    SEARCH_TIME_LIMIT_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1 || {
        cat "${log_file}" >&2
        return 1
    }

    grep -Fq 'FINAL_RESULT: NON_EVASIVE;' "${log_file}"
    test -s "${certificate}"
    "${SAGE_BIN}" "${VERIFIER}" "${FACETS}" "${certificate}" \
        >"${TEST_OUTPUT_DIR}/${mode}_verify.log" 2>&1 || {
        cat "${TEST_OUTPUT_DIR}/${mode}_verify.log" >&2
        return 1
    }
    grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
        "${TEST_OUTPUT_DIR}/${mode}_verify.log"
}

run_case false
run_case true

grep -Fq 'isomorphism_cache_hits=0;' "${TEST_OUTPUT_DIR}/false.log"
grep -Eq 'isomorphism_cache_hits=[1-9][0-9]*;' \
    "${TEST_OUTPUT_DIR}/true.log"
grep -Eq 'certificate_isomorphism_aliases=[1-9][0-9]*;' \
    "${TEST_OUTPUT_DIR}/true.log"

"${SAGE_BIN}" -python -c '
import json
import ast
import os
import re
import sys

(
    enabled_log,
    disabled_log,
    enabled_path,
    disabled_path,
    output_dir,
    facets_path,
) = sys.argv[1:]
sys.path.insert(0, os.path.dirname(enabled_path))
from simplicial_bitset import RootBitsetComplex

def metric(path, label):
    text = open(path, encoding="utf-8").read()
    match = re.search(rf"^{re.escape(label)}: ([0-9,]+)", text, re.MULTILINE)
    assert match, label
    return int(match.group(1).replace(",", ""))

assert metric(enabled_log, "Subcomplex cache misses") < metric(
    disabled_log, "Subcomplex cache misses"
)
assert metric(enabled_log, "Sage state materializations") < metric(
    disabled_log, "Sage state materializations"
)

with open(enabled_path, encoding="utf-8") as input_file:
    enabled = json.load(input_file)
with open(disabled_path, encoding="utf-8") as input_file:
    disabled = json.load(input_file)
assert enabled["schema_version"] == 3
assert disabled["schema_version"] == 3
assert enabled["result"] == disabled["result"] == "NON_EVASIVE"
aliases = [state for state in enabled["states"] if "isomorphic_state" in state]
assert aliases
assert all(state.get("vertex_isomorphism") is not None for state in aliases)
with open(facets_path, encoding="utf-8") as input_file:
    root_facets = ast.literal_eval(input_file.read())
model = RootBitsetComplex(
    root_facets, vertex_order=enabled["input"]["vertex_order"]
)
states = {state["id"]: state for state in enabled["states"]}
for isomorphism_alias in aliases:
    target = states[isomorphism_alias["isomorphic_state"]]
    source_facets = model.state_facets(
        int(isomorphism_alias["linked_mask"], 0),
        int(isomorphism_alias["deleted_mask"], 0),
    )
    target_facets = model.state_facets(
        int(target["linked_mask"], 0),
        int(target["deleted_mask"], 0),
    )
    assert source_facets != target_facets
alias = aliases[0]

def write_variant(name, mutate):
    document = json.loads(json.dumps(enabled))
    variant_alias = next(
        state for state in document["states"] if state["id"] == alias["id"]
    )
    mutate(document, variant_alias)
    with open(f"{output_dir}/{name}.json", "w", encoding="utf-8") as output_file:
        json.dump(document, output_file)

write_variant(
    "missing_isomorphic_target",
    lambda document, record: record.__setitem__("isomorphic_state", "Ldead-D0"),
)
write_variant(
    "missing_vertex_mapping",
    lambda document, record: record.pop("vertex_isomorphism"),
)
write_variant(
    "partial_vertex_mapping",
    lambda document, record: record["vertex_isomorphism"].pop(),
)
write_variant(
    "outside_target_vertex",
    lambda document, record: record["vertex_isomorphism"][0].__setitem__(
        "target_vertex", 999999
    ),
)
write_variant(
    "mixed_isomorphism_proof",
    lambda document, record: record.__setitem__("terminal_reason", "simplex"),
)
write_variant(
    "schema2_isomorphism",
    lambda document, record: document.__setitem__("schema_version", 2),
)
' \
    "${TEST_OUTPUT_DIR}/true.log" \
    "${TEST_OUTPUT_DIR}/false.log" \
    "${TEST_OUTPUT_DIR}/true.json" \
    "${TEST_OUTPUT_DIR}/false.json" \
    "${TEST_OUTPUT_DIR}" \
    "${FACETS}"

for corrupted in \
    missing_isomorphic_target \
    missing_vertex_mapping \
    partial_vertex_mapping \
    outside_target_vertex \
    mixed_isomorphism_proof \
    schema2_isomorphism; do
    if "${SAGE_BIN}" "${VERIFIER}" \
        "${FACETS}" "${TEST_OUTPUT_DIR}/${corrupted}.json" \
        >"${TEST_OUTPUT_DIR}/${corrupted}.log" 2>&1; then
        echo "FAIL: invalid isomorphism certificate accepted: ${corrupted}" >&2
        exit 1
    fi
    grep -Fq 'CERTIFICATE_INVALID:' \
        "${TEST_OUTPUT_DIR}/${corrupted}.log"
done

if ISOMORPHISM_CACHE_MAX_FAILURES=-1 \
    FACETS_FILE="${FACETS}" \
    KNOT_NAME=stage5b_invalid_limit \
    CERTIFICATE_OUTPUT="${TEST_OUTPUT_DIR}/invalid_limit.json" \
    "${SAGE_BIN}" "${SOLVER}" \
    >"${TEST_OUTPUT_DIR}/invalid_limit.log" 2>&1; then
    echo "FAIL: negative isomorphism-cache limit was accepted" >&2
    exit 1
fi
grep -Fq 'ISOMORPHISM_CACHE_MAX_FAILURES cannot be negative' \
    "${TEST_OUTPUT_DIR}/invalid_limit.log"

echo "PASS: isomorphism caching reduced materialized states on Rudin's ball"
echo "PASS: cache-on and cache-off conclusions independently verified"
echo "PASS: malformed isomorphism aliases were rejected"
echo "All Stage 5B tests passed."
