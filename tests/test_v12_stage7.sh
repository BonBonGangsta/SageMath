#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-stage7-XXXXXX)
trap 'rm -rf "${TEST_OUTPUT_DIR}"' EXIT

SOLVER="${TEST_OUTPUT_DIR}/knot_nonevasive_v12.sage"
VERIFIER="${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage"
FACETS="${PROJECT_DIR}/knots/rudins_ball.txt"
PROTECTED_FACETS="${PROJECT_DIR}/tests/data/protected_policy_example.txt"
CHECKPOINT="${TEST_OUTPUT_DIR}/search_checkpoint.json"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEST_OUTPUT_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEST_OUTPUT_DIR}/"

run_lexical() {
    local log_file=$1
    local certificate=$2
    local checkpoint_path=$3
    local resume=$4
    local state_limit=$5

    FACETS_FILE="${FACETS}" \
    KNOT_NAME=stage7_lexical \
    RANDOM_SEED=123456 \
    CERTIFICATE_OUTPUT="${certificate}" \
    PROTECTED_VERTICES='' \
    PROTECTED_VERTEX_POLICY=prefer \
    STATE_ENGINE=bitset \
    SEARCH_STRATEGY=lexical \
    NORMALIZED_COMPLEX_CACHE=true \
    ISOMORPHISM_COMPLEX_CACHE=false \
    AUTOMORPHISM_ORBIT_PRUNING=false \
    CHILD_AWARE_ORDERING=false \
    OBSTRUCTION_SCHEDULER=fixed \
    NONCOLLAPSIBILITY_OBSTRUCTION=false \
    HOMOLOGY_FIELD_PRIMES=2 \
    CHECKPOINT_PATH="${checkpoint_path}" \
    CHECKPOINT_RESUME="${resume}" \
    CHECKPOINT_OVERWRITE=false \
    CHECKPOINT_INTERVAL_STATES=0 \
    CHECKPOINT_INTERVAL_SECONDS=0 \
    SEARCH_STATE_LIMIT="${state_limit}" \
    SEARCH_TIME_LIMIT_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1
}

LIMITED_LOG="${TEST_OUTPUT_DIR}/limited.log"
LIMITED_CERTIFICATE="${TEST_OUTPUT_DIR}/limited.json"
run_lexical "${LIMITED_LOG}" "${LIMITED_CERTIFICATE}" \
    "${CHECKPOINT}" false 10
grep -Fq 'FINAL_RESULT: INCONCLUSIVE_RESOURCE_LIMIT;' "${LIMITED_LOG}"
grep -Fq 'resource_limit=state_limit;' "${LIMITED_LOG}"
grep -Fq 'Checkpoint written:' "${LIMITED_LOG}"
test -s "${CHECKPOINT}"
if [[ -e "${LIMITED_CERTIFICATE}" ]]; then
    echo "FAIL: limited checkpoint run emitted a certificate" >&2
    exit 1
fi

"${SAGE_BIN}" -python -c '
import hashlib
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as input_file:
    document = json.load(input_file)
checksum = document.pop("payload_sha256")
encoded = json.dumps(
    document, sort_keys=True, separators=(",", ":")
).encode("utf-8")
assert checksum == hashlib.sha256(encoded).hexdigest()
assert document["status"] == "resource_limit"
assert document["stop"]["kind"] == "state_limit"
assert document["resource_limits"]["search_state_limit"] == 10
assert document["progress"]["states"]
assert document["progress"]["total_subcomplexes_examined"] == 10
' "${CHECKPOINT}"

RESUMED_LOG="${TEST_OUTPUT_DIR}/resumed.log"
RESUMED_CERTIFICATE="${TEST_OUTPUT_DIR}/resumed.json"
run_lexical "${RESUMED_LOG}" "${RESUMED_CERTIFICATE}" \
    "${CHECKPOINT}" true 0
grep -Fq 'FINAL_RESULT: NON_EVASIVE;' "${RESUMED_LOG}"
grep -Eq 'checkpoint_loaded_states=[1-9][0-9]*;' "${RESUMED_LOG}"
grep -Fq 'checkpoint_resume_count=1;' "${RESUMED_LOG}"
"${SAGE_BIN}" "${VERIFIER}" "${FACETS}" "${RESUMED_CERTIFICATE}" \
    >"${TEST_OUTPUT_DIR}/resumed_verify.log" 2>&1
grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
    "${TEST_OUTPUT_DIR}/resumed_verify.log"

FULL_LOG="${TEST_OUTPUT_DIR}/full.log"
FULL_CERTIFICATE="${TEST_OUTPUT_DIR}/full.json"
run_lexical "${FULL_LOG}" "${FULL_CERTIFICATE}" '' false 0
grep -Fq 'FINAL_RESULT: NON_EVASIVE;' "${FULL_LOG}"
"${SAGE_BIN}" "${VERIFIER}" "${FACETS}" "${FULL_CERTIFICATE}" \
    >"${TEST_OUTPUT_DIR}/full_verify.log" 2>&1
grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
    "${TEST_OUTPUT_DIR}/full_verify.log"

"${SAGE_BIN}" -python -c '
import json
import re
import sys

resumed_certificate, full_certificate, resumed_log, full_log = sys.argv[1:]
with open(resumed_certificate, encoding="utf-8") as input_file:
    resumed = json.load(input_file)
with open(full_certificate, encoding="utf-8") as input_file:
    full = json.load(input_file)
assert resumed["result"] == full["result"] == "NON_EVASIVE"
assert resumed["states"] == full["states"]

def misses(path):
    text = open(path, encoding="utf-8").read()
    match = re.search(r"^Subcomplex cache misses: ([0-9,]+)", text, re.M)
    assert match
    return int(match.group(1).replace(",", ""))

assert misses(resumed_log) < misses(full_log)
' "${RESUMED_CERTIFICATE}" "${FULL_CERTIFICATE}" \
    "${RESUMED_LOG}" "${FULL_LOG}"

COMPLETED_LOG="${TEST_OUTPUT_DIR}/completed_resume.log"
COMPLETED_CERTIFICATE="${TEST_OUTPUT_DIR}/completed_resume.json"
run_lexical "${COMPLETED_LOG}" "${COMPLETED_CERTIFICATE}" \
    "${CHECKPOINT}" true 0
grep -Fq 'FINAL_RESULT: NON_EVASIVE;' "${COMPLETED_LOG}"
grep -Fq 'Subcomplex cache misses: 0' "${COMPLETED_LOG}"
"${SAGE_BIN}" "${VERIFIER}" "${FACETS}" "${COMPLETED_CERTIFICATE}" \
    >"${TEST_OUTPUT_DIR}/completed_verify.log" 2>&1
grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
    "${TEST_OUTPUT_DIR}/completed_verify.log"

SIGNAL_CHECKPOINT="${TEST_OUTPUT_DIR}/signal_checkpoint.json"
SIGNAL_LOG="${TEST_OUTPUT_DIR}/signal_interrupted.log"
SIGNAL_CERTIFICATE="${TEST_OUTPUT_DIR}/signal_interrupted.json"
FACETS_FILE="${FACETS}" \
KNOT_NAME=stage7_signal \
RANDOM_SEED=123456 \
SEARCH_STRATEGY=lexical \
CERTIFICATE_OUTPUT="${SIGNAL_CERTIFICATE}" \
CHECKPOINT_PATH="${SIGNAL_CHECKPOINT}" \
CHECKPOINT_INTERVAL_STATES=0 \
CHECKPOINT_INTERVAL_SECONDS=0 \
"${SAGE_BIN}" "${SOLVER}" >"${SIGNAL_LOG}" 2>&1 &
solver_pid=$!
signal_sent=false
for _attempt in {1..1000}; do
    if grep -Fq '"phase": "root_homology_zz"' \
        "${SIGNAL_LOG}" 2>/dev/null; then
        kill -TERM "${solver_pid}"
        signal_sent=true
        break
    fi
    if ! kill -0 "${solver_pid}" 2>/dev/null; then
        break
    fi
    sleep 0.005
done
wait "${solver_pid}"
if [[ "${signal_sent}" != true ]]; then
    echo "FAIL: signal-interruption test could not reach root homology" >&2
    exit 1
fi
grep -Fq 'FINAL_RESULT: INCONCLUSIVE_INTERRUPTED;' "${SIGNAL_LOG}"
grep -Fq 'resource_limit=interruption_signal;' "${SIGNAL_LOG}"
if [[ -e "${SIGNAL_CERTIFICATE}" ]]; then
    echo "FAIL: interrupted search emitted a certificate" >&2
    exit 1
fi
"${SAGE_BIN}" -python -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as input_file:
    document = json.load(input_file)
assert document["status"] == "interrupted"
assert document["stop"] == {
    "kind": "interruption_signal",
    "signal": "SIGTERM",
}
' "${SIGNAL_CHECKPOINT}"

SIGNAL_RESUMED_LOG="${TEST_OUTPUT_DIR}/signal_resumed.log"
SIGNAL_RESUMED_CERTIFICATE="${TEST_OUTPUT_DIR}/signal_resumed.json"
run_lexical "${SIGNAL_RESUMED_LOG}" "${SIGNAL_RESUMED_CERTIFICATE}" \
    "${SIGNAL_CHECKPOINT}" true 0
grep -Fq 'FINAL_RESULT: NON_EVASIVE;' "${SIGNAL_RESUMED_LOG}"
"${SAGE_BIN}" "${VERIFIER}" "${FACETS}" \
    "${SIGNAL_RESUMED_CERTIFICATE}" \
    >"${TEST_OUTPUT_DIR}/signal_resumed_verify.log" 2>&1
grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
    "${TEST_OUTPUT_DIR}/signal_resumed_verify.log"
"${SAGE_BIN}" -python -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as input_file:
    resumed = json.load(input_file)
with open(sys.argv[2], encoding="utf-8") as input_file:
    uninterrupted = json.load(input_file)
assert resumed["states"] == uninterrupted["states"]
' "${SIGNAL_RESUMED_CERTIFICATE}" "${FULL_CERTIFICATE}"

if run_lexical "${TEST_OUTPUT_DIR}/overwrite_refused.log" \
    "${TEST_OUTPUT_DIR}/overwrite_refused.json" "${CHECKPOINT}" false 0; then
    echo "FAIL: checkpoint was overwritten without explicit permission" >&2
    exit 1
fi
grep -Fq 'Checkpoint already exists;' \
    "${TEST_OUTPUT_DIR}/overwrite_refused.log"

cp "${CHECKPOINT}" "${TEST_OUTPUT_DIR}/config_mismatch.json"
if FACETS_FILE="${FACETS}" \
    RANDOM_SEED=123456 \
    SEARCH_STRATEGY=reverse_lexical \
    CHECKPOINT_PATH="${TEST_OUTPUT_DIR}/config_mismatch.json" \
    CHECKPOINT_RESUME=true \
    "${SAGE_BIN}" "${SOLVER}" \
    >"${TEST_OUTPUT_DIR}/config_mismatch.log" 2>&1; then
    echo "FAIL: checkpoint accepted changed search configuration" >&2
    exit 1
fi
grep -Fq 'Checkpoint search configuration does not match: search_strategy' \
    "${TEST_OUTPUT_DIR}/config_mismatch.log"

cp "${CHECKPOINT}" "${TEST_OUTPUT_DIR}/input_mismatch.json"
if FACETS_FILE="${PROJECT_DIR}/tests/data/simplex.txt" \
    RANDOM_SEED=123456 \
    SEARCH_STRATEGY=lexical \
    CHECKPOINT_PATH="${TEST_OUTPUT_DIR}/input_mismatch.json" \
    CHECKPOINT_RESUME=true \
    "${SAGE_BIN}" "${SOLVER}" \
    >"${TEST_OUTPUT_DIR}/input_mismatch.log" 2>&1; then
    echo "FAIL: checkpoint accepted a different input complex" >&2
    exit 1
fi
grep -Fq 'Checkpoint input complex does not match' \
    "${TEST_OUTPUT_DIR}/input_mismatch.log"

cp "${CHECKPOINT}" "${TEST_OUTPUT_DIR}/implementation_mismatch.json"
"${SAGE_BIN}" -python -c '
import hashlib
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as input_file:
    document = json.load(input_file)
document["implementation"]["source_sha256"]["solver"] = "0" * 64
payload = {
    key: value for key, value in document.items()
    if key != "payload_sha256"
}
encoded = json.dumps(
    payload, sort_keys=True, separators=(",", ":")
).encode("utf-8")
document["payload_sha256"] = hashlib.sha256(encoded).hexdigest()
with open(path, "w", encoding="utf-8") as output_file:
    json.dump(document, output_file)
' "${TEST_OUTPUT_DIR}/implementation_mismatch.json"

if FACETS_FILE="${FACETS}" \
    RANDOM_SEED=123456 \
    SEARCH_STRATEGY=lexical \
    CHECKPOINT_PATH="${TEST_OUTPUT_DIR}/implementation_mismatch.json" \
    CHECKPOINT_RESUME=true \
    "${SAGE_BIN}" "${SOLVER}" \
    >"${TEST_OUTPUT_DIR}/implementation_mismatch.log" 2>&1; then
    echo "FAIL: checkpoint accepted a different implementation hash" >&2
    exit 1
fi
grep -Fq 'Checkpoint implementation hash does not match' \
    "${TEST_OUTPUT_DIR}/implementation_mismatch.log"

cp "${CHECKPOINT}" "${TEST_OUTPUT_DIR}/corrupt_checksum.json"
"${SAGE_BIN}" -python -c '
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as input_file:
    document = json.load(input_file)
document["status"] = "running"
with open(path, "w", encoding="utf-8") as output_file:
    json.dump(document, output_file)
' "${TEST_OUTPUT_DIR}/corrupt_checksum.json"

if FACETS_FILE="${FACETS}" \
    RANDOM_SEED=123456 \
    SEARCH_STRATEGY=lexical \
    CHECKPOINT_PATH="${TEST_OUTPUT_DIR}/corrupt_checksum.json" \
    CHECKPOINT_RESUME=true \
    "${SAGE_BIN}" "${SOLVER}" \
    >"${TEST_OUTPUT_DIR}/corrupt_checksum.log" 2>&1; then
    echo "FAIL: checkpoint with a corrupt checksum was accepted" >&2
    exit 1
fi
grep -Fq 'Checkpoint payload checksum does not match' \
    "${TEST_OUTPUT_DIR}/corrupt_checksum.log"

STRICT_CHECKPOINT="${TEST_OUTPUT_DIR}/strict_checkpoint.json"
for run_name in strict_initial strict_resumed; do
    resume=false
    if [[ "${run_name}" == strict_resumed ]]; then
        resume=true
    fi
    FACETS_FILE="${PROTECTED_FACETS}" \
    KNOT_NAME="stage7_${run_name}" \
    RANDOM_SEED=123456 \
    CERTIFICATE_OUTPUT="${TEST_OUTPUT_DIR}/${run_name}.json" \
    PROTECTED_VERTICES='[1, 2, 3]' \
    PROTECTED_VERTEX_POLICY=restrict \
    CHECKPOINT_PATH="${STRICT_CHECKPOINT}" \
    CHECKPOINT_RESUME="${resume}" \
    CHECKPOINT_INTERVAL_STATES=0 \
    CHECKPOINT_INTERVAL_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" \
        >"${TEST_OUTPUT_DIR}/${run_name}.log" 2>&1
    grep -Fq 'FINAL_RESULT: INCONCLUSIVE_RESTRICTED;' \
        "${TEST_OUTPUT_DIR}/${run_name}.log"
done
grep -Fq 'Subcomplex cache misses: 0' \
    "${TEST_OUTPUT_DIR}/strict_resumed.log"

ISOMORPHISM_CHECKPOINT="${TEST_OUTPUT_DIR}/isomorphism_checkpoint.json"
for run_name in isomorphism_initial isomorphism_resumed; do
    resume=false
    if [[ "${run_name}" == isomorphism_resumed ]]; then
        resume=true
    fi
    FACETS_FILE="${FACETS}" \
    KNOT_NAME="stage7_${run_name}" \
    RANDOM_SEED=13 \
    CERTIFICATE_OUTPUT="${TEST_OUTPUT_DIR}/${run_name}.json" \
    NORMALIZED_COMPLEX_CACHE=true \
    ISOMORPHISM_COMPLEX_CACHE=true \
    AUTOMORPHISM_ORBIT_PRUNING=false \
    CHECKPOINT_PATH="${ISOMORPHISM_CHECKPOINT}" \
    CHECKPOINT_RESUME="${resume}" \
    CHECKPOINT_INTERVAL_STATES=0 \
    CHECKPOINT_INTERVAL_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" \
        >"${TEST_OUTPUT_DIR}/${run_name}.log" 2>&1
    grep -Fq 'FINAL_RESULT: NON_EVASIVE;' \
        "${TEST_OUTPUT_DIR}/${run_name}.log"
done
grep -Fq 'Subcomplex cache misses: 0' \
    "${TEST_OUTPUT_DIR}/isomorphism_resumed.log"
"${SAGE_BIN}" "${VERIFIER}" "${FACETS}" \
    "${TEST_OUTPUT_DIR}/isomorphism_resumed.json" \
    >"${TEST_OUTPUT_DIR}/isomorphism_resumed_verify.log" 2>&1
grep -Fq 'CERTIFICATE_VALID: NON_EVASIVE;' \
    "${TEST_OUTPUT_DIR}/isomorphism_resumed_verify.log"

ORBIT_FACETS="${PROJECT_DIR}/tests/data/acyclic_evasive_suspension.txt"
ORBIT_CHECKPOINT="${TEST_OUTPUT_DIR}/orbit_checkpoint.json"
for run_name in orbit_initial orbit_resumed; do
    resume=false
    if [[ "${run_name}" == orbit_resumed ]]; then
        resume=true
    fi
    FACETS_FILE="${ORBIT_FACETS}" \
    KNOT_NAME="stage7_${run_name}" \
    RANDOM_SEED=45 \
    CERTIFICATE_OUTPUT="${TEST_OUTPUT_DIR}/${run_name}.json" \
    NORMALIZED_COMPLEX_CACHE=false \
    ISOMORPHISM_COMPLEX_CACHE=false \
    AUTOMORPHISM_ORBIT_PRUNING=true \
    CHECKPOINT_PATH="${ORBIT_CHECKPOINT}" \
    CHECKPOINT_RESUME="${resume}" \
    CHECKPOINT_INTERVAL_STATES=0 \
    CHECKPOINT_INTERVAL_SECONDS=0 \
    "${SAGE_BIN}" "${SOLVER}" \
        >"${TEST_OUTPUT_DIR}/${run_name}.log" 2>&1
    grep -Fq 'FINAL_RESULT: EVASIVE_CERTIFIED;' \
        "${TEST_OUTPUT_DIR}/${run_name}.log"
done
grep -Fq 'Subcomplex cache misses: 0' \
    "${TEST_OUTPUT_DIR}/orbit_resumed.log"
"${SAGE_BIN}" "${VERIFIER}" "${ORBIT_FACETS}" \
    "${TEST_OUTPUT_DIR}/orbit_resumed.json" \
    >"${TEST_OUTPUT_DIR}/orbit_resumed_verify.log" 2>&1
grep -Fq 'CERTIFICATE_VALID: EVASIVE_CERTIFIED;' \
    "${TEST_OUTPUT_DIR}/orbit_resumed_verify.log"

for invalid_case in resume_without_path conflicting_mode states seconds; do
    checkpoint_path=''
    resume=false
    overwrite=false
    interval_states=1000
    interval_seconds=300
    expected_message=''
    case "${invalid_case}" in
        resume_without_path)
            resume=true
            expected_message='CHECKPOINT_RESUME requires CHECKPOINT_PATH'
            ;;
        conflicting_mode)
            checkpoint_path="${CHECKPOINT}"
            resume=true
            overwrite=true
            expected_message='CHECKPOINT_OVERWRITE and CHECKPOINT_RESUME cannot both be true'
            ;;
        states)
            interval_states=-1
            expected_message='CHECKPOINT_INTERVAL_STATES cannot be negative'
            ;;
        seconds)
            interval_seconds=nan
            expected_message='CHECKPOINT_INTERVAL_SECONDS must be a finite nonnegative number'
            ;;
    esac
    if FACETS_FILE="${PROJECT_DIR}/tests/data/simplex.txt" \
        CHECKPOINT_PATH="${checkpoint_path}" \
        CHECKPOINT_RESUME="${resume}" \
        CHECKPOINT_OVERWRITE="${overwrite}" \
        CHECKPOINT_INTERVAL_STATES="${interval_states}" \
        CHECKPOINT_INTERVAL_SECONDS="${interval_seconds}" \
        "${SAGE_BIN}" "${SOLVER}" \
        >"${TEST_OUTPUT_DIR}/invalid_${invalid_case}.log" 2>&1; then
        echo "FAIL: invalid checkpoint setting accepted: ${invalid_case}" >&2
        exit 1
    fi
    grep -Fq "${expected_message}" \
        "${TEST_OUTPUT_DIR}/invalid_${invalid_case}.log"
done

echo "PASS: bounded resume matched the uninterrupted verified certificate"
echo "PASS: SIGTERM produced a distinct resumable interruption checkpoint"
echo "PASS: completed and strict-policy checkpoints resumed correctly"
echo "PASS: equivalence, isomorphism, and orbit proof records survived resume"
echo "PASS: stale input, configuration, implementation, and checksum were rejected"
echo "PASS: checkpoint overwrite protection and setting validation passed"
echo "All Stage 7 tests passed."
