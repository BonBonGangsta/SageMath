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
BENCHMARK_STATE_LIMIT=${BENCHMARK_STATE_LIMIT:-50000}
BENCHMARK_TIME_LIMIT_SECONDS=${BENCHMARK_TIME_LIMIT_SECONDS:-3600}
PROTECTED_VERTICES=${PROTECTED_VERTICES:-}
PROTECTED_VERTEX_POLICY=${PROTECTED_VERTEX_POLICY:-prefer}
STATE_ENGINE=${STATE_ENGINE:-bitset}
SEARCH_STRATEGY=${SEARCH_STRATEGY:-random}
NORMALIZED_COMPLEX_CACHE=${NORMALIZED_COMPLEX_CACHE:-true}
NORMALIZED_CACHE_MAX_FAILURES=${NORMALIZED_CACHE_MAX_FAILURES:-100000}
ISOMORPHISM_COMPLEX_CACHE=${ISOMORPHISM_COMPLEX_CACHE:-false}
ISOMORPHISM_CACHE_MAX_FAILURES=${ISOMORPHISM_CACHE_MAX_FAILURES:-100000}
AUTOMORPHISM_ORBIT_PRUNING=${AUTOMORPHISM_ORBIT_PRUNING:-false}
CHILD_AWARE_ORDERING=${CHILD_AWARE_ORDERING:-true}
CHILD_AWARE_MAX_VERTICES=${CHILD_AWARE_MAX_VERTICES:-80}
CHILD_AWARE_MAX_FACETS=${CHILD_AWARE_MAX_FACETS:-500}
OBSTRUCTION_ADAPTIVE_WARMUP_CALLS=${OBSTRUCTION_ADAPTIVE_WARMUP_CALLS:-8}
NONCOLLAPSIBILITY_OBSTRUCTION=${NONCOLLAPSIBILITY_OBSTRUCTION:-true}
NONCOLLAPSIBILITY_MAX_VERTICES=${NONCOLLAPSIBILITY_MAX_VERTICES:-80}
NONCOLLAPSIBILITY_MAX_FACETS=${NONCOLLAPSIBILITY_MAX_FACETS:-200}
HOMOLOGY_FIELD_PRIMES=${HOMOLOGY_FIELD_PRIMES:-2,3}
HOMOLOGY_FIELDS_AT_ROOT=${HOMOLOGY_FIELDS_AT_ROOT:-false}
BENCHMARK_RUN_ID=${BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
BENCHMARK_OUTPUT_DIR=${BENCHMARK_OUTPUT_DIR:-"${PROJECT_DIR}/outputs/benchmarks/${KNOT_NAME}_obstructions_${BENCHMARK_RUN_ID}"}

if [[ -e "${BENCHMARK_OUTPUT_DIR}" ]]; then
    echo "Benchmark output already exists; choose a new directory: ${BENCHMARK_OUTPUT_DIR}" >&2
    exit 2
fi
mkdir -p "${BENCHMARK_OUTPUT_DIR}"
TEMP_DIR=$(mktemp -d /tmp/nonevasive-v12-obstructions-XXXXXX)
trap 'rm -rf "${TEMP_DIR}"' EXIT

SOLVER="${TEMP_DIR}/knot_nonevasive_v12.sage"
cp "${PROJECT_DIR}/scripts/knot_nonevasive_v12.sage" "${SOLVER}"
cp "${PROJECT_DIR}/scripts/simplicial_bitset.py" "${TEMP_DIR}/"
cp "${PROJECT_DIR}/scripts/simplicial_isomorphism.py" "${TEMP_DIR}/"

SUMMARY="${BENCHMARK_OUTPUT_DIR}/summary.tsv"
printf '%s\n' \
    $'scheduler\tresult\telapsed_seconds\tpeak_rss_mib\tstates\tvertex_attempts\trecursive_calls\tdeepest_path\tschedules\treorders\tnoncollapsibility_rejections\thomology_zz_calls\thomology_field_calls\thomology_field_rejections\tresource_limit\tcertificate' \
    >"${SUMMARY}"

extract_field() {
    local line=$1
    local key=$2
    printf '%s\n' "${line}" \
        | tr ';' '\n' \
        | sed -n "s/^[[:space:]]*${key}=//p" \
        | tail -n 1
}

for scheduler in fixed adaptive; do
    log_file="${BENCHMARK_OUTPUT_DIR}/${scheduler}.log"
    certificate="${BENCHMARK_OUTPUT_DIR}/${scheduler}_certificate.json"

    echo "Running ${scheduler} obstruction scheduling sequentially..."
    FACETS_FILE="${FACETS_FILE}" \
    KNOT_NAME="${KNOT_NAME}_${scheduler}" \
    RANDOM_SEED="${RANDOM_SEED}" \
    CERTIFICATE_OUTPUT="${certificate}" \
    PROTECTED_VERTICES="${PROTECTED_VERTICES}" \
    PROTECTED_VERTEX_POLICY="${PROTECTED_VERTEX_POLICY}" \
    STATE_ENGINE="${STATE_ENGINE}" \
    SEARCH_STRATEGY="${SEARCH_STRATEGY}" \
    NORMALIZED_COMPLEX_CACHE="${NORMALIZED_COMPLEX_CACHE}" \
    NORMALIZED_CACHE_MAX_FAILURES="${NORMALIZED_CACHE_MAX_FAILURES}" \
    ISOMORPHISM_COMPLEX_CACHE="${ISOMORPHISM_COMPLEX_CACHE}" \
    ISOMORPHISM_CACHE_MAX_FAILURES="${ISOMORPHISM_CACHE_MAX_FAILURES}" \
    AUTOMORPHISM_ORBIT_PRUNING="${AUTOMORPHISM_ORBIT_PRUNING}" \
    CHILD_AWARE_ORDERING="${CHILD_AWARE_ORDERING}" \
    CHILD_AWARE_MAX_VERTICES="${CHILD_AWARE_MAX_VERTICES}" \
    CHILD_AWARE_MAX_FACETS="${CHILD_AWARE_MAX_FACETS}" \
    OBSTRUCTION_SCHEDULER="${scheduler}" \
    OBSTRUCTION_ADAPTIVE_WARMUP_CALLS="${OBSTRUCTION_ADAPTIVE_WARMUP_CALLS}" \
    NONCOLLAPSIBILITY_OBSTRUCTION="${NONCOLLAPSIBILITY_OBSTRUCTION}" \
    NONCOLLAPSIBILITY_MAX_VERTICES="${NONCOLLAPSIBILITY_MAX_VERTICES}" \
    NONCOLLAPSIBILITY_MAX_FACETS="${NONCOLLAPSIBILITY_MAX_FACETS}" \
    HOMOLOGY_FIELD_PRIMES="${HOMOLOGY_FIELD_PRIMES}" \
    HOMOLOGY_FIELDS_AT_ROOT="${HOMOLOGY_FIELDS_AT_ROOT}" \
    SEARCH_STATE_LIMIT="${BENCHMARK_STATE_LIMIT}" \
    SEARCH_TIME_LIMIT_SECONDS="${BENCHMARK_TIME_LIMIT_SECONDS}" \
    HEARTBEAT_INTERVAL_SECONDS=86400 \
    "${SAGE_BIN}" "${SOLVER}" >"${log_file}" 2>&1 || {
        cat "${log_file}" >&2
        exit 1
    }

    final_line=$(grep '^FINAL_RESULT:' "${log_file}" | tail -n 1)
    if [[ -z "${final_line}" ]]; then
        echo "No FINAL_RESULT found for ${scheduler}" >&2
        exit 1
    fi

    result=${final_line#FINAL_RESULT: }
    result=${result%%;*}
    elapsed=$(extract_field "${final_line}" elapsed_seconds)
    peak_rss=$(extract_field "${final_line}" peak_rss_mib)
    states=$(extract_field "${final_line}" subcomplexes_examined)
    vertex_attempts=$(extract_field "${final_line}" vertex_attempts)
    recursive_calls=$(extract_field "${final_line}" recursive_calls)
    deepest_path=$(extract_field "${final_line}" deepest_path)
    schedules=$(extract_field "${final_line}" obstruction_schedules)
    reorders=$(extract_field "${final_line}" obstruction_reorders)
    no_free=$(extract_field \
        "${final_line}" noncollapsibility_rejections)
    zz_calls=$(extract_field "${final_line}" homology_zz_calls)
    field_calls=$(extract_field "${final_line}" homology_field_calls)
    field_rejections=$(extract_field \
        "${final_line}" homology_field_rejections)
    resource_limit=$(extract_field "${final_line}" resource_limit)

    certificate_status=none
    if [[ "${result}" == "NON_EVASIVE" || "${result}" == "EVASIVE_CERTIFIED" ]]; then
        test -s "${certificate}"
        "${SAGE_BIN}" \
            "${PROJECT_DIR}/scripts/verify_nonevasive_certificate.sage" \
            "${FACETS_FILE}" "${certificate}" \
            >"${BENCHMARK_OUTPUT_DIR}/${scheduler}_verification.log" 2>&1
        certificate_status=verified
    elif [[ -e "${certificate}" ]]; then
        echo "Inconclusive run unexpectedly wrote a certificate: ${scheduler}" >&2
        exit 1
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${scheduler}" \
        "${result}" \
        "${elapsed}" \
        "${peak_rss}" \
        "${states}" \
        "${vertex_attempts}" \
        "${recursive_calls}" \
        "${deepest_path}" \
        "${schedules}" \
        "${reorders}" \
        "${no_free}" \
        "${zz_calls}" \
        "${field_calls}" \
        "${field_rejections}" \
        "${resource_limit}" \
        "${certificate_status}" \
        >>"${SUMMARY}"
done

echo
cat "${SUMMARY}"
echo "Benchmark artifacts: ${BENCHMARK_OUTPUT_DIR}"
