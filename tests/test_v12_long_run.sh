#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

TEST_OUTPUT_DIR=$(mktemp -d /tmp/nonevasive-v12-long-run-XXXXXX)
WRAPPER_JOB_NAME="v12_long_run_wrapper_probe_$$"
trap 'rm -rf "${TEST_OUTPUT_DIR}"; rm -f "${PROJECT_DIR}/outputs/${WRAPPER_JOB_NAME}.log"' EXIT

"${SAGE_BIN}" "${PROJECT_DIR}/tests/test_v12_long_run.sage" \
    >"${TEST_OUTPUT_DIR}/cache.log" 2>&1 || {
        cat "${TEST_OUTPUT_DIR}/cache.log" >&2
        exit 1
    }
cat "${TEST_OUTPUT_DIR}/cache.log"

# Exercise the wrapper with fake docker/curl executables. This verifies that a
# caller-provided seed and the daily heartbeat setting actually reach the
# docker-compose argument list without starting a container or notification.
FAKE_BIN="${TEST_OUTPUT_DIR}/fake-bin"
mkdir -p "${FAKE_BIN}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$@" >"${WRAPPER_CAPTURE:?}"' \
    'printf "fake docker completed\n"' \
    >"${FAKE_BIN}/docker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${FAKE_BIN}/curl"
chmod +x "${FAKE_BIN}/docker" "${FAKE_BIN}/curl"

PATH="${FAKE_BIN}:${PATH}" \
WRAPPER_CAPTURE="${TEST_OUTPUT_DIR}/wrapper_args.txt" \
NTFY_URL=http://notifications.invalid \
NTFY_TOPIC=v12-test \
RANDOM_SEED=987654321 \
HEARTBEAT_INTERVAL_SECONDS=86400 \
SEARCH_MEMORY_LIMIT_MIB=18432 \
bash "${PROJECT_DIR}/run_sage_and_notify.sh" \
    "${WRAPPER_JOB_NAME}" \
    "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" \
    "${PROJECT_DIR}/tests/data/point.txt" \
    >"${TEST_OUTPUT_DIR}/wrapper.log" 2>&1
grep -Fxq 'RANDOM_SEED=987654321' \
    "${TEST_OUTPUT_DIR}/wrapper_args.txt"
grep -Fxq 'HEARTBEAT_INTERVAL_SECONDS=86400' \
    "${TEST_OUTPUT_DIR}/wrapper_args.txt"
grep -Fxq 'SEARCH_MEMORY_LIMIT_MIB=18432' \
    "${TEST_OUTPUT_DIR}/wrapper_args.txt"

# Exercise fresh and resumed batch environments with a fake runner.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'capture="${BATCH_CAPTURE_DIR:?}/${CHECKPOINT_RESUME:?}.txt"' \
    '{' \
    '  printf "name=%s\n" "$1"' \
    '  printf "seed=%s\n" "${RANDOM_SEED:-}"' \
    '  printf "heartbeat=%s\n" "${HEARTBEAT_INTERVAL_SECONDS:-}"' \
    '  printf "checkpoint=%s\n" "${CHECKPOINT_PATH:-}"' \
    '  printf "resume=%s\n" "${CHECKPOINT_RESUME:-}"' \
    '  printf "checkpoint_states=%s\n" "${CHECKPOINT_INTERVAL_STATES:-}"' \
    '  printf "checkpoint_seconds=%s\n" "${CHECKPOINT_INTERVAL_SECONDS:-}"' \
    '  printf "state_limit=%s\n" "${SEARCH_STATE_LIMIT:-}"' \
    '  printf "time_limit=%s\n" "${SEARCH_TIME_LIMIT_SECONDS:-}"' \
    '  printf "memory_limit=%s\n" "${SEARCH_MEMORY_LIMIT_MIB:-}"' \
    '} >"${capture}"' \
    >"${TEST_OUTPUT_DIR}/fake-runner.sh"
chmod +x "${TEST_OUTPUT_DIR}/fake-runner.sh"
mkdir -p "${TEST_OUTPUT_DIR}/batch/outputs" \
    "${TEST_OUTPUT_DIR}/batch-captures"
printf '%s\n' \
    'ID,KNOT,SCRIPT_PATH,FACET_FILE,RANDOM_SEED' \
    '06,sdB_15_66,scripts/knot_nonevasive_v12.sage,knots/sdB_15_66.txt,24681357' \
    >"${TEST_OUTPUT_DIR}/batch/jobs.csv"

run_batch_and_wait() {
    local expected_resume=$1
    (
        cd "${TEST_OUTPUT_DIR}/batch"
        BATCH_RUNNER_SCRIPT="${TEST_OUTPUT_DIR}/fake-runner.sh" \
        BATCH_CAPTURE_DIR="${TEST_OUTPUT_DIR}/batch-captures" \
        bash "${PROJECT_DIR}/scripts/batch_calculations.sh" jobs.csv
    )
    for _attempt in {1..100}; do
        if [[ -s "${TEST_OUTPUT_DIR}/batch-captures/${expected_resume}.txt" ]]; then
            return 0
        fi
        sleep 0.02
    done
    echo "FAIL: batch runner did not capture resume=${expected_resume}" >&2
    return 1
}

run_batch_and_wait false
FRESH_CAPTURE="${TEST_OUTPUT_DIR}/batch-captures/false.txt"
grep -Fxq 'name=sdB_15_66_06' "${FRESH_CAPTURE}"
grep -Fxq 'seed=24681357' "${FRESH_CAPTURE}"
grep -Fxq 'heartbeat=86400' "${FRESH_CAPTURE}"
grep -Fxq 'checkpoint=outputs/sdB_15_66_06_checkpoint.json' \
    "${FRESH_CAPTURE}"
grep -Fxq 'resume=false' "${FRESH_CAPTURE}"
grep -Fxq 'checkpoint_states=0' "${FRESH_CAPTURE}"
grep -Fxq 'checkpoint_seconds=1800' "${FRESH_CAPTURE}"
grep -Fxq 'state_limit=0' "${FRESH_CAPTURE}"
grep -Fxq 'time_limit=0' "${FRESH_CAPTURE}"
grep -Fxq 'memory_limit=18432' "${FRESH_CAPTURE}"

: >"${TEST_OUTPUT_DIR}/batch/outputs/sdB_15_66_06_checkpoint.json"
run_batch_and_wait true
grep -Fxq 'resume=true' \
    "${TEST_OUTPUT_DIR}/batch-captures/true.txt"

echo "PASS: wrapper forwarded seed, heartbeat, and memory safeguards"
echo "PASS: batch jobs received stable seeds and production checkpoint defaults"
echo "All v12 long-run launcher tests passed."
