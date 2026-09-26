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

Set any limit to a positive value to bound a search. Zero disables that
limit:

```bash
SEARCH_STATE_LIMIT=50000 \
SEARCH_TIME_LIMIT_SECONDS=3600 \
SEARCH_MEMORY_LIMIT_MIB=4096 \
./run_sage_and_notify.sh \
  example \
  scripts/knot_nonevasive_v12.sage \
  knots/example.txt
```

A limit stop returns `INCONCLUSIVE_RESOURCE_LIMIT` and does not emit a proof
certificate. Time and resident-memory limits are cooperative: they are checked
between search operations and before homology, but cannot interrupt one
SageMath operation that is already running. Configure `CHECKPOINT_PATH` to
preserve completed search states for a later resumed session, as described
below.

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

Stage 5C adds separate, opt-in automorphism-orbit pruning:

```bash
AUTOMORPHISM_ORBIT_PRUNING=true
```

At each nonterminal state, it tests only the first vertex in each
color-preserving automorphism orbit. Evasiveness certificates include a full
facet-preserving automorphism from the tested representative to every skipped
vertex, so the independent verifier can confirm complete coverage without
trusting the search program's orbit calculation. This optimization is also
disabled by default pending benchmarks on representative unresolved inputs.

Current certificates use schema version 4. Exact labeled reuse records an
`equivalent_state` edge; isomorphic reuse records an `isomorphic_state` edge
and the complete source-to-target vertex bijection. The independent verifier
reconstructs both states and verifies equality or the claimed simplicial
isomorphism directly. Orbit-reduced failures additionally record orbit members
and explicit automorphisms. Legacy schema-1 through schema-3 certificates
remain supported under their original feature limits.

On the symmetric suspension regression fixture with both memoization layers
disabled, orbit pruning reduced Sage state materializations from 24 to 16 and
vertex attempts from 23 to 15. Both evasiveness certificates independently
verified. This small run improved from about 0.10 to 0.09 seconds, but it is
not a performance guarantee for larger complexes.

Run the exhaustive canonical-label and cache-on/off regression suite with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/test_v12_stage5b.sh'
```

Run the exhaustive automorphism-orbit and negative-certificate suite with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/test_v12_stage5c.sh'
```

## Child-Aware Branch Ordering

Stage 6A adds an opt-in ordering layer that cheaply classifies every immediate
link and deletion using the bitset representation before choosing which
candidate to explore first:

```bash
SEARCH_STRATEGY=random
CHILD_AWARE_ORDERING=true
CHILD_AWARE_MAX_VERTICES=80
CHILD_AWARE_MAX_FACETS=500
```

The exact cheap cases are empty complexes, simplices, cones, trees,
one-dimensional non-trees, and disconnected complexes. The base strategy is
retained as the final tie-breaker, and soft protected vertices remain after
unprotected candidates. A zero size limit means unlimited; states exceeding a
positive limit retain the base ordering. The optimization does not change the
certificate format or omit any candidate.

On Rudin's ball with seed `123456`, child-aware ordering reduced Sage state
materializations from 57 to 37 and vertex attempts from 36 to 20. The tiny run
took about 0.12 seconds instead of 0.10 seconds because scoring overhead
dominated, so the feature remains disabled by default.

Run an auditable sequential A/B comparison on any complex with:

```bash
docker compose run --rm --entrypoint /bin/bash \
  -e BENCHMARK_STATE_LIMIT=50000 \
  -e BENCHMARK_TIME_LIMIT_SECONDS=3600 \
  -e RANDOM_SEED=123456 \
  sagemath-runner -c '
    cd /workspace
    bash benchmarks/run_v12_branching_benchmark.sh \
      path/to/facets.txt experiment_name
  '
```

The baseline and child-aware jobs run sequentially with identical settings.
Timestamped output contains logs, `summary.tsv`, and independently verified
certificates for any conclusive result.

Run the Stage 6A regression suite with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/test_v12_stage6a.sh'
```

## Adaptive Obstruction Scheduling

Stage 6B adds opt-in scheduling and two additional one-sided rejection tools:

```bash
OBSTRUCTION_SCHEDULER=adaptive
OBSTRUCTION_ADAPTIVE_WARMUP_CALLS=8
NONCOLLAPSIBILITY_OBSTRUCTION=true
NONCOLLAPSIBILITY_MAX_VERTICES=80
NONCOLLAPSIBILITY_MAX_FACETS=200
HOMOLOGY_FIELD_PRIMES=2,3
HOMOLOGY_FIELDS_ON_LINKS=true
HOMOLOGY_FIELDS_AT_ROOT=false
```

The scheduler profiles connectivity, Euler characteristic, the no-free-face
test, finite-field homology, and integral homology by calls, elapsed time, and
rejections. After every eligible test has completed its warmup, adaptive mode
prefers the lowest observed time per rejection. All eligible tests still run
unless an earlier test has already proved rejection. Root tests retain their
fixed conservative order.

A non-simplex with no free face cannot begin an elementary collapse.
Non-evasive complexes are collapsible, so this is a certified evasiveness
obstruction rather than a failed collapse heuristic. It is disabled by
default and size-gated because the exact ridge-containment test can be
quadratic in the number of facets. Zero size limits mean unlimited.

`HOMOLOGY_FIELD_PRIMES` accepts distinct comma-separated primes from 2 through
97. The default remains `2`; adding `3` can detect odd torsion invisible over
GF(2). Field screens at the root remain disabled by default, and integral
homology remains the final root check when earlier screens do not reject.
`OBSTRUCTION_SCHEDULER=fixed`,
`NONCOLLAPSIBILITY_OBSTRUCTION=false`, and the other defaults preserve the
pre-Stage-6B search behavior.

The Dunce Hat regression is contractible but has no free face. The new
obstruction reduced its verified evasiveness certificate from nine states to
one. A Moore-space regression verifies that GF(3) rejects odd torsion after
GF(2) reports trivial reduced homology.

Run a sequential fixed-versus-adaptive comparison with identical search
settings using:

```bash
docker compose run --rm --entrypoint /bin/bash \
  -e BENCHMARK_STATE_LIMIT=50000 \
  -e BENCHMARK_TIME_LIMIT_SECONDS=3600 \
  -e RANDOM_SEED=123456 \
  sagemath-runner -c '
    cd /workspace
    bash benchmarks/run_v12_obstruction_benchmark.sh \
      path/to/facets.txt experiment_name
  '
```

The runner enables the same no-free-face and GF(2)/GF(3) screens in both jobs;
only the scheduler changes. It never overwrites an existing result directory
and independently verifies every conclusive certificate.

Run the Stage 6B regression suite with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/test_v12_stage6b.sh'
```

## Checkpoint and Resume

Stage 7 can atomically preserve completed search states and resume them in a
later process. Checkpointing is opt-in and does not remove the file after a
completed run:

```bash
CHECKPOINT_PATH=outputs/my_complex_checkpoint.json \
CHECKPOINT_INTERVAL_STATES=1000 \
CHECKPOINT_INTERVAL_SECONDS=300 \
SEARCH_STATE_LIMIT=50000 \
./run_sage_and_notify.sh \
  my_complex scripts/knot_nonevasive_v12.sage path/to/facets.txt
```

To continue, use the same input, seed, and search settings, set resume mode,
and optionally raise or remove the resource limits:

```bash
CHECKPOINT_PATH=outputs/my_complex_checkpoint.json \
CHECKPOINT_RESUME=true \
SEARCH_STATE_LIMIT=0 \
SEARCH_TIME_LIMIT_SECONDS=0 \
./run_sage_and_notify.sh \
  my_complex scripts/knot_nonevasive_v12.sage path/to/facets.txt
```

The state, time, and memory limits are deliberately excluded from the
compatibility fingerprint so each resumed session can receive a new budget.
The following must still match:

- the canonical input complex and vertex order;
- solver, bitset, and isomorphism source hashes and the Sage version;
- seed, strategy, engine, protected-vertex policy, caches, symmetry options,
  branch ordering, obstruction settings, and homology policy.

Each checkpoint includes a SHA-256 payload checksum, completed certificate
fragments, the exact failure-cache LRU, RNG state, adaptive profiles, and
cumulative cache-miss counters. Writes use a temporary file followed by an
atomic replacement. Derived normalized and isomorphism caches are rebuilt as
needed after resume; exact completed-state results are restored immediately.

An existing checkpoint is never overwritten by a fresh run unless
`CHECKPOINT_OVERWRITE=true` is explicit. Use `CHECKPOINT_RESUME=true` for the
normal continuation path. `SIGINT` and `SIGTERM` are cooperative: the solver
finishes the current Sage operation, writes an `interrupted` checkpoint, and
reports `INCONCLUSIVE_INTERRUPTED`. A forced `SIGKILL` can only recover the
most recent periodic checkpoint.

Run the Stage 7 regression suite with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/test_v12_stage7.sh'
```

## Independent Reference and Regression Suite

Stage 8 adds a plain-Python implementation of the recursive definition that
does not import the production search, bitset, cache, obstruction, or
certificate code. The v12 result is compared against that independent oracle
with the normalized cache both disabled and enabled for all 189 distinct
simplicial complexes on at most four vertices. Every permutation of each
ambient label set is also checked, for 4,101 relabeled production searches.

Named fixtures cover a point, filled simplex, tree, cycle, disconnected
zero-dimensional complex, cones over non-evasive and evasive bases, and the
boundary of a tetrahedron. The end-to-end suite additionally verifies positive
and negative certificate serialization round trips, rejects deliberately
corrupted proofs, and checks preferred versus strict protected-vertex result
semantics.

Run Stage 8 alone with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/test_v12_stage8.sh'
```

Run every accumulated v12 regression suite in stage order with:

```bash
docker compose run --rm --entrypoint /bin/bash sagemath-runner \
  -c 'cd /workspace && bash tests/run_v12_regression_suite.sh'
```

## Long-Running Batch Searches

`scripts/batch_calculations.sh` accepts the following CSV columns:

```text
ID,KNOT,SCRIPT_PATH,FACET_FILE,RANDOM_SEED
```

`RANDOM_SEED` is optional. If it is blank or the older four-column format is
used, the launcher derives a stable seed from the combined knot name and ID.
Each batch job receives its own checkpoint at
`outputs/<KNOT>_<ID>_checkpoint.json`. Re-running the same row automatically
requests resume when that checkpoint exists; the solver still validates its
input, code hashes, and correctness-affecting settings before accepting it.

The notification wrapper now forwards an explicit `RANDOM_SEED` and emits a
regular heartbeat once per day by default. Override the interval for a launch
or in `.env`, for example:

```bash
HEARTBEAT_INTERVAL_SECONDS=43200 \
bash scripts/batch_calculations.sh extra_knots.csv
```

Forced root-homology boundary messages and the final result are still emitted
regardless of the regular heartbeat interval. Batch launches default to
time-only checkpointing every 30 minutes
(`CHECKPOINT_INTERVAL_STATES=0`, `CHECKPOINT_INTERVAL_SECONDS=1800`). This
avoids repeatedly rewriting a large checkpoint when the search completes many
proof records quickly. Either value can be overridden for a launch or in
`.env`.

Batch state and time limits default to zero (unlimited). Batch launches set
`SEARCH_MEMORY_LIMIT_MIB=18432`, leaving about 6 GiB of headroom below the
default 24 GiB Docker memory ceiling for checkpoint serialization and
temporary SageMath allocations. When the process RSS reaches the soft limit,
the solver reports `INCONCLUSIVE_RESOURCE_LIMIT` and writes its checkpoint
before exiting. This is a cooperative safeguard checked at most once every
five seconds; it cannot prevent a single SageMath operation from crossing the
hard container limit. If `SAGE_MEMORY_LIMIT` is lowered, lower
`SEARCH_MEMORY_LIMIT_MIB` as well so comparable headroom remains.

For example, a launch with a smaller soft memory budget and hourly
checkpoints can use:

```bash
SEARCH_MEMORY_LIMIT_MIB=12288 \
CHECKPOINT_INTERVAL_SECONDS=3600 \
bash scripts/batch_calculations.sh extra_knots.csv
```

The long-run cache regression covers the case where the bounded exact failure
LRU evicts a state that remains a representative in the normalized or
isomorphism cache. Such a revisit restores the exact entry directly and does
not create an invalid self-alias proof edge.
