"""Exhaustive independent-reference tests for v12 Stage 8.

The reference implementation is deliberately plain Python and shares no
search, cache, obstruction, or certificate code with the production solver.
This test loads only the definition portion of the v12 script so thousands of
tiny complexes can be checked without paying Sage startup cost per case.
"""

import itertools
import json
import os
import random
import sys
from pathlib import Path

from sage.topology.simplicial_complex import SimplicialComplex


PROJECT_DIR = Path(__file__).resolve().parent.parent
SOLVER_PATH = PROJECT_DIR / "scripts" / "knot_nonevasive_v12.sage"
TEST_DATA_DIR = PROJECT_DIR / "tests" / "data"
sys.path.insert(0, str(PROJECT_DIR / "tests"))

import nonevasive_reference as reference  # noqa: E402


def load_facets(name):
    return json.loads((TEST_DATA_DIR / name).read_text(encoding="utf-8"))


def load_solver_definitions():
    """Execute v12 definitions but not its command-line search driver."""
    settings = {
        "FACETS_FILE": str(TEST_DATA_DIR / "point.txt"),
        "RANDOM_SEED": "123456",
        "PROTECTED_VERTICES": "",
        "PROTECTED_VERTEX_POLICY": "prefer",
        "STATE_ENGINE": "bitset",
        "SEARCH_STRATEGY": "lexical",
        "NORMALIZED_COMPLEX_CACHE": "true",
        "ISOMORPHISM_COMPLEX_CACHE": "false",
        "AUTOMORPHISM_ORBIT_PRUNING": "false",
        "CHILD_AWARE_ORDERING": "false",
        "OBSTRUCTION_SCHEDULER": "fixed",
        "NONCOLLAPSIBILITY_OBSTRUCTION": "false",
        "HOMOLOGY_FIELD_PRIMES": "",
        "CHECKPOINT_PATH": "",
        "CHECKPOINT_RESUME": "false",
        "CHECKPOINT_OVERWRITE": "false",
        "SEARCH_STATE_LIMIT": "0",
        "SEARCH_TIME_LIMIT_SECONDS": "0",
    }
    os.environ.update(settings)
    source = SOLVER_PATH.read_text(encoding="utf-8")
    definitions, marker, _driver = source.partition("# Run the test")
    assert marker, "Could not find the v12 command-line driver marker"
    namespace = {
        "__file__": str(SOLVER_PATH),
        "__name__": "v12_stage8_definitions",
    }
    exec(compile(definitions, str(SOLVER_PATH), "exec"), namespace)
    namespace["log_heartbeat"] = lambda *args, **kwargs: None
    return namespace


SOLVER = load_solver_definitions()


def production_verdict(facets, normalized_cache=True):
    SOLVER["NORMALIZED_COMPLEX_CACHE"] = bool(normalized_cache)
    complex_ = SimplicialComplex([list(facet) for facet in facets])
    verdict, _certificate_store, _vertex_bits, stop_reason = SOLVER[
        "is_nonevasive"
    ](
        complex_,
        strategy="lexical",
        # Sage preparses integer literals as Sage Integers, while the Python
        # standard-library RNG deliberately accepts only builtin seed types.
        rng=random.Random(int(123456)),
    )
    assert stop_reason is None
    assert verdict in (True, False)
    return bool(verdict)


def all_distinct_complexes(vertex_count):
    """Enumerate facet antichains on a fixed set of at most four vertices."""
    nonempty_faces = tuple(range(1, 1 << vertex_count))
    distinct = set()
    for selection in range(1, 1 << len(nonempty_faces)):
        chosen_facets = []
        for index, face_mask in enumerate(nonempty_faces):
            if selection & (1 << index):
                chosen_facets.append(
                    frozenset(
                        vertex
                        for vertex in range(vertex_count)
                        if face_mask & (1 << vertex)
                    )
                )
        distinct.add(reference.normalize_facets(chosen_facets))
    return tuple(
        sorted(
            distinct,
            key=lambda facets: tuple(
                (len(facet), tuple(sorted(facet))) for facet in facets
            ),
        )
    )


def relabel_facets(facets, mapping):
    return [
        [mapping[vertex] for vertex in sorted(facet)]
        for facet in facets
    ]


expected_counts = {1: 1, 2: 4, 3: 18, 4: 166}
complex_count = 0
relabeling_count = 0

for vertex_count in range(1, 5):
    complexes = all_distinct_complexes(vertex_count)
    assert len(complexes) == expected_counts[vertex_count]
    for facets in complexes:
        expected = reference.is_nonevasive(facets)
        without_cache = production_verdict(facets, normalized_cache=False)
        with_cache = production_verdict(facets, normalized_cache=True)
        assert without_cache == with_cache == expected, (
            facets,
            expected,
            without_cache,
            with_cache,
        )
        complex_count += 1

        # Exercise every permutation, using sparse labels so no production
        # code can accidentally depend on contiguous or zero-based vertices.
        for permutation in itertools.permutations(range(vertex_count)):
            mapping = {
                source: 10 + 7 * permutation[source]
                for source in range(vertex_count)
            }
            relabeled = relabel_facets(facets, mapping)
            relabeled_expected = reference.is_nonevasive(relabeled)
            relabeled_actual = production_verdict(
                relabeled, normalized_cache=True
            )
            assert relabeled_expected == expected
            assert relabeled_actual == expected, (
                facets,
                permutation,
                expected,
                relabeled_actual,
            )
            relabeling_count += 1


named_cases = {
    "point.txt": True,
    "simplex.txt": True,
    "tree.txt": True,
    "cycle.txt": False,
    "disconnected_vertices.txt": False,
    "cone_over_tree.txt": True,
    "cone_over_cycle.txt": True,
    "tetrahedron_boundary.txt": False,
}

for fixture_name, expected in named_cases.items():
    facets = load_facets(fixture_name)
    assert reference.is_nonevasive(facets) is expected
    assert production_verdict(facets) is expected
    vertices = sorted({vertex for facet in facets for vertex in facet})
    mapping = {
        vertex: 100 + 11 * index
        for index, vertex in enumerate(reversed(vertices))
    }
    relabeled = relabel_facets(facets, mapping)
    assert reference.is_nonevasive(relabeled) is expected
    assert production_verdict(relabeled) is expected


# The preferred protected-vertex policy is complete. The historical strict
# policy is intentionally incomplete and must record that it skipped choices.
protected_facets = load_facets("protected_policy_example.txt")
assert reference.is_nonevasive(protected_facets) is True
SOLVER["PROTECTED_VERTICES"] = frozenset({1, 2, 3})
SOLVER["PROTECTED_VERTEX_POLICY"] = "prefer"
assert production_verdict(protected_facets) is True
assert SOLVER["search_stats"].restricted_vertices_skipped == 0

SOLVER["PROTECTED_VERTEX_POLICY"] = "restrict"
assert production_verdict(protected_facets) is False
assert SOLVER["search_stats"].restricted_vertices_skipped > 0

SOLVER["PROTECTED_VERTICES"] = frozenset()
SOLVER["PROTECTED_VERTEX_POLICY"] = "prefer"

print(
    "PASS: production search matched the independent recursive oracle on "
    f"{complex_count} complexes with cache disabled and enabled."
)
print(
    "PASS: all "
    f"{relabeling_count} vertex permutations preserved the exact verdict."
)
print(
    "PASS: named topology fixtures, relabeled copies, and protected policies "
    "matched their expected semantics."
)
print("All Stage 8 reference tests passed.")
