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

SCRIPT_BASENAME=$(basename "${SCRIPT_FILE}")

docker compose run --rm sagemath-runner sage "${SCRIPT_BASENAME}" 2>&1


SUMMARY_LINE=$(tail -n 2 "${KNOT_NAME}.log")

curl -d "✅ SageMath job complete for ${KNOT_NAME}. ${SUMMARY_LINE}" \
  "${NTFY_URL%/}/${NTFY_TOPIC}"
