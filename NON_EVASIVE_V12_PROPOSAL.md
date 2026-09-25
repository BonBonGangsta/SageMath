# Non-Evasive Search v12: Proposal and Change Record

Date started: 2026-09-24  
Development branch: `feature/nonevasive-v12`

## Purpose

This document records the proposed changes to the non-evasiveness search,
the reason for each change, and the order in which the changes will be made.
It is also intended to provide an audit trail for dissertation work.

The central goals are:

1. distinguish a proof from an incomplete or restricted search;
2. produce independently verifiable certificates;
3. improve performance without weakening mathematical correctness;
4. preserve every historical implementation and its context.

## Preservation policy

- Versions `v1` through `v11` will not be deleted or rewritten.
- New implementation work will begin in `knot_nonevasive_v12.sage`.
- Historical scripts with known limitations will remain available as research
  artifacts. Their limitations will be documented rather than silently fixed.
- Each substantial stage should be committed separately so that it can be
  reviewed, tested, reverted, or cited independently.
- Search outputs used in research should record the input hash, Git commit,
  SageMath version, configuration, strategy, and random seed.

## Result semantics

Version 12 should use explicit result states:

| Result | Meaning |
| --- | --- |
| `NON_EVASIVE` | A valid non-evasive witness was found. |
| `EVASIVE_CERTIFIED` | An unrestricted search or a sound obstruction produced a verifiable proof of evasiveness. |
| `INCONCLUSIVE_RESTRICTED` | No witness was found under an explicitly restricted vertex policy. |
| `INCONCLUSIVE_RESOURCE_LIMIT` | The search stopped because of time, memory, interruption, or another configured limit. |
| `ERROR` | The input, configuration, or computation was invalid. |

A heuristic failure must never be printed as `EVASIVE_CERTIFIED`.

## Why result semantics come first

Versions 9 through 11 avoid protected knot vertices while any unprotected
vertices remain. This is useful as a witness-search heuristic, but it excludes
otherwise valid decision trees. Exhausting that restricted search proves only
that no witness satisfying the restriction was found.

In v12, protected vertices will be a **soft ordering preference by default**:
they will be placed after ordinary vertices but will still be tested. A strict
protected mode may remain available for experiments, but failure in that mode
will return `INCONCLUSIVE_RESTRICTED`.

## Planned implementation stages

### Stage 0: Establish the v12 baseline

Status: completed on 2026-09-24

- Copy v11 to a new `knot_nonevasive_v12.sage` file.
- Leave v11 and all earlier versions unchanged.
- Add a short version-history document or section describing what each version
  attempted and which conclusions it can safely support.
- Record the initial input, configuration, seed, and code revision in outputs.

Validation performed:

- Created `scripts/knot_nonevasive_v12.sage` from v11 without modifying v11.
- Preserved the v11 homology, caching, memory, and heartbeat instrumentation so
  that later performance comparisons remain meaningful.
- Added reusable small-complex fixtures and a standalone Rudin's-ball facets
  file extracted from the historical embedded data.

### Stage 1: Correct result classification and protected-vertex handling

Status: completed on 2026-09-24

- Replace the single Boolean-style final result with the explicit result states
  defined above.
- Change protected vertices from an exclusion rule to a soft ordering rule.
- Add an explicit restricted-search option for experiments that require it.
- Distinguish a sound root obstruction from exhaustion of a restricted search.
- Validate `FACETS_FILE` and other required inputs before constructing the
  simplicial complex.
- Use the actual generated seed, rather than the possibly absent environment
  value, in output metadata and filenames.

Validation performed:

- Added a five-vertex regression complex for which soft preference finds a
  witness while strict protection does not.
- Verified that soft preference returns `NON_EVASIVE` and strict protection
  returns `INCONCLUSIVE_RESTRICTED` for that example.
- Verified that a simplex returns `NON_EVASIVE`.
- Verified that a cycle returns `EVASIVE_CERTIFIED` through the exact
  one-dimensional tree classification.
- Ran Rudin's ball with protected vertices `[1, 2, 3]`, policy `prefer`, and
  seed `123456`. It returned `NON_EVASIVE` after 54 vertex attempts and 84
  examined subcomplexes, with zero protected candidates skipped.
- Shell and Python syntax checks passed.

### Stage 2: Define a certificate format and add an independent verifier

Status: completed on 2026-09-24

- Store certificates as state DAGs rather than expanded trees.
- Give every state a stable identifier.
- For a non-evasive state, record the selected vertex and both successful child
  states: deletion and link.
- For an evasive state, record a failed child for every candidate vertex, or an
  independently checkable terminal obstruction.
- Record terminal reasons such as simplex, cone, tree, disconnected complex,
  Euler-characteristic obstruction, or nontrivial homology.
- Add a separate verifier that reconstructs each state from the original facets
  and does not trust the search program's verdict.

Validation gate:

- Every emitted certificate must pass the independent verifier.
- Deliberately corrupted vertices, branches, terminal reasons, and input hashes
  must cause verification to fail.

Stage 2A validation performed:

- Added a versioned JSON certificate containing an input-complex hash, vertex
  bit order, reproducibility metadata, terminal reasons, and a reachable proof
  DAG for `NON_EVASIVE` results.
- Added an independent verifier that reconstructs deletion and link states from
  the original facets and recomputes simplex, cone, and tree leaves.
- Verified the Rudin's-ball certificate, including all internal transitions.
- Confirmed that corrupting the input hash causes verification to fail.
- Reran all Stage 1 result-semantics tests successfully.

Stage 2B validation performed:

- Extended the proof store and JSON schema so every recursive evasive state
  names one evasive child for every vertex in that state.
- Extended the independent verifier to require exact vertex coverage, validate
  every failed-child mask and transition, and recompute empty, non-tree,
  disconnected, Euler-characteristic, and homology obstruction leaves.
- Added a seven-vertex acyclic evasive regression complex whose certificate
  requires recursive negative proof obligations rather than a root homology
  rejection.
- Verified its complete evasiveness certificate and confirmed that removing
  one root vertex obligation causes verification to fail.
- Confirmed that corrupted hashes, winning vertices, branch references, and
  terminal reasons are rejected.
- Reran the Stage 2A and Stage 1 suites successfully.

### Stage 3: Repair and simplify proof output

Status: completed on 2026-09-24

- Export the certificate once after the search finishes.
- Remove repeated CSV rewrites from inside recursive tree printing.
- Replace ambiguous depth-only CSV relationships with explicit node and parent
  or child identifiers.
- Stop describing the root winning vertex as a complete "deletion path"; the
  mathematical witness is a branching decision tree or DAG.

Validation performed:

- Removed v12's expanded `ProofNode` reconstruction and recursive console-tree
  printing. The cached search result now feeds the certificate DAG directly.
- Removed v12's legacy CSV writer and all repeated recursive CSV rewrites.
- The JSON certificate is written atomically exactly once for each conclusive
  v12 run and reports its reachable DAG state count.
- Confirmed that setting the historical `CSV_OUTPUT` variable does not create a
  v12 CSV artifact, while the generic runner retains that variable for v1-v11.
- Verified the resulting Rudin's-ball DAG with the independent verifier.
- Reran the Stage 2A, Stage 2B, and Stage 1 suites successfully.

### Stage 4: Introduce a bitset search core

Status: completed on 2026-09-24

- Assign one bit to each root vertex.
- Store facets as integer masks.
- Represent a search state using linked and deleted masks.
- Perform common deletion, link, presence, and facet operations without
  repeatedly constructing SageMath objects.
- Materialize a Sage `SimplicialComplex` only when a Sage-specific topological
  calculation is needed.

Validation gate:

- For a comprehensive collection of small complexes, bitset deletion and link
  must exactly match SageMath deletion and link.
- The bitset and v12 reference searches must return the same verdicts and
  verifiable certificates.

Stage 4A validation performed:

- Added a standalone root-facet bitset model supporting canonical facet
  normalization, vertex presence, deletion, link, and direct reconstruction
  from disjoint linked/deleted masks.
- Kept the active v12 recursion unchanged so representation correctness can be
  reviewed independently of search-engine integration.
- Exhaustively compared bitset operations with SageMath for every distinct
  nonempty complex on at most four labeled vertices, with additional
  relabeled, custom-order, redundant-facet, and non-pure examples.
- Confirmed that empty-vertex states retain SageMath's empty-facet convention
  and that invalid, overlapping, unknown, and non-face masks are rejected.

Stage 4B validation performed:

- Made the verified root-facet bitset model the default v12 state engine.
- Moved state reconstruction after cache lookup, so cache hits no longer build
  unused child SageMath complexes.
- Each cache miss now reconstructs facets directly from the linked/deleted
  masks and materializes exactly one SageMath complex for classification.
- Retained a `sage_reference` engine that independently replays SageMath links
  and deletions from the root for equivalence testing.
- The bitset and Sage-reference engines returned the same verdict and exact
  certificate state DAG on Rudin's ball and the recursive acyclic evasive
  fixture. All four certificates passed the independent verifier.
- Added the engine and materialization counters to heartbeat, certificate, and
  final-result metadata. The generic runner now forwards `STATE_ENGINE`.

Stage 4C bounded-search and benchmark validation performed:

- Added optional cache-miss state and cooperative wall-time limits. A stop at
  either limit returns `INCONCLUSIVE_RESOURCE_LIMIT` and cannot fall through
  to evasiveness classification or certificate emission.
- Recorded configured limits, the stopping reason, elapsed time, and peak
  resident memory in run output and heartbeat metadata.
- Added a sequential comparison runner for the bitset and Sage-reference
  engines. It applies the same input, seed, protection policy, and limits;
  verifies any conclusive certificates; and writes a tab-separated summary.
- Benchmark directories are timestamped and the runner refuses to overwrite
  an existing directory, preserving prior experimental records.
- Confirmed with regression tests that a one-state limit materializes exactly
  one state, a near-zero time limit materializes none, neither emits a
  certificate, invalid limits fail validation, and both engines participate
  in the bounded benchmark path.
- Corrected the generic runner to copy the v12 bitset companion module beside
  its temporary Sage script.

Recorded Stage 4C benchmark (`RANDOM_SEED=123456`, protected vertices
`[1, 2, 3]`, 10,000-state limit, 60-second cooperative limit):

| Engine | Result | States | Elapsed seconds | Peak RSS MiB | Certificate |
| --- | --- | ---: | ---: | ---: | --- |
| `bitset` | `NON_EVASIVE` | 84 | 0.122800 | 224.027 | verified |
| `sage_reference` | `NON_EVASIVE` | 84 | 0.362682 | 207.648 | verified |

On this small resolved workload, the bitset engine was about 3.0 times faster
but reported about 16 MiB higher peak resident memory. This is one benchmark,
not a general performance guarantee or a direct comparison with historical
v11, because the reference engine deliberately replays each state from the
root. The local artifacts are stored under
`outputs/benchmarks/rudins_stage4c_fair_20260924T193515Z/`.

### Stage 5: Improve memoization and exploit symmetry

Status: completed; Stage 5A normalized-complex memoization completed on
2026-09-24, with Stage 5B canonical isomorphism reuse and Stage 5C
automorphism-orbit pruning completed on 2026-09-25.

- Cache by normalized resulting complexes in addition to operation history.
- Investigate canonical labeling of the vertex-facet incidence graph so that
  isomorphic states can share results.
- Compute automorphism orbits and branch on one representative per orbit when
  the orbit computation is cheaper than the saved search.
- Record orbit justifications in evasiveness certificates.

Validation gate:

- Turning symmetry reduction on or off must not change the mathematical result.
- The verifier must confirm every isomorphism map directly.
- In Stage 5C, the verifier must confirm that orbit representatives cover
  every vertex.

Stage 5A validation performed:

- Added an optional, default-enabled cache keyed by the exact canonical tuple
  of labeled maximal facet masks. No probabilistic hash is used, so cache-key
  collisions cannot affect correctness.
- Kept the linked/deleted operation-history cache as the first lookup. The
  normalized key is computed only after that cache misses, and a normalized
  hit avoids SageMath materialization and recursive recomputation.
- Added a separately configurable bounded LRU for normalized failed states
  (`NORMALIZED_CACHE_MAX_FAILURES`, default 100,000) and exposed cache sizes,
  hits, evictions, key computations, and proof aliases in heartbeats and final
  statistics.
- Extended certificates to schema version 2 with explicit
  `equivalent_state` proof edges. The independent verifier reconstructs both
  states, checks identical labeled facets and verdicts, rejects cycles and
  mixed proof forms, and still accepts alias-free schema-1 certificates.
- Added the suspension over the seven-vertex acyclic evasive fixture. With
  seed 45, cache-off search materialized 24 states while cache-on search
  materialized 16; one normalized hit reused the full eight-state proof of the
  shared suspension-vertex link. Both evasiveness certificates verified.
- Verified positive equivalence handling with Rudin's ball and seed 13, whose
  reachable non-evasive proof DAG contains a normalized equivalence edge.
- Confirmed that missing, nonidentical, mixed-form, and schema-1 equivalence
  aliases are rejected. Cache-on and cache-off runs retain the same
  mathematical result.

Stage 5B validation performed:

- Added an optional cache keyed by the complete canonically labeled
  vertex-facet incidence graph, with distinct color classes for vertices and
  facets. No digest is used. Strict protected-vertex searches additionally
  distinguish protected from unprotected vertices so restricted-search cache
  results remain valid.
- Preserved lookup order: operation history first, exact labeled facets
  second, and isomorphism third. Canonical labeling therefore runs only when
  both cheaper exact caches miss.
- Added a separately configurable bounded LRU for failed isomorphism classes
  (`ISOMORPHISM_CACHE_MAX_FAILURES`, default 100,000), along with heartbeat,
  certificate-metadata, final-result, runner, and benchmark fields.
- Kept the feature opt-in (`ISOMORPHISM_COMPLEX_CACHE=false` by default)
  because its fixed canonical-label cost can outweigh the saved recursion on
  small inputs.
- Extended certificates to schema version 3 with `isomorphic_state` edges and
  explicit source-to-target vertex bijections. The independent verifier
  checks total coverage, bijectivity, mapped facets, verdicts, reachability,
  proof-form exclusivity, and cycles without invoking the search cache.
- Exhaustively compared the incidence-graph keys with an independent
  brute-force permutation canonicalizer for all 189 labeled complexes on at
  most four vertices. Colored-vertex and explicit-map tests also passed.
- With Rudin's ball and seed 13, exact caching alone materialized 57 states;
  enabling isomorphism reuse materialized 43 and produced 10 verified
  isomorphism aliases. Both runs returned `NON_EVASIVE` and their certificates
  independently verified. Elapsed time on this tiny fixture rose from about
  0.11 to 0.13 seconds, supporting the opt-in default.
- Confirmed that missing targets, absent or partial maps, out-of-range target
  labels, mixed proof forms, and schema-2 isomorphism records are rejected.
  Legacy schema-1 and schema-2 support remains covered by earlier suites.

Stage 5C validation performed:

- Added optional automorphism-orbit pruning after terminal classification and
  vertex ordering. The first candidate in each color-preserving orbit is used
  as its representative, so existing strategies still determine representative
  order.
- Reused the colored vertex-facet incidence model. In strict protected mode,
  protected and unprotected vertices cannot share an orbit, preserving the
  restricted search semantics.
- Extended certificates to schema version 4. Each pruned negative obligation
  records its complete orbit and an explicit simplicial automorphism from the
  tested representative to every skipped vertex.
- Extended the independent verifier to check every automorphism is a total
  vertex bijection, preserves the complete facet set, maps the representative
  to the claimed member, has no overlapping coverage, and collectively covers
  every vertex. The verifier does not trust Sage's orbit result from the search.
- Exhaustively compared orbit partitions with an independent brute-force
  permutation implementation for all 189 labeled complexes on at most four
  vertices and checked 641 explicit maps. Colored candidate coverage also
  passed.
- On the symmetric suspension fixture with both memoization layers disabled,
  orbit pruning reduced materialized states from 24 to 16 and vertex attempts
  from 23 to 15. Both runs returned `EVASIVE_CERTIFIED` and independently
  verified; the orbit certificate used one explicit automorphism.
- Rejected missing orbit fields, missing automorphisms, invalid targets,
  incorrect representative images, broken bijections, and schema-3 orbit
  records. Orbit-free schema-3 certificates remain supported.
- Kept `AUTOMORPHISM_ORBIT_PRUNING=false` as the default because automorphism
  computation can outweigh saved branching on asymmetric or small states.

### Stage 6: Improve branching and obstruction scheduling

Status: completed on 2026-09-25. Stage 6A added child-aware branch ordering;
Stage 6B added adaptive obstruction scheduling and certified residual-state
obstructions.

- Classify both immediate children cheaply before entering deep recursion.
- Prefer vertices whose links are already simplices, trees, cones, or other
  certified non-evasive terminal states.
- Retain outer-layer, minimum-link, lexical, and seeded-random orderings as
  ordering strategies rather than correctness restrictions.
- Profile connectivity, Euler characteristic, GF(2) homology, small-prime
  homology, and integral homology by time spent per rejected state.
- Investigate certified non-collapsibility or discrete-Morse obstructions on
  sufficiently small residual complexes.

Validation gate:

- Each rejection test must be mathematically one-sided and covered by a test.
- Disabling an optimization must affect performance only, not the final result.

Stage 6A validation performed:

- Added an opt-in child-aware ordering layer after the configured base vertex
  strategy. `SEARCH_STRATEGY` now exposes the existing random, greedy,
  outer-layer, maximum-degree, lexical, reverse-lexical, and exhaustive
  strategies without changing the default seeded-random behavior.
- Added exact bitset recognition for empty complexes, simplices, cones, trees,
  one-dimensional non-trees, and disconnected complexes. These classifications
  rank candidates but do not replace recursive proof obligations or alter the
  certificate schema.
- Prioritized candidates with two cheaply certified positive children, then
  candidates with one positive child, unresolved candidates, and finally
  candidates with a cheaply certified negative child. The original strategy
  remains the final tie-breaker, and soft protected vertices retain their
  ordering priority.
- Reused precomputed child facet tuples in the selected recursive calls, so
  scoring does not force the bitset state to be reconstructed a second time.
- Added configurable size gates (`CHILD_AWARE_MAX_VERTICES`, default 80, and
  `CHILD_AWARE_MAX_FACETS`, default 500). Zero means unlimited. The feature
  remains opt-in (`CHILD_AWARE_ORDERING=false`) because full candidate scoring
  can cost more than it saves on small or asymmetric states.
- Exhaustively matched every cheap classification and connectivity result with
  SageMath for all 189 labeled complexes on at most four vertices: 79 positive
  terminals, 87 negative terminals, and 23 correctly left unresolved.
- With Rudin's ball, seed `123456`, exact normalized caching, and other
  symmetry options disabled, child-aware ordering reduced materialized states
  from 57 to 37 and vertex attempts from 36 to 20. Both certificates verified,
  and bitset and Sage-reference engines produced identical proof states.
  Elapsed time on this tiny case rose from about 0.10 to 0.12 seconds, showing
  why a representative bounded A/B run is required before long deployment.
- Confirmed that size-gated fallback reproduces the baseline, protected
  preference and restriction retain their result semantics, invalid settings
  fail early, and all earlier suites remain compatible.
- Added a sequential, non-overwriting branching benchmark runner. It holds the
  input, seed, base strategy, caches, symmetry settings, engine, and resource
  limits fixed; changes only child-aware ordering; and verifies every
  conclusive certificate independently. This runner is ready for an unresolved
  server test without waiting for Stage 6B or later stages.

Recorded Stage 6A validation benchmark (`RANDOM_SEED=123456`, random base
strategy, normalized cache enabled, other symmetry options disabled, unlimited
state/time limits):

| Ordering | Result | States | Vertex attempts | Deepest path | Seconds | Certificate |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| baseline | `NON_EVASIVE` | 57 | 36 | 10 | 0.113251 | verified |
| child-aware | `NON_EVASIVE` | 37 | 20 | 9 | 0.119396 | verified |

The preserved local artifacts are stored under
`outputs/benchmarks/rudins_stage6a_seed123456_20260925/`.

Stage 6B validation performed:

- Added a fixed or adaptive obstruction scheduler. Fixed mode remains the
  default. Adaptive mode waits until each eligible test completes a configured
  warmup, then orders tests by observed seconds per rejection. Every eligible
  test still runs unless an earlier one has already certified rejection.
- Profiled connectivity, Euler characteristic, the no-free-face theorem,
  every configured finite-field homology screen, and integral homology by
  calls, elapsed time, rejections, and time per rejection. Heartbeats, console
  statistics, certificates, and the final machine-readable result expose the
  relevant configuration and counters.
- Generalized the GF(2) descendant screen to distinct configurable small prime
  fields from 2 through 97. The default remains GF(2), and optional root field
  screens remain disabled by default. Integral homology is still the final
  root test whenever earlier one-sided screens do not reject.
- Added an exact, opt-in no-free-face obstruction with independent vertex and
  facet size gates. A non-simplex with no free face cannot begin an elementary
  collapse; because every non-evasive complex is collapsible, this certifies a
  negative terminal rather than treating heuristic failure as proof.
- Independently taught the certificate verifier to validate arbitrary allowed
  small-prime homology reasons and no-free-face non-collapsibility reasons.
  The certificate schema remains version 4 because the proof record structure
  did not change.
- Exhaustively matched bitset free-face detection against an independent Sage
  facet-set implementation on all 189 labeled complexes with at most four
  vertices.
- On Sage's eight-vertex Dunce Hat triangulation, both the old exhaustive path
  and the new theorem returned independently verified `EVASIVE_CERTIFIED`
  results. The no-free-face theorem reduced the reachable certificate from
  nine states to one and avoided root integral homology.
- On a nine-vertex triangulation of the Moore space with 3-torsion, GF(2)
  reduced homology was trivial while GF(3) was nontrivial. The solver emitted
  a one-state `nontrivial_homology_GF3` certificate, which the independent
  verifier accepted without running integral homology.
- Confirmed that size-gated fallback follows the previous exact path, invalid
  scheduler and prime settings fail early, and the sequential non-overwriting
  fixed-versus-adaptive benchmark verifies every conclusive certificate.

Stage 6B remains opt-in for long searches (`OBSTRUCTION_SCHEDULER=fixed` and
`NONCOLLAPSIBILITY_OBSTRUCTION=false` by default) until a representative
bounded A/B run establishes the best settings for the unresolved complexes.

### Stage 7: Add checkpoint and resume support

Status: completed on 2026-09-25.

- Persist completed states, certificate fragments, and configuration metadata.
- Refuse to resume if the input hash, code version, or correctness-affecting
  configuration differs.
- Distinguish a clean completed search from interruption or resource exhaustion.
- Consider a disk-backed failure cache for long exact searches.

Validation gate:

- An interrupted and resumed small search must produce a certificate equivalent
  to an uninterrupted run.

Validation performed:

- Added opt-in, atomic JSON checkpoints containing completed proof records,
  the exact failed-state LRU, RNG state, adaptive obstruction profiles,
  cumulative cache-miss counts, resource-limit metadata, and explicit
  `running`, `resource_limit`, `interrupted`, `completed`, or `error` status.
- Added a canonical input fingerprint, correctness/search configuration
  record, Sage version, and SHA-256 hashes of the solver, bitset engine, and
  isomorphism implementation. Resume refuses mismatched input, configuration,
  implementation, schema, structure, or payload checksum.
- Kept state and time limits outside the compatibility fingerprint so a new
  session can safely receive a larger budget without changing the underlying
  search semantics.
- Added explicit overwrite protection. A fresh run refuses an existing path
  unless `CHECKPOINT_OVERWRITE=true`; ordinary continuation requires
  `CHECKPOINT_RESUME=true`. Completed checkpoints are retained rather than
  silently deleted.
- Added cooperative `SIGINT` and `SIGTERM` handling. An interruption is
  reported separately as `INCONCLUSIVE_INTERRUPTED`, writes an `interrupted`
  checkpoint after the current Sage operation, and never emits a mathematical
  certificate.
- A ten-state bounded lexical search of Rudin's ball resumed to
  `NON_EVASIVE`; its independently verified 47-state certificate records were
  exactly equal to those from an uninterrupted lexical run. The resumed
  session examined fewer new states.
- A real SIGTERM during root homology produced a checksummed `interrupted`
  checkpoint. Resuming it produced the same verified certificate records as
  the uninterrupted run.
- Confirmed that resuming an already completed checkpoint performs zero new
  cache-miss materializations, and that strict protected-vertex checkpoints
  remain `INCONCLUSIVE_RESTRICTED` after resume.
- Did not add a live disk lookup on every failed-cache access. The in-memory
  bounded LRU is restored between sessions; a disk-backed online cache remains
  unnecessary until representative long-run measurements justify its I/O and
  consistency cost.

### Stage 8: Add a regression and reference test suite

Status: completed on 2026-09-25.

Include at least:

- a point and filled simplices;
- trees, a cycle, and disconnected zero-dimensional complexes;
- cones over both non-evasive and evasive bases;
- boundaries of simplices;
- relabeled copies of every test complex;
- cache-on/cache-off comparisons;
- protected-preference and strict-restriction comparisons;
- exhaustive comparison with a small independent reference implementation;
- certificate serialization, verification, and corruption tests.

Validation performed:

- Added a deliberately small, independent recursive implementation using
  immutable Python sets. It imports no production bitset, search, cache,
  obstruction, or certificate implementation.
- Enumerated all 189 distinct nonempty facet antichains on at most four
  vertices. Production search matched the independent verdict for every
  complex with normalized memoization both disabled and enabled.
- Checked every permutation of every ambient label set: all 4,101 relabeled
  production searches agreed with the original and independent verdicts, using
  sparse nonzero labels to expose label-index assumptions.
- Added named fixtures for a point, tree, disconnected zero-dimensional
  complex, cones over a tree and cycle, and a tetrahedron boundary, alongside
  the existing simplex, cycle, protected-policy, and recursive evasive cases.
- Verified positive and recursive negative certificates after JSON round trips,
  independently accepted cache-on and cache-off proofs, and rejected a broken
  input binding and incomplete negative child coverage.
- Confirmed that preferred protected vertices retain a conclusive
  `NON_EVASIVE` result, while the deliberately incomplete strict policy returns
  `INCONCLUSIVE_RESTRICTED` without a certificate.
- Added one ordered runner for every accumulated v12 suite so the complete
  stage history can be validated without deleting or replacing earlier tests.
- Ran that consolidated matrix successfully: all 14 bounded-search and
  Stage 1 through Stage 8 suites passed in a fresh disposable Sage container.

## Related experimental scripts

The homology deletion scripts remain useful for exploration, but trivial
homology does not prove non-evasiveness. Testing deletions of one fixed size
also does not replace the recursive link/deletion proof required for
evasiveness.

Partitionability, collapsibility, homological triviality, and non-evasiveness
should be reported as distinct properties unless a specific theorem connects
them for the complexes under study.

## Batch concurrency decision

No immediate change is planned for `batch_calculations.sh`.

The batch launcher was intentionally created to start multiple smaller jobs,
and current usage is limited manually to two simultaneous jobs per server.
That is a reasonable operating procedure. If automated scheduling becomes
useful later, an optional `MAX_PARALLEL` setting can be added without removing
the existing ability to submit several jobs. This is lower priority than search
correctness, certificates, and checkpointing.

## Recommended next sequence

1. Run the consolidated v12 regression command before each merge or deployment.
2. Run a bounded unresolved-complex experiment with the Stage 6 features and
   Stage 7 checkpointing enabled, comparing the most promising configuration
   against the fixed baseline.
3. Review the full v12 branch and its preserved stage-by-stage history before
   merging or deploying it as the primary long-search implementation.

## Change log

| Date | Branch | Change | Validation |
| --- | --- | --- | --- |
| 2026-09-24 | `feature/nonevasive-v12` | Created the v12 proposal and preservation plan. No search implementation changed. | Repository history and prior scripts preserved. |
| 2026-09-24 | `feature/nonevasive-v12` | Added the v12 baseline and Stage 1 result semantics, protected-vertex policies, input checks, fixtures, and tests. | Four focused Sage tests passed; Rudin's-ball smoke test returned `NON_EVASIVE`. |
| 2026-09-24 | `feature/nonevasive-v12` | Stage 2A: added positive certificate DAG export and an independent verifier. | Rudin's-ball certificate passed; a corrupted certificate was rejected; Stage 1 regression suite passed. |
| 2026-09-24 | `feature/nonevasive-v12` | Stage 2B: added complete recursive evasiveness certificates and negative verification. | A recursive acyclic evasive certificate passed; incomplete vertex coverage and other corruptions were rejected; earlier suites passed. |
| 2026-09-24 | `feature/nonevasive-v12` | Stage 3: made the certificate DAG the primary v12 proof output and removed expanded tree/CSV reconstruction. | No legacy CSV or expanded tree was produced; the sole proof artifact passed independent verification; all earlier suites passed. |
| 2026-09-24 | `feature/nonevasive-v12` | Stage 4A: added an isolated root-facet bitset representation and Sage-equivalence suite without changing the active search path. | Bitset state reconstruction, deletion, and link matched Sage for every distinct complex on at most four labeled vertices plus relabeled and non-pure cases. |
| 2026-09-24 | `feature/nonevasive-v12` | Stage 4B: integrated the bitset representation after cache lookup and retained a Sage replay engine for reference testing. | Both engines produced identical independently verified certificates for Rudin's ball and a recursive evasive fixture; every cache miss materialized exactly one Sage state. |
| 2026-09-24 | `feature/nonevasive-v12` | Stage 4C: added sound state/time limits and a non-overwriting sequential engine benchmark runner. | State and time stops returned `INCONCLUSIVE_RESOURCE_LIMIT` without certificates; bounded bitset and Sage-reference smoke runs produced an auditable summary. |
| 2026-09-24 | `feature/nonevasive-v12` | Stage 5A: cached exact labeled complexes across different link/deletion histories and added schema-2 equivalence proof edges. | Cache-on/off results verified; the suspension fixture fell from 24 to 16 materializations; positive and negative aliases verified; corrupt aliases were rejected. |
| 2026-09-25 | `feature/nonevasive-v12` | Stage 5B: added opt-in canonical isomorphism memoization and schema-3 bijection proof edges. | Exhaustive keys matched brute force on 189 small complexes; Rudin's ball fell from 57 to 43 materializations; cache-on/off certificates verified; malformed maps were rejected. |
| 2026-09-25 | `feature/nonevasive-v12` | Stage 5C: added opt-in automorphism-orbit pruning and schema-4 orbit justifications. | Exhaustive orbits and 641 maps matched brute force; the suspension fixture fell from 24 to 16 materializations; corrupt orbit evidence was rejected. |
| 2026-09-25 | `feature/nonevasive-v12` | Stage 6A: added exact child preclassification, size-gated child-aware ordering, and a sequential branching benchmark. | Cheap classifications matched Sage on 189 complexes; Rudin's ball fell from 57 to 37 materializations; both engines and certificates matched; protected and fallback semantics passed. |
| 2026-09-25 | `feature/nonevasive-v12` | Stage 6B: added profiled adaptive obstruction scheduling, configurable small-prime homology, and a certified no-free-face obstruction. | Free-face detection matched Sage on 189 complexes; the Dunce Hat certificate fell from nine states to one; GF(3) detected Moore-space torsion missed by GF(2); certificates and the A/B runner verified. |
| 2026-09-25 | `feature/nonevasive-v12` | Stage 7: added atomic, checksummed checkpoint/resume with compatibility fingerprints, overwrite protection, and cooperative signal handling. | A bounded Rudin run resumed to the exact uninterrupted 47-state certificate; SIGTERM resumed equivalently; completed and strict-policy resumes passed; stale and corrupted checkpoints were rejected. |
| 2026-09-25 | `feature/nonevasive-v12` | Stage 8: added an independent recursive oracle, exhaustive small-complex and relabeling comparisons, named topology fixtures, and a consolidated regression runner. | Cache-on/off verdicts matched for all 189 complexes; all 4,101 relabelings agreed; certificates and corruptions behaved correctly; all 14 accumulated suites passed. |
