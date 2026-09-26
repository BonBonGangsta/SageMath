#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  # Load variables like LOG_PATH, NTFY_URL, NTFY_TOPIC
  set -a
  source "${ENV_FILE}"
  set +a
fi

KNOT_NAME=${1:-}
SCRIPT_FILE=${2:-}
FACETS_FILE=${3:-${FACETS_FILE:-}}
PROTECTIVE_FACETS=${4:-}

if [[ -z "${SCRIPT_FILE}" ]]; then
  echo "Please provide a script file to run"
  exit 1
fi

if [[ -z "${KNOT_NAME}" ]]; then
  echo "Please provide a knot name"
  exit 1
fi

: "${NTFY_URL:?Missing NTFY_URL; set it in .env}"
: "${NTFY_TOPIC:?Missing NTFY_TOPIC; set it in .env}"

if [[ ! -f "${SCRIPT_FILE}" ]]; then
  echo "Script file '${SCRIPT_FILE}' was not found"
  exit 1
fi

SCRIPT_PATH=$(realpath "${SCRIPT_FILE}")
if [[ "${SCRIPT_PATH}" != "${SCRIPT_DIR}"/* ]]; then
  echo "Script file must live inside ${SCRIPT_DIR}"
  exit 1
fi

RELATIVE_SCRIPT_PATH=${SCRIPT_PATH#"${SCRIPT_DIR}/"}

if [[ -n "${FACETS_FILE}" ]]; then
  if [[ ! -f "${FACETS_FILE}" ]]; then
    echo "Facets file '${FACETS_FILE}' was not found"
    exit 1
  fi
  FACETS_PATH=$(realpath "${FACETS_FILE}")
  if [[ "${FACETS_PATH}" != "${SCRIPT_DIR}"/* ]]; then
    echo "Facets file must live inside ${SCRIPT_DIR}"
    exit 1
  fi
  RELATIVE_FACETS_PATH=${FACETS_PATH#"${SCRIPT_DIR}/"}
fi

LOG_DIR="${SCRIPT_DIR}/outputs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${KNOT_NAME}.log"
CSV_OUTPUT="outputs/${KNOT_NAME}_tree.csv"
CERTIFICATE_OUTPUT="outputs/${KNOT_NAME}_certificate.json"

CONTAINER_NAME="sagemath_${KNOT_NAME}"

RUN_EXIT=0
docker compose run --rm \
  --name "${CONTAINER_NAME}" \
  --entrypoint /bin/bash \
  -v "${LOG_DIR}:/outputs" \
  -e CSV_OUTPUT="${CSV_OUTPUT}" \
  -e CERTIFICATE_OUTPUT="${CERTIFICATE_OUTPUT}" \
  -e KNOT_NAME="${KNOT_NAME}" \
  -e HEARTBEAT_MODE="${HEARTBEAT_MODE:-stdout}" \
  -e HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-86400}" \
  -e WITNESS_CACHE_MAX_FAILURES="${WITNESS_CACHE_MAX_FAILURES:-500000}" \
  -e NORMALIZED_COMPLEX_CACHE="${NORMALIZED_COMPLEX_CACHE:-true}" \
  -e NORMALIZED_CACHE_MAX_FAILURES="${NORMALIZED_CACHE_MAX_FAILURES:-100000}" \
  -e ISOMORPHISM_COMPLEX_CACHE="${ISOMORPHISM_COMPLEX_CACHE:-false}" \
  -e ISOMORPHISM_CACHE_MAX_FAILURES="${ISOMORPHISM_CACHE_MAX_FAILURES:-100000}" \
  -e AUTOMORPHISM_ORBIT_PRUNING="${AUTOMORPHISM_ORBIT_PRUNING:-false}" \
  ${RANDOM_SEED:+-e RANDOM_SEED="${RANDOM_SEED}"} \
  -e SEARCH_STRATEGY="${SEARCH_STRATEGY:-random}" \
  -e CHILD_AWARE_ORDERING="${CHILD_AWARE_ORDERING:-false}" \
  -e CHILD_AWARE_MAX_VERTICES="${CHILD_AWARE_MAX_VERTICES:-80}" \
  -e CHILD_AWARE_MAX_FACETS="${CHILD_AWARE_MAX_FACETS:-500}" \
  -e OBSTRUCTION_SCHEDULER="${OBSTRUCTION_SCHEDULER:-fixed}" \
  -e OBSTRUCTION_ADAPTIVE_WARMUP_CALLS="${OBSTRUCTION_ADAPTIVE_WARMUP_CALLS:-8}" \
  -e NONCOLLAPSIBILITY_OBSTRUCTION="${NONCOLLAPSIBILITY_OBSTRUCTION:-false}" \
  -e NONCOLLAPSIBILITY_MAX_VERTICES="${NONCOLLAPSIBILITY_MAX_VERTICES:-80}" \
  -e NONCOLLAPSIBILITY_MAX_FACETS="${NONCOLLAPSIBILITY_MAX_FACETS:-200}" \
  -e HOMOLOGY_ZZ_MAX_VERTICES="${HOMOLOGY_ZZ_MAX_VERTICES:-80}" \
  -e HOMOLOGY_ZZ_MAX_FACES="${HOMOLOGY_ZZ_MAX_FACES:-1500}" \
  -e HOMOLOGY_START_DEPTH="${HOMOLOGY_START_DEPTH:-200}" \
  -e HOMOLOGY_GF2_DEPTH_INTERVAL="${HOMOLOGY_GF2_DEPTH_INTERVAL:-20}" \
  -e HOMOLOGY_FIELDS_ON_LINKS="${HOMOLOGY_FIELDS_ON_LINKS:-true}" \
  -e HOMOLOGY_FIELD_PRIMES="${HOMOLOGY_FIELD_PRIMES:-2}" \
  -e HOMOLOGY_FIELDS_AT_ROOT="${HOMOLOGY_FIELDS_AT_ROOT:-false}" \
  -e STATE_ENGINE="${STATE_ENGINE:-bitset}" \
  -e SEARCH_STATE_LIMIT="${SEARCH_STATE_LIMIT:-0}" \
  -e SEARCH_TIME_LIMIT_SECONDS="${SEARCH_TIME_LIMIT_SECONDS:-0}" \
  -e CHECKPOINT_PATH="${CHECKPOINT_PATH:-}" \
  -e CHECKPOINT_RESUME="${CHECKPOINT_RESUME:-false}" \
  -e CHECKPOINT_OVERWRITE="${CHECKPOINT_OVERWRITE:-false}" \
  -e CHECKPOINT_INTERVAL_STATES="${CHECKPOINT_INTERVAL_STATES:-1000}" \
  -e CHECKPOINT_INTERVAL_SECONDS="${CHECKPOINT_INTERVAL_SECONDS:-300}" \
  -e PROTECTED_VERTICES="${PROTECTED_VERTICES:-}" \
  -e PROTECTED_VERTEX_POLICY="${PROTECTED_VERTEX_POLICY:-prefer}" \
  -e PROTECTIVE_FACETS="${PROTECTIVE_FACETS}" \
  ${FACETS_FILE:+-e FACETS_FILE="${RELATIVE_FACETS_PATH}"} \
  sagemath-runner -c "
    set -euo pipefail
    export PATH=/usr/bin:/usr/local/bin:/bin:\$PATH
    cd /workspace
    unset SAGE_ROOT
    tmp_file=\$(mktemp /tmp/sage-script-XXXXXX.sage)
    cp '${RELATIVE_SCRIPT_PATH}' \"\$tmp_file\"
    cp scripts/simplicial_bitset.py /tmp/simplicial_bitset.py
    cp scripts/simplicial_isomorphism.py /tmp/simplicial_isomorphism.py
    sage \"\$tmp_file\"
    rm -f \"\$tmp_file\"
    rm -f /tmp/simplicial_bitset.py
    rm -f /tmp/simplicial_isomorphism.py
  " > "${LOG_FILE}" 2>&1 || RUN_EXIT=$?


SUMMARY_LINE=$(tail -n 2 "${LOG_FILE}")

case "${RUN_EXIT}" in
  0)
    if grep -Fq 'FINAL_RESULT: INCONCLUSIVE_INTERRUPTED;' "${LOG_FILE}"; then
      NOTIFICATION="⏸️ SageMath job checkpointed after interruption for ${KNOT_NAME}. ${SUMMARY_LINE}"
    elif grep -Fq 'FINAL_RESULT: INCONCLUSIVE_RESOURCE_LIMIT;' "${LOG_FILE}"; then
      NOTIFICATION="⏸️ SageMath job reached a configured limit for ${KNOT_NAME}. ${SUMMARY_LINE}"
    elif grep -Fq 'FINAL_RESULT: INCONCLUSIVE_RESTRICTED;' "${LOG_FILE}"; then
      NOTIFICATION="⚠️ SageMath job completed only under a restricted policy for ${KNOT_NAME}. ${SUMMARY_LINE}"
    else
      NOTIFICATION="✅ SageMath job complete for ${KNOT_NAME}. ${SUMMARY_LINE}"
    fi
    ;;
  137)
    NOTIFICATION="🚨 SageMath job ${KNOT_NAME} was killed (exit 137; likely out of memory or an external SIGKILL). ${SUMMARY_LINE}"
    ;;
  *)
    NOTIFICATION="❌ SageMath job ${KNOT_NAME} failed with exit ${RUN_EXIT}. ${SUMMARY_LINE}"
    ;;
esac

CURL_EXIT=0
curl -d "${NOTIFICATION}" \
  "${NTFY_URL%/}/${NTFY_TOPIC}" || CURL_EXIT=$?

if (( RUN_EXIT != 0 )); then
  exit "${RUN_EXIT}"
fi

exit "${CURL_EXIT}"
