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

SAFE_KNOT_NAME=$(echo "${KNOT_NAME}" | tr -c ':alnum:]_.-' '_')
CONTAINER_NAME="sagemath_${SAFE_KNOT_NAME}"

sudo docker compose run --rm \
  --name "${CONTAINER_NAME}" \
  --entrypoint /bin/bash \
  -v "${LOG_DIR}:/outputs" \
  -e CSV_OUTPUT="${CSV_OUTPUT}" \
  -e KNOT_NAME="${KNOT_NAME}" \
  -e HEARTBEAT_MODE="${HEARTBEAT_MODE:-stdout}" \
  -e HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-86400}" \
  -e PROTECTIVE_FACETS="${PROTECTIVE_FACETS}" \
  ${FACETS_FILE:+-e FACETS_FILE="${RELATIVE_FACETS_PATH}"} \
  sagemath-runner -c "
    set -euo pipefail
    export PATH=/usr/bin:/usr/local/bin:/bin:\$PATH
    cd /workspace
    unset SAGE_ROOT
    tmp_file=\$(mktemp /tmp/sage-script-XXXXXX.sage)
    cp '${RELATIVE_SCRIPT_PATH}' \"\$tmp_file\"
    sage \"\$tmp_file\"
    rm -f \"\$tmp_file\"
  " > "${LOG_FILE}" 2>&1


SUMMARY_LINE=$(tail -n 2 "${LOG_FILE}")


curl -d "✅ SageMath job complete for ${KNOT_NAME}. ${SUMMARY_LINE}" \
  "${NTFY_URL%/}/${NTFY_TOPIC}"
