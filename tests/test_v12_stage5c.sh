#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

"${SAGE_BIN}" "${PROJECT_DIR}/tests/test_v12_stage5c.sage"

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage5c-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${TEST_OUTPUT_DIR}/verify_nonevasive_certificate.sage"
FACETS="${PROJECT_DIR}/tests/data/acyclic_evasive_suspension.txt"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" "${VERIFIER}"

run_case() {
    local mode=$1
    local certificate="${TEST_OUTPUT_DIR}/${mode}.json"
    local log_file="${TEST_OUTPUT_DIR}/${mode}.log"

    FACETS_FILE="${FACETS}" \
    KNOT_NAME="stage5c_${mode}" \
    RANDOM_SEED=45 \
    CERTIFICATE_OUTPUT="${certificate}" \
    PROTECTED_VERTICES='' \
    PROTECTED_VERTEX_POLICY=prefer \
    STATE_ENGINE=bitset \
    NORMALIZED_COMPLEX_CACHE=false \
    ISOMORPHISM_COMPLEX_CACHE=false \
    AUTOMORPHISM_ORBIT_PRUNING="${mode}" \
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

run_case false
run_case true

grep -Fq 'automorphism_vertices_pruned=0;' "${TEST_OUTPUT_DIR}/false.log"
grep -Eq 'automorphism_vertices_pruned=[1-9][0-9]*;' \
    "${TEST_OUTPUT_DIR}/true.log"
grep -Eq 'certificate_orbit_automorphisms=[1-9][0-9]*;' \
    "${TEST_OUTPUT_DIR}/true.log"

"${SAGE_BIN}" -python -c '
import json
import re
import sys

enabled_log, disabled_log, enabled_path, disabled_path, output_dir = sys.argv[1:]

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
assert metric(enabled_log, "Vertex attempts") < metric(
    disabled_log, "Vertex attempts"
)

with open(enabled_path, encoding="utf-8") as input_file:
    enabled = json.load(input_file)
with open(disabled_path, encoding="utf-8") as input_file:
    disabled = json.load(input_file)
assert enabled["schema_version"] == 4
assert disabled["schema_version"] == 4
assert enabled["result"] == disabled["result"] == "EVASIVE_CERTIFIED"

orbit_locations = []
for state in enabled["states"]:
    for failure in state.get("failed_children", []):
        if len(failure.get("orbit_members", [])) > 1:
            orbit_locations.append((state["id"], failure["vertex"]))
assert orbit_locations
state_id, representative = orbit_locations[0]

def locate(document):
    state = next(state for state in document["states"] if state["id"] == state_id)
    return next(
        failure
        for failure in state["failed_children"]
        if failure["vertex"] == representative
    )

def write_variant(name, mutate):
    document = json.loads(json.dumps(enabled))
    mutate(document, locate(document))
    with open(f"{output_dir}/{name}.json", "w", encoding="utf-8") as output_file:
        json.dump(document, output_file)

write_variant(
    "missing_orbit_members",
    lambda document, failure: failure.pop("orbit_members"),
)
write_variant(
    "missing_orbit_automorphism",
    lambda document, failure: failure["orbit_automorphisms"].pop(),
)
write_variant(
    "outside_orbit_target",
    lambda document, failure: failure["orbit_automorphisms"][0].__setitem__(
        "target_vertex", 999999
    ),
)

def replace_with_identity(document, failure):
    item = failure["orbit_automorphisms"][0]
    item["vertex_isomorphism"] = [
        {"source_vertex": vertex, "target_vertex": vertex}
        for vertex in sorted(
            entry["source_vertex"] for entry in item["vertex_isomorphism"]
        )
    ]

write_variant("wrong_representative_image", replace_with_identity)

def break_bijection(document, failure):
    mapping = failure["orbit_automorphisms"][0]["vertex_isomorphism"]
    mapping[0]["target_vertex"] = 999999

write_variant("broken_orbit_bijection", break_bijection)
write_variant(
    "schema3_orbit",
    lambda document, failure: document.__setitem__("schema_version", 3),
)

disabled["schema_version"] = 3
with open(f"{output_dir}/legacy_schema3.json", "w", encoding="utf-8") as output_file:
    json.dump(disabled, output_file)
' \
    "${TEST_OUTPUT_DIR}/true.log" \
    "${TEST_OUTPUT_DIR}/false.log" \
    "${TEST_OUTPUT_DIR}/true.json" \
    "${TEST_OUTPUT_DIR}/false.json" \
    "${TEST_OUTPUT_DIR}"

for corrupted in \
    missing_orbit_members \
    missing_orbit_automorphism \
    outside_orbit_target \
    wrong_representative_image \
    broken_orbit_bijection \
    schema3_orbit; do
    if "${SAGE_BIN}" "${VERIFIER}" \
        "${FACETS}" "${TEST_OUTPUT_DIR}/${corrupted}.json" \
        >"${TEST_OUTPUT_DIR}/${corrupted}.log" 2>&1; then
        echo "FAIL: invalid orbit certificate accepted: ${corrupted}" >&2
        exit 1
    fi
    grep -Fq 'CERTIFICATE_INVALID:' \
        "${TEST_OUTPUT_DIR}/${corrupted}.log"
done

"${SAGE_BIN}" "${VERIFIER}" \
    "${FACETS}" "${TEST_OUTPUT_DIR}/legacy_schema3.json" \
    >"${TEST_OUTPUT_DIR}/legacy_schema3.log" 2>&1 || {
    cat "${TEST_OUTPUT_DIR}/legacy_schema3.log" >&2
    exit 1
}
grep -Fq 'CERTIFICATE_VALID: EVASIVE_CERTIFIED;' \
    "${TEST_OUTPUT_DIR}/legacy_schema3.log"

echo "PASS: orbit pruning reduced the symmetric evasive search"
echo "PASS: orbit-on and orbit-off conclusions independently verified"
echo "PASS: malformed orbit justifications were rejected"
echo "PASS: orbit-free schema-3 certificates remain supported"
echo "All Stage 5C tests passed."
