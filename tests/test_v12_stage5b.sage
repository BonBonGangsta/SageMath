"""Exhaustive small-complex tests for Stage 5B canonical labeling."""

import itertools
import sys
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_DIR / "scripts"))

from simplicial_bitset import normalize_facet_masks, vertices_mask  # noqa: E402
from simplicial_isomorphism import (  # noqa: E402
    canonical_incidence_key,
    canonical_map_inverse,
    vertex_isomorphism,
)


def all_distinct_complexes(vertex_count):
    """Generate every nonempty antichain of nonempty faces."""
    nonempty_faces = tuple(range(1, 1 << vertex_count))
    distinct = set()
    for selection in range(1, 1 << len(nonempty_faces)):
        facets = (
            face
            for index, face in enumerate(nonempty_faces)
            if selection & (1 << index)
        )
        distinct.add(normalize_facet_masks(facets))
    return tuple(sorted(distinct))


def brute_force_isomorphism_key(facet_masks, vertex_count):
    """Canonize by trying every permutation, independently of Sage Graph."""
    normalized = normalize_facet_masks(facet_masks)
    present_mask = vertices_mask(normalized)
    present_positions = tuple(
        position
        for position in range(vertex_count)
        if present_mask & (1 << position)
    )
    compact_position = {
        position: index for index, position in enumerate(present_positions)
    }
    compact_facets = tuple(
        tuple(
            compact_position[position]
            for position in present_positions
            if facet_mask & (1 << position)
        )
        for facet_mask in normalized
    )

    canonical_facets = None
    for permutation in itertools.permutations(range(len(present_positions))):
        relabeled = tuple(
            sorted(
                tuple(sorted(permutation[position] for position in facet))
                for facet in compact_facets
            )
        )
        if canonical_facets is None or relabeled < canonical_facets:
            canonical_facets = relabeled
    return (len(present_positions), canonical_facets)


brute_to_incidence = {}
incidence_to_brute = {}
complex_count = 0

empty_key, empty_map = canonical_incidence_key((0,), (10, 20))
assert empty_map == {}
assert empty_key[0] == (0, 0)

for vertex_count in range(1, 5):
    vertex_order = tuple(range(vertex_count))
    for facet_masks in all_distinct_complexes(vertex_count):
        incidence_key, label_to_canonical = canonical_incidence_key(
            facet_masks, vertex_order
        )
        brute_key = brute_force_isomorphism_key(
            facet_masks, vertex_count
        )
        assert set(label_to_canonical) == {
            position
            for position in range(vertex_count)
            if vertices_mask(facet_masks) & (1 << position)
        }

        previous_incidence = brute_to_incidence.setdefault(
            brute_key, incidence_key
        )
        previous_brute = incidence_to_brute.setdefault(
            incidence_key, brute_key
        )
        assert incidence_key == previous_incidence
        assert brute_key == previous_brute
        complex_count += 1

# A path with its center distinguished is not color-preservingly isomorphic
# to the same path with an endpoint distinguished.
path_facets = (0b011, 0b110)
center_key, _ = canonical_incidence_key(
    path_facets, (10, 20, 30), distinguished_vertices=(20,)
)
endpoint_key, _ = canonical_incidence_key(
    path_facets, (10, 20, 30), distinguished_vertices=(10,)
)
assert center_key != endpoint_key

# Relabeling the abstract path leaves its key unchanged and the induced map
# really sends every source facet onto a target facet.
source_key, source_map = canonical_incidence_key(
    (0b011, 0b110), (10, 20, 30)
)
target_key, target_map = canonical_incidence_key(
    (0b101, 0b110), (30, 10, 20)
)
assert source_key == target_key
mapping = dict(
    vertex_isomorphism(
        source_map,
        canonical_map_inverse(target_map),
    )
)
source_facets = ({10, 20}, {20, 30})
target_facets = ({30, 20}, {10, 20})
assert {frozenset(mapping[vertex] for vertex in facet) for facet in source_facets} == {
    frozenset(facet) for facet in target_facets
}

print(
    "PASS: colored incidence keys matched independent brute-force "
    f"isomorphism classes across {complex_count} labeled complexes."
)
print("PASS: distinguished colors and explicit vertex maps were validated.")
print("All Stage 5B canonical-label tests passed.")
