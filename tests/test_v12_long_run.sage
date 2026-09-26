"""Regression tests for cache representatives surviving exact-LRU eviction."""

import os
import random
import sys
from pathlib import Path

from sage.topology.simplicial_complex import SimplicialComplex


PROJECT_DIR = Path(__file__).resolve().parent.parent
SOLVER_PATH = PROJECT_DIR / "scripts" / "knot_nonevasive_v12.sage"
TEST_DATA_DIR = PROJECT_DIR / "tests" / "data"
sys.path.insert(0, str(PROJECT_DIR / "scripts"))


def load_solver_definitions():
    settings = {
        "FACETS_FILE": str(TEST_DATA_DIR / "cycle.txt"),
        "RANDOM_SEED": "123456",
        "PROTECTED_VERTICES": "",
        "PROTECTED_VERTEX_POLICY": "prefer",
        "STATE_ENGINE": "bitset",
        "SEARCH_STRATEGY": "lexical",
        "WITNESS_CACHE_MAX_FAILURES": "1",
        "NORMALIZED_COMPLEX_CACHE": "true",
        "NORMALIZED_CACHE_MAX_FAILURES": "10",
        "ISOMORPHISM_COMPLEX_CACHE": "false",
        "ISOMORPHISM_CACHE_MAX_FAILURES": "10",
        "AUTOMORPHISM_ORBIT_PRUNING": "false",
        "CHILD_AWARE_ORDERING": "false",
        "NONCOLLAPSIBILITY_OBSTRUCTION": "false",
        "HOMOLOGY_FIELD_PRIMES": "",
        "CHECKPOINT_PATH": "",
        "SEARCH_STATE_LIMIT": "0",
        "SEARCH_TIME_LIMIT_SECONDS": "0",
    }
    os.environ.update(settings)
    source = SOLVER_PATH.read_text(encoding="utf-8")
    definitions, marker, _driver = source.partition("# Run the test")
    assert marker
    namespace = {
        "__file__": str(SOLVER_PATH),
        "__name__": "v12_long_run_definitions",
    }
    exec(compile(definitions, str(SOLVER_PATH), "exec"), namespace)
    namespace["log_heartbeat"] = lambda *args, **kwargs: None
    return namespace


SOLVER = load_solver_definitions()


class DummyCheckpointManager:
    def maybe_write(self):
        return None


def cycle_state():
    complex_ = SimplicialComplex([[1, 2], [2, 3], [1, 3]])
    root_bitset = SOLVER["RootBitsetComplex"](
        SOLVER["canonical_facets"](complex_),
        vertex_order=[int(vertex) for vertex in complex_.vertices()],
    )
    return complex_, root_bitset, (int(0), int(0))


def evict_exact_failure(witness_cache, state_key):
    no_winner = SOLVER["_NO_WINNING_VERTEX"]
    witness_cache.store(state_key, False, no_winner)
    witness_cache.store((int(0), int(1)), False, no_winner)
    assert witness_cache.lookup(state_key) is SOLVER["_CACHE_MISS"]


def run_search(
    complex_,
    root_bitset,
    state_key,
    witness_cache,
    normalized_cache,
    isomorphism_cache,
    certificate_store,
):
    return SOLVER["find_nonevasive_witness"](
        complex_,
        root_bitset,
        witness_cache,
        normalized_cache,
        isomorphism_cache,
        certificate_store,
        DummyCheckpointManager(),
        root_bitset.vertex_bits,
        strategy="lexical",
        rng=random.Random(int(123456)),
        state_key=state_key,
        precomputed_facets=root_bitset.root_facets,
    )


complex_, root_bitset, state_key = cycle_state()
no_winner = SOLVER["_NO_WINNING_VERTEX"]

# Reproduce the production failure: the exact failure is evicted while the
# normalized cache and proof store still retain this state as representative.
SOLVER["search_stats"].reset(len(complex_.vertices()), "lexical")
SOLVER["NORMALIZED_COMPLEX_CACHE"] = True
SOLVER["ISOMORPHISM_COMPLEX_CACHE"] = False
witness_cache = SOLVER["WitnessCache"](max_failures=1)
normalized_cache = SOLVER["NormalizedComplexCache"](max_failures=10)
isomorphism_cache = SOLVER["IsomorphismComplexCache"](max_failures=10)
certificate_store = SOLVER["CertificateStore"]()
certificate_store.store_terminal(
    state_key, False, "one_dimensional_not_tree"
)
normalized_cache.store(
    root_bitset.root_facets, state_key, False, no_winner
)
evict_exact_failure(witness_cache, state_key)

assert run_search(
    complex_,
    root_bitset,
    state_key,
    witness_cache,
    normalized_cache,
    isomorphism_cache,
    certificate_store,
) is False
assert witness_cache.lookup(state_key)[0] is False
assert SOLVER["search_stats"].normalized_cache_hits == 1
assert SOLVER["search_stats"].certificate_equivalence_aliases == 0
assert SOLVER["search_stats"].subcomplexes_examined == 0
assert certificate_store.get(state_key)["terminal_reason"] == (
    "one_dimensional_not_tree"
)

# The isomorphism cache has the same representative lifetime issue and must
# likewise restore the exact cache without writing a self-isomorphism edge.
SOLVER["search_stats"].reset(len(complex_.vertices()), "lexical")
SOLVER["NORMALIZED_COMPLEX_CACHE"] = False
SOLVER["ISOMORPHISM_COMPLEX_CACHE"] = True
witness_cache = SOLVER["WitnessCache"](max_failures=1)
normalized_cache = SOLVER["NormalizedComplexCache"](max_failures=10)
isomorphism_cache = SOLVER["IsomorphismComplexCache"](max_failures=10)
certificate_store = SOLVER["CertificateStore"]()
certificate_store.store_terminal(
    state_key, False, "one_dimensional_not_tree"
)
canonical_key, label_to_canonical = SOLVER["canonical_incidence_key"](
    root_bitset.root_facets,
    root_bitset.vertex_order,
    distinguished_vertices=(),
)
isomorphism_cache.store(
    canonical_key,
    label_to_canonical,
    state_key,
    False,
    no_winner,
)
evict_exact_failure(witness_cache, state_key)

assert run_search(
    complex_,
    root_bitset,
    state_key,
    witness_cache,
    normalized_cache,
    isomorphism_cache,
    certificate_store,
) is False
assert witness_cache.lookup(state_key)[0] is False
assert SOLVER["search_stats"].isomorphism_cache_hits == 1
assert SOLVER["search_stats"].certificate_isomorphism_aliases == 0
assert SOLVER["search_stats"].subcomplexes_examined == 0
assert certificate_store.get(state_key)["terminal_reason"] == (
    "one_dimensional_not_tree"
)

print("PASS: normalized representative survived exact failure eviction")
print("PASS: isomorphism representative survived exact failure eviction")
print("All v12 long-run cache tests passed.")
