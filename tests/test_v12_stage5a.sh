#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage5a-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${TEST_OUTPUT_DIR}/verify_nonevasive_certificate.sage"
FACETS="${PROJECT_DIR}/tests/data/acyclic_evasive_suspension.txt"
POSITIVE_FACETS="${PROJECT_DIR}/knots/rudins_ball.txt"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" "${VERIFIER}"

run_case() {
    local mode=$1
    local certificate="${TEST_OUTPUT_DIR}/${mode}.json"
    local log_file="${TEST_OUTPUT_DIR}/${mode}.log"

    FACETS_FILE="${FACETS}" \
    KNOT_NAME="stage5a_${mode}" \
    RANDOM_SEED=45 \
    CERTIFICATE_OUTPUT="${certificate}" \
    PROTECTED_VERTICES='' \
    PROTECTED_VERTEX_POLICY=prefer \
    STATE_ENGINE=bitset \
    NORMALIZED_COMPLEX_CACHE="${mode}" \
    NORMALIZED_CACHE_MAX_FAILURES=100000 \
    SEARCH_STATE_LIMIT=0 \
    SEARCH_TIME_LIMIT_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1 || {
        cat "${log_file}" >&2
        return 1
    }

    grep -Fq 'FINAL_RESULT: EVASIVE_CERTIFIED;' "${log_file}"
    test -s "${certificate}"
    "${SAGE_BIN}" "${VERIFIER}" "${FACETS}" "${certificate}" \
        >"${TEST_OUTPUT_DIR}/${mode}_verify.log" 2>&1 || {
        cat "${TEST_OUTPUT_DIR}/${mode}_verify.log" >&2
        return 1
    }
    grep -Fq 'CERTIFICATE_VALID: EVASIVE_CERTIFIED;' \
        "${TEST_OUTPUT_DIR}/${mode}_verify.log"
}

run_case true
run_case false

POSITIVE_CERTIFICATE="${TEST_OUTPUT_DIR}/positive_alias.json"
POSITIVE_LOG="${TEST_OUTPUT_DIR}/positive_alias.log"
FACETS_FILE="${POSITIVE_FACETS}" \
KNOT_NAME="stage5a_positive_alias" \
RANDOM_SEED=13 \
CERTIFICATE_OUTPUT="${POSITIVE_CERTIFICATE}" \
PROTECTED_VERTICES='' \
PROTECTED_VERTEX_POLICY=prefer \
STATE_ENGINE=bitset \
NORMALIZED_COMPLEX_CACHE=true \
NORMALIZED_CACHE_MAX_FAILURES=100000 \
SEARCH_STATE_LIMIT=0 \
SEARCH_TIME_LIMIT_SECONDS=0 \
"${SAGE_BIN}" "${SOLVER}" >"${POSITIVE_LOG}" 2>&1 || {
    cat "${POSITIVE_LOG}" >&2
    exit 1
}
grep -Fq 'FINAL_RESULT: NON_EVASIVE;' "${POSITIVE_LOG}"
grep -Fq 'normalized_cache_hits=1;' "${POSITIVE_LOG}"
grep -Fq 'certificate_equivalence_aliases=1;' "${POSITIVE_LOG}"
"${SAGE_BIN}" "${VERIFIER}" \
    "${POSITIVE_FACETS}" "${POSITIVE_CERTIFICATE}" \
    >"${TEST_OUTPUT_DIR}/positive_alias_verify.log" 2>&1 || {
    cat "${TEST_OUTPUT_DIR}/positive_alias_verify.log" >&2
    exit 1
}
grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
    "${TEST_OUTPUT_DIR}/positive_alias_verify.log"
"${SAGE_BIN}" -python -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as input_file:
    document = json.load(input_file)
aliases = [state for state in document["states"] if "equivalent_state" in state]
assert document["schema_version"] == 4
assert len(aliases) == 1
assert all(state["verdict"] == "NON_EVASIVE" for state in aliases)
' "${POSITIVE_CERTIFICATE}"

grep -Fq 'normalized_cache_hits=1;' "${TEST_OUTPUT_DIR}/true.log"
grep -Fq 'certificate_equivalence_aliases=1;' "${TEST_OUTPUT_DIR}/true.log"
grep -Fq 'Subcomplex cache misses: 16' "${TEST_OUTPUT_DIR}/true.log"
grep -Fq 'Sage state materializations: 16' "${TEST_OUTPUT_DIR}/true.log"

grep -Fq 'normalized_cache_hits=0;' "${TEST_OUTPUT_DIR}/false.log"
grep -Fq 'certificate_equivalence_aliases=0;' "${TEST_OUTPUT_DIR}/false.log"

"${SAGE_BIN}" -python -c '
import re
import sys

enabled_log, disabled_log = sys.argv[1:]
def metric(path, label):
    text = open(path, encoding="utf-8").read()
    match = re.search(rf"^{re.escape(label)}: ([0-9,]+)$", text, re.MULTILINE)
    assert match, label
    return int(match.group(1).replace(",", ""))

enabled_misses = metric(enabled_log, "Subcomplex cache misses")
disabled_misses = metric(disabled_log, "Subcomplex cache misses")
enabled_materializations = metric(enabled_log, "Sage state materializations")
disabled_materializations = metric(disabled_log, "Sage state materializations")
assert enabled_misses == enabled_materializations == 16
assert disabled_misses == disabled_materializations == 24
' "${TEST_OUTPUT_DIR}/true.log" "${TEST_OUTPUT_DIR}/false.log"

"${SAGE_BIN}" -python -c '
import json
import sys

enabled_path, disabled_path, output_dir = sys.argv[1:]
with open(enabled_path, encoding="utf-8") as input_file:
    enabled = json.load(input_file)
with open(disabled_path, encoding="utf-8") as input_file:
    disabled = json.load(input_file)
assert enabled["schema_version"] == 4
assert disabled["schema_version"] == 4
assert enabled["result"] == disabled["result"] == "EVASIVE_CERTIFIED"
aliases = [state for state in enabled["states"] if "equivalent_state" in state]
assert len(aliases) == 1
assert not any("equivalent_state" in state for state in disabled["states"])
alias = aliases[0]

def write_variant(name, mutate):
    document = json.loads(json.dumps(enabled))
    variant_alias = next(
        state for state in document["states"]
        if state["id"] == alias["id"]
    )
    mutate(document, variant_alias)
    with open(f"{output_dir}/{name}.json", "w", encoding="utf-8") as output_file:
        json.dump(document, output_file)

write_variant(
    "missing_alias_target",
    lambda document, record: record.__setitem__(
        "equivalent_state", "Ldead-D0"
    ),
)

def use_nonidentical_target(document, record):
    original_target = record["equivalent_state"]
    replacement = next(
        state["id"] for state in document["states"]
        if state["id"] not in {
            record["id"], original_target, document["root_state"]
        }
        and "terminal_reason" in state
    )
    record["equivalent_state"] = replacement

write_variant("nonidentical_alias_target", use_nonidentical_target)
write_variant(
    "mixed_alias_proof",
    lambda document, record: record.__setitem__(
        "terminal_reason", "empty_complex"
    ),
)
write_variant(
    "schema1_alias",
    lambda document, record: document.__setitem__("schema_version", 1),
)

disabled["schema_version"] = 1
with open(f"{output_dir}/legacy_schema1.json", "w", encoding="utf-8") as output_file:
    json.dump(disabled, output_file)

enabled["schema_version"] = 2
with open(f"{output_dir}/legacy_schema2.json", "w", encoding="utf-8") as output_file:
    json.dump(enabled, output_file)
' \
    "${TEST_OUTPUT_DIR}/true.json" \
    "${TEST_OUTPUT_DIR}/false.json" \
    "${TEST_OUTPUT_DIR}"

for corrupted in \
    missing_alias_target \
    nonidentical_alias_target \
    mixed_alias_proof \
    schema1_alias; do
    if "${SAGE_BIN}" "${VERIFIER}" \
        "${FACETS}" "${TEST_OUTPUT_DIR}/${corrupted}.json" \
        >"${TEST_OUTPUT_DIR}/${corrupted}.log" 2>&1; then
        echo "FAIL: invalid equivalence certificate accepted: ${corrupted}" >&2
        exit 1
    fi
    grep -Fq 'CERTIFICATE_INVALID:' \
        "${TEST_OUTPUT_DIR}/${corrupted}.log"
done

"${SAGE_BIN}" "${VERIFIER}" \
    "${FACETS}" "${TEST_OUTPUT_DIR}/legacy_schema1.json" \
    >"${TEST_OUTPUT_DIR}/legacy_schema1.log" 2>&1 || {
    cat "${TEST_OUTPUT_DIR}/legacy_schema1.log" >&2
    exit 1
}
grep -Fq 'CERTIFICATE_VALID: EVASIVE_CERTIFIED;' \
    "${TEST_OUTPUT_DIR}/legacy_schema1.log"

"${SAGE_BIN}" "${VERIFIER}" \
    "${FACETS}" "${TEST_OUTPUT_DIR}/legacy_schema2.json" \
    >"${TEST_OUTPUT_DIR}/legacy_schema2.log" 2>&1 || {
    cat "${TEST_OUTPUT_DIR}/legacy_schema2.log" >&2
    exit 1
}
grep -Fq 'CERTIFICATE_VALID: EVASIVE_CERTIFIED;' \
    "${TEST_OUTPUT_DIR}/legacy_schema2.log"

echo "PASS: normalized cache strictly reduced Sage materializations"
echo "PASS: positive and negative equivalence certificates verified"
echo "PASS: cache-on and cache-off conclusions independently verified"
echo "PASS: malformed equivalence aliases were rejected"
echo "PASS: alias-free schema-1 certificates remain supported"
echo "PASS: schema-2 equivalence certificates remain supported"
echo "All Stage 5A tests passed."
