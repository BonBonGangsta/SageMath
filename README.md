# SageMath Container Toolkit
A clean starting point for running SageMath workflows inside Docker and orchestrating them with run_sage_and_notify.sh.

## Prerequisites
- Docker Engine ≥ 20.x installed and running
- Bash 4+ (the helper script uses Bash features)
- Optional: .env file with any API keys or notification settings consumed by run_sage_and_notify.sh

## Repository Layout
- Dockerfile or docker/Dockerfile — SageMath runtime image definition
- run_sage_and_notify.sh — wrapper script that launches SageMath jobs and sends notifications
- extras/ — scripts that I created to automate tasks
- scripts/ — templates and versions of final scripts used

## Quick Start

### 1. Build the Docker Image
Replace docker/Dockerfile with the real path if it lives elsewhere.
```
docker build \
  --file docker/Dockerfile \
  --tag your-namespace/sagemath:latest \
  .
```

### 2. Run SageMath in a Container
Mount the project so SageMath can read/write notebooks or scripts.
```
docker run \
  --rm \
  --interactive \
  --tty \
  --name sagemath-runner \
  --volume "$(pwd)":/workspace \
  your-namespace/sagemath:latest \
  sage
```

## Using run_sage_and_notify.sh

### Make the Script Executable
chmod +x run_sage_and_notify.sh

### Basic Invocation
Run the script from the repository root:
`./run_sage_and_notify.sh {Name of Knot} {/path/to/knot_script.sage}`

recommendations:

`nohup ./run_sage_and_notify.sh {Name of Knot} {/path/to/knot_script.sage} 2>&1 & `

### Running Inside Docker
If the script is meant to execute inside the container, first enter the container:
`docker run --rm -it -v "$(pwd)":/workspace your-namespace/sagemath:latest /bin/bash`

Then run:
`sage /path/to/sagefile`

## Troubleshooting
- Image build fails: check the Docker build context path and that all COPY/ADD targets exist.
- Permission denied: ensure the script has execute permissions and that Docker volumes map to writable directories.

## Using NTFY
NTFY is a simple HTTP-based pub-sub notification service. You can self host the application or use their REST API for free. Filling in the `NTFY_URL` and `NTFY_TOPIC` if you are self hosting. For more information, please visit: [https://ntfy.sh](https://ntfy.sh)

## Non-Evasive Search v12

Version 12 is developed separately from the preserved historical scripts. Its
implementation plan and change record are in
`NON_EVASIVE_V12_PROPOSAL.md`.

Protected vertices are optional and use a soft ordering preference by default:

```bash
PROTECTED_VERTICES='[1,2,3]' \
PROTECTED_VERTEX_POLICY=prefer \
./run_sage_and_notify.sh \
  rudins_ball \
  scripts/knot_nonevasive_v12.sage \
  knots/rudins_ball.txt
```

Supported policies are:

- `prefer`: try protected vertices last, without excluding them;
- `restrict`: reproduce the historical hard restriction and report an
  inconclusive result if candidates were skipped;
- `ignore`: use the selected vertex-ordering strategy without special handling.

Run the focused Stage 1 regression suite inside the Sage container with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && tests/test_v12_stage1.sh'
```

Conclusive v12 searches write a versioned JSON proof certificate for either
`NON_EVASIVE` or `EVASIVE_CERTIFIED`. Verify a certificate independently with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner -c '
  cd /workspace
  sage scripts/verify_nonevasive_certificate.sage \
    knots/rudins_ball.txt \
    outputs/rudins_ball_certificate.json
'
```

The JSON certificate DAG is v12's primary and sole proof artifact. V12 no
longer expands that DAG into a console decision tree or repeatedly rewrites a
legacy CSV tree. The preserved v1-v11 scripts may continue using `CSV_OUTPUT`.

Stage 4 uses an independently tested bitset representation as the default v12
state engine. It performs cache lookup before reconstructing a state and only
materializes a Sage complex for a cache miss. Run the low-level Sage-equivalence
suite with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/test_v12_stage4a.sh'
```

Run the complete engine and certificate equivalence suite with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/test_v12_stage4b.sh'
```

`STATE_ENGINE=bitset` is the default. `STATE_ENGINE=sage_reference` replays
Sage links and deletions from the root and is retained for correctness testing,
not for long searches. The chosen engine is recorded in heartbeats,
certificates, and final statistics.

## Bounded v12 Searches and Benchmarks

Set either limit to a positive value to bound a search. Zero disables that
limit:

```bash
SEARCH_STATE_LIMIT=50000 \
SEARCH_TIME_LIMIT_SECONDS=3600 \
./run_sage_and_notify.sh \
  example \
  scripts/knot_nonevasive_v12.sage \
  knots/example.txt
```

A limit stop returns `INCONCLUSIVE_RESOURCE_LIMIT` and does not emit a proof
certificate. The time limit is cooperative: it is checked between search
operations and before homology, but it cannot interrupt one SageMath operation
that is already running. A bounded stop does not yet preserve resumable search
state; checkpoint/resume remains planned for Stage 7.

Compare the bitset and Sage-reference engines sequentially with identical
limits and seed using:

```bash
docker compose run --rm --entrypoint /bin/bash \
  -e BENCHMARK_STATE_LIMIT=50000 \
  -e BENCHMARK_TIME_LIMIT_SECONDS=3600 \
  -e RANDOM_SEED=123456 \
  -e PROTECTED_VERTICES='[1, 2, 3]' \
  sagemath-runner -c '
    cd /workspace
    bash benchmarks/run_v12_engine_benchmark.sh \
      knots/rudins_ball.txt rudins_ball
  '
```

Each benchmark creates a new timestamped directory under
`outputs/benchmarks/`, refuses to overwrite an existing run, executes the two
engines one at a time, and writes `summary.tsv`, logs, and any independently
verified conclusive certificates.

## Normalized and Isomorphic-Complex Memoization

Stage 5A enables a second cache by default. After an operation-history cache
miss, v12 canonicalizes the resulting maximal facet masks and reuses a
completed result when another linked/deleted history produced the exact same
labeled complex:

```bash
NORMALIZED_COMPLEX_CACHE=true
NORMALIZED_CACHE_MAX_FAILURES=100000
```

Set `NORMALIZED_COMPLEX_CACHE=false` for reference comparisons. The failure
index uses a bounded LRU; successful entries remain available for positive
proof construction. Proof records are retained separately for certificate
construction, so checkpointing or disk-backed proof storage is still needed
for searches whose negative certificates exceed memory.

Stage 5B adds a third, opt-in cache for complexes that are isomorphic under a
vertex relabeling:

```bash
ISOMORPHISM_COMPLEX_CACHE=true
ISOMORPHISM_CACHE_MAX_FAILURES=100000
```

It canonically labels the complete vertex-facet incidence graph with separate
colors for simplicial vertices and facet nodes. In strict protected-vertex
mode, protected and unprotected vertices receive separate colors as well. The
key is the complete canonical graph, not a probabilistic digest. Exact cache
lookups remain first, so canonical labeling is attempted only after both exact
caches miss.

The isomorphism cache is disabled by default because canonical labeling has a
measurable fixed cost. On Rudin's ball with seed 13 it reduced Sage state
materializations from 57 to 43 and produced 10 independently verified
isomorphism aliases, but this very small run took about 0.13 seconds instead
of 0.11 seconds. Enable it for representative bounded comparisons before a
long search.

Current certificates use schema version 3. Exact labeled reuse records an
`equivalent_state` edge; isomorphic reuse records an `isomorphic_state` edge
and the complete source-to-target vertex bijection. The independent verifier
reconstructs both states and verifies equality or the claimed simplicial
isomorphism directly. Legacy schema-1 and schema-2 certificates remain
supported. Automorphism-orbit branch reduction is a separate future stage.

Run the exhaustive canonical-label and cache-on/off regression suite with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/test_v12_stage5b.sh'
```
