#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

PYTHONDONTWRITEBYTECODE=1 \
    "${SAGE_BIN}" "${PROJECT_DIR}/tests/test_v12_stage4a.sage"
