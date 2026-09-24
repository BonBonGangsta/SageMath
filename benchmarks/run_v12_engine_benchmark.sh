#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAGE_BIN=${SAGE_BIN:-sage}

if ! command -v "${SAGE_BIN}" >/dev/null 2>&1; then
    echo "SageMath executable not found: ${SAGE_BIN}" >&2
    exit 127
fi

FACETS_FILE=${1:-}
KNOT_NAME=${2:-}
if [[ -z "${FACETS_FILE}" || ! -f "${FACETS_FILE}" ]]; then
    echo "Usage: $0 FACETS_FILE [KNOT_NAME]" >&2
    exit 2
fi
if [[ -z "${KNOT_NAME}" ]]; then
    KNOT_NAME=$(basename "${FACETS_FILE}")
    KNOT_NAME=${KNOT_NAME%.*}
fi

RANDOM_SEED=${RANDOM_SEED:-123456}
BENCHMARK_STATE_LIMIT=${BENCHMARK_STATE_LIMIT:-10000}
BENCHMARK_TIME_LIMIT_SECONDS=${BENCHMARK_TIME_LIMIT_SECONDS:-300}
PROTECTED_VERTICES=${PROTECTED_VERTICES:-}
PROTECTED_VERTEX_POLICY=${PROTECTED_VERTEX_POLICY:-prefer}
BENCHMARK_RUN_ID=${BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
BENCHMARK_OUTPUT_DIR=${BENCHMARK_OUTPUT_DIR:-"${PROJECT_DIR}/outputs/benchmarks/${KNOT_NAME}_${BENCHMARK_RUN_ID}"}

if [[ -e "${BENCHMARK_OUTPUT_DIR}" ]]; then
    echo "Benchmark output already exists; choose a new directory: ${BENCHMARK_OUTPUT_DIR}" >&2
    exit 2
fi
mkdir -p "${BENCHMARK_OUTPUT_DIR}"
TEMP_DIR=$(mktemp -d /tmp/nonevasive-v12-benchmark-XXXXXX)
trap 'rm -rf "${TEMP_DIR}"' EXIT

SOLVER="${TEMP_DIR}/knot_nonevasive_v12.sage"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEMP_DIR}/"

SUMMARY="${BENCHMARK_OUTPUT_DIR}/summary.tsv"
printf '%s\n' \
    $'engine\tresult\telapsed_seconds\tpeak_rss_mib\tstates\trecursive_calls\tcache_hits\tresource_limit\tcertificate' \
    >"${SUMMARY}"

extract_field() {
    local line=$1
    local key=$2
    printf '%s\n' "${line}" \
        | tr ';' '\n' \
        | sed -n "s/^[[:space:]]*${key}=//p" \
        | tail -n 1
}

for engine in bitset sage_reference; do
    log_file="${BENCHMARK_OUTPUT_DIR}/${engine}.log"
    certificate="${BENCHMARK_OUTPUT_DIR}/${engine}_certificate.json"

    echo "Running ${engine} sequentially..."
    FACETS_FILE="${FACETS_FILE}" \
    KNOT_NAME="${KNOT_NAME}" \
    RANDOM_SEED="${RANDOM_SEED}" \
    CERTIFICATE_OUTPUT="${certificate}" \
    PROTECTED_VERTICES="${PROTECTED_VERTICES}" \
    PROTECTED_VERTEX_POLICY="${PROTECTED_VERTEX_POLICY}" \
    STATE_ENGINE="${engine}" \
    SEARCH_STATE_LIMIT="${BENCHMARK_STATE_LIMIT}" \
    SEARCH_TIME_LIMIT_SECONDS="${BENCHMARK_TIME_LIMIT_SECONDS}" \
    HEARTBEAT_INTERVAL_SECONDS=86400 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1 || {
        cat "${log_file}" >&2
        exit 1
    }

    final_line=$(grep '^FINAL_RESULT:' "${log_file}" | tail -n 1)
    if [[ -z "${final_line}" ]]; then
        echo "No FINAL_RESULT found for ${engine}" >&2
        exit 1
    fi

    result=${final_line#FINAL_RESULT: }
    result=${result%%;*}
    elapsed=$(extract_field "${final_line}" elapsed_seconds)
    peak_rss=$(extract_field "${final_line}" peak_rss_mib)
    states=$(extract_field "${final_line}" subcomplexes_examined)
    recursive_calls=$(extract_field "${final_line}" recursive_calls)
    cache_hits=$(extract_field "${final_line}" cache_hits)
    resource_limit=$(extract_field "${final_line}" resource_limit)

    certificate_status=none
    if [[ "${result}" == "NON_EVASIVE" || "${result}" == "EVASIVE_CERTIFIED" ]]; then
        test -s "${certificate}"
        "${SAGE_BIN}" \
            "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" \
            "${FACETS_FILE}" "${certificate}" \
            >"${BENCHMARK_OUTPUT_DIR}/${engine}_verification.log" 2>&1
        certificate_status=verified
    elif [[ -e "${certificate}" ]]; then
        echo "Inconclusive run unexpectedly wrote a certificate: ${engine}" >&2
        exit 1
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${engine}" \
        "${result}" \
        "${elapsed}" \
        "${peak_rss}" \
        "${states}" \
        "${recursive_calls}" \
        "${cache_hits}" \
        "${resource_limit}" \
        "${certificate_status}" \
        >>"${SUMMARY}"
done

echo
cat "${SUMMARY}"
echo "Benchmark artifacts: ${BENCHMARK_OUTPUT_DIR}"
